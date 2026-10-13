# SPDX-License-Identifier: MIT
"""A MacBook Neo's Touch ID (Mesa) calibration, read from macOS.

Accept both the comb/fdrd/secb FSCl record handled by Aurora's Linux
extractor and the standalone signed FSC2 format. The format on a
sensor-equipped J700 has not yet been hardware-qualified. No calibration
is read on J700 variants without an on-board SPI2 sensor controller.
"""

import os
import plistlib
import subprocess
from xml.parsers.expat import ExpatError

FIRMWARE_NAME = "apple/mesacal-j700.bin"
# The iBoot System Container is about 550 MB; refuse anything far larger.
CONTAINER_MAXIMUM = 1 << 30


class MesaError(Exception):
    pass


def _tlv(data, at):
    if at < 0 or at + 2 > len(data):
        raise ValueError("truncated DER header")
    tag, length, header = data[at], data[at + 1], 2
    if length >= 0x80:
        count = length & 0x7F
        if not 1 <= count <= 4 or at + 2 + count > len(data):
            raise ValueError("bad DER length")
        if data[at + 2] == 0:
            raise ValueError("non-minimal DER length")
        length = int.from_bytes(data[at + 2 : at + 2 + count], "big")
        if length < 0x80:
            raise ValueError("non-minimal DER length")
        header = 2 + count
    end = at + header + length
    if end > len(data):
        raise ValueError("DER runs past the input")
    return tag, at + header, end


def _children(data, start, end):
    while start < end:
        child = _tlv(data, start)
        if child[2] > end:
            raise ValueError("DER child runs past its parent")
        yield child
        start = child[2]


def _ia5(data, child):
    tag, start, end = child
    return bytes(data[start:end]) if tag == 0x16 else None


def fsc2_calibrations(data):
    """Every distinct signed FSC2 IMG4 (IM4P payload holding CALB, IM4M
    manifest) in data, as bytes."""
    found = set()
    at = data.find(b"\x16\x04IMG4")
    while at >= 0:
        for header in range(2, 7):
            start = at - header
            if start < 0 or data[start] != 0x30:
                continue
            try:
                _, content, end = _tlv(data, start)
                if content != at:
                    continue
                parts = list(_children(data, content, end))
                im4p = list(_children(data, parts[1][1], parts[1][2]))
                if (
                    _ia5(data, parts[0]) == b"IMG4"
                    and _ia5(data, im4p[0]) == b"IM4P"
                    and _ia5(data, im4p[1]) == b"FSC2"
                    and im4p[3][0] == 0x04
                    and b"CALB" in data[im4p[3][1] : min(im4p[3][2], im4p[3][1] + 256)]
                    and len(parts) >= 3
                    and parts[2][0] == 0xA0
                    and b"IM4M" in data[parts[2][1] : parts[2][2]]
                ):
                    found.add(bytes(data[start:end]))
            except (ValueError, IndexError):
                continue
        at = data.find(b"\x16\x04IMG4", at + 1)
    return found


def fscl_calibrations(data):
    """Carve complete FSCl comb records using the Linux extractor's checks.

    Keep the outer comb/fdrd/secb wrapper, which is part of the calibration
    consumed by the SEP driver; do not return only its embedded IMG4.
    """
    found = set()
    marker = data.find(b"\x16\x04comb")
    while marker >= 0:
        for header in range(2, 7):
            start = marker - header
            if start < 0 or data[start] != 0x30:
                continue
            try:
                _, content, end = _tlv(data, start)
                if content != marker:
                    continue
                outer = list(_children(data, content, end))
                if len(outer) != 3 or _ia5(data, outer[0]) != b"comb":
                    continue
                if outer[1][0] != 0x30 or outer[2][0] != 0x30:
                    continue
                fdrd = list(_children(data, outer[1][1], outer[1][2]))
                secb = list(_children(data, outer[2][1], outer[2][2]))
                if len(fdrd) != 2 or _ia5(data, fdrd[0]) != b"fdrd":
                    continue
                if fdrd[1][0] != 0x04 or _ia5(data, secb[0]) != b"secb":
                    continue
                image = _tlv(data, fdrd[1][1])
                if image[0] != 0x30 or image[2] != fdrd[1][2]:
                    continue
                parts = list(_children(data, image[1], image[2]))
                if _ia5(data, parts[0]) != b"IMG4" or parts[1][0] != 0x30:
                    continue
                im4p = list(_children(data, parts[1][1], parts[1][2]))
                if (_ia5(data, im4p[0]) != b"IM4P"
                        or _ia5(data, im4p[1]) != b"FSCl"
                        or im4p[2][0] != 0x16 or im4p[3][0] != 0x04):
                    continue
                if b"CALB" not in data[im4p[3][1]:min(im4p[3][2], im4p[3][1] + 64)]:
                    continue
                remainder = data[parts[1][2]:image[2]]
                if b"IM4M" not in remainder or b"FSCl" not in remainder:
                    continue
                found.add(bytes(data[start:end]))
            except (ValueError, IndexError):
                continue
        marker = data.find(b"\x16\x04comb", marker + 1)
    return found


def calibration(container):
    """The one distinct supported calibration in an iBoot container."""
    found = fsc2_calibrations(container) | fscl_calibrations(container)
    if len(found) != 1:
        raise MesaError(f"expected one signed FSCl/FSC2 calibration, found {len(found)}")
    return found.pop()


def has_builtin_sensor(run=subprocess.run):
    """Read the on-board controller from ADT, never an external keyboard.

    J700 variants lacking Touch ID omit spi2 from arm-io. A failed or
    malformed query is an error, not evidence that the sensor is absent.
    """
    output = run(
        ["/usr/sbin/ioreg", "-a", "-r", "-p", "IODeviceTree", "-n", "arm-io", "-d", "2"],
        check=True, capture_output=True,
    ).stdout
    try:
        roots = plistlib.loads(output)
        if not isinstance(roots, list) or len(roots) != 1:
            raise ValueError("expected one arm-io node")
        root = roots[0]
        if root.get("IORegistryEntryName", "").split("@")[0] != "arm-io":
            raise ValueError("not the arm-io node")
        children = root["IORegistryEntryChildren"]
        if not isinstance(children, list) or not children:
            raise ValueError("arm-io children are missing")
        names = [child["IORegistryEntryName"].split("@")[0] for child in children]
    except (ValueError, KeyError, TypeError, AttributeError, ExpatError, plistlib.InvalidFileException) as error:
        raise MesaError(f"cannot determine built-in Touch ID hardware: {error}") from error
    return "spi2" in names


def collect(device):
    """{firmware path: bytes} for this Mac's Touch ID, read from the raw
    iBoot System Container device, never written."""
    fd = os.open(device, os.O_RDONLY)
    try:
        size = os.lseek(fd, 0, os.SEEK_END)
        if not 0 < size <= CONTAINER_MAXIMUM:
            raise MesaError(f"{device} is {size} bytes, not an iBoot System Container")
        os.lseek(fd, 0, os.SEEK_SET)
        container = bytearray()
        while len(container) < size:
            block = os.read(fd, min(8 << 20, size - len(container)))
            if not block:
                raise MesaError("short read of the iBoot System Container")
            container += block
    finally:
        os.close(fd)
    return {FIRMWARE_NAME: calibration(container)}
