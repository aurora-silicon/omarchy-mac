#!/bin/bash

# The inputs record is canonical, names https servers only, and hands a build
# exactly the database bytes it pinned.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
inputs=$ROOT/bin/mac-image-inputs
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "ok - $*"
}

sha() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

mkdir -p "$work/cache/db"
declare -A digest=()
for repository in omarchy asahi-alarm core extra alarm aur; do
  printf '%s database\n' "$repository" >"$work/$repository.db"
  digest[$repository]=$(sha "$work/$repository.db")
  cp "$work/$repository.db" "$work/cache/db/${digest[$repository]}.db"
done
hex() { printf "$1%.0s" $(seq 64); }

record() {
  cat <<EOF
format=2
resolved_at=2026-09-25T10:41:01Z
candidate_set=apple-test-fixture
candidate_source_commit=$(printf 'a%.0s' $(seq 40))
candidate_signer=$(printf 'E%.0s' $(seq 40))
candidate_receipt_sha256=$(hex 1)
candidate_manifest_sha256=$(hex 2)
omarchy_channel=edge
omarchy_server=https://pkgs.omarchy.org/edge/\$arch
omarchy_db_sha256=${digest[omarchy]}
asahi_alarm_server=https://github.com/asahi-alarm/asahi-alarm/releases/download/aarch64
asahi_alarm_db_sha256=${digest[asahi-alarm]}
alarm_server=https://ca.us.mirror.archlinuxarm.org/\$arch/\$repo
alarm_core_db_sha256=${digest[core]}
alarm_extra_db_sha256=${digest[extra]}
alarm_alarm_db_sha256=${digest[alarm]}
alarm_aur_db_sha256=${digest[aur]}
alarm_rootfs_sha256=$(hex 3)
EOF
}

record >"$work/inputs"
"$BASH" "$inputs" check "$work/inputs" | cmp -s - "$work/inputs" || fail "check prints a canonical record"
pass "a canonical record checks"

awk -v policy="$(hex 4)" -v public="$(hex 5)" '{print; if ($0 ~ /^candidate_manifest_sha256=/) {
  print "candidate_trust_policy_sha256=" policy; print "candidate_trust_public_key_sha256=" public
}}' "$work/inputs" >"$work/pinned-trust-inputs"
"$BASH" "$inputs" check "$work/pinned-trust-inputs" | cmp -s - "$work/pinned-trust-inputs" ||
  fail "operator trust hash pair is canonical"
for field in candidate_trust_policy_sha256 candidate_trust_public_key_sha256; do
  sed "/^$field=/d" "$work/pinned-trust-inputs" >"$work/incomplete-trust"
  if "$BASH" "$inputs" check "$work/incomplete-trust" >/dev/null 2>&1; then
    fail "incomplete operator trust pins accepted"
  fi
done
if "$BASH" "$inputs" check "$work/inputs" --trust-dir "$work" >/dev/null 2>&1; then
  fail "a trust directory is an operator resolve input, not a check override"
fi
pass "operator trust pins must be a complete canonical pair"

refuse() {
  local description=$1
  shift
  "$@" >"$work/record" || true
  if "$BASH" "$inputs" check "$work/record" >/dev/null 2>&1; then
    fail "check accepts $description"
  fi
  pass "check refuses $description"
}

refuse "reordered fields" awk 'NR == 2 { held = $0; next } NR == 3 { print; print held; next } 1' "$work/inputs"
refuse "an unknown field" bash -c 'cat "$1"; echo lane=edge' _ "$work/inputs"
refuse "a repeated field" bash -c 'cat "$1"; sed -n 2p "$1"' _ "$work/inputs"
refuse "a short digest" sed 's/^omarchy_db_sha256=.*/omarchy_db_sha256=abc/' "$work/inputs"
refuse "an http server" sed 's|^alarm_server=https|alarm_server=http|' "$work/inputs"
refuse "a server that climbs" sed 's|^omarchy_server=.*|omarchy_server=https://pkgs.omarchy.org/edge/../x|' "$work/inputs"
refuse "an unknown channel" sed 's/^omarchy_channel=.*/omarchy_channel=beta/' "$work/inputs"
refuse "a lowercase signer" sed 's/^candidate_signer=.*/candidate_signer=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee/' "$work/inputs"
refuse "the mx-mac record format" sed 's/^format=2$/format=1/' "$work/inputs"

mkdir "$work/dbs"
"$BASH" "$inputs" dbs "$work/inputs" "$work/dbs" --cache "$work/cache" >/dev/null || fail "dbs from the cache"
for repository in omarchy asahi-alarm core extra alarm aur; do
  cmp -s "$work/$repository.db" "$work/dbs/$repository.db" || fail "$repository.db is the pinned database"
done
pass "dbs puts every pinned database in place from the cache"

mkdir "$work/moved"
printf 'moved on\n' >"$work/cache/db/${digest[extra]}.db"
if "$BASH" "$inputs" dbs "$work/inputs" "$work/moved" --cache "$work/cache" >/dev/null 2>&1; then
  fail "dbs accepts a database that is not the pinned one"
fi
pass "dbs refuses a database that is not the pinned one"

if "$BASH" "$inputs" dbs "$work/inputs" "$work/dbs" --cache "$work/cache" >/dev/null 2>&1; then
  fail "dbs writes into a directory that is not empty"
fi
pass "dbs needs an empty directory"

if "$BASH" "$inputs" resolve "$work/new" --candidates "$work" --alarm-server http://mirror.invalid >"$work/out" 2>&1; then
  fail "resolve accepts an http server"
fi
grep -Fq "not an https server URL: http://mirror.invalid" "$work/out" || fail "resolve refuses an http server by name"
pass "resolve refuses an http server"

# Target choice belongs to the immutable input record and pinned operator policy.
awk -v policy="$(hex 4)" -v public="$(hex 5)" '{print; if ($0 ~ /^candidate_manifest_sha256=/) {
  print "candidate_trust_policy_sha256=" policy; print "candidate_trust_public_key_sha256=" public;
  print "image_target_profile=neo-j700"
}}' "$work/inputs" >"$work/neo-inputs"
"$BASH" "$inputs" check "$work/neo-inputs" | cmp -s - "$work/neo-inputs" || fail "a pinned Neo record checks"
for variant in unknown unpinned; do
  if [[ $variant == "unknown" ]]; then
    sed 's/image_target_profile=neo-j700/image_target_profile=j614s/' "$work/neo-inputs" >"$work/bad-profile"
  else
    sed '/^candidate_trust_.*sha256=/d' "$work/neo-inputs" >"$work/bad-profile"
  fi
  if "$BASH" "$inputs" check "$work/bad-profile" >/dev/null 2>&1; then
    fail "target record rejects $variant selection"
  fi
done
pass "Neo input records pin the known target and require both operator trust digests"
