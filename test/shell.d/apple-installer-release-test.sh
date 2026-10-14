#!/bin/bash
# The app release workflow and its scripts: what each trigger may do, the
# signing order and flags, the publishing refusals, and the workflow's
# security invariants. Stubs stand in for codesign and gh, so this runs on any
# host (Bash 3.2 too, for the macOS runner); the notarization flow needs macOS (hdiutil, plutil) and
# is skipped elsewhere. The real signing runs in the workflow's dry run.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
source "$ROOT/Packaging/identity.conf"

release=$ROOT/Packaging/release
workflow=$ROOT/.github/workflows/mac-app-release.yml
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

# ── plan: what each trigger may do ─────────────────────────────────────────
plan() {
  env -i PATH="$PATH" "$@" bash "$release/plan" 2>&1
}
expect_plan() {
  local description=$1 expected=$2 output
  shift 2
  output=$(plan "$@") || fail "$description" "$output"
  [[ $output == *"$expected"* ]] || fail "$description" "$output"
  pass "$description"
}
refuse_plan() {
  local description=$1 output
  shift
  if output=$(plan "$@"); then
    fail "$description" "$output"
  fi
  pass "$description"
}

expect_plan "a pushed v* tag is a Developer ID release of the tag's version" \
  $'dry_run=false\nsigning=developer-id\nversion=2.2.0\nbuild_number=107\nstand_in_trust_root=false' \
  EVENT=push REF=refs/tags/v2.2.0 RUN_NUMBER=7
expect_plan "a dispatch defaults to an ad hoc dry run" \
  $'dry_run=true\nsigning=ad-hoc\nversion=0.0.0-dry-run' \
  EVENT=workflow_dispatch REF=refs/heads/some-branch RUN_NUMBER=1 VERSION=0.0.0-dry-run
expect_plan "main may dry-run with the Developer ID (to test the secrets)" "signing=developer-id" \
  EVENT=workflow_dispatch REF=refs/heads/main RUN_NUMBER=1 DRY_RUN=true SIGNING=developer-id VERSION=2.2.0
expect_plan "a dispatch on a v* tag takes the tag's version" "version=2.3.0" \
  EVENT=workflow_dispatch REF=refs/tags/v2.3.0 RUN_NUMBER=1 DRY_RUN=false SIGNING=developer-id
refuse_plan "pull requests never run the release" EVENT=pull_request REF=refs/pull/1/merge RUN_NUMBER=1
refuse_plan "pull_request_target never runs the release" EVENT=pull_request_target REF=refs/heads/main RUN_NUMBER=1
refuse_plan "a push to a branch is not a release" EVENT=push REF=refs/heads/main RUN_NUMBER=1
refuse_plan "a tag that is not v<version> is refused" EVENT=push REF=refs/tags/vnext RUN_NUMBER=1
refuse_plan "a release version is plain X.Y.Z (the app compares only that)" EVENT=push REF=refs/tags/v2.2.0-preview.2 RUN_NUMBER=1
refuse_plan "only a v* tag publishes" \
  EVENT=workflow_dispatch REF=refs/heads/main RUN_NUMBER=1 DRY_RUN=false SIGNING=developer-id VERSION=2.2.0
refuse_plan "a release is never ad hoc" \
  EVENT=workflow_dispatch REF=refs/tags/v2.2.0 RUN_NUMBER=1 DRY_RUN=false SIGNING=ad-hoc
refuse_plan "the Developer ID signs only main and v* tags" \
  EVENT=workflow_dispatch REF=refs/heads/feature RUN_NUMBER=1 DRY_RUN=true SIGNING=developer-id VERSION=2.2.0
refuse_plan "a stand-in trust root never meets the Developer ID" \
  EVENT=workflow_dispatch REF=refs/heads/main RUN_NUMBER=1 SIGNING=developer-id STAND_IN_TRUST_ROOT=true VERSION=2.2.0
refuse_plan "a tag dispatch cannot override the tag's version" \
  EVENT=workflow_dispatch REF=refs/tags/v2.2.0 RUN_NUMBER=1 VERSION=9.9.9

# ── sign-app: inside-out, hardened runtime, timestamps, never --deep ───────
stubs=$test_tmp/stubs
mkdir -p "$stubs"
cat >"$stubs/codesign" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$CODESIGN_LOG"
case " $* " in
  *" --display "*)
    if [[ $STUB_SIGNATURE == adhoc ]]; then
      printf 'CodeDirectory v=20500 size=1 flags=0x10002(adhoc,runtime) hashes=1+0\nSignature=adhoc\n' >&2
    else
      printf 'CodeDirectory v=20500 size=1 flags=0x10000(runtime) hashes=1+0\n' >&2
      printf 'Authority=Developer ID Application: Someone (%s)\nTimestamp=1 Jan 2027\nTeamIdentifier=%s\n' \
        "$STUB_TEAM" "$STUB_TEAM" >&2
    fi
    ;;
esac
STUB
chmod +x "$stubs/codesign"
app=$test_tmp/$INSTALLER_APP_NAME.app
mkdir -p "$app/Contents/Library/LaunchServices"
: >"$app/Contents/Library/LaunchServices/$INSTALLER_HELPER_IDENTIFIER"
helper=$app/Contents/Library/LaunchServices/$INSTALLER_HELPER_IDENTIFIER

sign() {
  CODESIGN_LOG=$test_tmp/codesign.log PATH="$stubs:$PATH" STUB_TEAM=$INSTALLER_TEAM_ID "$@"
}
: >"$test_tmp/codesign.log"
sign env STUB_SIGNATURE=devid bash "$release/sign-app" "$app" "Developer ID Application: Someone ($INSTALLER_TEAM_ID)" \
  "$test_tmp/release.keychain-db" >/dev/null || fail "sign-app signs with a Developer ID"
signing=()
while IFS= read -r line; do
  signing+=("$line")
done < <(grep -e '--sign ' "$test_tmp/codesign.log")
(( ${#signing[@]} == 2 )) || fail "sign-app signs exactly the helper and the app" "$(cat "$test_tmp/codesign.log")"
[[ ${signing[0]} == *"--identifier $INSTALLER_HELPER_IDENTIFIER $helper" ]] ||
  fail "the helper is signed first, under its own identifier" "${signing[0]}"
[[ ${signing[1]} == *" $app" && ${signing[1]} != *"--identifier"* ]] || fail "the app is signed second" "${signing[1]}"
for line in "${signing[@]}"; do
  [[ " $line " == *" --options runtime "* && " $line " == *" --timestamp "* ]] ||
    fail "every Developer ID signature has the hardened runtime and a secure timestamp" "$line"
  [[ " $line " == *" --keychain $test_tmp/release.keychain-db "* ]] || fail "signing reads only the given keychain" "$line"
  [[ " $line " != *" --deep "* && " $line " != *" --entitlements"* ]] ||
    fail "signing never uses --deep or entitlements" "$line"
done
grep -qF -- "-R=anchor apple generic and identifier \"$INSTALLER_HELPER_IDENTIFIER\" and certificate leaf[subject.OU] = \"$INSTALLER_TEAM_ID\" $helper" \
  "$test_tmp/codesign.log" || fail "the helper is verified against the team's designated requirement"
grep -qF -- "-R=anchor apple generic and identifier \"$INSTALLER_APP_IDENTIFIER\" and certificate leaf[subject.OU] = \"$INSTALLER_TEAM_ID\" $app" \
  "$test_tmp/codesign.log" || fail "the app is verified against the team's designated requirement"
pass "sign-app signs the helper then the app with runtime and timestamps, never --deep, and checks both requirements"

: >"$test_tmp/codesign.log"
sign env STUB_SIGNATURE=adhoc bash "$release/sign-app" "$app" - >/dev/null || fail "sign-app signs ad hoc"
grep -e '--sign ' "$test_tmp/codesign.log" | grep -qv -e '--timestamp=none' &&
  fail "an ad hoc dry run asks for no timestamp" "$(cat "$test_tmp/codesign.log")"
grep -qF -- "-R=identifier \"$INSTALLER_HELPER_IDENTIFIER\" $helper" "$test_tmp/codesign.log" ||
  fail "an ad hoc helper is verified by its identifier"
pass "sign-app signs a dry run ad hoc with the same order"

if sign env STUB_SIGNATURE=adhoc bash "$release/sign-app" "$app" "Developer ID Application: Someone ($INSTALLER_TEAM_ID)" \
  >/dev/null 2>&1; then
  fail "sign-app refuses a Developer ID run whose signature is ad hoc"
fi
sed 's/^      printf .Authority=Developer ID Application: Someone (%s)\\nTimestamp=1 Jan 2027\\n/      printf '"'"'Authority=Developer ID Application: Someone (%s)\\n/' \
  "$stubs/codesign" >"$stubs/codesign.untimestamped"
grep -q Timestamp "$stubs/codesign.untimestamped" && fail "the untimestamped stub drops the timestamp"
mkdir -p "$test_tmp/untimestamped"
install -m 755 "$stubs/codesign.untimestamped" "$test_tmp/untimestamped/codesign"
if CODESIGN_LOG=/dev/null PATH="$test_tmp/untimestamped:$PATH" STUB_TEAM=$INSTALLER_TEAM_ID STUB_SIGNATURE=devid \
  bash "$release/sign-app" "$app" "Developer ID Application: Someone ($INSTALLER_TEAM_ID)" >/dev/null 2>&1; then
  fail "sign-app refuses a Developer ID signature without a secure timestamp"
fi
pass "sign-app refuses a signature without the Developer ID team and timestamp"

# ── publish-app: draft only, never latest, never replace, built commit ────
dmg_dir=$test_tmp/out
mkdir -p "$dmg_dir"
dmg=$dmg_dir/$INSTALLER_FILE_STEM-2.2.0.dmg
printf 'dmg bytes' >"$dmg"
(cd "$dmg_dir" && shasum -a 256 "${dmg##*/}" >"${dmg##*/}.sha256")
# A stateful stand-in for gh: GH_SERVER holds the draft's assets, GH_STATE is
# missing, draft or published, GH_TAGGED is the commit the tag names.
cat >"$stubs/gh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$GH_LOG"
case "$1 $2" in
  "api repos/"*) echo "$GH_TAGGED" ;;
  "release view")
    if [[ $* == *isDraft* ]]; then
      [[ $GH_STATE == missing ]] && { echo "release not found" >&2; exit 1; }
      [[ $GH_STATE == published ]] && echo false || echo true
    else
      ls "$GH_SERVER"
    fi
    ;;
  "release create") ;;
  "release upload")
    shift 5
    for file in "$@"; do
      if [[ -n ${GH_CORRUPT:-} ]]; then printf 'corrupt' >"$GH_SERVER/${file##*/}"; else cp "$file" "$GH_SERVER/"; fi
    done
    ;;
  "release download")
    args=("$@")
    dir=${args[${#args[@]} - 1]}
    mkdir -p "$dir"
    for (( i = 0; i < ${#args[@]}; i++ )); do
      if [[ ${args[i]} == -p ]]; then cp "$GH_SERVER/${args[i + 1]}" "$dir/"; fi
    done
    ;;
esac
exit 0
STUB
chmod +x "$stubs/gh"
server=$test_tmp/server
publish() {
  GH_LOG=$test_tmp/gh.log GH_SERVER=$server GH_TAGGED=built GITHUB_REPOSITORY=owner/repo RELEASE_COMMIT=built \
    PATH="$stubs:$PATH" "$@" bash "$release/publish-app" --target github-release --version 2.2.0 "$dmg" "$dmg.sha256" 2>&1
}
fresh() {
  rm -rf "$server"
  mkdir -p "$server"
  : >"$test_tmp/gh.log"
}

fresh
output=$(publish env GH_STATE=missing) || fail "publish-app creates a draft for a new version" "$output"
create=$(grep '^release create' "$test_tmp/gh.log")
for flag in "release create v2.2.0" --verify-tag --draft --prerelease --latest=false; do
  [[ " $create " == *" $flag "* ]] || fail "the release is a draft prerelease on the existing tag, never latest" "$create"
done
cmp -s "$dmg" "$server/${dmg##*/}" && cmp -s "$dmg.sha256" "$server/${dmg##*/}.sha256" ||
  fail "publish-app uploads the dmg and its sha256"
grep -q '^release download v2.2.0' "$test_tmp/gh.log" || fail "publish-app downloads its files back"
pass "publish-app creates a draft prerelease, never latest, and checks what it uploaded"

fresh
output=$(publish env GH_STATE=missing GH_TAGGED=other) && fail "publish-app refuses a tag that moved" "$output"
[[ $output == *"not the built commit"* ]] || fail "publish-app refuses a tag that moved" "$output"
pass "publish-app publishes only the commit the workflow built"

fresh
output=$(publish env GH_STATE=published) && fail "publish-app refuses a published release" "$output"
[[ $output == *"already published"* ]] || fail "publish-app refuses a published release" "$output"
fresh
printf 'other dmg' >"$server/${dmg##*/}"
output=$(publish env GH_STATE=draft) && fail "publish-app refuses to replace a file" "$output"
[[ $output == *"never replaced"* && $(cat "$server/${dmg##*/}") == "other dmg" ]] ||
  fail "publish-app refuses to replace a file" "$output"
pass "publish-app never changes a published release or replaces a file"

fresh
cp "$dmg" "$server/"
output=$(publish env GH_STATE=draft) || fail "publish-app finishes an interrupted upload" "$output"
grep -q "^release upload v2.2.0 -R owner/repo $dmg.sha256$" "$test_tmp/gh.log" ||
  fail "publish-app uploads only the missing file" "$(cat "$test_tmp/gh.log")"
pass "publish-app finishes an interrupted upload, keeping the identical file"

fresh
output=$(publish env GH_STATE=missing GH_CORRUPT=1) && fail "publish-app notices a corrupted upload" "$output"
[[ $output == *"differs from what was uploaded"* ]] || fail "publish-app notices a corrupted upload" "$output"
pass "publish-app downloads each file back and refuses one that changed"

printf 'other bytes' >"$dmg"
fresh
output=$(publish env GH_STATE=missing) && fail "publish-app refuses a dmg its sha256 does not match" "$output"
pass "publish-app refuses a dmg that does not match its sha256"
output=$(GH_LOG=/dev/null bash "$release/publish-app" --target r2 --version 2.2.0 "$dmg" "$dmg.sha256" 2>&1) &&
  fail "the r2 target is refused until ticket 13" "$output"
pass "the r2 target is refused until it exists"

# ── sign-and-package: the notarization flow (macOS) ────────────────────────
if [[ $(uname) == Darwin ]] && command -v hdiutil >/dev/null; then
  flow=$test_tmp/flow
  mkdir -p "$flow/bin"
  # A public app as build-app.sh assembles it for the Developer ID.
  python3 - "$flow/$INSTALLER_APP_NAME.app" "$INSTALLER_APP_IDENTIFIER" "$INSTALLER_HELPER_IDENTIFIER" \
    "$INSTALLER_TEAM_ID" "$INSTALLER_CATALOG_BASE" <<'PY'
import hashlib, json, os, plistlib, sys
app, app_id, helper_id, team, base = sys.argv[1:]
c = os.path.join(app, "Contents")
for d in ("MacOS", "Resources/Release", "Library/LaunchDaemons", "Library/LaunchServices"):
    os.makedirs(os.path.join(c, d))
req = lambda i: f'anchor apple generic and identifier "{i}" and certificate leaf[subject.OU] = "{team}"'
plistlib.dump({"CFBundleIdentifier": app_id, "CFBundleShortVersionString": "2.2.0",
               "SMPrivilegedExecutables": {helper_id: req(helper_id)}}, open(os.path.join(c, "Info.plist"), "wb"))
plistlib.dump({"EnvironmentVariables": {"OMARCHY_CLIENT_CODE_SIGNING_REQUIREMENT": req(app_id)}},
              open(os.path.join(c, f"Library/LaunchDaemons/{helper_id}.plist"), "wb"))
open(os.path.join(c, "MacOS/app"), "wb").write(b"app")
open(os.path.join(c, f"Library/LaunchServices/{helper_id}"), "wb").write(b"helper")
key = bytes(range(1, 33))
open(os.path.join(c, "Resources/Release/trust-root.ed25519.pub"), "wb").write(key)
json.dump({"channels": {ch: {"catalog_url": f"{base}/catalog-{ch}.signed.json"} for ch in ("stable", "rc", "edge")},
           "trust_root_fingerprint": "sha256:" + hashlib.sha256(key).hexdigest(),
           "helper_code_signing_requirement": req(helper_id)},
          open(os.path.join(c, "Resources/Release/release.json"), "w"))
PY
  sed 's|>>"$CODESIGN_LOG"|>>"$CODESIGN_LOG"; printf "codesign %s\\n" "$*" >>"$FLOW_LOG"|' "$stubs/codesign" >"$flow/bin/codesign"
  cat >"$flow/bin/xcrun" <<'STUB'
#!/bin/bash
printf 'xcrun %s\n' "$*" >>"$FLOW_LOG"
case "$1 $2" in
  "notarytool submit")
    [[ $NOTARY_STATUS == none ]] && { echo '{"message":"authentication failed"}'; exit 1; }
    printf '{"id":"submission-%s","status":"%s","message":"done"}\n' "${3##*/}" "$NOTARY_STATUS"
    ;;
  "notarytool log") printf '{"status":"%s","issues":null}\n' "$NOTARY_STATUS" >"${@: -1}" ;;
esac
exit 0
STUB
  printf '#!/bin/bash\nprintf "spctl %%s\\n" "$*" >>"$FLOW_LOG"\n' >"$flow/bin/spctl"
  chmod +x "$flow/bin/"*
  printf 'key' >"$flow/AuthKey.p8"
  package() {
    rm -rf "$flow/out" "$flow/work"
    mkdir -p "$flow/work"
    cp -R "$flow/$INSTALLER_APP_NAME.app" "$flow/work/"
    : >"$flow/log"
    FLOW_LOG=$flow/log CODESIGN_LOG=/dev/null STUB_SIGNATURE=devid STUB_TEAM=$INSTALLER_TEAM_ID \
      NOTARY_API_KEY=$flow/AuthKey.p8 NOTARY_API_KEY_ID=KEYID NOTARY_API_ISSUER_ID=issuer PATH="$flow/bin:$PATH" "$@" \
      bash "$release/sign-and-package" --app "$flow/work/$INSTALLER_APP_NAME.app" --output "$flow/out" \
      --identity "Developer ID Application: Someone ($INSTALLER_TEAM_ID)" --keychain "$flow/k.keychain-db" --notarize 2>&1
  }
  output=$(package env NOTARY_STATUS=Accepted) || fail "sign-and-package notarizes an accepted app and dmg" "$output"
  steps=$(grep -E -e '--sign |notarytool submit|stapler staple|stapler validate .*/mount/|spctl' "$flow/log" |
    sed -E -e "s|$INSTALLER_APP_NAME.app/Contents/Library/LaunchServices/||" -e 's|/[^ ]*/||g' -e 's/ --(key|key-id|issuer) [^ ]+//g' -e 's/^codesign --force --sign [^(]*\([^)]*\) /codesign /')
  expected="codesign --options runtime --timestamp --keychain k.keychain-db --identifier $INSTALLER_HELPER_IDENTIFIER $INSTALLER_HELPER_IDENTIFIER
codesign --options runtime --timestamp --keychain k.keychain-db $INSTALLER_APP_NAME.app
xcrun notarytool submit app.zip --wait --timeout 1h --output-format json
xcrun stapler staple $INSTALLER_APP_NAME.app
spctl --assess --type execute --verbose=4 $INSTALLER_APP_NAME.app
codesign --timestamp --keychain k.keychain-db release.dmg
xcrun notarytool submit release.dmg --wait --timeout 1h --output-format json
xcrun stapler staple release.dmg
spctl --assess --type open --context context:primary-signature --verbose=4 release.dmg
xcrun stapler validate $INSTALLER_APP_NAME.app
spctl --assess --type execute --verbose=4 $INSTALLER_APP_NAME.app"
  [[ $steps == "$expected" ]] || fail "sign-and-package signs, notarizes and staples the app, then the dmg, then checks the app inside" \
    "$(diff <(echo "$expected") <(echo "$steps"))"
  for file in "$INSTALLER_FILE_STEM-2.2.0.dmg" "$INSTALLER_FILE_STEM-2.2.0.dmg.sha256" notary-app.json notary-dmg.json; do
    [[ -f $flow/out/$file ]] || fail "sign-and-package writes $file" "$(ls "$flow/out")"
  done
  (cd "$flow/out" && shasum -a 256 -c "$INSTALLER_FILE_STEM-2.2.0.dmg.sha256" >/dev/null) || fail "the sha256 file matches the dmg"
  pass "sign-and-package notarizes and staples the app, then the dmg, checks both with Gatekeeper and keeps the notary logs"

  output=$(package env NOTARY_STATUS=Invalid) && fail "sign-and-package refuses a rejected notarization" "$output"
  [[ $output == *"notarization of app ended Invalid"* && ! -e $flow/out/$INSTALLER_FILE_STEM-2.2.0.dmg ]] ||
    fail "sign-and-package refuses a rejected notarization" "$output"
  output=$(package env NOTARY_STATUS=none) && fail "sign-and-package refuses a submission notarytool did not take" "$output"
  [[ $output == *"did not accept the app submission"* ]] || fail "sign-and-package refuses a failed submission" "$output"
  pass "sign-and-package stops at a rejected or failed notarization, with no dmg"
else
  echo "skip - sign-and-package's notarization flow needs macOS"
fi

# ── the workflow's security invariants ─────────────────────────────────────
triggers=$(awk '/^on:/{on=1; next} on && /^[^ ]/{exit} on && /^  [a-z_]+:/{sub(/:.*/, ""); print $1}' "$workflow")
[[ $triggers == $'push\nworkflow_dispatch' ]] || fail "the workflow runs only for pushes (v* tags) and dispatches" "$triggers"
push=$(awk '/^  push:/{p=1; next} p && /^  [a-z_]+:/{exit} p && !/^ *#/' "$workflow")
[[ $push == "    tags: ['v*']" ]] || fail "pushes run only for v* tags" "$push"
pass "pull requests cannot trigger the release workflow"

# Each job's lines, keyed by job id.
job_of() {
  awk -v job="$1" '/^jobs:/{in_jobs=1; next} in_jobs && /^  [a-z][a-z0-9-]*:$/{current=$1; sub(/:$/, "", current)} in_jobs && current == job' "$workflow"
}
jobs=$(awk '/^jobs:/{in_jobs=1; next} in_jobs && /^  [a-z][a-z0-9-]*:$/{sub(/:$/, "", $1); print $1}' "$workflow")
[[ $jobs == $'plan\nengine\nbuild\nsign-ad-hoc\nsign\npublish' ]] || fail "the workflow has the expected jobs" "$jobs"
for job in $jobs; do
  body=$(job_of "$job")
  if [[ $job == sign ]]; then
    grep -q '^    environment: macos-release$' <<<"$body" || fail "the sign job runs in the macos-release environment"
  else
    ! grep -q 'secrets\.' <<<"$body" || fail "only the sign job reads secrets ($job does)"
    ! grep -q 'environment:' <<<"$body" || fail "only the sign job uses an environment ($job does)"
  fi
done
grep -q '^permissions: {}$' "$workflow" || fail "the workflow grants no permissions by default"
! job_of sign | grep -Eq '(^|[^a-z])(brew|npm|npx|pip3?|gem|cargo|curl|wget) ' ||
  fail "the sign job installs nothing"
[[ -z $(job_of sign | grep 'uses: ' | grep -Ev 'actions/(checkout|download-artifact|upload-artifact)@') ]] ||
  fail "the sign job uses only GitHub's checkout and artifact actions"
pass "only the sign job reads secrets, in macos-release, and it installs nothing"

[[ $(job_of sign | grep -B3 'name: signed-dmg' | head -1) == "      - if: needs.plan.outputs.dry-run == 'false'" ]] ||
  fail "a notarized dmg leaves the sign job only for a release"
publish_if=$(job_of publish | grep '^    if: ')
for condition in "needs.plan.outputs.dry-run == 'false'" "needs.plan.outputs.signing == 'developer-id'" \
  "startsWith(github.ref, 'refs/tags/v')"; do
  [[ $publish_if == *"$condition"* ]] || fail "publish runs only for a Developer ID release of a v* tag" "$publish_if"
done
job_of publish | grep -q 'RELEASE_COMMIT: ${{ github.sha }}' || fail "publish names the commit it built"
job_of plan | grep -q 'git merge-base --is-ancestor "$GITHUB_SHA" origin/main' || fail "a release must be a commit on main"
pass "a notarized dmg is kept and published only for a release of a commit on main"

while IFS= read -r line; do
  [[ $line =~ uses:\ [a-z0-9-]+/[a-z0-9-]+@[0-9a-f]{40}\ \#\ v[0-9] ]] || fail "every action is pinned to a commit" "$line"
done < <(grep 'uses: ' "$workflow")
pass "every action in the workflow is pinned to a commit"

! grep -n -- '^[^#]*codesign .*--deep' "$release/sign-app" "$release/sign-and-package" | grep -v -- '--verify' ||
  fail "the release scripts never sign with --deep"
pass "the release scripts use --deep only to verify"
