#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Build an unsigned radio-policy candidate from the authenticated frozen engine profile.

This does not change the production engine pin, catalog, signing or release lock.
Inputs are local files; this command performs no downloads or installation.
"""
import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import stat
import subprocess
import tarfile
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent
VERSION = "v0.9.2-aurora.radio-policy.2"
BASE = {
    "filename": "installer-v0.9.2-omarchy.40.tar.gz",
    "size_bytes": 23858473,
    "sha256": "f7c37dea75abad81f825a7d4a623f52f0d4d30495fef5d00ee43e0187779059e",
}
WHEEL = {
    "filename": "unicorn-2.1.4-cp37-abi3-macosx_11_0_arm64.whl",
    "bytes": 12142730,
    "sha256": "d6c93e0f60328d8f4a1792af3f834137a28050fcc2305f2ec01efe8558a9844e",
    "url": "https://files.pythonhosted.org/packages/6c/ae/4943c6f8524d729ec7d5e69df6407ea05d710fe77471d91cecf3fc64eb57/unicorn-2.1.4-cp37-abi3-macosx_11_0_arm64.whl",
}
COLLECTORS = ("omarchy_asahi.py", "omarchy_mt7932.py")
NATIVE_BINDING = "unicorn/unicorn_py3/unicorn.py"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def checked_name(name):
    name = name.removeprefix("./")
    parts = name.rstrip("/").split("/")
    if not name or any(part in ("", ".", "..") for part in parts) or "\\" in name or "\0" in name:
        raise ValueError("Unsafe archive path: " + name)
    return name.rstrip("/")


def wheel_members(data):
    """Return a bounded, safe package inventory after the caller verifies bytes."""
    files = {}
    total = 0
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        for member in archive.infolist():
            name = checked_name(member.filename)
            if name in files:
                raise ValueError("Duplicate wheel member: " + name)
            if PurePosixPath(name).parts[0] not in ("unicorn", "unicorn-2.1.4.dist-info"):
                raise ValueError("Unexpected wheel member: " + name)
            mode = member.external_attr >> 16
            if stat.S_ISLNK(mode) or (stat.S_IFMT(mode) and not (stat.S_ISDIR(mode) or stat.S_ISREG(mode))):
                raise ValueError("Unexpected wheel member type: " + name)
            if member.is_dir():
                continue
            total += member.file_size
            if total > 128 * 1024**2 or len(files) >= 256:
                raise ValueError("Wheel exceeds package budget")
            files[name] = archive.read(member)
    if not {"unicorn/__init__.py", "unicorn/lib/libunicorn.2.dylib",
            "unicorn-2.1.4.dist-info/METADATA", "unicorn-2.1.4.dist-info/RECORD"} <= files.keys():
        raise ValueError("Wheel lacks the expected Python/native distribution")
    return files


def pin_native_loader(files):
    # The stock bindings search LIBUNICORN_PATH and host/global libraries after
    # a bundled-library failure. Candidate macOS engines must never fall back.
    source = files[NATIVE_BINDING].decode()
    start = source.index("def __load_uc_lib() -> ctypes.CDLL:")
    end = source.index("def __set_lib_prototypes", start)
    replacement = '''def __load_uc_lib() -> ctypes.CDLL:
    from pathlib import Path
    library = Path(__file__).resolve().parents[1] / 'lib' / 'libunicorn.2.dylib'
    return ctypes.cdll.LoadLibrary(str(library))


'''
    files[NATIVE_BINDING] = (source[:start] + replacement + source[end:]).encode()


def patched_collectors(originals):
    patch_path = ROOT / "collector.patch"
    if set(originals) != set(COLLECTORS):
        raise ValueError("Unexpected collector patch inventory")
    with tempfile.TemporaryDirectory(prefix="aurora-radio-patch-") as temp:
        root = Path(temp)
        for name, content in originals.items():
            (root / name).write_bytes(content)
        subprocess.run(["git", "apply", "--unidiff-zero", "--check", str(patch_path)], cwd=root,
                       check=True, capture_output=True, timeout=15)
        subprocess.run(["git", "apply", "--unidiff-zero", str(patch_path)], cwd=root,
                       check=True, capture_output=True, timeout=15)
        return {name: (root / name).read_bytes() for name in COLLECTORS}


def build(base, wheel, output):
    if output.exists():
        raise ValueError("Output already exists")
    lock = json.loads((ROOT.parent / "source-lock.json").read_text())
    artifact = lock["validation_artifact"]
    if any(artifact.get(key) != value for key, value in BASE.items()):
        raise ValueError("Candidate requires the frozen .40 source lock")
    base_data = base.read_bytes()
    if len(base_data) != artifact["size_bytes"] or digest(base_data) != artifact["sha256"]:
        raise ValueError("Base is not the exact authenticated frozen engine profile")
    wheel_data = wheel.read_bytes()
    if len(wheel_data) != WHEEL["bytes"] or digest(wheel_data) != WHEEL["sha256"]:
        raise ValueError("Unicorn wheel size/hash mismatch")
    overlay = wheel_members(wheel_data)
    pin_native_loader(overlay)
    sources = {p.name: p.read_bytes() for p in (ROOT / "src").glob("*.py")}
    if set(sources) != {"mt7932_policy.py", "mt7932_policy_reference.py"}:
        raise ValueError("Unexpected radio-policy source inventory")
    overlay.update(sources)
    with tarfile.open(fileobj=io.BytesIO(base_data), mode="r:gz") as archive:
        members = {}
        for member in archive.getmembers():
            if member.name in (".", "./"):
                continue
            name = checked_name(member.name)
            if name in members:
                raise ValueError("Duplicate engine member: " + name)
            members[name] = member
        originals = {name: archive.extractfile(members[name]).read() for name in COLLECTORS}
        records = {Path(r["path"]).name: r for r in lock["downstream_overlay"]["files"]}
        for name, data in originals.items():
            if digest(data) != records[name]["sha256"]:
                raise ValueError("Base collector differs from source lock: " + name)
        overlay.update(patched_collectors(originals))
        if (set(overlay) - set(COLLECTORS)) & members.keys():
            raise ValueError("Candidate would replace an unexpected base member")
        overlay["version.tag"] = (VERSION + "\n").encode()
        receipt = {
            "schema": 1, "version": VERSION, "base_sha256": digest(base_data),
            "wheel": WHEEL, "collector_patch_sha256": digest((ROOT / "collector.patch").read_bytes()),
            "builder_sha256": digest(Path(__file__).read_bytes()),
            "files": {name: {"bytes": len(data), "sha256": digest(data)}
                      for name, data in sorted(overlay.items())},
            "qualification": "unsigned candidate; native macOS runtime and fresh install require qualification",
        }
        overlay["radio-policy-candidate.json"] = (json.dumps(receipt, indent=2) + "\n").encode()
        with output.open("xb") as raw, gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as gz:
            with tarfile.open(fileobj=gz, mode="w|", format=tarfile.PAX_FORMAT) as result:
                for name, member in members.items():
                    if name in overlay or (name.startswith("._") and name[2:] in overlay):
                        continue
                    if "__pycache__" in name and any(Path(p).stem in name for p in COLLECTORS):
                        continue
                    result.addfile(member, archive.extractfile(member) if member.isfile() else None)
                for name, data in sorted(overlay.items()):
                    member = tarfile.TarInfo("./" + name)
                    member.mode = 0o644
                    member.mtime = 1786436181
                    member.size = len(data)
                    result.addfile(member, io.BytesIO(data))
    return {"file": str(output), "bytes": output.stat().st_size,
            "sha256": digest(output.read_bytes()), "base_sha256": digest(base_data)}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("base", type=Path, help="exact frozen engine archive for the fixed .40 base")
    parser.add_argument("wheel", type=Path, help=WHEEL["filename"])
    parser.add_argument("output", type=Path, help="new unsigned candidate archive")
    args = parser.parse_args()
    print(json.dumps(build(args.base, args.wheel, args.output), indent=2))
