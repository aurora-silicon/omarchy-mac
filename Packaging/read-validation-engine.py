#!/usr/bin/env python3
"""Print the inspection engine pin shared by app packaging and release CI."""
import json
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
source = (root / "Sources/OmarchyAppleInstaller/ValidationEngineArtifact.swift").read_text()
name = re.search(r'public static let fileName = "(installer-[A-Za-z0-9.-]+\.tar\.gz)"', source)
digest = re.search(r'public static let expectedDigest\s*=\s*"sha256:([0-9a-f]{64})"', source)
size = re.search(r'public static let expectedSizeBytes: UInt64 = ([0-9_]+)', source)
if not all((name, digest, size)):
    raise SystemExit("Cannot read the app inspection engine identity")
actual = (name[1], digest[1], int(size[1].replace("_", "")))
lock = json.loads((root / "Engine/source-lock.json").read_text())["validation_artifact"]
if actual != (lock["filename"], lock["sha256"], lock["size_bytes"]):
    raise SystemExit("App inspection engine differs from its source lock")
print(*actual)
