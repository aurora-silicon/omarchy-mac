# SPDX-License-Identifier: MIT
import os
from pathlib import Path
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'src'))
import omarchy_mt7932 as mt  # noqa: E402


def der(tag, content):
    """A DER element; `tag` is its tag bytes, so high-tag-number forms fit."""
    length = len(content)
    if length < 0x80:
        size = bytes([length])
    else:
        encoded = length.to_bytes((length.bit_length() + 7) // 8, 'big')
        size = bytes([0x80 | len(encoded)]) + encoded
    return tag + size + content


def ia5(text):
    return der(b'\x16', text)


def field(name, blob):
    """A BWC2 field: its tag as a little-endian INTEGER, ".", the bytes."""
    return der(b'\x30', der(b'\x02', name[::-1]) + ia5(b'.') + der(b'\x04', blob))


def bwc2(fields):
    """An IMG4 shaped like the Neo's factory BWC2 record.

    `fields` maps tags to bytes, or lists (tag, bytes) pairs to allow repeats.
    """
    pairs = fields.items() if isinstance(fields, dict) else fields
    # Apple keys the field set with a high-tag-number element, as BWC2 does.
    keyed = der(b'\xff\x85\x9a\xc1\x82\x59', der(b'\x31', b''.join(field(n, b) for n, b in pairs)))
    payload = der(b'\x30', der(b'\x02', b'2CWB') + der(b'\x02', b'\x03\x00\x03\x00') + keyed)
    im4p = der(b'\x30', ia5(b'IM4P') + ia5(b'BWC2') + ia5(b'1.0') + der(b'\x04', payload))
    manifest = der(b'\xa0', der(b'\x30', ia5(b'IM4M')))
    return der(b'\x30', ia5(b'IMG4') + im4p + manifest)


def oca2(entries=((0x1001, b'a' * 20), (0x2001, b'b' * 30))):
    """A big-endian BLOB that passes the driver's mt7932_cal_validate()."""
    end = 16 + 20 * len(entries)
    records, bodies, offset = b'', b'', end
    for kind, body in entries:
        length = 8 + len(body)
        chunk = struct.pack('>HHI', kind, 12, length) + body
        records += struct.pack('>HHIII', kind, 12, offset, length, sum(chunk)) + b'\0' * 4
        bodies += chunk
        offset += length
    return b'BLOB' + struct.pack('>IHH', end, 12, len(entries)) + b'\0' * 4 + records + bodies


def ptx():
    """A 198-byte little-endian BLOB that passes bt7932_validate_ptx()."""
    sections = ((0x101, b'p' * 14), (0x201, b'q' * 44), (0x301, b'r' * 44), (0x401, b''))
    records, bodies, offset = b'', b'', 96
    for kind, body in sections:
        records += struct.pack('<IIIII', kind, offset, len(body), sum(body), 0)
        bodies += body
        offset += len(body)
    return b'BLOB' + struct.pack('<IHHI', 96, 1, 4, 0) + records + bodies


def config(count=64, without=()):
    keys = ['Sta5gBw', 'DisRoaming'] + [f'Key{n}' for n in range(count - 2)]
    lines = ['#Qos 0', ''] + [f'{key} {n % 3}' for n, key in enumerate(keys) if key not in without]
    return '\n'.join(lines) + '\n'


def bluetooth_firmware(trailer=mt.BT_TRAILER):
    return b'\x01' * 64 + b'\0' * 16 + trailer + b'\0' * 8


class Bwc2Tests(unittest.TestCase):
    def test_fields_come_out_by_their_tags(self):
        fields = mt.bwc2_fields(bwc2({b'OCA2': b'one', b'WCAL': b'two', b'BCAL': b'three'}))
        self.assertEqual(fields, {'OCA2': b'one', 'WCAL': b'two', 'BCAL': b'three'})

    def test_another_record_type_is_refused(self):
        image = bwc2({b'OCA2': b'one'}).replace(b'BWC2', b'FSC2', 1)
        with self.assertRaisesRegex(mt.Mt7932Error, 'not of type BWC2'):
            mt.bwc2_fields(image)

    def test_a_truncated_record_is_refused(self):
        with self.assertRaises(mt.Mt7932Error):
            mt.bwc2_fields(bwc2({b'OCA2': b'one'})[:-20])

    def test_a_repeated_field_is_refused(self):
        with self.assertRaisesRegex(mt.Mt7932Error, 'OCA2 twice'):
            mt.bwc2_fields(bwc2([(b'OCA2', b'one'), (b'OCA2', b'two')]))


class Oca2Tests(unittest.TestCase):
    def test_a_well_formed_blob_passes(self):
        mt.validate_oca2(oca2())

    def test_a_bad_checksum_is_refused(self):
        blob = bytearray(oca2())
        blob[-1] ^= 1
        with self.assertRaisesRegex(mt.Mt7932Error, 'checksum'):
            mt.validate_oca2(bytes(blob))

    def test_a_little_endian_blob_is_refused(self):
        with self.assertRaisesRegex(mt.Mt7932Error, 'inconsistent'):
            mt.validate_oca2(b'BLOB' + struct.pack('<IHH', 36, 12, 1) + b'\0' * 40)

    def test_repeated_kinds_are_refused(self):
        with self.assertRaisesRegex(mt.Mt7932Error, 'repeats or overlaps'):
            mt.validate_oca2(oca2(((0x1001, b'a' * 20), (0x1001, b'b' * 20))))


class ConfigTests(unittest.TestCase):
    def test_settings_become_68_byte_records(self):
        package = mt.j7cf(config())
        self.assertEqual(package[:4], b'J7CF')
        self.assertEqual(struct.unpack_from('<I', package, 4)[0], 64)
        self.assertEqual(len(package), 8 + 64 * 68)
        kind, key_len, value_len, reserved, key, value = mt.J7CF_RECORD.unpack_from(package, 8)
        self.assertEqual((kind, key_len, value_len, reserved), (3, 7, 1, 0))
        self.assertEqual(key.rstrip(b'\0'), b'Sta5gBw')
        self.assertEqual(value.rstrip(b'\0'), b'0')

    def test_only_64_or_65_settings_fit(self):
        mt.j7cf(config(65))
        with self.assertRaisesRegex(mt.Mt7932Error, '63 settings'):
            mt.j7cf(config(63))

    def test_the_settings_the_driver_rewrites_must_exist(self):
        with self.assertRaisesRegex(mt.Mt7932Error, 'no DisRoaming'):
            mt.j7cf(config(65, without=('DisRoaming',)))

    def test_a_repeated_setting_is_refused(self):
        with self.assertRaisesRegex(mt.Mt7932Error, 'twice'):
            mt.j7cf(config() + 'Sta5gBw 1\n')


class BluetoothTests(unittest.TestCase):
    def test_the_ptx_checks_pass(self):
        mt.validate_ptx(ptx())

    def test_a_changed_ptx_is_refused(self):
        blob = bytearray(ptx())
        blob[100] ^= 1
        with self.assertRaisesRegex(mt.Mt7932Error, 'checksum'):
            mt.validate_ptx(bytes(blob))

    def test_firmware_needs_its_alps_trailer(self):
        mt.validate_bluetooth_firmware(bluetooth_firmware())
        with self.assertRaisesRegex(mt.Mt7932Error, 'ALPS'):
            mt.validate_bluetooth_firmware(bluetooth_firmware(b'XXXX\x8a\x10\x8a\x10'))

    def test_the_address_is_taken_as_the_device_tree_gives_it(self):
        self.assertEqual(mt.bluetooth_address({'mac-address-bluetooth0': b'\x01\x02\x03\x04\x05\x06'}),
                         b'\x01\x02\x03\x04\x05\x06')
        for unusable in (b'', b'\0' * 6, b'\xff' * 6, b'\x01' * 5):
            with self.assertRaises(mt.Mt7932Error):
                mt.bluetooth_address({'mac-address-bluetooth0': unusable})


class CollectTests(unittest.TestCase):
    """collect() over a macOS tree laid out as on the Neo (macOS 26.6)."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.wcal = b'BLOB' + b'w' * 764
        self.bcal = b'BLOB' + b'c' * 384
        self.write(mt.IZUBA, mt.WIFI_PATCH, b'patch')
        self.write(mt.IZUBA, mt.WIFI_RAM, b'ram')
        self.write(mt.IZUBA, 'IZUBA_PPR_MT7932.bin', b'BLOB' + b'p' * 408)
        self.write(mt.IZUBA, 'IZUBA_wifi.cfg', config().encode())
        self.write(mt.FACTORY_DATA, 'BWC2-00008140-0000',
                   bwc2({b'OCA2': oca2(), b'WCAL': self.wcal, b'BCAL': self.bcal, b'OCAL': b'older'}))
        for name in mt.BT_FIRMWARE:
            self.write(mt.BLUETOOTH, name, bluetooth_firmware())
        self.write(mt.BLUETOOTH, mt.BT_PTX, ptx())
        self.chosen = {'mac-address-bluetooth0': b'\x01\x02\x03\x04\x05\x06'}

    def write(self, folder, name, data):
        path = self.root / folder / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def test_every_input_but_the_country_policy_is_collected(self):
        files = mt.collect(str(self.root), chosen=self.chosen)
        self.assertEqual(sorted(files), sorted([
            'mediatek/mt7932/IZUBA_WIFI_MT7932_patch_mcu_1_2_hdr.bin',
            'mediatek/mt7932/IZUBA_W7932_2.bin',
            'mediatek/mt7932/ppr.bin',
            'mediatek/mt7932/oca2.bin',
            'mediatek/mt7932/wcal.bin',
            'mediatek/mt7932/config-original.bin',
            'mediatek/MT7932B0_OS_TypeB_0.1.44.0_241001003711.bin',
            'mediatek/MT7932B1_OS_TypeB_0.1.133.0_260128190103.bin',
            'mediatek/MT7932_PTB_IzubaA_0.1.0.0_20251021141303.ptx',
            'mediatek/j700-mt7932-btcal.bin',
            'mediatek/j700-mt7932-bdaddr.bin',
        ]))
        self.assertEqual(files['mediatek/mt7932/wcal.bin'], self.wcal)
        self.assertEqual(files['mediatek/j700-mt7932-btcal.bin'], self.bcal)
        self.assertEqual(files['mediatek/mt7932/oca2.bin'], oca2())
        self.assertFalse(any('policy' in name for name in files))

    def test_a_ppr_of_another_size_is_refused(self):
        self.write(mt.IZUBA, 'IZUBA_PPR_MT7932.bin', b'BLOB' + b'p' * 400)
        with self.assertRaisesRegex(mt.Mt7932Error, '412-byte'):
            mt.collect(str(self.root), chosen=self.chosen)

    def test_a_missing_factory_record_is_refused(self):
        for record in (self.root / mt.FACTORY_DATA).glob('BWC2-*'):
            os.remove(record)
        with self.assertRaisesRegex(mt.Mt7932Error, 'found 0'):
            mt.collect(str(self.root), chosen=self.chosen)

    def test_a_corrupt_calibration_is_refused(self):
        blob = bytearray(oca2())
        blob[-1] ^= 1
        self.write(mt.FACTORY_DATA, 'BWC2-00008140-0000',
                   bwc2({b'OCA2': bytes(blob), b'WCAL': self.wcal, b'BCAL': self.bcal}))
        with self.assertRaisesRegex(mt.Mt7932Error, 'checksum'):
            mt.collect(str(self.root), chosen=self.chosen)


if __name__ == '__main__':
    unittest.main()
