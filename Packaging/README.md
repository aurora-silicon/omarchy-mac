# Apple installer packaging

`build-app.sh` assembles a signed macOS application bundle without installing it,
registering its privileged helper, submitting it for notarization, or changing a
disk. The result is safe to inspect before any separately authorized deployment
step.

## Identity and hosting

`identity.conf` is the one place that sets the app name, bundle, helper and package identifiers, the Apple Developer team and its Developer ID identities, the catalog trust root and its Keychain service, and the catalog and download hosts. `build-app.sh` writes them into `Info.plist` and the helper's launch-daemon property list, the Swift build compiles them in through `OmarchyInstallerIdentityPlugin`, and the package, notarization and release scripts source the same file.

`INSTALLER_RECOVERY_APP_NAME` is a separate Recovery product contract. The main installer may change its branding while Recovery keeps the bundle name and paths consumed by the admitted validation engine. Changing the Recovery name requires updating and qualifying that engine contract; the identity fixture verifies the frozen overlay bytes against `Engine/source-lock.json` and checks their Recovery name before accounting for frozen literals. Live installer code and other identity/hosting values remain guarded.

Moving to another identity or host is an edit to `identity.conf` followed by `scripts/make-release-descriptor` for a matching `Release/release.json`. `test/all` fails when the descriptor drifts from the configuration or when a configured value is repeated in code, scripts or tests.

## Bundle layout

The generated `Omarchy Installer.app` contains:

- the SwiftUI application in `Contents/MacOS`;
- the root helper in `Contents/Library/LaunchServices`, named by its label, with its Info.plist (carrying the build number it reports) and, for builds with a real signing identity, its `SMJobBless` launchd job linked into `__TEXT` sections;
- the helper's declaration for `SMJobBless` (`SMPrivilegedExecutables`) in the app's Info.plist, for builds with a real signing identity;
- the launch-daemon property list the fallback installer package derives its system daemon from, in `Contents/Library/LaunchDaemons`, pointing at the same helper;
- the immutable release descriptor and Ed25519 trust root in
  `Contents/Resources/Release`; and
- the pinned Asahi validation engine in `Contents/Resources/Engine/artifacts`.

The helper and application use reciprocal code-signing requirements. The helper
also authenticates each XPC client before accepting a request. A release
descriptor whose helper identity does not match the compiled product is rejected.

## Build

Provide a directory containing the production-owned `release.json` and the exact
32-byte `trust-root.ed25519.pub` named by that descriptor:

```sh
Packaging/build-app.sh /absolute/path/to/release-inputs /absolute/path/to/output
```

For a private or offline build, the same directory may also contain the signed
pair `catalog.json` and `catalog.json.sig`. The packager accepts the pair only
when both are regular, non-symlinked files within the catalog size limits and
the signature is exactly 64 bytes. The app verifies this sealed catalog with
the same bundled Ed25519 trust root; when the pair is absent, it fetches the
configured HTTPS catalog as normal.

For a single-download offline preview, place every enabled model's engine,
metadata and complete OS payload in `offline-artifacts/` beside that sealed
catalog, using the catalog's exact filenames, sizes and SHA-256 digests. Then
build with `OMARCHY_OFFLINE_BUILD=1` (and `OMARCHY_DEVELOPER_BUILD=1` for the
developer preview). The packager verifies and embeds those files in the app.
The normal package builder includes them in the resulting single `.pkg`.
At runtime the app verifies the embedded files before staging them; a missing
or damaged embedded file fails locally instead of falling back to a download.
Firmware that the engine needs from Apple can still be downloaded separately.

Build concurrency defaults to 10 workers so a 14-core Mac retains four cores for
responsiveness. Override it with `OMARCHY_BUILD_JOBS`; the same value is exported
as `CARGO_BUILD_JOBS` for nested Rust builds.

The default signing identity is `-`, which creates an ad-hoc development bundle
for local structural validation only. A named identity also requires its
10-character team identifier:

```sh
OMARCHY_APP_SIGNING_IDENTITY="Apple Development: Name (TEAMID)" \
OMARCHY_TEAM_ID="TEAMID" \
Packaging/build-app.sh /absolute/path/to/release-inputs /absolute/path/to/output
```

Production distribution must use a `Developer ID Application` identity, a
hardened-runtime signature and secure timestamp, followed by notarization and
stapling. After an explicitly authorized production build, notarize it with a
preconfigured keychain profile:

```sh
OMARCHY_NOTARY_PROFILE="omarchy-notary" \
Packaging/notarize-app.sh "/absolute/path/Omarchy Installer.app"
```

The app installs its own helper with `SMJobBless` the first time the person authorizes an install, using the password they typed; ad hoc builds leave the declaration out and still need the installer package. After notarization, package the download:

```sh
Packaging/make-download-zip.sh "/absolute/path/Omarchy Installer.app" /absolute/path/Omarchy-Installer.zip
```

It refuses an app without a stapled ticket and checks that the zip holds only the app.

After a completed removal the helper uninstalls itself. A build that can install its own helper sets it up again at the next authorization. A build that cannot (ad hoc builds, and anything relying on the installer package) needs the installer package run again before its next install or removal.

Notarization is deliberately separate from the assembler. The script rejects
ad-hoc and development-signed bundles, submits a temporary ZIP, staples the
accepted ticket to the app, and validates it with Gatekeeper. It requires the
owner's explicit authorization because it uses production credentials and
changes the application bundle.

The script refuses unsafe or mismatched release inputs and will not overwrite an
existing application bundle.

For a local hardware test, first assemble an explicitly marked `OMARCHY_DEVELOPER_BUILD=1` app with its sealed developer catalog, then run `Packaging/build-developer-pkg.sh APP OUTPUT.pkg`. This verifies the app and embedded client requirement and creates an unsigned local package that installs the app and its helper through PackageKit. It requires the developer marker and does not use the production signing identities. This package is for local testing, not public distribution.
