#!/bin/bash

# The one image's update-m1n1 board selector and the /etc/default/update-m1n1
# that sources it, run against fake device trees in every POSIX shell on the
# host, the way update-m1n1 sources its configuration.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

selector=$ROOT/image-builder/one-image/update-m1n1-board
default=$ROOT/image-builder/one-image/update-m1n1.default
installed_selector=/usr/lib/omarchy-mac-image/update-m1n1-board
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

[[ -r $selector && -r $default ]] || fail "the update-m1n1 selector and its /etc/default file exist"

# pacman stub: linux-aurora owns two Apple device trees and a non-DTB file.
mkdir -p "$test_tmp/bin"
cat >"$test_tmp/bin/pacman" <<'STUB'
#!/bin/sh
[ "$*" = "-Qlq linux-aurora" ] || exit 1
printf '%s\n' /usr/lib/modules/6.99.0-aurora/dtbs/ \
  /usr/lib/modules/6.99.0-aurora/dtbs/t8103-j274.dtb \
  /usr/lib/modules/6.99.0-aurora/dtbs/t8140-j700.dtb \
  /usr/lib/modules/6.99.0-aurora/vmlinuz
STUB
chmod +x "$test_tmp/bin/pacman"
expected_dtbs=$'/usr/lib/modules/6.99.0-aurora/dtbs/t8103-j274.dtb\n/usr/lib/modules/6.99.0-aurora/dtbs/t8140-j700.dtb'

dt() {
  local name=$1
  shift
  printf '%s\0' "$@" >"$test_tmp/$name"
}
dt j700 apple,j700 apple,t8140 apple,arm-platform
dt j314s apple,j314s apple,t6000 apple,arm-platform
dt j613 apple,j613 apple,t8122 apple,arm-platform
dt j614s apple,j614s apple,t6031 apple,arm-platform
dt t8132 apple,j713 apple,t8132 apple,arm-platform
dt j704 apple,j704 apple,t8140x apple,arm-platform
: >"$test_tmp/empty"

shells=()
for shell in sh dash bash; do
  command -v "$shell" >/dev/null && shells+=("$shell")
done
[[ " ${shells[*]} " == *" sh "* ]] || fail "a POSIX sh is available"

# Sources the selector and prints what it chose. Without `set -e`, so a
# refusal must come from the selector's own `exit 1`, not from update-m1n1's
# shell options.
run_selector() {
  local shell=$1 compatible=$2 board=${3:-} script=${4:-$selector}
  env -u M1N1 -u U_BOOT -u DTBS -u LC_ALL PATH="$test_tmp/bin:$PATH" \
    OMARCHY_DT_COMPATIBLE="$compatible" OMARCHY_M1N1_BOARD="$board" \
    "$shell" -c '
      . "$1"
      printf "M1N1=%s\nU_BOOT=%s\nleftover=%s\n" "${M1N1-default}" "${U_BOOT-default}" \
        "${omarchy_m1n1_board-}${omarchy_m1n1_found-}${omarchy_m1n1_dt-}"
      printf "%s" "$DTBS" >"$2"
    ' _ "$script" "$test_tmp/dtbs"
}

expect_choice() {
  local shell=$1 description=$2 compatible=$3 board=$4 m1n1=$5 u_boot=$6 script=${7:-$selector} output
  rm -f "$test_tmp/dtbs"
  output=$(run_selector "$shell" "$compatible" "$board" "$script" 2>&1) ||
    fail "$shell: $description is accepted" "$output"
  [[ $output == $'M1N1='"$m1n1"$'\nU_BOOT='"$u_boot"$'\nleftover=' ]] ||
    fail "$shell: $description selects $m1n1 and $u_boot" "$output"
  [[ $(<"$test_tmp/dtbs") == "$expected_dtbs" ]] ||
    fail "$shell: $description takes DTBS from linux-aurora's device trees" "$(<"$test_tmp/dtbs")"
  pass "$shell: $description selects $m1n1"
}

expect_refusal() {
  local shell=$1 description=$2 compatible=$3 board=$4 message=$5 script=${6:-$selector} output status=0
  output=$(run_selector "$shell" "$compatible" "$board" "$script" 2>&1) || status=$?
  ((status == 1)) || fail "$shell: $description exits 1" "status $status: $output"
  [[ $output == *"$message"* && $output == *"m1n1/boot.bin is unchanged"* && $output != *M1N1=* ]] ||
    fail "$shell: $description explains the refusal on stderr" "$output"
  pass "$shell: $description is refused"
}

neo_m1n1=/usr/lib/m1n1-neo/m1n1.bin
neo_u_boot=/usr/lib/asahi-boot-j700/u-boot-nodtb.bin
for shell in "${shells[@]}"; do
  expect_choice "$shell" "MacBook Neo (j700)" "$test_tmp/j700" "" "$neo_m1n1" "$neo_u_boot"
  expect_choice "$shell" "M1 Pro (j314s, t6000)" "$test_tmp/j314s" "" default default
  expect_choice "$shell" "M3 Air (j613, t8122)" "$test_tmp/j613" "" default default
  expect_choice "$shell" "board override j700" "$test_tmp/missing" j700 "$neo_m1n1" "$neo_u_boot"
  expect_choice "$shell" "board override m123 on a Neo tree" "$test_tmp/j700" m123 default default
  expect_refusal "$shell" "j614s (t6031)" "$test_tmp/j614s" "" "compatible with apple,j614s apple,t6031 apple,arm-platform;"
  expect_refusal "$shell" "M4 (t8132)" "$test_tmp/t8132" "" "compatible with apple,j713 apple,t8132"
  expect_refusal "$shell" "a near-miss compatible (t8140x)" "$test_tmp/j704" "" "compatible with apple,j704"
  expect_refusal "$shell" "an empty compatible file" "$test_tmp/empty" "" "cannot read the device tree's compatible strings from $test_tmp/empty"
  expect_refusal "$shell" "a missing compatible file" "$test_tmp/missing" "" "cannot read the device tree's compatible strings from $test_tmp/missing"
  expect_refusal "$shell" "an unknown board override" "$test_tmp/j700" m4 "OMARCHY_M1N1_BOARD=m4 is not j700 or m123"
done

# A DTBS already chosen (by the caller, or omarchy-mac-boot's overlays) stays.
for shell in "${shells[@]}"; do
  output=$(env DTBS=/kept.dtb PATH="$test_tmp/bin:$PATH" OMARCHY_DT_COMPATIBLE="$test_tmp/j613" \
    "$shell" -c 'set -e; . "$1"; printf "%s" "$DTBS"' _ "$selector" 2>&1) ||
    fail "$shell: a preset DTBS is accepted" "$output"
  [[ $output == "/kept.dtb" ]] || fail "$shell: a preset DTBS is kept" "$output"
  pass "$shell: a preset DTBS is kept"
done

# /etc/default/update-m1n1 is omarchy-mac-boot's packaged file (omacom/
# omarchy-mac-pkgs 2dc0ad6, omarchy-mac-boot/files/etc/default/update-m1n1)
# unchanged, followed by the block that sources the selector.
packaged_sha=2dc3d768210e78a0ee258703c81d28389f9e00df96509acdc5f40449b4a78a33
[[ $(head -n 14 "$default" | shasum -a 256 | cut -d' ' -f1) == "$packaged_sha" ]] ||
  fail "/etc/default/update-m1n1 starts with omarchy-mac-boot's packaged file unchanged"
grep -qxF "  . $installed_selector" "$default" ||
  fail "/etc/default/update-m1n1 sources $installed_selector"
# install-aurora-sep.sh's m1n1_update deletes ^DTBS= lines and, on a Neo it
# moves to the packaged m1n1, indented M1N1= lines; neither may touch this file.
! grep -Eq '^DTBS=|^[[:space:]]*(export[[:space:]]+)?M1N1=|^# aurora-sep: build m1n1' "$default" ||
  fail "install-aurora-sep.sh's line edits leave /etc/default/update-m1n1's selection alone"
pass "/etc/default/update-m1n1 is the packaged file plus the selector"

# The /etc/default file itself, with the selector at a test path.
sed "s|$installed_selector|$selector|g" "$default" >"$test_tmp/default-here"
sed "s|$installed_selector|$test_tmp/no-selector|g" "$default" >"$test_tmp/default-missing"
for shell in "${shells[@]}"; do
  expect_choice "$shell" "/etc/default on a MacBook Neo" "$test_tmp/j700" "" "$neo_m1n1" "$neo_u_boot" "$test_tmp/default-here"
  expect_choice "$shell" "/etc/default on an M1 Pro" "$test_tmp/j314s" "" default default "$test_tmp/default-here"
  expect_refusal "$shell" "/etc/default on an M4" "$test_tmp/t8132" "" "apple,t8132" "$test_tmp/default-here"
  expect_refusal "$shell" "/etc/default without the selector" "$test_tmp/j700" "" "$test_tmp/no-selector is missing" "$test_tmp/default-missing"
done

# update-m1n1 (asahi-scripts) runs `set -e` and then
# `[ -e /etc/default/update-m1n1 ] && . /etc/default/update-m1n1` before it
# opens "${TARGET}.new". A sourced `exit 1` must end it there.
for shell in "${shells[@]}"; do
  for case_name in j614s j613; do
    rm -f "$test_tmp/boot.bin.new"
    status=0
    env PATH="$test_tmp/bin:$PATH" OMARCHY_DT_COMPATIBLE="$test_tmp/$case_name" "$shell" -c '
      set -e
      [ -e "$1" ] && . "$1"
      : >"$2"
    ' _ "$test_tmp/default-here" "$test_tmp/boot.bin.new" 2>/dev/null || status=$?
    if [[ $case_name == "j614s" ]]; then
      ((status == 1)) && [[ ! -e $test_tmp/boot.bin.new ]] ||
        fail "$shell: a refusal stops update-m1n1 before it writes boot.bin"
    else
      ((status == 0)) && [[ -e $test_tmp/boot.bin.new ]] ||
        fail "$shell: a supported Mac lets update-m1n1 write boot.bin"
    fi
  done
  pass "$shell: update-m1n1's sourcing stops on a refusal and continues otherwise"
done
