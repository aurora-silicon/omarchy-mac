# Candidate source validation

Validation on x86_64 NixOS, 2026-10-14. Implementation commit: `f6c9b9395e3a8a327ede4c07471c7d500a2d3de9`, based on Aurora native installer `d9981171da408ad0451c768588fdc888646f95af`. A follow-up adds this record, a simulated-macOS package-origin test and source-test portability/documentation corrections; it does not change the runtime or packaging implementation.

| Check | Result |
| --- | --- |
| Focused radio candidate tests, Python3.14.7 + Unicorn2.1.4 | 23 passed after the follow-up, including actual private-stock parity, simulated macOS import refusal and emulator fail-closed cases. |
| Existing engine/source-lock tests | 41 passed; the original source lock and released inputs are unchanged. |
| Existing overlay suite | 307 run, 22 existing environment-dependent skips, no failures. |
| Existing script Python suite | 44 passed. |
| Image producer source suite | Passed: 25 candidate-set, 47 inspection, 26 image-check and 11 lab-access tests, plus shell fixtures. |
| Full `macOS/test/all` | Python/syntax and preceding packaging fixtures pass, then the unchanged preview identity check fails: `the app signing identity belongs to the configured team`. The unsigned Aurora preview has no configured Developer ID identity. |
| Real macOS-arm64 Unicorn wheel | Downloaded bytes independently match the pinned size/SHA-256; safe 40-file inventory and restricted-loader Python syntax verified. Native dylib was not executed on Linux. |
| Private original inputs | Ported child process generated 10,241 bytes with SHA-256 `926b390f709a4125a53ecbc12d5b94eba765f142e099b9a711b43dda23f7aea0`, matching the previously qualified output. No private input/output blobs are part of the commit. |

The portable commands are in README.md. On this NixOS host, the inherited suites also needed GnuPG/libarchive/jq on PATH, `LC_ALL=C`, and an unprivileged Bubblewrap view supplying `/bin/bash` and `/usr/bin/perl` plus private writable `/tmp`; neither source checks nor host installation files were changed to accommodate those assumptions. Initial runs exposed the missing tools/absolute paths and locale-dependent formatting; the image suite subsequently passed, and the installer aggregate reached the documented identity failure above.

Synthetic candidate-archive tests verify real collector patch application and preservation of base payload bytes, native-loader failure without host fallback, candidate version and per-file receipts. A real `.39`-based candidate archive, macOS bundled/signed-runtime JIT execution, Swift application packaging and fresh hardware installation have not been qualified. Access to the exact pinned `.39` artifact is needed for that next step. This PR is a source candidate, not a release promotion or a Neo deployment.

## Local .40 preparation, 2026-10-15

The default candidate now binds frozen .40 archive SHA `f7c37dea75abad81f825a7d4a623f52f0d4d30495fef5d00ee43e0187779059e` and distinct `.2` version. The original .39 → .1 builder remains in immutable a703/public PR4 history; this changed builder does not reproduce or relabel it. Synthetic source suite:25 tests run,19 pass; five native emulator tests and one private stock-parity test are skipped. No Apple input, native stock conversion, candidate archive, signing or hardware test was performed. The incomplete .40 acquisition recipe deliberately fails J700 preflight pending its missing executable/two-table pins and public decoder qualification.
