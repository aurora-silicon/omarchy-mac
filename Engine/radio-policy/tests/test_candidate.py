# SPDX-License-Identifier: MIT
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import stat
import subprocess
import sys
import tarfile
import tempfile
from types import ModuleType, SimpleNamespace
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[1]
ENGINE = ROOT.parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "src"))
sys.path.insert(0, str(ENGINE / "overlay/tests"))
import build_candidate as builder
import mt7932_policy as policy
import test_omarchy_mt7932 as fixtures
import test_omarchy_asahi as adapter_fixtures


def wheel(extra=()):
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w") as archive:
        for name in ("unicorn/__init__.py", "unicorn/lib/libunicorn.2.dylib",
                     "unicorn-2.1.4.dist-info/METADATA", "unicorn-2.1.4.dist-info/RECORD",
                     "unicorn-2.1.4.dist-info/LICENSE.TXT"):
            archive.writestr(name, "synthetic " + name)
        archive.writestr(builder.NATIVE_BINDING, "def __load_uc_lib() -> ctypes.CDLL:\n    return None\n\ndef __set_lib_prototypes(lib):\n    pass\n")
        for name, content in extra:
            archive.writestr(name, content)
    return output.getvalue()


class CandidateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        originals = {n: (ENGINE / "overlay/src" / n).read_bytes() for n in builder.COLLECTORS}
        cls.collectors = builder.patched_collectors(originals)

    def test_patch_integrates_policy_and_rejects_partial_package(self):
        candidate = ModuleType("radio_candidate")
        exec(compile(self.collectors["omarchy_mt7932.py"], "candidate", "exec"), candidate.__dict__)
        fixture = fixtures.CollectTests()
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        with patch.object(policy, "collect", return_value=b"policy-fixture") as collect, \
                patch.object(policy, "validate_policy", side_effect=lambda d: d):
            files = candidate.collect(str(fixture.root), chosen=fixture.chosen)
            collect.assert_called_once_with(str(fixture.root))
        self.assertEqual(files[policy.POLICY_PATH], b"policy-fixture")
        self.assertEqual(len(files), 12)
        with patch.object(policy, "collect", side_effect=ValueError("unsupported stock input")):
            with self.assertRaisesRegex(candidate.Mt7932Error, "unsupported stock"):
                candidate.collect(str(fixture.root), chosen=fixture.chosen)

        adapter = ModuleType("adapter_candidate")
        with patch.dict(sys.modules, {"omarchy_mt7932": candidate}):
            exec(compile(self.collectors["omarchy_asahi.py"], "candidate", "exec"), adapter.__dict__)
        package = SimpleNamespace(added=[])
        package.add_file = lambda name, value: package.added.append((name, value))
        adapter.asahi_firmware = SimpleNamespace(core=SimpleNamespace(FWFile=lambda n, d: d))
        installer = SimpleNamespace(sysinfo=SimpleNamespace(device_class="j700ap"))
        missing = dict(files)
        del missing[policy.POLICY_PATH]
        with self.assertRaisesRegex(adapter.AsahiAdapterError, "world-XZ"):
            adapter._collect_neo_radios(installer, package, collect=lambda: missing)
        self.assertFalse(package.added)
        adapter._collect_neo_radios(installer, package, collect=lambda: files)
        self.assertEqual(dict(package.added), files)
        # Follow the real default binding with preflight's cached policy.
        with patch.object(candidate, "_read", side_effect=lambda root, *parts: fixtures.mt._read(str(fixture.root), *parts)), \
                patch.object(candidate.glob, "glob", return_value=[str(fixture.root / candidate.FACTORY_DATA / 'BWC2-00008140-0000')]), \
                patch.object(candidate, "device_tree_chosen", return_value=fixture.chosen), \
                patch.object(policy, "validate_policy", side_effect=lambda d: d), \
                patch.object(policy, "collect", side_effect=AssertionError("cached policy must be reused")):
            adapter._collect_neo_radios(installer, package, policy=b"policy-fixture")
        installer.sysinfo.device_class = "j613ap"
        adapter._collect_neo_radios(installer, package, collect=lambda: self.fail("non-Neo collection"))

    def test_failed_policy_preflight_cannot_reach_disk_operations(self):
        adapter = ModuleType("adapter_candidate")
        exec(compile(self.collectors["omarchy_asahi.py"], "candidate", "exec"), adapter.__dict__)
        installer = SimpleNamespace(sysinfo=SimpleNamespace(device_class="j700ap"))
        instance = adapter.AsahiStage1Adapter(installer=installer, metadata_path=None,
                                             payload_path=None, stub_size=1)
        with patch.object(policy, "collect", side_effect=ValueError("bad stock/native runtime")):
            with self.assertRaisesRegex(adapter.AsahiAdapterError, "radio-policy preflight"):
                instance.preflight(None)
        self.assertFalse(instance.preflight_complete)
        self.assertIsNone(instance.osins)
        self.assertIsNone(instance.template)
        for operation in (instance.prepare_target, instance.remove_existing_install):
            with self.assertRaises(adapter.AsahiAdapterError):
                operation(None)

    def test_native_library_failure_has_no_host_fallback(self):
        files = builder.wheel_members(wheel())
        builder.pin_native_loader(files)
        import ctypes
        namespace = {"ctypes": ctypes, "__file__": "/fixture/unicorn/unicorn_py3/unicorn.py"}
        exec(files[builder.NATIVE_BINDING], namespace)
        with patch.object(ctypes.cdll, "LoadLibrary", side_effect=OSError("cannot load bundled dylib")) as load:
            with self.assertRaises(OSError):
                namespace["__load_uc_lib"]()
        load.assert_called_once_with("/fixture/unicorn/lib/libunicorn.2.dylib")

    def test_wheel_keeps_library_and_license_metadata(self):
        members = builder.wheel_members(wheel())
        self.assertIn("unicorn/lib/libunicorn.2.dylib", members)
        self.assertIn("unicorn-2.1.4.dist-info/LICENSE.TXT", members)

    def test_unsafe_duplicate_and_foreign_wheel_members_are_rejected(self):
        cases = ["../escape", "/absolute", "unicorn/../../escape", "foreign/package.py",
                 "unicorn/__init__.py", "unicorn\\escape"]
        for name in cases:
            with self.subTest(name=name), self.assertRaises(ValueError):
                builder.wheel_members(wheel([(name, b"bad")]))
        link = zipfile.ZipInfo("unicorn/link")
        link.create_system = 3
        link.external_attr = (stat.S_IFLNK | 0o777) << 16
        with self.assertRaisesRegex(ValueError, "type"):
            builder.wheel_members(wheel([(link, b"../../escape")]))

    def test_wrong_base_and_wheel_are_rejected_before_output(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "base").write_bytes(b"wrong")
            (root / "wheel").write_bytes(b"wrong")
            with self.assertRaisesRegex(ValueError, "authenticated .39"):
                builder.build(root / "base", root / "wheel", root / "out")
            self.assertFalse((root / "out").exists())

    def test_candidate_archive_preserves_base_and_records_every_added_member(self):
        # Real collectors/patch, synthetic native runtime: no Apple assets.
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            engine = root / "Engine"
            candidate = engine / "radio-policy"
            (candidate / "src").mkdir(parents=True)
            (candidate / "collector.patch").write_bytes((ROOT / "collector.patch").read_bytes())
            for source in (ROOT / "src").glob("*.py"):
                (candidate / "src" / source.name).write_bytes(source.read_bytes())
            base = root / "base.tar.gz"
            originals = {n: (ENGINE / "overlay/src" / n).read_bytes() for n in builder.COLLECTORS}
            originals.update({"version.tag": b"original\n", "boot/m1n1.bin": b"unchanged fixture"})
            with tarfile.open(base, "w:gz") as archive:
                for name, content in originals.items():
                    info = tarfile.TarInfo("./" + name)
                    info.size, info.mode = len(content), 0o644
                    archive.addfile(info, io.BytesIO(content))
            pin_base = dict(builder.BASE, sha256=builder.digest(base.read_bytes()), size_bytes=base.stat().st_size)
            lock = {"validation_artifact": pin_base,
                    "downstream_overlay": {"files": [{"path": "overlay/src/"+n, "sha256": builder.digest(originals[n])}
                                                      for n in builder.COLLECTORS]}}
            (engine / "source-lock.json").write_text(json.dumps(lock))
            w = root / "wheel.whl"
            w.write_bytes(wheel())
            pin = dict(builder.WHEEL, bytes=w.stat().st_size, sha256=builder.digest(w.read_bytes()))
            with patch.object(builder, "ROOT", candidate), patch.object(builder, "WHEEL", pin), patch.object(builder, "BASE", pin_base):
                corrupted = root / "corrupt.whl"
                corrupted.write_bytes(b"X" + w.read_bytes()[1:])
                with self.assertRaisesRegex(ValueError, "wheel size/hash"):
                    builder.build(base, corrupted, root / "out.tar.gz")
                self.assertFalse((root / "out.tar.gz").exists())
                builder.build(base, w, root / "out.tar.gz")
            with patch.object(builder, "ROOT", candidate):
                with self.assertRaisesRegex(ValueError, "frozen .39 source lock"):
                    builder.build(base, w, root / "different-base.tar.gz")
            with tarfile.open(root / "out.tar.gz") as archive:
                self.assertEqual(archive.extractfile("./boot/m1n1.bin").read(), originals["boot/m1n1.bin"])
                receipt = json.load(archive.extractfile("./radio-policy-candidate.json"))
                for name, info in receipt["files"].items():
                    data = archive.extractfile("./" + name).read()
                    self.assertEqual(info, {"bytes": len(data), "sha256": builder.digest(data)})
                self.assertEqual(archive.extractfile("./omarchy_mt7932.py").read(), self.collectors["omarchy_mt7932.py"])
                self.assertEqual(archive.extractfile("./version.tag").read().decode().strip(), builder.VERSION)


if __name__ == "__main__":
    unittest.main()
