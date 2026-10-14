# Public asahi-bless 0.4.4

The recipe pins public AsahiLinux/asahi-nvram commit `3df52c939fbcedb03344212090d25c98afe4dec1`. It includes Sasha Finkelstein's upstream arbitrary-bank fix, `70b16a288cfc6795bc1b145255325f59f000be28`, and the 0.4.4 release. Upstream authorship and licensing are preserved.

Build with `makepkg --syncdeps` on native Arch ARM64. The recipe verifies the clean source revision, fetches locked Cargo dependencies, and builds with `--frozen` in a separate output directory. Checks run the upstream library tests and synthetic valid/invalid 16- and 29-bank parser cases entirely in memory. The package includes the source revision, Cargo.lock and MIT license; its runtime dependencies are glibc and libgcc.

The reviewed AArch64 binary was built offline with Rust 1.99.0, then repackaged through this recipe without recompilation. Package installation, integrity checks, version/help and removal passed. No validation read or wrote hardware NVRAM or invoked boot selection; Neo boot qualification remains pending. The installer retains its minimum-version gate of 0.4.4.
