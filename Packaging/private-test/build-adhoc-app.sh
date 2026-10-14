#!/bin/bash
# Build a private app whose helper trust is tied to this exact binary.
set -euo pipefail
(( $# == 2 )) || { echo 'usage: build-adhoc-app.sh RELEASE_INPUTS NEW_OUTPUT_DIRECTORY' >&2; exit 64; }
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
source "$root/Packaging/identity.conf"
source "$root/Packaging/private-test/code-identity.sh"
release=$(cd "$1" && pwd -P)
output=$2
[[ $output == /* && ! -e $output && ! -L $output ]] || exit 64
[[ ${OMARCHY_PRIVATE_PLAIN_TEST:-0} != "1" || ${OMARCHY_PRIVATE_LIMINE_TEST:-0} != "1" ]] || exit 64
mkdir "$output"
if [[ ${OMARCHY_PRIVATE_LIMINE_TEST:-0} == "1" ]]; then
  OMARCHY_PRIVATE_PLAIN_TEST=0 OMARCHY_APP_SIGNING_IDENTITY=- \
    bash "$root/Packaging/build-app.sh" "$release" "$output"
else
  OMARCHY_PRIVATE_PLAIN_TEST=1 OMARCHY_APP_SIGNING_IDENTITY=- \
    bash "$root/Packaging/build-app.sh" "$release" "$output"
fi
app="$output/$INSTALLER_APP_NAME.app"
helper="$app/Contents/Library/LaunchServices/$INSTALLER_HELPER_IDENTIFIER"
[[ $(/usr/bin/lipo -archs "$helper") == "arm64" ]] || exit 1
[[ $(/usr/bin/lipo -archs "$app/Contents/MacOS/OmarchyAppleInstallerApp") == "arm64" ]] || exit 1
helper_requirement=$(private_code_requirement "$helper" "$INSTALLER_HELPER_IDENTIFIER")
/usr/bin/codesign --verify --deep --strict "$app"
/usr/bin/codesign --verify --strict -R="$helper_requirement" "$helper"
private_code_requirement "$app" "$INSTALLER_APP_IDENTIFIER"
