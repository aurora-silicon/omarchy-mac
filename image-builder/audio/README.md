# Aurora J700 audio packages

The standard Asahi audio packages do not yet contain the J700 UCM and DSP profiles. A Neo image requires all three pinned repositories in `build-packages.py`: `speakerguardd`, `alsa-ucm-conf-asahi`, and `asahi-audio`.

Build and test `speakerguardd` with `cargo test --locked` and `cargo build --locked --release --target aarch64-unknown-linux-gnu`. Then run `build-packages.py --speakerguardd CHECKOUT --alsa-ucm-conf-asahi CHECKOUT --asahi-audio CHECKOUT --output NEW_DIRECTORY`. Install every package in the resulting manifest together, in the image root with `pacman --root IMAGE_ROOT -U ...`, before image finalization.

The packages retain the kernel speaker interlock. The feed-forward daemon explicitly selects `AppleJ700` because its capture-only AOP sibling can enumerate first. A model-specific condition skips the stock feedback daemon on J700 while keeping it available on other Macs. The J700 udev rule starts `speakerguardd` when its sense PCM appears; do not enable this J700-only service globally in a universal image.

Existing images need a PipeWire/WirePlumber restart after replacing the profiles. New images use the new profiles at first boot. No microphone recording or playback is required to install the packages.

## Clamshell microphone: omarchy-mac mapper patch

`omarchy-mac/0001-Drop-the-Asahi-mic-mapping-while-the-array-is-absent.patch` is not for this repository. It patches `bin/omarchy-audio-asahi-mic-map` and its test in omacom/omarchy-mac (branch `quattro`, against 458042ba7f), which installs `omarchy-asahi-mic.service` on every Apple machine. It is carried here because the Neo work lands on `feat/neo`; whoever packages omarchy-mac for the Neo applies it there.

With the clamshell kernel (`t8140-aop-audio` "Internal Mic Jack") and the matching UCM, closing the lid removes the J700 microphone array from PipeWire. Without this patch the mapper keeps its null sink, and its monitor stays the default source and records silence. With it, the mapper removes its sink while the array is absent, so applications fall back to another microphone, and recreates it with the saved gain when the lid opens, when WirePlumber selects the configured monitor again.

It also keeps two error paths safe: a run that configured the monitor itself and then fails rolls that default back, and a gain that cannot be saved while the array is gone does not keep the silent mapping.

Tested only with the mapper's own test (`bash test/shell.d/asahi-mic-map-test.sh`, which fails without the patch). Not tested on Omarchy hardware.
