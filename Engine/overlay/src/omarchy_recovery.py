# SPDX-License-Identifier: MIT
"""Stage the native Recovery app against the actual newly created volumes.

The app template is an authenticated engine input and is copied unchanged.
Per-install config and raw payloads live beside it on the stub volume, after
stage 1 and the ESP have been finalized and before autolaunch is selected.
No machine UUID, administrator name, credential or calibration is compiled in.
"""

import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import tempfile
import uuid

APP_NAME = "Omarchy Installer.app"
INSTALL_DATA_DIRECTORY = "Aurora/Recovery/InstallData"
PAYLOAD_DIRECTORY = "aurora/recovery"
MANIFEST_NAME = "omarchy-recovery-app.json"
STAGE2_PATH = "m1n1/boot.bin"
VENDOR_FIRMWARE = ("vendorfw/firmware.tar", "vendorfw/firmware.cpio", "vendorfw/manifest.txt")
OPTIONAL_VENDOR_FIRMWARE = "vendorfw/u-boot/asmedia/asm2214a-apple.bin"
UUID_PATTERN = re.compile(r"[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}\Z")


class RecoveryError(ValueError):
    pass


def identifier(value):
    if not isinstance(value, str):
        raise RecoveryError("missing target volume UUID")
    value = value.upper()
    if not UUID_PATTERN.fullmatch(value) or uuid.UUID(value).int == 0:
        raise RecoveryError("invalid target volume UUID")
    return value


def source_system_volume(dutil, source_os):
    """Resolve the System volume, never the mounted macOS boot snapshot."""
    group = identifier(source_os.vgid)
    observed = dutil.get("info", "-plist", source_os.sys_volume)
    if identifier(observed.get("APFSVolumeGroupID")) != group:
        raise RecoveryError("bootstrap source volume identity changed")
    matches = []
    tree = dutil.get("apfs", "list", "-plist")
    for container in tree.get("Containers", []):
        for volume in container.get("Volumes", []):
            if "System" not in volume.get("Roles", []):
                continue
            uuid = identifier(volume.get("APFSVolumeUUID"))
            info = dutil.get("info", "-plist", uuid)
            if info.get("APFSVolumeGroupID", "").upper() != group:
                continue
            if identifier(info.get("VolumeUUID")) != uuid:
                raise RecoveryError("bootstrap source volume identity changed")
            matches.append(info)
    if len(matches) != 1:
        raise RecoveryError("bootstrap source System volume is missing or ambiguous")
    return matches[0]


def digest(data):
    return hashlib.sha256(data).hexdigest()


def app_inventory(app):
    """Byte inventory, independent of FAT's synthesized permission bits."""
    app = Path(app)
    if not app.is_dir() or app.is_symlink():
        raise RecoveryError("native Recovery app template is missing")
    files = {}
    for path in sorted(app.rglob("*")):
        if path.is_symlink() or not (path.is_file() or path.is_dir()):
            raise RecoveryError("native Recovery app contains a non-regular entry")
        if path.is_file():
            data = path.read_bytes()
            files[path.relative_to(app).as_posix()] = {
                "sha256": digest(data), "bytes": len(data),
            }
    return {"schema": 1, "buildMode": "recovery", "files": files}


def validate_source(app_source, manifest_path, run=subprocess.run, requirement=None):
    app_source = Path(app_source)
    try:
        manifest = json.loads(Path(manifest_path).read_text())
        if manifest != app_inventory(app_source):
            raise RecoveryError("native Recovery app differs from its engine manifest")
        info = plistlib.loads((app_source / "Contents/Info.plist").read_bytes())
        if (info.get("OmarchyRecoveryBuildMode") != "recovery"
                or info.get("CFBundleExecutable") != "OmarchyRecovery"
                or info.get("CFBundleDisplayName") != "Omarchy Installer"):
            raise RecoveryError("native Recovery input is not a real enrollment build")
        if info.get("OmarchyRecoveryDataLayout") != "external-install-data-v1":
            raise RecoveryError("native Recovery input uses an unsupported installation data layout")
        strings = (app_source / "Contents/Resources/en.lproj/InfoPlist.strings").read_text()
        if '"CFBundleDisplayName" = "Omarchy Installer";' not in strings:
            raise RecoveryError("native Recovery app lacks its localized launch name")
        executable = app_source / "Contents/MacOS/OmarchyRecovery"
        if not executable.is_file():
            raise RecoveryError("native Recovery executable is missing")
        command = ["/usr/bin/codesign", "--verify", "--deep", "--strict"]
        if requirement is not None:
            if not isinstance(requirement, str) or not requirement:
                raise RecoveryError("native Recovery signature identity is missing")
            command.append("-R=" + requirement)
        run(command + [str(app_source)], check=True)
    except (OSError, KeyError, json.JSONDecodeError, plistlib.InvalidFileException) as error:
        raise RecoveryError("native Recovery app template is incomplete") from error
    return manifest


def validate_payload(package):
    """Validate native app bytes in the authenticated OS ZIP before any erase."""
    prefix = "esp/" + PAYLOAD_DIRECTORY + "/"
    try:
        manifest = json.loads(package.read(prefix + MANIFEST_NAME))
        if (set(manifest) != {"schema", "buildMode", "files"}
                or manifest["schema"] != 1 or manifest["buildMode"] != "recovery"
                or not isinstance(manifest["files"], dict) or not manifest["files"]):
            raise RecoveryError("invalid native Recovery payload manifest")
        app_prefix = prefix + APP_NAME + "/"
        actual = {n[len(app_prefix):] for n in package.namelist()
                  if n.startswith(app_prefix) and not n.endswith("/")}
        if actual != set(manifest["files"]):
            raise RecoveryError("native Recovery app files differ from the payload manifest")
        for name, expected in manifest["files"].items():
            if any(part in ("", ".", "..") for part in name.split("/")):
                raise RecoveryError("invalid native Recovery payload path")
            info = package.getinfo(app_prefix + name)
            if (info.external_attr >> 16) & 0o170000 == 0o120000:
                raise RecoveryError("native Recovery payload contains a symbolic link")
            data = package.read(app_prefix + name)
            if expected != {"sha256": digest(data), "bytes": len(data)}:
                raise RecoveryError("native Recovery payload checksum mismatch")
        info = plistlib.loads(package.read(app_prefix + "Contents/Info.plist"))
        if (info.get("OmarchyRecoveryBuildMode") != "recovery"
                or info.get("CFBundleExecutable") != "OmarchyRecovery"):
            raise RecoveryError("native Recovery payload must be a real recovery build")
        if info.get("OmarchyRecoveryDataLayout") != "external-install-data-v1":
            raise RecoveryError("native Recovery payload uses an unsupported installation data layout")
        if "Contents/MacOS/OmarchyRecovery" not in actual:
            raise RecoveryError("native Recovery executable is missing")
    except (OSError, KeyError, TypeError, json.JSONDecodeError, plistlib.InvalidFileException) as error:
        raise RecoveryError("native Recovery payload is incomplete") from error
    return manifest


def source_bootstrap(dutil, source_os, authorized_owner=None, target_group=None):
    """Validate the exact authenticated source owner before target mutation."""
    if source_os is None:
        raise RecoveryError("native Recovery requires the original source OS")
    source = source_system_volume(dutil, source_os)
    source_uuid = identifier(source.get("VolumeUUID"))
    source_group = identifier(source.get("APFSVolumeGroupID"))
    if source_group != identifier(source_os.vgid) or source_group == target_group:
        raise RecoveryError("bootstrap source volume identity changed")
    users = dutil.get("apfs", "listUsers", source_uuid, "-plist")
    owners = {identifier(user.get("APFSCryptoUserUUID"))
              for user in users.get("Users", []) if user.get("VolumeOwner") is True}
    if authorized_owner is None:
        authorized_owner = os.environ.get("OMARCHY_MACHINE_OWNER", "")
    if not isinstance(authorized_owner, str) or not re.fullmatch(r"[A-Za-z0-9._-]{1,255}", authorized_owner):
        raise RecoveryError("authorized bootstrap owner is unavailable")
    source_preboot = dutil.get("info", "-plist", source_os.preboot)
    if identifier(source_preboot.get("VolumeUUID")) != identifier(source_os.preboot_vgid):
        raise RecoveryError("bootstrap source Preboot identity changed")
    admin_path = Path(source_os.preboot) / source_group / "var/db/AdminUserRecoveryInfo.plist"
    try:
        admins = plistlib.loads(admin_path.read_bytes())
        selected = identifier(admins[authorized_owner]["GeneratedUID"])
    except (OSError, ValueError, KeyError, TypeError, plistlib.InvalidFileException) as error:
        raise RecoveryError("authorized bootstrap owner is absent from source Preboot metadata") from error
    if selected not in owners:
        raise RecoveryError("authorized bootstrap user is not an APFS source volume owner")
    return {"mode": "source-volume-owner", "sourceSystemUUID": source_uuid,
                 "sourceGroupUUID": source_group, "ownerUUIDs": [selected]}


def target_config(installer, esp_uuid, esp_root, source_os=None, authorized_owner=None, expected_bootstrap=None):
    osi = installer.osi
    system = Path(osi.system)
    info = installer.dutil.get("info", "-plist", str(system))
    preboot = installer.dutil.get("info", "-plist", osi.preboot)
    esp = installer.dutil.get("info", "-plist", str(esp_root))
    group = identifier(osi.vgid)
    preboot_uuid = identifier(osi.preboot_vgid)
    esp_uuid = identifier(esp_uuid)
    if (identifier(info.get("APFSVolumeGroupID")) != group
            or info.get("MountPoint") != str(system)
            or identifier(preboot.get("VolumeUUID")) != preboot_uuid
            or identifier(esp.get("DiskUUID")) != esp_uuid
            or esp.get("Content") != "EFI" or esp.get("MountPoint") != str(esp_root)):
        raise RecoveryError("native Recovery target identities changed")
    name = info.get("VolumeName")
    if (not isinstance(name, str) or not 1 <= len(name) <= 80
            or "/" in name or any(ord(c) < 32 or ord(c) == 127 for c in name)):
        raise RecoveryError("invalid target volume name")
    bootstrap = (source_bootstrap(installer.dutil, source_os, authorized_owner, group)
                 if source_os is not None else None)
    if expected_bootstrap is not None and bootstrap != expected_bootstrap:
        raise RecoveryError("source owner changed after native Recovery preflight")
    return {
        "schema": 2, "volumeName": name, "systemUUID": identifier(info.get("VolumeUUID")),
        "groupUUID": group, "prebootUUID": preboot_uuid, "espUUID": esp_uuid,
        "bootMode": "raw", "stage2Path": STAGE2_PATH, "bootstrap": bootstrap,
        "allowCustomBootArguments": getattr(getattr(installer, "sysinfo", None), "device_class", "") == "j700ap",
    }


def _json(path, value):
    path.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")


def _atomic_bytes(path, data, mode=0o600):
    path = Path(path)
    if path.is_symlink():
        raise RecoveryError("refusing a symbolic link in Recovery publication")
    with tempfile.NamedTemporaryFile(prefix=".recovery-write-", dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        try:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
            os.chmod(temporary, mode)
            os.replace(temporary, path)
            directory = os.open(path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        finally:
            temporary.unlink(missing_ok=True)


def _verify_staged_app(app, template, run):
    if app_inventory(app) != template:
        raise RecoveryError("existing Recovery application differs from its template")
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)


def _install_data_root(system):
    root = Path(system)
    for component in INSTALL_DATA_DIRECTORY.split("/"):
        root = root / component
        if root.is_symlink() or (root.exists() and not root.is_dir()):
            raise RecoveryError("unsafe Recovery installation data path")
    return root


def _verify_install_data(root, config, files, manifest):
    expected = {"install-config.json", "AuraPayloads/manifest.json"}
    expected.update("AuraPayloads/" + name for name in files)
    actual = set()
    for path in root.rglob("*"):
        if path.is_symlink() or not (path.is_file() or path.is_dir()):
            raise RecoveryError("unsafe Recovery installation data entry")
        if path.is_file():
            actual.add(path.relative_to(root).as_posix())
    if actual != expected:
        raise RecoveryError("existing Recovery installation data is incomplete or changed")
    if json.loads((root / "install-config.json").read_text()) != config:
        raise RecoveryError("existing Recovery app belongs to another installation")
    if json.loads((root / "AuraPayloads/manifest.json").read_text()) != manifest:
        raise RecoveryError("existing Recovery startup bundle differs from this operation")
    for name, data in files.items():
        if (root / "AuraPayloads" / name).read_bytes() != data:
            raise RecoveryError("existing Recovery payload is incomplete or changed")


def _flush_directory(path):
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0))
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _flush_tree(root):
    # Persist copied files and child entries before exposing either root.
    paths = sorted(root.rglob("*"), key=lambda p: len(p.parts), reverse=True) + [root]
    for path in paths:
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        if path.is_dir():
            flags |= getattr(os, "O_DIRECTORY", 0)
        fd = os.open(path, flags)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)


def _payload(path, maximum=256 << 20):
    path = Path(path)
    if path.is_symlink() or not path.is_file():
        raise RecoveryError("finalized startup payload is missing")
    size = path.stat().st_size
    if not 0 < size <= maximum:
        raise RecoveryError("finalized startup payload has an invalid size")
    return path.read_bytes()


def stage(installer, esp_uuid, esp_root, app_source=None,
          manifest_path=None, run=subprocess.run, source_os=None,
          requirement=None, authorized_owner=None, expected_bootstrap=None):
    """Called after OS/ESP installation and common stage-1 target patching.

    Preserve upstream's Finish Installation resource paths for resume checks;
    its step2.sh becomes a relative launcher for the native app. The GUI remains
    on the stub after successful enrollment disables .IAPhysicalMedia.
    """
    template_root = Path(esp_root) / PAYLOAD_DIRECTORY
    app_source = Path(app_source) if app_source is not None else template_root / APP_NAME
    manifest_path = Path(manifest_path) if manifest_path is not None else template_root / MANIFEST_NAME
    template = validate_source(app_source, manifest_path, run, requirement=requirement)
    config = target_config(installer, esp_uuid, esp_root, source_os, authorized_owner, expected_bootstrap)
    system = Path(installer.osi.system)
    esp_root = Path(esp_root)
    stage1 = _payload(installer.boot_obj_path)
    stage2 = _payload(esp_root / STAGE2_PATH)
    # Copy only this installation's finalized package. Never put these
    # per-device inputs in the distributable application template.
    firmware = {
        name: _payload(esp_root / name, (1 << 20) if name.endswith(".txt") else (256 << 20))
        for name in VENDOR_FIRMWARE
    }
    if not firmware["vendorfw/manifest.txt"].strip():
        raise RecoveryError("finalized device firmware manifest is empty")
    if os.path.lexists(esp_root / OPTIONAL_VENDOR_FIRMWARE):
        firmware[OPTIONAL_VENDOR_FIRMWARE] = _payload(esp_root / OPTIONAL_VENDOR_FIRMWARE, 16 << 20)
    marker = Path(installer.iapm_path)
    if marker.parent != system or marker.name != ".IAPhysicalMedia":
        raise RecoveryError("unexpected Recovery launch marker path")
    launch = plistlib.loads(marker.read_bytes())
    if not isinstance(launch, dict):
        raise RecoveryError("invalid Recovery launch marker")
    launch["AppName"] = APP_NAME
    destination = system / APP_NAME
    legacy_step2 = Path(installer.step2_sh)
    expected_legacy = system / "Finish Installation.app/Contents/Resources/step2.sh"
    if legacy_step2 != expected_legacy or legacy_step2.is_symlink():
        raise RecoveryError("unexpected legacy Recovery launcher path")
    # Never embed the install-time mount name: Recovery may choose another one.
    launcher = (
        '#!/bin/sh\nset -eu\n'
        'resources=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)\n'
        'exec "$resources/../../../Omarchy Installer.app/Contents/MacOS/OmarchyRecovery" "$@"\n'
    )
    files = {"raw/aura-raw.bin": stage1, "raw/boot.bin": stage2, **firmware}
    install_data = _install_data_root(system)
    payload_manifest = {
        "schema": 2, "defaultMode": "raw", "nestedVirtualization": False,
        "modes": {"raw": {"espPath": STAGE2_PATH}},
        "vendorFirmware": sorted(firmware),
        "files": {name: {"sha256": digest(data), "bytes": len(data)} for name, data in files.items()},
    }
    identity = {"configuration": config,
                "files": {name: digest(data) for name, data in files.items()},
                "template": digest(json.dumps(app_inventory(app_source), sort_keys=True).encode())}
    pending = system / ".omarchy-recovery-publication.json"
    if pending.is_symlink():
        raise RecoveryError("unsafe Recovery publication record")
    if pending.exists():
        info = pending.stat()
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
                or info.st_mode & 0o077 or info.st_size > 128 << 10):
            raise RecoveryError("Recovery publication record is not trusted")
        journal = json.loads(pending.read_text())
        if journal.get("identity") != identity:
            raise RecoveryError("interrupted Recovery publication belongs to another operation")
    else:
        journal = {"identity": identity,
                   "launcher": base64.b64encode(legacy_step2.read_bytes()).decode(),
                   "marker": base64.b64encode(marker.read_bytes()).decode(),
                   "markerMode": marker.stat().st_mode & 0o777}
    if destination.exists():
        _verify_staged_app(destination, template, run)
    if install_data.exists():
        _verify_install_data(install_data, config, files, payload_manifest)
    if not destination.exists() or not install_data.exists():
        with tempfile.TemporaryDirectory(prefix=".omarchy-recovery-stage-", dir=system) as temporary:
            app = Path(temporary) / APP_NAME
            if not destination.exists():
                shutil.copytree(app_source, app)
                (app / "Contents/MacOS/OmarchyRecovery").chmod(0o755)
                _verify_staged_app(app, template, run)
                _flush_tree(app)
            data_stage = Path(temporary) / "InstallData"
            if not install_data.exists():
                data_stage.mkdir(mode=0o700)
                _json(data_stage / "install-config.json", config)
                payloads = data_stage / "AuraPayloads"
                for name, data in files.items():
                    target = payloads / name
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(data)
                    target.chmod(0o600)
                _json(payloads / "manifest.json", payload_manifest)
                _verify_install_data(data_stage, config, files, payload_manifest)
                _flush_tree(data_stage)
            # The same journal binds both immutable app and separate data. A
            # partial publication resumes without changing the signed bundle.
            _atomic_bytes(pending, json.dumps(journal, sort_keys=True).encode())
            if data_stage.exists():
                parent = system
                for component in INSTALL_DATA_DIRECTORY.split("/")[:-1]:
                    parent = parent / component
                    parent.mkdir(mode=0o700, exist_ok=True)
                    _flush_directory(parent.parent)
                _install_data_root(system)
                os.replace(data_stage, install_data)
                _flush_directory(install_data.parent)
            if app.exists():
                os.replace(app, destination)
                _flush_directory(system)
    try:
        if not pending.exists():
            _atomic_bytes(pending, json.dumps(journal, sort_keys=True).encode())
        _verify_staged_app(destination, template, run)
        _verify_install_data(_install_data_root(system), config, files, payload_manifest)
        _atomic_bytes(legacy_step2, launcher.encode(), 0o755)
        _atomic_bytes(marker, plistlib.dumps(launch), journal["markerMode"])
    except Exception:
        # Keep the signed app and bound journal so the same operation can resume.
        _atomic_bytes(legacy_step2, base64.b64decode(journal["launcher"], validate=True), 0o755)
        _atomic_bytes(marker, base64.b64decode(journal["marker"], validate=True), journal["markerMode"])
        raise
    pending.unlink()
    return {"configuration": config, "stage1SHA256": digest(stage1), "stage2SHA256": digest(stage2)}
