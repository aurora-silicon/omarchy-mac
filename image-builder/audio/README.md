# Aurora J700 audio packages

The standard Asahi audio packages do not yet contain the J700 UCM and DSP profiles. A Neo image requires all three pinned repositories in `build-packages.py`: `speakerguardd`, `alsa-ucm-conf-asahi`, and `asahi-audio`.

Build and test `speakerguardd` with `cargo test --locked` and `cargo build --locked --release --target aarch64-unknown-linux-gnu`. Then run `build-packages.py --speakerguardd CHECKOUT --alsa-ucm-conf-asahi CHECKOUT --asahi-audio CHECKOUT --output NEW_DIRECTORY`. Install every package in the resulting manifest together, in the image root with `pacman --root IMAGE_ROOT -U ...`, before image finalization.

The packages retain the kernel speaker interlock. The feed-forward daemon explicitly selects `AppleJ700` because its capture-only AOP sibling can enumerate first. A model-specific condition skips the stock feedback daemon on J700 while keeping it available on other Macs. The J700 udev rule starts `speakerguardd` when its sense PCM appears; do not enable this J700-only service globally in a universal image.

Existing images need a PipeWire/WirePlumber restart after replacing the profiles. New images use the new profiles at first boot. No microphone recording or playback is required to install the packages.
