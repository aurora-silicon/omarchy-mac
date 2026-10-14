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
for name in INSTALLER_APP_NAME INSTALLER_RECOVERY_APP_NAME INSTALLER_LEGACY_APP_NAME INSTALLER_FILE_STEM INSTALLER_APP_IDENTIFIER \
  INSTALLER_HELPER_IDENTIFIER INSTALLER_PKG_IDENTIFIER INSTALLER_TEAM_ID \
  INSTALLER_APP_SIGNING_IDENTITY INSTALLER_PKG_SIGNING_IDENTITY INSTALLER_TRUST_ROOT_FINGERPRINT \
  INSTALLER_CATALOG_KEY_SERVICE INSTALLER_PUBLIC_BASE INSTALLER_STREAM_PATH INSTALLER_R2_BUCKET \
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
# One path segment: the stream must never be the bucket root, where the MX Mac
# feeds live, nor reach into another stream.
[[ $INSTALLER_STREAM_PATH =~ ^[a-z0-9][a-z0-9-]*$ ]] ||
  fail "the stream path is one lowercase path segment"
trust_root=$ROOT/Release/trust-root.ed25519.pub
[[ -f $trust_root && ! -L $trust_root && $(wc -c <"$trust_root") -eq 32 ]] ||
  fail "the trust root is a 32-byte public key"
[[ $INSTALLER_TRUST_ROOT_FINGERPRINT == "sha256:$(sha256sum "$trust_root" | cut -d' ' -f1)" ]] ||
  fail "Release/trust-root.ed25519.pub is the configured trust root"
pass "identity.conf is well formed and internally consistent"

# Release inputs that embed identity or hosting must be derived from it.
descriptor=$ROOT/Release/release.json
default_channel=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["default_channel"])' "$descriptor")
bash "$ROOT/scripts/make-release-descriptor" \
  --public-key "$trust_root" \
  --base-url "$INSTALLER_PUBLIC_BASE/$INSTALLER_STREAM_PATH" \
  --default-channel "$default_channel" \
  --output "$test_tmp/release.json" >/dev/null
cmp -s "$test_tmp/release.json" "$descriptor" ||
  fail "Release/release.json is what make-release-descriptor writes from identity.conf" \
    "$(diff "$test_tmp/release.json" "$descriptor" || true)"
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

# Recovery is a separate product contract in the immutable admitted engine.
# Validate its exact source hashes and AST constant before accounting for those
# frozen literals in the scan; changing Recovery requires updating the engine
# contract through its own qualification workflow. No live app code is exempt.
python3 - "$ROOT" "$INSTALLER_RECOVERY_APP_NAME" "$test_tmp/frozen-recovery-files" <<'PY'
import ast, hashlib, json, pathlib, shutil, sys, tempfile
paths = ["overlay/src/omarchy_recovery.py", "overlay/tests/test_omarchy_asahi.py"]

def validate_contract(root, configured_name):
    entries = json.loads((root / "Engine/source-lock.json").read_text())["downstream_overlay"]["files"]
    for path in paths:
        entry = next(item for item in entries if item["path"] == path)
        if hashlib.sha256((root / "Engine" / path).read_bytes()).hexdigest() != entry["sha256"]:
            raise ValueError("frozen Recovery source differs from source-lock: " + path)
    module = ast.parse((root / "Engine" / paths[0]).read_text())
    name = next(ast.literal_eval(node.value) for node in module.body
                if isinstance(node, ast.Assign)
                and any(isinstance(target, ast.Name) and target.id == "APP_NAME" for target in node.targets))
    if name != configured_name + ".app":
        raise ValueError("configured Recovery name disagrees with the frozen engine contract")
    fixture = ast.parse((root / "Engine" / paths[1]).read_text())
    expected = "esp/aurora/recovery/" + name + "/Contents/MacOS/OmarchyRecovery"
    if expected not in [node.value for node in ast.walk(fixture) if isinstance(node, ast.Constant)]:
        raise ValueError("frozen engine fixture disagrees with its Recovery name")

root = pathlib.Path(sys.argv[1])
try:
    validate_contract(root, sys.argv[2])
except ValueError as error:
    sys.exit("identity: " + str(error))
# Negative fixtures prove changing the Recovery identity or frozen source fails
# before any literal can be filtered from the identity scan.
try:
    validate_contract(root, sys.argv[2] + " Alternate")
except ValueError:
    pass
else:
    sys.exit("identity: changed Recovery contract was accepted")
with tempfile.TemporaryDirectory() as directory:
    probe = pathlib.Path(directory)
    for path in ["source-lock.json", *paths]:
        destination = probe / "Engine" / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(root / "Engine" / path, destination)
    changed = probe / "Engine" / paths[0]
    changed.write_text(changed.read_text() + "\n# altered frozen source\n")
    try:
        validate_contract(probe, sys.argv[2])
    except ValueError:
        pass
    else:
        sys.exit("identity: changed frozen source was accepted")
pathlib.Path(sys.argv[3]).write_text("\n".join("Engine/" + path for path in paths) + "\n")
PY
pass "the separate Recovery identity matches exact source-locked engine bytes"

# Values set here must not be repeated in code, scripts or tests. Docs,
# recorded evidence and the derived release inputs checked above may name them.
guarded=(
  "$INSTALLER_APP_NAME" "$INSTALLER_LEGACY_APP_NAME" "$INSTALLER_FILE_STEM" "$INSTALLER_APP_IDENTIFIER"
  "$INSTALLER_HELPER_IDENTIFIER" "$INSTALLER_PKG_IDENTIFIER" "$INSTALLER_TEAM_ID"
  "$INSTALLER_CATALOG_KEY_SERVICE" "${INSTALLER_PUBLIC_BASE#https://}"
  "$INSTALLER_R2_BUCKET" "${INSTALLER_R2_ENDPOINT#https://}"
  "$INSTALLER_GITHUB_RELEASE_REPO" "$INSTALLER_GITHUB_RELEASE_LOGIN"
  "${INSTALLER_TRUST_ROOT_FINGERPRINT#sha256:}"
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
status=0
hits=$(cd "$ROOT" && grep -n -I -F "${patterns[@]}" -- "${scanned[@]}") || status=$?
(( status <= 1 )) || fail "the repeated-value scan completed" "$hits"
# Every file was scanned. Only the already hash/AST-validated frozen engine
# literals may coincide with the main default name; other guarded values there
# and every literal in live code still fail the invariant.
hits=$(printf '%s' "$hits" | python3 -c '
import pathlib, sys
frozen = set(pathlib.Path(sys.argv[1]).read_text().splitlines())
main, recovery, guarded = sys.argv[2], sys.argv[3], sys.argv[4:]
for line in sys.stdin.read().splitlines():
    path, _, text = line.split(":", 2)
    matching = {value for value in guarded if value in text}
    if path in frozen and main == recovery and matching == {main}:
        continue
    print(line)
' "$test_tmp/frozen-recovery-files" "$INSTALLER_APP_NAME" "$INSTALLER_RECOVERY_APP_NAME" "${guarded[@]}")
[[ -z $hits ]] || fail "identity and hosting values live only in Packaging/identity.conf or the validated frozen Recovery contract" "$hits"
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

frozen_recovery_name="$INSTALLER_RECOVERY_APP_NAME.app"
sed 's/^INSTALLER_APP_NAME=.*/INSTALLER_APP_NAME="Alternate Product Installer"/' \
  "$config" >"$test_tmp/alternate.conf"
(
  source "$test_tmp/alternate.conf"
  [[ $INSTALLER_APP_NAME == "Alternate Product Installer" ]]
  [[ $INSTALLER_RECOVERY_APP_NAME.app == "$frozen_recovery_name" ]]
) || fail "alternate main branding preserves the frozen Recovery product identity"
pass "main installer branding can vary independently of canonical Recovery identity"
