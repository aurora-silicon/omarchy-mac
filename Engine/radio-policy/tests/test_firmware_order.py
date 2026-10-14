# SPDX-License-Identifier: MIT
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3] / "image-builder/firmware-ordering"


class FirmwareOrderTests(unittest.TestCase):
    def test_world_policy_is_required_but_us_is_optional(self):
        source = (ROOT / "aurora-peripheral-firmware.sh").read_text()
        # Redirect reads and module operations into an isolated shell fixture.
        for missing in (False, True):
            with self.subTest(missing=missing), tempfile.TemporaryDirectory() as temp:
                prefix = '''grep() { return 0; }
modprobe() { printf 'module:%s\\n' "$1"; }
has_firmware() { CASE; }
'''.replace("CASE", '[ "$1" != mediatek/mt7932/policy/world-XZ.bin ]' if missing else
            '[ "$1" != mediatek/mt7932/policy/US.bin ]')
                start = source.index("neo=false")
                result = subprocess.run(["bash", "-eu"], input=prefix + source[start:], text=True,
                                        capture_output=True, cwd=temp, timeout=5)
                if missing:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertNotIn("module:", result.stdout)
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout.splitlines(), ["module:aop", "module:mt7932-fullmac"])

    def test_initramfs_can_build_without_precollected_policy(self):
        source = (ROOT / "aurora-vendor-order.install").read_text()
        for present in ((), ("world-XZ",), ("US", "world-XZ")):
            with self.subTest(present=present), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                for name in present:
                    (root / (name + ".bin")).write_bytes(b"fixture")
                script = '''add_binary() { :; }; add_module() { :; }; add_symlink() { :; }
add_file() {
  case "$1" in
    TEMP/*) [[ -f "$1" ]] || return 1 ;;
  esac
  printf '%s\\n' "$1"
}
'''.replace("TEMP", temp) + source.replace("/usr/lib/firmware/mediatek/mt7932/policy", temp) + "\nbuild\n"
                result = subprocess.run(["bash", "-eu"], input=script, text=True, capture_output=True, timeout=5)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("aurora-peripheral-firmware.service", result.stdout)
                for name in ("US", "world-XZ"):
                    self.assertEqual(str(root / (name + ".bin")) in result.stdout, name in present)


if __name__ == "__main__":
    unittest.main()
