#!/bin/bash

set -euo pipefail

fail() {
  echo "build-app: $*" >&2
  exit 1
}

usage() {
  echo "usage: build-app.sh RELEASE_DIRECTORY OUTPUT_DIRECTORY" >&2
  exit 64
}

(( $# == 2 )) || usage

script_directory="$({ cd "$(dirname "$0")" && pwd -P; })"
package_directory="$({ cd "$script_directory/.." && pwd -P; })"
release_directory="$({ cd "$1" && pwd -P; })"
output_directory="$2"
# shellcheck source=identity.conf
source "$script_directory/identity.conf"

[[ -d $release_directory && ! -L $release_directory ]] \
  || fail "release directory must be a real directory"
[[ $output_directory == /* ]] \
  || output_directory="$package_directory/$output_directory"

build_jobs="${OMARCHY_BUILD_JOBS:-10}"
[[ $build_jobs =~ ^[1-9][0-9]*$ ]] \
  || fail "OMARCHY_BUILD_JOBS must be a positive integer"
export CARGO_BUILD_JOBS="$build_jobs"

marketing_version="${OMARCHY_APP_VERSION:-2.1.0}"
# SMJobBless never replaces a helper with a lower build, so a developer build
# defaults to its UTC build minute (YYMMDDHHMM): each one installs over the
# helper an earlier one left, without anyone tracking numbers by hand.
if [[ ${OMARCHY_DEVELOPER_BUILD:-0} == "1" ]]; then
  build_number="${OMARCHY_APP_BUILD_NUMBER:-$(date -u +%y%m%d%H%M)}"
else
  build_number="${OMARCHY_APP_BUILD_NUMBER:-27}"
fi
signing_identity="${OMARCHY_APP_SIGNING_IDENTITY:--}"
team_identifier="${OMARCHY_TEAM_ID:-}"

[[ $marketing_version =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9]+)*$ ]] \
  || fail "OMARCHY_APP_VERSION has an invalid format"
[[ $build_number =~ ^[1-9][0-9]*$ ]] \
  || fail "OMARCHY_APP_BUILD_NUMBER must be a positive integer"

app_identifier="$INSTALLER_APP_IDENTIFIER"
helper_identifier="$INSTALLER_HELPER_IDENTIFIER"
app_name="$INSTALLER_APP_NAME.app"
app_executable_name="OmarchyAppleInstallerApp"
daemon_plist_name="$helper_identifier.plist"
read -r engine_file_name engine_digest engine_size < <(
  python3 - "$package_directory/Sources/OmarchyAppleInstaller/ValidationEngineArtifact.swift" <<'PY'
import re
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text()
name = re.search(r'public static let fileName = "(installer-[A-Za-z0-9.-]+\.tar\.gz)"', source)
digest = re.search(r'public static let expectedDigest\s*=\s*"sha256:([0-9a-f]{64})"', source)
size = re.search(r'public static let expectedSizeBytes: UInt64 = ([0-9_]+)', source)
if not all((name, digest, size)):
    raise SystemExit("Cannot read the runtime validation-engine identity")
print(name[1], digest[1], int(size[1].replace("_", "")))
PY
)

if [[ $signing_identity == "-" ]]; then
  client_requirement="identifier \"$app_identifier\""
  helper_requirement="identifier \"$helper_identifier\""
  timestamp_arguments=(--timestamp=none)
else
  [[ $team_identifier =~ ^[A-Z0-9]{10}$ ]] \
    || fail "OMARCHY_TEAM_ID is required for named signing identities"
  client_requirement="anchor apple generic and identifier \"$app_identifier\" and certificate leaf[subject.OU] = \"$team_identifier\""
  helper_requirement="anchor apple generic and identifier \"$helper_identifier\" and certificate leaf[subject.OU] = \"$team_identifier\""
  if [[ $signing_identity == "Developer ID Application:"* ]]; then
    timestamp_arguments=(--timestamp)
  elif [[ $signing_identity =~ ^[0-9A-Fa-f]{40}$ ]] \
    && security find-identity -p codesigning -v \
      | grep -i "$signing_identity" | grep -q "Developer ID Application"; then
    # Signing by SHA-1 fingerprint (duplicate same-name certificates make
    # names ambiguous): resolve the certificate kind from the keychain so
    # Developer ID builds keep the secure timestamp notarization requires.
    timestamp_arguments=(--timestamp)
  else
    timestamp_arguments=(--timestamp=none)
  fi
fi

release_descriptor="$release_directory/release.json"
trust_root="$release_directory/trust-root.ed25519.pub"
sealed_catalog="$release_directory/catalog.json"
sealed_catalog_signature="$release_directory/catalog.json.sig"
[[ -f $release_descriptor && ! -L $release_descriptor ]] \
  || fail "release.json is missing or unsafe"
[[ -f $trust_root && ! -L $trust_root ]] \
  || fail "trust-root.ed25519.pub is missing or unsafe"
(( $(stat -f %z "$release_descriptor") <= 65536 )) \
  || fail "release.json exceeds 65536 bytes"
(( $(stat -f %z "$trust_root") == 32 )) \
  || fail "trust-root.ed25519.pub must contain exactly 32 bytes"

[[ ${OMARCHY_PRIVATE_PLAIN_TEST:-0} != "1" || ${OMARCHY_PRIVATE_LIMINE_TEST:-0} != "1" ]] \
  || fail "private plain and Limine profiles are mutually exclusive"
[[ ${OMARCHY_DEVELOPER_BUILD:-0} != "1" \
  || ( ${OMARCHY_PRIVATE_PLAIN_TEST:-0} != "1" && ${OMARCHY_PRIVATE_LIMINE_TEST:-0} != "1" ) ]] \
  || fail "the developer build cannot also be a private profile"
sealed_catalog_available=false
if [[ -e $sealed_catalog || -L $sealed_catalog \
  || -e $sealed_catalog_signature || -L $sealed_catalog_signature ]]; then
  if [[ ! -f $sealed_catalog || -L $sealed_catalog ]]; then
    fail "catalog.json is missing or unsafe"
  fi
  if [[ ! -f $sealed_catalog_signature || -L $sealed_catalog_signature ]]; then
    fail "catalog.json.sig is missing or unsafe"
  fi
  catalog_size="$(stat -f %z "$sealed_catalog")"
  if (( catalog_size <= 0 || catalog_size > 1048576 )); then
    fail "catalog.json is empty or exceeds 1048576 bytes"
  fi
  if (( $(stat -f %z "$sealed_catalog_signature") != 64 )); then
    fail "catalog.json.sig must contain exactly 64 bytes"
  fi
  sealed_catalog_available=true
fi

if [[ ${OMARCHY_PRIVATE_LIMINE_TEST:-0} == "1" && $sealed_catalog_available != "true" ]]; then
  fail "private Limine builds require a sealed private catalog"
fi
# A developer catalog can admit Macs no public catalog does, so it must never
# reach a developer build over the network.
if [[ ${OMARCHY_DEVELOPER_BUILD:-0} == "1" && $sealed_catalog_available != "true" ]]; then
  fail "developer builds require a sealed developer catalog"
fi
if [[ ${OMARCHY_OFFLINE_BUILD:-0} == "1" && $sealed_catalog_available != "true" ]]; then
  fail "offline builds require a sealed catalog"
fi

if [[ ${OMARCHY_PRIVATE_LIMINE_TEST:-0} == "1" ]]; then
  python3 "$script_directory/private-test/prepare-limine-assets.py" --verify-release "$release_directory" >/dev/null
fi

descriptor_schema="$(plutil -extract schema_version raw -o - "$release_descriptor")"
descriptor_service="$(plutil -extract helper_mach_service_name raw -o - "$release_descriptor")"
descriptor_requirement="$(plutil -extract helper_code_signing_requirement raw -o - "$release_descriptor")"
descriptor_fingerprint="$(plutil -extract trust_root_fingerprint raw -o - "$release_descriptor")"
if [[ $descriptor_schema != "3" ]]; then
  fail "release.json schema_version must be 3"
fi
release_channels=(stable rc edge)
descriptor_default_channel="$(plutil -extract default_channel raw -o - "$release_descriptor")"
if [[ " ${release_channels[*]} " != *" $descriptor_default_channel "* ]]; then
  fail "release.json default_channel must be one of: ${release_channels[*]}"
fi
descriptor_channel_keys="$(plutil -extract channels raw -o - "$release_descriptor" | sort | tr '\n' ' ')"
if [[ $descriptor_channel_keys != "$(printf '%s\n' "${release_channels[@]}" | sort | tr '\n' ' ')" ]]; then
  fail "release.json must name exactly the channels: ${release_channels[*]}"
fi
descriptor_urls=" "
for release_channel in "${release_channels[@]}"; do
  descriptor_url="$(plutil -extract "channels.$release_channel.catalog_url" raw -o - "$release_descriptor")"
  if [[ $descriptor_url != https://?*/?* ]]; then
    fail "release.json channel URLs must be https with a host and a path"
  fi
  # Two channels pointing at one object would silently erase the separation
  # between what testers see and what everyone else installs.
  if [[ $descriptor_urls == *" $descriptor_url "* ]]; then
    fail "release.json channels must not share a URL"
  fi
  descriptor_urls+="$descriptor_url "
done
if [[ $descriptor_service != "$helper_identifier" ]]; then
  fail "release.json helper service does not match the compiled product"
fi
if [[ $descriptor_requirement != "$helper_requirement" ]]; then
  fail "release.json helper signing requirement does not match this build"
fi
actual_fingerprint="sha256:$(/usr/bin/shasum -a 256 "$trust_root" | awk '{print $1}')"
if [[ $descriptor_fingerprint != "$actual_fingerprint" ]]; then
  fail "release.json trust root fingerprint does not match the public key"
fi

engine_source="$package_directory/Engine/artifacts/$engine_file_name"
if [[ ! -f $engine_source || -L $engine_source ]]; then
  fail "the pinned validation engine artifact is missing"
fi
actual_engine_digest="$(/usr/bin/shasum -a 256 "$engine_source" | awk '{print $1}')"
if [[ $actual_engine_digest != "$engine_digest" ]]; then
  fail "the pinned validation engine digest is incorrect"
fi
[[ $(stat -f %z "$engine_source") == "$engine_size" ]] \
  || fail "the pinned validation engine size is incorrect"

mkdir -p "$output_directory"
final_app="$output_directory/$app_name"
[[ ! -e $final_app ]] \
  || fail "refusing to overwrite existing app: $final_app"

recovery_template="${OMARCHY_RECOVERY_TEMPLATE:-}"
if [[ -z $recovery_template ]]; then
  "$package_directory/Recovery/build-recovery.sh" "$output_directory/recovery-template"
  recovery_template="$output_directory/recovery-template/Omarchy Installer.app"
fi
[[ -d $recovery_template && ! -L $recovery_template ]] || fail "native Recovery template is missing"
[[ $(/usr/bin/plutil -extract OmarchyRecoveryBuildMode raw -o - "$recovery_template/Contents/Info.plist") == recovery ]] \
  || fail "Recovery template is not a real Recovery build"
[[ ! -e "$recovery_template/Contents/Resources/install-config.json" \
  && ! -e "$recovery_template/Contents/Resources/AuraPayloads" ]] \
  || fail "Recovery template contains another installation's data"
codesign --verify --deep --strict "$recovery_template"

swift_tool="$(xcrun --find swift)"
(
  cd "$package_directory"
  "$swift_tool" build \
    --configuration release \
    --jobs "$build_jobs"
)
binary_directory="$({
  cd "$package_directory"
  "$swift_tool" build --configuration release --show-bin-path
})"

assembly_root="$(mktemp -d "$output_directory/.omarchy-app.XXXXXX")"
trap 'rm -rf "$assembly_root"' EXIT

# The helper carries its Info.plist and, for SMJobBless, its launchd job in
# __TEXT sections, so it is linked again with them. Ad hoc builds get only the
# Info.plist: they cannot install their helper and rely on the package.
helper_plists="$assembly_root/helper-plists"
mkdir "$helper_plists"
if [[ $signing_identity == "-" ]]; then
  "$script_directory/helper-plists" "$helper_plists" "$build_number" "$marketing_version" >/dev/null
else
  "$script_directory/helper-plists" "$helper_plists" "$build_number" "$marketing_version" \
    "$client_requirement" >/dev/null
fi
helper_link_arguments=(
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist
  -Xlinker "$helper_plists/helper-info.plist"
)
if [[ -f $helper_plists/helper-launchd.plist ]]; then
  helper_link_arguments+=(
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __launchd_plist
    -Xlinker "$helper_plists/helper-launchd.plist"
  )
fi
(
  cd "$package_directory"
  "$swift_tool" build \
    --configuration release \
    --jobs "$build_jobs" \
    --product OmarchyAppleInstallerHelper \
    "${helper_link_arguments[@]}"
)

app_binary="$binary_directory/$app_executable_name"
helper_binary="$binary_directory/OmarchyAppleInstallerHelper"
[[ -x $app_binary ]] || fail "app executable was not built"
[[ -x $helper_binary ]] || fail "helper executable was not built"
assembled_app="$assembly_root/$app_name"
contents="$assembled_app/Contents"
resources="$contents/Resources"
# SMJobBless finds the helper here, named by its label; the package's daemon
# plist points at the same binary.
helper_relative_path="Contents/Library/LaunchServices/$helper_identifier"
helper_path="$assembled_app/$helper_relative_path"

mkdir -p \
  "$contents/MacOS" \
  "$resources/Release" \
  "$resources/Engine/artifacts" \
  "$contents/Library/LaunchDaemons" \
  "$contents/Library/LaunchServices"

install -m 0755 "$app_binary" "$contents/MacOS/$app_executable_name"
install -m 0755 "$helper_binary" "$helper_path"
install -m 0444 "$release_descriptor" "$resources/Release/release.json"
install -m 0444 "$trust_root" "$resources/Release/trust-root.ed25519.pub"
install -m 0444 "$package_directory/Design/Assets/MacBookPowerButton.png" "$resources/MacBookPowerButton.png"
install -m 0444 "$package_directory/Design/Assets/MacDesktopPowerButton.png" "$resources/MacDesktopPowerButton.png"
mkdir -p "$resources/RecoveryTemplate"
/usr/bin/ditto "$recovery_template" "$resources/RecoveryTemplate/Omarchy Installer.app"
codesign --force --sign "$signing_identity" "${timestamp_arguments[@]}" \
  "$resources/RecoveryTemplate/Omarchy Installer.app"
if [[ ${OMARCHY_PRIVATE_LIMINE_TEST:-0} == "1" ]]; then
  install -m 0444 "$release_directory/limine-inputs.json" "$resources/Release/limine-inputs.json"
fi
if [[ $sealed_catalog_available == "true" ]]; then
  install -m 0444 "$sealed_catalog" "$resources/Release/catalog.json"
  install -m 0444 \
    "$sealed_catalog_signature" \
    "$resources/Release/catalog.json.sig"
fi
install -m 0444 "$engine_source" "$resources/Engine/artifacts/$engine_file_name"
# Optional execution engines belong to the signed app, not the download cache.
# Admit only files whose name, size and hash match its sealed catalog.
if [[ $sealed_catalog_available == "true" && -d "$release_directory/engine-artifacts" ]]; then
  python3 - "$sealed_catalog" "$release_directory/engine-artifacts" "$resources/Engine/artifacts" <<'PYCODE'
import hashlib
import json
from pathlib import Path
import shutil
import sys
catalog, sources, destination = map(Path, sys.argv[1:])
for model in json.loads(catalog.read_text())["models"]:
    artifact = model["engineArtifact"]
    name = artifact["fileName"]
    if Path(name).name != name or not name.endswith(".tar.gz"):
        raise SystemExit("unsafe bundled engine name")
    source = sources / name
    if source.is_symlink():
        raise SystemExit("bundled engine cannot be a symlink")
    if not source.exists():
        continue
    expected = model["engineDigest"].removeprefix("sha256:")
    if source.stat().st_size != artifact["sizeBytes"] or hashlib.sha256(source.read_bytes()).hexdigest() != expected:
        raise SystemExit("bundled engine differs from signed catalog")
    target = destination / name
    if target.exists():
        if hashlib.sha256(target.read_bytes()).hexdigest() != expected:
            raise SystemExit("bundled engine conflicts with inspection engine")
        # The inspection engine is already this exact execution engine.
        continue
    shutil.copyfile(source, target)
    target.chmod(0o444)
PYCODE
fi
install -m 0444 \
  "$script_directory/OmarchyInstaller.icns" \
  "$resources/OmarchyInstaller.icns"
install -m 0444 "$script_directory/Info.plist" "$contents/Info.plist"
install -m 0444 \
  "$script_directory/helper-daemon.plist" \
  "$contents/Library/LaunchDaemons/$daemon_plist_name"

chmod 0644 "$contents/Info.plist"
chmod 0644 "$contents/Library/LaunchDaemons/$daemon_plist_name"
plutil -replace CFBundleShortVersionString \
  -string "$marketing_version" "$contents/Info.plist"
if [[ ${OMARCHY_PRIVATE_PLAIN_TEST:-0} == "1" ]]; then
  plutil -insert OmarchyPrivatePlainTest -bool true "$contents/Info.plist"
fi
if [[ ${OMARCHY_PRIVATE_LIMINE_TEST:-0} == "1" ]]; then
  plutil -insert OmarchyPrivateLimineTest -bool true "$contents/Info.plist"
fi
if [[ ${OMARCHY_DEVELOPER_BUILD:-0} == "1" ]]; then
  plutil -insert OmarchyDeveloperBuild -bool true "$contents/Info.plist"
fi
if [[ ${OMARCHY_OFFLINE_BUILD:-0} == "1" ]]; then
  python3 "$script_directory/bundle-offline-artifacts.py" \
    "$sealed_catalog" "$release_directory/offline-artifacts" "$resources/Artifacts"
  plutil -insert OmarchyOfflineBundle -bool true "$contents/Info.plist"
fi
plutil -replace CFBundleVersion \
  -string "$build_number" "$contents/Info.plist"
plutil -replace CFBundleIdentifier \
  -string "$app_identifier" "$contents/Info.plist"
plutil -replace CFBundleName \
  -string "$INSTALLER_APP_NAME" "$contents/Info.plist"
plutil -replace CFBundleDisplayName \
  -string "$INSTALLER_APP_NAME" "$contents/Info.plist"
plutil -replace Label \
  -string "$helper_identifier" \
  "$contents/Library/LaunchDaemons/$daemon_plist_name"
plutil -replace MachServices \
  -json "{\"$helper_identifier\":true}" \
  "$contents/Library/LaunchDaemons/$daemon_plist_name"
plutil -replace BundleProgram \
  -string "$helper_relative_path" \
  "$contents/Library/LaunchDaemons/$daemon_plist_name"
if [[ $signing_identity != "-" ]]; then
  plutil -replace SMPrivilegedExecutables \
    -json "{\"$helper_identifier\":$(printf '%s' "$helper_requirement" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')}" \
    "$contents/Info.plist"
fi
plutil -replace \
  EnvironmentVariables.OMARCHY_CLIENT_CODE_SIGNING_REQUIREMENT \
  -string "$client_requirement" \
  "$contents/Library/LaunchDaemons/$daemon_plist_name"
plutil -lint \
  "$contents/Info.plist" \
  "$contents/Library/LaunchDaemons/$daemon_plist_name" >/dev/null
if grep -q REPLACED_DURING_PACKAGING \
  "$contents/Info.plist" \
  "$contents/Library/LaunchDaemons/$daemon_plist_name"; then
  fail "a packaging placeholder was left in the app"
fi

codesign --force --sign "$signing_identity" \
  "${timestamp_arguments[@]}" \
  --options runtime \
  --identifier "$helper_identifier" \
  "$helper_path"
codesign --force --sign "$signing_identity" \
  "${timestamp_arguments[@]}" \
  --options runtime \
  "$assembled_app"

codesign --verify --deep --strict --verbose=2 "$assembled_app"
codesign --verify --strict \
  -R="$helper_requirement" \
  "$helper_path"
embedded_version="$(launchctl plist __TEXT,__info_plist "$helper_path" 2>/dev/null \
  | awk -F'"' '/"CFBundleVersion"/ {print $4}')"
[[ $embedded_version == "$build_number" ]] \
  || fail "the helper does not carry its build number (got '${embedded_version:-none}')"
codesign --verify --strict \
  -R="$client_requirement" \
  "$assembled_app"

mv "$assembled_app" "$final_app"
echo "$final_app"
