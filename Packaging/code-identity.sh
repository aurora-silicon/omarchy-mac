#!/bin/bash
# Native macOS code-directory identity helpers. Shared by normal and private packagers.
code_hash() {
  local details digest
  details=$(codesign --display --verbose=4 "$1" 2>&1) || return 1
  digest=$(printf '%s\n' "$details" | /usr/bin/sed -n 's/^CDHash=//p')
  [[ $digest =~ ^[0-9a-f]{40}$ ]] || return 1
  printf '%s\n' "$digest"
}

code_requirement() {
  local digest
  digest=$(code_hash "$1") || return 1
  printf 'identifier "%s" and cdhash H"%s"\n' "$2" "$digest"
}

# Finalize resource identities after the helper is signed, before signing the app.
# The app hash cannot be embedded in its own resources without changing that hash.
# Its exact client requirement is derived externally from the final sealed app.
seal_adhoc_identity() {
  local app=$1 helper_identifier=$2 helper requirement descriptor daemon
  helper="$app/Contents/Library/LaunchServices/$helper_identifier"
  descriptor="$app/Contents/Resources/Release/release.json"
  daemon="$app/Contents/Library/LaunchDaemons/$helper_identifier.plist"
  requirement=$(code_requirement "$helper" "$helper_identifier") || return 1
  chmod u+w "$descriptor"
  plutil -replace helper_code_signing_requirement -string "$requirement" "$descriptor"
  chmod 444 "$descriptor"
  plutil -insert OmarchyExactBuild -bool true "$app/Contents/Info.plist"
  # No usable identifier-only registration path may remain in the sealed app.
  plutil -replace EnvironmentVariables.OMARCHY_CLIENT_CODE_SIGNING_REQUIREMENT \
    -string 'never' "$daemon"
}
