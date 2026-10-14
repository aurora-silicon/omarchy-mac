#!/usr/bin/env python3
"""Cold Bluetooth admission through isolated firmware/sysfs and recording tools."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'firmware-ordering'
FIRMWARE = (
    'mediatek/MT7932B0_OS_TypeB_0.1.44.0_241001003711.bin',
    'mediatek/MT7932_PTB_IzubaA_0.1.0.0_20251021141303.ptx',
    'mediatek/j700-mt7932-btcal.bin', 'mediatek/j700-mt7932-bdaddr.bin',
    'mediatek/MT7932B1_OS_TypeB_0.1.133.0_260128190103.bin',
)


class BluetoothAdmissionTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.compatible = self.root / 'sys/firmware/devicetree/base/compatible'
        self.compatible.parent.mkdir(parents=True)
        self.compatible.write_bytes(b'apple,j700\0')
        self.device = self.root / 'sys/bus/pci/devices/0000:01:00.1'
        self.device.mkdir(parents=True)
        self.wifi = self.root / 'sys/bus/pci/devices/0000:01:00.0'
        self.wifi.mkdir()
        (self.root / 'wifi-driver').mkdir()
        (self.wifi / 'driver').symlink_to(self.root / 'wifi-driver')
        (self.device / 'vendor').write_text('0x14c3\n')
        (self.device / 'device').write_text('0x793b\n')
        self.gate = self.root / 'sys/module/mt7932_bt_pcie/parameters/enable'
        self.gate.parent.mkdir(parents=True)
        self.probes = self.root / 'sys/bus/pci/drivers_probe'
        self.probes.write_text('')
        self.calls = self.root / 'calls'
        self.firmware = self.root / 'firmware/vendor'
        for name in FIRMWARE:
            path = self.firmware / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'isolated firmware fixture')
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        shim = self.bin / 'modprobe'
        shim.write_text('''#!/bin/bash
printf '%s\\n' "$*" >> "$BT_TEST_CALLS"
[[ -e $BT_TEST_GATE ]] || printf 'N\\n' > "$BT_TEST_GATE"
if [[ ${BT_TEST_BIND_AFTER_LOAD:-0} == "1" ]]; then
  ln -s /fixture-driver "$BT_TEST_DEVICE/driver"
fi
''')
        shim.chmod(0o755)
        helper = (SOURCE / 'aurora-j700-bluetooth-admit').read_text()
        helper = helper.replace('/sys/', str(self.root / 'sys') + '/')
        helper = helper.replace('/lib/firmware', str(self.root / 'firmware'))
        self.helper = self.root / 'helper'
        self.helper.write_text(helper)

    def run_helper(self, bind_after_load=False):
        return subprocess.run(['bash', str(self.helper)], capture_output=True, text=True,
            env=dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                     BT_TEST_CALLS=str(self.calls), BT_TEST_GATE=str(self.gate),
                     BT_TEST_DEVICE=str(self.device), BT_TEST_BIND_AFTER_LOAD=str(int(bind_after_load))))

    def assert_untouched(self):
        self.assertFalse(self.calls.exists())
        self.assertEqual(self.probes.read_text(), '')

    def test_cold_unbound_radio_is_admitted_once_after_firmware(self):
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls.read_text(), 'mt7932_bt_pcie enable=0\n')
        self.assertEqual(self.gate.read_text(), '1\n')
        self.assertEqual(self.probes.read_text(), '0000:01:00.1\n')
        (self.device / 'driver').symlink_to('/fixture-driver')
        self.assertEqual(self.run_helper().returncode, 0)
        self.assertEqual(self.calls.read_text(), 'mt7932_bt_pcie enable=0\n')

    def test_every_missing_bluetooth_input_defers_before_module_load(self):
        for name in FIRMWARE:
            with self.subTest(name=name):
                path = self.firmware / name
                data = path.read_bytes()
                path.unlink()
                result = self.run_helper()
                self.assertNotEqual(result.returncode, 0)
                self.assert_untouched()
                path.write_bytes(data)

    def test_new_public_driver_b1_primary_is_accepted_without_fallback(self):
        (self.firmware / FIRMWARE[-1]).unlink()
        (self.firmware / 'mediatek/MT7932B1_OS_TypeB_2.0.177.0_260706180356.bin').write_bytes(b'primary')
        self.assertEqual(self.run_helper().returncode, 0)

    def test_other_board_or_wrong_chip_does_not_touch_hardware(self):
        self.compatible.write_bytes(b'apple,j313\0')
        self.assertEqual(self.run_helper().returncode, 0)
        self.assert_untouched()
        self.compatible.write_bytes(b'apple,j700\0')
        (self.device / 'vendor').write_text('0x14e4\n')
        self.assertEqual(self.run_helper().returncode, 0)
        self.assert_untouched()

    def test_already_bound_radio_is_never_reprobed(self):
        (self.device / 'driver').symlink_to('/fixture-driver')
        self.assertEqual(self.run_helper().returncode, 0)
        self.assert_untouched()

    def test_already_enabled_unbound_radio_is_never_reprobed(self):
        self.gate.write_text('Y\n')
        result = self.run_helper()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('cold reboot', result.stderr)
        self.assert_untouched()

    def test_missing_wifi_binding_prevents_bluetooth_admission(self):
        (self.wifi / 'driver').unlink()
        self.assertNotEqual(self.run_helper().returncode, 0)
        self.assert_untouched()

    def test_binding_during_module_load_prevents_a_second_probe(self):
        result = self.run_helper(bind_after_load=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.probes.read_text(), '')
        self.assertEqual(self.gate.read_text(), 'N\n')


if __name__ == '__main__':
    unittest.main()
