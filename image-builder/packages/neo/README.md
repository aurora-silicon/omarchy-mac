# Public Neo package recipes

This is a minimal source-only normalization bundle for review. It contains normal PKGBUILDs, required source/support files, exact source/development-input locks and build instructions. It contains no packages, driver binaries, controller configuration, signing credentials or captured device state. Root owns publication and final package/image qualification; no clean kernel/Mesa/FEX rebuild is claimed by preparing this bundle.

The intended sources are Linux 5f6c917, Aura c4331a9, U-Boot0cb6fed6, native/guest Mesa524105a, compatible Omarchy runtime/settings a76179c, public speaker d6ee942, public libfprint/SEP sources and the source pins recorded in each recipe. Read ORIGINS.md for licensing and provenance. Stock platform omarchy-mac0.1.4-1 stays a verified signed stock input; its45-entry public-source correspondence is independently recorded by assembly. It is not rebuilt or relabeled here.

Read BUILD.md for clean source builds and optional qualified reuse. `public-reuse-assets.json` and FEX's `reuse.lock.json` intentionally refuse absent immutable public asset URLs. Publishing recipes does not make private caches publicly downloadable. Root must complete and qualify those public links before advertising the reuse path. Clean source builds do not depend on a private build directory.

The corrected guest overlay recipe targets the actual public Mesa524 source and emits `26.3.0-devel.20261014.g524105a-arch2`. The earlier worker's `-arch.1` stamp is superseded, not silently relabeled. Dedicated guest-cache recompilation/repacking and new artifact receipts belong to the native worker. No full native Mesa rebuild is needed for that metadata correction.

The FEX development sysroot is built from exact public Fedora RPMs in `guest-rpms.lock.json`, with source-build origins and SHA256 values pinned. These are development inputs only. Native runtime dependencies, actual guest rootfs, muVM, Valve client/runtime/Proton availability and licensing remain separate assembly inputs. `mesa-dummy` belongs only inside the guest rootfs, never the native host.

Source fixtures:

```sh
python3 -m unittest discover -s tests -v
find recipes -name PKGBUILD -exec bash -n '{}' \;
python3 -m py_compile recipes/fex/sources.py scripts/*.py tests/*.py
```

They exercise clean checkout guards, ignored/untracked injection refusal, local/default runtime source selection, current overlay version/cross-file declaration, pinned support hashes and reuse rejection. They are not compiler, dependency-transaction, performance or hardware qualification. Fresh boot, encryption, SEP enrollment/reboot persistence, speaker safety, GPU/compositor and gaming functionality still need the actual software image and physical gates.
