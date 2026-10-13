# Apple Silicon image producer

Builds the full-OS payload the Omarchy Mac installer installs, from a signed candidate set, and inspects it before packaging. [One image producer](../docs/image-producer.md) records why this producer and where its parts come from.

## Build an image

An aarch64 Linux host with Docker, loop devices and passwordless sudo for Docker, plus `curl`, `gpg`, `python3` (3.11 or newer), `bsdtar`, `jq` and `gh`:

```bash
image-builder/bin/mac-image-inputs candidates MANIFEST set/
image-builder/bin/mac-image-inputs resolve inputs --candidates set/ --cache cache/
image-builder/bin/build-mac-image --inputs inputs --candidates set/ --cache cache/ out/
```

- `candidates` downloads the release a candidate `manifest.json` names (the set's packages, their signatures and `signing.json`). Nothing in it is trusted yet.
- A set holds the runtime built from one omarchy-mac commit (`omarchy`, `omarchy-settings`, `omarchy-mac`, `omarchy-mac-boot`), the boot packages, and may hold the rest of the Apple default set's closure that the Apple repository order takes from an Omarchy channel. Boot and closure packages may come from that channel (the set records each file's `pkgs.omarchy.org` URL), and so may `omarchy-mac-boot` (`channel_runtime_packages` in the policy), whose recorded source revision the import keeps. The platform packages (`omarchy-mac`, `omarchy-mac-boot`; `platform_packages` in the policy) are versioned apart from the runtime, so a set may carry them built from their own commit of a platform repository (`platform_repositories` in the policy: omacom/omarchy-mac-pkgs, their home, or omacom/omarchy-mac, where they were built before) when its signed manifest declares it: `"platform_sources": {"omarchy-mac": "<commit>", ...}`. A declared package must name that commit as its source and carry it as its source revision; a runtime package from any other commit, declared or not, is refused (`mixed package sources`). The import records each runtime package's source commit, and the image's `PROVENANCE` carries them as `candidate_source=` lines, matched to what the inspection read in the image. Every archive is still signed by the set's key.
- `resolve` verifies the set against the key pinned in `builder/candidate-trust/` and writes the inputs record: the set's receipt, manifest and source commit, the Omarchy channel's database (`--channel`, default edge), the asahi-alarm and Arch Linux ARM databases and the Arch Linux ARM root filesystem, each by sha256, with the servers they come from. `--cache` keeps the databases and root filesystem.
- `build-mac-image` imports the set again (exclusively, read-only), then builds in a privileged Arch Linux ARM container. It writes the zip, `installer_data.json`, `INSPECTION`, `PROVENANCE`, `IMAGE`, the inputs record and the build logs to `out/`. With `--cache`, the package archives it downloads stay in `cache/pkg`, so a later build from the same record installs the same bytes even after the servers move on.

A build takes about 15 minutes and 25 GB of disk. On a host with a desktop session, an automounter (udiskie, gvfs) would mount the filesystems the build puts on loop devices, and ask for a password to do it: run the build as root or with passwordless sudo, and it hides every loop device from udisks with a transient udev rule while it runs. Without either, it refuses to run beside an automounter. devmon and udevil mount without udisks, so the build always refuses to run beside them.

## What a build does

1. Installs a base system and `omarchy-settings` first, so its pacman platform guard is resident, then writes the root-owned image-target manifest (`/var/lib/omarchy/image/target`: `format=1`, `platform=apple-silicon`, read by deferred hardware setup and the platform guard, then the image's provenance, which the runtime ignores: `candidate_set`, `candidate_source_commit`, `builder_commit`, `builder_tree_clean` and `image_profile` of `lab`, `test` for a candidate-only set, or `release`), then installs the runtime with `omarchy-base.packages` and `omarchy-aarch64.packages` (as `omarchy-pkg-defaults apple-silicon` composes them) and, last, the Apple set: the runtime's Apple list (`omarchy-apple-silicon.packages`, or an older runtime's `omarchy-apple.packages`; a runtime with neither stops the build), the Aurora kernel, m1n1, U-Boot, the Limine hook, and the speaker stack's model profiles and DSP chain (`alsa-ucm-conf-asahi`, `asahi-audio`), which the runtime's audio step would otherwise fetch on a first boot that may have no network. Set packages are installed by their `omarchy-candidates/` name, so no other repository can supply them. Base names the pinned repositories lack are recorded as `unavailable=` in `PROVENANCE`.
2. Runs the runtime's own `omarchy-apply-system --defer-provisioning --first-install` in an isolated chroot. The chroot never sees the build host's hardware: its device tree names the image's platform, it has UEFI (as U-Boot provides) without EFI variables, and no PCI, USB, input or DMI devices, so hardware setup installs the same packages on any aarch64 host whose kernel runs with a device tree (an Apple Silicon Mac, most arm64 boards; on an ACPI-only host the image's platform checks find no device tree and the build stops at the Limine activation). A runtime with deferred hardware setup (omacom/omarchy-mac#528) queues its hardware steps from the manifest; an older one runs them here for the image's platform.
3. Sets the kernel command line in `/etc/default/grub`, which the Limine command line is derived from; the image installs no GRUB (`quiet splash`, and `plymouth.ignore-serial-consoles` as on mx-mac, since the Mac's device tree registers a serial console), and Plymouth's `omarchy` theme, which omarchy-settings leaves to Arch Linux ARM's `bgrt` on Apple Silicon. Applies the Apple presets (`80-omarchy-mac*.preset`, including omarchy-mac's audio preset), stages owner provisioning with the pinned Node.js, rebuilds the initramfs, runs `update-m1n1` with `LC_ALL=C` so the device trees go into m1n1's stage 2 in one order, activates Limine through omarchy-mac-boot's `setup-boot` operation of the runtime's lifecycle dispatcher (once before the Limine gate is set, for the console settings, and once after, for the activation; a runtime whose dispatcher has no `setup-boot`, or a boot package without it, keeps the runtime's own `install/hardware/apple` console and Limine leaves), and arms first boot with the boot package's own `arm` command. Once the installed package set is recorded, it appends the build's identity to the image-target manifest (see [Build identity](#build-identity)).
4. Copies the root into a fresh image, keeping snapper's `/.snapshots` a btrfs subvolume (a file copy would flatten it into a plain directory and snapper would fail on the Mac), seals a snapshot of it into `@factory`, then inspects the images against the set's archives and packages them.

## Inspection

`INSPECTION` (JSON) records each check. A missing or mismatched boot component fails the build:

- every set package installed at the set's version, `omarchy-mac-boot` and `limine-mkinitcpio-hook` at or above the minimums in `builder/candidate-trust/policy.json`, no refused package (`linux-asahi`, `m1n1`, `omarchy-apple-boot`, `omarchy-first-boot`, `grub`)
- every package the image's Apple list names installed, reading the list the builder took
- m1n1's stage 2 on the ESP is the set's m1n1, then every device tree of the set's kernel in C order, then the set's U-Boot, then exactly the options the image's `/etc/m1n1.conf` sets; every Mac the set's U-Boot supports has an Aurora device tree there
- every file and link of every runtime and boot package of the set is in the image with the set's bytes and modes (m1n1, U-Boot, the kernel and device trees, the boot package's hooks and scripts, the Limine gate, the runtime), and Limine's loader is the bytes its pinned package installed; the closure's packages are held to the set's versions and archives, since the runtime may restyle their files
- Limine at `EFI/BOOT/BOOTAA64.EFI` is the installed `limine` package's, its menu boots `omarchy_linux-aurora.efi` (with a matching BLAKE2 hash when the menu carries one), and the UKI's kernel is the set's, its release, os-release and command line match the image
- the initramfs the UKI embeds carries the boot package's encryption and vendor firmware units and their activation links
- the unlock screen is Plymouth's `omarchy` theme, in the image and in the UKI's initramfs, and the UKI's command line has `quiet splash plymouth.ignore-serial-consoles`
- the pacman hooks that rebuild the UKI and redeploy Limine come from their packages, the Apple gate included
- the image-target manifest (its provenance matching the set, the build's profile and `@factory`'s copy; `mac-image-check provenance` matches it to `PROVENANCE`), first boot, owner provisioning, the Limine gate and the fresh-image `deferred-steps` contract; the hardware queue never runs an older runtime's `install/hardware/apple/pacman.sh`, which adds the unsigned `[omarchy-aarch64]`
- `/.snapshots` is an empty btrfs subvolume under snapper's root configuration, or absent with a deferred hardware step queued to create it; a plain directory fails
- the installed pacman configuration is omarchy-mac's Apple Silicon template for the channel (`/usr/share/omarchy-mac/pacman`; on an older set the runtime's `default/pacman/apple-silicon`, or `aarch64` on an older runtime still) with the runtime's aarch64 mirror list (`aarch64/mirrorlist-<channel>`, or a single `mirrorlist-aarch64`), plus the test image's pin below, and the installed-system checks (`builder/verify_installed_system.py`) pass, `alsa-ucm-conf-asahi`, `asahi-audio`, `vulkan-asahi` and `asahi-bless` included, and no `[omarchy-aarch64]` section or `TrustAll` SigLevel; Bluetooth counts as enabled when its hardware step is queued for first boot
- `@factory` is sealed for the set without fresh-image or owner state

`bin/mac-image-check` also holds the payload to the installer engine's contract and checks `PROVENANCE` and `IMAGE` against the bytes beside them.

## Test images keep the candidate runtime

Every set the importer takes is a test candidate set (`candidate_only`), and its runtime is versioned `4.0.0.alpha.quattro…`, which sorts below the channel's `omarchy` (4.0.2 on edge). A `pacman -Syu` on the installed Mac would replace it with the channel's. So a test image's `/etc/pacman.conf` starts its `[options]` with a marked block, `IgnorePkg = omarchy omarchy-mac omarchy-settings`: the packages built from the set's source commit, or from the commit it declares for a platform package (`builder/test_image_pin.py`, recorded as `test_image_pin` in `IMAGE` and `PROVENANCE`). Everything else follows the channel: the kernel, the closure, and the boot package when the set takes it from the channel. Keep the three marked lines (the second says so): until the channel carries qualified Mac packages, deleting them lets a `pacman -Syu` downgrade the runtime and break the Mac. On this runtime `omarchy-refresh-pacman` and `omarchy-channel-set` leave an Apple Silicon Mac's pacman.conf alone (no aarch64 channel is qualified yet); once they rewrite it from the template, the pin goes with it. The runtime's templates and every other default are unchanged. A local candidate repository ordered first was not used: the image would have to trust the candidate test key, or install it unsigned.

## Lab test images

`build-mac-image --lab-access DIR` builds an edge test image the lab controller can reach without anyone at the Mac. DIR holds `authorized_keys` (public keys only), and optionally `user` (default `maralc`: the owner must create that user at first-boot setup) and `thunderbolt` (`MODEL-GLOB|10.x.y.z/NN` per test Mac model). Before `mkinitcpio` and the `@factory` seal, the builder writes `builder/lab_access.py`'s overlay into `@`: the keys under `/etc/omarchy-lab/authorized_keys/<user>` (read through an sshd drop-in), passwordless sudo and polkit for that user, `sshd` enabled, and `omarchy-lab-access.service`, which on every boot opens SSH in ufw and writes the `lab-thunderbolt` NetworkManager profile (never the default route) for the model it finds. The payload is named `…-mac-edge-lab-os-package.zip`, so it never passes for a release payload, and `IMAGE`, `PROVENANCE` and `INSPECTION` record `profile=lab` and the overlay's `lab_access_sha256`.

A lab image carries no secret: test images are published for download, so Tailscale enrollment and anything else credential-bearing happens over SSH after the first boot. The inspection refuses any Tailscale key, private key or disk key file in every image, lab or not.

Every other image is a release image, and its inspection refuses lab access wherever it is and whatever it is called: `authorized_keys` files, `AuthorizedKeysFile`, `AuthorizedKeysCommand`, `AuthorizedPrincipals*` or `TrustedUserCAKeys` settings, sudo rules without a password for every command, sshd enabled by a link or a preset, polkit rules that grant every action to a named user (or any local one), `lab-thunderbolt` or `omarchy-lab` files, in `@` mounted and unmounted, `@home`, `@log`, `@pkg`, `@factory`, `/boot`, the ESP and the UKI's initramfs. A lab inspection (`mac-image-check image|tree edge … --profile lab`) requires exactly the overlay and nothing beyond it, and `rc` and `stable` refuse the lab profile outright, in the inspection and in the `IMAGE`/`PROVENANCE` checks.

## First boot acceptance

Inspection is not boot qualification. After the owner's first login on the Mac, as root:

- `btrfs subvolume show /.snapshots` succeeds, and `snapper list` and `systemctl start snapper-cleanup.service` finish without error
- `plymouth-set-default-theme` prints `omarchy`, and `/proc/cmdline` has `splash plymouth.ignore-serial-consoles`
- `/var/lib/omarchy/image/deferred-steps` is gone: the deferred hardware setup finished (if not, `/var/log/omarchy-install.log` names the step it stopped at)
- `pacman -Q alsa-ucm-conf-asahi asahi-audio` lists both, and in the owner's session `wpctl status` shows the model's `audio_effect.<model>-convolver` (on the M2 Max, `j416-convolver`) as the default sink, not a `stereo-fallback` one

## Neo external-display defaults

The Aurora J700 stack uses the ordinary `t8140-j700.dtb` for external displays.
The kernel supplies the native bandwidth offsets from its T8140 hardware
profile, and m1n1 enables the external controller only after validating the
inherited firmware and its dependency group. Installer images must carry both
sides of this handoff; no `appledrm.experimental_h17p_external*` command-line
arguments or replacement test DTB are required.

The first qualified defaults are Linux `d08fd52e1619` and m1n1 `f3ac615eb137`.
Neo booted the packaged stack with no display arguments and automatically
activated a Samsung Odyssey G81SF at 3840×2160, 60 Hz while retaining its
internal display. Higher refresh rates, other monitors, reversed cable
orientation and suspend need separate qualification. Keep the firmware's mode
and bandwidth validation intact.

## Build identity

A booted Mac names the build it came from in `/var/lib/omarchy/image/target` (`target.booted` after its first boot; `@factory` carries the same bytes, so a factory reset keeps it). After the provenance lines above, the builder appends, once the package set is recorded and before `@factory` is sealed:

- `package_set_sha256=`: 64 lowercase hex digits, the same value as `IMAGE` and `PROVENANCE`'s `package_set_sha256`
- `built=`: the UTC time this build recorded it, `YYYY-MM-DDTHH:MM:SSZ`, the same value as `IMAGE` and `PROVENANCE`'s `built`

For example:

```
format=1
platform=apple-silicon
candidate_set=apple-test-f22c43fb7903-20260928
candidate_source_commit=f22c43fb7903…
builder_commit=6f1b40df2732…
builder_tree_clean=true
image_profile=test
package_set_sha256=f9ead5a6…
built=2026-09-28T03:04:05Z
```

The zip's own sha256 cannot be here, since root.img holds this file. To map a report to a release asset, find the release whose `IMAGE` asset has the report's `package_set_sha256` and `built` (the package set alone also matches a rebuild from the same inputs, and a lab and a release image of one set); that `IMAGE`'s `image_sha256` lines and `PROVENANCE`'s `payload=` name the payload, whose sha256 is the catalog's `payloadDigest`. Every value is checked against a strict pattern before it is written (`candidate_set` is `[A-Za-z0-9._-]+`), none is secret, and inspection refuses an image whose manifest lacks one or holds a malformed one; `mac-image-check provenance` and `descriptor` require the manifest's values, as `INSPECTION` read them, to be `PROVENANCE`'s and `IMAGE`'s. An image built before builds recorded their identity (preview-3-f22c43fb7903, the m1 and m2 lab kits) has neither key in its manifest, `INSPECTION`, `IMAGE` or `PROVENANCE`, and still passes; one key without the other, or a record that has them while another lacks them, is refused.

## Reproducibility

`IMAGE` records the inputs (the builder commit and whether its tree was clean, the set's receipt, manifest and source commit, and the inputs record's digest) and `package_set_sha256`, the sha256 of every installed package's name, version and archive sha256. Two builds from the same builder commit, inputs record and candidate set give the same `package_set_sha256` and the same input lines; any changed input changes them. `built` is the one line that differs between them, by design: it tells the builds apart. Filesystem images are not byte-identical between builds, and the default UKI's initramfs is autodetected as mkinitcpio does, so its module list follows the build host's devices; the Mac's boot modules come from the asahi hook either way.

## Checks

`bash image-builder/test/all` runs the source checks: the importer against signed fixture sets (tampering, a foreign key, a key that travels with the set, missing and refused packages, closure and channel packages and their sources, versions below a minimum, a file with two owners, a runtime package from another commit, declared platform sources and the mixes they still refuse), the inspection against fixture images (every boot component missing or mismatched, a set file rewritten, a wrong `@factory`, a `bgrt` or missing splash, a flattened `/.snapshots`, a missing speaker stack, Vulkan driver or `asahi-bless`, an unsigned repository in `pacman.conf` or the first-boot queue, a missing or different test image pin), the inputs record, lab access (the overlay, its refusal in release images and the credentials no image may carry) and the builder's own decisions. They need Bash 5, Python 3.11 or newer, GnuPG, jq and bsdtar, and no container, network or root.

## Sources

`bin/` is mx-mac's image builder from maralcbr/omarchy-pkgs `asahi-quattro` at `7e2f6cfe` (`bin/build-mac-image`, `bin/mac-image-inputs`, `bin/mac-image-check`, and `mac-image-finalize` as `builder/finalize-root`), adapted to the candidate set. `builder/candidate_set.py`, `builder/apple_limine.py` and `builder/verify_installed_system.py` come from the candidate importer, Limine contract and installed-system verifier of this repository's #2.
