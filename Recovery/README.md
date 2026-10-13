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

Put the app and adjacent manifest in the OS ZIP under `esp/aurora/recovery/`. The OS template should declare `"recovery_gui": "omarchy-native-v1"`; this requires the app and verifies its entire content inventory before partitioning. Older payloads without this contract or app retain their existing shell Step 2. After creating the target and finalizing Stage 1 and `m1n1/boot.bin`, `omarchy_recovery.stage` copies the app to the stub System volume, generates `Contents/Resources/install-config.json`, bundles the exact finalized raw Stage 1 and Stage 2 with hashes, and re-signs/verifies the copy before changing `.IAPhysicalMedia` to launch it.

Configuration schema 2 includes `volumeName`, `systemUUID`, `groupUUID`, `prebootUUID`, `espUUID`, `bootMode`, `stage2Path` and `bootstrap`. Only raw mode and `m1n1/boot.bin` are currently accepted. Mach-O and nested virtualization controls remain disabled in the real build until backed by a qualified complete payload. Runtime target discovery uses the app's containing volume, verified against the configured APFS identity; it does not rely on `/Volumes/Omarchy` or a fixed disk number.

The legacy `Finish Installation.app/Contents/Resources/boot.bin` remains for upstream resume detection; its `step2.sh` becomes a relative launcher for `Omarchy Installer.app`. The new app remains on the stub after completion removes `.IAPhysicalMedia`, and the `aura` command opens its actual executable or invokes recovery actions. The localized `CFBundleDisplayName` must remain present: Recovery's Springboard requires it for this direct native launch contract.

Enrollment rechecks root, the configured target volume and paired power-button 1TR, then resolves a real target volume owner from APFS and target Preboot metadata. When no eligible target owner exists, the explicitly configured `source-volume-owner` bootstrap can use the original macOS owner. That path binds the original System volume and APFS group UUIDs, requires the volume still exists, and intersects copied target administrator metadata with both the specifically authorized source owner UUID recorded by Stage 1 and its current APFS VolumeOwner list. Ambiguous or unmatched owners are rejected; a real target owner always takes precedence. Existing bputil/kmutil prompt handling stays in the native PTY backend. Normal macOS is rejected before writes. The app retains persistent attempt logs and bounded UI log rendering.

## Validation and limits

The strict configuration fixture, original enrollment/owner/boot-selection fixtures, native prompt fixture, Python staging/checksum/target-identity fixtures and source formatting are tested. Both real and preview builds compile and pass signing and localized-name checks. The normal-macOS CLI rejection is tested. These are build and fixture results, not a completed fresh-install or Recovery boot qualification.

The main installer's new Recovery-account creation screen still has no live account/ownership finalizer. This Step 2 resolves existing actual owners, including the explicitly verified original macOS owner for Asahi’s initial copied-admin bootstrap. It does not create an account, use the Recovery login or treat copied admin metadata alone as proof of ownership. A fresh installation must validate the existing-owner authorization flow on hardware.

The welcome screen retains a small text attribution without an Aurora logo. The Omarchy banner and Kanagawa volume artwork are independent. AppKit owns the outer rounding with hidden title bar and standard window controls; Command-Q quits.
