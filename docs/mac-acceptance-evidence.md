# Mac acceptance evidence record

The VM acceptance job (`.github/workflows/mac-acceptance.yml`) writes one evidence record per tested image: `scripts/mac-acceptance-record.py` turns the harness's `run.txt` and exit status into the record, on every run, passing or not. The upload job (`mac-upload.yml`) and the catalog job refuse an image unless its record passes. `scripts/mac-upload.py check-evidence --evidence FILE --sha256 HEX` is the upload's check, and the acceptance job's gate uses it too. The catalog checks with `catalog_release.py check-evidence`, which takes every record the upload takes (it also allows `skip` for scenarios outside the required three).

## Format

A JSON object in a file named `acceptance-evidence.json`, uploaded as its own workflow artifact, `acceptance-evidence` (the upload job's `evidence-artifact` input names it):

```json
{
  "image_sha256": "<sha256 of the image zip, 64 lowercase hex digits>",
  "result": "pass",
  "scenarios": [
    {"name": "first-boot", "result": "pass"},
    {"name": "conversion", "result": "pass"},
    {"name": "second-boot", "result": "pass"}
  ],
  "harness_commit": "<40-hex commit of the omarchy-mac-pkgs VM harness>",
  "runner": "<runner label and host, for example namespace-profile-... M4>",
  "run_url": "https://github.com/omacom/omarchy-mac-installer/actions/runs/<id>"
}
```

- `image_sha256`: the digest of the exact zip the harness booted. It must equal the upload's expected sha256.
- `result`: `pass` or `fail`. A failing run still writes a record, with `fail`.
- `scenarios`: one entry per scenario run, each `pass` or `fail`. A passing record has every scenario `pass` and includes at least `first-boot`, `conversion` and `second-boot`.
- `harness_commit`, `runner`, `run_url`: where and with what the scenarios ran. `run_url` is the GitHub Actions run that uploaded the record's artifact; a real upload refuses a record that names any other run.

Other keys are allowed and ignored, so the harness can add detail (log digests, timings) without a format change.

## How the acceptance job fills it in

- `image_sha256` is the job's `image-sha256` input. The job checks the downloaded zip against it, and the zip's build attestation from `mac-image.yml` on `main`, before the harness runs; a mismatch writes a failing record.
- `scenarios` comes from the harness's `run.txt` (`ok`, `not ok` and `skip` lines, each naming its scenario). A scenario with a `not ok` line, or with no line at all because the run stopped before it, fails; one with only `skip` lines is `skip`. When the harness fails without a `not ok` line for any scenario, the scenario that was running fails.
- `result` is `pass` only when the harness exited 0, every scenario passed, and the record passes `mac-upload.py check-evidence`. Otherwise it is `fail`, with a `reason`.
- `harness_commit` is the job's pinned `HARNESS_COMMIT`, checked against the fetched harness.
- `runner` is the job's `runs-on` labels, the runner's name and its host name, at most 200 characters.
- Extra keys: `image` (the image name), `harness_status` (the harness's exit status, `null` when it never ran) and `reason`.

## Where a record is trusted from

A real upload takes the record only from a run of this repository's `main` branch that was not triggered by a pull request and, unless it is the upload's own run, that succeeded (`check-run`). Any such run can upload an artifact, so the acceptance workflow's `attest` job (GitHub-hosted, after a passing record) attests the record, and a real upload refuses a record without an attestation whose signer is `mac-acceptance.yml` on `main` from a GitHub-hosted runner. Dry runs accept a record from any run they're given, warn when it has no attestation, and still check it.
