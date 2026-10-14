# SPDX-License-Identifier: MIT
import io
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
import omarchy_recovery as recovery

# Recovery has a separate product identity; the pinned engine consumes its name.
identity = Path(__file__).resolve().parents[3] / "Packaging/identity.conf"
RECOVERY_DISPLAY_NAME = next(line.split('=', 1)[1].strip('"')
                             for line in identity.read_text().splitlines()
                             if line.startswith('INSTALLER_RECOVERY_APP_NAME='))

SYSTEM = "11111111-1111-4111-8111-111111111111"
GROUP = "22222222-2222-4222-8222-222222222222"
PREBOOT = "33333333-3333-4333-8333-333333333333"
ESP = "44444444-4444-4444-8444-444444444444"


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.system = self.root / "Omarchy Name With Spaces"
        self.esp = self.root / "ESP"
        self.system.mkdir()
        self.esp.mkdir()
        self.template = self.esp / recovery.PAYLOAD_DIRECTORY
        self.app = self.template / recovery.APP_NAME
        self.resources = self.app / "Contents/Resources"
        (self.resources / "en.lproj").mkdir(parents=True)
        (self.resources / "en.lproj/InfoPlist.strings").write_text(
            '"CFBundleDisplayName" = ' + json.dumps(RECOVERY_DISPLAY_NAME) + ';\n')
        self.info = self.app / "Contents/Info.plist"
        self.info.write_bytes(plistlib.dumps({
            "OmarchyRecoveryBuildMode": "recovery", "CFBundleExecutable": "OmarchyRecovery",
            "CFBundleDisplayName": RECOVERY_DISPLAY_NAME,
        }))
        self.binary = self.app / "Contents/MacOS/OmarchyRecovery"
        self.binary.parent.mkdir()
        self.binary.write_bytes(b"test-executable")
        self.binary.chmod(0o755)
        self.manifest = self.template / recovery.MANIFEST_NAME
        self.repin()
        legacy = self.system / "Finish Installation.app/Contents/Resources"
        legacy.mkdir(parents=True)
        self.boot = legacy / "boot.bin"
        self.boot.write_bytes(b"generated-stage1-with-unique-esp-uuid")
        self.step2 = legacy / "step2.sh"
        self.step2.write_text("old launcher")
        (self.esp / "m1n1").mkdir()
        (self.esp / recovery.STAGE2_PATH).write_bytes(b"actual-installed-stage2")
        (self.esp / "vendorfw").mkdir()
        for name in recovery.VENDOR_FIRMWARE:
            (self.esp / name).write_bytes(("device-specific " + name).encode())
        self.marker = self.system / ".IAPhysicalMedia"
        self.marker.write_bytes(plistlib.dumps({
            "AppName": "Finish Installation.app", "ProductVersion": "12.1",
            "ProductBuildVersion": "00A191",
        }))
        self.infos = {
            str(self.system): {"VolumeUUID": SYSTEM, "APFSVolumeGroupID": GROUP,
                              "MountPoint": str(self.system), "VolumeName": self.system.name},
            "/preboot": {"VolumeUUID": PREBOOT},
            str(self.esp): {"DiskUUID": ESP, "Content": "EFI", "MountPoint": str(self.esp)},
        }
        self.installer = SimpleNamespace(
            osi=SimpleNamespace(system=str(self.system), vgid=GROUP, preboot="/preboot", preboot_vgid=PREBOOT),
            dutil=SimpleNamespace(get=lambda *args: self.infos[args[-1]]),
            boot_obj_path=str(self.boot), step2_sh=str(self.step2), iapm_path=str(self.marker),
        )
        self.commands = []

    def repin(self):
        self.manifest.write_text(json.dumps(recovery.app_inventory(self.app)))

    def fake_run(self, command, **kwargs):
        self.commands.append(command)
        self.assertTrue(kwargs["check"])
        return SimpleNamespace(returncode=0)

    def stage(self):
        return recovery.stage(self.installer, ESP, str(self.esp), run=self.fake_run)

    def package(self):
        data = io.BytesIO()
        with zipfile.ZipFile(data, "w") as package:
            for path in self.template.rglob("*"):
                if path.is_file():
                    package.write(path, "esp/" + path.relative_to(self.esp).as_posix())
        data.seek(0)
        return zipfile.ZipFile(data)

    def test_payload_preflight_valid_and_missing_template_rejected(self):
        with self.package() as package:
            self.assertEqual(recovery.validate_payload(package)["buildMode"], "recovery")
        with zipfile.ZipFile(io.BytesIO(), "w") as empty:
            with self.assertRaises(recovery.RecoveryError):
                recovery.validate_payload(empty)

    def test_payload_checksum_changed(self):
        self.binary.write_bytes(b"changed")
        with self.package() as package, self.assertRaisesRegex(recovery.RecoveryError, "checksum"):
            recovery.validate_payload(package)

    def test_stage_config_and_actual_payloads_not_fixed_fixture(self):
        result = self.stage()
        app = self.system / recovery.APP_NAME
        config = json.loads((app / "Contents/Resources/install-config.json").read_text())
        self.assertEqual(config, result["configuration"])
        self.assertEqual(config["systemUUID"], SYSTEM)
        self.assertEqual(config["espUUID"], ESP)
        self.assertEqual(config["volumeName"], self.system.name)
        payloads = app / "Contents/Resources/AuraPayloads"
        self.assertEqual((payloads / "raw/aura-raw.bin").read_bytes(), self.boot.read_bytes())
        self.assertEqual((payloads / "raw/boot.bin").read_bytes(), b"actual-installed-stage2")
        manifest = json.loads((payloads / "manifest.json").read_text())
        self.assertEqual(set(manifest["modes"]), {"raw"})
        self.assertFalse(manifest["nestedVirtualization"])
        self.assertEqual(set(manifest["vendorFirmware"]), set(recovery.VENDOR_FIRMWARE))
        for name in recovery.VENDOR_FIRMWARE:
            self.assertEqual((payloads / name).read_bytes(), (self.esp / name).read_bytes())
            self.assertEqual(manifest["files"][name]["sha256"], recovery.digest((self.esp / name).read_bytes()))
        marker = plistlib.loads(self.marker.read_bytes())
        self.assertEqual(marker["AppName"], recovery.APP_NAME)
        self.assertEqual(marker["ProductBuildVersion"], "00A191")
        self.assertIn("../../../" + RECOVERY_DISPLAY_NAME + ".app/Contents/MacOS/OmarchyRecovery", self.step2.read_text())
        self.assertTrue(self.boot.is_file())
        self.assertEqual(len(self.commands), 3)
        self.assertEqual(self.commands[1][1:4], ["--force", "--sign", "-"])

    def test_second_install_never_overwrites_existing_recovery_app(self):
        self.stage()
        with self.assertRaisesRegex(recovery.RecoveryError, "already exists"):
            self.stage()

    def test_wrong_target_esp_stops_before_any_mutation(self):
        before = self.marker.read_bytes()
        self.infos[str(self.esp)]["DiskUUID"] = SYSTEM
        with self.assertRaisesRegex(recovery.RecoveryError, "identities changed"):
            self.stage()
        self.assertEqual(self.marker.read_bytes(), before)
        self.assertFalse((self.system / recovery.APP_NAME).exists())

    def test_preview_or_tampered_source_rejected(self):
        self.binary.write_bytes(b"tampered")
        with self.assertRaisesRegex(recovery.RecoveryError, "differs"):
            self.stage()
        info = plistlib.loads(self.info.read_bytes())
        info["OmarchyRecoveryBuildMode"] = "preview"
        self.info.write_bytes(plistlib.dumps(info))
        self.repin()
        with self.assertRaisesRegex(recovery.RecoveryError, "real enrollment"):
            self.stage()

    def test_missing_finalized_stage2_does_not_publish_app(self):
        (self.esp / recovery.STAGE2_PATH).unlink()
        with self.assertRaisesRegex(recovery.RecoveryError, "missing"):
            self.stage()
        self.assertFalse((self.system / recovery.APP_NAME).exists())

    def test_final_sign_failure_keeps_original_launcher_and_marker(self):
        marker = self.marker.read_bytes()

        def fail(command, **kwargs):
            if "--force" in command:
                raise subprocess.CalledProcessError(1, command)

        with self.assertRaises(subprocess.CalledProcessError):
            recovery.stage(self.installer, ESP, str(self.esp), run=fail)
        self.assertFalse((self.system / recovery.APP_NAME).exists())
        self.assertEqual(self.marker.read_bytes(), marker)
        self.assertEqual(self.step2.read_text(), "old launcher")

    def test_source_symlink_rejected(self):
        (self.resources / "link").symlink_to(self.info)
        with self.assertRaisesRegex(recovery.RecoveryError, "non-regular"):
            recovery.app_inventory(self.app)

    def test_required_firmware_missing_empty_or_oversized_is_rejected(self):
        for name in recovery.VENDOR_FIRMWARE:
            path = self.esp / name
            original = path.read_bytes()
            for missing in (False, True):
                if missing:
                    path.unlink()
                else:
                    path.write_bytes(b"")
                with self.subTest(name=name, missing=missing), self.assertRaises(recovery.RecoveryError):
                    self.stage()
                self.assertFalse((self.system / recovery.APP_NAME).exists())
                path.write_bytes(original)
        path = self.esp / "vendorfw/manifest.txt"
        with path.open("wb") as stream:
            stream.truncate((1 << 20) + 1)
        with self.assertRaises(recovery.RecoveryError):
            self.stage()

    def test_optional_uboot_firmware_is_preserved_only_when_present(self):
        name = recovery.OPTIONAL_VENDOR_FIRMWARE
        path = self.esp / name
        path.parent.mkdir(parents=True)
        path.write_bytes(b"this-unit-usb-controller-firmware")
        (self.esp / "vendorfw/unrelated.bin").write_bytes(b"do not include")
        self.stage()
        root = self.system / recovery.APP_NAME / "Contents/Resources/AuraPayloads"
        manifest = json.loads((root / "manifest.json").read_text())
        self.assertIn(name, manifest["vendorFirmware"])
        self.assertEqual((root / name).read_bytes(), path.read_bytes())
        self.assertNotIn("vendorfw/unrelated.bin", manifest["files"])

    def test_required_firmware_symlink_is_not_copied(self):
        path = self.esp / "vendorfw/firmware.tar"
        path.unlink()
        path.symlink_to(self.boot)
        with self.assertRaises(recovery.RecoveryError):
            self.stage()

    def test_bootstrap_is_bound_to_live_source_volume_and_owners(self):
        source_uuid = "55555555-5555-4555-8555-555555555555"
        source_group = "66666666-6666-4666-8666-666666666666"
        owner_uuid = "77777777-7777-4777-8777-777777777777"
        other_owner = "99999999-9999-4999-8999-999999999999"
        preboot_uuid = "88888888-8888-4888-8888-888888888888"
        preboot = self.root / "source-preboot"
        admin_path = preboot / source_group / "var/db/AdminUserRecoveryInfo.plist"
        admin_path.parent.mkdir(parents=True)
        admin_path.write_bytes(plistlib.dumps({
            "source-user": {"GeneratedUID": owner_uuid},
            "other-user": {"GeneratedUID": other_owner},
            "not-owner": {"GeneratedUID": SYSTEM},
        }))
        source_os = SimpleNamespace(sys_volume="source-system", vgid=source_group,
                                    preboot=str(preboot), preboot_vgid=preboot_uuid)

        def get(*args):
            if args == ("apfs", "list", "-plist"):
                return {"Containers": [{"Volumes": [{"APFSVolumeUUID": source_uuid,
                                                       "Roles": ["System"]}]}]}
            if args[0] == "apfs":
                self.assertEqual(args, ("apfs", "listUsers", source_uuid, "-plist"))
                return {"Users": [{"APFSCryptoUserUUID": value, "VolumeOwner": True}
                                  for value in (owner_uuid, other_owner)]}
            if args[-1] in ("source-system", source_uuid):
                return {"VolumeUUID": source_uuid, "APFSVolumeGroupID": source_group}
            if args[-1] == str(preboot):
                return {"VolumeUUID": preboot_uuid}
            return self.infos[args[-1]]

        self.installer.dutil.get = get
        config = recovery.target_config(self.installer, ESP, str(self.esp), source_os, "source-user")
        self.assertEqual(config["bootstrap"], {
            "mode": "source-volume-owner", "sourceSystemUUID": source_uuid,
            "sourceGroupUUID": source_group, "ownerUUIDs": [owner_uuid],
        })
        for missing in ("", "unlisted", "not-owner"):
            with self.subTest(owner=missing), self.assertRaises(recovery.RecoveryError):
                recovery.target_config(self.installer, ESP, str(self.esp), source_os, missing)
        other = recovery.target_config(self.installer, ESP, str(self.esp), source_os, "other-user")
        self.assertEqual(other["bootstrap"]["ownerUUIDs"], [other_owner])
        source_os.vgid = SYSTEM
        with self.assertRaisesRegex(recovery.RecoveryError, "source volume identity changed"):
            recovery.target_config(self.installer, ESP, str(self.esp), source_os, "source-user")


class SourceSystemTests(unittest.TestCase):
    def setUp(self):
        self.system = "11111111-1111-4111-8111-111111111111"
        self.snapshot = "22222222-2222-4222-8222-222222222222"
        self.group = "33333333-3333-4333-8333-333333333333"
        self.observed_group = self.group
        self.volumes = [{"APFSVolumeUUID": self.system, "Roles": ["System"]}]
        self.info = {"VolumeUUID": self.system, "APFSVolumeGroupID": self.group}
        self.calls = []

    def get(self, *args):
        self.calls.append(args)
        if args == ("apfs", "list", "-plist"):
            return {"Containers": [{"Volumes": self.volumes}]}
        if args == ("info", "-plist", "/"):
            return {"VolumeUUID": self.snapshot, "APFSSnapshotUUID": self.snapshot,
                    "APFSVolumeGroupID": self.observed_group}
        if args == ("info", "-plist", self.system):
            return self.info
        raise AssertionError(args)

    def resolve(self):
        return recovery.source_system_volume(
            SimpleNamespace(get=self.get), SimpleNamespace(sys_volume="/", vgid=self.group))

    def test_boot_snapshot_resolves_to_underlying_system_volume(self):
        self.assertEqual(self.resolve()["VolumeUUID"], self.system)
        self.assertNotIn(("info", "-plist", self.snapshot), self.calls)

    def test_data_role_is_not_a_system_volume(self):
        self.volumes[0]["Roles"] = ["Data"]
        with self.assertRaisesRegex(recovery.RecoveryError, "missing or ambiguous"):
            self.resolve()

    def test_ambiguous_system_volumes_are_rejected(self):
        self.volumes *= 2
        with self.assertRaisesRegex(recovery.RecoveryError, "missing or ambiguous"):
            self.resolve()

    def test_source_group_change_is_rejected(self):
        self.observed_group = self.system
        with self.assertRaisesRegex(recovery.RecoveryError, "identity changed"):
            self.resolve()

    def test_enumerated_volume_identity_change_is_rejected(self):
        self.info["VolumeUUID"] = self.snapshot
        with self.assertRaisesRegex(recovery.RecoveryError, "identity changed"):
            self.resolve()


if __name__ == "__main__":
    unittest.main()
