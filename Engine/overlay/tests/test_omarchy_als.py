# SPDX-License-Identifier: MIT
from pathlib import Path
import plistlib
import struct
import subprocess
import sys
from types import SimpleNamespace
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
import omarchy_als as als


def lsci():
    data = bytearray(156)
    data[:2] = b"\x05\x04"
    struct.pack_into("<H", data, 4, 156)
    struct.pack_into("<5i", data, 28, 32768, 65536, 16384, -8192, 131072)
    for offset, value in zip((58, 62, 66, 60, 64, 68), (2040, 4080, 32640, 1785, 3825, 32385)):
        struct.pack_into("<h", data, offset, value)
    return bytes(data)


def plist(records=None):
    if records is None:
        records = [{"IORegistryEntryName": "exbright", "LSCI": lsci()}]
    return plistlib.dumps(records)


class AlsTests(unittest.TestCase):
    def test_aop_abi_and_per_step_not_cumulative_gains(self):
        data = als.calibration(lsci())
        self.assertEqual(len(data), 80)
        self.assertEqual(struct.unpack_from("<QQ", data), (0x0746B8D665152E31, 56))
        self.assertEqual(
            struct.unpack_from("<14f", data, 16),
            (0.5, 1.0, 0.25, -0.125, 2.0, 1.0, 1.0, 8.0, 16.0, 128.0, 1.0, 7.0, 15.0, 127.0),
        )
        self.assertEqual(data[-8:], bytes(8))

    def test_distinct_devices_produce_distinct_coefficients(self):
        changed = bytearray(lsci())
        struct.pack_into("<i", changed, 28, 65536)
        self.assertNotEqual(als.calibration(lsci()), als.calibration(bytes(changed)))

    def test_rejects_unknown_version_length_size_and_bad_gains(self):
        cases = [b"", lsci()[:-1], lsci() + b"\0", "not bytes"]
        for offset, replacement in ((0, b"\x06"), (1, b"\x05"), (4, b"\x98"), (58, b"\0\0"), (60, b"\xff\xff")):
            changed = bytearray(lsci())
            changed[offset:offset + len(replacement)] = replacement
            cases.append(bytes(changed))
        for data in cases:
            with self.subTest(data=str(data)[:60]), self.assertRaises(als.AlsError):
                als.calibration(data)

    def test_searches_actual_node_not_fixed_descendant_indexes(self):
        child = {"IORegistryEntryName": "exbright", "LSCI": lsci()}
        data = plist([{"IORegistryEntryName": "root", "IORegistryEntryChildren": [child]}])
        self.assertEqual(als.from_ioreg(data), lsci())

    def test_rejects_malformed_absent_ambiguous_or_wrong_node(self):
        child = {"IORegistryEntryName": "exbright", "LSCI": lsci()}
        cases = [b"not plist", b"<?xml version='1.0'?><plist><", plist([]), plist([child, child]),
                 plist([{"IORegistryEntryName": "other", "LSCI": lsci()}]),
                 plist({"IORegistryEntryName": "exbright", "LSCI": lsci()}),
                 plist([{"IORegistryEntryChildren": "bad"}]), plist([17])]
        for data in cases:
            with self.subTest(data=data[:40]), self.assertRaises(als.AlsError):
                als.from_ioreg(data)

    def test_collect_reads_host_and_correct_kernel_filename(self):
        calls = []

        def run(args, **kwargs):
            calls.append((args, kwargs))
            return SimpleNamespace(stdout=plist())

        self.assertEqual(als.collect(run), {"apple/j700-aop-als-cal.bin": als.calibration(lsci())})
        self.assertEqual(calls, [(["/usr/sbin/ioreg", "-r", "-a", "-n", "exbright", "-l"],
                                  {"capture_output": True, "check": True})])

    def test_ioreg_failure_is_not_silent_success(self):
        def run(*args, **kwargs):
            raise subprocess.CalledProcessError(1, args[0])

        with self.assertRaises(subprocess.CalledProcessError):
            als.collect(run)


if __name__ == "__main__":
    unittest.main()
