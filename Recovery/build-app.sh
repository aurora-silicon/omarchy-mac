#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
MODE="${1:?preview or recovery}"
OUT="${2:-build}"
[[ "$MODE" == "preview" || "$MODE" == "recovery" ]] || exit 2
export OMARCHY_RECOVERY_BUILD="$MODE"
APP="$OUT/Omarchy Installer.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/OmarchyVolumeIcon.png "$APP/Contents/Resources/OmarchyVolumeIcon.png"
mkdir -p "$APP/Contents/Resources/en.lproj"
cp Resources/en.lproj/InfoPlist.strings "$APP/Contents/Resources/en.lproj/InfoPlist.strings"
# Build the standalone Recovery target with XcodeBuildMCP before packaging.
"${XCODEBUILDMCP:-xcodebuildmcp}" swift-package build --package-path "$PWD" --configuration release
cp .build/release/OmarchyRecovery "$APP/Contents/MacOS/OmarchyRecovery"
[[ "$("$APP/Contents/MacOS/OmarchyRecovery" --build-mode)" == "$MODE" ]]
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>OmarchyRecovery</string>
<key>CFBundleIdentifier</key><string>org.aurorasilicon.omarchy.recovery.$MODE</string>
<key>OmarchyRecoveryBuildMode</key><string>$MODE</string>
<key>CFBundleName</key><string>Omarchy Installer</string>
<key>CFBundleDisplayName</key><string>Omarchy Installer</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
xcrun swiftc Sources/RecoveryOwner.swift Sources/InstallConfiguration.swift Tests/InstallConfigurationCheck.swift -o "$OUT/configuration-check"
"$OUT/configuration-check"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
xcrun clang -fobjc-arc -Wall -Wextra -Werror -framework Foundation Tests/BundleLookupCheck.m -o "$OUT/bundle-lookup-check"
"$OUT/bundle-lookup-check" "$(cd "$APP" && pwd)"
if [[ "$MODE" == "recovery" ]]; then
  PYTHONPATH=../Engine/overlay/src python3 - "$APP" "$OUT/omarchy-recovery-app.json" <<'PY'
import json
from pathlib import Path
import sys
from omarchy_recovery import app_inventory
Path(sys.argv[2]).write_text(json.dumps(app_inventory(Path(sys.argv[1])), sort_keys=True, indent=2) + "\n")
PY
fi
printf 'Built %s\n' "$APP"
