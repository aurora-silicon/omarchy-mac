# SPDX-License-Identifier: MIT
"""J700 CT817 calibration derived from this Mac's exbright LSCI record.

LSCI 4.5 stores five signed Q16 coefficients and six signed gain steps.
The AOP setup message uses per-step ratios, not cumulative gains: this is
consistent with the captured J700 native 80-byte CT817 setup message. The
correction factor is 1.0 and the final eight bytes are zero in that capture.
Never substitute calibration from another Mac when collection fails.
"""

import plistlib
import struct
import subprocess
from xml.parsers.expat import ExpatError

FIRMWARE_NAME = "apple/j700-aop-als-cal.bin"
LSCI_SIZE = 156
SETUP_OPCODE = 0x0746B8D665152E31


class AlsError(ValueError):
    pass


def calibration(lsci):
    """Convert the supported LSCI 4.5 record into the driver's 80-byte ABI."""
    if not isinstance(lsci, bytes) or len(lsci) != LSCI_SIZE:
        raise AlsError("expected a 156-byte exbright LSCI record")
    if lsci[:2] != b"\x05\x04":
        raise AlsError("unsupported exbright LSCI version (expected 4.5)")
    if struct.unpack_from("<H", lsci, 4)[0] != LSCI_SIZE:
        raise AlsError("exbright LSCI size field disagrees with its record")

    coefficients = [value / 65536.0 for value in struct.unpack_from("<5i", lsci, 28)]
    gains = []
    for offsets in ((58, 62, 66), (60, 64, 68)):
        raw = [struct.unpack_from("<h", lsci, offset)[0] for offset in offsets]
        if any(value <= 0 for value in raw):
            raise AlsError("exbright LSCI contains a non-positive gain ratio")
        gains.extend([1.0] + [value / 255.0 for value in raw])
    return struct.pack("<QQ14f8x", SETUP_OPCODE, 56, *coefficients, 1.0, *gains)


def from_ioreg(data):
    """Find one exbright LSCI property in an IORegistry XML/binary plist."""
    try:
        roots = plistlib.loads(data)
    except (ValueError, TypeError, ExpatError, plistlib.InvalidFileException) as error:
        raise AlsError("invalid exbright IORegistry property list") from error
    if not isinstance(roots, list):
        raise AlsError("expected IORegistry roots in the exbright property list")
    found = []
    pending = list(roots)
    while pending:
        node = pending.pop()
        if not isinstance(node, dict):
            raise AlsError("invalid IORegistry entry in exbright property list")
        if node.get("IORegistryEntryName") == "exbright" and "LSCI" in node:
            found.append(node["LSCI"])
        children = node.get("IORegistryEntryChildren", [])
        if not isinstance(children, list):
            raise AlsError("invalid IORegistry children in exbright property list")
        pending.extend(children)
    if len(found) != 1:
        raise AlsError(f"expected one exbright LSCI record, found {len(found)}")
    # Validate before retaining the raw fallback record as well.
    calibration(found[0])
    return found[0]


def read_lsci(run=subprocess.run):
    """Read and validate this booted Mac's exbright calibration, without writes."""
    result = run(
        ["/usr/sbin/ioreg", "-r", "-a", "-n", "exbright", "-l"],
        capture_output=True,
        check=True,
    )
    return from_ioreg(result.stdout)


def collect(run=subprocess.run):
    return {FIRMWARE_NAME: calibration(read_lsci(run))}
