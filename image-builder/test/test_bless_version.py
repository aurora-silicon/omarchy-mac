#!/usr/bin/env python3
"""Do not accept the old base image's boot selector for a Neo-capable image."""
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "builder"))
from verify_installed_system import Verification, check_packages


class BlessVersionTest(unittest.TestCase):
    def check_version(self, version):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package = root / "var/lib/pacman/local/asahi-bless-fixture"
            package.mkdir(parents=True)
            (package / "desc").write_text(f"%NAME%\nasahi-bless\n\n%VERSION%\n{version}\n")
            result = Verification()
            check_packages(result, root)
            return result.checks["asahi-bless-neo-nvram"]["result"]

    def test_old_base_image_selector_is_rejected(self):
        self.assertEqual(self.check_version("0.4.2-1"), "failed")

    def test_neo_capable_releases_are_accepted(self):
        for version in ("0.4.4-1", "0.4.4.aurora1-20261013.727b5895db67", "1.0-1"):
            with self.subTest(version=version):
                self.assertEqual(self.check_version(version), "passed")

    def test_unrecognized_version_is_rejected(self):
        self.assertEqual(self.check_version("unknown"), "failed")


if __name__ == "__main__":
    unittest.main()
