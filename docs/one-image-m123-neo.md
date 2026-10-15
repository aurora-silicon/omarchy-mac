# One image for M1–M3 and the MacBook Neo

Pre-release `neo-preview-dev5-20261011` ships two developer images built from the same Aurora 2026.10.11.14 kernel: one for M1, M2 and M3 Macs (`build5-m123.sh`) and one for the MacBook Neo (`apple,j700`, T8140, `build5-neo.sh`). Two images mean two builds, two 3.7 GB downloads, two catalog groups and two qualification runs for every kernel bump. This note records how one image replaces both. It condenses the spec and tickets kept in `.scratch/one-image-m123-neo/` in the omacom/omarchy-mac-installer working tree (local files; tickets are named by number below, under `.scratch/one-image-m123-neo/issues/`).

Status: design and source prototype. Nothing here has been built on pancake, installed on a Mac, signed or published. `apple,j614s` and every M4 or later Mac stay refused.

## Why the images can't simply be merged

- `m1n1-aurora` and `m1n1-neo` both declare `provides = m1n1` and `conflict = m1n1`, so pacman won't install them together.
- Each Mac needs a different Stage 2 `boot.bin`, and that file must stay correct across every later `pacman -Syu`, which rebuilds it through update-m1n1.

## Decisions

- **One image, both Stage 2s.** The image carries both m1n1 packages and every Neo-only piece. Each Neo-only piece is either a file nothing else reads or a unit gated on the J700 device tree, so it does nothing on other Macs.
- **Per-board choices happen in exactly two places.** At install, engine .33 places the Neo's prebuilt `boot.bin` (and .32 already fills the board's Aurora Stage 1). At every update-m1n1 run, a selector reads the live device tree and picks the m1n1 and U-Boot. On a board it doesn't recognise it refuses and writes nothing.
- **Package ownership.** Aurora (omacom/linux-aurora) publishes every package the image installs, pinned by digest. A local repack is allowed only to test the prototype and is never released or uploaded.
- **Selector placement.** `/etc/default/update-m1n1` is `omarchy-mac-boot`'s backup file. It keeps its packaged lines and gains one appended block that sources the selector at `/usr/lib/omarchy-mac-image/update-m1n1-board`. Long term the selector ships in `omarchy-mac-boot`, so upgrades don't leave a `.pacnew`.
- **Regulatory domain.** Never set globally. If the Neo needs a country for 5 GHz, that's a separate per-board or user-chosen follow-up (ticket 09 decides whether it's needed).
- **`arm64.nowfxt`** applies to every Mac. An optional Aurora kernel quirk would let it go.
- **Neo-only files.** Aurora is asked for one support package (for example `aurora-j700-support`). Until it ships, the prototype copies the files in unowned.
- **Catalog.** One payload zip and three metadata files: main M1–M3; J613 with `supported_fw: ["26.6.2"]`; J700. `make-unsigned-catalog.py --developer` already lets groups share a payload, so it needs no changes.
- **Long term.** If Aurora merges the two m1n1s, the selector shrinks to choosing the U-Boot and `m1n1-neo` goes away. If the J700 U-Boot also lands in `uboot-asahi`, the selector disappears.

## Differences and how each is handled

Rows 13–17 come from ticket 01's read-only diff of the two dev5 images on pancake (`observations/01-summary.md` in the spec directory).

| # | Difference | Mechanism | Trade-off or open point |
|---|---|---|---|
| 1 | `m1n1-aurora` vs `m1n1-neo` | Image installs both; the update-m1n1 selector chooses at runtime | Needs Aurora's co-installable `m1n1-neo` (no `provides`/`conflicts=m1n1`). Paths are already separate: `/usr/lib/asahi-boot/m1n1.bin` and `/usr/lib/m1n1-neo/m1n1.bin`. Two m1n1s on disk until Aurora merges them |
| 2 | Stage 2 `boot.bin` | Image builds both (`esp/m1n1/boot.bin` for M1–M3, `esp/m1n1/boot-j700.bin` for the Neo); engine .33 lays out the ESP per board | Every download carries both (about 9.7 MB and 9.2 MB). Needs an engine and lock bump (ticket 07) |
| 3 | J700 Stage 1 `esp/aurora/stage1-j700.bin` | Image + engine `BOARD_STAGE1` (.32, unchanged) | 5000 ms proxy window |
| 4 | J613 Stage 1 `esp/aurora/stage1-j613.bin` | Image + engine `BOARD_STAGE1` (.32, unchanged) | 26.6.2 OS firmware only, 0 ms window; older firmware keeps asahi's Stage 1 |
| 5 | J700 U-Boot `/usr/lib/asahi-boot-j700/u-boot-nodtb.bin` | Image | Copied in by dev2, owned by no package; nothing else reads it. Aurora is asked to package it from a pinned commit (no public J700 U-Boot release exists) |
| 6 | `arm64.nowfxt` in `GRUB_CMDLINE_LINUX` | Image, every Mac | ID-register override; does nothing on a CPU without FEAT_WFxT (checked on M1–M3; ticket 09 rechecks on the J613). Under UEFI → Limine the load options replace the DT's `/chosen/bootargs`, so the flag must be on the cmdline. Can go once Aurora adds a T8140 quirk |
| 7 | MT7932 policy `/usr/lib/firmware/mediatek/mt7932/policy/{US,world-XZ}.bin` | Image | Only the mt7932 driver reads it. Redistribution in a public package is an open question for Aurora. With no global regdom, a Neo in a country with its own code has no matching policy and no world fallback |
| 8 | Bluetooth admit script and `omarchy-neo-bluetooth.service` | Image, gated on `ConditionFirmware=device-tree-compatible(apple,j700)` | Today its only condition is that `0000:01:00.1` exists, which on M1–M3 is the Broadcom Bluetooth function, so it runs and exits at the vendor check. The gate stops it starting at all |
| 9 | `WIRELESS_REGDOM="US"` | Removed | Stays stock, so M1–M3 owners outside the US keep their legal channels. Ticket 09 checks whether the Neo's 5 GHz needs a country |
| 10 | `/etc/default/update-m1n1` | Image: the selector replaces the Neo's fixed `M1N1=`/`U_BOOT=` lines | See row 13 for how it is placed |
| 11 | Stale `/usr/lib/asahi-boot-j700/m1n1.bin` (dev2's J700 Stage 2) | Removed | Superseded by `m1n1-neo` |
| 12 | Anything the build scripts don't record | Ticket 01 diff | Each finding became a row below |
| 13 | `/etc/default/update-m1n1` is in `omarchy-mac-boot`'s backup array, and the Neo build replaced it whole (dev2, then dev5's `cat >`), dropping the packaged `export LC_ALL=C` and the device-tree-overlay helper call | Image keeps the packaged lines byte for byte and appends one block that sources the selector | Any modification makes later `omarchy-mac-boot` upgrades write `update-m1n1.pacnew`, which is never applied. The prototype still installs a modified file, so this persists until the selector ships in `omarchy-mac-boot`. A separate file also keeps Aurora's `install-aurora-sep.sh` line edits off the selector |
| 14 | Neo build history: three extra kernel transactions (11.16, 11.35, 12.0), `m1n1-aurora` removed with `-Rdd`, `m1n1-neo` installed separately | Removed: build from stock 2026.09.26 in one pass, as `build5-m123.sh` does | Only `pacman.log` shows it. Package sets are otherwise identical (929 each) and `@factory` matches `@` in both images; no functional effect found |
| 15 | UKI `EFI/Linux/omarchy_linux-aurora.efi`: same size, different digest | Follows row 6 | The only cause is the embedded cmdline. `limine.conf` and `limine.conf.old` differ only in that cmdline and the UKI hash. One merged UKI serves every Mac |
| 16 | Neither image has `/etc/m1n1.conf` or a NetworkManager MT7932 MAC config (`/etc/NetworkManager/conf.d` holds only `omarchy-wifi-powersave.conf`) | Not a difference | `build5-m123.sh`'s `m1n1.conf` check passes because the file is missing. Aurora's RPM-only `80-aurora-neo-mt7932.conf` (permanent MAC on `mt7932-fullmac`) is offered for the support package; if the Neo needs a MAC setting, ticket 09 records it |
| 17 | **Unverified:** contents of the small `/etc` files stored inline (about 7,200 of 8,370, including `/etc/default/grub`, `/etc/default/limine`, `/etc/conf.d/wireless-regdom`, mkinitcpio and modprobe.d) and unowned paths in `/usr/lib` outside the boot and radio trees | Ticket 01 follow-up: one mounted read-only run, which needs sudo on pancake | `btrfs restore` (btrfs-progs v7.1) restores inline zstd extents as empty files, and its dry run prints no listing without the global `-v`. Path presence, larger-file digests, packages and enabled units were compared and match apart from the rows above. The Neo-specific small files came from deterministic heredocs and `sed` edits in the build scripts |
| — | Neo radio firmware and Touch ID calibration | Engine at install (.32, unchanged) | |
| — | Touch ID packages | First boot (`install-aurora-sep.sh`, unchanged) | |

## Engine .33

Ticket 04. These changes are in the working tree of `Engine/overlay/src/omarchy_asahi.py` on `mac/one-image-m123-neo`, uncommitted; the artifact `installer-v0.9.2-omarchy.33.tar.gz` and the `Engine/source-lock.json` bump are ticket 07 and are not done (the lock still names `v0.9.2-omarchy.32`).

- **`BOARD_STAGE2 = {"j700ap": "esp/m1n1/boot-j700.bin"}`**, beside `ESP_SOURCE = "esp"` and `ESP_STAGE2 = "esp/m1n1/boot.bin"`.
- **`esp_board_layout(device_class, members)`** is pure: it maps each payload `esp/…` member to its installed path relative to the ESP. On j700ap, `boot-j700.bin` becomes `m1n1/boot.bin` and the generic `boot.bin` is dropped. On every other board every `BOARD_STAGE2` file is dropped and the rest map unchanged, so a dev5 M1–M3 payload without the Neo file installs as before. On j700ap a missing `boot-j700.bin` raises `this image has no esp/m1n1/boot-j700.bin for the MacBook Neo`. A member outside `esp/` is refused.
- **`install_esp_board_layout(device_class, members, esp_root)`** applies the layout to the copied ESP with `os.replace` for moves and `os.unlink` for dropped members. The install step calls it right after `osins.install()` and `install_board_stage1`, before installer data is collected.
- **Preflight** runs the layout check before any disk change, beside the existing `read_board_stage1` check, and on j700ap also refuses an empty `boot-j700.bin`.
- **ESP verifier.** `_verify_copied_tree` takes its expected files for the `esp` source from the same layout, so installed evidence and the Recovery retry recheck agree. A dropped member left on the ESP fails (`installed tree holds a dropped member`), and a wrong `boot.bin` fails the byte comparison. The tree digest still hashes payload member names, so an identity-mapped (dev5) ESP keeps its digest.
- **Unchanged:** the template's `next_object == "m1n1/boot.bin"` check, `UNSUPPORTED_DEVICES = {"apple,j614s"}` in `omarchy_execution.py`, and the M4 refusal.
- **Not yet proven:** `os.replace` over an existing file on the macOS msdos ESP mount is expected to work but hasn't run on a device (ticket 09).

## The update-m1n1 selector

Ticket 03. Two files in `image-builder/one-image/`, uncommitted:

- **`update-m1n1.default`** becomes the image's `/etc/default/update-m1n1`. Its first 14 lines are `omarchy-mac-boot`'s packaged file byte for byte (`export LC_ALL=C` and the `dtb_overlays_update_m1n1` call, from omacom/omarchy-mac-pkgs `2dc0ad6c`). One appended block sources the selector, or exits 1 if the selector is missing.
- **`update-m1n1-board`** installs at `/usr/lib/omarchy-mac-image/update-m1n1-board`, unowned until a package adopts it. It reads `/proc/device-tree/compatible` (NUL-separated):
  - `apple,j614s` is refused first, because it carries a supported M3 SoC compatible.
  - `apple,j700` sets `M1N1=/usr/lib/m1n1-neo/m1n1.bin` and `U_BOOT=/usr/lib/asahi-boot-j700/u-boot-nodtb.bin`.
  - `apple,t8103`, `t6000`, `t6001`, `t6002`, `t8112`, `t6020`, `t6021`, `t6022`, `t8122`, `t6030`, `t6031` or `t6034` keeps update-m1n1's defaults (`m1n1-aurora` and `uboot-asahi`).
  - Anything else (missing or empty device tree, M4 SoCs, near misses) prints the reason to stderr and runs an explicit `exit 1`.
  - `DTBS` comes from `pacman -Qlq linux-aurora`, as Aurora's installer sets it, and only when nothing (a caller or the overlay helper) has set it already. For M1–M3 without overlays this differs from dev5, which used update-m1n1's newest `-ARCH` module directory default.
  - `OMARCHY_M1N1_BOARD=j700|m123` skips detection, for the image build's chroot only (where `/proc/device-tree` belongs to the build host). Any other value is refused. `OMARCHY_DT_COMPATIBLE` redirects detection for tests.

**Why a separate file.** `install-aurora-sep.sh` edits `/etc/default/update-m1n1` line by line: it deletes `^DTBS=` lines and, on a Neo with `NEO_AURORA_M1N1=1`, indented `M1N1=` lines, then appends its own. Keeping the selection in a sourced file keeps those edits off it; the lines it appends land after the selector and agree with it.

**Why POSIX sh.** The repository's shell rule is Bash 5 with `[[ ]]`, but both files are sourced by `#!/bin/sh` update-m1n1 and by `sh -c` probes in `install-aurora-sep.sh` and `omarchy-apple-silicon-boot-check`. `/bin/sh` is Bash on Arch but need not be; under dash a `[[` would fail as "command not found" and could choose the wrong m1n1. So they use `[ ]` and `case` only. The test file is Bash as usual.

**Refusal behaviour.** asahi-scripts `update-m1n1` (tag `20260127.1`) is `#!/bin/sh` with `set -e` and sources `/etc/default/update-m1n1` with `.` before it writes `boot.bin.new` or `boot.bin`. An `exit 1` in the sourced file, or in a file it sources, ends update-m1n1 there, so the old `boot.bin` stays. The selector's last command always returns 0 on success, so errexit never ends a good run. A failing pacman hook doesn't fail the transaction; the selector's message explains it. `omarchy-apple-silicon-boot-check` reads the config in a clean shell and fails closed with "cannot read" on a refused board.

**Test.** `test/shell.d/update-m1n1-selector-test.sh`, wired into `test/all`, runs 52 checks under `sh`, `dash` and `bash` against fake compatible files (j700, j314s, j613, j614s, t8132, `apple,t8140x`, empty, missing), the override, `DTBS` handling with a stubbed `pacman`, the packaged-prefix hash, and update-m1n1's sourcing lines reproduced exactly. It uses only `mktemp` files and needs no privilege.

## How `pacman -Syu` keeps the right m1n1

The only hook that runs update-m1n1 is asahi-scripts' `95-m1n1-install.hook`, which fires on `usr/lib/modules/*/dtbs/*` and `usr/lib/asahi-boot/*`. Neither m1n1 package nor `linux-aurora` ships its own hook.

| Update | M1–M3 (including J613) | MacBook Neo | Unsupported board (e.g. a chroot with no device tree) |
|---|---|---|---|
| `linux-aurora` (new DTBs) | Hook fires; selector keeps `m1n1-aurora` and `uboot-asahi`; `boot.bin` rebuilt | Hook fires; selector picks `m1n1-neo` and the J700 U-Boot; `boot.bin` rebuilt | Hook fires; selector refuses; old `boot.bin` stays |
| `m1n1-aurora` or `uboot-asahi` | Hook fires through `usr/lib/asahi-boot/*`; rebuilt | Hook fires; selector still picks `m1n1-neo`, so the Neo `boot.bin` is rebuilt unchanged in substance | Refuses; unchanged |
| `m1n1-neo` | Nothing fires today | **Nothing fires today:** the Neo keeps its old Stage 2 until the next kernel update | Nothing fires |
| J700 U-Boot (once packaged) | Nothing fires today | **Nothing fires today**, same gap | Nothing fires |
| `omarchy-mac-boot` | `/etc/default/update-m1n1` is modified, so the upgrade writes `update-m1n1.pacnew` and the live file stays (row 13) | Same | Same |

The hook gap closes when Aurora adds matching hooks on `usr/lib/m1n1-neo/*` (in `m1n1-neo`) and `usr/lib/asahi-boot-j700/*` (in the support package). Whichever hook fires, the selector decides, so a Neo m1n1 update never changes an M1–M3 `boot.bin`, and the other way round. If one transaction fires two hooks, update-m1n1 runs twice, which is noisy but idempotent.

- **Factory reset:** the image is identical on every Mac, so a reset carries no stale per-board state and needs no migration.
- **Existing dev5 installs:** M1–M3 are unchanged. A dev5 Neo keeps its fixed config, which is still correct, and can move to the selector once Aurora ships the co-installable `m1n1-neo`.

## Upstream asks

Ticket 02; the draft for Chris is `.scratch/one-image-m123-neo/aurora-asks.md` and has not been sent. In priority order:

1. **Co-installable `m1n1-neo`:** drop `provides=m1n1` and `conflicts=m1n1`, add `depends=asahi-scripts` as `m1n1-aurora` has, keep `/usr/lib/m1n1-neo/m1n1.bin` and the `ESP_STAGE2` `build-config.h` marker, and ship a `95-m1n1-neo-install.hook` on `usr/lib/m1n1-neo/*`. `linux-aurora`'s `m1n1>=1.6.1.aurora15` and `omarchy-mac-boot`'s `m1n1` dependencies stay met by `m1n1-aurora`.
2. **A Neo support package** (for example `aurora-j700-support`): the J700 U-Boot built from a pinned commit plus its hook, the MT7932 policy files (if redistributable), the Bluetooth admit script under `/usr/lib` and its device-tree-gated unit, and optionally Ryan's `80-aurora-neo-mt7932.conf`.
3. **Optional:** a MIDR-keyed T8140 WFxT quirk in the kernel, so `arm64.nowfxt` can come off the command line.
4. **Long term:** one m1n1 that boots all four families, so only the U-Boot differs per board.

The image also needs `omarchy-mac-boot` (omacom/omarchy-mac-pkgs) to adopt the selector, so the image stops modifying its backup file.

## Build script

Ticket 05: `image-builder/one-image/build6-m123-neo.sh`, written but not yet run. It starts from `build5-m123.sh` (stock 2026.09.26 edge base, one pass) and installs `m1n1-neo` beside `m1n1-aurora`, refusing a package whose `.PKGINFO` still declares `conflict`, `provides` or `replaces` `= m1n1`. It adds the J700 U-Boot, both Stage 1s, the MT7932 policy, the gated Bluetooth unit (`/usr/lib/aurora-j700/bluetooth-admit`, `aurora-j700-bluetooth.service`), `arm64.nowfxt` and the selector, after checking that the image's `/etc/default/update-m1n1` is `omarchy-mac-boot`'s unmodified file. It skips `WIRELESS_REGDOM` and the stale J700 `m1n1.bin`. It runs update-m1n1 with `OMARCHY_M1N1_BOARD=j700` (moved to `esp/m1n1/boot-j700.bin`) and then `=m123` (`esp/m1n1/boot.bin`).

Post-checks: each `boot.bin` starts with its m1n1, carries the required device trees and ends with the right gzipped U-Boot; Stage 1 and selector digests match; sourcing the config refuses the build host's generic device tree; the Bluetooth gate is present; `wireless-regdom` is stock; no snapshots were created. Outputs are `omarchy-2026.10.11-aarch64-apple-silicon-mac-edge-m123-neo-os-package.zip` and three metadata files (`installer_data-m123-neo.json`, `-j613.json` with `["26.6.2"]`, `-j700.json`). The `m1n1-neo` inputs are `TICKET-02-PLACEHOLDER` values and the script refuses to start until they're filled. Running it is ticket 08.

Known gaps: the J700 pieces are copied in without a package owning them, so a Mac that later installs `aurora-j700-support` hits pacman's "exists in filesystem" error unless the package takes them over. `/etc/default/update-m1n1` and `/etc/default/grub` end up modified, so upgrades write `.pacnew` files. The Bluetooth script doesn't yet check for the per-unit calibration files, because their installed path hasn't been confirmed.

## Test plan

- **Engine (ticket 04):** `py_compile`, plus focused tests in `Engine/overlay/tests/test_omarchy_asahi.py` (`EspBoardLayoutTests` and adapter tests): the layout for j700ap, j613ap and j314s; a Neo payload without, or with an empty, `boot-j700.bin` refused at preflight with no disk change; the verifier accepting the transformed ESP and rejecting a wrong `boot.bin` or a leftover `boot-j700.bin`; dev5 back-compat on j613ap and j314s. `test_omarchy_runtime.py` checks that j614s and an M4 inspected as unsupported get no layout; `test_omarchy_execution.py::test_m4_is_rejected_even_with_otherwise_valid_binding` still passes unchanged.
- **Selector (ticket 03):** the shell test above.
- **Whole suite:** `./test/all` must pass and stay unprivileged. It currently stops at `Engine/tests` (`test_verify_source_lock`) because the edited engine files no longer match `Engine/source-lock.json`; that clears with the ticket 07 lock refresh, after which one green run on the exact candidate commit is owed. Run it with a Python 3.10+ first on PATH; the system 3.9.6 can't run the overlay suite.
- **Engine artifact (ticket 07):** reproducible build, `verify-source-lock.py` and `verify-archive-modes.py`, and Swift tests in debug and release if the app pins the engine.
- **Build (ticket 08):** every post-check passes, `e2fsck -fn` and `btrfs check --readonly` are clean, and the catalog builds from the three metadata files with neither `apple,j614s` nor any M4 board in it.
- **Physical (ticket 09):** M1 or M2; the 13-inch M3 Air (J613) on 26.6.2; the Neo. Each records the image digest, engine version, macOS build and firmware, and checks the installed `boot.bin`, boot, Wi-Fi/Bluetooth/WFxT/regdom behaviour, a kernel update rebuilding the right `boot.bin`, and update-m1n1 refusing with the device tree hidden. The installer must still refuse `apple,j614s` and M4. A source test is not physical proof.
- **Ticket 01 follow-up:** the mounted read-only diff that closes row 17.

## Authorization boundary

Source edits, pure tests and writing the prototype are local and reversible. The read-only pancake diff (ticket 01) was authorized. Each of these needs Scott's explicit OK at the time: the mounted (sudo) pancake read, building on pancake as root, the engine lock change, signing, notarizing, publishing, and any Mac install. `apple,j614s` and M4 or later stay fail-closed until official support and physical qualification both exist.
