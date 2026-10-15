#!/bin/bash
# Derive the one developer image for M1, M2 and M3 Macs and the MacBook Neo
# (apple,j700) from the stock 2026.09.26 edge image, in one pass: install Aurora
# 2026.10.11.14's kernel (omacom/linux-aurora) with both of Aurora's m1n1 Stage
# 2s side by side, m1n1-aurora for M1-M3 and a co-installable m1n1-neo for the
# Neo, then rebuild the UKI, the Limine menu and two Stage 2s:
# esp/m1n1/boot.bin (m1n1-aurora, uboot-asahi) and esp/m1n1/boot-j700.bin
# (m1n1-neo, the J700 U-Boot). Engine .33 puts boot-j700.bin in place of
# boot.bin on a j700ap and drops it everywhere else. The ESP carries both
# unfilled Aurora Stage 1s, esp/aurora/stage1-j613.bin (13-inch M3 Air on
# 26.6.2) and esp/aurora/stage1-j700.bin, which engine .32 fills per board.
#
# Every Neo-only piece is inert on other Macs: the J700 U-Boot and the MT7932
# regulatory policy are files only the Neo's chain reads, the Bluetooth
# admission unit is gated on the J700 device tree, and arm64.nowfxt does nothing
# on a core without FEAT_WFxT. /etc/default/update-m1n1 stays omarchy-mac-boot's
# packaged file plus one block that sources the board selector
# (/usr/lib/omarchy-mac-image/update-m1n1-board), so every later update-m1n1
# run picks this Mac's m1n1 and U-Boot from the live device tree, or refuses
# and leaves boot.bin alone. Unlike the dev5 Neo image there is no global
# WIRELESS_REGDOM and no stale /usr/lib/asahi-boot-j700/m1n1.bin.
#
# Not runnable yet: m1n1-neo must come from an Aurora release that no longer
# provides or conflicts with m1n1 (ticket 02, aurora-asks.md). Fill in the
# TICKET-02 values below when it ships; until then the script stops at once.
# Until Aurora packages the Neo support files (aurora-j700-support), the J700
# U-Boot, the MT7932 policy and the Bluetooth unit are copied in unowned.
#
# Run as root on an aarch64 Arch Linux host: sudo bash ~/neo-build/build6-m123-neo.sh
# Inputs come from ~/neo-build/in; the result lands in ~/neo-build/out. The
# board selector's two files sit next to this script (image-builder/one-image).
# Every mount lives in a private mount namespace and disappears on exit.
set -euo pipefail

STOCK_ZIP=omarchy-2026.09.26-aarch64-apple-silicon-mac-edge-os-package.zip
STOCK_SHA256=6e7959cda3a6d4eef833a132e81d6c63395074a3f0efe4c7d242c6bd3011fe79
OUT_ZIP=omarchy-2026.10.11-aarch64-apple-silicon-mac-edge-m123-neo-os-package.zip
RELEASE_URL=https://github.com/omacom/linux-aurora/releases/download/aurora-2026.10.11.14
KERNEL_VERSION=7.1.12.aurora2-20261011.14
MODULES_VERSION=7.1.12-2-20261011.14-sep-ARCH
M1N1_PACKAGE=m1n1-aurora-1.6.1.aurora17-5-aarch64.pkg.tar.zst
# The m1n1.bin inside it; Aurora's installer reports the same digest.
M1N1_SHA256=396cf3ec1774ca9d15ca1b6f71b5e8a3639b27f80b95d530722b35a5ea35141d
# ---- TICKET-02 placeholders: Aurora's co-installable m1n1-neo. ----
# The release that ships it (it may also carry a newer kernel; if so, move the
# kernel pins above to it), the package file, GitHub's asset digest for it, and
# the digest of /usr/lib/m1n1-neo/m1n1.bin inside it (Aurora's installer
# reports the same). dev5's m1n1-neo-1.6.1.aurora16.neo.20261009-10 still
# conflicts with m1n1 and cannot be used.
M1N1_NEO_RELEASE_URL=TICKET-02-PLACEHOLDER-release-url
M1N1_NEO_PACKAGE=TICKET-02-PLACEHOLDER-m1n1-neo-aarch64.pkg.tar.zst
M1N1_NEO_PACKAGE_SHA256=TICKET-02-PLACEHOLDER-package-sha256
M1N1_NEO_SHA256=TICKET-02-PLACEHOLDER-m1n1-bin-sha256
# GitHub's published asset digests: file, digest, release.
PACKAGES=(
  "linux-aurora-$KERNEL_VERSION-aarch64.pkg.tar.zst ea2dd7b92f90ddc4411932b5fff25ac1209509ddfb2986222ee5ee3bfe15d9be $RELEASE_URL"
  "linux-aurora-headers-$KERNEL_VERSION-aarch64.pkg.tar.zst 3c5eaf403820d74f7bfde4592d04aa2c7c246d7e53521f5e3e6866b8c2be877c $RELEASE_URL"
  "$M1N1_PACKAGE fd72ec6c7ff514a2fb17141ccd8ff94268e4412fc5660fb0db62564a036e30ca $RELEASE_URL"
  "$M1N1_NEO_PACKAGE $M1N1_NEO_PACKAGE_SHA256 $M1N1_NEO_RELEASE_URL"
)
# Satya's unfilled v1.6.1-m3next.stage1 (aurora-silicon/m1n1 a7f0b4583150), in
# $in/j613. It boots only a J613 on 26.6.2 OS firmware and stays in proxy mode
# anywhere else; engine .32 fills it with the ESP and a 0 ms proxy window.
J613_STAGE1=m1n1-j613-stage1-v1.6.1-m3next.stage1.bin
J613_STAGE1_SHA256=2cc65ed4dc01c3a7ae26846b1e330f463d5f9c27d5f74ecc80a5c7ff8dc6cc38
# The J700 boot binaries in $in/j700 (also listed in its SHA256SUMS), as dev2
# installed them and dev5 shipped them: the unfilled J700 Stage 1, which engine
# .32 fills with a 5000 ms window, and aurora-silicon/u-boot j700. dev2's J700
# m1n1 Stage 2 (m1n1-j700-stage2.bin) is superseded by m1n1-neo and not used.
J700_STAGE1=m1n1-j700-stage1.bin
J700_STAGE1_SHA256=68851212af8e3bc4ad30f7c9ddf6a3f6e83fb10383737172282c3150db288257
J700_UBOOT=u-boot-j700-nodtb.bin
J700_UBOOT_SHA256=3b80e484ae0af137043c2e1ab9a333655b0916d4c5a15483908cf6e2f18c1092
# MT7932 Wi-Fi regulatory policy from Chris, in $in/mt7932-policy, as the third
# Neo image installed it: world-XZ.bin from his policy bundle, US.bin his
# 5-record rebuild for the stock parser.
POLICY=(
  "US.bin 9e519590d4a66972cfd7909132f3567c7b47a5252f89d345c1e7083a7d5bb9fe"
  "world-XZ.bin cbc887013ca6cc31ea1a326cba485a2c89c70ad6d3f85bbf4bbda65f60ebb97b"
)
# The board selector (ticket 03), next to this script. Update these digests
# whenever either file changes. The first 14 lines of update-m1n1.default are
# omarchy-mac-boot's packaged /etc/default/update-m1n1 (omacom/omarchy-mac-pkgs
# 2dc0ad6), and the image's own copy must still be exactly that.
SELECTOR_SHA256=a218059dcde01e5df78ccede5e324e7b0636d48d39151e516ccc020dd5d396f5
DEFAULT_SHA256=22d5be1aa5500b7bab49373fe998df7baa04f55352d80eb62886ff0f2ad35257
PACKAGED_DEFAULT_LINES=14
PACKAGED_DEFAULT_SHA256=2dc3d768210e78a0ee258703c81d28389f9e00df96509acdc5f40449b4a78a33
# Macs whose device trees must reach both Stage 2s: an M1, M1 Pro, M2, M2 Pro,
# M3 and M3 Pro model each (the Neo's is checked on its own).
REQUIRED_TREES=(j293 j313 j314s j413 j414s j613 j516s)
# supported_fw for the three descriptions of the one payload. The J700 list is
# dev5's Neo file (installer_data-dev5.json) unchanged.
J613_FW='["26.6.2"]'
J700_FW='["13.5", "14.8.3", "26.6"]'

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mneo-build: %s\033[0m\n' "$*" >&2; exit 1; }
sha() { sha256sum "$1" | cut -d' ' -f1; }

(( EUID == 0 )) || fail "run with sudo"
[[ $(uname -m) == "aarch64" ]] || fail "this needs an aarch64 host"
for value in "$M1N1_NEO_RELEASE_URL" "$M1N1_NEO_PACKAGE" "$M1N1_NEO_PACKAGE_SHA256" "$M1N1_NEO_SHA256"; do
  [[ $value != *TICKET-02* ]] || fail "fill in Aurora's co-installable m1n1-neo (ticket 02) before building: $value"
done
script_dir=$(dirname "$(readlink -f "$0")")
selector=$script_dir/update-m1n1-board
default=$script_dir/update-m1n1.default
owner=${SUDO_USER:-root}
home=$(getent passwd "$owner" | cut -d: -f6)
base=$home/neo-build
in=$base/in
work=$base/work
out=$base/out
logs=$base/logs

if [[ ${1:-} != --inside ]]; then
  for tool in bsdtar losetup btrfs e2fsck unshare python3 curl sha256sum md5sum mkfs.vfat fsck.vfat; do
    command -v "$tool" >/dev/null || fail "missing $tool"
  done
  [[ ! -e $out/$OUT_ZIP ]] || fail "$out/$OUT_ZIP already exists; move it away to rebuild"
  mkdir -p "$in/pkgs" "$work" "$out" "$logs"
  say "Fetching Aurora's $KERNEL_VERSION kernel and both m1n1s"
  for entry in "${PACKAGES[@]}"; do
    read -r file digest url <<<"$entry"
    if [[ ! -f $in/pkgs/$file ]]; then
      curl -fL --retry 3 --progress-bar -o "$in/pkgs/$file.part" "$url/$file"
      mv "$in/pkgs/$file.part" "$in/pkgs/$file"
    fi
    [[ $(sha "$in/pkgs/$file") == "$digest" ]] || fail "$file does not match GitHub's digest"
  done
  say "Checking the stock image, both m1n1 packages, the boot binaries and the selector"
  [[ $(sha "$in/$STOCK_ZIP") == "$STOCK_SHA256" ]] || fail "$STOCK_ZIP does not match its digest"
  bsdtar -xOf "$in/pkgs/$M1N1_PACKAGE" usr/lib/asahi-boot/m1n1.bin >"$work/m1n1.bin"
  [[ $(sha "$work/m1n1.bin") == "$M1N1_SHA256" ]] || fail "$M1N1_PACKAGE's m1n1.bin does not match Aurora's digest"
  # m1n1-neo must install beside m1n1-aurora: pacman --noconfirm will not
  # remove a conflicting package, and both still claiming m1n1 would make
  # pacman -U stop (or, answered differently, drop m1n1-aurora).
  bsdtar -xOf "$in/pkgs/$M1N1_NEO_PACKAGE" .PKGINFO >"$work/m1n1-neo.PKGINFO"
  grep -qx 'pkgname = m1n1-neo' "$work/m1n1-neo.PKGINFO" || fail "$M1N1_NEO_PACKAGE is not m1n1-neo"
  if grep -Eq '^(conflict|provides|replaces) = m1n1([<>=].*)?$' "$work/m1n1-neo.PKGINFO"; then
    grep -E '^(conflict|provides|replaces) = ' "$work/m1n1-neo.PKGINFO" >&2
    fail "$M1N1_NEO_PACKAGE still provides, conflicts with or replaces m1n1, so it cannot sit beside m1n1-aurora; wait for Aurora's co-installable build (ticket 02)"
  fi
  # Listed to a file first: grep -q closing a pipe early would turn bsdtar's
  # SIGPIPE into a failure that the ! hides under pipefail.
  bsdtar -tf "$in/pkgs/$M1N1_NEO_PACKAGE" >"$work/m1n1-neo.list"
  ! grep -q '^usr/lib/asahi-boot/' "$work/m1n1-neo.list" ||
    fail "$M1N1_NEO_PACKAGE ships files under usr/lib/asahi-boot, which m1n1-aurora owns"
  bsdtar -xOf "$in/pkgs/$M1N1_NEO_PACKAGE" usr/lib/m1n1-neo/m1n1.bin >"$work/m1n1-neo.bin"
  [[ $(sha "$work/m1n1-neo.bin") == "$M1N1_NEO_SHA256" ]] || fail "$M1N1_NEO_PACKAGE's m1n1.bin does not match Aurora's digest"
  bsdtar -xOf "$in/pkgs/$M1N1_NEO_PACKAGE" usr/share/m1n1-neo/build-config.h >"$work/m1n1-neo.build-config.h"
  grep -qx '#define ESP_STAGE2' "$work/m1n1-neo.build-config.h" ||
    fail "$M1N1_NEO_PACKAGE is not an ESP Stage 2 build"
  ! cmp -s "$work/m1n1.bin" "$work/m1n1-neo.bin" || fail "m1n1-aurora and m1n1-neo carry the same m1n1.bin"
  [[ $(sha "$in/j613/$J613_STAGE1") == "$J613_STAGE1_SHA256" ]] || fail "$J613_STAGE1 does not match its digest"
  (cd "$in/j700" && sha256sum -c --quiet SHA256SUMS) || fail "the J700 boot binaries do not match SHA256SUMS"
  [[ $(sha "$in/j700/$J700_STAGE1") == "$J700_STAGE1_SHA256" ]] || fail "$J700_STAGE1 does not match dev5's J700 Stage 1"
  [[ $(sha "$in/j700/$J700_UBOOT") == "$J700_UBOOT_SHA256" ]] || fail "$J700_UBOOT does not match dev5's J700 U-Boot"
  for entry in "${POLICY[@]}"; do
    read -r file digest <<<"$entry"
    [[ $(sha "$in/mt7932-policy/$file") == "$digest" ]] || fail "policy $file does not match its digest"
  done
  [[ $(sha "$selector") == "$SELECTOR_SHA256" ]] || fail "$selector does not match its digest"
  [[ $(sha "$default") == "$DEFAULT_SHA256" ]] || fail "$default does not match its digest"
  [[ $(head -n "$PACKAGED_DEFAULT_LINES" "$default" | sha256sum | cut -d' ' -f1) == "$PACKAGED_DEFAULT_SHA256" ]] ||
    fail "$default does not start with omarchy-mac-boot's packaged file"
  [[ -s $in/installer_data.json ]] || fail "missing $in/installer_data.json"
  # A run that stopped early can leave a loop device on its work files.
  while read -r stale; do
    [[ -n $stale ]] && losetup -d "$stale" && say "Detached leftover $stale"
  done < <(losetup -n -O NAME,BACK-FILE --list | awk '$2 ~ /neo-build\/work\/(image\/(root|boot)|esp)\.img$/ { print $1 }')
  say "Unpacking the stock image (about 15 GB)"
  rm -rf "$work/image"
  mkdir -p "$work/image"
  bsdtar -xf "$in/$STOCK_ZIP" -C "$work/image"
  # Limine's tools only work on a real FAT32 ESP, made as build-mac-image makes it.
  rm -f "$work/esp.img"
  truncate -s 524288000 "$work/esp.img"
  mkfs.vfat -F 32 -n OMARCHYESP -i 4f4d5801 "$work/esp.img" >/dev/null
  unshare --mount --propagation private "$BASH" "$0" --inside 2>&1 | tee "$logs/build.log"
  (( PIPESTATUS[0] == 0 )) || fail "the build failed; see $logs/build.log"

  say "Checking the filesystems"
  e2fsck -fn "$work/image/boot.img" >/dev/null || fail "boot.img does not check clean"
  btrfs check --readonly "$work/image/root.img" >"$logs/btrfs-check.log" 2>&1 || fail "root.img does not check clean"

  say "Packaging $OUT_ZIP (several minutes)"
  (cd "$work/image" && bsdtar --format zip -cf "$out/$OUT_ZIP.part" esp boot.img root.img omarchy-volume.icns)
  mv "$out/$OUT_ZIP.part" "$out/$OUT_ZIP"
  # Three descriptions of the one payload: every M1-M3 Mac on its usual stub
  # firmware, the 13-inch M3 Air on a 26.6.2 stub, and the MacBook Neo.
  python3 - "$in/installer_data.json" "$out" "$OUT_ZIP" "$J613_FW" "$J700_FW" <<'PY'
import json, os, sys
source, out, name, j613_fw, j700_fw = sys.argv[1:]
for target, firmware in (("installer_data-m123-neo.json", None),
                         ("installer_data-m123-neo-j613.json", json.loads(j613_fw)),
                         ("installer_data-m123-neo-j700.json", json.loads(j700_fw))):
    data = json.load(open(source))
    entry = data["os_list"][0]
    entry["package"] = name
    if firmware:
        entry["supported_fw"] = firmware
    elif "26.6" not in entry["supported_fw"]:
        entry["supported_fw"].append("26.6")
    open(os.path.join(out, target), "w").write(json.dumps(data, indent=2) + "\n")
PY
  (cd "$out" && sha256sum "$OUT_ZIP" installer_data-m123-neo.json installer_data-m123-neo-j613.json installer_data-m123-neo-j700.json | tee SHA256SUMS-m123-neo &&
    stat -c '%s %n' "$OUT_ZIP" installer_data-m123-neo.json installer_data-m123-neo-j613.json installer_data-m123-neo-j700.json)
  chown -R "$owner:" "$base"
  rm -rf "$work/image"
  say "Done: $out"
  exit 0
fi

# ---- Inside a private mount namespace from here on. ----
target=$work/target
top=$work/top
mkdir -p "$target" "$top"
loops=()
cleanup() {
  local loop
  umount -R "$target" 2>/dev/null || true
  umount -R "$top" 2>/dev/null || true
  for loop in "${loops[@]}"; do losetup -d "$loop" 2>/dev/null || true; done
}
trap cleanup EXIT

root_loop=$(losetup --find --show "$work/image/root.img"); loops+=("$root_loop")
boot_loop=$(losetup --find --show "$work/image/boot.img"); loops+=("$boot_loop")
mount -o compress=zstd "$root_loop" "$top"
for subvolume in @ @home @log @pkg @factory; do
  [[ -d $top/$subvolume ]] || fail "root.img has no $subvolume"
done
mount -o subvol=@,compress=zstd "$root_loop" "$target"
mount -o subvol=@home,compress=zstd "$root_loop" "$target/home"
mount -o subvol=@log,compress=zstd "$root_loop" "$target/var/log"
mount -o subvol=@pkg,compress=zstd "$root_loop" "$target/var/cache/pacman/pkg"
mount "$boot_loop" "$target/boot"
mkdir -p "$target/boot/efi"
esp_loop=$(losetup --find --show "$work/esp.img"); loops+=("$esp_loop")
mount -t vfat -o umask=0077 "$esp_loop" "$target/boot/efi"
cp -rT --preserve=timestamps "$work/image/esp" "$target/boot/efi"
# asahi-scripts' builder marker keeps update-m1n1 on this ESP.
: >"$target/boot/efi/.builder"

# The build host's hardware never reaches the image, as in build-mac-image:
# a generic Apple Silicon device tree, UEFI without variables, no PCI, USB,
# input or DMI devices. The selector refuses this device tree, so every
# update-m1n1 run below names its board with OMARCHY_M1N1_BOARD.
mount -t proc -o nosuid,noexec,nodev proc "$target/proc"
mount -t sysfs -o nosuid,noexec,nodev,ro sysfs "$target/sys"
mount -t tmpfs -o mode=0755,nosuid,noexec,nodev,size=1m tmpfs "$target/sys/firmware"
mkdir -p "$target/sys/firmware/devicetree/base" "$target/sys/firmware/efi/efivars"
printf '%s\0' apple,arm-platform >"$target/sys/firmware/devicetree/base/compatible"
printf 'Omarchy image (apple-silicon)\0' >"$target/sys/firmware/devicetree/base/model"
for point in sys/class/dmi sys/devices/virtual/dmi sys/bus/pci sys/bus/usb sys/class/input proc/bus/pci proc/bus/input; do
  [[ -d $target/$point ]] || continue
  mount -t tmpfs -o mode=0755,nosuid,noexec,nodev,size=64k tmpfs "$target/$point"
  [[ $point != sys/bus/* ]] || mkdir -p "$target/$point/devices" "$target/$point/drivers"
done
mount -t tmpfs -o mode=0755,nosuid tmpfs "$target/dev"
mkdir -p "$target/dev/pts" "$target/dev/shm"
mount -t devpts -o mode=0620,gid=5,nosuid,noexec devpts "$target/dev/pts"
mount -t tmpfs -o mode=1777,nosuid,nodev tmpfs "$target/dev/shm"
for node in null zero random urandom tty; do
  touch "$target/dev/$node"
  mount --bind "/dev/$node" "$target/dev/$node"
done
ln -s /proc/self/fd "$target/dev/fd"
ln -s /proc/self/fd/0 "$target/dev/stdin"
ln -s /proc/self/fd/1 "$target/dev/stdout"
ln -s /proc/self/fd/2 "$target/dev/stderr"
mount -t tmpfs -o mode=0755,nosuid,noexec tmpfs "$target/run"
mkdir -m 0755 -p "$target/run/lock" "$target/run/systemd/resolve"
mount -t tmpfs -o mode=1777,strictatime,nodev,nosuid tmpfs "$target/tmp"
# DNS for pacman, whether the image links resolv.conf to resolved or not.
upstream=/run/systemd/resolve/resolv.conf
[[ -s $upstream ]] || upstream=/etc/resolv.conf
cp -L "$upstream" "$target/run/systemd/resolve/resolv.conf"
cp -L "$upstream" "$target/run/systemd/resolve/stub-resolv.conf"
if [[ ! -L $target/etc/resolv.conf ]]; then
  touch "$target/etc/resolv.conf"
  mount --bind "$target/run/systemd/resolve/resolv.conf" "$target/etc/resolv.conf"
fi
mkdir -p "$target/tmp/neo-pkgs"
mount --bind -o ro "$in/pkgs" "$target/tmp/neo-pkgs"

guest() {
  unshare --pid --fork --mount-proc="$target/proc" chroot "$target" \
    env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/bin HOME=/root TERM=dumb LANG=C.UTF-8 \
    SNAP_PAC_SKIP=y "$@"
}
# True when the last gzip member of $1 inflates to exactly $2's bytes: how
# update-m1n1 appends U-Boot after m1n1 and the device trees. Only m1n1's
# text options (chosen.*, display=, mitigations= from /etc/m1n1.conf) may
# follow it.
ends_with_gzip_of() {
  python3 - "$1" "$2" <<'PY'
import sys, zlib
blob = open(sys.argv[1], "rb").read()
want = open(sys.argv[2], "rb").read()
at = len(blob)
while True:
    at = blob.rfind(b"\x1f\x8b\x08", 0, at)
    if at < 0:
        sys.exit(1)
    inflater = zlib.decompressobj(31)
    try:
        got = inflater.decompress(blob[at:])
    except zlib.error:
        continue
    tail = inflater.unused_data
    text = all(32 <= byte < 127 or byte == 10 for byte in tail)
    if inflater.eof and got == want and (not tail or (text and tail.endswith(b"\n"))):
        sys.exit(0)
PY
}

boot_bin=$target/boot/efi/m1n1/boot.bin
boot_j700=$target/boot/efi/m1n1/boot-j700.bin
policy_dir=$target/usr/lib/firmware/mediatek/mt7932/policy
bt_admit=/usr/lib/aurora-j700/bluetooth-admit
bt_unit=aurora-j700-bluetooth.service

say "Before"
guest pacman -Q linux-aurora m1n1-aurora || true
old_modules=$(ls "$target/usr/lib/modules")
echo "modules: $old_modules"
snapshots_before=$(btrfs subvolume list -o "$target" 2>/dev/null | awk '{print $NF}' | sort)
grep -n "^GRUB_CMDLINE_LINUX=" "$target/etc/default/grub"
regdom_before=absent
[[ ! -e $target/etc/conf.d/wireless-regdom ]] || regdom_before=$(sha "$target/etc/conf.d/wireless-regdom")
echo "wireless-regdom: $regdom_before"
[[ ! -e $target/usr/lib/asahi-boot-j700 && ! -e $target/usr/lib/m1n1-neo ]] || fail "the stock image already carries Neo boot files"

say "Checking /etc/default/update-m1n1 is omarchy-mac-boot's packaged file"
# The selector goes in beside the packaged lines, not over them, so the
# image's file must be the unmodified backup file the selector's first lines
# reproduce: same md5 as pacman's backup record, same bytes as our prefix.
[[ $(guest pacman -Qoq /etc/default/update-m1n1) == "omarchy-mac-boot" ]] || fail "omarchy-mac-boot does not own /etc/default/update-m1n1"
mac_boot=$(guest pacman -Q omarchy-mac-boot | tr ' ' '-')
backup_md5=$(awk '/^%BACKUP%$/ { b = 1; next } /^%/ { b = 0 } b && $1 == "etc/default/update-m1n1" { print $2 }' \
  "$target/var/lib/pacman/local/$mac_boot/files")
[[ -n $backup_md5 ]] || fail "$mac_boot does not list /etc/default/update-m1n1 as a backup file"
[[ $(md5sum "$target/etc/default/update-m1n1" | cut -d' ' -f1) == "$backup_md5" ]] ||
  fail "the image's /etc/default/update-m1n1 is not $mac_boot's packaged file"
cmp -s "$target/etc/default/update-m1n1" <(head -n "$PACKAGED_DEFAULT_LINES" "$default") ||
  fail "the image's packaged /etc/default/update-m1n1 differs from the first $PACKAGED_DEFAULT_LINES lines of $default; rebase the selector on it"
! grep -qE '^[[:space:]]*(export[[:space:]]+)?(M1N1|U_BOOT|SOURCE|TARGET|CONFIG)=' "$target/etc/default/update-m1n1" ||
  fail "/etc/default/update-m1n1 points update-m1n1 at its own files"
! grep -q '^chosen\.' "$target/etc/m1n1.conf" 2>/dev/null || fail "/etc/m1n1.conf arms switches"

say "Installing Aurora's $KERNEL_VERSION kernel, m1n1-aurora and m1n1-neo"
# One transaction. asahi-scripts' hook rebuilds boot.bin from the stock
# configuration here (m1n1-aurora); both Stage 2s are rebuilt below anyway.
install=(/tmp/neo-pkgs/linux-aurora-"$KERNEL_VERSION"-aarch64.pkg.tar.zst /tmp/neo-pkgs/"$M1N1_PACKAGE" /tmp/neo-pkgs/"$M1N1_NEO_PACKAGE")
if guest pacman -Q linux-aurora-headers >/dev/null 2>&1; then
  install+=(/tmp/neo-pkgs/linux-aurora-headers-"$KERNEL_VERSION"-aarch64.pkg.tar.zst)
fi
guest pacman -U --noconfirm "${install[@]}"

say "Adding the J700 U-Boot (unowned until aurora-j700-support ships)"
install -d -m 0755 "$target/usr/lib/asahi-boot-j700"
install -m 0644 "$in/j700/$J700_UBOOT" "$target/usr/lib/asahi-boot-j700/u-boot-nodtb.bin"

say "Adding the MT7932 regulatory policy (no regulatory domain change)"
install -d -m 0755 "$policy_dir"
for entry in "${POLICY[@]}"; do
  read -r file digest <<<"$entry"
  install -m 0644 "$in/mt7932-policy/$file" "$policy_dir/$file"
done

say "Adding the Bluetooth admission service, gated on the J700 device tree"
# At the paths aurora-asks.md proposes for aurora-j700-support. The script is
# dev5's; the unit gains ConditionFirmware, because on M1-M3 0000:01:00.1 is
# the Broadcom Bluetooth function and ConditionPathExists alone would start it.
install -d -m 0755 "$target/usr/lib/aurora-j700"
cat >"$target$bt_admit" <<'ADMIT'
#!/bin/bash
# Admit the MacBook Neo's MT7932 Bluetooth function once per boot, as
# aurora-silicon/linux Documentation/networking/device_drivers/wifi/mt7932-neo.rst
# describes: only a cold, unbound 14c3:793b, after the root filesystem (and its
# firmware) is mounted; open the driver's gate, then request one PCI probe.
# Never reprobe: a bound device, or a second run in the same boot, does nothing.
set -euo pipefail
dev=/sys/bus/pci/devices/0000:01:00.1
[[ -e $dev ]] || exit 0
[[ $(<"$dev/vendor") == 0x14c3 && $(<"$dev/device") == 0x793b ]] || exit 0
[[ -e $dev/driver ]] && exit 0
modprobe mt7932_bt_pcie
echo 1 >/sys/module/mt7932_bt_pcie/parameters/enable
echo 0000:01:00.1 >/sys/bus/pci/drivers_probe
ADMIT
chmod 0755 "$target$bt_admit"
cat >"$target/usr/lib/systemd/system/$bt_unit" <<UNIT
[Unit]
Description=Admit the MacBook Neo Bluetooth radio once per boot
ConditionFirmware=device-tree-compatible(apple,j700)
ConditionPathExists=/sys/bus/pci/devices/0000:01:00.1
After=local-fs.target systemd-modules-load.service
Before=bluetooth.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$bt_admit

[Install]
WantedBy=multi-user.target
UNIT
chmod 0644 "$target/usr/lib/systemd/system/$bt_unit"
install -d -m 0755 "$target/etc/systemd/system/multi-user.target.wants"
ln -sfn "/usr/lib/systemd/system/$bt_unit" "$target/etc/systemd/system/multi-user.target.wants/$bt_unit"

say "Adding arm64.nowfxt to the kernel command line"
grep -q 'arm64.nowfxt' "$target/etc/default/grub" ||
  sed -i 's/^GRUB_CMDLINE_LINUX="\(.*\)"/GRUB_CMDLINE_LINUX="\1 arm64.nowfxt"/' "$target/etc/default/grub"
grep -q '^GRUB_CMDLINE_LINUX=".*arm64\.nowfxt.*"' "$target/etc/default/grub" || fail "GRUB_CMDLINE_LINUX did not take arm64.nowfxt"
grep -n "^GRUB_CMDLINE_LINUX=" "$target/etc/default/grub"

say "Installing the update-m1n1 board selector"
install -d -m 0755 "$target/usr/lib/omarchy-mac-image"
install -m 0644 "$selector" "$target/usr/lib/omarchy-mac-image/update-m1n1-board"
install -m 0644 "$default" "$target/etc/default/update-m1n1"

say "Adding both unfilled Aurora Stage 1s"
install -d -m 0755 "$target/boot/efi/aurora"
install -m 0644 "$in/j613/$J613_STAGE1" "$target/boot/efi/aurora/stage1-j613.bin"
install -m 0644 "$in/j700/$J700_STAGE1" "$target/boot/efi/aurora/stage1-j700.bin"

say "Rebuilding the Limine menu and both m1n1 Stage 2s"
guest limine-update
# The Neo's first: update-m1n1 writes boot.bin, which becomes boot-j700.bin.
guest env LC_ALL=C OMARCHY_M1N1_BOARD=j700 update-m1n1
mv -f "$boot_bin" "$boot_j700"
rm -f "$boot_bin.old" "$boot_bin.new"
# Then every M1-M3 Mac's, into boot.bin.
guest env LC_ALL=C OMARCHY_M1N1_BOARD=m123 update-m1n1
rm -f "$boot_bin.old" "$boot_bin.new" "$boot_j700.old" "$boot_j700.new"

# limine-entry-tool keys a history directory on the ESP by machine-id; the
# image ships none, so the Mac takes its own identity on first boot.
: >"$target/etc/machine-id"
while read -r identity; do
  [[ -n $identity ]] && rm -rf "${target:?}/boot/efi/$identity"
done < <(grep -o 'machine-id=[0-9a-f]\{32\}' "$target/boot/efi/limine.conf" | cut -d= -f2 | sort -u)
sed -i '/^comment: machine-id=/d' "$target/boot/efi/limine.conf"
rm -f "$target/boot/efi/.builder"
find "$target/var/cache/pacman/pkg" -mindepth 1 -delete

snapshots_after=$(btrfs subvolume list -o "$target" 2>/dev/null | awk '{print $NF}' | sort)
[[ $snapshots_before == "$snapshots_after" ]] || fail "the install created btrfs snapshots: $(comm -13 <(echo "$snapshots_before") <(echo "$snapshots_after") | tr '\n' ' ')"

say "After"
modules=$(ls "$target/usr/lib/modules")
echo "modules: $modules"
guest pacman -Q linux-aurora linux-aurora-headers m1n1-aurora m1n1-neo || fail "a kernel or m1n1 package is missing"
[[ $modules == "$MODULES_VERSION" ]] || fail "expected only $MODULES_VERSION modules, found: $modules"
for module in kernel/drivers/net/wireless/mediatek/mt7932/mt7932-fullmac.ko kernel/drivers/bluetooth/mt7932_bt_pcie.ko; do
  ls "$target/usr/lib/modules/$MODULES_VERSION/$module"* >/dev/null 2>&1 || fail "the kernel has no $module"
done
grep -aq 'apple,j700' "$target/usr/lib/modules/$MODULES_VERSION/dtbs/t8140-j700.dtb" || fail "the kernel has no j700 device tree"
# The M1-M3 Stage 2.
cmp -s <(head -c "$(stat -c %s "$work/m1n1.bin")" "$boot_bin") "$work/m1n1.bin" ||
  fail "boot.bin does not start with aurora17-5's m1n1"
for tree in "${REQUIRED_TREES[@]}"; do
  grep -aq "apple,$tree" "$boot_bin" || fail "boot.bin has no $tree device tree"
done
grep -aq 'mBoot-18000.161.9' "$boot_bin" || fail "boot.bin's m1n1 does not know macOS 26.6 firmware"
grep -aq 'mBoot-18000.161.10' "$boot_bin" || fail "boot.bin's m1n1 does not know macOS 26.6.2 firmware"
ends_with_gzip_of "$boot_bin" "$target/usr/lib/asahi-boot/u-boot-nodtb.bin" || fail "boot.bin does not end with uboot-asahi's U-Boot"
# The Neo's Stage 2.
cmp -s <(head -c "$(stat -c %s "$work/m1n1-neo.bin")" "$boot_j700") "$work/m1n1-neo.bin" ||
  fail "boot-j700.bin does not start with m1n1-neo's m1n1"
grep -aq 'apple,j700' "$boot_j700" || fail "boot-j700.bin has no j700 device tree"
for tree in "${REQUIRED_TREES[@]}"; do
  grep -aq "apple,$tree" "$boot_j700" || fail "boot-j700.bin has no $tree device tree"
done
ends_with_gzip_of "$boot_j700" "$in/j700/$J700_UBOOT" || fail "boot-j700.bin does not end with the J700 U-Boot"
ls "$target/boot/efi/m1n1"
for leftover in "$target"/boot/efi/m1n1/*.old "$target"/boot/efi/m1n1/*.new; do
  [[ ! -e $leftover ]] || fail "update-m1n1 left $leftover"
done
# Both Stage 1s.
[[ $(sha "$target/boot/efi/aurora/stage1-j613.bin") == "$J613_STAGE1_SHA256" ]] || fail "the J613 Stage 1 on the ESP does not match its digest"
[[ $(sha "$target/boot/efi/aurora/stage1-j700.bin") == "$J700_STAGE1_SHA256" ]] || fail "the J700 Stage 1 on the ESP does not match its digest"
# The selector, and the packaged lines kept above it.
cmp -s "$target/etc/default/update-m1n1" "$default" || fail "/etc/default/update-m1n1 is not the selector's default file"
cmp -s "$target/usr/lib/omarchy-mac-image/update-m1n1-board" "$selector" || fail "the board selector is not installed"
! guest sh -c '. /etc/default/update-m1n1' 2>/dev/null || fail "the selector accepts the build host's generic device tree"
# The Neo-only files.
[[ $(sha "$target/usr/lib/asahi-boot-j700/u-boot-nodtb.bin") == "$J700_UBOOT_SHA256" ]] || fail "the J700 U-Boot does not match its digest"
[[ ! -e $target/usr/lib/asahi-boot-j700/m1n1.bin ]] || fail "the image carries dev2's stale J700 m1n1"
for entry in "${POLICY[@]}"; do
  read -r file digest <<<"$entry"
  [[ $(sha "$policy_dir/$file") == "$digest" ]] || fail "the image's MT7932 policy $file does not match its digest"
done
[[ -x $target$bt_admit ]] || fail "the image has no Bluetooth admission script"
grep -qx 'ConditionFirmware=device-tree-compatible(apple,j700)' "$target/usr/lib/systemd/system/$bt_unit" ||
  fail "the Bluetooth admission unit is not gated on the J700 device tree"
grep -qx 'ConditionPathExists=/sys/bus/pci/devices/0000:01:00.1' "$target/usr/lib/systemd/system/$bt_unit" ||
  fail "the Bluetooth admission unit lost its device condition"
[[ $(readlink "$target/etc/systemd/system/multi-user.target.wants/$bt_unit") == "/usr/lib/systemd/system/$bt_unit" ]] ||
  fail "the Bluetooth admission service is not enabled"
# No global regulatory domain: the stock file, byte for byte.
regdom_after=absent
[[ ! -e $target/etc/conf.d/wireless-regdom ]] || regdom_after=$(sha "$target/etc/conf.d/wireless-regdom")
[[ $regdom_after == "$regdom_before" ]] || fail "/etc/conf.d/wireless-regdom changed"
! grep -q '^[[:space:]]*WIRELESS_REGDOM=' "$target/etc/conf.d/wireless-regdom" 2>/dev/null || fail "the image sets a global regulatory domain"
# The kernel command line and the menu.
grep -q 'arm64.nowfxt' "$target/boot/efi/limine.conf" || fail "the Limine menu lacks arm64.nowfxt"
grep -q "Kernel version: $MODULES_VERSION" "$target/boot/efi/limine.conf" || fail "the Limine menu does not boot the new kernel"
! grep -q "Kernel version: $old_modules" "$target/boot/efi/limine.conf" || fail "the Limine menu still lists $old_modules"
[[ "$target/boot/efi/EFI/Linux/omarchy_linux-aurora.efi" -nt "$work/image/esp/EFI/Linux/omarchy_linux-aurora.efi" ]] || fail "the UKI was not rebuilt"
echo "boot.bin: $(stat -c %s "$boot_bin") bytes; boot-j700.bin: $(stat -c %s "$boot_j700") bytes; UKI: $(stat -c %s "$target/boot/efi/EFI/Linux/omarchy_linux-aurora.efi") bytes"
grep -E '^(/|  (protocol|path|kernel_path|cmdline|comment):)' "$target/boot/efi/limine.conf" | head -12

say "Copying the ESP back for packaging"
rm -rf "$work/image/esp"
mkdir "$work/image/esp"
cp -rT "$target/boot/efi" "$work/image/esp"
ls -la "$work/image/esp" "$work/image/esp/EFI/Linux"
say "Resealing @factory from the new system"
sealed=$(cat "$top/@factory/var/lib/omarchy/factory-sealed")
umount -R "$target"
btrfs property set -ts "$top/@factory" ro false
btrfs subvolume delete "$top/@factory" >/dev/null
btrfs subvolume snapshot "$top/@" "$top/@factory.new" >/dev/null
new=$top/@factory.new
rm -rf -- "$new/var/lib/omarchy/first-boot" "$new/var/lib/omarchy/mac-first-boot" \
  "$new/var/lib/omarchy/provisioning/pending" \
  "$new/etc/pacman.d/gnupg" "$new/var/lib/omarchy/backups" \
  "$new/var/cache/pacman/pkg/"* \
  "$new/etc/NetworkManager/system-connections/"* "$new/var/lib/NetworkManager/"* "$new/var/lib/iwd"
install -d -m 0755 "$new/var/lib/omarchy"
printf '%s\n' "$sealed" >"$new/var/lib/omarchy/factory-sealed"
chmod 0644 "$new/var/lib/omarchy/factory-sealed"
btrfs property set -ts "$new" ro true
mv -T "$new" "$top/@factory"
btrfs filesystem sync "$top"
free=$(btrfs filesystem usage -b "$top" | awk '/Free \(estimated\)/ { print $3; exit }')
echo "root free: $free bytes"
(( free >= 512 * 1024 * 1024 )) || fail "the root has too little free space ($free)"
