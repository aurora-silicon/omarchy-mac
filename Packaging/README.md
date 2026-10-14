# Apple installer packaging

`build-app.sh` assembles a signed macOS application bundle without installing it,
registering its privileged helper, submitting it for notarization, or changing a
disk. The result is safe to inspect before any separately authorized deployment
step.

## Identity and hosting

`identity.conf` is the one place that sets the app name, bundle, helper and package identifiers, the Apple Developer team and its Developer ID identities, the Keychain service of the catalog signing key, the catalog base the app reads (`https://mac.omarchy.org/v1`), and the hosts the publishing tools write to. `build-app.sh` writes them into `Info.plist` and the helper's launch-daemon property list, the Swift build compiles them in through `OmarchyInstallerIdentityPlugin`, and the package, notarization and release scripts source the same file.

Moving to another identity or host is an edit to `identity.conf` followed by `scripts/make-release-descriptor` for a matching `Release/release.json`. The catalog trust root is the one value kept outside `identity.conf`: it is `Release/trust-root.ed25519.pub`, and swapping it is the same replace-then-regenerate step (see `Release/README.md`). `test/all` fails when the descriptor drifts from the configuration or when a configured value is repeated in code, scripts or tests.

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

After a completed removal, a helper the app installed itself with `SMJobBless` uninstalls itself: its job file, its binary in `/Library/PrivilegedHelperTools` and its state directory go, and the app sets it up again at the next authorization. A helper an installer package put in place (the package from `pkg/build-pkg.sh`, which runs it from inside the app in `/Applications`, or the private ad hoc package, whose build cannot bless its helper) stays registered after a removal, because nothing but the package could register it again; Remove followed by Install then works without running the package again. The helper tells the two apart by where it runs from and whether its build declares `SMAuthorizedClients`.

A helper that stays keeps its removal records. Before any install or removal it checks them: an unfinished removal blocks both until the record and disk layout are checked, and a completed removal whose install journals were not yet set aside (the helper stopped in between, or moving them failed) gets them set aside first, or the request is refused. If the app loses a removal's reply, it asks the kept helper whether the removal finished; the macOS container size alone only shows that macOS has its space back.

Notarization is deliberately separate from the assembler. The script rejects
ad-hoc and development-signed bundles, submits a temporary ZIP, staples the
accepted ticket to the app, and validates it with Gatekeeper. It requires the
owner's explicit authorization because it uses production credentials and
changes the application bundle.

The script refuses unsafe or mismatched release inputs and will not overwrite an
existing application bundle.

For a local hardware test, first assemble an explicitly marked `OMARCHY_DEVELOPER_BUILD=1` app with its sealed developer catalog, then run `Packaging/build-developer-pkg.sh APP OUTPUT.pkg`. This verifies the app and embedded client requirement and creates an unsigned local package that installs the app and its helper through PackageKit. It requires the developer marker and does not use the production signing identities. This package is for local testing, not public distribution.

## Release workflow

`.github/workflows/mac-app-release.yml` builds the public download. Pushing a `v<version>` tag builds the app for the Developer ID team in `identity.conf`, signs it in the `macos-release` environment, notarizes and staples it into `Omarchy-Mac-Installer-<version>.dmg` (the app beside an `/Applications` link) and leaves the `.dmg` and its `.sha256` on a draft prerelease `v<version>`, never marked latest; the owner publishes it. A manual dispatch defaults to an ad hoc dry run that needs no secrets and publishes nothing. `Packaging/release/plan` decides what a run may do and refuses the rest: only a `v*` tag publishes, only a `v*` tag or `main` may use the Developer ID (a signed dry run from `main` tests the secrets), and pull requests never trigger the workflow.

The jobs split the key from the build. `build` runs `build-app.sh` with `OMARCHY_APP_SIGNING_IDENTITY=none` (Developer ID requirements and `SMJobBless` declarations, no signature) and holds no secrets. `sign` alone reads the secrets, after a second maintainer approves; it installs nothing and runs only this commit's `Packaging/release` scripts and Apple's tools on the build job's app, checked by digest:

- `release-guard` refuses an app or `.dmg` with a `get-task-allow` entitlement, the lab catalog key (`release/lab-catalog-key.ed25519.pub`), the test candidate key, SSH keys, passwordless sudo, lab files or host names (inside the bundled engine too), a private profile, a sealed catalog, catalogs outside the catalog base, or code-signing requirements not anchored to the Developer ID team. It runs on the unsigned app and on the finished `.dmg`.
- `sign-app` signs inside-out (the helper under its own identifier, then the app) with the hardened runtime and a secure timestamp, never `--deep` and with no entitlements, then verifies both designated requirements and the signature's team and timestamp.
- `sign-and-package` runs the guard, `sign-app`, notarizes and staples the app, builds and signs the `.dmg`, notarizes and staples it, checks both with `spctl`, checks the app inside the finished `.dmg` (signature, requirements, staple, Gatekeeper), guards the `.dmg` and writes the sha256. It fails on any notarization status but Accepted and keeps the notary logs. With `--identity -` it is the dry run: ad hoc, no notarization or Gatekeeper checks.
- `publish-app` is the only publishing step: target `github-release` today, `r2` (`installer/<version>/` under the catalog base) with the hosting switch. It publishes only when the tag still names the built commit, never replaces a file, and finishes an interrupted upload when the files already there are identical.

A release must be a commit on `main` (which takes only reviewed pull requests that passed the installer checks). A notarized `.dmg` leaves the sign job only for a release, as a one-day artifact for `publish`; a signed dry run keeps only the notary logs and checksum. `publish` attests the `.dmg` (`actions/attest-build-provenance`) and runs `publish-app`. The engine the app embeds comes from the draft release named by `ENGINE_RELEASE`, checked against the digest `build-app.sh` pins.

The `macos-release` environment accepts `v*` tags and `main`, requires one approval from its reviewers (maralcbr, ryanrhughes), blocks self-review and has no admin bypass. Its secrets:

| Secret | What it holds | How to produce it |
|---|---|---|
| `DEVELOPER_ID_P12_BASE64` | the Developer ID Application certificate and private key, base64 | Keychain Access › My Certificates › the "Developer ID Application" identity › Export as `.p12` with a strong password, then `base64 -i DeveloperID.p12 \| gh secret set DEVELOPER_ID_P12_BASE64 --env macos-release` |
| `DEVELOPER_ID_P12_PASSWORD` | the `.p12` export password | `gh secret set DEVELOPER_ID_P12_PASSWORD --env macos-release` |
| `NOTARY_API_KEY_ID` | the App Store Connect API key ID | App Store Connect › Users and Access › Integrations › Team Keys › generate a key with the Developer role; its Key ID |
| `NOTARY_API_ISSUER_ID` | the issuer ID shown above the team keys | same page |
| `NOTARY_API_KEY_P8_BASE64` | the key's `AuthKey_<ID>.p8`, base64 (downloadable once) | `base64 -i AuthKey_<ID>.p8 \| gh secret set NOTARY_API_KEY_P8_BASE64 --env macos-release` |

Switching to Omacom's Developer ID replaces these secrets and `INSTALLER_TEAM_ID`/`INSTALLER_APP_SIGNING_IDENTITY` in `identity.conf` (with a regenerated `Release/release.json`); testers reinstall once because the helper trusts only its own team.
