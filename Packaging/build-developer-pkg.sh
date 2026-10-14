#!/bin/bash
# Package an explicitly marked local developer app without production keys.
set -euo pipefail

fail() { echo "build-developer-pkg: $*" >&2; exit 1; }
[[ $# == 2 ]] || fail "usage: build-developer-pkg.sh APP OUTPUT.pkg"
directory="$(cd "$(dirname "$0")" && pwd -P)"
source "$directory/identity.conf"
app="$(cd "$1" && pwd -P)"
output="$2"
[[ $output == /* ]] || output="$PWD/$output"
[[ ! -e $output ]] || fail "output already exists"
[[ $(/usr/bin/plutil -extract OmarchyDeveloperBuild raw -o - "$app/Contents/Info.plist") == true ]] \
  || fail "app is not an explicit developer build"
[[ $(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$app/Contents/Info.plist") == "$INSTALLER_APP_IDENTIFIER" ]] \
  || fail "unexpected app identifier"
/usr/bin/codesign --verify --deep --strict "$app"
version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")"
work="$(mktemp -d "${TMPDIR:-/tmp}/omarchy-developer-pkg.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/root/Applications" "$work/root/Library/LaunchDaemons"
/usr/bin/ditto "$app" "$work/root/Applications/$INSTALLER_APP_NAME.app"
plist="$work/root/Library/LaunchDaemons/$INSTALLER_HELPER_IDENTIFIER.plist"
"$directory/pkg/derive-daemon-plist" "$app" "$plist" /Applications >/dev/null
requirement="$(/usr/bin/plutil -extract EnvironmentVariables.OMARCHY_CLIENT_CODE_SIGNING_REQUIREMENT raw -o - "$plist")"
[[ -n $requirement && $requirement != *REPLACED_DURING_PACKAGING* ]] \
  || fail "app has no completed client requirement"
/usr/bin/codesign --verify --strict -R="$requirement" "$app"
# Ad-hoc identifiers do not identify a particular build. Bind the root daemon
# to the copied, already-signed application's exact code hash.
client_hash=$(/usr/bin/codesign --display --verbose=4 "$app" 2>&1 | sed -n 's/^CDHash=//p')
[[ $client_hash =~ ^[0-9a-f]{40,64}$ ]] || fail "cannot read the developer app code hash"
requirement="$requirement and cdhash H\"$client_hash\""
/usr/bin/plutil -replace EnvironmentVariables.OMARCHY_CLIENT_CODE_SIGNING_REQUIREMENT \
  -string "$requirement" "$plist"
/usr/bin/codesign --verify --strict -R="$requirement" "$app"
chmod 0644 "$plist"
/usr/bin/ditto "$directory/pkg/scripts" "$work/scripts"
install -m 0644 "$directory/identity.conf" "$work/scripts/identity.conf"
/usr/bin/pkgbuild --analyze --root "$work/root" "$work/components.plist"
component_index=0
while /usr/bin/plutil -extract "$component_index.RootRelativeBundlePath" raw -o - "$work/components.plist" >/dev/null 2>&1; do
  /usr/bin/plutil -replace "$component_index.BundleIsRelocatable" -bool false "$work/components.plist"
  component_index=$((component_index + 1))
done
(( component_index > 0 )) || fail "package contains no application bundles"
mkdir -p "$(dirname "$output")"
/usr/bin/pkgbuild \
  --root "$work/root" --component-plist "$work/components.plist" \
  --scripts "$work/scripts" --identifier "$INSTALLER_PKG_IDENTIFIER.developer" \
  --version "$version" --install-location / --ownership recommended "$output"
printf 'Built unsigned local developer package: %s\n' "$output"
/usr/bin/shasum -a 256 "$output"
