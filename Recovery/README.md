# Omarchy Step 2

The Omarchy-branded native Recovery interface lives alongside the main installer. It has two explicit build modes, targeting macOS 13 independently of the main installer's macOS 15 requirement.

## Preview

On macOS with Xcode and XcodeBuildMCP installed:

```sh
cd Recovery
./build-preview.sh
open "build/Omarchy Installer.app" --args --preview
```

Use `--recovery-preview` to preview repair. This build always defines `OMARCHY_STEP2_PREVIEW` and cannot enroll or modify startup software even when launched in Recovery. Keep only one review app instance open. Previewing does not implement the main installer's proposed new Recovery-account creation flow.

## Actual Recovery build

```sh
cd Recovery
./build-recovery.sh
```

This explicitly defines `OMARCHY_STEP2_RECOVERY`, emits `build-recovery/Omarchy Installer.app` and `build-recovery/omarchy-recovery-app.json`, and verifies the executable's `--build-mode`, ad-hoc signature and localized bundle name. The template has no target UUIDs, credentials or boot payloads. It cannot enroll by itself: the engine must populate validated configuration and the target's actual startup files.

Put the app and adjacent manifest in the OS ZIP under `esp/aurora/recovery/`. The OS template should declare `"recovery_gui": "omarchy-native-v1"`; this requires the app and verifies its entire content inventory before partitioning. Older payloads without this contract or app retain their existing shell Step 2. After creating the target and finalizing Stage 1 and `m1n1/boot.bin`, `omarchy_recovery.stage` copies the app to the stub System volume, generates `Contents/Resources/install-config.json`, bundles the exact finalized raw Stage 1, Stage 2 and this installation’s extracted device firmware with hashes, and re-signs/verifies the copy before changing `.IAPhysicalMedia` to launch it.

Configuration schema 2 includes `volumeName`, `systemUUID`, `groupUUID`, `prebootUUID`, `espUUID`, `bootMode`, `stage2Path` and `bootstrap`. Only raw mode and `m1n1/boot.bin` are currently accepted. Mach-O and nested virtualization controls remain disabled in the real build until backed by a qualified complete payload. Runtime target discovery uses the app's containing volume, verified against the configured APFS identity; it does not rely on `/Volumes/Omarchy` or a fixed disk number.

The legacy `Finish Installation.app/Contents/Resources/boot.bin` remains for upstream resume detection; its `step2.sh` becomes a relative launcher for `Omarchy Installer.app`. The new app remains on the stub after completion removes `.IAPhysicalMedia`, and the `aura` command opens its actual executable or invokes recovery actions. The localized `CFBundleDisplayName` must remain present: Recovery's Springboard requires it for this direct native launch contract.

Enrollment rechecks root, the configured target volume and paired power-button 1TR, then resolves a real target volume owner from APFS and target Preboot metadata. When no eligible target owner exists, the explicitly configured `source-volume-owner` bootstrap can use the original macOS owner. That path binds the original System volume and APFS group UUIDs, requires the volume still exists, and intersects copied target administrator metadata with both the specifically authorized source owner UUID recorded by Stage 1 and its current APFS VolumeOwner list. Ambiguous or unmatched owners are rejected. The recorded recovery account takes precedence once APFS reports it as a volume owner; a finalized account that loses ownership is rejected. Existing bputil/kmutil prompt handling stays in the native PTY backend. Normal macOS is rejected before writes. The app retains persistent attempt logs and bounded UI log rendering.

The bootstrap System UUID names the underlying System-role APFS volume, not the boot snapshot mounted at `/`. For older configurations that recorded a snapshot UUID, Recovery resolves the unique System volume in the recorded source group and verifies that the recorded snapshot belongs to it before querying ownership. Snapshot enumeration can require mounting that source volume read-only. A missing snapshot, changed group, ambiguous System volume, or unregistered owner remains an error.

## Validation and limits

The strict configuration fixture, original enrollment/owner/boot-selection fixtures, native prompt fixture, Python staging/checksum/target-identity fixtures and source formatting are tested. Both real and preview builds compile and pass signing and localized-name checks. The normal-macOS CLI rejection is tested. These are build and fixture results, not a completed fresh-install or Recovery boot qualification.

The main installer ends with shutdown instructions. Its authenticated helper verifies the completed installation and updates that target’s Recovery app before requesting shutdown. It does not create an account in macOS.

Step 2 enrolls startup software using the explicitly bound existing macOS owner, then asks for a new recovery username, password and confirmation. Account creation uses the existing native implementation: immutable target identity checks, empty-database/APFS-user guards, native password verification and a resumable, password-free receipt. The account form is the penultimate screen; successful creation leads to the final Startup Disk handoff. If interrupted after enrollment but before account creation finishes, reopening Step 2 resumes the form. Older repair receipts do not force a new account.

The final Restart button opens Apple’s Recovery Startup Disk application. The user selects the new OS and completes Apple’s authorization prompt there. Once APFS reports the recorded account as a volume owner, subsequent enrollment uses that account and can complete its existing metadata finalization. The full new ordering and subsequent paired-Recovery login still require a fresh hardware test; creating an ordinary account is not proof of native ownership or a working Recovery login.

Account preparation now invokes the existing conditional finalizer before the Startup Disk handoff. A matching APFS credential must pass password verification before missing SecureToken metadata can be reconciled; the native record must finish saving without changing its UUID or password hash. Returning from Startup Disk or reopening Recovery resumes prepared and awaiting-ownership accounts. The UI reports authorization as pending until finalization and current ownership readback succeed.

The first-stage engine reads back the selected APFS volume group after `bless`. The macOS shutdown handoff also verifies that the target group remains selected. A successful process exit without the expected selection cannot complete the handoff.

The welcome screen retains a small text attribution without an Aurora logo. The Omarchy banner and Kanagawa volume artwork are independent. AppKit owns the outer rounding with hidden title bar and standard window controls; Command-Q quits.

## Per-install firmware recovery baseline

The stager requires the actual finalized ESP `vendorfw/firmware.tar`, `vendorfw/firmware.cpio` and `vendorfw/manifest.txt`. It also retains `vendorfw/u-boot/asmedia/asm2214a-apple.bin` when present. These files are read from this installation’s ESP and inserted into the signed per-install app under `AuraPayloads`; they are never included in the distributable template. All are nonempty, with 256 MiB limits for the archive files, 1 MiB for the manifest, and 16 MiB for the optional U-Boot firmware. Missing required inputs stop staging.

`aura recover` validates the baseline’s file names, sizes and SHA256 hashes, then restores Stage 2 and the retained firmware as one transaction. It backs up every existing destination before the first ESP write and records which files were absent. A failed write restores all attempted destinations, removing only new files that were originally absent. It continues rollback if one restoration fails and reports the retained backup location and affected file names. Files outside the explicit baseline are not copied or deleted.

Focused native tests cover checksum, empty-file and path rejection, optional firmware, successful restoration, failure after a partial replacement, restoration of missing-file state, backup failures before mutation, and incomplete rollback reporting.

## Review policy and interruption handling

The native GUI is selected only by the authenticated template's `recovery_gui: omarchy-native-v1` declaration. A common raw Stage 1 additionally needs `aurora_stage1: {kind: common-raw-v1, qualified_machines: {j700ap: [26.6.2]}}` with the actual qualified firmware versions; asset presence does not qualify another board or firmware. Optional Neo radio or Touch ID extraction becomes mandatory only for entries explicitly listed in `required_neo_peripherals` (`radio`, `touch-id`). Radio model files come from the authenticated pinned 25G83 input recipe, so the running macOS point release does not select a guessed PTX filename.

The recovery account remains an explicit part of the requested workflow. It belongs to the stub's System/Data group, and its native token and volume-owner checks must pass before independent authorization is offered. It is not an account on the user's existing macOS installation. The macOS helper exposes inspection and handoff only; account creation/finalization runs in verified paired Recovery. Enrollment uses `bputil -nc`; boot-argument policy is not weakened by default.

File snapshots preserve original bytes, absence, ownership, permissions and flags. UUID-bound records can remap the same selected files when Recovery assigns different mount names. Saved bytes are verified before the first restore write. Pre-enrollment failure restores files; an authorized LocalPolicy or enclave change is not undone by file recovery. After `kmutil` starts, a timeout may have occurred after enrollment: retain the matching Stage 2 and resume the exact recorded build rather than replacing it with an older bundle. Version metadata and the installed receipt are persisted before disabling autolaunch. The iSC `var` tree is replaced as a whole with a sibling rollback directory instead of merging stale metadata.

Run `Recovery/test-all.sh <output>` on macOS. It runs the existing pure fixtures plus file snapshots, directory-swap interruption checks and the injected installation phase runner. It never enrolls a boot object or creates a live account. Debug/release package and Recovery builds remain separate native validation gates.

The GUI clears password state on completion/dismissal, and owned native command buffers are wiped before release. SwiftUI String/Data copies cannot be guaranteed to have no allocator or framework copies; this is a bounded best-effort lifetime policy, not a claim of complete process-memory erasure.
