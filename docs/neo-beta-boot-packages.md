# MacBook Neo beta boot packages

The Omarchy/Arch beta for the MacBook Neo (J700, T8140) needs a kernel with the J700 device tree. The edge channel's `linux-aurora` (7.1.12.aurora2-11, built 2026-09-27) has none, so a channel-mode image cannot boot a Neo. This page pins the public boot packages the beta takes instead. It also lists what stands between them and a candidate set this builder accepts.

## The packages

The packages are built from public sources only, by the recipes on aurora-silicon/omarchy-pkgs `beta/linux-aurora-neo-5f6c917` (`862dc9143b7ee84340c057bcc407f26742d033cc`, aurora-silicon/omarchy-pkgs#2). They are attached to the draft release `neo-beta-2026.10.15` on aurora-silicon/omarchy-pkgs. Its `SHA256SUMS` pins their bytes, `BUILD-RECEIPT.json` records how they were built, and `VERIFY.json` compares the kernel with the stripped package that booted the Neo.

| Package | Source |
| --- | --- |
| `linux-aurora`, `linux-aurora-headers` 7.1.12.aurora20261015-1 | aurora-silicon/linux `5f6c917f2c824b3c87497e8bd7dd92a6de0efe60` (aurora-wip, merges #301), with `aurora_j700_defconfig` (aurora-silicon/linux#306) |
| `m1n1-aurora` 1.6.1.aurora20261015-1 | aurora-silicon/m1n1 `f3ac615eb1376d3bbba24cd84c414b9e41892adb` (aurora-wip) |
| `uboot-asahi` 2026.07.aurora20261015-1 | aurora-silicon/u-boot `0cb6fed6a10512d1013a4a80b6d83c3d56140f2f` (aurora-wip) |

- **Kernel release.** It is `7.1.12-aurora-g5f6c917-ARCH`. It ends in `-ARCH` because asahi-scripts' `update-m1n1` takes its device trees from the newest `/lib/modules/*-ARCH/dtbs` unless `/etc/default/update-m1n1` overrides that, and omarchy-mac-boot keeps the default.
- **Modules.** They are installed stripped (`INSTALL_MOD_STRIP=1`, llvm-strip). The unstripped set (405 MB, a 100 MB initramfs) hung the Neo's first boot.
- **Device trees.** They are in `usr/lib/modules/<release>/dtbs/`, flat, `t8140-j700.dtb` included, where `update-m1n1` and this builder read them.
- **U-Boot device trees.** `uboot-asahi` lists the Macs it supports in `usr/lib/asahi-boot/dtb/`, as `check_supported_models` expects.
- **Toolchain.** Arch Linux ARM's LLVM 22.1.8 (`clang22`, `lld22`, `llvm22`), Rust 1.99.0 and the kernel's own patched bindgen (`tools/aurora-bindgen`). With LLVM 23 the kernel selects `-fms-anonymous-structs`, and the Rust layout assertions fail.

## Image command line

UEFI load options replace the device tree's `/chosen/bootargs`, which is where the Neo's `arm64.nowfxt` comes from. `builder/finalize-root` therefore writes the token into every image's GRUB defaults, from which the UKI and Limine command lines are generated. M1 to M3 have no FEAT_WFxT, so it changes nothing on them.

## Turning the packages into a candidate set

`build-mac-image --candidates` accepts only a set signed by the key pinned in `builder/candidate-trust/` (`E11E851AF82E02AEF54C8794599A6024E3D35379`, the candidate test lane). The set must also hold the runtime packages (`omarchy`, `omarchy-settings`, `omarchy-mac`, `omarchy-mac-boot`) built from one source commit, and `limine-mkinitcpio-hook`. The draft release holds the boot packages only, unsigned. To build the beta image:

1. Sign the four boot packages, together with the runtime packages and the closure, with the candidate key. Its holder runs omacom/omarchy-mac `tools/release/candidate-set`. Alternatively, decide to pin an Aurora key in `builder/candidate-trust/`, which is a policy change.
2. `policy.json` names `omacom/omarchy-pkgs` as `boot_repository`. Either record the boot packages' source as that repository at the recipes commit, or add `aurora-silicon/omarchy-pkgs` to the policy.
3. Build on an aarch64 host:
   ```
   image-builder/bin/mac-image-inputs candidates MANIFEST set/
   image-builder/bin/mac-image-inputs resolve inputs --candidates set/ --cache cache/
   image-builder/bin/build-mac-image --inputs inputs --candidates set/ --cache cache/ out/
   ```
4. Run the hardware gate on the Neo. It covers Stage 1 and Stage 2 with the rebuilt J700 device tree (`apple,firmware-owned` in `/proc/device-tree`), LUKS unlock with the keyboard, the display and the GPU desktop, Wi-Fi and Bluetooth, speakers and microphone, Touch ID after the 43-second key store, suspend and resume, and a reboot.
