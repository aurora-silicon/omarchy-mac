# Locally derived Neo radio-policy candidate

This source candidate supplies the MT7932 `policy/world-XZ.bin` missing from the native installer's radio collector. This candidate derives the policy from authenticated, staged Apple 25G83 executable and regulatory tables before disk work. This Mac supplies its own factory calibration and Bluetooth address. No Apple executable, regulatory blob, firmware or per-device calibration is included here or in the candidate engine archive.

The original `.39` port came from Aurora's `feat/native-installer` at `d9981171da408ad0451c768588fdc888646f95af`. This preparation applies to the public `.40` engine and its frozen source lock. The candidate builder preserves the selected base's native runtime and bootloader. App inspection pins, catalog trust root and signing identity are retained. **Building this candidate does not activate it in the current app.** Its distinct engine archive needs an explicitly selected developer catalog/package and native qualification before installation.

## Conversion contract

- Preflight requires the stock executable and all seven `IZUBA_*.dat` inputs in an authenticated staged 25G83 system root. The current embedded range recipe lacks the executable and two required tables, so this preparation stops before disk mutation until that acquisition route is completed and qualified. Exact SHA-256 identities admit only the qualified inputs. The original `.39` → `.1` implementation remains in immutable source history; this builder produces a distinct `.2` candidate.
- In a bounded child process, run the original x86_64 data serializers with Unicorn2.1.4. This uses neither Rosetta nor native execution of the Apple driver. Host services are limited to memory/string operations and capture of command buffers; unknown services, syscalls, memory faults and instruction/time exhaustion fail.
- Select the stock `00` → `XZ` fallback with 6-GHz channel capability disabled. Preserve the two original mode commands and thirteen 2.4/5-GHz power tables. No country relabelling, fabricated limits or global regulatory-domain change is performed. This supplies neither a US policy nor general country/6-GHz support.
- Validate the complete 10,241-byte J7RP result against the independently qualified SHA-256 `926b390f709a4125a53ecbc12d5b94eba765f142e099b9a711b43dda23f7aea0`. This strict result identity also detects serializer/environment differences. The digest is not a distributed policy blob.
- Run conversion in `AsahiStage1Adapter.preflight` before resize, replacement removal or partition creation. Reuse the validated bytes during the subsequent firmware collection; the policy becomes part of the existing per-install tar/CPIO/Recovery baseline along with the original radio inputs.
- The collector still reads this unit's OCA2/WCAL/BCAL and Bluetooth address. The policy depends on the qualified stock driver/tables, not another unit's calibration. Missing policy is a collection failure, not a reason to copy an unrelated image policy.

The converter is adapted, with MIT attribution, from `niteria/nixos-neo` revision `d56e34f78d534fdb24ff714bf9a23c2f7f2a72ac`, `radio/radio_policy_reference.py` and `radio/radio_policy.py`. That pipeline validated the exact output with Aurora Linux's unchanged J7RP parser at `3bb0a6104a11c1e6a2836af07759db0986ac5f85` and used it successfully on a Neo. Prior evidence qualifies those policy bytes; it does not qualify this newly assembled macOS engine or a new end-to-end installation.

## Build the unsigned candidate

On a build host with Python3.12+ and Git, supply these already downloaded local inputs:

| Input | Bytes | SHA-256 |
| --- | ---: | --- |
| `installer-v0.9.2-omarchy.40.tar.gz` | 23,858,473 | `f7c37dea75abad81f825a7d4a623f52f0d4d30495fef5d00ee43e0187779059e` |
| `unicorn-2.1.4-cp37-abi3-macosx_11_0_arm64.whl` | 12,142,730 | `d6c93e0f60328d8f4a1792af3f834137a28050fcc2305f2ec01efe8558a9844e` |

The exact PyPI wheel URL is recorded in `build_candidate.py`. It is an arm64 wheel, not universal2. The builder has no downloader, dependency resolver or source-build fallback.

```sh
python3 Engine/radio-policy/build_candidate.py \
  /path/to/installer-v0.9.2-omarchy.40.tar.gz \
  /path/to/unicorn-2.1.4-cp37-abi3-macosx_11_0_arm64.whl \
  /new/path/installer-v0.9.2-aurora.radio-policy.2.tar.gz
```

This builder accepts only the frozen .40 base and writes the distinct `.2` version. Original .39 → .1 source remains recoverable at immutable a703/public PR4; its archive and catalog are untouched. The builder checks both input identities, verifies the two original collectors against the released source lock, applies `collector.patch`, and inserts the new modules and pinned wheel package at the engine root. It retains the wheel's distribution/license metadata. It narrows Unicorn's native loader to the bundled dylib: missing/unloadable bundled code fails instead of searching `LIBUNICORN_PATH` or host libraries. Existing runtime/bootloader members are retained. `radio-policy-candidate.json` records the base, wheel, patch, builder and added/replaced file hashes; `version.tag` identifies this candidate distinctly.

The output is **unsigned**. Existing native signing tools discover Mach-O files, but this additional dylib and its JIT must be verified under the actual bundled/signed macOS interpreter. A candidate catalog must require installer2.1.0 or later, as the supported bases do; the historical catalog generator's Omarchy-only version pattern does not infer that minimum from this Aurora candidate name. Do not replace either pinned base archive under its old filename/hash.

## Matching Linux image

The firmware-ordering helper requires world-XZ but no longer requires a US policy. The mkinitcpio hook preserves legacy image policies if present and also permits policy-free image construction; the installer-generated policy arrives through ESP vendor extraction before the peripheral helper runs. Missing world-XZ still stops probe. A policy-free image therefore needs this candidate engine; the old `.39` collector does not produce it. `image-builder/one-image/build6-m123-neo.sh` remains the historical preprovided-policy prototype and is not a new candidate image recipe.

## Verification

```sh
PYTHONPATH=Engine/overlay/src python3 -B -m unittest discover \
  -s Engine/radio-policy/tests -p 'test_*.py' -v
bash test/all
```

Portable tests cover collector/default-adapter integration, preflight failure before disk work, cached-policy reuse, output identity, malformed commands, input bounds/revisions, worker failure/timeouts, archive assembly, native-loader refusal, wheel tampering/unsafe paths, and firmware ordering with world-only, absent and legacy policies. Optional Unicorn tests exercise the emulator's unknown-service/syscall/memory/budget failures. Tests use synthetic public fixtures.

For a private Linux parity check, install Unicorn2.1.4 in the test environment and set `MT7932_STOCK_ROOT` to a local directory laid out like the source Mac's filesystem. Never add that directory or its outputs to Git. The private test re-runs the child process and checks the qualified policy digest, size and mode commands. On macOS the converter deliberately requires the candidate's sibling bundled Unicorn package; a host virtual environment is insufficient. Native macOS loading/JIT, signed-app execution, fresh installation and first-boot peripheral operation remain separate qualification steps. The pinned `.39` archive is not published in the upstream repository's releases at the time of this work; real candidate assembly requires access to that exact artifact.

## .40 acquisition frontier (not release qualified)

The frozen .40 acquisition recipe currently lacks three mandatory policy inputs: `com.apple.AppleSunriseWLAN` at the dext root, `IZUBA_TxPwrLimit6G_MT79x1.dat`, and `IZUBA_TxPwrLimit_AntGain.dat`. The executable needs a separate dext-root mapping because the existing `sunrise` prefix maps into `IZUBA`. Their exact identities remain in `mt7932_policy.py`. Until an independently reviewed complete authenticated recipe is supplied, J700 preflight fails before any disk work; this source preparation does not qualify macOS27 radio conversion.

The .40 patch collects and checks the entire immutable-byte radio snapshot (including this Mac's factory data) before metadata/disk setup. It passes a frozen tuple of sorted `(name, bytes)` pairs to the stub collector, which performs no second acquisition, converter run or calibration read after disk mutation. Missing policy or any radio output is fatal. Existing sandbox, fixed input/output identities and the engine-only Unicorn loader remain unchanged. A new source lock/archive/catalog must record the new actual source and artifact identities; no digest weakening or .39/.40 base substitution.

The .40 collector diff is zero-context, applied with explicit `git apply --unidiff-zero --check` then application; exact frozen collector hashes remain required before patching. This avoids treating unified-diff blank context prefixes as source whitespace errors.
