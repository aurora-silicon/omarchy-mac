#!/usr/bin/env python3
"""Write a fake image build artifact for the upload job's tests and dry runs.

The directory looks like the image build's artifact (`mac-image.yml`): one
image zip, its `.sha256` line and the image records. The zip is filler bytes,
not an image; the upload job never opens it. With --evidence, a passing
acceptance evidence record for it is written too.

Usage:
  make-mac-upload-fixture.py --out DIR [--size BYTES] [--seed TEXT]
                             [--evidence FILE] [--run-url URL]

Prints `name=<image name>` and `sha256=<zip sha256>`.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

DATE = "2026.10.14"
RECORDS = ("installer_data.json", "IMAGE", "PROVENANCE", "INSPECTION", "inputs")


def filler(seed: str, size: int) -> bytes:
    block = hashlib.sha256(seed.encode()).digest() * 2048
    return (block * (size // len(block) + 1))[:size]


def make(out: Path, size: int, seed: str) -> tuple[str, str]:
    out.mkdir(parents=True, exist_ok=True)
    zip_name = f"omarchy-{DATE}-aarch64-apple-silicon-mac-edge-os-package.zip"
    payload = filler(seed, size)
    sha256 = hashlib.sha256(payload).hexdigest()
    (out / zip_name).write_bytes(payload)
    (out / f"{zip_name}.sha256").write_text(f"{sha256}  {zip_name}\n")
    name = f"omarchy-mac-edge-{DATE}-{hashlib.sha256(seed.encode()).hexdigest()[:12]}"
    for record in RECORDS:
        (out / record).write_text(f"fixture {record} for {name}\n")
    return name, sha256


def evidence(sha256: str, run_url: str) -> dict:
    return {
        "image_sha256": sha256,
        "result": "pass",
        "scenarios": [
            {"name": "first-boot", "result": "pass"},
            {"name": "conversion", "result": "pass"},
            {"name": "second-boot", "result": "pass"},
        ],
        "harness_commit": "0" * 40,
        "runner": "fixture (no VM ran)",
        "run_url": run_url,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--size", type=int, default=3 * 1024 * 1024 + 12345)
    parser.add_argument("--seed", default="mac-upload fixture")
    parser.add_argument("--evidence", type=Path)
    parser.add_argument("--run-url", default="https://example.invalid/fixture")
    args = parser.parse_args()
    name, sha256 = make(args.out, args.size, args.seed)
    if args.evidence:
        args.evidence.parent.mkdir(parents=True, exist_ok=True)
        args.evidence.write_text(json.dumps(evidence(sha256, args.run_url), indent=2) + "\n")
    print(f"name={name}")
    print(f"sha256={sha256}")


if __name__ == "__main__":
    main()
