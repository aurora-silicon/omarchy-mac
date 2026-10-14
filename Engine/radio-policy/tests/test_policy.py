# SPDX-License-Identifier: MIT
import hashlib
import importlib.util
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))
import mt7932_policy as policy


class PolicyTests(unittest.TestCase):
    def test_output_is_checked_even_when_worker_reports_success(self):
        completed = SimpleNamespace(returncode=0, stdout=b"incomplete", stderr=b"")
        with patch.object(policy.subprocess, "run", return_value=completed) as run:
            with self.assertRaisesRegex(ValueError, "qualified stock result"):
                policy.collect("/private/fixture")
        self.assertEqual(run.call_args.kwargs["input"], b"")
        self.assertEqual(run.call_args.kwargs["timeout"], 150)

    def test_worker_timeout_and_failure_stop_collection(self):
        cases = [subprocess.TimeoutExpired("fixture", 150),
                 SimpleNamespace(returncode=1, stdout=b"", stderr=b"wrong revision")]
        for result in cases:
            with self.subTest(result=result):
                kwargs = {"side_effect": result} if isinstance(result, Exception) else {"return_value": result}
                with patch.object(policy.subprocess, "run", **kwargs):
                    with self.assertRaises(ValueError):
                        policy.collect("/private/fixture")

    def test_stock_input_revision_and_size_fail_before_emulation(self):
        with tempfile.TemporaryDirectory() as temp:
            p = Path(temp) / "stock"
            p.write_bytes(b"local input")
            sha = hashlib.sha256(p.read_bytes()).hexdigest()
            self.assertEqual(policy.read_original(p, sha), b"local input")
            with self.assertRaisesRegex(ValueError, "Unsupported stock input"):
                policy.read_original(p, "0" * 64)
            with self.assertRaisesRegex(ValueError, "size/type"):
                policy.read_original(p, sha, maximum=2)

    def test_missing_or_changed_driver_rejected_without_unicorn(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            with self.assertRaises(OSError):
                policy.generate(root)
            path = root / policy.DRIVER
            path.parent.mkdir(parents=True)
            path.write_bytes(b"unqualified driver")
            with self.assertRaisesRegex(ValueError, "26.6.2/25G83"):
                policy.generate(root)

    def test_command_sequence_and_exact_result_are_both_required(self):
        commands = [dict(cid=0xca, set=1, reply=0, payload=bytes(328)) for _ in range(2)]
        commands += [dict(cid=0x5d, set=1, reply=0, payload=bytes(n)) for n in policy.TABLE_LENGTHS]
        with self.assertRaisesRegex(ValueError, "qualified stock result"):
            policy.package(commands)
        for field, value in (("cid", 15), ("reply", 1), ("set", 0), ("payload", b"")):
            broken = [dict(c) for c in commands]
            broken[0][field] = value
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "Unexpected stock"):
                policy.package(broken)
        with self.assertRaisesRegex(ValueError, "two mode"):
            policy.package(commands[1:])

    def test_unrecognized_unicorn_version_is_refused(self):
        with patch.object(policy, "read_original", return_value=b"fixture"), patch.object(sys, "platform", "linux"):
            with patch.dict(sys.modules, {"unicorn": SimpleNamespace(__version__="0.0")}):
                with self.assertRaisesRegex(ValueError, "Unicorn 2.1.4"):
                    policy.generate("/unused")

    def test_macos_refuses_host_python_package_before_import(self):
        with patch.object(policy, "read_original", return_value=b"fixture"), patch.object(sys, "platform", "darwin"), \
                patch.object(importlib.util, "find_spec", return_value=SimpleNamespace(origin="/host/unicorn/__init__.py")):
            with self.assertRaisesRegex(ValueError, "this engine's bundled Unicorn"):
                policy.generate("/unused")

    def test_each_missing_or_changed_table_is_rejected_before_native_import(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            driver = root / policy.DRIVER
            driver.parent.mkdir(parents=True)
            driver.write_bytes(b"synthetic driver")
            tables = root / policy.IZUBA
            tables.mkdir()
            digests = {}
            for name in policy.ASSETS:
                data = ("synthetic " + name).encode()
                (tables / ("IZUBA_" + name)).write_bytes(data)
                digests[name] = hashlib.sha256(data).hexdigest()
            with patch.object(policy, "DRIVER_SHA256", hashlib.sha256(driver.read_bytes()).hexdigest()), \
                    patch.object(policy, "ASSETS", digests), patch.dict(sys.modules, {"unicorn": None}):
                for name in digests:
                    p = tables / ("IZUBA_" + name)
                    original = p.read_bytes()
                    p.unlink()
                    with self.subTest(missing=name), self.assertRaises(FileNotFoundError):
                        policy.generate(root)
                    p.write_bytes(b"changed table")
                    with self.subTest(changed=name), self.assertRaisesRegex(ValueError, "Unsupported stock input"):
                        policy.generate(root)
                    p.write_bytes(original)


@unittest.skipUnless(os.environ.get("MT7932_STOCK_ROOT"), "requires private stock inputs, never committed")
class PrivateParityTests(unittest.TestCase):
    def test_original_serializers_reproduce_independently_qualified_bytes(self):
        data = policy.collect(os.environ["MT7932_STOCK_ROOT"])
        self.assertEqual(len(data), 10241)
        self.assertEqual(hashlib.sha256(data).hexdigest(), policy.POLICY_SHA256)
        self.assertEqual(struct.unpack_from("<4sH2sBB2xI", data), (b"J7RP", 1, b"XZ", 2, 13, 10241))
        self.assertEqual([data[24 + 328*i:344 + 328*i].split(b"\0", 1)[0] for i in range(2)],
                         [b"SarEnableConfig 1", b"coex tasar_set 0 0"])


if __name__ == "__main__":
    unittest.main()
