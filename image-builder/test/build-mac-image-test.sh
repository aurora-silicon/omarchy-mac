#!/bin/bash

# The builder's own decisions, without a container: which repositories a
# transaction reads and from where, the order the package set installs in, the
# image-target manifests, the pre-check's refusals and the first-boot contract.

set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../bin/build-mac-image
source "$here/bin/build-mac-image"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
# The builder's own work directory, for what it records.
work=$scratch
candidate_trust=$ROOT/builder/candidate-trust

builder_fail() {
  echo "build-mac-image: $*" >&2
  exit 1
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "ok - $*"
}

cat >"$scratch/inputs" <<'EOF'
omarchy_channel=edge
omarchy_server=https://pkgs.omarchy.org/edge/$arch
omarchy_db_sha256=1111111111111111111111111111111111111111111111111111111111111111
asahi_alarm_server=https://github.com/asahi-alarm/asahi-alarm/releases/download/aarch64
asahi_alarm_db_sha256=2222222222222222222222222222222222222222222222222222222222222222
alarm_server=https://ca.us.mirror.archlinuxarm.org/$arch/$repo
alarm_core_db_sha256=3333333333333333333333333333333333333333333333333333333333333333
alarm_extra_db_sha256=4444444444444444444444444444444444444444444444444444444444444444
alarm_alarm_db_sha256=5555555555555555555555555555555555555555555555555555555555555555
alarm_aur_db_sha256=6666666666666666666666666666666666666666666666666666666666666666
EOF
field() {
  sed -n "s/^$1=//p" "$scratch/inputs"
}

# ── repositories ───────────────────────────────────────────────────────────
render_config /repos /cache >"$scratch/pacman.conf"
sections=$(sed -n 's/^\[\(.*\)\]$/\1/p' "$scratch/pacman.conf" | paste -sd' ' -)
[[ $sections == "options omarchy-candidates asahi-alarm core extra alarm aur omarchy omarchy-aarch64" ]] ||
  fail "the candidate set is first, then the Apple profile's order: $sections"
pass "the candidate set comes first, then asahi-alarm, Arch Linux ARM and [omarchy]"

files=$(grep -c '^Server = file://' "$scratch/pacman.conf")
((files == 2)) && grep -Fxq 'Server = file:///repos/omarchy-candidates' "$scratch/pacman.conf" &&
  grep -Fxq 'Server = file:///repos/omarchy-aarch64' "$scratch/pacman.conf" ||
  fail "only the candidate set and the empty fork repository are served from disk"
grep -Fxq 'Server = https://pkgs.omarchy.org/edge/$arch' "$scratch/pacman.conf" &&
  grep -Fxq 'Server = https://ca.us.mirror.archlinuxarm.org/$arch/$repo' "$scratch/pacman.conf" ||
  fail "the remote servers are the record's"
pass "only the set and the empty [omarchy-aarch64] come from disk; the rest from the record's servers"

# ── package set ────────────────────────────────────────────────────────────
candidates=$scratch/candidates
mkdir -p "$candidates"
cat >"$candidates/import.json" <<'EOF'
{"packages": [
  {"name": "omarchy", "version": "4.0.0-1", "filename": "omarchy-4.0.0-1-aarch64.pkg.tar.xz", "group": "runtime"},
  {"name": "omarchy-settings", "version": "4.0.0-1", "filename": "s.pkg.tar.xz", "group": "runtime"},
  {"name": "omarchy-mac", "version": "0.1.0-1", "filename": "m.pkg.tar.xz", "group": "runtime"},
  {"name": "omarchy-mac-boot", "version": "20260921-10", "filename": "b.pkg.tar.xz", "group": "runtime"},
  {"name": "linux-aurora", "version": "7.0-1", "filename": "k.pkg.tar.zst", "group": "boot"},
  {"name": "m1n1-aurora", "version": "1.6.1-1", "filename": "n.pkg.tar.zst", "group": "boot"},
  {"name": "uboot-asahi", "version": "2026.07-1", "filename": "u.pkg.tar.zst", "group": "boot"}
]}
EOF
[[ $(qualified uboot-asahi limine gum | paste -sd' ' -) == "omarchy-candidates/uboot-asahi limine gum" ]] ||
  fail "set packages are installed by their repository-qualified name"
pass "a plain uboot-asahi request cannot resolve to asahi-alarm: set packages are qualified"

# What omarchy-pkg-defaults composes before the Apple list: base, then aarch64 when the runtime ships it.
mkdir -p "$scratch/runtime/usr/share/omarchy/install"
printf '# Base\nhyprland\nzram-generator\n' >"$scratch/runtime/usr/share/omarchy/install/omarchy-base.packages"
printf 'omarchy-mac\n' >"$scratch/runtime/usr/share/omarchy/install/omarchy-apple-silicon.packages"
(cd "$scratch/runtime" && bsdtar -cJf "$candidates/omarchy-4.0.0-1-aarch64.pkg.tar.xz" usr)
[[ $(runtime_lists | paste -sd' ' -) == "hyprland zram-generator" ]] ||
  fail "a runtime without an aarch64 list composes the base list alone"
printf '# aarch64\nzram-generator\n' >"$scratch/runtime/usr/share/omarchy/install/omarchy-aarch64.packages"
(cd "$scratch/runtime" && bsdtar -cJf "$candidates/omarchy-4.0.0-1-aarch64.pkg.tar.xz" usr)
[[ $(runtime_lists | paste -sd' ' -) == "hyprland zram-generator zram-generator" ]] ||
  fail "the aarch64 additions follow the base list"
pass "the runtime's base list, then its aarch64 additions, as omarchy-pkg-defaults composes them"

# The Apple list by upstream's name, else an older runtime's; never a link, which bsdtar reads as empty.
install_dir=$scratch/runtime/usr/share/omarchy/install
apple_layout() {
  rm -f "$install_dir"/omarchy-apple*.packages
  while (($#)); do
    if [[ $2 == @* ]]; then
      ln -s "${2#@}" "$install_dir/$1"
    else
      { echo "# Apple"; tr ' ' '\n' <<<"$2"; } >"$install_dir/$1"
    fi
    shift 2
  done
  (cd "$scratch/runtime" && bsdtar -cJf "$candidates/omarchy-4.0.0-1-aarch64.pkg.tar.xz" usr)
}
chosen_apple() {
  (fail() { builder_fail "$@"; }; read_apple_list && echo "${apple_names[*]}")
}
apple_layout omarchy-apple-silicon.packages 'omarchy-mac wf-recorder'
[[ $(chosen_apple) == "omarchy-mac wf-recorder" ]] || fail "an upstream runtime's omarchy-apple-silicon.packages is the Apple list"
apple_layout omarchy-apple.packages omarchy-mac
[[ $(chosen_apple) == omarchy-mac ]] || fail "an older runtime's omarchy-apple.packages is the Apple list"
apple_layout omarchy-apple-silicon.packages 'omarchy-mac wf-recorder' omarchy-apple.packages omarchy-mac
[[ $(chosen_apple) == "omarchy-mac wf-recorder" ]] || fail "upstream's name wins when a runtime ships both"
apple_layout omarchy-apple-silicon.packages 'omarchy-mac wf-recorder' omarchy-apple.packages @omarchy-apple-silicon.packages
[[ $(chosen_apple) == "omarchy-mac wf-recorder" ]] || fail "a compatibility link beside the list changes nothing"
apple_layout omarchy-apple.packages omarchy-mac omarchy-apple-silicon.packages @omarchy-apple.packages
[[ $(chosen_apple) == omarchy-mac ]] || fail "a link by upstream's name is passed over for the list it names"
pass "the Apple list is omarchy-apple-silicon.packages, else an older runtime's omarchy-apple.packages, never a link"
refused_apple() {
  local output
  if output=$(chosen_apple 2>&1); then
    fail "$2 is refused"
  fi
  [[ $output == "build-mac-image: $1" ]] || fail "$2 is refused with: $1 (got: $output)"
}
apple_layout
refused_apple "the runtime ships no Apple package list (omarchy-apple-silicon.packages or omarchy-apple.packages)" \
  "a runtime with no Apple list"
apple_layout omarchy-apple.packages @omarchy-apple-silicon.packages
refused_apple "the runtime ships no Apple package list (omarchy-apple-silicon.packages or omarchy-apple.packages)" \
  "a runtime whose only Apple list is a link"
apple_layout omarchy-apple-silicon.packages ''
refused_apple "the runtime's omarchy-apple-silicon.packages names no package" "a runtime whose Apple list names nothing"
rm -f "$candidates/omarchy-4.0.0-1-aarch64.pkg.tar.xz"
pass "a runtime with no Apple list, only a link to one, or an empty one stops the build before anything installs"
grep -A3 '^  prepare_repositories$' "$here/bin/build-mac-image" | grep -Fxq '  read_apple_list' ||
  fail "the build reads the Apple list before it creates the images"
pass "the build reads the Apple list once, before it creates the images"

runtime_list() {
  case $1 in
    base) printf 'hyprland\nobs-studio\n' ;;
  esac
}
apple_names=(omarchy-mac omarchy-mac-boot)
resolution=good
target_pacman() {
  local name
  if [[ $1 == -Sp && $3 == x ]]; then
    case $4 in
      obs-studio) echo "error: target not found: obs-studio"; return 1 ;;
      broken) echo "error: failed to prepare transaction (could not satisfy dependencies)"; return 1 ;;
    esac
    return
  fi
  printf '%s\n' "$@" >"$scratch/requested"
  for name in omarchy omarchy-settings omarchy-mac omarchy-mac-boot linux-aurora m1n1-aurora uboot-asahi; do
    if [[ $resolution == stolen && $name == uboot-asahi ]]; then
      echo "asahi-alarm uboot-asahi 2026.07.asahi1-1"
    else
      echo "omarchy-candidates $name 1-1"
    fi
  done
  [[ $resolution != refused ]] || echo "extra linux-asahi 6.16-1"
  echo "extra hyprland 0.56.2-3"
}
logs=$scratch/logs
mkdir -p "$logs"
(fail() { builder_fail "$@"; }; precheck_transaction) >/dev/null || fail "a set that resolves from itself passes the pre-check"
(fail() { builder_fail "$@"; }; precheck_transaction; printf '%s\n' "${base_names[@]}" >"$scratch/base"; printf '%s\n' "${unavailable[@]}" >"$scratch/missing") >/dev/null
[[ $(<"$scratch/base") == hyprland && $(<"$scratch/missing") == obs-studio ]] ||
  fail "base names the pinned repositories lack are left out and recorded"
for name in omarchy omarchy-settings omarchy-mac omarchy-mac-boot linux-aurora m1n1-aurora uboot-asahi; do
  grep -Fxq "omarchy-candidates/$name" "$scratch/requested" || fail "the pre-check resolves $name by its qualified name"
  ! grep -Fxq "$name" "$scratch/requested" || fail "the pre-check also asks for a plain $name"
done
grep -Fxq hyprland "$scratch/requested" && ! grep -Fxq obs-studio "$scratch/requested" ||
  fail "the pre-check resolves the base names the repositories carry, and only those"
grep -Fxq alsa-ucm-conf-asahi "$scratch/requested" && grep -Fxq asahi-audio "$scratch/requested" ||
  fail "the pre-check resolves the speaker stack's profiles and DSP chain"
pass "the pre-check passes a set that resolves from itself and records base names the repositories lack"
runtime_list() {
  case $1 in
    base) printf 'hyprland\nbroken\n' ;;
  esac
}
if (fail() { builder_fail "$@"; }; precheck_transaction) >/dev/null 2>&1; then
  fail "the pre-check drops a base name that exists but does not resolve"
fi
runtime_list() {
  case $1 in
    base) printf 'hyprland\nobs-studio\n' ;;
  esac
}
for resolution in stolen refused; do
  if (fail() { builder_fail "$@"; }; precheck_transaction) >/dev/null 2>&1; then
    fail "the pre-check accepts a $resolution resolution"
  fi
done
pass "the pre-check refuses a set package resolved elsewhere, a refused package, and a base name that does not resolve"

# ── install order ──────────────────────────────────────────────────────────
source_commit=$(printf 'a%.0s' {1..40})
builder_commit=$(printf 'c%.0s' {1..40})
printf 'candidate_set=apple-test-fixture\ncandidate_source_commit=%s\n' "$source_commit" >>"$scratch/inputs"
jq '. + {candidate_only: true}' "$candidates/import.json" >"$scratch/import.json" && mv "$scratch/import.json" "$candidates/import.json"
export MAC_IMAGE_BUILDER_COMMIT=$builder_commit MAC_IMAGE_BUILDER_CLEAN=false
target=$scratch/target
mkdir -p "$target"
mount_api() { :; }
unmount_api() { :; }
chown() { :; }
pacman() { printf 'omarchy 4.0.0-1\nomarchy-settings 4.0.0-1\nomarchy-mac 0.1.0-1\nomarchy-mac-boot 20260921-10\nlinux-aurora 7.0-1\nm1n1-aurora 1.6.1-1\nuboot-asahi 2026.07-1\n'; }
target_pacman() {
  [[ -e $target/var/lib/omarchy/image/target ]] && manifest=yes || manifest=no
  printf '%s manifest=%s\n' "$*" "$manifest" >>"$scratch/transactions"
}
: >"$scratch/transactions"
base_names=(hyprland)
(fail() { builder_fail "$@"; }; install_settings; write_image_target; install_runtime; install_apple_set)
unset -f chown pacman
mapfile -t transactions <"$scratch/transactions"
((${#transactions[@]} == 3)) || fail "three transactions: ${transactions[*]}"
[[ ${transactions[0]} == *" omarchy-candidates/omarchy-settings manifest=no" && ${transactions[0]} != *linux-aurora* ]] ||
  fail "the first transaction is the base and omarchy-settings alone, before the manifest: ${transactions[0]}"
[[ ${transactions[1]} == "-S omarchy-candidates/omarchy hyprland manifest=yes" ]] ||
  fail "the runtime comes next, after the manifest: ${transactions[1]}"
for name in omarchy-mac omarchy-mac-boot linux-aurora m1n1-aurora uboot-asahi; do
  [[ " ${transactions[2]} " == *" omarchy-candidates/$name "* ]] || fail "the Apple set installs $name by its qualified name"
done
[[ " ${transactions[2]} " == *" alsa-ucm-conf-asahi asahi-audio "* ]] ||
  fail "the Apple set installs alsa-ucm-conf-asahi and asahi-audio: ${transactions[2]}"
pass "omarchy-settings installs alone, then the manifest, the runtime and the Apple set, set packages by qualified name"
pass "the Apple set carries the speaker stack's model profiles and DSP chain"

expected_target="format=1
platform=apple-silicon
candidate_set=apple-test-fixture
candidate_source_commit=$source_commit
builder_commit=$builder_commit
builder_tree_clean=false
image_profile=test"
[[ $(<"$target/var/lib/omarchy/image/target") == "$expected_target" ]] ||
  fail "the image-target manifest names the platform, then the set, the builder and the profile" \
    "$(<"$target/var/lib/omarchy/image/target")"
[[ $(stat -c %a "$target/var/lib/omarchy/image/target" 2>/dev/null || stat -f %Lp "$target/var/lib/omarchy/image/target") == 644 ]] ||
  fail "the image-target manifest is mode 0644"
[[ ! -e $target/var/lib/omarchy/image-target ]] || fail "only the one manifest path is written"
pass "the image-target manifest names apple-silicon, mode 0644, at /var/lib/omarchy/image/target"
pass "the image-target manifest records the candidate set, its source commit, the builder commit and tree state, and the test profile"

image_profile_of() {
  (profile=$1; jq "$2" "$candidates/import.json" >"$scratch/import.json.new" &&
    cp "$candidates/import.json" "$scratch/import.json.keep" && mv "$scratch/import.json.new" "$candidates/import.json" &&
    image_profile; mv "$scratch/import.json.keep" "$candidates/import.json")
}
[[ $(image_profile_of lab .) == lab && $(image_profile_of release .) == test &&
  $(image_profile_of release '. + {candidate_only: false}') == release ]] ||
  fail "the image profile is lab for a lab image, else test for a candidate-only set, else release"
pass "the image profile is lab for a lab image, else test for a candidate-only set, else release"

mv "$candidates/import.json" "$scratch/import.json.keep"
if (chown() { :; }; fail() { builder_fail "$@"; }; write_image_target) >/dev/null 2>&1; then
  fail "the image-target manifest is refused when the candidate set cannot be read"
fi
mv "$scratch/import.json.keep" "$candidates/import.json"
pass "the image-target manifest is refused when the candidate set cannot be read"

for unset_variable in MAC_IMAGE_BUILDER_COMMIT MAC_IMAGE_BUILDER_CLEAN; do
  if (unset "$unset_variable"; chown() { :; }; fail() { builder_fail "$@"; }; write_image_target) >/dev/null 2>&1; then
    fail "the image-target manifest is refused without $unset_variable"
  fi
done
pass "the image-target manifest is not written without the builder commit and tree state"

# ── build identity ─────────────────────────────────────────────────────────
printf 'omarchy|4.0.0-1|omarchy-candidates|omarchy-4.0.0-1-aarch64.pkg.tar.xz|%s\nglibc|2.43-1|core|glibc-2.43-1-aarch64.pkg.tar.xz|%s\n' \
  "$(printf '3%.0s' {1..64})" "$(printf '5%.0s' {1..64})" >"$scratch/packages"
digest=$(package_set_sha256)
[[ $digest =~ ^[0-9a-f]{64}$ ]] || fail "the package set digest is 64 hex digits: $digest"
before=$(<"$target/var/lib/omarchy/image/target")
(fail() { builder_fail "$@"; }; write_build_identity; printf '%s\n' "$built" >"$scratch/built")
recorded_built=$(<"$scratch/built")
[[ $recorded_built =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] ||
  fail "the build time is UTC, YYYY-MM-DDTHH:MM:SSZ: $recorded_built"
[[ $(<"$target/var/lib/omarchy/image/target") == "$before"$'\n'"package_set_sha256=$digest"$'\n'"built=$recorded_built" ]] ||
  fail "the build identity follows the manifest's other lines, unchanged" "$(<"$target/var/lib/omarchy/image/target")"
[[ $(stat -c %a "$target/var/lib/omarchy/image/target" 2>/dev/null || stat -f %Lp "$target/var/lib/omarchy/image/target") == 644 ]] ||
  fail "the image-target manifest stays mode 0644"
pass "the image-target manifest records the build's package set digest and UTC build time after its other lines"

if (fail() { builder_fail "$@"; }; write_build_identity) >/dev/null 2>&1; then
  fail "the build identity is refused when the manifest already records one"
fi
pass "the build identity is written once"

cp "$target/var/lib/omarchy/image/target" "$scratch/target.keep"
printf '%s\n' "$before" >"$target/var/lib/omarchy/image/target"
for bad_date in '2026-09-28 03:04:05' '2026-09-28T03:04:05+10:00' $'2026-09-28T03:04:05Z\nsecret=x' ''; do
  if (date() { printf '%s\n' "$bad_date"; }; fail() { builder_fail "$@"; }; write_build_identity) >/dev/null 2>&1; then
    fail "a malformed build time is refused: $bad_date"
  fi
  [[ $(<"$target/var/lib/omarchy/image/target") == "$before" ]] || fail "a refused build identity leaves the manifest unchanged"
done
if (package_set_sha256() { echo "not-a-digest"; }; fail() { builder_fail "$@"; }; write_build_identity) >/dev/null 2>&1; then
  fail "a malformed package set digest is refused"
fi
[[ $(<"$target/var/lib/omarchy/image/target") == "$before" ]] || fail "a refused build identity leaves the manifest unchanged"
rm "$target/var/lib/omarchy/image/target"
if (fail() { builder_fail "$@"; }; write_build_identity) >/dev/null 2>&1; then
  fail "the build identity is refused without a manifest"
fi
mv "$scratch/target.keep" "$target/var/lib/omarchy/image/target"
pass "the build identity is refused when malformed or when there is no manifest, and never half-written"

mkdir -p "$scratch/final"
: >"$scratch/final/root.img"
image_record() {
  (lane=edge hardware_setup=build test_image_pin="" profile=release
    sha256_of() { printf '%064d\n' 0; }
    fail() { builder_fail "$@"; }
    "$@")
}
(fail() { builder_fail "$@"; }; package_set_digest="" built=""
  [[ -e $target/var/lib/omarchy/image/target ]] || fail "the manifest is still there"
  sed -i.bak '/^package_set_sha256=/d; /^built=/d' "$target/var/lib/omarchy/image/target"
  rm -f "$target/var/lib/omarchy/image/target.bak"
  write_build_identity
  package_set_sha256() { echo recomputed; }
  image_record write_image >"$scratch/IMAGE")
manifest_identity=$(grep -E '^(package_set_sha256|built)=' "$target/var/lib/omarchy/image/target")
image_identity=$(grep -E '^(package_set_sha256|built)=' "$scratch/IMAGE")
[[ $image_identity == "$manifest_identity" && $(grep -c '^built=' "$scratch/IMAGE") == 1 ]] ||
  fail "IMAGE records the manifest's package set digest and build time" "$image_identity" "$manifest_identity"
pass "IMAGE records the package set digest and build time the manifest recorded, computed once"

for writer in write_image write_provenance; do
  if (package_set_digest="" built=""; image_record "$writer" z.zip) >/dev/null 2>&1; then
    fail "$writer is refused before the build recorded its identity"
  fi
done
pass "IMAGE and PROVENANCE are not written before the build recorded its identity"

# ── first boot ─────────────────────────────────────────────────────────────
make_first_boot() {
  rm -rf "$target"
  mkdir -p "$target/usr/lib/omarchy/mac-first-boot"
  cat >"$target/usr/lib/omarchy/mac-first-boot/omarchy-mac-first-boot" <<EOF
#!/bin/bash
if [[ \$1 == arm ]]; then mkdir -p "\$2/var/lib/omarchy/mac-first-boot"; : >"\$2/var/lib/omarchy/mac-first-boot/pending"; fi
exit 0
run_deferred_steps() { $1; }
EOF
  chmod +x "$target/usr/lib/omarchy/mac-first-boot/omarchy-mac-first-boot"
}
make_first_boot "cmp -s \"\$steps\" <(printf '%s\\n' 'install/hardware/apple/limine-boot.sh')"
(fail() { builder_fail "$@"; }; arm_first_boot)
[[ -f $target/var/lib/omarchy/mac-first-boot/pending &&
  $(<"$target/var/lib/omarchy/mac-first-boot/deferred-steps") == install/hardware/apple/limine-boot.sh ]] ||
  fail "a first boot that runs the Limine leaf gets its deferred-steps contract"
make_first_boot "/usr/bin/omarchy-provision-hardware"
(fail() { builder_fail "$@"; }; arm_first_boot)
[[ -f $target/var/lib/omarchy/mac-first-boot/pending && ! -e $target/var/lib/omarchy/mac-first-boot/deferred-steps ]] ||
  fail "a first boot without that contract gets pending only"
pass "first boot is armed by the boot package, with deferred-steps only for the contract it reads"

# ── snapper's subvolume ────────────────────────────────────────────────────
# The build root's btrfs subvolumes, as btrfs subvolume show would find them.
: >"$scratch/subvolumes"
btrfs() {
  case "$1 $2" in
    "subvolume show") grep -Fxq "$3" "$scratch/subvolumes" ;;
    "subvolume create") mkdir "$3" && printf '%s\n' "$3" >>"$scratch/created" ;;
    *) return 1 ;;
  esac
}
carry() {
  rm -rf "$scratch/build" "$scratch/sealed" "$scratch/created"
  mkdir -p "$scratch/build" "$scratch/sealed"
  : >"$scratch/created"
  "$@"
  (fail() { builder_fail "$@"; }; carry_snapshots_subvolume "$scratch/build" "$scratch/sealed") >/dev/null 2>&1
}
carry true || fail "a build root without /.snapshots seals"
[[ ! -s $scratch/created ]] || fail "no /.snapshots is made when the runtime made none"
carry eval 'mkdir "$scratch/build/.snapshots"; echo "$scratch/build/.snapshots" >"$scratch/subvolumes"' ||
  fail "an empty /.snapshots subvolume is carried"
[[ $(<"$scratch/created") == "$scratch/sealed/.snapshots" ]] || fail "the sealed @ gets its own /.snapshots subvolume"
if carry eval 'mkdir "$scratch/build/.snapshots"; : >"$scratch/subvolumes"'; then
  fail "a flattened /.snapshots is carried as a plain directory"
fi
if carry eval 'mkdir -p "$scratch/build/.snapshots/1"; echo "$scratch/build/.snapshots" >"$scratch/subvolumes"'; then
  fail "snapshots taken during the build are carried"
fi
unset -f btrfs carry
pass "snapper's empty /.snapshots subvolume is carried into the sealed @; a plain or non-empty one stops the build"

# ── desktop automounters ───────────────────────────────────────────────────
if ((EUID != 0)); then
  sudo() { return 1; }
  pgrep() { [[ $2 == *udiskie* ]]; }
  if (fail() { builder_fail "$@"; }; hide_loop_devices) >/dev/null 2>&1; then
    fail "a build without root or passwordless sudo runs beside a desktop automounter"
  fi
  pgrep() { return 1; }
  (fail() { builder_fail "$@"; }; hide_loop_devices) || fail "a build without an automounter needs no root"
  unset -f sudo pgrep
  pass "without a way to hide its loop devices, the build refuses to run beside a desktop automounter"
fi

# ── boot setup ─────────────────────────────────────────────────────────────
# The boot setup's script runs outside a chroot here: its fixed paths move
# under the scratch root, and the dispatcher and the runtime's leaves are
# fakes that record whether the Limine gate was set when each ran.
boot_root=$scratch/boot-root
logs=$scratch/boot-logs
findmnt() { echo /dev/loop7; }
isolated_chroot() {
  shift
  if [[ $1 == /usr/bin/omarchy-lifecycle-dispatch ]]; then
    [[ $* == "/usr/bin/omarchy-lifecycle-dispatch --resolve setup-boot" ]] || return 99
    [[ -z $resolve_output ]] || echo "$resolve_output"
    return "$resolve_status"
  fi
  local mode=${*: -1} script
  script=$(sed -e "s|/dev/disk/by-uuid|$boot_root/by-uuid|g" -e "s|/var/lib/omarchy/limine.enabled|$boot_root/gate|g" \
    -e "s|/usr/bin/omarchy-lifecycle-dispatch|$boot_root/bin/omarchy-lifecycle-dispatch|g")
  PATH=$boot_root/bin:$PATH OMARCHY_PATH=$boot_root/runtime /bin/bash -eE -s -- /dev/loop7 "$ROOT_UUID" "$mode" <<<"$script" || return
  mkdir -p "$target/boot/efi/EFI/Linux" "$target/boot/efi/EFI/BOOT" "$target/usr/share/limine" "$target/etc"
  echo "/Omarchy" >"$target/boot/efi/limine.conf"
  echo uki >"$target/boot/efi/EFI/Linux/omarchy_$KERNEL.efi"
  echo limine | tee "$target/usr/share/limine/BOOTAA64.EFI" >"$target/boot/efi/EFI/BOOT/BOOTAA64.EFI"
}
boot_layout() {
  rm -rf "$boot_root" "$scratch/boot-target"
  target=$scratch/boot-target
  mkdir -p "$boot_root/bin" "$boot_root/runtime/install/hardware/apple" "$target/usr/bin" "$logs"
  : >"$boot_root/ran"
  resolve_output=/usr/lib/omarchy/mac-boot/setup-boot resolve_status=0
  local part
  for part in "$@"; do
    case $part in
      dispatcher) printf '#!/bin/bash\n' >"$target/usr/bin/omarchy-lifecycle-dispatch"; chmod +x "$target/usr/bin/omarchy-lifecycle-dispatch" ;;
      entry) mkdir -p "$target/usr/lib/omarchy/mac-boot"; : >"$target/usr/lib/omarchy/mac-boot/setup-boot" ;;
      leaves)
        for leaf in grub-console limine-boot; do
          printf 'echo "%s $([[ -e %s ]] && echo gate || echo no-gate) sudo=$(type -t sudo)" >>%s\n' \
            "$leaf" "$boot_root/gate" "$boot_root/ran" >"$boot_root/runtime/install/hardware/apple/$leaf.sh"
          mkdir -p "$target/usr/share/omarchy/install/hardware/apple"
          : >"$target/usr/share/omarchy/install/hardware/apple/$leaf.sh"
        done ;;
    esac
  done
  printf '#!/bin/bash\necho "$* $([[ -e %s ]] && echo gate || echo no-gate)" >>%s\n' "$boot_root/gate" "$boot_root/ran" \
    >"$boot_root/bin/omarchy-lifecycle-dispatch"
  chmod +x "$boot_root/bin/omarchy-lifecycle-dispatch"
}
# GNU sed's in-place edit, which the activation's tail uses, on BSD sed too.
portable_sed() {
  if [[ $1 == -i ]]; then
    shift
    command sed "${@:1:$#-1}" "${@: -1}" >"${@: -1}.new" && mv "${@: -1}.new" "${@: -1}"
  else
    command sed "$@"
  fi
}
activate() { (fail() { builder_fail "$@"; }; sed() { portable_sed "$@"; }; activate_limine); }

boot_layout dispatcher entry
activate
[[ $(<"$boot_root/ran") == $'setup-boot no-gate\nsetup-boot gate' ]] ||
  fail "setup-boot runs before the gate, then after it" "$(<"$boot_root/ran")"
[[ $(<"$logs/limine-boot.log") == "boot setup: dispatch" && ! -e $boot_root/by-uuid/$ROOT_UUID ]] ||
  fail "the boot setup says it dispatched and removes its device link" "$(<"$logs/limine-boot.log")"
pass "a runtime without Apple leaves (omacom/omarchy#13362) runs omarchy-mac-boot's setup-boot, before the Limine gate and after it"

boot_layout dispatcher entry leaves
activate
[[ $(<"$boot_root/ran") == $'setup-boot no-gate\nsetup-boot gate' ]] ||
  fail "a boot package with setup-boot wins over the runtime's shims" "$(<"$boot_root/ran")"
pass "a boot package with setup-boot is dispatched even when the runtime still carries its Apple leaves"

for layout in "leaves" "dispatcher leaves" "entry leaves" "dispatcher entry leaves:2"; do
  boot_layout ${layout%:*}
  [[ $layout != *:2 ]] || resolve_output="" resolve_status=2
  activate
  [[ $(<"$boot_root/ran") == $'grub-console no-gate sudo=function\nlimine-boot gate sudo=function' ]] ||
    fail "the runtime's leaves run as before ($layout)" "$(<"$boot_root/ran")"
done
pass "without a dispatchable setup-boot (no entrypoint, no dispatcher, or one without the operation) the runtime's Apple leaves run, the gate between them"

for layout in "dispatcher entry leaves:1" "dispatcher entry leaves:0:/usr/lib/omarchy/mac-boot/other" "dispatcher entry leaves:0:" \
  "dispatcher entry:2" "dispatcher" ""; do
  IFS=: read -r parts status output <<<"$layout"
  boot_layout $parts
  if [[ -n $status ]]; then
    resolve_status=$status resolve_output=$output
  fi
  if activate 2>"$scratch/boot-error"; then
    fail "the boot setup is refused ($layout)"
  fi
  [[ ! -s $boot_root/ran ]] || fail "nothing runs when the boot setup is refused ($layout)"
done
grep -Fq "neither omarchy-mac-boot's setup-boot operation nor the runtime's grub-console.sh" "$scratch/boot-error" ||
  fail "a runtime with neither boot setup names both" "$(<"$scratch/boot-error")"
pass "a dispatcher that fails or resolves setup-boot elsewhere stops the build, and so does a runtime with no boot setup at all"

boot_layout dispatcher entry
mkdir -p "$target/var/lib/omarchy"
: >"$target/var/lib/omarchy/limine.enabled"
if activate 2>/dev/null; then fail "a gate set before the boot setup is refused"; fi
pass "the Limine gate must not be set before the boot setup runs"
unset -f findmnt isolated_chroot

# ── lab access ─────────────────────────────────────────────────────────────
target=$scratch/lab-root
logs=$scratch
mkdir -p "$target/usr/lib/systemd/system" "$scratch/lab-access"
: >"$target/usr/lib/systemd/system/sshd.service"
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKm3ZIe3P3NW/VLwzdZ6vgFvk4OAabP02rnxiZKmXG2r lab\n' \
  >"$scratch/lab-access/authorized_keys"
isolated_chroot() { shift; printf '%s\n' "$*" >>"$scratch/chroot"; }
: >"$scratch/chroot"
(fail() { builder_fail "$@"; }; profile=release; apply_lab_access)
[[ ! -e $target/etc/sudoers.d/omarchy-lab && ! -s $scratch/chroot ]] || fail "a release image gets no lab access"
(fail() { builder_fail "$@"; }; profile=lab; lab_access_dir=$scratch/lab-access; apply_lab_access
  [[ $lab_access_sha256 =~ ^[0-9a-f]{64}$ ]] || fail "the lab access digest is recorded")
[[ $(<"$scratch/chroot") == "visudo -cf /etc/sudoers.d/omarchy-lab" ]] || fail "the lab sudoers rule is validated in the image"
python3 -c 'import importlib.util, sys; s = importlib.util.spec_from_file_location("l", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m); m.check(__import__("pathlib").Path(sys.argv[2]), "the image", True)' \
  "$here/builder/lab_access.py" "$target" || fail "the builder writes exactly the lab overlay"
unset -f isolated_chroot
pass "a lab build writes the lab overlay and validates its sudoers rule; a release build writes none"

# ── sync databases the image keeps ─────────────────────────────────────────
target=$scratch/sync-root
sync=$target/var/lib/pacman/sync
mkdir -p "$sync" "$target/etc"
cat >"$target/etc/pacman.conf" <<'CONF'
[options]
SigLevel = Required DatabaseOptional

[omarchy]
Server = https://pkgs.omarchy.org/edge/$arch

[asahi-alarm]
Server = https://github.com/asahi-alarm/asahi-alarm/releases/download/aarch64
  [core]
Include = /etc/pacman.d/mirrorlist
# [core-debug]
[extra]
Include = /etc/pacman.d/mirrorlist
[alarm]
Include = /etc/pacman.d/mirrorlist
[aur]
Include = /etc/pacman.d/mirrorlist
CONF
[[ $(pacman_repositories "$target/etc/pacman.conf" | paste -sd' ' -) == "omarchy asahi-alarm core extra alarm aur" ]] ||
  fail "the installed configuration's repositories are read in order, comments and [options] skipped"
fill_sync() {
  rm -rf "$sync"
  mkdir -p "$sync"
  local name
  for name in omarchy-candidates asahi-alarm core extra alarm aur omarchy omarchy-aarch64; do
    printf '%s database\n' "$name" >"$sync/$name.db"
  done
  : >"$sync/db.lck"
  mkdir "$sync/.stale"
}
fill_sync
pins=$(printf 'omarchy-candidates - -\n'
  for name in asahi-alarm core extra alarm aur omarchy; do
    printf '%s %s https://%s.invalid\n' "$name" "$(sha256_of "$sync/$name.db")" "$name"
  done)
repositories() {
  printf '%s\n' "$pins"
}
(fail() { builder_fail "$@"; }; keep_installed_databases) || fail "the installed repositories' databases are kept"
[[ $(cd "$sync" && ls -A | sort | paste -sd' ' -) == "alarm.db asahi-alarm.db aur.db core.db extra.db omarchy.db" ]] ||
  fail "only the installed repositories' databases are left: $(ls -A "$sync")"
fill_sync
printf 'moved\n' >"$sync/core.db"
if (fail() { builder_fail "$@"; }; keep_installed_databases) >/dev/null 2>&1; then
  fail "a kept database that is not the pinned one stops the build"
fi
fill_sync
rm "$sync/aur.db"
if (fail() { builder_fail "$@"; }; keep_installed_databases) >/dev/null 2>&1; then
  fail "a repository with no database stops the build"
fi
fill_sync
printf '\n[omarchy-candidates]\nServer = file:///repos\n' >>"$target/etc/pacman.conf"
if (fail() { builder_fail "$@"; }; keep_installed_databases) >/dev/null 2>&1; then
  fail "a repository the inputs pin no database for stops the build"
fi
unset -f repositories fill_sync
pass "the image keeps the pinned database of each repository its pacman.conf names, and nothing else"

# ── first-boot probe ───────────────────────────────────────────────────────
probe_pacman "$scratch/requests" "echo pacman" >"$scratch/probe-pacman"
: >"$scratch/requests"
for request in "-Q vulkan-asahi" "-Qi asahi-bless" "-T vulkan-driver" "-U /var/tmp/x.pkg.tar.zst" "--query --search Sy"; do
  read -ra words <<<"$request"
  [[ $("$BASH" "$scratch/probe-pacman" "${words[@]}") == "pacman ${words[*]}" ]] || fail "the probe's pacman runs $request"
done
[[ ! -s $scratch/requests ]] || fail "queries and local installs are not recorded"
for request in "-S --noconfirm --needed vulkan-asahi" "-Sy" "-Syu --noconfirm" "--sync foo" "-Fy" "--needed --refresh -S foo"; do
  read -ra words <<<"$request"
  if "$BASH" "$scratch/probe-pacman" "${words[@]}" >/dev/null; then
    fail "the probe's pacman refuses $request"
  fi
done
[[ $(wc -l <"$scratch/requests") -eq 6 && $(head -n 1 "$scratch/requests") == "-S --noconfirm --needed vulkan-asahi" ]] ||
  fail "every sync or refresh is recorded: $(<"$scratch/requests")"
pass "the first-boot probe's pacman refuses and records every sync or refresh, and runs everything else"

select_target_profile neo-j700
[[ $PLATFORM_COMPATIBLE == "apple,j700" && $image_board == "apple,j700" && ${SUPPORTED_FW[*]} == "26.6.2" \
  && ${BOARD_CONTEXT[*]} == "OMARCHY_M1N1_BOARD=j700" ]] || fail "Neo profile is bound to J700 firmware and temporary builder context"
mkdir -p "$scratch/profile-root/usr/lib/aura"
target=$scratch/profile-root
printf 'package-owned Stage1' >"$target/usr/lib/aura/aura-stage1.bin"
stage_common_stage1
cmp -s "$target/usr/lib/aura/aura-stage1.bin" "$target/boot/efi/aurora/stage1.bin" || fail "common Stage1 stages exact installed bytes"
mkdir -p "$target/run/systemd/system"
if (fail() { builder_fail "$@"; }; require_unbooted_target "$target") >/dev/null 2>&1; then
  fail "Neo context rejects a booted target"
fi
rmdir "$target/run/systemd/system"
require_unbooted_target "$target"
if (fail() { builder_fail "$@"; }; select_target_profile j614s) >/dev/null 2>&1; then
  fail "an unknown/unqualified target profile is rejected"
fi
select_target_profile generic
[[ $PLATFORM_COMPATIBLE == "apple,arm-platform" && ${SUPPORTED_FW[*]} == "13.5 14.8.3" \
  && -z $image_board && ${#BOARD_CONTEXT[@]} == 0 ]] || fail "generic defaults remain unchanged"
pass "Neo profile selects J700/26.6.2, stages exact bare payload, rejects booted context, and preserves generic defaults"
