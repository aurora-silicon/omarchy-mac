#!/usr/bin/env python3
"""Copy the complete, catalog-pinned runtime into an offline application."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile


def digest(path):
    hasher = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(chunk)
    return "sha256:" + hasher.hexdigest()


def bundle(catalog_path, source, destination):
    if source.is_symlink() or not source.is_dir():
        raise ValueError("offline-artifacts must be a real directory")
    if destination.exists() or destination.is_symlink():
        raise ValueError("offline artifact destination already exists")
    artifacts = {}
    models = json.loads(catalog_path.read_text())["models"]
    if not models:
        raise ValueError("offline catalog has no models")
    for model in models:
        if model.get("status") != "enabled":
            continue
        for role in ("engine", "metadata", "payload", "repairManifest"):
            key = role + "Artifact"
            if role == "repairManifest" and key not in model:
                continue
            artifact = model[key]
            name = artifact["fileName"]
            expected = model[role + "Digest"]
            size = artifact["sizeBytes"]
            if (not isinstance(name, str) or not name or len(name.encode()) > 255
                    or Path(name).name != name or name in (".", "..")
                    or "\\" in name or "\0" in name):
                raise ValueError("unsafe offline artifact name")
            if not re.fullmatch(r"sha256:[0-9a-f]{64}", expected):
                raise ValueError("invalid offline artifact digest")
            if type(size) is not int or size <= 0:
                raise ValueError("invalid offline artifact size")
            identity = (expected, size)
            if name in artifacts and artifacts[name] != identity:
                raise ValueError("conflicting offline artifact: " + name)
            artifacts[name] = identity
    if not artifacts:
        raise ValueError("offline catalog has no enabled artifacts")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".offline-artifacts-", dir=destination.parent) as temp:
        staging = Path(temp) / "Artifacts"
        staging.mkdir()
        for name, (expected, size) in artifacts.items():
            path = source / name
            if path.is_symlink() or not path.is_file():
                raise ValueError("missing or unsafe offline artifact: " + name)
            if path.stat().st_size != size or digest(path) != expected:
                raise ValueError("offline artifact does not match catalog: " + name)
            target = staging / name
            shutil.copyfile(path, target)
            target.chmod(0o444)
            if target.stat().st_size != size or digest(target) != expected:
                raise ValueError("offline artifact changed during copy: " + name)
        os.rename(staging, destination)
    return len(artifacts)


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit("usage: bundle-offline-artifacts.py CATALOG SOURCE DESTINATION")
    print("Bundled", bundle(*map(Path, sys.argv[1:])), "verified offline artifacts")
