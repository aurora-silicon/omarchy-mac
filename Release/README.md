# Installer release inputs

Production packaging reads this directory and copies its contents into
`Omarchy Installer.app/Contents/Resources/Release/`:

- `release.json` — schema version 3 descriptor naming the stable, rc and edge
  channel catalog URLs, the default channel, the expected Ed25519 trust-root
  fingerprint, the helper Mach service name, and the helper code-signing
  requirement. Generate it with `scripts/make-release-descriptor`.
- `trust-root.ed25519.pub` — exactly 32 raw Ed25519 public-key bytes matching
  the descriptor fingerprint.

Both files are the same for every build. The trust root changes only when the
signing key is rotated; the descriptor also changes when the default channel
does.

`trust-root.ed25519.pub` is the only place the trust root is set. To swap the
catalog key, replace that file with the new 32-byte public key and run
`scripts/make-release-descriptor --public-key Release/trust-root.ed25519.pub
--output Release/release.json` (after removing the old descriptor) to update
the pinned fingerprint; `test/all` fails until the two agree. A build can also
take both files from another release directory, `build-app.sh
RELEASE_DIRECTORY OUTPUT_DIRECTORY`, which checks that they match.

The trust root is the Omacom catalog key (`sha256:bb914ffba2a74d05fd8d57013999376654ff9d7489929c76996a7f7716f27ea3`). Its private key is the `CATALOG_SIGNING_KEY` secret of the `catalog-release` environment, used only by `.github/workflows/mac-catalog-sign.yml` (which `mac-catalog.yml` and the parked `mac-promote.yml` call), with the owner's backup in the Keychain item `omacom-catalog-signing-key` and 1Password. It must never appear here or anywhere else on disk; see [`docs/catalog-release.md`](../docs/catalog-release.md).

The default channel is `edge`. The channels match Omarchy's (stable, rc, edge; dev is a developer choice made after installation), and today only edge has a Mac release. Stable and rc serve signed empty catalogs (`scripts/publish-channels empty-catalog`), which the app shows as "No Mac release yet", never as a channel it cannot reach or verify.

The catalog URLs are `INSTALLER_CATALOG_BASE/catalog-<channel>.signed.json` (`Packaging/identity.conf`): `https://mac.omarchy.org/v1/catalog-stable.signed.json`, `catalog-rc.signed.json` and `catalog-edge.signed.json`. Every signed app keeps reading these addresses, so they never change for a released app. The existing publishing tools (`scripts/publish-channels`) still write their older stream layout to the previous host until publishing moves to `mac.omarchy.org`. The app keeps its accepted catalog sequences in stream-named state files so the MX Mac installer's rollback floors and this one's never meet.

The descriptor names every channel because the app is signed once: a channel absent from the descriptor
cannot be opened later without shipping another signed app.

The app rejects missing, symlinked, group- or world-writable, oversized,
unknown, or mismatched release inputs, and `build-app.sh` refuses a descriptor
whose schema, helper identity, fingerprint, or channel URLs do not match the
product it is building.

For a private or offline build the directory may also contain a signed
`catalog.json` and `catalog.json.sig` pair. The app then verifies that sealed
catalog with the same trust root instead of fetching a channel. Production
builds omit the pair so the app reads its channel at run time.

The helper identity, team and catalog base in `release.json` come from `Packaging/identity.conf`; `test/all` fails when the descriptor no longer matches it.
