# SPDX-License-Identifier: MIT
from pathlib import Path
import struct
import sys
import tempfile
from types import SimpleNamespace
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
import omarchy_isp as isp

LEGACY = isp.SetFile(0x248, 0x18200103, "1820_01XX", 0x442C)
IMX558_1921 = isp.SetFile(0x558, 0x19210106, "1921_01XX", 0xAD40)


def blob(entry, fill=0):
    data = bytearray([fill] * ((entry.size + 63) & ~63))
    struct.pack_into(">8I", data, 0, entry.magic, 1, 0, 0, 0x1000000, 0x10000, 0, 0x3C00000)
    return bytes(data)


class IspTests(unittest.TestCase):
    def test_extends_registry_without_changing_inherited_entries(self):
        custom = isp.SetFile(1, 0xABCD1234, "future_01XX", 100)
        result = isp.extended_setfiles([LEGACY, IMX558_1921, custom])
        self.assertEqual(result, (LEGACY, IMX558_1921, custom, isp.IMX558_1925))
        self.assertEqual(isp.extended_setfiles(result), result)
        with self.assertRaises(isp.IspError):
            isp.extended_setfiles([isp.IMX558_1925._replace(size=64)])

    def test_extracts_1925_full_kernel_size(self):
        data = blob(isp.IMX558_1925, 0xAB)
        output = isp.extract(bytes(4096) + data, [LEGACY])
        self.assertEqual(output, {"apple/isp_1925_03XX.dat": data})
        self.assertEqual(len(next(iter(output.values()))), 52160)

    def test_both_daemons_and_legacy_only_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            (directory / "appleh13camerad").write_bytes(blob(LEGACY))
            self.assertEqual(isp.collect(tmp, [LEGACY]), {"apple/isp_1820_01XX.dat": blob(LEGACY)})
            (directory / "appleh16camerad").write_bytes(blob(isp.IMX558_1925))
            self.assertEqual(set(isp.collect(tmp, [LEGACY])),
                             {"apple/isp_1820_01XX.dat", "apple/isp_1925_03XX.dat"})

    def test_h16_only_and_single_file_paths(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "appleh16camerad"
            path.write_bytes(blob(isp.IMX558_1925))
            self.assertEqual(isp.collect(path, []), isp.collect(tmp, []))
            self.assertTrue(isp.collect(tmp, []))

    def test_deduplicates_identical_and_rejects_conflicting_copies(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths = [Path(tmp) / name for name in isp.DAEMON_NAMES]
            for path in paths:
                path.write_bytes(blob(LEGACY))
            self.assertEqual(len(isp.collect(tmp, [LEGACY])), 1)
            paths[1].write_bytes(blob(LEGACY, 2))
            with self.assertRaisesRegex(isp.IspError, "conflicting copies"):
                isp.collect(tmp, [LEGACY])

    def test_truncated_known_setfile_never_published(self):
        for entry in (LEGACY, isp.IMX558_1925):
            with self.subTest(entry=entry), self.assertRaisesRegex(isp.IspError, "truncated"):
                isp.extract(blob(entry)[:-1], [LEGACY])

    def test_bad_header_unknown_magic_and_unaligned_match_ignored(self):
        for word in (2, 3, 4, 5, 6, 7):
            data = bytearray(blob(LEGACY))
            struct.pack_into(">I", data, word * 4, 1)
            self.assertEqual(isp.extract(data, [LEGACY]), {})
        self.assertEqual(isp.extract(blob(LEGACY._replace(magic=0x99999999)), [LEGACY]), {})
        self.assertEqual(isp.extract(b"x" + blob(LEGACY), [LEGACY]), {})
        self.assertEqual(isp.extract(bytes(31), [LEGACY]), {})

    def test_collection_preserves_FWFile_interface(self):
        class FWFile:
            def __init__(self, name, data):
                self.name, self.data = name, data

        class Original:
            def __init__(self, source):
                self.fwfiles = []
                self.load(source)

            def files(self):
                return self.fwfiles

        upstream = SimpleNamespace(ISP_SETFILES=[LEGACY], FWFile=FWFile, ISPFWCollection=Original)
        collection = isp.collection_class(upstream)
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "appleh16camerad").write_bytes(blob(isp.IMX558_1925))
            name, firmware = collection(tmp).files()[0]
            self.assertIsInstance(firmware, FWFile)
            self.assertEqual(name, firmware.name)
            self.assertEqual(firmware.data, blob(isp.IMX558_1925))


if __name__ == "__main__":
    unittest.main()
