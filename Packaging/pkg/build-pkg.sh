#!/bin/bash
# Build a signed + notarized macOS installer package for the Omarchy Apple
# Silicon installer. The package installs the notarized app to /Applications and
# a system LaunchDaemon to /Library/LaunchDaemons, then loads the daemon in its
# postinstall — so the recipient enters one admin password (the macOS installer
# prompt) and never touches Login Items.
#
# Usage: build-pkg.sh --app <signed .app> --version <x.y.z> --out <output.pkg> \
#          [--plist <daemon plist>]
#
# The system daemon plist is derived from the plist the app embeds
# (Contents/Library/LaunchDaemons), rewriting its bundle-relative BundleProgram
# into an absolute Program under /Applications. Pass --plist only to supply a
# daemon plist that already carries an absolute Program; it is validated the
# same way. Exact ad-hoc builds always derive the canonical plist and reject
# --plist overrides.
set -euo pipefail

PKG_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../identity.conf
source "$PKG_DIR/../identity.conf"
APP="" PLIST="" VERSION="" OUT=""
INSTALLER_ID="$INSTALLER_PKG_SIGNING_IDENTITY"
PKG_IDENTIFIER="$INSTALLER_PKG_IDENTIFIER"
SCRIPTS="$PKG_DIR/scripts"
DAEMON_PLIST_NAME="$INSTALLER_HELPER_IDENTIFIER.plist"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP="$2"; shift 2 ;;
    --plist) PLIST="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --installer-identity) INSTALLER_ID="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 64 ;;
  esac
done
[[ -d "$APP" && -n "$VERSION" && -n "$OUT" ]] || {
  echo "usage: build-pkg.sh --app <app> --version <v> --out <pkg> [--plist <plist>]" >&2
  exit 64
}
[[ -z "$PLIST" || -f "$PLIST" ]] || { echo "build-pkg.sh: --plist is not a file: $PLIST" >&2; exit 64; }

# An exact build must always derive its client requirement from the final seal.
# Preserve explicit plist overrides for the existing named-signing workflow.
if [[ -n "$PLIST" ]]; then
  python3 - "$APP/Contents/Info.plist" <<'PY'
import pathlib, plistlib, sys
path = pathlib.Path(sys.argv[1])
info = plistlib.loads(path.read_bytes()) if path.is_file() else {}
if info.get("OmarchyExactBuild") is True or info.get("OmarchyPrivateExactBuild") is True:
    sys.exit("build-pkg.sh: --plist is forbidden for exact builds; derive the canonical sealed identity")
PY
fi

work="$(mktemp -d /tmp/omarchy-pkg.XXXXXX)"
trap 'rm -rf "$work"' EXIT
root="$work/root"
mkdir -p "$root/Applications" "$root/Library/LaunchDaemons"

# Payload: the notarized app and the system daemon plist.
/usr/bin/ditto "$APP" "$root/Applications/$(basename "$APP")"

# Derive the daemon plist from the app's embedded copy (absolute Program under
# /Applications), or validate a supplied one the same way. A daemon whose
# Program is missing, relative, or points at nothing inside the staged app
# cannot be loaded by launchd, so that is a build failure, not a warning.
daemon_plist="$work/$DAEMON_PLIST_NAME"
if [[ -n "$PLIST" ]]; then
  /bin/cp "$PLIST" "$daemon_plist"
else
  "$PKG_DIR/derive-daemon-plist" "$APP" "$daemon_plist" /Applications >/dev/null
fi
prog="$(/usr/bin/plutil -extract Program raw -o - "$daemon_plist" 2>/dev/null || true)"
[[ $prog == /Applications/* ]] || {
  echo "build-pkg.sh: daemon Program must be an absolute path under /Applications (got '${prog:-<missing>}')" >&2
  exit 65
}
[[ -f "$root$prog" ]] || {
  echo "build-pkg.sh: daemon Program does not exist inside the staged app: $prog" >&2
  exit 65
}
# The helper compiles this requirement at launch and exits EX_CONFIG when it
# cannot, and launchd then respawns it forever while the app waits on a reply
# that never comes. The repo template carries a placeholder that build-app.sh
# replaces in the app's embedded copy; a pkg built from the template itself
# shipped exactly that failure once, so refuse anything but a real requirement.
requirement="$(/usr/bin/plutil -extract EnvironmentVariables.OMARCHY_CLIENT_CODE_SIGNING_REQUIREMENT raw -o - "$daemon_plist" 2>/dev/null || true)"
case "$requirement" in
  "" | *REPLACED_DURING_PACKAGING*)
    echo "build-pkg.sh: daemon plist has no client code-signing requirement (got '${requirement:-<missing>}'); use the app's embedded plist, not the repo template" >&2
    exit 65
    ;;
esac
/usr/bin/install -m 0644 "$daemon_plist" "$root/Library/LaunchDaemons/$DAEMON_PLIST_NAME"
echo "daemon client requirement: $requirement"
echo "daemon Program: $prog"

# Pin the app to /Applications. Without this, PackageKit "relocates" the
# install onto any existing copy of the bundle it can find anywhere on disk
# (it did exactly that onto a stale test copy in /Users/Shared), leaving
# /Applications empty and the daemon pointing at nothing.
component_plist="$work/component.plist"
/usr/bin/pkgbuild --analyze --root "$root" "$component_plist"
/usr/bin/plutil -replace 0.BundleIsRelocatable -bool false "$component_plist"

# postinstall reads the helper label and app name from the identity it ships with.
scripts="$work/scripts"
/usr/bin/ditto "$SCRIPTS" "$scripts"
/usr/bin/install -m 0644 "$PKG_DIR/../identity.conf" "$scripts/identity.conf"

echo "=== pkgbuild (component) ==="
comp="$work/component.pkg"
/usr/bin/pkgbuild \
  --root "$root" \
  --component-plist "$component_plist" \
  --scripts "$scripts" \
  --identifier "$PKG_IDENTIFIER" \
  --version "$VERSION" \
  --install-location / \
  --ownership recommended \
  "$comp"

echo "=== productbuild (signed distribution) ==="
# Installer asks for a running installer app, under either name, to be closed
# before it installs; otherwise the old app keeps running, postinstall has to
# leave it in place and the new app can't take the single-instance lease.
distribution="$work/distribution.xml"
/usr/bin/productbuild --synthesize --package "$comp" "$distribution"
"$PKG_DIR/add-must-close" "$distribution" "$PKG_IDENTIFIER" "$INSTALLER_APP_IDENTIFIER"
/usr/bin/productbuild \
  --distribution "$distribution" \
  --package-path "$work" \
  --identifier "$PKG_IDENTIFIER" \
  --version "$VERSION" \
  --sign "$INSTALLER_ID" \
  "$OUT"

echo "=== verify signature ==="
/usr/sbin/pkgutil --check-signature "$OUT" | head -6

echo "PKG_BUILT: $OUT"
echo "sha256: $(/usr/bin/shasum -a 256 "$OUT" | awk '{print $1}')"
