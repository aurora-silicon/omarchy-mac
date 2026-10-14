# Mac release pipeline

`.github/workflows/mac-release-pipeline.yml` runs one edge image from build to a signed edge catalog. `edge-dispatch.yml` starts it (`dry-run=false`, on `main`) when an edge publish changes a package the image installs. You can also start it by hand, and a manual run is a dry run unless you say otherwise. The only manual step is the owner's approval of the catalog signature.

| Job | Workflow | Runs when | Gates it keeps |
| --- | --- | --- | --- |
| `plan` | here | always | a real run starts only from `main`, never for a pull request |
| `build` | `mac-image.yml` | after `plan` | no secrets; the release guard; a build attestation on the zip |
| `acceptance` | `mac-acceptance.yml` | after `build` | main only, never for a pull request; the zip's sha256 and build attestation checked; the VM harness's `fresh-install` scenarios on the VM runner ([runner](mac-acceptance-runner.md)); fails unless the evidence record for the zip's sha256 passes; a passing record is attested |
| `catalog-inputs` | here | acceptance passed | `.github/mac-release-pipeline.json` must name an app release (a dry run only notes it), before anything is public |
| `upload` | `mac-upload.yml` | acceptance `result == pass`, catalog inputs read | `publish` environment (main only); evidence and attestation re-checked; never overwrites; publishes the draft as a prerelease (never latest) on a real run |
| `catalog` | `mac-catalog.yml` | real run, all of the above succeeded | evidence re-checked for the payload's digest; every URL serves its pinned bytes; `catalog-release` (owner approval, main only) signs |

A dry run uploads to a `dryrun-` scratch release and deletes it, and signs no catalog. A catalog dry run needs files the app can download, so run `mac-catalog.yml` by hand for that.

## What passes between jobs

- `build` outputs `name` (also the image artifact's name), `payload` (the zip's file name) and `sha256`.
- `acceptance` uploads the artifact `acceptance-evidence`, holding `acceptance-evidence.json` ([format](mac-acceptance-evidence.md)), and outputs `result`, `evidence-artifact` and `evidence-run-id` (this run). It also keeps the harness's logs as `acceptance-harness-logs`. The pipeline's `runner` input (empty by default) overrides the VM job's runner.
- `upload` downloads the image and evidence artifacts from this run. After a real upload it outputs `payload` and `installer-data` (the catalog's inputs, built from the files it uploaded and verified) and `evidence` (the record it checked).
- `catalog-inputs` outputs the `engine` and `installer` blocks of `.github/mac-release-pipeline.json`.

## Secrets

The only secret is `CATALOG_SIGNING_KEY`, an environment secret of `catalog-release`. The pipeline passes it to `mac-catalog.yml` by name and never uses `secrets: inherit`. GitHub delivers an environment secret to a called workflow only when the caller passes it, and only to the job that runs in that environment. A throwaway probe (run 38553165283) confirmed this: passed by name or with inherit, the secret reached the job in the environment but not a job without it, and not passed, it reached neither. A second probe (run 38558712893) checked one more level of nesting, which is what happens once #69 moves signing into `mac-catalog-sign.yml`: when the pipeline passes the key by name and `mac-catalog.yml` forwards it, by name or with `inherit`, the key reaches the sign job. When the pipeline passes nothing, it stays empty. `mac-catalog.yml` can only forward what it was given, which here is the key alone. When ticket 13 puts an R2 token in `publish`, the pipeline's `upload` job must pass that token by name in the same way.

The catalog takes the evidence record the upload checked, and the upload took it from this run's acceptance artifact, with the attestation `mac-acceptance.yml`'s `attest` job made for it. The acceptance workflow uses no secrets.

## `.github/mac-release-pipeline.json`

- `engine`: the catalog's engine block ([format](catalog-release.md#inputs)). It is the engine `Packaging/build-app.sh` pins, published as the `engine-v0.9.2-omarchy.28` release. Ticket 13 moves it to `mac.omarchy.org/v1/engine/`. A test keeps this block in step with `build-app.sh` and `Engine/source-lock.json`.
- `installer`: the app compatibility block, `{"minimumVersion", "latestVersion", "downloadURL"}`. Until an app release from `mac-app-release.yml` is published, it is `null`, and on a real run `catalog-inputs` refuses with a message saying so, before the upload, so nothing is made public. Set it to that release's version and `.dmg` URL.
