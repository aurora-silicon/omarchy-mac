"""Collect the MacBook Neo's MediaTek MT7932 radio inputs from macOS.

aurora-silicon/linux's mt7932-fullmac (Wi-Fi) and mt7932_bt_pcie (Bluetooth)
drivers, merged into aurora-wip by 3bb0a6104a11, load these from
/lib/firmware; Documentation/networking/device_drivers/wifi/mt7932-neo.rst
lists them. Each comes from this Mac's own macOS:

- the Wi-Fi firmware and ppr.bin: the AppleSunriseWLAN driver extension;
- oca2.bin, wcal.bin and the Bluetooth calibration: the OCA2, WCAL and BCAL
  fields of the factory BWC2 record, a signed IMG4 unique to this Mac;
- config-original.bin (J7CF): the driver extension's IZUBA_wifi.cfg;
- the Bluetooth firmware and PTX: /usr/share/firmware/bluetooth;
- the Bluetooth address: the device tree's /chosen.

The country policy (policy/world-XZ.bin, J7RP) is not derived here yet, so
Wi-Fi does not start without it; Bluetooth does not need it.

Every output is checked the way the drivers check it before it is used.
"""

import glob
import os
import plistlib
import struct
import subprocess

IZUBA = "System/Library/DriverExtensions/com.apple.AppleSunriseWLAN.dext/IZUBA"
FACTORY_DATA = "System/Volumes/Hardware/FactoryData/System/Library/Caches/com.apple.factorydata"
BLUETOOTH = "usr/share/firmware/bluetooth"

WIFI_PATCH = "IZUBA_WIFI_MT7932_patch_mcu_1_2_hdr.bin"
WIFI_RAM = "IZUBA_W7932_2.bin"
# The driver loads B0 or B1 by the chip's ROM; for B1 it prefers a newer
# build that macOS 26.6 does not ship, then this one.
BT_FIRMWARE = (
    "MT7932B0_OS_TypeB_0.1.44.0_241001003711.bin",
    "MT7932B1_OS_TypeB_0.1.133.0_260128190103.bin",
)
BT_TRAILER = b"ALPS\x8a\x10\x8a\x10"
BT_PTX = "MT7932_PTB_IzubaA_0.1.0.0_20251021141303.ptx"

PPR_BYTES = 412
WCAL_MAXIMUM = 1024
BTCAL_MAXIMUM = 0xFFFF
J7CF_RECORD = struct.Struct("<BBBB32s32s")


class Mt7932Error(RuntimeError):
    pass


def _tlv(data, at):
    """One DER element at `at`: (first tag byte, content start, end).

    Apple's records key some elements by four-letter tags encoded in DER's
    high-tag-number form, so the tag can run past its first byte.
    """
    if at + 2 > len(data):
        raise Mt7932Error("truncated DER element")
    tag, cursor = data[at], at + 1
    if tag & 0x1F == 0x1F:
        while cursor < len(data) and data[cursor] & 0x80:
            cursor += 1
        cursor += 1
    if cursor >= len(data):
        raise Mt7932Error("truncated DER tag")
    length = data[cursor]
    cursor += 1
    if length & 0x80:
        count = length & 0x7F
        if not 1 <= count <= 4 or cursor + count > len(data):
            raise Mt7932Error("bad DER length")
        length = int.from_bytes(data[cursor : cursor + count], "big")
        cursor += count
    header = cursor - at
    end = at + header + length
    if end > len(data):
        raise Mt7932Error("DER element runs past its container")
    return tag, at + header, end


def _children(data, start, end):
    while start < end:
        child = _tlv(data, start)
        yield child
        start = child[2]


def bwc2_fields(image):
    """The tagged fields of a BWC2 IMG4: {"OCA2": bytes, "WCAL": bytes, ...}.

    The IM4P payload is DER. Each field is a SEQUENCE of a four-byte INTEGER
    holding its tag in little-endian order, an IA5String and an OCTET STRING
    holding the field itself.
    """
    _, start, end = _tlv(image, 0)
    parts = list(_children(image, start, end))
    if not parts or image[parts[0][1] : parts[0][2]] != b"IMG4":
        raise Mt7932Error("BWC2 is not an IMG4")
    im4p = list(_children(image, parts[1][1], parts[1][2]))
    if [image[s:e] for _, s, e in im4p[:2]] != [b"IM4P", b"BWC2"]:
        raise Mt7932Error("BWC2's IM4P is not of type BWC2")
    payload = im4p[3]
    if payload[0] != 0x04:
        raise Mt7932Error("BWC2 has no payload")
    fields = {}

    def walk(start, end):
        for tag, cstart, cend in _children(image, start, end):
            if not tag & 0x20:
                continue
            inner = list(_children(image, cstart, cend))
            if (
                tag == 0x30
                and len(inner) == 3
                and inner[0][0] == 0x02
                and inner[0][2] - inner[0][1] == 4
                and inner[1][0] == 0x16
                and inner[2][0] == 0x04
            ):
                name = image[inner[0][1] : inner[0][2]][::-1].decode("ascii", "replace")
                if name in fields:
                    raise Mt7932Error(f"BWC2 holds {name} twice")
                fields[name] = bytes(image[inner[2][1] : inner[2][2]])
            else:
                walk(cstart, cend)

    walk(payload[1], payload[2])
    return fields


def validate_oca2(data):
    """mt7932_cal_validate() from the driver: a whole big-endian BLOB."""
    size = len(data)
    if size < 16 or size > 16 << 20 or data[:4] != b"BLOB":
        raise Mt7932Error("oca2 is not a BLOB")
    end, header, count = struct.unpack_from(">IHH", data, 4)
    if header != 12 or not count or end != 16 + 20 * count or end > size:
        raise Mt7932Error("oca2's BLOB header is inconsistent")
    spans = []
    for index in range(count):
        entry = data[16 + 20 * index : 36 + 20 * index]
        kind, entry_header, offset, length, checksum = struct.unpack_from(">HHIII", entry)
        if entry_header != 12 or offset < end or offset > size or length < 12 or length > size - offset:
            raise Mt7932Error(f"oca2 entry {index} is out of bounds")
        if data[offset : offset + 4] != entry[:4] or struct.unpack_from(">I", data, offset + 4)[0] != length:
            raise Mt7932Error(f"oca2 entry {index} does not match its record")
        if sum(data[offset : offset + length]) & 0xFFFFFFFF != checksum:
            raise Mt7932Error(f"oca2 entry {index} has a bad checksum")
        for prior_kind, start, bytes_ in spans:
            if prior_kind == kind or (offset < start + bytes_ and start < offset + length):
                raise Mt7932Error(f"oca2 entry {index} repeats or overlaps another")
        spans.append((kind, offset, length))


def validate_bluetooth_firmware(data):
    """bt7932_read_inputs(): a 32-byte trailer carrying the ALPS marker."""
    if len(data) <= 32 or data[-16:-8] != BT_TRAILER:
        raise Mt7932Error("the Bluetooth firmware has no ALPS trailer")


def validate_ptx(data):
    """bt7932_validate_ptx() from the Bluetooth driver."""
    if len(data) != 198 or data[:4] != b"BLOB":
        raise Mt7932Error("the PTX is not a 198-byte BLOB")
    first, version, count, reserved = struct.unpack_from("<IHHI", data, 4)
    if first != 96 or version != 1 or count != 4 or reserved:
        raise Mt7932Error("the PTX header is not the expected one")
    expected = 96
    for index, (kind, length) in enumerate(((0x101, 14), (0x201, 44), (0x301, 44), (0x401, 0))):
        record_kind, offset, record_length, checksum, tail = struct.unpack_from("<IIIII", data, 16 + 20 * index)
        if record_kind != kind or offset != expected or record_length != length or tail:
            raise Mt7932Error(f"PTX record {index} is not the expected one")
        if sum(data[offset : offset + length]) != checksum:
            raise Mt7932Error(f"PTX record {index} has a bad checksum")
        expected = offset + length
    if expected != len(data):
        raise Mt7932Error("the PTX has trailing bytes")


def j7cf(config_text):
    """config-original.bin: IZUBA_wifi.cfg's settings as the driver's records.

    "J7CF", a little-endian count of 64 or 65, then per setting: type 3, key
    and value lengths, a zero byte, and the NUL-padded 32-byte key and value.
    """
    records = []
    keys = set()
    for line in config_text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        key, _, value = line.partition(" ")
        key, value = key.strip(), value.strip()
        key_bytes, value_bytes = key.encode("ascii"), value.encode("ascii")
        if not 0 < len(key_bytes) < 32 or len(value_bytes) >= 32 or b"\0" in key_bytes + value_bytes:
            raise Mt7932Error(f"Wi-Fi setting {key!r} does not fit a J7CF record")
        if key in keys:
            raise Mt7932Error(f"Wi-Fi setting {key!r} appears twice")
        keys.add(key)
        records.append(J7CF_RECORD.pack(3, len(key_bytes), len(value_bytes), 0, key_bytes, value_bytes))
    if len(records) not in (64, 65):
        raise Mt7932Error(f"IZUBA_wifi.cfg has {len(records)} settings, not 64 or 65")
    for required in ("Sta5gBw", "DisRoaming"):
        if required not in keys:
            raise Mt7932Error(f"IZUBA_wifi.cfg has no {required}")
    return b"J7CF" + struct.pack("<I", len(records)) + b"".join(records)


def bluetooth_address(chosen):
    """The six-byte Bluetooth address, in the order the driver reverses."""
    address = bytes(chosen.get("mac-address-bluetooth0", b""))
    if len(address) != 6 or address in (b"\0" * 6, b"\xff" * 6):
        raise Mt7932Error("the device tree has no usable Bluetooth address")
    return address


def device_tree_chosen():
    """/chosen from the running Mac's device tree."""
    output = subprocess.run(
        ["/usr/sbin/ioreg", "-a", "-r", "-p", "IODeviceTree", "-n", "chosen", "-d", "1"],
        check=True,
        capture_output=True,
    ).stdout
    found = plistlib.loads(output)
    if isinstance(found, list):
        found = found[0] if found else {}
    return found


def _read(root, *parts):
    with open(os.path.join(root, *parts), "rb") as source:
        return source.read()


def collect(root="/", chosen=None):
    """{firmware path: bytes} for this Mac's MT7932, all checked.

    Firmware paths are relative to /lib/firmware, as the drivers request them.
    """
    files = {}
    wifi = "mediatek/mt7932/"
    files[wifi + WIFI_PATCH] = _read(root, IZUBA, WIFI_PATCH)
    files[wifi + WIFI_RAM] = _read(root, IZUBA, WIFI_RAM)

    ppr = _read(root, IZUBA, "IZUBA_PPR_MT7932.bin")
    if len(ppr) != PPR_BYTES or ppr[:4] != b"BLOB":
        raise Mt7932Error("IZUBA_PPR_MT7932.bin is not the 412-byte BLOB ppr.bin needs")
    files[wifi + "ppr.bin"] = ppr

    records = glob.glob(os.path.join(root, FACTORY_DATA, "BWC2-*"))
    if len(records) != 1:
        raise Mt7932Error(f"expected one factory BWC2 record, found {len(records)}")
    with open(records[0], "rb") as source:
        fields = bwc2_fields(source.read())
    for name in ("OCA2", "WCAL", "BCAL"):
        if name not in fields:
            raise Mt7932Error(f"the factory BWC2 record has no {name}")
    validate_oca2(fields["OCA2"])
    files[wifi + "oca2.bin"] = fields["OCA2"]
    # The whole WCAL container, as ppr.bin is the whole PPR container; the
    # driver logs OWN_WCAL_ACCEPTED or WCAL_REPLY_REJECTED for it.
    if not 0 < len(fields["WCAL"]) <= WCAL_MAXIMUM or fields["WCAL"][:4] != b"BLOB":
        raise Mt7932Error("the factory WCAL field is not a BLOB of at most 1024 bytes")
    files[wifi + "wcal.bin"] = fields["WCAL"]

    config = _read(root, IZUBA, "IZUBA_wifi.cfg").decode("ascii")
    files[wifi + "config-original.bin"] = j7cf(config)

    for name in BT_FIRMWARE:
        firmware = _read(root, BLUETOOTH, name)
        validate_bluetooth_firmware(firmware)
        files["mediatek/" + name] = firmware
    ptx = _read(root, BLUETOOTH, BT_PTX)
    validate_ptx(ptx)
    files["mediatek/" + BT_PTX] = ptx
    if not 0 < len(fields["BCAL"]) <= BTCAL_MAXIMUM:
        raise Mt7932Error("the factory BCAL field is not a usable Bluetooth calibration")
    files["mediatek/j700-mt7932-btcal.bin"] = fields["BCAL"]
    files["mediatek/j700-mt7932-bdaddr.bin"] = bluetooth_address(
        device_tree_chosen() if chosen is None else chosen
    )
    return files
