#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
source "$ROOT/Packaging/identity.conf"
helper_id=$INSTALLER_HELPER_IDENTIFIER

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

pkg_dir=$ROOT/Packaging/pkg
derive=$pkg_dir/derive-daemon-plist

make_app() {
  local app=$1 bundle_program=$2 helper=${3:-Contents/Library/LaunchServices/$helper_id}
  mkdir -p "$app/Contents/Library/LaunchDaemons" "$app/$(dirname "$helper")"
  printf '#!/bin/sh\n' >"$app/$helper"
  python3 - "$app/Contents/Library/LaunchDaemons/$helper_id.plist" "$bundle_program" "$helper_id" <<'PY'
import plistlib, sys
plistlib.dump({
    "Label": sys.argv[3],
    "BundleProgram": sys.argv[2],
    "MachServices": {sys.argv[3]: True},
    "UserName": "root",
    "KeepAlive": False,
    "EnvironmentVariables": {"OMARCHY_CLIENT_CODE_SIGNING_REQUIREMENT": "anchor apple generic"},
}, open(sys.argv[1], "wb"))
PY
}

read_plist() {
  python3 -c 'import plistlib, sys, json; print(json.dumps(plistlib.load(open(sys.argv[1], "rb")), sort_keys=True))' "$1"
}

app="$test_tmp/$INSTALLER_APP_NAME.app"
make_app "$app" Contents/Library/LaunchServices/$helper_id
out=$test_tmp/daemon.plist
program=$("$derive" "$app" "$out" /Applications)
[[ $program == "/Applications/$INSTALLER_APP_NAME.app/Contents/Library/LaunchServices/$helper_id" ]] ||
  fail "the derived daemon Program is the helper's absolute path under /Applications"
derived=$(read_plist "$out")
grep -Fq "\"Program\": \"/Applications/$INSTALLER_APP_NAME.app/Contents/Library/LaunchServices/$helper_id\"" <<<"$derived" ||
  fail "the derived plist records the absolute Program"
! grep -Fq '"BundleProgram"' <<<"$derived" || fail "the derived plist drops the bundle-relative BundleProgram"
grep -Fq "\"Label\": \"$helper_id\"" <<<"$derived" || fail "the derived plist keeps the Label"
grep -Fq "\"$helper_id\": true" <<<"$derived" || fail "the derived plist keeps the Mach service"
grep -Fq '"UserName": "root"' <<<"$derived" || fail "the derived plist keeps the root UserName"
grep -Fq 'OMARCHY_CLIENT_CODE_SIGNING_REQUIREMENT' <<<"$derived" || fail "the derived plist keeps the client requirement"
pass "the system daemon plist is derived with an absolute Program inside the installed app"

app_missing="$test_tmp/Missing.app"
make_app "$app_missing" Contents/Library/LaunchServices/$helper_id
rm "$app_missing/Contents/Library/LaunchServices/$helper_id"
if "$derive" "$app_missing" "$test_tmp/missing.plist" /Applications >/dev/null 2>&1; then
  fail "derivation rejects a helper that is missing inside the app"
fi
app_escape="$test_tmp/Escape.app"
make_app "$app_escape" ../../../usr/bin/true
if "$derive" "$app_escape" "$test_tmp/escape.plist" /Applications >/dev/null 2>&1; then
  fail "derivation rejects a BundleProgram that escapes the bundle"
fi
app_absolute="$test_tmp/Absolute.app"
make_app "$app_absolute" /usr/bin/true
if "$derive" "$app_absolute" "$test_tmp/absolute.plist" /Applications >/dev/null 2>&1; then
  fail "derivation rejects an absolute BundleProgram"
fi
pass "derivation fails closed on missing, escaping, or absolute helper paths"

! grep -Eq 'launchctl bootstrap system "\$PLIST" 2>/dev/null \|\|' "$pkg_dir/scripts/postinstall" ||
  fail "postinstall no longer hides launchctl bootstrap failures"
grep -Fq 'exit 1' "$pkg_dir/scripts/postinstall" || fail "postinstall fails the package when the daemon cannot load"
grep -Fq 'derive-daemon-plist' "$pkg_dir/build-pkg.sh" || fail "build-pkg.sh derives the daemon plist"
grep -Fq 'daemon Program must be an absolute path' "$pkg_dir/build-pkg.sh" || fail "build-pkg.sh fails on a non-absolute daemon Program"
pass "the package builder and postinstall fail closed on an unloadable daemon"

# Pure fixtures exercise exact derivation without signing or registering a helper.
mkdir "$test_tmp/bin"
cat >"$test_tmp/bin/codesign" <<'SH'
#!/bin/bash
set -euo pipefail
if [[ $1 == "--display" ]]; then
  target=${!#}
  if [[ $target == *.app ]]; then
    echo CDHash=1111111111111111111111111111111111111111 >&2
  else
    echo CDHash=2222222222222222222222222222222222222222 >&2
  fi
else
  [[ ${MOCK_REJECT_SEAL:-0} != "1" ]]
fi
SH
chmod +x "$test_tmp/bin/codesign"
export PATH="$test_tmp/bin:$PATH"
exact_app="$test_tmp/Exact.app"
make_app "$exact_app" Contents/Library/LaunchServices/$helper_id
mkdir -p "$exact_app/Contents/Resources/Release"
python3 - "$exact_app" "$helper_id" <<'PY'
import json, pathlib, plistlib, sys
app = pathlib.Path(sys.argv[1])
plistlib.dump({"OmarchyExactBuild": True, "OmarchyDeveloperBuild": True},
             open(app / "Contents/Info.plist", "wb"))
path = app / ("Contents/Library/LaunchDaemons/" + sys.argv[2] + ".plist")
plist = plistlib.loads(path.read_bytes())
plist["EnvironmentVariables"]["OMARCHY_CLIENT_CODE_SIGNING_REQUIREMENT"] = "never"
path.write_bytes(plistlib.dumps(plist))
(app / "Contents/Resources/Release/release.json").write_text(json.dumps({
    "helper_code_signing_requirement": 'identifier "' + sys.argv[2] + '" and cdhash H"' + "2" * 40 + '"'
}))
PY
"$derive" "$exact_app" "$test_tmp/exact.plist" /Applications >/dev/null
python3 - "$test_tmp/exact.plist" "$INSTALLER_APP_IDENTIFIER" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as handle:
    requirement = plistlib.load(handle)["EnvironmentVariables"]["OMARCHY_CLIENT_CODE_SIGNING_REQUIREMENT"]
assert requirement == 'identifier "' + sys.argv[2] + '" and cdhash H"' + "1" * 40 + '"'
PY
for mismatch in label program both; do
  bad_app="$test_tmp/Exact-$mismatch.app"
  cp -R "$exact_app" "$bad_app"
  python3 - "$bad_app" "$helper_id" "$mismatch" <<'PY'
import pathlib, plistlib, sys
app = pathlib.Path(sys.argv[1])
path = app / ("Contents/Library/LaunchDaemons/" + sys.argv[2] + ".plist")
plist = plistlib.loads(path.read_bytes())
if sys.argv[3] in ("label", "both"):
    plist["Label"] = "com.example.unexpected.helper"
if sys.argv[3] in ("program", "both"):
    plist["BundleProgram"] = "Contents/Library/LaunchServices/com.example.unexpected.helper"
    (app / plist["BundleProgram"]).write_text("unexpected helper")
path.write_bytes(plistlib.dumps(plist))
PY
  if "$derive" "$bad_app" "$test_tmp/$mismatch.plist" >/dev/null 2>&1; then
    fail "exact derivation rejects a noncanonical $mismatch"
  fi
done
# Reject the override before any packaging/signing command can run.
if "$pkg_dir/build-pkg.sh" --app "$exact_app" --version 2.1.0 \
  --out "$test_tmp/unused.pkg" --plist "$out" >"$test_tmp/override.log" 2>&1; then
  fail "exact package rejects an identifier-only external plist override"
fi
grep -Fq -- '--plist is forbidden for exact builds' "$test_tmp/override.log" ||
  fail "exact package rejects the override at the identity boundary"
pass "exact packages reject noncanonical helper labels/paths and explicit daemon overrides"

if MOCK_REJECT_SEAL=1 "$derive" "$exact_app" "$test_tmp/rejected.plist" >/dev/null 2>&1; then
  fail "exact derivation rejects an invalid app seal"
fi
python3 - "$exact_app/Contents/Resources/Release/release.json" <<'PY'
import json, sys
with open(sys.argv[1], "w") as handle:
    json.dump({"helper_code_signing_requirement": "identifier only"}, handle)
PY
if "$derive" "$exact_app" "$test_tmp/wrong-helper.plist" >/dev/null 2>&1; then
  fail "exact derivation rejects a stale helper requirement"
fi
python3 - "$exact_app/Contents/Library/LaunchDaemons/$helper_id.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as handle:
    plist = plistlib.load(handle)
plist["EnvironmentVariables"]["OMARCHY_CLIENT_CODE_SIGNING_REQUIREMENT"] = "identifier only"
with open(sys.argv[1], "wb") as handle:
    plistlib.dump(plist, handle)
PY
if "$derive" "$exact_app" "$test_tmp/usable-embedded.plist" >/dev/null 2>&1; then
  fail "exact derivation rejects usable embedded registration"
fi
pass "exact developer fixtures bind the sealed client and reject broken seals, helper identities, or embedded registration"
