# Native Recovery input

GUI installs carry the installer's signed enrollment app separately from the distro image. A distro package without `recovery_gui` metadata still receives the native app. There is no GUI fallback to the legacy Recovery launcher.

The app serializes its bundled template into `native-recovery.json`, a bounded flat dictionary of relative file names and base64 file data. This is an input container, not a privileged ZIP or tar extraction. The handoff manifest's optional `recovery_template` record fixes its name, size and SHA-256. The ordinary helper importer copies that regular file through the submitted directory descriptor; symlinks and FIFOs are refused. These transit hashes do not authorize executable code.

The helper requires this input for execution. It reconstructs a private app with fixed permissions, rejects unsafe paths and per-install data, and verifies the app against its own signing policy. Ad-hoc helpers require the launchd-pinned code hash. Named-signing helpers require the fixed enrollment identifier and their own signing team. Neither the GUI nor the distro supplies that requirement. The encoded container is limited to 64 MiB, with at most 10,000 files and 1,024-byte relative paths.

The verified app is also published at the helper-owned Recovery template location for subsequent account and shutdown operations. Files are flushed before publication; the containing directory is flushed after the atomic replacement. An exchanged previous tree is retained if that durability check fails. Initial staging does not depend on an app installed in `/Applications`.

The engine must advertise `nativeRecoveryInput: helper-template-v1` in its byte-pinned `engine-capabilities.json`. A helper rejects an older engine before launching it, so an old runtime cannot silently ignore the new input. The engine validates the explicit app inventory and signature during preflight. It also resolves the original source System volume and authenticated volume owner before mutation, retains that identity, and compares it again when constructing the target's configuration.

The existing publication transaction stages the unchanged signed app and separate `Aurora/Recovery/InstallData` configuration, finalized firmware and boot payloads. It updates the launch marker only after that state is verified. Interrupted publication retains its existing resume behavior.

Ship the rebuilt engine and matching catalog entry with a new app/helper build. The source lock and content-derived engine name identify that runtime. An already completed legacy installation is not converted by replaying its disk-install checkpoints; it needs a separate bounded staging action with fresh owner authorization.

This change makes template preparation and admission native Swift. The installation backend still contains the existing engine adapter; the Aurora requirement to replace that backend entirely with Swift remains separate unfinished work.
