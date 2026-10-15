#!/bin/bash
# Build the Neo installer DMG from a release directory sealed by
# seal-catalog.py: the Recovery app, the ad hoc developer app carrying that
# catalog, and its disk image, all under OUTPUT_DIR. Runs on a Mac with Xcode.
set -euo pipefail

fail() {
  echo "build-release: $*" >&2
  exit 1
}

if (( $# != 3 )); then
  echo "usage: build-release.sh RELEASE_DIR OUTPUT_DIR BUILD_NUMBER" >&2
  exit 64
fi

repository="$(cd "$(dirname "$0")/../.." && pwd -P)"
# shellcheck source=../identity.conf
source "$repository/Packaging/identity.conf"
release="$(cd "$1" && pwd -P)"
mkdir -p "$2"
output="$(cd "$2" && pwd -P)"
build_number="$3"
[[ $build_number =~ ^[0-9]+$ ]] || fail "the build number must be a positive integer"
[[ -f $release/catalog.json && -f $release/catalog.json.sig && -f $release/trust-root.ed25519.pub ]] \
  || fail "$release needs the trust root and a catalog sealed by seal-catalog.py"

app_dir="$output/app-$build_number"
image="$output/Omarchy-Installer-Neo-macOS27-$build_number.dmg"
[[ ! -e $app_dir && ! -e $image ]] || fail "build $build_number already exists in $output"

# The descriptor follows this checkout's app and helper identity. The sealed
# catalog leaves its channel URLs unused, so they point nowhere.
rm -f "$release/release.json"
"$repository/scripts/make-release-descriptor" --adhoc \
  --public-key "$release/trust-root.ed25519.pub" --output "$release/release.json" \
  --base-url https://aurora-installer.invalid/neo

# The app installs this Recovery app as the helper's template.
recovery="$output/recovery-$build_number"
"$repository/Recovery/build-app.sh" recovery "$recovery"
recovery_apps=("$recovery"/*.app)
(( ${#recovery_apps[@]} == 1 )) && [[ -d ${recovery_apps[0]} ]] || fail "the Recovery build made no single app"

OMARCHY_DEVELOPER_BUILD=1 OMARCHY_APP_BUILD_NUMBER="$build_number" \
  OMARCHY_RECOVERY_TEMPLATE="${recovery_apps[0]}" \
  "$repository/Packaging/build-app.sh" "$release" "$app_dir"

app="$app_dir/$INSTALLER_APP_NAME.app"
cmp "$app/Contents/Resources/Release/catalog.json" "$release/catalog.json" \
  || fail "the app does not carry the sealed catalog"

# Staged as Packaging/release/sign-and-package stages the notarized app.
stage="$(mktemp -d "${TMPDIR:-/tmp}/omarchy-neo-dmg.XXXXXX")"
trap 'rm -rf -- "$stage"' EXIT
/usr/bin/ditto "$app" "$stage/${app##*/}"
ln -s /Applications "$stage/Applications"
hdiutil create -volname "$INSTALLER_APP_NAME" -srcfolder "$stage" -fs HFS+ \
  -format UDZO -imagekey zlib-level=9 "$image" >/dev/null
hdiutil verify "$image" >/dev/null
shasum -a 256 "$image"
