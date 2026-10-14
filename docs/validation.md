# Standalone installer validation

## Candidate boundary

The standalone extraction validated at `3f1e30bb265e77da04ce03533be0a7dddaa8c84c` extracted source and adjusted repository-relative paths without altering the Swift runtime, Python engine overlay, source lock, release trust configuration or Linux payload. The local evidence below applies to that extraction revision. The provenance record identifies the original source; record `git rev-parse HEAD` whenever testing a candidate.

The subsequent CI integration adds a behavior-preserving Swift 6.2 compatibility change in `Sources/OmarchyAppleInstallerApp/InstallerComponents.swift`: both disk-bar drag callbacks explicitly convert the `CGFloat` ratio to `Double` before calculating the Omarchy fraction, resolving a compiler ambiguity. It also skips the live physical-Mac inspection test on `VirtualMac` hosts, as described below. These changes passed [CI run 35539039492](https://github.com/omacom/omarchy-mac-installer/actions/runs/35539039492) at merge revision `f2235e4ed823b31efd2c53306d7f9435ac1fd250`, separately from the earlier extraction validation.

The Linux source checks are `bash test/all`. They compile Python, check shell syntax, run the engine and catalog unit tests, and exercise the preclean, package-plist, branding and publication scripts with fixtures. They do not qualify a macOS app bundle, engine binary or physical installation.

## Continuous integration

[Installer checks](../.github/workflows/checks.yml) runs for every pull request to `main`, every push to `main` and manual dispatch. There are no path filters, so documentation changes also receive the checks expected by branch protection. New commits cancel superseded runs for the same pull request. Pushes to `main` and manual runs have unique concurrency groups, preserving each run and its evidence even when several are queued.

- **Portable checks** runs `bash test/all` on Ubuntu 24.04 with Python 3.12, including shell syntax, Python compilation, engine/catalog tests and packaging/publication fixtures.
- **macOS checks** runs strict Swift formatting and debug/release Swift tests on an Apple Silicon macOS 15 runner using Xcode 26.2 and the same checksum-pinned XcodeBuildMCP 2.7.0 used for the initial Mac validation.

The read-only live physical-Mac inspection test explicitly skips `VirtualMac` hosts. Hosted CI cannot assert a physical Mac model or internal disk; the fixture-based inspection and blocked-model tests still run in both configurations, and the live check remains enabled on real Macs.

Both jobs record the checked-out commit and tool versions and retain logs as Actions artifacts for 14 days, including failures. Pull requests test GitHub's proposed merge revision. GitHub Actions are pinned to commit hashes; tool updates should change the pin and its version comment together. Explicit Bash execution enables `errexit` and `pipefail`, so collecting logs through `tee` does not hide test failures.

These checks use hosted runners, read-only repository access and no release secrets. The release secrets live only in the `macos-release` environment, which only the app release workflow's sign job uses after a second maintainer approves (see `Packaging/README.md`, Release workflow). It performs source checks and fixture tests; app assembly with an authenticated engine, production signing, visual review and physical installation remain separate validation steps. Require both named checks along with the existing independent review before merging to `main`.

## Local evidence

The extraction was checked on 2026-09-20 as the non-root `scott` user on aarch64 Linux with Python 3.14.7. The portable suite passed: 37 engine tooling tests, 104 engine overlay tests and 17 catalog tests (158 Python tests), plus all existing preclean and three extracted packaging/publication shell tests. Python compilation and shell syntax checks passed.

The same source revision, `3f1e30bb265e77da04ce03533be0a7dddaa8c84c`, was then validated on Scott's M4 Pro (`Mac16,7`, arm64), running macOS 26.6.2 (25G83), Xcode 27.0 (27A266a) and Swift 6.4. XcodeBuildMCP 2.7.0 was staged inside the validation workspace from its official standalone archive, verified against the publisher's SHA-256 `bd724a2c0e6ffe027b3f46257e66d626149a64cd045f4867124bd683b3cf081a`.

| Check | Result |
| --- | --- |
| Strict Swift formatting | Passed |
| Debug Swift tests | 402 passed, 0 failed, 0 skipped |
| Release Swift tests | 396 passed, 0 failed, 0 skipped |
| Recorded journal fixture and blocked-host tests | Passed within both Swift suites |
| Development app assembly | Passed with the exact pinned inspection engine |
| Ad-hoc app and helper signatures | Deep/strict verification and reciprocal code requirements passed |
| Bundle structure | Executables, helper plist, release inputs and engine verified |
| Debug simulation launch | Scott confirmed the simulation window is visible |
| Successful installation → Recovery simulation | Scott completed the flow and shutdown confirmation; the app displayed “Simulation complete: shutdown would begin now. Your Mac stays on.” |

The app was assembled with a separate development copy of the release descriptor using an ad-hoc helper requirement. The tracked production descriptor, public key and source code were unchanged. No production signing credentials, helper registration or installation operation were used.

Swift 6.4 emits three capture warnings in inherited code: `PayloadPrefetch.swift:94`, `PayloadPrefetch.swift:523` and `InstallerSession.swift:635`. They concern inner weak captures inside an implicitly strong outer capture. They did not fail builds or tests, and the extraction does not change that runtime behavior.

The Python/shell suite was not repeated on macOS: its installed Python 3.9.6 and Bash 3.2 are below this runner's declared prerequisites. Its complete Linux result remains separately recorded. The successful-install visual path is confirmed. The remaining visual failure/recovery scenarios, complete native engine rebuild and physical installation qualification are still pending. Exact logs, app file hashes, isolated-copy results and transfer artifacts are retained alongside the local checkout in the extraction workspace's `evidence/` and `artifacts/` directories. These extraction results do not qualify subsequent implementation changes.

## macOS build handoff

Scott has an M3 Air and an M4 Pro available with macOS. Either can be the primary build machine. Build once against the recorded revision and use the second machine for a separate UI or host-support check when useful; do not run duplicate qualification jobs for the same inputs.

1. Copy or clone the standalone repository and check out the candidate revision. Record `git rev-parse HEAD`, `sw_vers`, `uname -m`, `xcodebuild -version` and `xcrun swift --version` with the results. The package requires macOS 15+ and Swift 6.2+; use an Xcode toolchain meeting those requirements and XcodeBuildMCP.
2. Run the portable suite with Bash 5 and its listed dependencies.
3. Lint with Xcode's bundled formatter, then run both Swift configurations:

```bash
xcrun swift-format lint --strict --recursive Package.swift Sources Tests
xcodebuildmcp swift-package test --package-path "$PWD" --configuration debug
xcodebuildmcp swift-package test --package-path "$PWD" --configuration release
```

4. If those pass, use the existing `Development/Run Simulation.command` launcher for a debug-only UI review. Keep one app instance on the review machine. Follow [the simulation scenario matrix](../Development/Simulation.md), including unsupported hosts, failed downloads, changed plans, interrupted execution and Recovery handoff. Simulation uses dummy credentials; it is not a live install or an inspection of that Mac's actual eligibility.
5. Record failures and the exact test counts/logs. Verify the imported journal fixture is exercised and unsupported models remain rejected. Mac hardware support needs a separate real host inspection against the intended engine and signed catalog; simulation does not establish it.

These steps require no helper registration, real machine-owner credentials, production signing, disk changes or release publication. If a run asks to cross one of those boundaries, stop and review that as a separate operation.

## Before packaging or installation

For another app assembly, supply the exact authenticated inspection engine described in [extraction.md](extraction.md#inherited-prerequisites-and-open-issues) and review the resulting app structure and code-signing requirements. The initial ad-hoc assembly passed; a complete native engine rebuild remains a separate unvalidated path. The current publisher's catalog, public key and signing identity are not interchangeable with a new Omacom release identity.

An M3 Air may be a physical validation candidate only after its exact model, engine support and intended payload are checked. The M4 Pro is available for macOS development; `apple,j614s` remains explicitly blocked. No hardware restriction is relaxed by this extraction.

Physical installation needs its own backup, recovery, image/package revision and authorization record. Later release qualification must cover installation, Recovery boot, first boot, update, encrypted-install behavior and recovery on the assembled shared stack. Passing this source suite does not satisfy those checks.
