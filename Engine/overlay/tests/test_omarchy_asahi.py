# SPDX-License-Identifier: MIT
import io
from contextlib import contextmanager
import hashlib
import json
import os
import plistlib
from pathlib import Path
from types import SimpleNamespace
import sys
import subprocess
import tempfile
import re
import shutil
import time
import subprocess
import unittest
from unittest.mock import patch
import zipfile


class FakeOSInstaller:
    def __init__(self, dutil, data, template):
        self.min_recommended_size = template.get("minimum_size", 64 * GIB)
        self.min_size = template.get("floor_size", self.min_recommended_size)
        self.name = template.get("default_os_name", "Omarchy")
        self.needs_firmware = False
        self.idata_targets = []
        self.efi_part = SimpleNamespace(uuid="ABCDEF")
        self.calls = []
        self.template = template

    def partition_disk(self, name, size):
        self.calls.append(("partition_disk", name, size))
        self.part_info = [
            SimpleNamespace(name="disk0s5", uuid="EFI-UUID", size=500 * 1024**2),
            SimpleNamespace(name="disk0s6", uuid="BOOT-UUID", size=2 * GIB),
            SimpleNamespace(name="disk0s7", uuid="ROOT-UUID", size=32 * GIB),
        ]
        self.efi_part = self.part_info[0]

    def install(self, installer):
        self.calls.append(("install", installer))
        icon = self.template.get("icon")
        if icon:
            Path(installer.icon_path).write_bytes(self.pkg.read(icon))
        for partition, info in zip(self.template["partitions"], self.part_info):
            if partition.get("image"):
                self.install_raw_image(partition["image"], info)


class FakeStubInstaller:
    def __init__(self, sysinfo, dutil, osinfo):
        self.calls = []
        self.recovery = tempfile.TemporaryDirectory()
        self.osi = SimpleNamespace(
            vgid="11111111-2222-3333-4444-555555555555",
            sys_volume="System",
            recovery=self.recovery.name,
            preboot_vgid="66666666-7777-8888-9999-AAAAAAAAAAAA",
        )
        # Where the real stub writes the Recovery setup that Omarchy replaces.
        self.step2_sh = os.path.join(self.recovery.name, "step2.sh")
        self.icon_path = dutil.stub_icon_path
        self.boot_obj_path = os.path.join(self.recovery.name, "boot.bin")

    def load_ipsw(self, ipsw):
        self.calls.append(("load_ipsw", ipsw))

    def load_identity(self):
        self.bootcaches = {"bless2": {}}

    def collect_firmware(self, pkg):
        self.calls.append(("collect_firmware", pkg))

    def prepare_volume(self, part):
        self.calls.append(("prepare_volume", part.name))

    def check_volume(self, part=None):
        if part is not None:
            self.calls.append(("check_volume", part.name))
            return
        self.calls.append(("check_volume",))

    def install_files(self, current_os):
        self.calls.append(("install_files", current_os))
        # As the real stub does, with the plain image older firmware ships.
        image = Path(self.osi.recovery, self.osi.vgid, "usr/standalone/firmware/arm64eBaseSystem.dmg")
        image.parent.mkdir(parents=True, exist_ok=True)
        image.write_bytes(b"plain recovery image")

    def prepare_for_bless(self):
        self.calls.append(("prepare_for_bless",))

    def prepare_for_step2(self):
        self.calls.append(("prepare_for_step2",))


sys.modules["asahi_firmware"] = SimpleNamespace(
    core=SimpleNamespace(FWPackage=object),
)
sys.modules["osinstall"] = SimpleNamespace(OSInstaller=FakeOSInstaller, psize=lambda value: int(value[:-2]) * 1024**3 if value.endswith("GB") else int(value[:-1]))
sys.modules["stub"] = SimpleNamespace(StubInstaller=FakeStubInstaller)
sys.modules.setdefault(
    "util",
    SimpleNamespace(align_down=lambda value, align: value - value % align),
)
sys.path.insert(
    0,
    str(Path(__file__).resolve().parents[1] / "src"),
)

import omarchy_apple_aea  # noqa: E402
from omarchy_asahi import (  # noqa: E402
    _collect_neo_radios,
    _collect_neo_touch_id,
    STEP2_SCRIPT,
    AsahiAdapterError,
    AsahiInPlaceRepairAdapter,
    AsahiStage1Adapter,
    OmarchyOSInstaller,
    esp_board_layout,
    fill_aurora_stage1,
    install_board_stage1,
    install_esp_board_layout,
    stub_installer,
    verify_default_boot,
)


GIB = 1024**3


class DefaultBootVerificationTests(unittest.TestCase):
    group = "11111111-2222-3333-4444-555555555555"

    def verify(self, selected_group, output=None):
        payload = plistlib.dumps({"Boot Volume": "/dev/disk8s1"}) if output is None else output
        dutil = SimpleNamespace(get=lambda *args: {"APFSVolumeGroupID": selected_group})
        with patch("omarchy_asahi.subprocess.run", return_value=SimpleNamespace(stdout=payload)):
            verify_default_boot(dutil, self.group)

    def test_selected_group_is_verified(self):
        self.verify(self.group)

    def test_successful_command_with_other_group_is_rejected(self):
        with self.assertRaisesRegex(AsahiAdapterError, "not confirmed"):
            self.verify("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")

    def test_missing_or_malformed_selection_is_rejected(self):
        for output in (b"not a plist", plistlib.dumps({})):
            with self.subTest(output=output), self.assertRaisesRegex(AsahiAdapterError, "not confirmed"):
                self.verify(self.group, output)


class ESPTreeExtractionTests(unittest.TestCase):
    def test_tree_without_directory_entries_or_with_late_directories(self):
        for explicit_directories in (False, True):
            with self.subTest(explicit_directories=explicit_directories):
                with tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    payload = root / "payload.zip"
                    files = {
                        "esp/EFI/BOOT/BOOTAA64.EFI": b"limine",
                        "esp/aurora/recovery/Omarchy Installer.app/Contents/MacOS/OmarchyRecovery": b"app",
                        "esp/m1n1/boot.bin": b"stage2",
                    }
                    with zipfile.ZipFile(payload, "w") as archive:
                        for name, data in files.items():
                            archive.writestr(name, data)
                        if explicit_directories:
                            archive.writestr("esp/EFI/BOOT/", b"")
                    with zipfile.ZipFile(payload) as archive:
                        installer = OmarchyOSInstaller(None, {}, {})
                        installer.pkg = archive
                        installer.path = lambda name: name

                        # Exercise the inherited extractor's file-writing
                        # contract: it opens files without creating parents.
                        def inherited_extract(instance, source, destination):
                            for name, data in files.items():
                                target = Path(destination) / name.removeprefix(source + "/")
                                with target.open("wb") as output:
                                    output.write(instance.pkg.read(name))

                        with patch.object(FakeOSInstaller, "extract_tree", inherited_extract, create=True):
                            installer.extract_tree("esp", root / "fresh-esp")
                    for name, data in files.items():
                        target = root / "fresh-esp" / name.removeprefix("esp/")
                        self.assertEqual(target.read_bytes(), data)


class AsahiStage1AdapterTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.metadata = self.root / "installer_data.json"
        self.payload = self.root / "payload.zip"
        self._write_metadata()
        with zipfile.ZipFile(self.payload, "w") as archive:
            archive.writestr("omarchy-volume.icns", b"omarchy-icon")
            archive.writestr("esp/m1n1/boot.bin", "m1n1")
            archive.writestr("esp/EFI/BOOT/BOOTAA64.EFI", "grub")
            archive.writestr("boot.img", b"b" * 4096)
            archive.writestr("root.img", b"r" * 4096)
        self.installed_esp = self.root / "installed-esp"
        self.installed_stub_icon = self.root / ".VolumeIcon.icns"
        (self.installed_esp / "m1n1").mkdir(parents=True)
        (self.installed_esp / "m1n1/boot.bin").write_bytes(b"m1n1")
        (self.installed_esp / "EFI/BOOT").mkdir(parents=True)
        (self.installed_esp / "EFI/BOOT/BOOTAA64.EFI").write_bytes(b"grub")
        self.raw_images = {
            "disk0s6": b"b" * 4096,
            "disk0s7": b"r" * 4096,
        }
        self.free = FakePart(
            "disk0s3",
            offset=400 * GIB,
            size=100 * GIB,
            free=True,
            part_type="Free space",
        )
        self.plan = SimpleNamespace(
            plan_digest="a" * 64,
            candidate_kind="free",
            source_identifier="disk0s3",
            offset_bytes=self.free.offset,
            length_bytes=80 * GIB,
            minimum_container_bytes=0,
        )

    def tearDown(self):
        self.temporary.cleanup()

    def test_preflight_accepts_the_partition_floor(self):
        metadata = self._target_metadata()
        metadata["floor_size"] = 40 * GIB
        metadata["minimum_size"] = 64 * GIB
        self._write_metadata([metadata])
        self.plan.length_bytes = 50 * GIB
        adapter = self._adapter(FakeInstaller(FakeDiskUtil([[self.free]])))

        adapter.preflight(self.plan)

        self.assertTrue(adapter.preflight_complete)

    def test_native_recovery_contract_requires_app_before_disk_changes(self):
        metadata = self._target_metadata()
        metadata["recovery_gui"] = "omarchy-native-v1"
        self._write_metadata([metadata])
        dutil = FakeDiskUtil([[self.free]])
        adapter = self._adapter(FakeInstaller(dutil))
        with self.assertRaisesRegex(AsahiAdapterError, "Recovery payload is incomplete"):
            adapter.preflight(self.plan)
        self.assertFalse(adapter.preflight_complete)
        self.assertEqual(dutil.add_calls, [])

    def test_unknown_recovery_contract_is_not_silently_ignored(self):
        metadata = self._target_metadata()
        metadata["recovery_gui"] = "not-a-real-build"
        self._write_metadata([metadata])
        adapter = self._adapter(FakeInstaller(FakeDiskUtil([[self.free]])))
        with self.assertRaisesRegex(AsahiAdapterError, "unknown Recovery GUI contract"):
            adapter.preflight(self.plan)

    def test_preflight_rejects_an_extent_below_the_partition_floor(self):
        metadata = self._target_metadata()
        metadata["floor_size"] = 40 * GIB
        self._write_metadata([metadata])
        self.plan.length_bytes = 30 * GIB
        adapter = self._adapter(FakeInstaller(FakeDiskUtil([[self.free]])))

        with self.assertRaisesRegex(
            AsahiAdapterError,
            "smaller than Asahi minimum",
        ):
            adapter.preflight(self.plan)

    def _on_26_6_2(self):
        installer = FakeInstaller(FakeDiskUtil([[self.free]]))
        installer.ipsw = SimpleNamespace(version="26.6.2")
        return installer

    def test_a_26_6_2_air_payload_without_the_j613_stage1_is_refused_before_disk_changes(self):
        installer = self._on_26_6_2()
        adapter = self._adapter(installer)

        with self.assertRaisesRegex(AsahiAdapterError, "stage1-j613.bin"):
            adapter.preflight(self.plan)

        self.assertFalse(adapter.preflight_complete)
        self.assertEqual(installer.dutil.add_calls, [])

    def test_a_26_6_2_air_boots_through_the_filled_j613_stage1(self):
        with zipfile.ZipFile(self.payload, "a") as archive:
            archive.writestr("esp/aurora/stage1-j613.bin", j700_stage1())
        (self.installed_esp / "aurora").mkdir()
        (self.installed_esp / "aurora/stage1-j613.bin").write_bytes(j700_stage1())
        installer = self._on_26_6_2()
        adapter = self._adapter(installer)

        adapter.preflight(self.plan)
        adapter.prepare_target(self.plan)
        partition_disk = adapter.osins.partition_disk
        def with_a_real_esp_uuid(name, size):
            partition_disk(name, size)
            adapter.osins.efi_part.uuid = "180190F8-0000-4000-8000-000000000000"
        adapter.osins.partition_disk = with_a_real_esp_uuid
        adapter.install_stub_and_esp(self.plan)

        boot_object = Path(installer.ins.boot_obj_path).read_bytes()
        self.assertTrue(boot_object.startswith(b"m1n1 j700 stage 1"))
        self.assertIn(b"180190f8-0000-4000-8000-000000000000", boot_object)
        self.assertIn(b";m1n1/boot.bin", boot_object)

    def _common_payload(self, stage1=None, stage2=b"common stage2"):
        with zipfile.ZipFile(self.payload) as archive:
            entries = {name: archive.read(name) for name in archive.namelist()}
        entries["esp/aurora/stage1.bin"] = j700_stage1(window=5000) if stage1 is None else stage1
        entries["esp/m1n1/boot.bin"] = stage2
        with zipfile.ZipFile(self.payload, "w") as archive:
            for name, data in entries.items():
                archive.writestr(name, data)

    def test_generic_image_preflights_neo_without_legacy_board_payloads(self):
        self._common_payload()
        metadata = self._target_metadata()
        metadata["aurora_stage1"] = {
            "kind": "common-raw-v1",
            "qualified_machines": {"j700ap": ["14.8.3"]},
        }
        self._write_metadata([metadata])
        installer = FakeInstaller(FakeDiskUtil([[self.free]]))
        installer.sysinfo.device_class = "j700ap"
        adapter = self._adapter(installer)
        adapter.preflight(self.plan)
        self.assertTrue(adapter.preflight_complete)
        self.assertEqual(installer.dutil.add_calls, [])

    def test_generic_image_requires_explicit_board_and_firmware_qualification(self):
        self._common_payload()
        for contract in (None, {"kind": "common-raw-v1", "qualified_machines": {
            "j700ap": ["26.6.2"]}}):
            metadata = self._target_metadata()
            if contract is not None:
                metadata["aurora_stage1"] = contract
            self._write_metadata([metadata])
            installer = FakeInstaller(FakeDiskUtil([[self.free]]))
            installer.sysinfo.device_class = "j700ap"
            adapter = self._adapter(installer)
            with self.assertRaises(AsahiAdapterError):
                adapter.preflight(self.plan)
            self.assertEqual(installer.dutil.add_calls, [])

    def test_generic_image_rejects_invalid_boot_objects_before_disk_changes(self):
        for stage1, stage2 in ((b"invalid", b"stage2"), (j700_stage1(), b"")):
            with self.subTest(stage1=stage1[:10], stage2=stage2):
                self._common_payload(stage1, stage2)
                installer = FakeInstaller(FakeDiskUtil([[self.free]]))
                installer.sysinfo.device_class = "j700ap"
                adapter = self._adapter(installer)
                with self.assertRaises(AsahiAdapterError):
                    adapter.preflight(self.plan)
                self.assertFalse(adapter.preflight_complete)
                self.assertEqual(installer.dutil.add_calls, [])

    def _neo_payload(self, stage2=b"m1n1 neo"):
        with zipfile.ZipFile(self.payload, "a") as archive:
            archive.writestr("esp/aurora/stage1-j700.bin", j700_stage1())
            if stage2 is not None:
                archive.writestr("esp/m1n1/boot-j700.bin", stage2)
        # As extract_tree leaves the ESP: every payload member under its own name.
        (self.installed_esp / "aurora").mkdir()
        (self.installed_esp / "aurora/stage1-j700.bin").write_bytes(j700_stage1())
        if stage2 is not None:
            (self.installed_esp / "m1n1/boot-j700.bin").write_bytes(stage2)

    def _install_on(self, device_class):
        installer = FakeInstaller(FakeDiskUtil([[self.free]]))
        installer.sysinfo.device_class = device_class
        adapter = self._adapter(installer)
        adapter.preflight(self.plan)
        target = adapter.prepare_target(self.plan)
        partition_disk = adapter.osins.partition_disk
        def with_a_real_esp_uuid(name, size):
            partition_disk(name, size)
            adapter.osins.efi_part.uuid = "180190F8-0000-4000-8000-000000000000"
        adapter.osins.partition_disk = with_a_real_esp_uuid
        return target, adapter.install_stub_and_esp(self.plan)

    def _retry_on(self, device_class, target, evidence):
        retry = self._retry_adapter(target, evidence)
        retry.installer.sysinfo.device_class = device_class
        retry.preflight(self.plan)
        return retry

    def test_a_neo_payload_without_its_stage2_is_refused_before_disk_changes(self):
        self._neo_payload(stage2=None)
        installer = FakeInstaller(FakeDiskUtil([[self.free]]))
        installer.sysinfo.device_class = "j700ap"
        adapter = self._adapter(installer)

        with self.assertRaisesRegex(AsahiAdapterError, "no esp/m1n1/boot-j700.bin for the MacBook Neo"):
            adapter.preflight(self.plan)

        self.assertFalse(adapter.preflight_complete)
        self.assertEqual(installer.dutil.add_calls, [])
        self.assertEqual(installer.dutil.resize_calls, [])

    def test_a_neo_payload_with_an_empty_stage2_is_refused_before_disk_changes(self):
        self._neo_payload(stage2=b"")
        installer = FakeInstaller(FakeDiskUtil([[self.free]]))
        installer.sysinfo.device_class = "j700ap"
        adapter = self._adapter(installer)

        with self.assertRaisesRegex(AsahiAdapterError, "empty esp/m1n1/boot-j700.bin"):
            adapter.preflight(self.plan)

        self.assertEqual(installer.dutil.add_calls, [])

    def test_a_neo_boots_its_own_stage2_as_m1n1_boot_bin(self):
        self._neo_payload()

        target, evidence = self._install_on("j700ap")

        self.assertEqual((self.installed_esp / "m1n1/boot.bin").read_bytes(), b"m1n1 neo")
        self.assertFalse((self.installed_esp / "m1n1/boot-j700.bin").exists())
        retry = self._retry_on("j700ap", target, evidence)
        retry.validate_installed_checkpoint(self.plan, target, evidence)

    def test_the_neo_esp_recheck_rejects_the_generic_stage2(self):
        self._neo_payload()
        target, evidence = self._install_on("j700ap")
        # Same size as the Neo's, so only the content comparison can tell.
        (self.installed_esp / "m1n1/boot.bin").write_bytes(b"m1n1 m13")

        retry = self._retry_on("j700ap", target, evidence)
        with self.assertRaisesRegex(AsahiAdapterError, "differs from payload"):
            retry.validate_installed_checkpoint(self.plan, target, evidence)

    def test_the_neo_esp_recheck_rejects_a_leftover_neo_stage2(self):
        self._neo_payload()
        target, evidence = self._install_on("j700ap")
        (self.installed_esp / "m1n1/boot-j700.bin").write_bytes(b"m1n1 neo")

        retry = self._retry_on("j700ap", target, evidence)
        with self.assertRaisesRegex(AsahiAdapterError, "dropped member"):
            retry.validate_installed_checkpoint(self.plan, target, evidence)

    def test_other_macs_drop_the_neo_stage2_from_the_esp(self):
        self._neo_payload()

        target, evidence = self._install_on("j613ap")

        self.assertEqual((self.installed_esp / "m1n1/boot.bin").read_bytes(), b"m1n1")
        self.assertFalse((self.installed_esp / "m1n1/boot-j700.bin").exists())
        retry = self._retry_on("j613ap", target, evidence)
        retry.validate_installed_checkpoint(self.plan, target, evidence)
        (self.installed_esp / "m1n1/boot-j700.bin").write_bytes(b"m1n1 neo")
        with self.assertRaisesRegex(AsahiAdapterError, "dropped member"):
            retry.validate_installed_checkpoint(self.plan, target, evidence)

    def test_a_payload_without_the_neo_stage2_installs_unchanged_on_other_macs(self):
        for device_class in ("j613ap", "j314s"):
            with self.subTest(device_class=device_class):
                target, evidence = self._install_on(device_class)

                self.assertEqual(
                    sorted(str(path.relative_to(self.installed_esp))
                           for path in self.installed_esp.rglob("*") if path.is_file()),
                    ["EFI/BOOT/BOOTAA64.EFI", "m1n1/boot.bin"],
                )
                self.assertEqual(json.loads(evidence)["populated_partitions"][0]["installed_bytes"], 8)

    def test_free_extent_runs_exact_upstream_stage_one_primitives(self):
        dutil = FakeDiskUtil([[self.free]])
        dutil.get = lambda *args: {"APFSVolumeGroupID": "11111111-2222-3333-4444-555555555555"}
        installer = FakeInstaller(dutil)
        adapter = self._adapter(installer)

        adapter.preflight(self.plan)
        target_evidence = json.loads(adapter.prepare_target(self.plan))
        installed_evidence = json.loads(
            adapter.install_stub_and_esp(self.plan)
        )
        with patch.dict(
            os.environ,
            {"OMARCHY_MACHINE_OWNER": "mina"},
        ), patch(
            "omarchy_asahi.sys.stdin",
            SimpleNamespace(buffer=io.BytesIO(b"owner-password\n")),
        ), patch(
            "omarchy_asahi.subprocess.run",
        ) as run:
            run.return_value.stdout = plistlib.dumps({"Boot Volume": "/dev/disk0s4"})
            recovery_evidence = json.loads(
                adapter.prepare_recovery_handoff(self.plan)
            )

        self.assertEqual(installer.chosen_firmware, None)
        self.assertEqual(
            installer.ins.calls[0],
            ("load_ipsw", installer.ipsw),
        )
        self.assertEqual(
            dutil.add_calls,
            [("disk0s3", "apfs", "Omarchy", 2 * GIB)],
        )
        self.assertEqual(
            target_evidence["partition_identifier"],
            "disk0s4",
        )
        self.assertEqual(installed_evidence["apfs_vgid"], "11111111-2222-3333-4444-555555555555")
        self.assertEqual(installed_evidence["efi_partition"], "efi-uuid")
        self.assertEqual(
            installed_evidence["startup_volume_icon"],
            {
                "content_sha256": hashlib.sha256(b"omarchy-icon").hexdigest(),
                "installed_bytes": 12,
                "member": "omarchy-volume.icns",
                "verification": "stub-file-sha256",
            },
        )
        self.assertEqual(
            [item["partition_identifier"] for item in installed_evidence["populated_partitions"]],
            ["disk0s5", "disk0s6", "disk0s7"],
        )
        self.assertEqual(
            [item["installed_bytes"] for item in installed_evidence["populated_partitions"]],
            [8, 4096, 4096],
        )
        self.assertEqual(
            [item["verification"] for item in installed_evidence["populated_partitions"]],
            ["copied-tree-sha256", "raw-prefix-sha256", "source-sha256-write-flushed-v1"],
        )
        self.assertEqual(
            installed_evidence["populated_partitions"][1]["content_sha256"],
            hashlib.sha256(b"b" * 4096).hexdigest(),
        )
        self.assertEqual(
            recovery_evidence["outcome"],
            "awaiting_recovery",
        )
        self.assertLess(
            installer.ins.calls.index(("prepare_for_bless",)),
            installer.ins.calls.index(("prepare_for_step2",)),
        )
        run.assert_any_call(
            [
                "/usr/sbin/bless",
                "--setBoot",
                "--device",
                "/dev/System",
                "--user",
                "mina",
                "--stdinpass",
            ],
            input=b"owner-password\n",
            check=True,
            stdout=-3,
            stderr=-3,
        )
        self.assertEqual(run.call_count, 2)
        self.assertEqual(run.call_args.args[0], ["/usr/sbin/bless", "--getBoot", "--plist"])

    def test_recovery_handoff_rejects_missing_owner_before_bless(self):
        adapter = self._adapter(FakeInstaller(FakeDiskUtil([[self.free]])))
        adapter.preflight(self.plan)

        with patch.dict(os.environ, {}, clear=True), patch(
            "omarchy_asahi.subprocess.run",
        ) as run:
            with self.assertRaisesRegex(
                AsahiAdapterError,
                "machine owner is unavailable",
            ):
                adapter.prepare_recovery_handoff(self.plan)

        run.assert_not_called()

    def test_resize_uses_only_approved_container_and_minimum(self):
        source = FakePart(
            "disk0s2",
            offset=1 * GIB,
            size=500 * GIB,
            free=False,
        )
        resized_free = FakePart(
            "disk0s3",
            offset=421 * GIB,
            size=80 * GIB,
            free=True,
            part_type="Free space",
        )
        plan = SimpleNamespace(
            **{
                **self.plan.__dict__,
                "candidate_kind": "resize",
                "source_identifier": "disk0s2",
                "offset_bytes": resized_free.offset,
                "minimum_container_bytes": 320 * GIB,
            }
        )
        dutil = FakeDiskUtil([[source], [resized_free]])
        adapter = self._adapter(FakeInstaller(dutil))

        adapter.preflight(plan)
        adapter.prepare_target(plan)

        self.assertEqual(
            dutil.resize_calls,
            [("disk0s2", 420 * GIB)],
        )
        self.assertEqual(dutil.add_calls[0][0], "disk0s3")

    def test_changed_free_extent_is_rejected_before_partition_creation(self):
        changed = FakePart(
            "disk0s3",
            offset=self.free.offset + GIB,
            size=self.free.size,
            free=True,
            part_type="Free space",
        )
        dutil = FakeDiskUtil([[changed]])
        adapter = self._adapter(FakeInstaller(dutil))
        adapter.preflight(self.plan)

        with self.assertRaisesRegex(
            AsahiAdapterError,
            "approved free extent changed",
        ):
            adapter.prepare_target(self.plan)

        self.assertEqual(dutil.add_calls, [])

    def test_retry_reconciles_the_exact_prepared_apfs_partition(self):
        prepared = FakePart(
            "disk0s4",
            offset=self.plan.offset_bytes,
            size=2 * GIB,
            free=False,
        )
        adapter = self._adapter(FakeInstaller(FakeDiskUtil([[prepared]])))
        adapter.preflight(self.plan)

        evidence = json.loads(adapter.install_stub_and_esp(self.plan))

        self.assertEqual(evidence["plan_digest"], self.plan.plan_digest)
        self.assertIn(("prepare_volume", "disk0s4"), adapter.installer.ins.calls)

    def test_installed_image_read_back_rejects_changed_partition_bytes(self):
        dutil = FakeDiskUtil([[self.free]])
        adapter = self._adapter(FakeInstaller(dutil))
        adapter.preflight(self.plan)
        adapter.prepare_target(self.plan)
        adapter.install_stub_and_esp(self.plan)
        self.raw_images["disk0s6"] = b"x" * 4096

        with self.assertRaisesRegex(
            AsahiAdapterError,
            "installed content does not match payload",
        ):
            adapter._installed_evidence(self.plan)

    def test_fast_root_is_not_reread_but_retry_detects_corruption(self):
        adapter = self._adapter(FakeInstaller(FakeDiskUtil([[self.free]])))
        adapter.preflight(self.plan)
        target = adapter.prepare_target(self.plan)
        read = adapter.raw_partition_opener
        def boot_only(name):
            self.assertNotEqual(name, "disk0s7")
            return read(name)
        adapter.raw_partition_opener = boot_only
        evidence = adapter.install_stub_and_esp(self.plan)
        self.raw_images["disk0s7"] = b"x" * 4096
        retry = self._retry_adapter(target, evidence)
        retry.preflight(self.plan)
        with self.assertRaisesRegex(AsahiAdapterError, "does not match payload"):
            retry.validate_installed_checkpoint(self.plan, target, evidence)

    def test_thorough_mode_reads_root(self):
        adapter = self._adapter(FakeInstaller(FakeDiskUtil([[self.free]])))
        adapter.full_readback = True
        adapter.preflight(self.plan)
        adapter.prepare_target(self.plan)
        evidence = json.loads(adapter.install_stub_and_esp(self.plan))
        self.assertEqual(evidence["populated_partitions"][-1]["verification"],
                         "raw-prefix-sha256")
        self.raw_images["disk0s7"] = b"x" * 4096
        with self.assertRaisesRegex(AsahiAdapterError, "does not match payload"):
            adapter._installed_evidence(self.plan)

    def test_oversized_image_fails_before_disk_mutation(self):
        metadata = json.loads(self.metadata.read_text())
        metadata["os_list"][0]["partitions"][1]["size"] = "1024B"
        self.metadata.chmod(0o600)
        self.metadata.write_text(json.dumps(metadata))
        self.metadata.chmod(0o400)
        installer = FakeInstaller(FakeDiskUtil([[self.free]]))
        adapter = self._adapter(installer)
        with self.assertRaisesRegex(AsahiAdapterError, "exceeds partition capacity"):
            adapter.preflight(self.plan)
        self.assertEqual(installer.dutil.resize_calls, [])
        self.assertFalse(adapter.preflight_complete)

    def test_preflight_does_not_expand_the_package(self):
        adapter = self._adapter(FakeInstaller(FakeDiskUtil([[self.free]])))
        with patch.object(zipfile.ZipFile, "testzip", side_effect=AssertionError("expanded")):
            adapter.preflight(self.plan)

    def test_recovery_retry_revalidates_exact_installed_checkpoint(self):
        initial = self._adapter(FakeInstaller(FakeDiskUtil([[self.free]])))
        initial.preflight(self.plan)
        target_evidence = initial.prepare_target(self.plan)
        installed_evidence = initial.install_stub_and_esp(self.plan)
        retry = self._retry_adapter(target_evidence, installed_evidence)

        retry.preflight(self.plan)
        retry.validate_installed_checkpoint(
            self.plan,
            target_evidence,
            installed_evidence,
        )

        self.assertEqual(retry.installer.dutil.resize_calls, [])
        self.assertEqual(retry.installer.dutil.add_calls, [])
        self.assertIn(
            ("check_volume", "disk0s4"),
            retry.installer.ins.calls,
        )

    def test_recovery_retry_rejects_changed_partition_identity(self):
        initial = self._adapter(FakeInstaller(FakeDiskUtil([[self.free]])))
        initial.preflight(self.plan)
        target_evidence = initial.prepare_target(self.plan)
        installed_evidence = initial.install_stub_and_esp(self.plan)
        retry = self._retry_adapter(
            target_evidence,
            installed_evidence,
            changed_partition="disk0s7",
        )
        retry.preflight(self.plan)

        with self.assertRaisesRegex(
            AsahiAdapterError,
            "installed partition identity changed",
        ):
            retry.validate_installed_checkpoint(
                self.plan,
                target_evidence,
                installed_evidence,
            )

        self.assertEqual(retry.installer.dutil.resize_calls, [])
        self.assertEqual(retry.installer.dutil.add_calls, [])

    def test_duplicate_target_metadata_is_rejected(self):
        target = self._target_metadata()
        self._write_metadata([target, dict(target)])
        adapter = self._adapter(FakeInstaller(FakeDiskUtil([[self.free]])))

        with self.assertRaisesRegex(
            AsahiAdapterError,
            "exactly one Omarchy full-OS target",
        ):
            adapter.preflight(self.plan)

    def test_validation_only_uefi_target_is_not_an_install_target(self):
        target = self._target_metadata()
        target["omarchy_target"] = "apple-silicon-uefi"
        self._write_metadata([target])
        adapter = self._adapter(FakeInstaller(FakeDiskUtil([[self.free]])))

        with self.assertRaisesRegex(
            AsahiAdapterError,
            "exactly one Omarchy full-OS target",
        ):
            adapter.preflight(self.plan)

    def test_missing_startup_volume_icon_is_rejected_before_mutation(self):
        target = self._target_metadata()
        target.pop("icon")
        self._write_metadata([target])
        adapter = self._adapter(FakeInstaller(FakeDiskUtil([[self.free]])))

        with self.assertRaisesRegex(
            AsahiAdapterError,
            "invalid Omarchy Startup Options icon metadata",
        ):
            adapter.preflight(self.plan)

    def test_metadata_symlink_and_unprepared_adapter_are_rejected(self):
        link = self.root / "metadata-link.json"
        link.symlink_to(self.metadata)
        adapter = AsahiStage1Adapter(
            installer=FakeInstaller(FakeDiskUtil([[self.free]])),
            metadata_path=str(link),
            payload_path=str(self.payload),
            stub_size=2 * GIB,
        )
        with self.assertRaisesRegex(
            AsahiAdapterError,
            "metadata is unavailable",
        ):
            adapter.preflight(self.plan)

        fresh = self._adapter(FakeInstaller(FakeDiskUtil([[self.free]])))
        with self.assertRaisesRegex(
            AsahiAdapterError,
            "preflight is required",
        ):
            fresh.prepare_target(self.plan)

    def _adapter(self, installer):
        installer.dutil.stub_icon_path = str(self.installed_stub_icon)
        installer.dutil.mount_points = {
            "disk0s5": str(self.installed_esp),
        }
        @contextmanager
        def writer(name):
            stream = io.BytesIO()
            yield stream
            self.raw_images[name] = stream.getvalue()
            stream.close()

        return AsahiStage1Adapter(
            installer=installer,
            metadata_path=str(self.metadata),
            payload_path=str(self.payload),
            stub_size=2 * GIB,
            raw_partition_writer=writer,
            image_flush=lambda stream: None,
            raw_partition_opener=lambda name: io.BytesIO(
                self.raw_images[name]
            ),
        )

    def _retry_adapter(
        self,
        target_evidence,
        installed_evidence,
        changed_partition=None,
    ):
        target = json.loads(target_evidence)
        installed = json.loads(installed_evidence)
        parts = [
            FakePart(
                target["partition_identifier"],
                offset=target["offset_bytes"],
                size=target["size_bytes"],
                free=False,
                uuid=target["uuid"],
            )
        ]
        next_offset = target["offset_bytes"] + target["size_bytes"]
        for item in installed["populated_partitions"]:
            identity = item["partition_uuid"]
            if item["partition_identifier"] == changed_partition:
                identity = "changed-uuid"
            parts.append(
                FakePart(
                    item["partition_identifier"],
                    offset=next_offset,
                    size=item["partition_size_bytes"],
                    free=False,
                    uuid=identity,
                )
            )
            next_offset += item["partition_size_bytes"]
        return self._adapter(FakeInstaller(FakeDiskUtil([parts])))

    def _target_metadata(self):
        return {
            "omarchy_target": "apple-silicon-full-os",
            "minimum_size": 64 * GIB,
            "name": "Omarchy MX Mac",
            "default_os_name": "Omarchy",
            "boot_object": "m1n1.bin",
            "next_object": "m1n1/boot.bin",
            "package": self.payload.name,
            "icon": "omarchy-volume.icns",
            "supported_fw": None,
            "partitions": [
                {
                    "name": "EFI",
                    "type": "EFI",
                    "size": "500MB",
                    "format": "fat",
                    "copy_firmware": True,
                    "copy_installer_data": True,
                    "source": "esp",
                },
                {
                    "name": "Boot",
                    "type": "Linux",
                    "size": "2GB",
                    "image": "boot.img",
                },
                {
                    "name": "Root",
                    "type": "Linux",
                    "size": "32GB",
                    "expand": True,
                    "image": "root.img",
                },
            ],
        }

    def _write_metadata(self, targets=None):
        if targets is None:
            targets = [self._target_metadata()]
        if self.metadata.exists():
            self.metadata.chmod(0o600)
        self.metadata.write_text(
            json.dumps({"os_list": targets}),
            encoding="utf-8",
        )
        self.metadata.chmod(0o400)


class AsahiInPlaceRepairAdapterTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.payload = self.root / "payload.zip"
        self.content = {
            "disk0s3": bytearray(b"stub-old"),
            "disk0s4": bytearray(b"efi-old!"),
            "disk0s5": bytearray(b"boot-old"),
            "disk0s6": bytearray(b"root-old"),
        }
        replacements = {
            "boot": b"boot-new",
            "root": b"root-new",
        }
        with zipfile.ZipFile(self.payload, "w") as archive:
            for role, content in replacements.items():
                archive.writestr(f"repair/{role}.img", content)
        self.manifest = {
            "partitions": [
                {"role": "stub", "identifier": "disk0s3"},
                {"role": "efi", "identifier": "disk0s4"},
                {"role": "boot", "identifier": "disk0s5"},
                {"role": "root", "identifier": "disk0s6"},
            ],
            "existing_content": {
                role: self._identity(self.content[identifier])
                for role, identifier in (
                    ("stub", "disk0s3"),
                    ("efi", "disk0s4"),
                    ("boot", "disk0s5"),
                    ("root", "disk0s6"),
                )
            },
            "replacement_content": {
                "stub": {
                    **self._identity(self.content["disk0s3"]),
                    "payload_member": None,
                },
                "efi": {
                    **self._identity(self.content["disk0s4"]),
                    "payload_member": None,
                },
                "boot": {
                    **self._identity(replacements["boot"]),
                    "payload_member": "repair/boot.img",
                },
                "root": {
                    **self._identity(replacements["root"]),
                    "payload_member": "repair/root.img",
                },
            },
        }
        self.disk_utility = FakeDiskUtil([[]])
        self.installer = SimpleNamespace(dutil=self.disk_utility)
        self.opened_partitions = []
        self.adapter = AsahiInPlaceRepairAdapter(
            installer=self.installer,
            manifest=self.manifest,
            metadata_path=self.root / "metadata.json",
            payload_path=self.payload,
            raw_partition_opener=self._open_partition,
            boot_policy_authorizer=lambda *_: b"authorized",
        )
        self.plan = SimpleNamespace(plan_digest="a" * 64)

    def tearDown(self):
        self.temporary.cleanup()

    def test_repair_rewrites_only_declared_content_without_partitioning(self):
        existing = json.loads(
            self.adapter.validate_existing_install(self.plan)
        )
        written = json.loads(self.adapter.rewrite_existing_content(self.plan))
        repaired = json.loads(
            self.adapter.validate_repaired_content(self.plan)
        )

        self.assertEqual(set(existing["content"]), {"boot", "root"})
        self.assertEqual(existing["preserved_roles"], ["stub", "efi"])
        self.assertEqual(written["rewritten_roles"], ["boot", "root"])
        self.assertEqual(set(repaired["content"]), {"boot", "root"})
        self.assertEqual(repaired["preserved_roles"], ["stub", "efi"])
        self.assertEqual(self.content["disk0s3"], b"stub-old")
        self.assertEqual(self.content["disk0s4"], b"efi-old!")
        self.assertEqual(self.content["disk0s5"], b"boot-new")
        self.assertEqual(self.content["disk0s6"], b"root-new")
        self.assertEqual(self.disk_utility.resize_calls, [])
        self.assertEqual(self.disk_utility.add_calls, [])

    def test_readback_is_exhaustive_for_declared_writes_and_skips_preserved_content(self):
        self.adapter.validate_existing_install(self.plan)
        self.adapter.rewrite_existing_content(self.plan)
        self.content["disk0s4"][0] ^= 1

        self.assertEqual(
            json.loads(self.adapter.validate_repaired_content(self.plan))["preserved_roles"],
            ["stub", "efi"],
        )
        self.content["disk0s5"][0] ^= 1

        with self.assertRaisesRegex(
            AsahiAdapterError,
            "repair content changed",
        ):
            self.adapter.validate_repaired_content(self.plan)

    @staticmethod
    def _identity(content):
        return {
            "size_bytes": len(content),
            "sha256": "sha256:" + hashlib.sha256(content).hexdigest(),
        }

    def _open_partition(self, identifier, mode):
        self.opened_partitions.append((identifier, mode))
        return PartitionAccess(self.content[identifier], "w" in mode or "+" in mode)


class FakePart:
    def __init__(
        self,
        name,
        *,
        offset,
        size,
        free,
        part_type="Apple_APFS",
        uuid="PART-UUID",
    ):
        self.name = name
        self.offset = offset
        self.size = size
        self.free = free
        self.type = part_type
        self.uuid = uuid


class FakeDiskUtil:
    def __init__(self, partition_rounds):
        self.partition_rounds = list(partition_rounds)
        self.round = 0
        self.resize_calls = []
        self.add_calls = []
        self.mount_points = {}

    def get_info(self):
        return None

    def get_partitions(self, disk):
        index = min(self.round, len(self.partition_rounds) - 1)
        self.round += 1
        return self.partition_rounds[index]

    def resizeContainer(self, name, new_size):
        self.resize_calls.append((name, new_size))

    def addPartition(self, name, part_type, label, size):
        self.add_calls.append((name, part_type, label, size))
        source = self.partition_rounds[-1][0]
        return FakePart(
            "disk0s4",
            offset=source.offset,
            size=size,
            free=False,
        )

    def mount(self, name):
        return self.mount_points[name]


class PartitionAccess:
    def __init__(self, content, writable):
        self.content = content
        self.writable = writable
        self.stream = io.BytesIO(bytes(content))

    def __enter__(self):
        return self.stream

    def __exit__(self, exc_type, exc_value, traceback):
        if exc_type is None and self.writable:
            self.content[:] = self.stream.getvalue()
        self.stream.close()


class FakeInstaller:
    def __init__(self, dutil):
        self.dutil = dutil
        self.sys_disk = "disk0"
        # An M3 Air: asahi's own Stage 1 stays the boot object.
        self.sysinfo = SimpleNamespace(device_class="j613ap")
        self.ipsw = SimpleNamespace(version="14.8.3")
        self.osinfo = object()
        self.cur_os = "current-os"
        self.chosen_firmware = "unset"
        self.check_cur_os_calls = 0

    def choose_ipsw(self, supported_firmware):
        self.chosen_firmware = supported_firmware
        return self.ipsw

    def check_cur_os(self):
        self.check_cur_os_calls += 1


# A kmutil that prints each prompt before reading its answer, and echoes what
# a terminal would show: the confirmation and the user name, but never the
# password, which a real terminal reads with echo off.
PROMPTING_KMUTIL = """printf 'Are you sure you want to do this? (enter y or n) '; IFS= read -r a; echo "$a"
echo 'updating local machine policy...'; printf 'Username: '; IFS= read -r u; echo "$u"
printf 'Password: '; IFS= read -r p; echo
printf '%s|%s|%s' "$a" "$u" "$p" >"$PIPED"
[ "$a|$u|$p" = "y|scott|$EXPECTED_PASSWORD" ]"""

# Files step2.sh may leave in /tmp while it runs; none may outlive it.
STEP2_LOGS = ("bp.txt", "bless.log", "bputil.log", "bputil.status", "kmutil.log",
              "kmutil.status", "kmutil.pid", "kmutil.done")


class Step2ScriptTests(unittest.TestCase):
    """The Recovery setup: the installer's own name and one password prompt."""

    title = "Probe Installer"
    # How macOS and its recoveryOS run step2.sh's #!/bin/sh: bash in POSIX
    # mode. (Linux's /bin/sh is often dash, which the class below covers.)
    shell = [shutil.which("bash") or "/bin/bash", "--posix"]
    # The fake recoveryOS tools' interpreter.
    fake_shell = "/bin/sh"

    def make(self, owner):
        root = tempfile.TemporaryDirectory()
        self.addCleanup(root.cleanup)
        step2 = Path(root.name) / "step2.sh"
        step2.write_text("asahi step2")

        class Stub:
            def __init__(self, *args):
                self.osi = SimpleNamespace(vgid="0B1C2D3E-4F50-6172-8394-A5B6C7D8E9F0", preboot_vgid="1A2B3C4D-5E6F-7081-92A3-B4C5D6E7F809", recovery=root.name)
                self.step2_sh = str(step2)

            def load_identity(self):
                pass

            def collect_firmware(self, pkg):
                pass

            def install_files(self, cur_os):
                # As the real stub does, with the plain image older firmware ships.
                image = Path(self.osi.recovery, self.osi.vgid, "usr/standalone/firmware/arm64eBaseSystem.dmg")
                image.parent.mkdir(parents=True, exist_ok=True)
                image.write_bytes(b"plain recovery image")

        with patch("omarchy_asahi.stub.StubInstaller", Stub), patch.dict(
            os.environ, {"OMARCHY_MACHINE_OWNER": owner, "OMARCHY_INSTALLER_NAME": self.title}
        ):
            installer = stub_installer("sysinfo", "dutil", "osinfo")
            installer.install_files("cur-os")
        return step2

    def test_the_setup_is_branded_and_asks_for_the_password_once(self):
        step2 = self.make("scott")
        text = step2.read_text()
        self.assertTrue(os.access(step2, os.X_OK))
        self.assertIn("${BOLD}Probe Installer${RST}", text)
        self.assertNotIn("MX Mac", text)
        self.assertEqual(re.findall(r"##[A-Z]+##", text), [])
        self.assertIn('VGID="0B1C2D3E-4F50-6172-8394-A5B6C7D8E9F0"', text)
        self.assertIn('PREBOOT="1A2B3C4D-5E6F-7081-92A3-B4C5D6E7F809"', text)
        self.assertIn('OWNER="scott"', text)
        # One prompt, kept whole: leading and trailing spaces are part of it.
        self.assertEqual(text.count("read -r PASSWORD"), 1)
        self.assertIn("IFS= read -r PASSWORD", text)
        self.assertIn('bputil -nc -v "$VGID" -u "$OWNER" -p "$PASSWORD"', text)
        # kmutil runs on a hidden terminal, recording its own process ID.
        self.assertIn('script -q -t 0 "$kmutil_log"', text)
        self.assertIn("echo $$ >/tmp/kmutil.pid; exec kmutil configure-boot -c boot.bin --raw --entry-point 2048", text)
        self.assertIn('run_with_spinner "$kmutil_status" 60 /tmp/kmutil.pid hidden_kmutil', text)
        self.assertEqual(text.count("Are you sure you want to do this? (y or n)"), 1)
        # The recoveryOS checks stay.
        self.assertIn("': Paired'", text)
        self.assertIn("'one true recoveryOS'", text)
        result = subprocess.run([*self.shell, "-n", str(step2)])
        self.assertEqual(result.returncode, 0)

    def step2_with_fakes(self, kmutil_body, paired=True, bputil_mode="ok", password="secret",
                         startup="macos"):
        """step2.sh in place, with fake recoveryOS tools first on PATH."""
        step2 = self.make("scott")
        root = Path(step2).parent
        resources = root / "Omarchy" / "Finish Installation.app" / "Contents" / "Resources"
        resources.mkdir(parents=True)
        script = resources / "step2.sh"
        script.write_text(step2.read_text())
        script.chmod(0o755)
        bin_dir = root / "bin"
        bin_dir.mkdir()
        sleep = shutil.which("sleep")
        fakes = {
            "bputil": "\n".join((
                f"[ \"$1\" = -d ] && echo 'OS Pairing Status: {'Paired' if paired else 'Not Paired'}'"
                " && echo 'OS Type: one true recoveryOS' && exit 0",
                'echo "$*" >>"$CALLS.bputil"',
                # Without -u, bputil asks the owner itself: the fallback.
                '[ "$4" = -u ] || exit 0',
                "echo 'It should only be used to understand how the security works.'",
                "echo 'Use at your own risk!'",
                '[ "$7" = "$EXPECTED_PASSWORD" ] || exit 1',
                f'[ "$BPUTIL_MODE" = hang ] && echo $$ >"$CALLS.bputil-pid" && exec {sleep} 30',
                '[ "$BPUTIL_MODE" = fail ] && exit 1',
                "exit 0",
            )),
            "stty": 'echo "$*" >>"$CALLS.stty"',
            "mount": "exit 0",
            "reboot": "exit 0",
            "shutdown": "exit 0",
            # script -q -t 0 log command...: the command's output goes to the
            # log, which is kept for the test because step2.sh deletes it. Like
            # the real script, which gives kmutil its own session on a hidden
            # terminal, Ctrl-C ends script but never reaches kmutil: here
            # kmutil runs in the background, where SIGINT is ignored. Its
            # answers come through descriptor 3, since dash replaces a
            # background job's stdin with /dev/null even after <&0.
            "script": "\n".join((
                'log=$4; shift 4',
                "trap 'exit 130' INT",
                'exec 3<&0',
                '"$@" <&3 3<&- >"$log" 2>&1 &',
                'wait $!; s=$?',
                'cp "$log" "$CALLS.kmutil-log"; exit $s',
            )),
            # Every sleep lasts 50 ms, so the one-minute deadline is twelve seconds.
            "sleep": f"exec {sleep} 0.05",
            # Like macOS's bless, it exits 0 whatever the password, and only
            # a right one changes the startup disk.
            "bless": "\n".join((
                '[ "$1" = --getBoot ] && { cat "$CALLS.boot"; exit 0; }',
                'echo "$*" >>"$CALLS.bless"',
                'case "$*" in',
                '*--stdinpass) IFS= read -r pw; echo "$pw" >>"$CALLS.bless"',
                '    [ "$pw" = "$EXPECTED_PASSWORD" ] && echo /dev/omarchy >"$CALLS.boot" ;;',
                # Without --stdinpass, bless asks the owner itself.
                '*) echo /dev/omarchy >"$CALLS.boot" ;;',
                'esac',
                "exit 0",
            )),
            "diskutil": "\n".join((
                '[ "$1" = info ] || exit 0',
                'case "$2" in',
                "/dev/omarchy|*/Omarchy) printf '   Device Node:  /dev/omarchy\\n   APFS Volume Group:  0B1C2D3E-4F50-6172-8394-A5B6C7D8E9F0\\n' ;;",
                "*) printf '   Device Node:  /dev/disk0s2\\n   APFS Volume Group:  MACOS-VG\\n' ;;",
                'esac',
            )),
            "kmutil": 'n=$(($(cat "$CALLS" 2>/dev/null || echo 0) + 1)); echo "$n" >"$CALLS"\n' + kmutil_body,
        }
        for name, body in fakes.items():
            (bin_dir / name).write_text(f"#!{self.fake_shell}\n" + body + "\n")
            (bin_dir / name).chmod(0o755)
        calls = root / "kmutil-calls"
        Path(f"{calls}.boot").write_text("/dev/omarchy\n" if startup == "omarchy" else "/dev/disk0s2\n")
        env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}", CALLS=str(calls),
                   PIPED=str(root / "piped"), EXPECTED_PASSWORD=password, BPUTIL_MODE=bputil_mode)
        return script, env, calls

    def run_step2(self, kmutil_body, stdin="y\nsecret\n\n", **options):
        script, env, calls = self.step2_with_fakes(kmutil_body, **options)
        result = subprocess.run([*self.shell, str(script)], input=stdin, env=env,
                                capture_output=True, text=True, timeout=60)
        kmutil_calls = int(calls.read_text()) if calls.exists() else 0
        return result, kmutil_calls, calls

    def assert_nothing_left_in_tmp(self):
        for name in STEP2_LOGS:
            self.assertFalse(os.path.exists(f"/tmp/{name}"), name)

    def test_kmutil_is_answered_out_of_sight(self):
        result, kmutil_calls, calls = self.run_step2(PROMPTING_KMUTIL)
        out = result.stdout
        self.assertEqual(result.returncode, 0, out + result.stderr)
        self.assertEqual(kmutil_calls, 1)
        self.assertEqual(Path(calls.parent, "piped").read_text(), "y|scott|secret")
        self.assertNotIn("Username", out)
        self.assertNotIn("type y", out)
        self.assertEqual(out.count("Password for scott:"), 1)
        # Nothing changes before the owner agrees.
        self.assertLess(out.index("Are you sure you want to do this? (y or n)"), out.index("Password for scott:"))
        # The terminal shows what is typed, so the password goes only after
        # kmutil's own Password: prompt has turned echo off.
        log = Path(f"{calls}.kmutil-log").read_text()
        self.assertIn("scott", log)
        self.assertNotIn("secret", log)
        self.assert_nothing_left_in_tmp()

    def test_a_password_with_spaces_reaches_every_tool_intact(self):
        password = "  two words  "
        result, kmutil_calls, calls = self.run_step2(
            PROMPTING_KMUTIL, stdin=f"y\n{password}\n\n", password=password)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(kmutil_calls, 1)
        self.assertEqual(Path(calls.parent, "piped").read_text(), f"y|scott|{password}")

    def test_the_owner_can_decline_before_anything_changes(self):
        result, kmutil_calls, calls = self.run_step2("exit 0", stdin="n\n")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Nothing was changed", result.stdout)
        self.assertNotIn("Password for", result.stdout)
        self.assertFalse(Path(f"{calls}.bputil").exists())
        self.assertEqual(kmutil_calls, 0)
        self.assert_nothing_left_in_tmp()

    def test_a_wrong_password_is_named_without_bputils_disclaimer(self):
        result, kmutil_calls, _ = self.run_step2(PROMPTING_KMUTIL, stdin="y\nwrong\nsecret\n\n")
        out = result.stdout
        self.assertEqual(result.returncode, 0, out + result.stderr)
        self.assertIn("That password didn't work for scott. Try again.", out)
        self.assertNotIn("Use at your own risk", out)
        # Each attempt says what it is doing while bputil works, and a
        # rejected one replaces that line with the reason.
        self.assertEqual(out.count("Updating Omarchy's security settings..."), 2)
        # (Text-mode capture turns the carriage return into a newline.)
        self.assertIn("\x1b[KThat password didn't work for scott.", out)
        self.assertEqual(kmutil_calls, 1)

    def test_bputil_lets_macos_ask_after_three_failures(self):
        result, _, calls = self.run_step2("exit 0", stdin="y\nw1\nw2\nw3\n\n", bputil_mode="fail")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("macOS asks itself now", result.stdout)
        attempts = Path(f"{calls}.bputil").read_text().splitlines()
        self.assertEqual(len(attempts), 4)
        self.assertEqual(attempts[-1], "-nc -v 0B1C2D3E-4F50-6172-8394-A5B6C7D8E9F0")

    def test_a_kmutil_that_fails_is_handed_to_the_owner(self):
        started = time.monotonic()
        result, kmutil_calls, _ = self.run_step2('[ "$n" -gt 1 ] && exit 0\necho "Username: Password:"; exit 1')
        out = result.stdout
        self.assertEqual(result.returncode, 0, out + result.stderr)
        self.assertEqual(kmutil_calls, 2)
        self.assertIn("Type y, then your user name and password", out)
        self.assertNotIn("Username:", out)
        # A failure is handed over at once, not after the one-minute deadline.
        self.assertLess(time.monotonic() - started, 8)

    def test_a_kmutil_that_stalls_is_stopped_before_the_owner_answers(self):
        # It keeps its own command line, as kmutil does, so it can be recognized.
        result, kmutil_calls, calls = self.run_step2(
            '[ "$n" -gt 1 ] && exit 0\necho $$ >"$CALLS.stalled"\nwhile :; do sleep 1; done')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(kmutil_calls, 2)
        self.assertIn("Type y, then your user name and password", result.stdout)
        # The stalled kmutil itself, not only script, is gone before the
        # second one starts.
        with self.assertRaises(ProcessLookupError):
            os.kill(int(Path(f"{calls}.stalled").read_text()), 0)

    def test_ctrl_c_stops_everything_it_started(self):
        import signal
        script, env, calls = self.step2_with_fakes("exit 0", bputil_mode="hang")
        process = subprocess.Popen([*self.shell, str(script)], env=env, stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                   start_new_session=True)
        process.stdin.write("y\nsecret\n")
        process.stdin.flush()
        hanging = Path(f"{calls}.bputil-pid")
        deadline = time.monotonic() + 20
        while not hanging.exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertTrue(hanging.exists(), "bputil never started")
        # Ctrl-C reaches the terminal's whole foreground process group.
        os.killpg(process.pid, signal.SIGINT)
        out, _ = process.communicate(timeout=20)
        self.assertEqual(process.returncode, 130)
        self.assertIn("Stopped.", out)
        time.sleep(0.5)
        with self.assertRaises(ProcessLookupError):
            os.killpg(process.pid, 0)
        self.assert_nothing_left_in_tmp()

    def test_a_rejected_password_never_reaches_kmutil(self):
        # After three rejected passwords bputil asks macOS itself; the third
        # rejected one must not then be typed into kmutil.
        started = time.monotonic()
        result, kmutil_calls, calls = self.run_step2("exit 0", stdin="y\nw1\nw2\nw3\n\n", bputil_mode="fail")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(kmutil_calls, 1)
        self.assertFalse(Path(f"{calls}.kmutil-log").exists(), "the hidden kmutil ran")
        self.assertIn("Type y, then your user name and password", result.stdout)
        self.assertLess(time.monotonic() - started, 8)

    def interrupt(self, kmutil_body, started_file, stdin, **options):
        """Run step2.sh, wait for `started_file`, then press Ctrl-C."""
        import signal
        script, env, calls = self.step2_with_fakes(kmutil_body, **options)
        process = subprocess.Popen([*self.shell, str(script)], env=env, stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                   start_new_session=True)
        process.stdin.write(stdin)
        process.stdin.flush()
        started = Path(f"{calls}.{started_file}")
        deadline = time.monotonic() + 20
        while not started.exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertTrue(started.exists(), f"{started_file} never appeared")
        os.killpg(process.pid, signal.SIGINT)
        out, _ = process.communicate(timeout=20)
        self.assertEqual(process.returncode, 130)
        self.assertIn("Stopped.", out)
        return calls

    def test_ctrl_c_at_the_password_prompt_restores_echo(self):
        # The fake stty's log appears when echo is turned off for the prompt.
        calls = self.interrupt("exit 0", "stty", stdin="y\n")
        self.assertEqual(Path(f"{calls}.stty").read_text().splitlines(), ["-echo", "echo"])
        self.assertFalse(Path(f"{calls}.bputil").exists())
        self.assert_nothing_left_in_tmp()

    def test_ctrl_c_during_the_hidden_kmutil_stops_it(self):
        # A kmutil that ignores Ctrl-C, as one on its own hidden terminal would.
        calls = self.interrupt(
            "trap '' INT\necho $$ >\"$CALLS.kmutil-pid\"\nwhile :; do sleep 1; done",
            "kmutil-pid", stdin="y\nsecret\n")
        with self.assertRaises(ProcessLookupError):
            os.kill(int(Path(f"{calls}.kmutil-pid").read_text()), 0)
        self.assert_nothing_left_in_tmp()

    def test_a_volume_group_that_is_not_a_uuid_is_refused(self):
        for vgid in ("", "VG-1", '0B1C2D3E-4F50-6172-8394-A5B6C7D8E9F0"; reboot; "'):
            root = tempfile.TemporaryDirectory()
            self.addCleanup(root.cleanup)
            step2 = Path(root.name) / "step2.sh"

            class Stub:
                def __init__(self, *args, vgid=vgid):
                    self.osi = SimpleNamespace(vgid=vgid, preboot_vgid="1A2B3C4D-5E6F-7081-92A3-B4C5D6E7F809",
                                               recovery=root.name)
                    self.step2_sh = str(step2)

                def load_identity(self):
                    pass

                def collect_firmware(self, pkg):
                    pass

                def install_files(self, cur_os):
                    image = Path(root.name, vgid, "usr/standalone/firmware/arm64eBaseSystem.dmg")
                    image.parent.mkdir(parents=True, exist_ok=True)
                    image.write_bytes(b"plain recovery image")

            with self.subTest(vgid=vgid), patch("omarchy_asahi.stub.StubInstaller", Stub), patch.dict(
                os.environ, {"OMARCHY_MACHINE_OWNER": "scott", "OMARCHY_INSTALLER_NAME": self.title}
            ), self.assertRaisesRegex(AsahiAdapterError, "volume group is invalid"):
                stub_installer("sysinfo", "dutil", "osinfo").install_files("cur-os")

    def test_an_unpaired_recovery_blesses_with_the_known_owner(self):
        result, kmutil_calls, calls = self.run_step2(PROMPTING_KMUTIL, stdin="secret\n\n", paired=False)
        self.assertEqual(result.returncode, 1)
        self.assertIn("Password for scott:", result.stdout)
        root = calls.parent
        self.assertEqual(
            Path(f"{calls}.bless").read_text().splitlines(),
            [f"--setBoot --mount {root / 'Omarchy'} --user scott --stdinpass", "secret"],
        )
        self.assertEqual(Path(f"{calls}.boot").read_text(), "/dev/omarchy\n")
        self.assertIn("choose Omarchy, and log in.", result.stdout)
        self.assertEqual(kmutil_calls, 0)

    def test_an_unpaired_recovery_checks_the_startup_disk_not_bless(self):
        # bless exits 0 after a wrong password, so only the startup disk tells.
        result, _, calls = self.run_step2("exit 0", stdin="wrong\nsecret\n\n", paired=False)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout.count("That password didn't work for scott. Try again."), 1)
        self.assertEqual(Path(f"{calls}.boot").read_text(), "/dev/omarchy\n")

    def test_an_unpaired_recovery_lets_bless_ask_after_three_failures(self):
        result, _, calls = self.run_step2("exit 0", stdin="a\nb\nc\n\n", paired=False)
        self.assertEqual(result.returncode, 1)
        self.assertIn("macOS asks itself now", result.stdout)
        self.assertEqual(Path(f"{calls}.bless").read_text().splitlines()[-1],
                         f"--setBoot --mount {calls.parent / 'Omarchy'}")
        self.assertEqual(Path(f"{calls}.boot").read_text(), "/dev/omarchy\n")

    def test_an_unpaired_recovery_already_starting_omarchy_asks_nothing(self):
        result, _, calls = self.run_step2("exit 0", stdin="\n", paired=False, startup="omarchy")
        self.assertEqual(result.returncode, 1)
        self.assertIn("is already the", result.stdout)
        self.assertNotIn("Password for", result.stdout)
        self.assertFalse(Path(f"{calls}.bless").exists())

    def test_every_line_fits_an_80_column_terminal(self):
        text = self.make("scott").read_text()
        for line in text.splitlines():
            match = re.match(r'\s*(?:echo|printf)\s+"(.*)"', line)
            if not match:
                continue
            shown = re.sub(r"\$\{(BOLD|RST)\}", "", match.group(1))
            shown = shown.replace("$os_name", "Omarchy").replace("\\n", "")
            self.assertLessEqual(len(shown), 76, shown)

    def test_an_unknown_owner_is_asked_for(self):
        text = self.make("").read_text()
        self.assertIn('OWNER=""', text)
        self.assertIn('if [ -z "$OWNER" ]', text)

    def test_a_title_that_could_break_the_script_is_refused(self):
        self.title = 'Probe"; reboot; "'
        with self.assertRaises(AsahiAdapterError):
            self.make("scott")

    def test_an_owner_that_could_break_the_script_is_refused(self):
        with self.assertRaises(AsahiAdapterError):
            self.make('scott"; rm -rf /; "')

    def test_the_template_has_only_its_four_placeholders(self):
        import re as _re
        self.assertEqual(
            set(_re.findall(r"##[A-Z]+##", STEP2_SCRIPT)),
            {"##TITLE##", "##VGID##", "##PREBOOT##", "##OWNER##"},
        )



@unittest.skipUnless(shutil.which("dash"), "dash is not installed")
class Step2ScriptDashTests(Step2ScriptTests):
    """The same under dash: step2.sh is #!/bin/sh, so it must stay POSIX."""

    shell = [shutil.which("dash") or "dash"]
    # Linux's /bin/sh is often dash, so the fakes run under it too.
    fake_shell = shutil.which("dash") or "dash"

class Macos26BootcachesTests(unittest.TestCase):
    class Stub:
        def __init__(self, *args, bless2):
            self.args = args
            self.bless2 = bless2

        def load_identity(self):
            self.bootcaches = {"bless2": dict(self.bless2)}
            return "identity"

        def collect_firmware(self, pkg):
            return pkg

        def install_files(self, cur_os):
            pass

    def make(self, bless2):
        with patch(
            "omarchy_asahi.stub.StubInstaller",
            lambda *args: self.Stub(*args, bless2=bless2),
        ):
            return stub_installer("sysinfo", "dutil", "osinfo")

    def test_macos_26_bootcaches_get_the_restore_bundle_every_macos_uses(self):
        # macOS 26.6 (25G72) bless2 names no RestoreBundlePath.
        installer = self.make({"Version": 1, "SupportsExternalPrebootObjects": True})
        self.assertEqual(installer.load_identity(), "identity")
        self.assertEqual(installer.bootcaches["bless2"]["RestoreBundlePath"], "./Restore")
        self.assertEqual(installer.args, ("sysinfo", "dutil", "osinfo"))

    def test_a_named_restore_bundle_is_kept(self):
        installer = self.make({"RestoreBundlePath": "./Elsewhere"})
        installer.load_identity()
        self.assertEqual(installer.bootcaches["bless2"]["RestoreBundlePath"], "./Elsewhere")


class FakeDecrypt:
    """omarchy_apple_aea.decrypt, writing each archive's known plaintext."""

    def __init__(self, plaintexts):
        self.plaintexts, self.calls = plaintexts, []

    def __call__(self, source, destination):
        self.calls.append(os.path.basename(source))
        if os.path.exists(destination):
            raise AssertionError(f"{destination} decrypted twice")
        name = os.path.basename(source)
        if name not in self.plaintexts:
            raise omarchy_apple_aea.AppleInputError(f"no key for {name}")
        Path(destination).write_bytes(self.plaintexts[name])


class EncryptedRecoveryFirmwareTests(unittest.TestCase):
    """macOS 26 recovery images are AEA archives hdiutil cannot attach."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.work = root / "work"
        self.work.mkdir()
        self.recovery = root / "stub-recovery"
        self.image = self.recovery / "vgid-1/usr/standalone/firmware/arm64eBaseSystem.dmg"
        self.image.parent.mkdir(parents=True)
        previous = os.getcwd()
        os.chdir(self.work)
        self.addCleanup(os.chdir, previous)
        self.runs = []
        self.decrypt = FakeDecrypt({"arm64eBaseSystem.dmg": b"plain" + b"koly"})

    def make(self, image_bytes):
        self.image.write_bytes(image_bytes)
        test = self

        class Stub:
            def __init__(self, sysinfo, dutil, osinfo):
                self.sysinfo = SimpleNamespace(macos_build="27A5000")
                self.osi = SimpleNamespace(recovery=str(test.recovery), vgid="vgid-1")
                self.manifest = {"ProductBuildVersion": "25G83"}

            def load_identity(self):
                self.bootcaches = {"bless2": {}}

            def collect_firmware(self, pkg):
                fake_stub.subprocess.run(["hdiutil", "attach", "-quiet", "-readonly",
                                          "-mountpoint", "recovery", str(test.image)], check=True)
                fake_stub.subprocess.run(["tar", "czf", "all_firmware.tar.gz"], check=True)
                fake_stub.subprocess.run(["hdiutil", "detach", "-quiet", "recovery"])
                return pkg

            def install_files(self, cur_os):
                pass

        def run(command, **kwargs):
            test.runs.append(command)
            return subprocess.CompletedProcess(command, 0)

        fake_stub = SimpleNamespace(
            StubInstaller=Stub,
            subprocess=SimpleNamespace(run=run, CompletedProcess=subprocess.CompletedProcess),
        )
        self.fake_stub = fake_stub
        with patch("omarchy_asahi.stub", fake_stub):
            installer = stub_installer("sysinfo", "dutil", "osinfo")
        return installer

    def collect(self, installer):
        with patch("omarchy_asahi.stub", self.fake_stub), patch(
            "omarchy_asahi.omarchy_apple_aea.decrypt", self.decrypt
        ):
            return installer.collect_firmware("pkg")

    def test_an_encrypted_image_is_attached_decrypted_on_any_running_macos(self):
        installer = self.make(b"AEA1" + b"\0" * 60)
        self.assertEqual(self.collect(installer), "pkg")
        decrypted = str(self.work / "decrypted-0-arm64eBaseSystem.dmg")
        self.assertEqual(Path(decrypted).read_bytes(), b"plainkoly")
        self.assertEqual(self.runs, [
            ["hdiutil", "attach", "-quiet", "-readonly", "-mountpoint", "recovery", decrypted],
            ["tar", "czf", "all_firmware.tar.gz"],
            ["hdiutil", "detach", "-quiet", "recovery"],
        ])
        # The stub's own image is untouched; install_files replaces it.
        self.assertEqual(self.image.read_bytes()[:4], b"AEA1")

    def test_an_image_that_will_not_decrypt_is_refused(self):
        self.decrypt = FakeDecrypt({})
        installer = self.make(b"AEA1" + b"\0" * 60)
        with self.assertRaisesRegex(AsahiAdapterError, "could not decrypt arm64eBaseSystem.dmg"):
            self.collect(installer)
        self.assertEqual(self.runs, [])

    def test_a_plain_recovery_image_is_attached_as_before(self):
        installer = self.make(b"koly" + b"\0" * 60)
        self.collect(installer)
        self.assertEqual(self.decrypt.calls, [])
        self.assertEqual(self.runs[0][-1], str(self.image))
        self.assertEqual(self.runs[-1][:2], ["hdiutil", "detach"])


STUB_VG = "5A6B7C8D-9E0F-4A1B-8C2D-3E4F5A6B7C8D"


class DecryptedMacos26ImagesTests(unittest.TestCase):
    """The stub's recoveryOS cannot boot the AEA images in a macOS 26 restore image."""

    AEA = b"AEA1" + b"\0" * 60
    UDIF = b"plain image" + b"\0" * 600 + b"koly" + b"\0" * 508

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.work = root / "work"
        self.work.mkdir()
        previous = os.getcwd()
        os.chdir(self.work)
        self.addCleanup(os.chdir, previous)
        self.stub_recovery = root / "stub-recovery"
        self.stub_preboot = root / "stub-preboot"
        self.stub_image = self.stub_recovery / STUB_VG / "usr/standalone/firmware/arm64eBaseSystem.dmg"
        self.stub_restore = self.stub_preboot / STUB_VG / "Restore"
        self.stub_image.parent.mkdir(parents=True)
        self.stub_restore.mkdir(parents=True)
        self.step2 = root / "step2.sh"
        self.cur_os = SimpleNamespace(recovery="/host-recovery", preboot="/host-preboot", vgid="host-vg")
        self.decrypt = FakeDecrypt({
            "arm64eBaseSystem.dmg": self.UDIF, "094-96734-093.dmg.aea": b"exclave plain",
        })

    def make(self, image, restore):
        self.stub_image.write_bytes(image)
        for name, data in restore.items():
            (self.stub_restore / name).write_bytes(data)
        test = self

        class Stub:
            def __init__(self, *args):
                self.sysinfo = SimpleNamespace(macos_build="27A5000")
                self.osi = SimpleNamespace(
                    recovery=str(test.stub_recovery), preboot=str(test.stub_preboot), vgid=STUB_VG,
                    preboot_vgid=STUB_VG,
                )
                self.step2_sh = str(test.step2)
                self.manifest = {"ProductBuildVersion": "25G83"}
                self.pb_vgid = str(test.stub_preboot / STUB_VG)
                self.bootcaches = {"bless2": {}}

            def load_identity(self):
                pass

            def collect_firmware(self, pkg):
                pass

            def install_files(self, cur_os):
                test.installed = cur_os

        with patch("omarchy_asahi.stub.StubInstaller", Stub):
            return stub_installer("sysinfo", "dutil", "osinfo")

    def install(self, installer):
        with patch("omarchy_asahi.omarchy_apple_aea.decrypt", self.decrypt):
            installer.install_files(self.cur_os)

    def test_encrypted_images_are_decrypted_in_place_on_any_running_macos(self):
        installer = self.make(self.AEA, {"094-96734-093.dmg.aea": self.AEA, "BuildManifest.plist": b"x"})
        self.install(installer)
        self.assertIs(self.installed, self.cur_os)
        self.assertEqual(self.stub_image.read_bytes(), self.UDIF)
        self.assertEqual((self.stub_restore / "094-96734-093.dmg.aea").read_bytes(), b"exclave plain")
        self.assertEqual((self.stub_restore / "BuildManifest.plist").read_bytes(), b"x")
        self.assertEqual(self.decrypt.calls, ["arm64eBaseSystem.dmg", "094-96734-093.dmg.aea"])
        # No decrypted copy is left behind in the working directory.
        self.assertEqual(list(self.work.iterdir()), [])
        # The same install also writes Omarchy's Recovery setup.
        self.assertIn(f'VGID="{STUB_VG}"', self.step2.read_text())

    def test_older_firmware_is_left_alone(self):
        installer = self.make(b"koly-free plain", {"094-1.dmg": b"plain"})
        self.install(installer)
        self.assertEqual(self.stub_image.read_bytes(), b"koly-free plain")
        self.assertEqual(self.decrypt.calls, [])

    def test_an_encrypted_file_that_will_not_decrypt_is_refused(self):
        installer = self.make(self.AEA, {"094-00000-000.dmg.aea": self.AEA})
        with self.assertRaisesRegex(AsahiAdapterError, "094-00000-000.dmg.aea"):
            self.install(installer)
        # Nothing in the stub is replaced until every image has decrypted.
        self.assertEqual(self.stub_image.read_bytes(), self.AEA)

    def test_a_recovery_image_that_does_not_decrypt_to_a_disk_image_is_refused(self):
        self.decrypt.plaintexts["arm64eBaseSystem.dmg"] = b"not a disk image" * 64
        installer = self.make(self.AEA, {})
        with self.assertRaisesRegex(AsahiAdapterError, "recovery image"):
            self.install(installer)
        self.assertEqual(self.stub_image.read_bytes(), self.AEA)


def j700_stage1(path=b"", window=0, uuid=b""):
    import struct as _struct
    import zlib as _zlib
    body = _struct.pack("<II40s192s", 1, window, uuid.ljust(40, b"\0"), path.ljust(192, b"\0"))
    block = b"AURORA-S1-CFG01\0" + body + _struct.pack("<I", _zlib.crc32(body))
    return b"m1n1 j700 stage 1" + block + b"\0" * 64 + b"STACKBOT"


class BoardStage1Tests(unittest.TestCase):
    UUID = "97c92d03-2cb3-461f-9134-134a58cc9fdc"

    def test_the_block_is_filled_in_place(self):
        import struct as _struct
        import zlib as _zlib
        image = j700_stage1()
        filled = fill_aurora_stage1(image, self.UUID, "m1n1/boot.bin", 5000)
        self.assertEqual(len(filled), len(image))
        self.assertTrue(filled.endswith(b"STACKBOT"))
        offset = filled.index(b"AURORA-S1-CFG01\0") + 16
        version, window, uuid, path = _struct.unpack_from("<II40s192s", filled, offset)
        self.assertEqual((version, window), (1, 5000))
        self.assertEqual(uuid.rstrip(b"\0"), self.UUID.encode())
        self.assertEqual(path.rstrip(b"\0"), b";m1n1/boot.bin")
        crc = _struct.unpack_from("<I", filled, offset + _struct.calcsize("<II40s192s"))[0]
        self.assertEqual(crc, _zlib.crc32(filled[offset:offset + _struct.calcsize("<II40s192s")]))

    def test_bad_inputs_are_refused(self):
        image = j700_stage1()
        for args in (
            (image, self.UUID.upper(), "m1n1/boot.bin", 0),
            (image, self.UUID, "/m1n1/boot.bin", 0),
            (image, self.UUID, "m1n1/../boot.bin", 0),
            (image, self.UUID, "m1n1/boot.bin", 100000),
            (image[:-8], self.UUID, "m1n1/boot.bin", 0),
            (image + image, self.UUID, "m1n1/boot.bin", 0),
        ):
            with self.assertRaises(AsahiAdapterError):
                fill_aurora_stage1(*args)

    def write_generic(self, root):
        target = Path(root) / "boot.bin"
        target.write_bytes(b"asahi stage 1")
        return target

    def test_a_neo_gets_the_filled_j700_stage1(self):
        with tempfile.TemporaryDirectory() as root:
            target = self.write_generic(root)
            package = {"esp/aurora/stage1-j700.bin": j700_stage1()}
            install_board_stage1("j700ap", "14.8.3", package.__getitem__, self.UUID.upper(), str(target))
            data = target.read_bytes()
            self.assertTrue(data.startswith(b"m1n1 j700 stage 1"))
            self.assertIn(b";m1n1/boot.bin", data)
            self.assertIn(self.UUID.encode(), data)

    def test_a_13_inch_m3_air_on_26_6_2_gets_the_filled_j613_stage1(self):
        import struct as _struct
        with tempfile.TemporaryDirectory() as root:
            target = self.write_generic(root)
            package = {"esp/aurora/stage1-j613.bin": j700_stage1(window=1234)}
            install_board_stage1("j613ap", "26.6.2", package.__getitem__, self.UUID, str(target))
            data = target.read_bytes()
            offset = data.index(b"AURORA-S1-CFG01\0") + 16
            _, window, uuid, path = _struct.unpack_from("<II40s192s", data, offset)
            self.assertEqual(window, 0)
            self.assertEqual(uuid.rstrip(b"\0"), self.UUID.encode())
            self.assertEqual(path.rstrip(b"\0"), b";m1n1/boot.bin")

    def test_other_macs_and_older_firmware_keep_the_asahi_stage1(self):
        package = {
            "esp/aurora/stage1-j613.bin": j700_stage1(),
            "esp/aurora/stage1-j700.bin": j700_stage1(),
        }
        for device_class, firmware in (
            ("j613ap", "14.8.3"),
            ("j613ap", "26.6"),
            ("j615ap", "26.6.2"),
            ("j413ap", "26.6.2"),
        ):
            with self.subTest(device_class=device_class, firmware=firmware), \
                    tempfile.TemporaryDirectory() as root:
                target = self.write_generic(root)
                install_board_stage1(device_class, firmware, package.__getitem__, self.UUID, str(target))
                self.assertEqual(target.read_bytes(), b"asahi stage 1")

    def test_a_26_6_2_air_image_without_the_j613_stage1_is_refused(self):
        for package in ({}, {"esp/aurora/stage1-j613.bin": b"not a stage 1"}):
            with self.subTest(package=package), tempfile.TemporaryDirectory() as root:
                target = self.write_generic(root)
                with self.assertRaises(AsahiAdapterError):
                    install_board_stage1("j613ap", "26.6.2", package.__getitem__, self.UUID, str(target))
                self.assertEqual(target.read_bytes(), b"asahi stage 1")

    def test_common_stage1_is_used_on_every_admitted_board_with_zero_delay(self):
        import struct as _struct
        package = {"esp/aurora/stage1.bin": j700_stage1(window=5000),
                   "esp/aurora/stage1-j700.bin": b"obsolete board image"}
        for board in ("j700ap", "j613ap", "j314sap", "j274ap"):
            with self.subTest(board=board), tempfile.TemporaryDirectory() as root:
                target = self.write_generic(root)
                install_board_stage1(board, "26.6.2", package.__getitem__, self.UUID, str(target), common_allowed=True)
                image = target.read_bytes()
                offset = image.index(b"AURORA-S1-CFG01\0") + 16
                self.assertEqual(_struct.unpack_from("<II", image, offset), (1, 0))
                self.assertIn(self.UUID.encode(), image)
                self.assertIn(b";m1n1/boot.bin", image)

    def test_common_stage1_presence_alone_does_not_authorize_it(self):
        package = {"esp/aurora/stage1.bin": j700_stage1(window=5000)}
        with tempfile.TemporaryDirectory() as root:
            target = self.write_generic(root)
            with self.assertRaisesRegex(AsahiAdapterError, "signed-template qualification"):
                install_board_stage1("j700ap", "26.6.2", package.__getitem__, self.UUID, str(target))
            self.assertEqual(target.read_bytes(), b"asahi stage 1")

    def test_invalid_common_stage1_cannot_fall_back_to_legacy(self):
        for blob in (b"", b"malformed"):
            with tempfile.TemporaryDirectory() as root:
                target = self.write_generic(root)
                package = {"esp/aurora/stage1.bin": blob, "esp/aurora/stage1-j700.bin": j700_stage1()}
                with self.assertRaises(AsahiAdapterError):
                    install_board_stage1("j700ap", "26.6.2", package.__getitem__, self.UUID, str(target), common_allowed=True)
                self.assertEqual(target.read_bytes(), b"asahi stage 1")

    def test_a_neo_image_without_the_j700_stage1_is_refused(self):
        with tempfile.TemporaryDirectory() as root:
            target = self.write_generic(root)
            with self.assertRaisesRegex(AsahiAdapterError, "stage1-j700.bin"):
                install_board_stage1("j700ap", "14.8.3", {}.__getitem__, self.UUID, str(target))
            self.assertEqual(target.read_bytes(), b"asahi stage 1")


class EspBoardLayoutTests(unittest.TestCase):
    MEMBERS = [
        "esp/EFI/BOOT/BOOTAA64.EFI",
        "esp/aurora/stage1-j700.bin",
        "esp/m1n1/boot.bin",
        "esp/m1n1/boot-j700.bin",
    ]

    def test_common_image_uses_identical_layout_on_all_boards(self):
        members = ["esp/aurora/stage1.bin", "esp/m1n1/boot.bin", "esp/EFI/BOOT/BOOTAA64.EFI"]
        expected = {name: name[4:] for name in members}
        for board in ("j700ap", "j613ap", "j314sap", "j274ap"):
            with self.subTest(board=board):
                self.assertEqual(esp_board_layout(board, members), expected)
                # Leftovers from older image recipes must not override the
                # common Stage2 or be deployed alongside the common Stage1.
                self.assertEqual(esp_board_layout(board, members + self.MEMBERS), expected)

    def test_common_image_requires_common_stage2(self):
        with self.assertRaisesRegex(AsahiAdapterError, "common image has no esp/m1n1/boot.bin"):
            esp_board_layout("j700ap", ["esp/aurora/stage1.bin", "esp/m1n1/boot-j700.bin"])

    def test_a_neo_installs_its_stage2_as_m1n1_boot_bin(self):
        self.assertEqual(esp_board_layout("j700ap", self.MEMBERS), {
            "esp/EFI/BOOT/BOOTAA64.EFI": "EFI/BOOT/BOOTAA64.EFI",
            "esp/aurora/stage1-j700.bin": "aurora/stage1-j700.bin",
            "esp/m1n1/boot-j700.bin": "m1n1/boot.bin",
        })

    def test_other_macs_drop_the_neo_stage2(self):
        for device_class in ("j613ap", "j314s"):
            with self.subTest(device_class=device_class):
                self.assertEqual(esp_board_layout(device_class, self.MEMBERS), {
                    "esp/EFI/BOOT/BOOTAA64.EFI": "EFI/BOOT/BOOTAA64.EFI",
                    "esp/aurora/stage1-j700.bin": "aurora/stage1-j700.bin",
                    "esp/m1n1/boot.bin": "m1n1/boot.bin",
                })

    def test_a_payload_without_the_neo_stage2_is_unchanged_on_other_macs(self):
        members = ["esp/EFI/BOOT/BOOTAA64.EFI", "esp/m1n1/boot.bin"]
        for device_class in ("j613ap", "j314s"):
            with self.subTest(device_class=device_class):
                self.assertEqual(esp_board_layout(device_class, members), {
                    "esp/EFI/BOOT/BOOTAA64.EFI": "EFI/BOOT/BOOTAA64.EFI",
                    "esp/m1n1/boot.bin": "m1n1/boot.bin",
                })

    def test_a_neo_payload_without_its_stage2_is_refused(self):
        with self.assertRaisesRegex(AsahiAdapterError, "no esp/m1n1/boot-j700.bin for the MacBook Neo"):
            esp_board_layout("j700ap", ["esp/m1n1/boot.bin"])

    def test_a_member_outside_the_esp_is_refused(self):
        with self.assertRaises(AsahiAdapterError):
            esp_board_layout("j613ap", ["root.img"])

    def copied_esp(self, root):
        for member in self.MEMBERS:
            path = Path(root, *member.split("/")[1:])
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(member.encode())

    def files(self, root):
        return {
            str(path.relative_to(root)): path.read_bytes()
            for path in Path(root).rglob("*") if path.is_file()
        }

    def test_the_copied_esp_becomes_the_neo_layout(self):
        with tempfile.TemporaryDirectory() as root:
            self.copied_esp(root)
            install_esp_board_layout("j700ap", self.MEMBERS, root)
            self.assertEqual(self.files(root), {
                "EFI/BOOT/BOOTAA64.EFI": b"esp/EFI/BOOT/BOOTAA64.EFI",
                "aurora/stage1-j700.bin": b"esp/aurora/stage1-j700.bin",
                "m1n1/boot.bin": b"esp/m1n1/boot-j700.bin",
            })

    def test_the_copied_esp_loses_the_neo_stage2_elsewhere(self):
        with tempfile.TemporaryDirectory() as root:
            self.copied_esp(root)
            install_esp_board_layout("j314s", self.MEMBERS, root)
            self.assertEqual(self.files(root), {
                "EFI/BOOT/BOOTAA64.EFI": b"esp/EFI/BOOT/BOOTAA64.EFI",
                "aurora/stage1-j700.bin": b"esp/aurora/stage1-j700.bin",
                "m1n1/boot.bin": b"esp/m1n1/boot.bin",
            })


class NewerTrackpadKeyTests(unittest.TestCase):
    """J700's Multitouch.im4p keys its trackpad C1FE, not C1FD."""

    def test_c1fe_counts_as_a_trackpad_while_firmware_is_collected(self):
        original = lambda key: "trackpad" if key.startswith("C1FD") else "unknown"
        multitouch = SimpleNamespace(device_key_to_kind=original, DEVICE_KIND_TRACKPAD="trackpad")
        seen = {}

        class Stub:
            def __init__(self, *args):
                pass

            def load_identity(self):
                pass

            def install_files(self, cur_os):
                pass

            def collect_firmware(self, pkg):
                seen["C1FE0,0"] = multitouch.device_key_to_kind("C1FE0,0")
                seen["C1FD0,0"] = multitouch.device_key_to_kind("C1FD0,0")
                seen["C1FB0,0"] = multitouch.device_key_to_kind("C1FB0,0")

        with patch("omarchy_asahi.stub.StubInstaller", Stub), patch(
            "omarchy_asahi.asahi_firmware", SimpleNamespace(multitouch=multitouch)
        ), patch("omarchy_asahi._is_encrypted", lambda path: False), patch(
            "omarchy_asahi.os.path.join", lambda *parts: "/".join(str(p) for p in parts)
        ):
            installer = stub_installer("sysinfo", "dutil", "osinfo")
            installer.osi = SimpleNamespace(recovery="r", vgid="v")
            installer.collect_firmware("pkg")
        self.assertEqual(seen, {"C1FE0,0": "trackpad", "C1FD0,0": "trackpad", "C1FB0,0": "unknown"})
        self.assertIs(multitouch.device_key_to_kind, original)


class NeoPeripheralCollectionTests(unittest.TestCase):
    def setUp(self):
        self.installer = SimpleNamespace(sysinfo=SimpleNamespace(device_class="j700ap"))
        self.original_als, self.original_isp = object(), object()
        self.commands = []
        self.process = SimpleNamespace(run=lambda command, **kwargs: self.commands.append(command))
        self.stub = SimpleNamespace(AlsFWCollection=self.original_als, ISPFWCollection=self.original_isp,
                                    subprocess=self.process)
        self.firmware = SimpleNamespace(core=SimpleNamespace(FWFile=lambda name, data: (name, data)), isp=object())
        self.names = {"apple/isp_" + item + ".dat" for item in ("1921_01XX", "1922_02XX", "1925_03XX")}
        test = self
        class Collection:
            def __init__(self, path):
                self.path = path
            def files(self):
                return [(name, b"setfile") for name in test.names]
        self.collection = Collection
        self.stack = __import__("contextlib").ExitStack()
        self.addCleanup(self.stack.close)
        self.stack.enter_context(patch("omarchy_asahi.stub", self.stub))
        self.stack.enter_context(patch("omarchy_asahi.asahi_firmware", self.firmware))
        self.stack.enter_context(patch("omarchy_asahi.omarchy_als.read_lsci", return_value=b"raw LSCI"))
        self.stack.enter_context(patch("omarchy_asahi.omarchy_als.calibration", return_value=b"v2 ALS"))
        self.stack.enter_context(patch("omarchy_asahi.omarchy_isp.collection_class", return_value=self.collection))

    def test_neo_collectors_and_raw_archive_restore_original_state(self):
        from omarchy_asahi import _neo_peripheral_collectors
        with tempfile.TemporaryDirectory() as work:
            old = os.getcwd()
            os.chdir(work)
            try:
                Path("recovery/usr/sbin").mkdir(parents=True)
                Path("recovery/usr/sbin/appleh16camerad").write_bytes(b"h16")
                with _neo_peripheral_collectors(self.installer):
                    self.assertEqual(self.stub.AlsFWCollection().files(), [
                        ("apple/j700-aop-als-cal.bin", ("apple/j700-aop-als-cal.bin", b"v2 ALS"))])
                    self.assertEqual({name for name, _ in self.stub.ISPFWCollection("recovery/usr/sbin").files()}, self.names)
                    self.stub.subprocess.run(["tar", "czf", "all_firmware.tar.gz", "old-input"])
                    command = self.commands[-1]
                    self.assertEqual(command[:4], ["tar", "czf", "all_firmware.tar.gz", "old-input"])
                    self.assertIn("appleh16camerad", command)
                    self.assertEqual(Path(command[-2], command[-1]).read_bytes(), b"raw LSCI")
                    self.stub.subprocess.run(["hdiutil", "attach", "recovery"])
                    self.assertEqual(self.commands[-1], ["hdiutil", "attach", "recovery"])
                self.assertIs(self.stub.AlsFWCollection, self.original_als)
                self.assertIs(self.stub.ISPFWCollection, self.original_isp)
                self.assertIs(self.stub.subprocess, self.process)
                self.assertFalse(Path(command[-2]).exists())
            finally:
                os.chdir(old)

    def test_missing_required_camera_setfile_stops_and_restores_hooks(self):
        from omarchy_asahi import _neo_peripheral_collectors
        self.names.remove("apple/isp_1925_03XX.dat")
        with self.assertRaisesRegex(AsahiAdapterError, "1925_03XX"):
            with _neo_peripheral_collectors(self.installer):
                self.stub.ISPFWCollection("recovery/usr/sbin")
        self.assertIs(self.stub.ISPFWCollection, self.original_isp)
        self.assertIs(self.stub.subprocess, self.process)

    def test_non_neo_never_reads_lsci_or_replaces_collectors(self):
        from omarchy_asahi import _neo_peripheral_collectors
        self.installer.sysinfo.device_class = "j314sap"
        with patch("omarchy_asahi.omarchy_als.read_lsci", side_effect=AssertionError("not Neo")):
            with _neo_peripheral_collectors(self.installer):
                self.assertIs(self.stub.AlsFWCollection, self.original_als)
                self.assertIs(self.stub.ISPFWCollection, self.original_isp)
                self.assertIs(self.stub.subprocess, self.process)

    def test_missing_als_stops_collection(self):
        from omarchy_asahi import _neo_peripheral_collectors
        with patch("omarchy_asahi.omarchy_als.read_lsci", side_effect=ValueError("no LSCI")):
            with self.assertRaisesRegex(AsahiAdapterError, "no LSCI"):
                with _neo_peripheral_collectors(self.installer):
                    self.fail("continued without ALS")

    def test_final_manifest_requires_trackpad_and_preserves_hardlink_files(self):
        from omarchy_asahi import _validate_neo_firmware_package
        manifest = ["FILE " + name + " SHA256 dummy" for name in self.names]
        manifest.append("FILE apple/j700-aop-als-cal.bin SHA256 dummy")
        package = SimpleNamespace(manifest=manifest)
        with self.assertRaisesRegex(AsahiAdapterError, "tpmtfw-j700"):
            _validate_neo_firmware_package(package)
        manifest.append("LINK apple/tpmtfw-j700.bin other-trackpad.bin")
        _validate_neo_firmware_package(package)


class NeoRadioFirmwareTests(unittest.TestCase):
    """The MacBook Neo's MT7932 inputs join its vendor firmware package."""

    import omarchy_mt7932 as radio
    files = {
        "mediatek/mt7932/" + name: name.encode() for name in (
            radio.WIFI_PATCH, radio.WIFI_RAM, "ppr.bin", "oca2.bin", "wcal.bin", "config-original.bin"
        )
    }
    files.update({"mediatek/" + name: name.encode() for name in radio.BT_FIRMWARE})
    files.update({"mediatek/" + name: name.encode() for name in (
        radio.BT_PTX, "j700-mt7932-btcal.bin", "j700-mt7932-bdaddr.bin"
    )})

    def run_hook(self, device_class, collect, required=True):
        package = SimpleNamespace(added=[])
        package.add_file = lambda name, data: package.added.append((name, data))
        installer = SimpleNamespace(sysinfo=SimpleNamespace(device_class=device_class))
        firmware = SimpleNamespace(core=SimpleNamespace(FWFile=lambda name, data: ("FWFile", name, data)))
        with patch("omarchy_asahi.asahi_firmware", firmware):
            _collect_neo_radios(installer, package, collect=collect, required=required)
        return package.added

    def test_a_neo_adds_every_collected_file(self):
        added = self.run_hook("j700ap", lambda: self.files)
        self.assertEqual(added, [
            (name, ("FWFile", name, data)) for name, data in sorted(self.files.items())
        ])

    def test_other_macs_collect_nothing(self):
        def collect():
            raise AssertionError("collected on a Mac that is not a Neo")
        self.assertEqual(self.run_hook("j613ap", collect), [])

    def test_a_failed_collection_stops_installation(self):
        import omarchy_mt7932

        def collect():
            raise omarchy_mt7932.Mt7932Error("the factory BWC2 record has no WCAL")
        with self.assertRaisesRegex(AsahiAdapterError, "no WCAL"):
            self.run_hook("j700ap", collect)

    def test_a_partial_or_empty_radio_package_is_rejected(self):
        for missing in self.files:
            partial = dict(self.files)
            partial[missing] = b""
            with self.subTest(missing=missing), self.assertRaisesRegex(AsahiAdapterError, "missing required"):
                self.run_hook("j700ap", lambda: partial)

class NeoTouchIdCalibrationTests(unittest.TestCase):
    """The MacBook Neo's FSC2 calibration joins its vendor firmware package."""

    def run_hook(self, device_class, collect, partitions=None, sensor_present=lambda: True, required=True):
        package = SimpleNamespace(added=[])
        package.add_file = lambda name, data: package.added.append((name, data))
        dutil = SimpleNamespace(
            find_system_disk=lambda: "disk0",
            disk_parts={"disk0": {"Partitions": partitions or [
                {"Content": "Apple_APFS_ISC", "DeviceIdentifier": "disk0s1"},
                {"Content": "Apple_APFS", "DeviceIdentifier": "disk0s2"},
            ]}},
        )
        installer = SimpleNamespace(sysinfo=SimpleNamespace(device_class=device_class), dutil=dutil)
        firmware = SimpleNamespace(core=SimpleNamespace(FWFile=lambda name, data: ("FWFile", name, data)))
        with patch("omarchy_asahi.asahi_firmware", firmware):
            _collect_neo_touch_id(installer, package, collect=collect, sensor_present=sensor_present, required=required)
        return package.added

    def test_a_neo_reads_the_raw_iboot_system_container(self):
        devices = []

        def collect(device):
            devices.append(device)
            return {"apple/mesacal-j700.bin": b"img4"}

        self.assertEqual(self.run_hook("j700ap", collect), [
            ("apple/mesacal-j700.bin", ("FWFile", "apple/mesacal-j700.bin", b"img4")),
        ])
        self.assertEqual(devices, ["/dev/rdisk0s1"])

    def test_other_macs_collect_nothing(self):
        self.assertEqual(self.run_hook("j613ap", lambda device: self.fail("read the container")), [])

    def test_a_failed_collection_stops_installation(self):
        import omarchy_mesa

        def collect(device):
            raise omarchy_mesa.MesaError("expected one signed FSC2 calibration, found 0")

        with self.assertRaisesRegex(AsahiAdapterError, "found 0"):
            self.run_hook("j700ap", collect)

    def test_unqualified_touch_id_does_not_block_os_installation(self):
        import omarchy_mesa
        def collect(device):
            raise omarchy_mesa.MesaError("no calibration")
        with self.assertLogs(level="WARNING"):
            self.assertEqual(self.run_hook("j700ap", collect, required=False), [])

    def test_no_builtin_sensor_skips_the_raw_container(self):
        self.assertEqual(self.run_hook("j700ap", lambda device: self.fail("read container"),
                                      sensor_present=lambda: False), [])

    def test_sensor_detection_error_is_not_treated_as_absence(self):
        def detect():
            raise OSError("ioreg failed")
        with self.assertRaisesRegex(AsahiAdapterError, "ioreg failed"):
            self.run_hook("j700ap", lambda device: self.fail("read container"), sensor_present=detect)

    def test_present_sensor_requires_nonempty_calibration(self):
        with self.assertRaisesRegex(AsahiAdapterError, "calibration is missing"):
            self.run_hook("j700ap", lambda device: {})

    def test_a_disk_without_its_container_first_is_not_read(self):
        partitions = [{"Content": "Apple_APFS", "DeviceIdentifier": "disk0s1"}]
        with self.assertRaisesRegex(AsahiAdapterError, "does not start"):
            self.run_hook("j700ap", lambda device: self.fail("read"), partitions)


if __name__ == "__main__":
    unittest.main()
