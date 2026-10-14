# Omarchy Step 2

The Omarchy-branded native Recovery interface lives alongside the main installer. It has two explicit build modes, targeting macOS 13 independently of the main installer's macOS 15 requirement.

## Preview

On macOS with Xcode and XcodeBuildMCP installed:

```sh
cd Recovery
./build-preview.sh
open "build/Omarchy Installer.app" --args --preview
```

Use `--recovery-preview` to preview repair. This build always defines `OMARCHY_STEP2_PREVIEW` and cannot enroll or modify startup software even when launched in Recovery. Keep only one review app instance open.

## Actual Recovery build

```sh
cd Recovery
./build-recovery.sh
```

This explicitly defines `OMARCHY_STEP2_RECOVERY`, emits `build-recovery/Omarchy Installer.app` and `build-recovery/omarchy-recovery-app.json`, and verifies the executable's `--build-mode`, ad-hoc signature and localized bundle name. The template has no target UUIDs, credentials or boot payloads. It cannot enroll by itself: the engine must populate validated configuration and the target's actual startup files.

Put the app and adjacent manifest in the OS ZIP under `esp/aurora/recovery/`. The OS template should declare `"recovery_gui": "omarchy-native-v1"`; this requires the app and verifies its entire content inventory before partitioning. Older payloads without this contract or app retain their existing shell Step 2. After creating the target and finalizing Stage 1 and `m1n1/boot.bin`, `omarchy_recovery.stage` copies the app to the stub System volume, generates `Contents/Resources/install-config.json`, bundles the exact finalized raw Stage 1, Stage 2 and this installation’s extracted device firmware with hashes, and re-signs/verifies the copy before changing `.IAPhysicalMedia` to launch it.

Configuration schema 2 includes `volumeName`, `systemUUID`, `groupUUID`, `prebootUUID`, `espUUID`, `bootMode`, `stage2Path` and `bootstrap`. Only raw mode and `m1n1/boot.bin` are currently accepted. Mach-O and nested virtualization controls remain disabled in the real build until backed by a qualified complete payload. Runtime target discovery uses the app's containing volume, verified against the configured APFS identity; it does not rely on `/Volumes/Omarchy` or a fixed disk number.

The legacy `Finish Installation.app/Contents/Resources/boot.bin` remains for upstream resume detection; its `step2.sh` becomes a relative launcher for `Omarchy Installer.app`. The new app remains on the stub after completion removes `.IAPhysicalMedia`, and the `aura` command opens its actual executable or invokes recovery actions. The localized `CFBundleDisplayName` must remain present: Recovery's Springboard requires it for this direct native launch contract.

Enrollment rechecks root, the configured target volume and paired power-button 1TR, then resolves a real target volume owner from APFS and target Preboot metadata. When no eligible target owner exists, the explicitly configured `source-volume-owner` bootstrap can use the original macOS owner. That path binds the original System volume and APFS group UUIDs, requires the volume still exists, and intersects copied target administrator metadata with both the specifically authorized source owner UUID recorded by Stage 1 and its current APFS VolumeOwner list. Ambiguous or unmatched owners are rejected. Existing bputil/kmutil prompt handling stays in the native PTY backend. Normal macOS is rejected before writes. The app retains persistent attempt logs and bounded UI log rendering.

The bootstrap System UUID names the underlying System-role APFS volume, not the boot snapshot mounted at `/`. For older configurations that recorded a snapshot UUID, Recovery resolves the unique System volume in the recorded source group and verifies that the recorded snapshot belongs to it before querying ownership. Snapshot enumeration can require mounting that source volume read-only. A missing snapshot, changed group, ambiguous System volume, or unregistered owner remains an error.

## Validation and limits

The strict configuration fixture, original enrollment/owner/boot-selection fixtures, native prompt fixture, Python staging/checksum/target-identity fixtures and source formatting are tested. Both real and preview builds compile and pass signing and localized-name checks. The normal-macOS CLI rejection is tested. These are build and fixture results, not a completed fresh-install or Recovery boot qualification.

The main installer ends with shutdown instructions. Its authenticated helper verifies the completed installation and updates that target’s Recovery app before requesting shutdown.

Step 2 enrolls startup software with `bputil` and `kmutil` as the target's volume owner or, on a fresh stub, the explicitly bound existing macOS owner, as Asahi's installer does. It creates no additional account and needs no Startup Disk authorization. The final Restart button restarts into Omarchy, which the macOS handoff already verified as the selected startup disk.

The first-stage engine reads back the selected APFS volume group after `bless`. The macOS shutdown handoff also verifies that the target group remains selected. A successful process exit without the expected selection cannot complete the handoff.

The welcome screen retains a small text attribution without an Aurora logo. The Omarchy banner and Kanagawa volume artwork are independent. AppKit owns the outer rounding with hidden title bar and standard window controls; Command-Q quits.

## Per-install firmware recovery baseline

The stager requires the actual finalized ESP `vendorfw/firmware.tar`, `vendorfw/firmware.cpio` and `vendorfw/manifest.txt`. It also retains `vendorfw/u-boot/asmedia/asm2214a-apple.bin` when present. These files are read from this installation’s ESP and inserted into the signed per-install app under `AuraPayloads`; they are never included in the distributable template. All are nonempty, with 256 MiB limits for the archive files, 1 MiB for the manifest, and 16 MiB for the optional U-Boot firmware. Missing required inputs stop staging.

`aura recover` validates the baseline’s file names, sizes and SHA256 hashes, then restores Stage 2 and the retained firmware as one transaction. It backs up every existing destination before the first ESP write and records which files were absent. A failed write restores all attempted destinations, removing only new files that were originally absent. It continues rollback if one restoration fails and reports the retained backup location and affected file names. Files outside the explicit baseline are not copied or deleted.

Focused native tests cover checksum, empty-file and path rejection, optional firmware, successful restoration, failure after a partial replacement, restoration of missing-file state, backup failures before mutation, and incomplete rollback reporting.
