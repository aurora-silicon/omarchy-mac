# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Bartosz Nitka
"""Produce the qualified world-XZ policy from this Mac's original stock files."""
import hashlib
import importlib.util
import os
from pathlib import Path
import stat
import struct
import subprocess
import sys

DRIVER = "System/Library/DriverExtensions/com.apple.AppleSunriseWLAN.dext/com.apple.AppleSunriseWLAN"
IZUBA = "System/Library/DriverExtensions/com.apple.AppleSunriseWLAN.dext/IZUBA"
DRIVER_SHA256 = "5eb5587a310775efde276054d73f3827e79b61434a62c8e64d9a96208ebff007"
POLICY_PATH = "mediatek/mt7932/policy/world-XZ.bin"
POLICY_SHA256 = "926b390f709a4125a53ecbc12d5b94eba765f142e099b9a711b43dda23f7aea0"
POLICY_BYTES = 10241
ASSETS = {
    "db.dat": "a61e0b70cbc9a381fc41ff9afa8f036cbd032cadad66209134d4a5adfa18c8b2",
    "TxPwrLimit_MT79x1.dat": "03ee51df5231d131c1976f1d2ea7f81a1396988e63a132a318a9893e8ef5ec38",
    "TxPwrLimit_SAR.dat": "d8dc9dfff2ad2d1ddf301d892e60c93f476603992f71de9e742194a395ca850d",
    "TxPwrLimit_SDB.dat": "042906f4b23f05d82f211549b22f195a57d3437b137009fda0a0e40935abbfd0",
    "TxPwrLimit_2gCommonPath.dat": "43185e334cb074b9c89b71aa6440d5d22cc45e9d8dc1fdc66c8a4933f2376b6c",
    "TxPwrLimit6G_MT79x1.dat": "bc22e249526867b62542ef61231c14b7027ae49f8c926ad6d73029c742dc53bc",
    "TxPwrLimit_AntGain.dat": "e40bcdca52134ae24bbf80ecafad5b94432b8deb6e45223552a37622d90b88e8",
}
TABLE_LENGTHS = (532, 1020, 776, 1020, 1020, 1020, 1020, 1020, 1020, 654, 144, 58, 265)


def read_original(path, expected, maximum=32 * 1024**2):
    with path.open("rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or not 0 < info.st_size <= maximum:
            raise ValueError("Invalid stock input size/type: " + path.name)
        data = stream.read(maximum + 1)
    if len(data) != info.st_size or hashlib.sha256(data).hexdigest() != expected:
        raise ValueError("Unsupported stock input: " + path.name + "; expected macOS 26.6.2/25G83")
    return data


def validate_policy(data):
    # This output identity was independently accepted by the unchanged Linux
    # J7RP parser and physically qualified with these exact stock inputs.
    # It is a digest, not a bundled regulatory-policy blob.
    if len(data) != POLICY_BYTES or hashlib.sha256(data).hexdigest() != POLICY_SHA256:
        raise ValueError("Generated world-XZ policy differs from the qualified stock result")
    return data


def package(commands):
    if len(commands) != 15:
        raise ValueError("Expected two mode commands and thirteen power tables")
    for i, command in enumerate(commands):
        expected_cid = 0xca if i < 2 else 0x5d
        expected_length = 328 if i < 2 else TABLE_LENGTHS[i - 2]
        if (command["cid"] != expected_cid or command["set"] != 1 or command["reply"] != 0
                or len(command["payload"]) != expected_length):
            raise ValueError("Unexpected stock policy command")
    payload = b"".join(command["payload"] for command in commands)
    return validate_policy(struct.pack("<4sH2sBB2xI", b"J7RP", 1, b"XZ", 2, 13, 16 + len(payload)) + payload)


def generate(root):
    # Validate all local inputs before loading the optional native dependency.
    root = Path(root)
    driver = read_original(root / DRIVER, DRIVER_SHA256)
    assets = {name: read_original(root / IZUBA / ("IZUBA_" + name), digest)
              for name, digest in ASSETS.items()}
    try:
        if sys.platform == "darwin":
            expected = Path(__file__).resolve().parent / "unicorn/__init__.py"
            spec = importlib.util.find_spec("unicorn")
            if spec is None or spec.origin is None or Path(spec.origin).resolve() != expected:
                raise ValueError("Policy conversion requires this engine's bundled Unicorn")
        import unicorn
        if unicorn.__version__ != "2.1.4":
            raise ValueError("Policy conversion requires bundled Unicorn 2.1.4")
        from mt7932_policy_reference import Image, generate as serialize
    except ImportError as error:
        raise ValueError("This engine lacks the bundled Unicorn 2.1.4 policy converter") from error
    return package(serialize(Image(driver), assets))


def collect(root="/"):
    # Keep emulator resources and failures outside the privileged installer's
    # long-lived process. No stock executable is run by macOS or Rosetta.
    try:
        result = subprocess.run(
            [sys.executable, "-B", str(Path(__file__).resolve()), "--worker", str(root)],
            input=b"", stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=150,
        )
    except subprocess.TimeoutExpired as error:
        raise ValueError("Stock radio-policy conversion exceeded its time budget") from error
    if result.returncode:
        message = result.stderr.decode("utf-8", errors="replace").strip()
        raise ValueError("Stock radio-policy conversion failed: " + message[-2000:])
    return validate_policy(result.stdout)


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] != "--worker":
        raise SystemExit("This module is run by the installer's radio collector")
    try:
        sys.stdout.buffer.write(generate(sys.argv[2]))
    except Exception as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
