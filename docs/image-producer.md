# Apple image producer

This repository has one Apple Silicon image producer, in `image-builder/`. This page records how the two producers that existed became one, and the interface it has. The decision comes from the Apple Silicon convergence plan (omacom/omarchy-mac#512, "Installer and images"). [image-builder/README.md](../image-builder/README.md) is how to run it.

## Decision

The base is mx-mac's image builder: `bin/build-mac-image`, `bin/mac-image-inputs` and `bin/mac-image-check` from maralcbr/omarchy-pkgs `asahi-quattro` at `7e2f6cfe`. It keeps #2's authenticated candidate importer, its Limine contract and its installed-system checks. The omarchy-iso-derived builder that #2 imported into `image-builder/` (from `dbc46807`) is removed.

Why this base:

- It already built the payload the 2.0.10 app and engine install: fixed UUIDs, ESP volume id and sizes, the zip members and `installer_data.json` that `_validate_full_os_package` checks. Since 2026-09-22 it has built mx-mac's published fresh-install payloads, which ship Limine behind m1n1 and U-Boot with the Aurora kernel. The 2026-09-23 rc image passed mx-mac's image VM acceptance before publication.
- It is small: three scripts and their tests. The imported builder was about 270 files and 70,000 lines, most of it ISO, archinstall, checkpoint and stage machinery for linux-asahi and GRUB products the plan retires.
- One inputs record pins every database and the root filesystem by sha256, so each image traces back to the bytes it was built from.

Why keep #2's importer: `build-mac-image` trusted the fork. It installed a runtime release of `install-asahi-quattro` from maralcbr/omarchy-mx-mac and a `CANDIDATE` descriptor signed with the fork's repository key. The plan replaces that with signed candidate packages pinned to one `quattro-upstream` commit, and `candidate_set.py` verifies such a set without trusting keys that arrive with it.

## What comes from where

| Part | Source | In the producer |
| --- | --- | --- |
| Host/container split, verified ALARM root filesystem, isolated chroot, loop and mount cleanup | `build-mac-image` | kept |
| Payload contract: filesystems, UUIDs, subvolumes, sealed `@factory`, zip, `installer_data.json` | `build-mac-image` | kept unchanged, so the 2.0.10 app and engine take the image |
| Presets, Node pin staged, owner provisioning armed, image finalization (`mac-image-finalize`), Limine activated through the runtime's own leaves, `update-m1n1` | `build-mac-image`, omarchy-pkgs `mac-image-finalize` | kept; the finalizer is `builder/finalize-root`, since no runtime package ships it now |
| Inputs record | `mac-image-inputs` | kept; the fork's runtime, `[omarchy]` and `[omarchy-aurora]` channel fields replaced by the candidate set and the Omarchy channel's database; the hosts moved from script constants into the record |
| Payload, image, tree, provenance and descriptor checks | `mac-image-check` | kept, extended by the inspection |
| Fork runtime installer: `fetch_verified_installer`, `run_installer`, `fetch_bundle_manifest` | `build-mac-image` | removed; the runtime's own `omarchy-apply-system` sets the image up |
| Authenticated candidate importer | #2 `builder/quattro-candidate.py` | `builder/candidate_set.py`, for the plan's set: `manifest.json` and `signing.json` from omacom/omarchy-mac `tools/release/candidate-set` |
| Signer policy and public key | #2 `builder/quattro-trust/` | `builder/candidate-trust/`: the test-lane key `E11E851AF82E02AEF54C8794599A6024E3D35379`, the package set and the minimum versions |
| Limine contract | #2 `configs/airootfs/.../orchestrator/asahi_limine.py` | `builder/apple_limine.py`, its checks only; the activation is the runtime's |
| Installed-system checks | #2 `builder/verify-asahi-installed-system.py` | `builder/verify_installed_system.py`, the GRUB and linux-asahi branches dropped |
| Omarchy repository key, volume icon | #2 `builder/omarchy.gpg`, `builder/branding/omarchy-volume.icns` | `builder/keys/omarchy-repository.gpg`, `builder/omarchy-volume.icns` |
| Duplicate and overlap checks, disposable-root transaction check | #2 `builder/quattro-dependencies.py`, `builder/quattro-package-install-check.sh` | replaced: the whole package set is resolved against the pinned databases before anything installs (every set package from the set, no refused package), pacman refuses file conflicts, and every installed package is traced to a pinned database and its archive bytes |
| ISO media, archiso gitlink, archinstall configurator, VM tooling, asahi stages, checkpoints, leases, orchestrator, products, branding manifests, publication and upload commands | #2 `image-builder/` | removed |
| `release-mac-image.yml` publication workflow | omarchy-pkgs | not ported; building stays an owner-run step until release qualification |

The private M3 pilot's image recipe (the `omarchy-mx-mac-limine-private` product and `private-limine-qualification.py`) is not ported. The plan scopes M3 out, and that recipe stays reproducible from #2's head, `5274846`. The app side of the pilot stays: the `InstallerBuildProfile` private profiles, `Packaging/private-test/` and their tests.

## Interface

```
image-builder/bin/mac-image-inputs resolve FILE --candidates DIR [--channel edge|rc|stable] [--cache DIR]
image-builder/bin/build-mac-image --inputs FILE --candidates DIR [--cache DIR] [--dry-run] OUT
```

- The inputs record (format 2) pins the candidate set (its receipt and manifest sha256, source commit and signer), the Omarchy channel's `omarchy.db`, `asahi-alarm.db`, the Arch Linux ARM databases and root filesystem, and names each server. Trust comes only from files in this repository; no flag or environment variable supplies a key or a policy.
- The candidate set is imported (verified and frozen read-only) on the host before any network access or container. The build never refreshes a database: the pinned bytes are put in place. With `--cache`, package archives are kept, so a later build from the same record installs the same bytes after the servers have moved on.
- `OUT` receives the zip, `installer_data.json`, `INSPECTION`, `PROVENANCE`, `IMAGE`, the inputs record and the logs.

Candidate set, as the importer accepts it:

- **Runtime group** (built from the pinned `quattro-upstream` commit, which each archive also records): `omarchy`, `omarchy-settings`, `omarchy-mac`, `omarchy-mac-boot`
- **Boot group** (built from omacom/omarchy-pkgs): `linux-aurora`, `linux-aurora-headers`, `m1n1-aurora`, `uboot-asahi`, `limine-mkinitcpio-hook`
- **Minimum versions**, in the policy since the manifest records none: `omarchy-mac-boot` 20260921-10, `limine-mkinitcpio-hook` 1.39.0-2.
- **Refused outright:** `omarchy-apple-boot`, `omarchy-first-boot`, `linux-asahi` and the Asahi `m1n1`.
- **Not in the set:** `limine` and `limine-snapper-sync`, from the pinned Arch Linux ARM and Omarchy databases.

Build order inside the container:

1. A base system and `omarchy-settings`, alone, so its pacman platform guard (omacom/omarchy-mac#539) is resident before any platform package.
2. The root-owned image-target manifest `/var/lib/omarchy/image/target` (`format=1`, `platform=apple-silicon`: upstream's platform is now `aarch64-apple`, but the runtime still reads `apple-silicon` and an older runtime (omacom/omarchy `5397950a2`) refuses `aarch64-apple`), which deferred hardware setup (omacom/omarchy-mac#528) and the pacman platform guard (#539) both read. It also records `candidate_set`, `candidate_source_commit`, `builder_commit`, `builder_tree_clean` and `image_profile` (`lab` for `--lab-access`, `test` for a candidate-only set, else `release`), which the runtime ignores; after first boot the file is `target.booted`, so a booted Mac names the image it came from. Once the package set is recorded (step 5), the builder appends `package_set_sha256` and `built` (UTC, `YYYY-MM-DDTHH:MM:SSZ`), the values `IMAGE` and `PROVENANCE` record, before `@factory` is sealed, so a hardware report maps to one build's release assets (`image-builder/README.md`, Build identity). The image's own sha256 is not in it (root.img holds the file): `IMAGE`, `PROVENANCE` and the catalog carry it.
3. The runtime with `omarchy-base.packages` and `omarchy-aarch64.packages` (when the runtime ships it), then the Apple set: `omarchy-aarch64-apple.packages` (an older runtime's `omarchy-apple-silicon.packages` or `omarchy-apple.packages`), the kernel, m1n1, U-Boot and the Limine hook, plus `alsa-ucm-conf-asahi` and `asahi-audio` from the pinned asahi-alarm database. Every candidate set package is installed by its `omarchy-candidates/` name, so `[asahi-alarm]`, ordered before `[omarchy]` in the Apple profile, cannot supply `uboot-asahi` or `m1n1`.
4. The runtime's `omarchy-apply-system --defer-provisioning --first-install`. The build chroot never sees the build host's hardware: a device tree naming the image's platform, UEFI without EFI variables, no PCI, USB, input or DMI devices. The host kernel must run with a device tree for the image's platform checks to find one. A runtime with #528 queues its hardware steps for first boot from the manifest; the first candidate set's runtime (`073e489b5`) predates it and runs them here, and its first boot runs only the Limine leaf (`mac-first-boot/deferred-steps`).
5. The image's GRUB defaults (the Limine command line's source, with `plymouth.ignore-serial-consoles` as on mx-mac) and Plymouth's `omarchy` theme, presets (`80-omarchy-mac*.preset`, so omarchy-mac's audio preset too), Node.js for owner provisioning, `mkinitcpio -P`, GRUB, `update-m1n1` under `LC_ALL=C`, the runtime's GRUB compatibility and Limine leaves, and first boot armed by the boot package's own `arm` command.
6. Seal (snapper's `/.snapshots` stays a btrfs subvolume through the copy), inspect, package. `PROVENANCE` and `IMAGE` record the builder commit, the set's receipt, manifest, source commit and signer, each installed package's repository and archive sha256, `package_set_sha256`, and `built`, the UTC time the build recorded its identity in the image-target manifest (the same `package_set_sha256` and `built` the manifest carries).

**Reproducible** means: the same builder commit, inputs record and candidate set give the same installed package set (name, version and archive sha256, `package_set_sha256`) and the same `IMAGE` input lines. Any changed input changes them. `built` differs between two such builds by design. Byte-identical filesystem images are not required, and the default UKI's autodetected initramfs follows the build host's devices.

## Tests

`image-builder/test/all` runs in CI's image-builder job: the importer against signed fixture sets (a tampered archive, a wrong signer, a key that travels with the set, a missing, extra or refused package, a version below a minimum, a file with two owners, a runtime package from another commit), the inspection against fixture images whose m1n1 stage 2, device trees, U-Boot, set files, Limine loader, menu, UKI, embedded initramfs, Plymouth theme, splash command line, `/.snapshots` subvolume, speaker stack, maintenance hooks, versions, first-boot markers or `@factory` are missing or wrong, `PROVENANCE` and `IMAGE` against their build directory, the inputs record, and the builder's own decisions. None of them need Mac hardware, a container or root. The M2 Max install of the first image is the separate hardware gate (tickets 25 and 26).
