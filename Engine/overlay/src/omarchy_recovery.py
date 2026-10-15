# SPDX-License-Identifier: MIT
"""Stage the native Recovery app against the actual newly created volumes.

The app template is an authenticated engine input. Its per-install config and
raw payloads are added only after stage 1 and the ESP have been finalized, then
the copied app is ad-hoc signed again before Recovery autolaunch is selected.
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


def validate_source(app_source, manifest_path, run=subprocess.run):
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
        strings = (app_source / "Contents/Resources/en.lproj/InfoPlist.strings").read_text()
        if '"CFBundleDisplayName" = "Omarchy Installer";' not in strings:
            raise RecoveryError("native Recovery app lacks its localized launch name")
        executable = app_source / "Contents/MacOS/OmarchyRecovery"
        if not executable.is_file():
            raise RecoveryError("native Recovery executable is missing")
        run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app_source)], check=True)
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
        if "Contents/MacOS/OmarchyRecovery" not in actual:
            raise RecoveryError("native Recovery executable is missing")
    except (OSError, KeyError, TypeError, json.JSONDecodeError, plistlib.InvalidFileException) as error:
        raise RecoveryError("native Recovery payload is incomplete") from error
    return manifest


def target_config(installer, esp_uuid, esp_root, source_os=None, authorized_owner=None):
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
    bootstrap = None
    if source_os is not None:
        source = source_system_volume(installer.dutil, source_os)
        source_uuid = identifier(source.get("VolumeUUID"))
        source_group = identifier(source.get("APFSVolumeGroupID"))
        if source_group != identifier(source_os.vgid) or source_group == group:
            raise RecoveryError("bootstrap source volume identity changed")
        users = installer.dutil.get("apfs", "listUsers", source_uuid, "-plist")
        owners = {identifier(user.get("APFSCryptoUserUUID"))
                  for user in users.get("Users", []) if user.get("VolumeOwner") is True}
        if authorized_owner is None:
            authorized_owner = os.environ.get("OMARCHY_MACHINE_OWNER", "")
        if not isinstance(authorized_owner, str) or not re.fullmatch(r"[A-Za-z0-9._-]{1,255}", authorized_owner):
            raise RecoveryError("authorized bootstrap owner is unavailable")
        source_preboot = installer.dutil.get("info", "-plist", source_os.preboot)
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
        bootstrap = {"mode": "source-volume-owner", "sourceSystemUUID": source_uuid,
                     "sourceGroupUUID": source_group, "ownerUUIDs": [selected]}
    return {
        "schema": 2, "volumeName": name, "systemUUID": identifier(info.get("VolumeUUID")),
        "groupUUID": group, "prebootUUID": preboot_uuid, "espUUID": esp_uuid,
        "bootMode": "raw", "stage2Path": STAGE2_PATH, "bootstrap": bootstrap,
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


def _verify_staged_app(app, config, files, template, run):
    if app.is_symlink() or not app.is_dir():
        raise RecoveryError("unexpected existing Recovery app")
    for name, expected in template["files"].items():
        if name.startswith("Contents/_CodeSignature/"):
            continue
        path = app / name
        if path.is_symlink():
            raise RecoveryError("existing Recovery app contains a symbolic link")
        data = path.read_bytes()
        if expected != {"sha256": digest(data), "bytes": len(data)}:
            raise RecoveryError("existing Recovery application differs from its template")
    resources = app / "Contents/Resources"
    if json.loads((resources / "install-config.json").read_text()) != config:
        raise RecoveryError("existing Recovery app belongs to another installation")
    manifest = json.loads((resources / "AuraPayloads/manifest.json").read_text())
    expected = {name: {"sha256": digest(data), "bytes": len(data)} for name, data in files.items()}
    if manifest.get("files") != expected:
        raise RecoveryError("existing Recovery startup bundle differs from this operation")
    for name, data in files.items():
        target = resources / "AuraPayloads" / name
        if target.is_symlink() or target.read_bytes() != data:
            raise RecoveryError("existing Recovery payload is incomplete or changed")
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)


def _payload(path, maximum=256 << 20):
    path = Path(path)
    if path.is_symlink() or not path.is_file():
        raise RecoveryError("finalized startup payload is missing")
    size = path.stat().st_size
    if not 0 < size <= maximum:
        raise RecoveryError("finalized startup payload has an invalid size")
    return path.read_bytes()


def stage(installer, esp_uuid, esp_root, app_source=None,
          manifest_path=None, run=subprocess.run, source_os=None):
    """Called after OS/ESP installation and common stage-1 target patching.

    Preserve upstream's Finish Installation resource paths for resume checks;
    its step2.sh becomes a relative launcher for the native app. The GUI remains
    on the stub after successful enrollment disables .IAPhysicalMedia.
    """
    template_root = Path(esp_root) / PAYLOAD_DIRECTORY
    app_source = Path(app_source) if app_source is not None else template_root / APP_NAME
    manifest_path = Path(manifest_path) if manifest_path is not None else template_root / MANIFEST_NAME
    template = validate_source(app_source, manifest_path, run)
    config = target_config(installer, esp_uuid, esp_root, source_os)
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
        _verify_staged_app(destination, config, files, template, run)
        if not pending.exists():
            _atomic_bytes(pending, json.dumps(journal, sort_keys=True).encode())
    if not destination.exists():
        with tempfile.TemporaryDirectory(prefix=".omarchy-recovery-stage-", dir=system) as temporary:
            app = Path(temporary) / APP_NAME
            shutil.copytree(app_source, app)
            (app / "Contents/MacOS/OmarchyRecovery").chmod(0o755)
            resources = app / "Contents/Resources"
            _json(resources / "install-config.json", config)
            payloads = resources / "AuraPayloads"
            if payloads.exists():
                raise RecoveryError("Recovery template must not carry another installation's payloads")
            (payloads / "raw").mkdir(parents=True)
            (payloads / "vendorfw").mkdir()
            files = {"raw/aura-raw.bin": stage1, "raw/boot.bin": stage2, **firmware}
            for name, data in files.items():
                (payloads / name).parent.mkdir(parents=True, exist_ok=True)
                (payloads / name).write_bytes(data)
            _json(payloads / "manifest.json", {
                "schema": 2, "defaultMode": "raw", "nestedVirtualization": False,
                "modes": {"raw": {"espPath": STAGE2_PATH}},
                "vendorFirmware": sorted(firmware),
                "files": {name: {"sha256": digest(data), "bytes": len(data)} for name, data in files.items()},
            })
            run(["/usr/bin/codesign", "--force", "--sign", "-", str(app)], check=True)
            run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
            # Record the exact identity before publishing any of the three targets.
            # An interrupted run may finish only this same authenticated bundle.
            _atomic_bytes(pending, json.dumps(journal, sort_keys=True).encode())
            os.replace(app, destination)
    try:
        _verify_staged_app(destination, config, files, template, run)
        _atomic_bytes(legacy_step2, launcher.encode(), 0o755)
        _atomic_bytes(marker, plistlib.dumps(launch), journal["markerMode"])
    except Exception:
        # Keep the signed app and bound journal so the same operation can resume.
        _atomic_bytes(legacy_step2, base64.b64decode(journal["launcher"], validate=True), 0o755)
        _atomic_bytes(marker, base64.b64decode(journal["marker"], validate=True), journal["markerMode"])
        raise
    pending.unlink()
    return {"configuration": config, "stage1SHA256": digest(stage1), "stage2SHA256": digest(stage2)}
