# Omarchy Mac Installer

Development source for the Apple Silicon macOS installer, extracted from [maralcbr/omarchy-mx-mac](https://github.com/maralcbr/omarchy-mx-mac) into [omacom/omarchy-mac-installer](https://github.com/omacom/omarchy-mac-installer).

This first extraction preserves the installer behavior and Git attribution. The app is now named **Omarchy Installer**; it keeps the original `com.omarchy.mx.*` identifiers, download keys and release configuration, and the package removes a copy left under the old name, Omarchy MX Mac Installer. Integration with the shared Omarchy packages and Linux installation image is the next, separate change. This candidate is not an installation release.

## Source layout

| Directory | Responsibility |
| --- | --- |
| `Sources/`, `Tests/`, `Package.swift` | Swift macOS app, trust core, helper, simulation and tests |
| `Engine/` | Pinned Asahi source lock, Python overlay, build tooling and tests |
| `Packaging/` | App and macOS package assembly |
| [`Recovery/`](Recovery/README.md) | Omarchy Step 2 GUI preview, standalone macOS 13 target and app packaging |
| `Release/` | Inherited public trust root and release descriptor |
| `scripts/` | Catalog and release tools, with fixture tests |
| `test/` | Portable aggregate runner and extracted packaging tests |
| `evidence/` | Recorded journal fixture required by the Swift tests and preview |

## Supported Macs

Every catalog that offers a Mac release enables every M1, M2 and M3 Mac: the 34 boards in [`scripts/supported-models.json`](scripts/supported-models.json). `make-unsigned-catalog.py` refuses inputs that miss, add or refuse one, and `publish-channels envelope` refuses to wrap a catalog that lists a Mac but leaves any of them out or disabled; only an empty "No Mac release yet" catalog lists none. `os-promote` does not re-check an envelope staged before this rule, so a rollback to an older catalog stays possible. The file also names the boards that stay refused and why: the M3 Ultra Mac Studio (`apple,j575d`), which the pinned v0.9.2 engine cannot inspect, and M4 and later (`apple,j614s`). M3 Macs run with software rendering (llvmpipe) until their GPU driver lands.

## Start with the tests

The portable suite requires Bash 5+, Python 3.12+, Git and standard Unix tools, including GNU `sha256sum`. It runs on Linux and can run on macOS with those tools installed:

```bash
bash test/all
```

On macOS, use a Bash 5 installation explicitly if the system Bash is older. The suite uses temporary fixtures and mocked publishing/SSH commands; it does not install anything. The source directory is sufficient; no desktop checkout or engine binary is needed for these tests. The Linux suite passed, followed by strict Swift formatting, 402 debug tests, 396 release tests and ad-hoc app assembly on an M4 Pro. The debug simulation also launched successfully; see the [recorded validation and limits](docs/validation.md#local-evidence).

The Swift package requires macOS 15+ and Swift 6.2+. Follow [validation.md](docs/validation.md) for Xcode checks and a simulation-only review. App packaging additionally requires an authenticated engine archive; see [the extraction prerequisites](docs/extraction.md#inherited-prerequisites-and-open-issues) before following the inherited [packaging guide](Packaging/README.md).

## Review and next steps

Start by reviewing the [standalone adaptations against the unchanged extraction](https://github.com/omacom/omarchy-mac-installer/compare/0d6f8661a5ad7b263d6167f0afea7cae033419a0...main). The original commit mapping and validation evidence are linked below.

Changes to `main` go through pull requests with approval from someone other than the author. The [CI checks](docs/validation.md#continuous-integration) cover portable tests, Swift formatting and both Swift build configurations. Define the Linux image and shared package inputs in separate changes. Physical installation qualification follows the assembled image/package integration.

- [Extraction provenance and boundaries](docs/extraction.md): original revision, preserved history, inherited build issues and future shared-package integration.
- [Validation and macOS handoff](docs/validation.md): what has been checked and what remains.
- [Simulation guide](Development/Simulation.md): debug-only UI scenarios that avoid real installation.

The preserved release and cutover tools target the original publisher's infrastructure. They are not a release procedure for Omacom. Publishing, signing, privileged helper registration and physical installation require separate preparation and authorization.

## License

The original [MIT license](LICENSE), copyright notice and Git attribution are retained. External engine dependencies retain their own licenses; their exact revisions are recorded in `Engine/source-lock.json`.

## Linux image producer

The Apple Silicon image producer is `image-builder/`: mx-mac's `build-mac-image`, building from a signed candidate set with the authenticated candidate importer, and inspecting each image before it is packaged. See [checks and entrypoints](docs/image-builder.md), [how to build](image-builder/README.md) and [one image producer](docs/image-producer.md).
