# PR 29 review response validation

Validated source candidate: `ebe76e695f4a1c68f30b25d152f8394027b792a0`, on `codex/battle-test-installer`, based on PR head `51ad0d83513d39a499c9c167c856189248584f50`. This record is a subsequent documentation-only commit. The source candidate and all results below were produced locally on 2026-09-29/30 (Asia/Kolkata). No commits were pushed and no review threads were resolved.

After `main` began checking every locked engine input against `Engine/source-lock.json`, the engine overlay changes and their Python tests were moved from this PR to the `codex/engine-hardening` branch, to ship with a rebuilt engine. The Python counts below include those tests; the Swift results are unaffected.

The specification was Marcelo's review submitted 2026-09-29 at 01:47:55 UTC and Scott's review submitted at 03:37:55 UTC, including Scott's inline comments, on [PR 29](https://github.com/omacom/omarchy-mac-installer/pull/29). GitHub still reported the same reviews and head after local validation.

## Implemented changes

- Payload preparation and helper execution have separate quit/close state. A failed payload wait remains a pre-submission failure. Cancellation prevents a late successful wait from submitting a request.
- Wrapped helper connection/ping failures preserve the package-reinstallation remedy, including Recovery retry's existing checkpoint. Execution failures remain unwrapped.
- Prepared-resume target mismatches have a named diagnostic, preserve the journal, explain prior disk preparation, and offer no blind retry or fresh installation over uncertain disk state.
- An exact real-canary repair manifest exercises candidate discovery. Its provenance, size/alignment contract, and evidence boundary moved with the engine changes to `docs/engine-hardening.md` on `codex/engine-hardening`.
- The source-lock refresh and authenticated engine rebuild remain an explicit, separately reviewed release follow-up. The old archive does not contain these engine changes.

## Automated validation

Host: arm64 macOS 27.0 (`26A428`), Xcode 27.0 (`27A266a`), Swift 6.4, Python 3.14.7, Bash 5.3.15. XcodeBuildMCP 2.7.0 was downloaded from its official release and its archive matched the repository's pinned SHA-256 `bd724a2c0e6ffe027b3f46257e66d626149a64cd045f4867124bd683b3cf081a`.

| Check | Result |
| --- | --- |
| Focused Swift regression closure | 114 passed, zero failures or skips |
| Focused Python checks | 21 Asahi adapter, 12 repair, and 13 stage-one tests passed |
| `bash test/all` with Bash 5 | 174 Python tests passed: 38 engine tooling, 112 overlay, 24 scripts; shell and packaging fixtures passed |
| Strict Swift formatting | Passed for Package.swift, Sources, Plugins, and Tests |
| Full debug tests through XcodeBuildMCP | 577 XCTest passes and 4 Swift Testing passes; one XCTest skipped; zero failures |
| Full release tests through XcodeBuildMCP | 567 XCTest passes and 4 Swift Testing passes; one XCTest skipped; zero failures |
| Python compilation, shell syntax, Git whitespace | Passed |
| Working tree at source qualification | Clean |

Both configurations skipped `PrivateM3CatalogTests.testActualDraftThroughSealedCatalogTrustPath` because `OMARCHY_PRIVATE_CATALOG` was not supplied. Read-only live host inspection passed. Release compilation emitted three inherited weak-capture warnings at `PayloadPrefetch.swift:177,676` and `InstallerSession.swift:739`; the warning-bearing code was not changed by this response.

Focused regressions failed before their corresponding fixes for helper wording, prepared-target diagnostics, and the session verification/quit boundary. The real manifest test is a compatibility characterization, not a reproduced defect. Ordinary initial installation already requires a verified payload, so delayed payload-wait coverage is defensive; it does not prove that Scott's multi-gigabyte wait is reachable from the current normal install screen.

The standalone repository does not contain the parent Omarchy repository's `bin/omarchy` command router; those parent-repository checks are inapplicable. No image-builder source changed, and its separate full suite was not repeated.

## Native simulation

The exact debug executable from the qualified candidate ran with explicit `--simulate --simulate-scenario=preparedResumeMismatch --simulate-continue` flags in a disposable local review bundle. The simulation used its built-in dummy account and synthetic disk; no real credentials were entered.

The initial review bundle had incorrect executable metadata, causing UI attachment timeouts. Correcting that disposable bundle's metadata allowed native accessibility inspection and screenshots without changing repository source.

- During slow simulated helper execution, Command-Q and Command-W left the running session intact and the close control was unavailable.
- The terminal mismatch card displayed the explanation of prior preparation and journal-preservation guidance with no clipping or overlap in the inspected window.
- Expanding Last verified steps displayed Started preparing disk space and Disk space reserved for Omarchy, along with the copy-installation-record control. No fresh-install or Recovery retry button was offered.
- The close control returned after failure. Command-W terminated the simulation. The UI tool's subsequent state read automatically relaunched the disposable executable without its simulation arguments; it immediately rejected installation because the validation engine was absent. That exact process was stopped and the bundle's simulation-only launcher restored. No helper registration or disk operation occurred.

The pending payload wait is covered through the session's controllable test environment; the native simulation does not model that prefetch lifecycle. Native VoiceOver, all window sizes, and physical installation were not qualified by this review.

## Standards

Independent read-only review of `git diff origin/main...ebe76e6`, with `origin/main` at `9ce0c6f3eb7aabb6966fad1a97db336fc3a7e817`, found no blocking bugs, documented-standard violations, or actionable code-smell findings. Review covered execution and cancellation guards, pre-submission error boundaries, resumed-target reconciliation, repair size validation, and artifact promotion. Source locks, release trust configuration, and blocked-host restrictions remain unchanged.

## Spec

Independent read-only review found no blocking source defects or unrelated scope in the review-response commit. The failure diagnostics, quit/close boundary, helper-specific remedies, narrow wrapping regressions, and documented engine-lock follow-up match the requested behavior.

Marcelo requested checking the producer or a real shipped manifest. The checksum-verified fixture is a real manifest consumed by a physical non-release canary. It establishes compatibility with that artifact; it does not establish compatibility with current production output or verify an unavailable producer implementation. That limitation remains explicit rather than inferred away.

Review totals: Standards: zero findings. Spec: zero blocking source findings and one compatibility-evidence limitation. QA verdict: PASS for local source qualification.

## Release boundary

No physical installation, privileged helper registration, production signing, authenticated engine rebuild, publication, or deployment was performed. Before shipping the engine fixes, refresh and review the lock together with the rebuilt archive and artifact/catalog identity, validate the assembled package, and qualify interrupted stage-one and Recovery resume on authorized supported hardware. `apple,j614s` remains blocked.
