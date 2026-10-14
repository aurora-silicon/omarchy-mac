# Guarded GE-Proton native ntdll

This is the native Unix-side ntdll for GE-Proton11-7 ARM64, not a Wine SDK or a complete replacement Wine distribution. The package supplies an independently named first-launch compatibility tool; Steam user compatibility choices remain unchanged.

Build from GloriousEggroll/proton-ge-custom `c191f35dcebbeccfacd3b4c6f6eea026e588c1c2`, ValveSoftware/wine `46b29104e3741fe23bf5e2547196a253aab88c89`, wine-staging `6cc805ea57132eeaf44764e9213823c9b8d0d300`, with that GE revision's Wine preparation/patch section and pinned wineopenxr sources. Preserve the public GE preparation, including staging exclusions and game patches. Apply aurora-silicon/aurora-steam-native `a1b375b287fe6db4d2e95beb9d945af15b3ef9db` `proton/wine-arm64-sve-payload-guard.patch` (SHA256 `db9da41be4dda3cb89cfec3d6ad7360a7260de023a3007048542202ab57106fe`). The actual prepared source/cache is preserved separately; the artifact receipt records this incremental source-backed route, not a pristine clean GE reproduction claim.

Before isolating the build, fetch the source-declared Vulkan inputs from `https://raw.githubusercontent.com/KhronosGroup/Vulkan-Docs/v1.4.357/xml/vk.xml` (SHA256 `264d0d7350e37d70c82407fb430d085040fc01a9a961d43dec8c2d6ed1dfd183`) and the same tag's `video.xml` (SHA256 `d018b914014c06605e367a3b929670511e6f6de2f225c405a8b5e2d912408b76`). No generator network fallback is needed:

```bash
cd "$prepared_wine"
python3 dlls/winevulkan/make_vulkan -x "$inputs/vk.xml" -X "$inputs/video.xml"
perl tools/make_specfiles
mkdir -p "$build"
cd "$build"
"$prepared_wine/configure" --host=aarch64-linux-gnu --enable-win64 --disable-tests --without-x --without-wayland --without-freetype
make -j "${OMARCHY_BUILD_JOBS:-10}" dlls/ntdll/ntdll.so
```

The normal public-source route is `python3 build-source.py fetch /absolute/new-owned-work` on the source host, then `python3 build-source.py build /absolute/new-owned-work` in the isolated native ARM64 LLVM/toolchain environment. Fetch verifies exact Git source identities and public XML/patch hashes; build verifies the adapter against the pinned public GE Wine section, preserves the owned source, and emits a ready-to-makepkg `package/` directory with actual newly generated hashes. It requires the same normal Wine build prerequisites (compiler, binutils, autoconf, bison, flex, Perl, Python); no private prepared tree is required. This clean script route has source/contract checks; the reviewed binary came from the preserved prepared source and is separately qualified.

Stage `dlls/ntdll/ntdll.so`, the source `COPYING.LIB`, and an actual source/build/ABI receipt beside the PKGBUILD. Generate sha256sums from those newly built files before makepkg; these template hashes bind the reviewed artifact only and must not be attributed to other builds. No source binaries are committed. Public artifact reuse requires a separately published immutable URL/hash; a private artifact cache alone is not a reproducibility route.

The reviewed artifact matches the pinned vendor ntdll's complete global/weak export set, SONAME, libc-only dependency and GLIBC version requirements. An exact-source guard fixture covers 14 valid/invalid record cases under ASan/UBSan. Network-disabled build, normal package install/integrity/removal passed. These checks do not establish Wine/game execution, GPU correctness or physical installation.
