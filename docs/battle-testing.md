# Installer battle testing

This source review starts from `7a61e0a604ae812ddf9c1ff0f322ad301f6da7fb`. It exercises failures with disposable files, synthetic disks, mocked helpers and the debug simulation state machine. It is not physical installation qualification, and no finite test suite covers every possible machine, disk or interruption.

## Changes and regression coverage

| Failure | Prevention | Regression coverage |
| --- | --- | --- |
| A resumed run's engine reports that its prepared APFS target no longer matches the saved checkpoint | Name the diagnostic, preserve the journal, explain the earlier disk preparation, and offer neither a blind retry nor a fresh install | Diagnostic classification and failure-card tests; simulation retains the preparation checkpoint without enabling a fresh install |
| A network observer ends before the download | Distinguish observer completion from work completion | Finished stream plus delayed failing work cannot publish verified |
| Two releases reuse a payload digest but stage it at different paths | Bind in-flight reuse to the artifact and canonical destination | Both release directories receive their own verified file; unchanged replans still reuse the existing download |
| Cancellation arrives during local assembly or hashing | Check cancellation between chunks and before promotion; prevent superseded generations from promoting | Deterministic cancellation at assembly leaves no final payload and retains verified parts for retry |
| Local preparation or helper ping fails before submission and locks the UI permanently | Explicit app-side pre-submission error; revoke approval and allow fresh inspection | Proven pre-submission failure unlocks initial installation; Recovery retry preserves its checkpoint; ordinary connection loss remains locked |
| Quit/Close interrupts the app while its helper continues | Guard app termination only from entry to the helper execution stage; keep payload waiting cancellable | Session guard stays clear during payload wait, turns on before execution, and clears at terminal outcomes; quit invalidates a pending submission even if its payload wait later succeeds; Recovery retry retains its checkpoint |

The UI also displays the planned release and target, provides **Copy setup steps**, and exposes progress through native accessibility semantics while respecting Reduce Motion. These are source changes; passing Swift tests does not replace a visual or VoiceOver review.

The engine-side fixes first developed here (resume target reconciliation, the resize geometry check, repair member and size validation, atomic engine build promotion and the real canary repair manifest) change inputs pinned in `Engine/source-lock.json`. They moved to the `codex/engine-hardening` branch, documented in its `docs/engine-hardening.md`, so they ship with a reviewed lock refresh and rebuilt engine artifact. This branch leaves `Engine/` identical to `main`; the app recognizes the prepared-resume diagnostic ahead of the engine that emits it.

## Review regression boundaries

The session now asks the environment to confirm payload verification before every execution; the live environment immediately returns for a verified payload. Ordinary initial installation already requires a verified payload in `canStartInstallation`, so the delayed/failing-wait regression is defensive coverage, not proof of a currently reachable multi-gigabyte wait from that screen. During the wait, Quit and window close remain available. A failed wait is pre-submission; a late successful wait after quit cannot submit. The helper execution stage retains the close/quit guard through terminal handling.

Helper ping failures keep their specific package-reinstallation advice, including during Recovery retry, while preserving the pre-submission classification. The coordinator regression injects a failed ping before any execution request; a separate process regression verifies execution failures stay unwrapped. Failure-card tests cover the same wrapped helper errors and checkpoint-preserving Recovery advice.

The prepared-resume mismatch is recoverable through explicit reconciliation of the saved journal and expected disk state. It does not offer a blind retry, a fresh install, or discard the journal: the earlier preparation may already have changed the disk. The failure explains that prior preparation remains, reports that this resume started no further step, and directs the owner to retained checkpoints to determine whether file installation also completed. The `preparedResumeMismatch` debug scenario exercises that card and retained activity without touching a disk.

## Verification boundaries

Run `bash test/all` with Bash 5+, Python 3.12+ and the documented tools. Run strict Swift formatting and both Swift configurations through XcodeBuildMCP as described in `validation.md`. The debug suite iterates every defined installation simulation scenario; these remain synthetic environments.

The source lock, engine sources, trust roots, release descriptor and blocked-model rules are unchanged from `main`, so `Engine/source-lock.json` still describes the authenticated `.28` archive. In particular `apple,j614s` remains blocked.

## Remaining practical work

1. **Read-only subprocess hangs (high priority).** `MacHostInspection.swift` drains stdout before stderr although it discards stderr; enough stderr can fill the pipe and deadlock the child. Discard that unused stream or drain it concurrently. Add bounded timeouts and output caps to read-only disk/engine inspection with fixture children that flood stderr or never exit. Do not apply a generic kill timeout to an active disk write or APFS mutation.
2. **Restart-safe download recovery (medium priority).** Prefetch work directories are tracked only in memory and named with random UUIDs. After a crash, a new process cannot reclaim or reuse their multi-gigabyte parts. Design a narrowly scoped owner lease/manifest; reverify parts before reuse and reclaim only demonstrably abandoned directories. Test low-space relaunch and a concurrently live unrelated owner. Do not recursively clear the shared staging folder.
3. **Immediate unsupported-host feedback (medium priority).** `LiveInstallerEnvironment.inspect` waits for a catalog to enrich a model it already knows is unsupported; network timeout can delay the refusal. Show the refusal immediately and enrich the optional model list asynchronously or from an already validated catalog. Preserve the blocked-device gate.
4. **Prefetch simulation coverage (medium priority).** The simulation environment still uses preparation-stage download scenarios and does not model the live plan-screen prefetch lifecycle. Add waiting-for-network, pause/resume, verification, failure/retry and release-change cases through the same session interface.

## Native UI and physical scenario checklist

- During a pending payload wait, Command-Q, Command-W and the close button must remain available and cancel prefetch. During helper credential verification, active installation and Recovery retry execution, try Command-Q, Command-W and the close button. They must preserve the running session. Repeat after rejected credentials, completion and failure; normal exit and requested shutdown must be allowed.
- Review the release/target details, minimum-size and narrow-window layouts, keyboard size editing, light/dark mode, VoiceOver progress and toggling Reduce Motion while progress is visible.
- Copy Recovery steps before shutdown; retain warnings and step details. Simulate rejected shutdown and confirm instructions stay visible.
- Exercise all installation and removal simulation outcomes, including unknown helper results, changed allocation, rejected credentials, offline channels and partial removal. A missing checkpoint must never be presented as proof of no writes.
- On separately authorized, backed-up supported hardware: cold/warm downloads, dropped Wi-Fi, disk pressure, snapshots/FileVault, APFS resize refusal, interruption at each mutation boundary, Recovery retry, first boot, encryption choice and removal. Preserve recovery paths and record the exact catalog, payload, engine and app identities.
- Measure download, app/helper import, resize, decompression/write, synchronization, readback and Recovery separately. Keep streaming hashes, authenticated admission and sequential disk mutation. Do not promise a faster physical install without measurements.
