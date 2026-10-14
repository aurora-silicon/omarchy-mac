#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

config=$ROOT/Packaging/identity.conf
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

# The Swift generator parses this file while the shell sources it, so only
# lines whose meaning is identical in both are allowed.
# Names map to Swift properties by lower-camel-casing the words after
# INSTALLER_, so two names must never map to the same property.
entry_pattern='^(INSTALLER_[A-Z][A-Z0-9]*(_[A-Z0-9]+)*)="([^"\$`]+)"$'
declare -A seen=() properties=()
line_number=0
while IFS= read -r line || [[ -n $line ]]; do
  line_number=$((line_number + 1))
  [[ -z $line || $line == \#* ]] && continue
  [[ $line =~ $entry_pattern ]] ||
    fail "identity.conf line $line_number is NAME=\"value\" without quoting or expansion" "$line"
  name=${BASH_REMATCH[1]}
  IFS=_ read -r -a words <<<"${name#INSTALLER_}"
  property=${words[0],,}
  for word in "${words[@]:1}"; do
    word=${word,,}
    property+=${word^}
  done
  [[ $property != entries && -z ${properties[$property]:-} ]] ||
    fail "identity.conf line $line_number maps to a distinct Swift property" "$name"
  properties[$property]=1
  seen[$name]=1
done <"$config"
source "$config"
for name in INSTALLER_APP_NAME INSTALLER_LEGACY_APP_NAME INSTALLER_FILE_STEM INSTALLER_APP_IDENTIFIER \
  INSTALLER_HELPER_IDENTIFIER INSTALLER_PKG_IDENTIFIER INSTALLER_TEAM_ID \
  INSTALLER_APP_SIGNING_IDENTITY INSTALLER_PKG_SIGNING_IDENTITY \
  INSTALLER_CATALOG_KEY_SERVICE INSTALLER_CATALOG_BASE INSTALLER_PUBLIC_BASE INSTALLER_STREAM_PATH INSTALLER_R2_BUCKET \
  INSTALLER_R2_ENDPOINT INSTALLER_GITHUB_RELEASE_REPO INSTALLER_GITHUB_RELEASE_LOGIN; do
  [[ -n ${seen[$name]:-} ]] || fail "identity.conf defines $name"
done
[[ $INSTALLER_LEGACY_APP_NAME != "$INSTALLER_APP_NAME" ]] ||
  fail "the legacy app name differs from the current one"
[[ $INSTALLER_TEAM_ID =~ ^[A-Z0-9]{10}$ ]] || fail "the team identifier has ten characters"
[[ $INSTALLER_APP_SIGNING_IDENTITY == "Developer ID Application: "*" ($INSTALLER_TEAM_ID)" ]] ||
  fail "the app signing identity belongs to the configured team"
[[ $INSTALLER_PKG_SIGNING_IDENTITY == "Developer ID Installer: "*" ($INSTALLER_TEAM_ID)" ]] ||
  fail "the package signing identity belongs to the configured team"
[[ $INSTALLER_PUBLIC_BASE == https://?* && $INSTALLER_PUBLIC_BASE != */ ]] ||
  fail "the public base is https without a trailing slash"
[[ $INSTALLER_CATALOG_BASE == https://?* && $INSTALLER_CATALOG_BASE != */ ]] ||
  fail "the catalog base is https without a trailing slash"
# One path segment: the stream must never be the bucket root, where the MX Mac
# feeds live, nor reach into another stream.
[[ $INSTALLER_STREAM_PATH =~ ^[a-z0-9][a-z0-9-]*$ ]] ||
  fail "the stream path is one lowercase path segment"
trust_root=$ROOT/Release/trust-root.ed25519.pub
[[ -f $trust_root && ! -L $trust_root && $(wc -c <"$trust_root") -eq 32 ]] ||
  fail "the trust root is a 32-byte public key"
# The key file is the trust root's only source; release.json's fingerprint is
# derived from it and checked below.
trust_root_digest=$(sha256sum "$trust_root" | cut -d' ' -f1)
pass "identity.conf is well formed and internally consistent"

# Release inputs that embed identity or hosting must be derived from it.
descriptor=$ROOT/Release/release.json
default_channel=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["default_channel"])' "$descriptor")
bash "$ROOT/scripts/make-release-descriptor" \
  --public-key "$trust_root" \
  --default-channel "$default_channel" \
  --output "$test_tmp/release.json" >/dev/null
cmp -s "$test_tmp/release.json" "$descriptor" ||
  fail "Release/release.json is what make-release-descriptor writes from identity.conf" \
    "$(diff "$test_tmp/release.json" "$descriptor" || true)"
python3 - "$descriptor" "$INSTALLER_CATALOG_BASE" <<'PY' ||
import json, sys
descriptor, base = sys.argv[1:3]
channels = json.load(open(descriptor))["channels"]
for channel in ("stable", "rc", "edge"):
    expected = f"{base}/catalog-{channel}.signed.json"
    if channels[channel]["catalog_url"] != expected:
        sys.exit(f"{channel}: {channels[channel]['catalog_url']} is not {expected}")
PY
  fail "the shipped descriptor reads every channel's catalog from the catalog base"
bash "$ROOT/scripts/make-release-descriptor" --public-key "$trust_root" --stopgap \
  --default-channel "$default_channel" --output "$test_tmp/stopgap.json" >/dev/null
python3 - "$test_tmp/stopgap.json" "$descriptor" "$INSTALLER_CATALOG_STOPGAP_REPO" <<'PY' ||
import json, sys
stopgap, shipped = (json.load(open(p)) for p in sys.argv[1:3])
repo = sys.argv[3]
for channel in ("stable", "rc", "edge"):
    expected = f"https://github.com/{repo}/releases/download/catalog-{channel}/catalog-{channel}.signed.json"
    if stopgap["channels"][channel]["catalog_url"] != expected:
        sys.exit(f"{channel}: {stopgap['channels'][channel]['catalog_url']} is not {expected}")
del stopgap["channels"], shipped["channels"]
if stopgap != shipped:
    sys.exit("the stopgap descriptor differs from the shipped one beyond its catalog URLs")
PY
  fail "make-release-descriptor --stopgap names each channel's stopgap catalog and changes nothing else"
if bash "$ROOT/scripts/make-release-descriptor" --public-key "$trust_root" --stopgap \
  --base-url https://probe.invalid --output "$test_tmp/both.json" >/dev/null 2>&1; then
  fail "make-release-descriptor refuses --stopgap with --base-url"
fi
for template in "$ROOT"/scripts/release-inputs*.template.json; do
  python3 - "$template" "$INSTALLER_PUBLIC_BASE/$INSTALLER_STREAM_PATH" "$INSTALLER_FILE_STEM" <<'PY' ||
import json, sys
template, base, stem = sys.argv[1:4]
installer = json.load(open(template))["installer"]
version = installer["latest_version"]
expected = f"{base}/installer/{version}/{stem}-{version}.zip"
if installer["download_url"] != expected:
    sys.exit(f"{template}: download_url {installer['download_url']} is not {expected}")
PY
    fail "release input templates point at the configured installer download"
done
pass "release inputs are derived from identity.conf"

# Values set here must not be repeated in code, scripts or tests. Docs,
# recorded evidence and the derived release inputs checked above may name them.
guarded=(
  "$INSTALLER_APP_NAME" "$INSTALLER_LEGACY_APP_NAME" "$INSTALLER_FILE_STEM" "$INSTALLER_APP_IDENTIFIER"
  "$INSTALLER_HELPER_IDENTIFIER" "$INSTALLER_PKG_IDENTIFIER" "$INSTALLER_TEAM_ID"
  "$INSTALLER_CATALOG_KEY_SERVICE" "${INSTALLER_CATALOG_BASE#https://}" "${INSTALLER_PUBLIC_BASE#https://}"
  "$INSTALLER_R2_BUCKET" "${INSTALLER_R2_ENDPOINT#https://}"
  "$INSTALLER_GITHUB_RELEASE_REPO" "$INSTALLER_GITHUB_RELEASE_LOGIN"
  "$trust_root_digest"
)
patterns=()
for value in "${guarded[@]}"; do
  patterns+=(-e "$value")
done
git -C "$ROOT" ls-files -z >"$test_tmp/tracked" || fail "git lists the tracked files"
mapfile -d '' -t tracked <"$test_tmp/tracked"
exempt='^(docs|evidence|Design)/|\.md$|^Packaging/identity\.conf$|^Release/release\.json$|^scripts/release-inputs.*\.template\.json$'
scanned=()
for file in "${tracked[@]}"; do
  # A submodule gitlink is a directory, not a file to scan.
  [[ $file =~ $exempt || -d $ROOT/$file ]] && continue
  scanned+=("$file")
done
(( ${#scanned[@]} > 100 )) || fail "the repeated-value scan covers the repository" "${#scanned[@]} files"
python3 - "$ROOT/Engine/overlay/src/omarchy_recovery.py" "$ROOT/Recovery/Resources/en.lproj/InfoPlist.strings" "$INSTALLER_RECOVERY_APP_NAME" <<'PYCODE'
import ast
from pathlib import Path
import sys
source, strings, name = sys.argv[1:]
assignments = {node.targets[0].id: ast.literal_eval(node.value)
               for node in ast.parse(Path(source).read_text()).body
               if isinstance(node, ast.Assign) and len(node.targets) == 1
               and isinstance(node.targets[0], ast.Name) and node.targets[0].id == "APP_NAME"}
assert assignments["APP_NAME"] == name + ".app", "Recovery identity differs from locked engine protocol"
assert '"CFBundleDisplayName" = "' + name + '";' in Path(strings).read_text()
PYCODE

# The native Recovery app's bundle/display name is also the paired-Recovery
# engine protocol: the locked engine and its fixtures require those bytes.
# Exempt that one Recovery-name value only in the protocol implementation;
# every other identity/hosting value remains checked in those same files.
hits=""
for value in "${guarded[@]}"; do
  checked=()
  for file in "${scanned[@]}"; do
    if [[ $value == "$INSTALLER_RECOVERY_APP_NAME" ]]; then
      case "$file" in
        Recovery/*|Engine/overlay/src/omarchy_recovery.py|Engine/overlay/tests/test_omarchy_asahi.py|Engine/overlay/tests/test_omarchy_recovery.py|Packaging/build-app.sh)
          continue ;;
      esac
    fi
    checked+=("$file")
  done
  status=0
  found=$(cd "$ROOT" && grep -n -I -F -e "$value" -- "${checked[@]}") || status=$?
  (( status <= 1 )) || fail "identity scan reads every selected file"
  [[ -z $found ]] || hits+="$found"$'\n'
done
[[ -z $hits ]] || fail "identity and hosting values live only in Packaging/identity.conf outside the fixed Recovery protocol" "$hits"
pass "no code, script or test repeats an identity or hosting value, the image producer included"

# A different configuration changes what the packaging scripts produce.
cat >"$test_tmp/identity.conf" <<'CONF'
INSTALLER_APP_NAME="Identity Probe Installer"
INSTALLER_HELPER_IDENTIFIER="invalid.omarchy.identity-probe.helper"
CONF
cp "$ROOT/Packaging/pkg/scripts/postinstall" "$test_tmp/postinstall"
if bash "$test_tmp/postinstall" >"$test_tmp/postinstall.log" 2>&1; then
  fail "postinstall fails when the configured daemon plist is absent"
fi
grep -Fq "daemon plist is missing: /Library/LaunchDaemons/invalid.omarchy.identity-probe.helper.plist" \
  "$test_tmp/postinstall.log" ||
  fail "postinstall takes the helper label from the identity shipped beside it" "$(cat "$test_tmp/postinstall.log")"
grep -Fq '"$PKG_DIR/../identity.conf" "$scripts/identity.conf"' "$ROOT/Packaging/pkg/build-pkg.sh" ||
  fail "build-pkg.sh ships identity.conf beside postinstall"
grep -Fq -- '--scripts "$scripts"' "$ROOT/Packaging/pkg/build-pkg.sh" ||
  fail "build-pkg.sh packages the staged scripts"

mkdir -p "$test_tmp/tree/Packaging" "$test_tmp/tree/scripts"
cp "$ROOT/scripts/make-release-descriptor" "$test_tmp/tree/scripts/"
sed -e 's/^INSTALLER_HELPER_IDENTIFIER=.*/INSTALLER_HELPER_IDENTIFIER="invalid.omarchy.identity-probe.helper"/' \
  -e 's/^INSTALLER_TEAM_ID=.*/INSTALLER_TEAM_ID="PROBE12345"/' \
  "$config" >"$test_tmp/tree/Packaging/identity.conf"
bash "$test_tmp/tree/scripts/make-release-descriptor" \
  --public-key "$trust_root" --base-url https://probe.invalid \
  --output "$test_tmp/probe.json" >/dev/null
python3 - "$test_tmp/probe.json" <<'PY' || fail "make-release-descriptor takes the helper and team from identity.conf"
import json, sys
descriptor = json.load(open(sys.argv[1]))
assert descriptor["helper_mach_service_name"] == "invalid.omarchy.identity-probe.helper"
assert descriptor["helper_code_signing_requirement"].endswith(
    'identifier "invalid.omarchy.identity-probe.helper" and certificate leaf[subject.OU] = "PROBE12345"'
)
PY
pass "packaging scripts follow a changed identity.conf"
