# Source and recipe provenance

The runtime pair derives from omacom/omarchy-pkgs c33fd8c2547896b0c9ff355fd8e0d11d67caba08 and targets omacom/omarchy-mac a76179cdcf1e844251eecac2708b687c486aa497. Original maintainers remain in each PKGBUILD; normal differing package releases are intentional.

Aura c4331a90ef324eab33d34d1515d7e42748a293ab and U-Boot 0cb6fed6a10512d1013a4a80b6d83c3d56140f2f are public aurora-silicon sources. The package-owned Neo selector/removal hooks retain their original GPL-2.0-only notices. Their current authored recipe/support sources must be published with this distribution, not represented as unchanged upstream code.

The kernel is aurora-silicon/linux d32c6c259c49157b81bed62571c314710e585d98. Current artifacts use a qualified incremental build seeded by cd46babc03d1193d2bdaa23de076a185bc602b57, with exact public d32 SEP source rebuilt. This is not a clean or bit-identical reproduction claim. Build configuration is included; Linux COPYING/LICENSES come from the pinned source.

FEX source and source-only dependency commits/trees are in source-lock.json. Public development RPM inputs are in guest-rpms.lock.json. These are build-only inputs, not guest runtime authority or vendor-client licensing. License notices are individually pinned. The optional reviewed FEX package reuse digest is in reuse.lock.json; its public URL must be completed by the publisher before reuse is enabled.

Guest Mesa overlays derive from the licensed ALARM/Asahi recipe retained by worker1921, with pinned public Mesa524 source (26.3-devel) and the source-declared x86 cross file. They are separate guest images, not substitutes for native Mesa524. mesa-dummy is guest-rootfs-only and must not enter the native host package set.

Speaker source is public speakerguardd d6ee942ddfa129d5685c03d2f4fd230216f4fb93; the model-specific stock-daemon condition and unit drop-in are retained. Its draft/physical qualification status is preserved. libfprint applies public aurora-sep-userspace 4cd00a488f97889d3d2f068e5f2694d7f9aaf5ed patches to official v1.94.100, with LGPL/NIST notices retained. UPower 00e8cb66b408e2a7e5f1c527accbe0634a12996c and Steam launcher a1b375b287fe6db4d2e95beb9d945af15b3ef9db are public sources.

GTK2 comes from GNOME 2.24.33 and the licensed AUR recipe adaptation at 19829b43; local support patches, hook, install script, LICENSE and REUSE.toml are included with original notices. Its upstream source license remains LGPL-2.1-or-later.

The normal SEP loader changes already live in public Linux 5d38582. Firmware/peripheral ordering lives in the maintained public installer integration. Import those normal sources from their immutable public commits; do not copy stale activation-approved or sep-firstboot authority proposals. Stock platform omarchy-mac0.1.4-1 remains a signed stock package with independently verified45-path correspondence to public222f source/c33 recipe; no redundant rebuild is proposed.

Steam package-owned first-launch support and policy are MIT, Copyright 2026 Ryan Murray. The 0.1.0-2 recipe/support are the actual finalized worker1922 follow-up sources, unchanged; public a1b installer bytes remain upstream. Vendor manifest/cache are separately admitted image inputs and are absent from this source bundle.
