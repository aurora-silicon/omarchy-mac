# Installer simulation and audit fixes

The debug simulator exercises the same OnePageInstallerView and InstallerSession as the installer, through an in-memory environment. It does not inspect this Mac, fetch releases, invoke the helper, partition storage, change release preferences, or request macOS shutdown. It never asks for real credentials. Normal compilation caches, app window state, and the app instance lock still use local files.

## Launch

Double-click **Run Simulation.command** in this folder, or run:

```bash
./Development/"Run Simulation.command"
```

Requires Xcode and XcodeBuildMCP. The launcher builds the debug app and supplies `--simulate`. Quit the current review app before relaunching; the single-instance lease rejects duplicates. Release builds refuse `--simulate`, and exclude the simulation environment and dashboard.

## Controls

All simulation controls live in the **Simulation** menu bar item. They are absent from the release app and when simulation is not enabled. The installer content fills the resizable window; there is no simulation dashboard above it.

- **Scenario** selects one of 27 outcomes and resets the simulated session. `--simulate-scenario=NAME` (the scenario's raw name, for example `noMacRelease`) opens on that scenario, and `--simulate-continue` presses Continue once, so a screen can be captured without driving the window.
- **Reset simulation** abandons only the in-memory run, including a stopped or uncertain outcome.
- **Slow events** makes each event take two seconds; changing speed resets the session.
- **Test channel** offers Stable, Release candidate and Edge (the default), and is local to the simulator. The line under it shows the Release channel menu as the app words it for this scenario: stable and rc have no Mac release, and the three channel scenarios change the test channel's state. It locks while preparing, authorizing, executing, and after execution has started.
- **Dark appearance** is on by default to match Omarchy. Turn it off to test light mode.
- **Install / Authorize** on the simulation sheet uses a dummy credential. There are no real account fields.

## Scenario matrix

| Group | Scenarios | Expected behavior |
| --- | --- | --- |
| Normal path | Successful install and Recovery; installed-system verification handoff; installation media handoff | Review the plan, authorize with dummy credentials, inspect progress and handoff |
| Eligibility | Unsupported Mac; engine unavailable; existing installation | Stop before preparation; the unsupported Mac is named (MacBook Pro 14-inch M4 Pro, `Mac16,8`, `apple,j614s`) with the M1, M2 and M3 families of a simulated 34-model catalog |
| Preparation | Download interrupted; verification failed; out-of-date installer; no eligible space | Explain the error and permit a fresh check; simulation download links do not open |
| Channel states | Channel has no Mac release yet; channel doesn't include this Mac; channel release list missing (404) | Three distinct menu labels (No Mac release yet, Not available for this Mac, Couldn't load) and three distinct cards: nothing to install on this channel, this Mac not in the release, a server problem |
| Disk review | Large free extent; disk limit changes during replan | Preserve macOS capacity for free space; returned allocation always wins; reset acknowledgement |
| Authorization | Missing helper; plan changes before approval; first credentials rejected | Respect the gate; permit back-navigation before submission; rejected dummy credentials can be retried |
| Execution | Connection lost; empty reply; helper failure; interrupted live progress | Retain verified activity; uncertain outcomes cannot start another installation |
| Engine refusal | Space shrinks before install | The engine refuses the approved 137 GB plan before any disk step; the page says no disk changes were made and offers **Check available space**, which returns to review with 133 GB, a size-change notice and a cleared acknowledgement; the next install succeeds |
| Prepared resume | Prepared resume target changed | Explain earlier disk preparation, retain the saved checkpoint in Last verified activity, preserve the journal, and require reconciliation without offering a fresh install or blind retry |
| Recovery | Recovery fails then retry succeeds; manual recovery required; shutdown request fails | Retry only the eligible Recovery path; keep instructions visible when shutdown fails |

Click the size field to edit GB. Use the green checkmark or Return to apply; use the red cross or Escape to cancel. Invalid or out-of-range values cannot be applied. Installation is disabled until you apply or cancel.

For disk clamping, tick the acknowledgement and choose a larger size. The engine returns the original 137 GB allocation with a smaller upper bound. The displayed size must return to 137 GB and the tick must clear. In the free-space scenario, choose 600 GB: macOS remains 100 GB and unallocated capacity becomes 200 GB.

For cancellation, open the authorization sheet, cancel, then choose **Back to disk size**. Approval must be discarded and the acknowledgement must be empty. After submission, reset/back/channel changes in the installer remain unavailable; the simulator's separate reset can still start a new dry test.

For ambiguous outcomes, expand **Last verified activity**. Lack of a checkpoint is not proof that no writes occurred. The live app deliberately does not automatically resume or resubmit an uncertain installation. An owner must reconcile the trusted run journal before another installation; this change does not implement a new privileged journal-reattachment protocol.

## Audit changes

1. Session guards prevent inspection, replanning, or repeated submission from overlapping execution. Operation identities reject delayed callbacks. A synchronous journal buffer preserves checkpoints received immediately before the completion reply.
2. Disk controls use the engine candidate's actual bounds. Every replan resets tentative UI state and acknowledgement, even when allocation is unchanged. Free extents keep total capacity and macOS capacity stable and show remaining unallocated space.
3. Ambiguous helper outcomes no longer claim that nothing changed. Verified activity stays visible and resubmission stays locked.
4. Cancelling authorization permits returning to disk review and discards approval.
5. Progress shows step count, actual phase, elapsed time, and expandable verified activity. Byte-based download progress remains measurable.
6. Shutdown dispatch success or failure stays visible; the app does not quit before macOS decides whether shutdown can proceed. Recovery steps can be copied for another device.
7. Disk resizing has a text field with green Apply and red Cancel controls, plus an assistive adjustment action. Keyboard focus is retained. Long content scrolls, and technical errors expand on demand.
8. Plan review names the release/channel and target. The credential sheet explains the macOS account and authorization purpose. Wording consistently uses macOS, SSD, and Shut down.

## Verification

Run from the package directory:

```bash
xcodebuildmcp swift-package test --package-path "$PWD" --configuration debug
xcodebuildmcp swift-package test --package-path "$PWD" --configuration release
```

The simulation matrix runs in debug; production session and trust tests run in both configurations. Tests cover blocked hosts, preparation failures, all simulated terminal outcomes, same-size clamping, free-space capacity, credential retry, shutdown failure, overlapping operations, late callbacks, and retained checkpoints with zero-delay completion.

Simulation proves presentation and session behavior. It does not prove hardware compatibility, successful physical installation, Recovery boot, payload validity, notarization, or production deployment. No physical M1 connection is required.

## Removal

Choose **Installation → Remove Omarchy…** to dry-test removal independently of
installation. The **Simulation → Removal Scenario** menu selects the removal outcome. Type
`delete omarchy installation and data` exactly to enable removal. No real password
is requested in simulation. See [Removal.md](Removal.md) for the supported disk
layout, recovery behavior and test coverage.

The **Disk alignment · whole GB unchanged** scenario reproduces normal 1 MiB
partition alignment. Selecting 180 GB must keep 180 GB displayed without a
capacity-limit warning. The acknowledgement still resets. Actual whole-GB changes
use “Space for Omarchy changed from … to …” without assuming why it changed.

## Recovery account preview

**Simulation → Preview Recovery Account…** opens the proposed final account step directly. The successful simulated installation also ends at this form. It asks for a new short username, password and confirmation; validation follows the documented native account creator's username format and requires a nonempty, matching password. The GUI imposes no additional minimum length; live creation must report native password-policy errors. Continuing clears both password fields and shows the Startup Disk authorization instructions. **Open Startup Disk** displays a simulation notice; it does not open Settings or reboot. **Reset Simulation** returns to the ordinary installer start.

This is a presentation prototype. It does not create an account or grant ownership, and the live installer keeps its existing Recovery handoff. Production integration requires the resumable target-account creation and Preboot finalization described in Aurora's `work/sep-stub-account-20261011/README.md`; the original script is not a complete resume/finalization backend.
