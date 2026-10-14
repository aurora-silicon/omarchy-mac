#!/usr/bin/env python3
"""Firmware admission uses isolated files and a recording modprobe, never hardware."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'firmware-ordering'
J700_FILES = (
    'apple/j700-aop-als-cal.bin', 'apple/tpmtfw-j700.bin',
    'mediatek/mt7932/IZUBA_WIFI_MT7932_patch_mcu_1_2_hdr.bin', 'mediatek/mt7932/IZUBA_W7932_2.bin',
    'mediatek/mt7932/ppr.bin', 'mediatek/mt7932/oca2.bin', 'mediatek/mt7932/wcal.bin',
    'mediatek/mt7932/config-original.bin', 'mediatek/MT7932B0_OS_TypeB_0.1.44.0_241001003711.bin',
    'mediatek/MT7932B1_OS_TypeB_0.1.133.0_260128190103.bin',
    'mediatek/MT7932_PTB_IzubaA_0.1.0.0_20251021141303.ptx',
    'mediatek/j700-mt7932-btcal.bin', 'mediatek/j700-mt7932-bdaddr.bin',
    'mediatek/mt7932/policy/world-XZ.bin',
)


class FirmwareOrderingTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.firmware = self.root / 'firmware'
        self.compatible = self.root / 'sys/base/compatible'
        self.compatible.parent.mkdir(parents=True)
        self.compatible.write_bytes(b'apple,j700\0')
        self.calls = self.root / 'modprobe-calls'
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        modprobe = self.bin / 'modprobe'
        modprobe.write_text('#!/bin/bash\nprintf "%s\\n" "$*" >> "$FIRMWARE_TEST_CALLS"\n')
        modprobe.chmod(0o755)
        # Redirect only file reads in the test copy. The production script
        # retains its fixed paths and has no test/approval activation flag.
        script = (SOURCE / 'aurora-peripheral-firmware.sh').read_text()
        script = script.replace('/lib/firmware', str(self.firmware))
        script = script.replace('/sys/firmware/devicetree', str(self.root / 'sys'))
        self.helper = self.root / 'helper'
        self.helper.write_text(script)

    def complete_firmware(self):
        for name in J700_FILES:
            path = self.firmware / 'vendor' / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'isolated nonempty firmware fixture')

    def run_helper(self):
        return subprocess.run(['bash', str(self.helper)], capture_output=True, text=True,
            env=dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                     FIRMWARE_TEST_CALLS=str(self.calls)))

    def test_every_missing_j700_input_prevents_all_probe(self):
        self.complete_firmware()
        for name in J700_FILES:
            with self.subTest(name=name):
                path = self.firmware / 'vendor' / name
                content = path.read_bytes()
                path.unlink()
                result = self.run_helper()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(name, result.stderr)
                self.assertFalse(self.calls.exists())
                path.write_bytes(content)

    def test_complete_j700_firmware_loads_peripherals_without_sep_or_reload(self):
        self.complete_firmware()
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls.read_text(), 'aop\nmt7932-fullmac\n')

    def test_other_mac_does_not_require_j700_calibration_or_load_its_wifi(self):
        self.compatible.write_bytes(b'apple,j313\0')
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls.read_text(), 'aop\n')

    def run_hook(self, with_sep):
        alias = self.root / 'aurora-sep-firmware-order.conf'
        if with_sep:
            alias.write_text('blacklist apple_sep\n')
        hook = self.root / 'hook'
        hook.write_text((SOURCE / 'aurora-vendor-order.install').read_text().replace(
                       '/usr/lib/modprobe.d/aurora-sep-firmware-order.conf', str(alias)))
        script = '''add_binary() { :; }; add_module() { :; }; add_symlink() { :; }
add_file() { printf '%s\\n' "$1"; }
source "$1"
build
'''
        result = subprocess.run(['bash', '-c', script, 'hook-fixture', str(hook)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.splitlines(), str(alias)

    def test_existing_initrd_hook_carries_installed_sep_alias_blacklist(self):
        files, alias = self.run_hook(with_sep=True)
        self.assertIn(alias, files)

    def test_generic_initrd_hook_keeps_working_without_optional_sep_package(self):
        files, alias = self.run_hook(with_sep=False)
        self.assertNotIn(alias, files)
        self.assertIn('/usr/lib/omarchy/initcpio/aurora-peripheral-firmware.sh', files)

    def test_sep_unit_dropin_only_orders_sep_after_normal_vendor_firmware(self):
        self.assertEqual((SOURCE / '50-aurora-sep-vendor-firmware.conf').read_text(),
                         '[Unit]\nRequires=omarchy-vendor-firmware.service\nAfter=omarchy-vendor-firmware.service\n')


if __name__ == '__main__':
    unittest.main()
