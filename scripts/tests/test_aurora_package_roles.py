import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("installed", ROOT / "image-builder/builder/verify_installed_system.py")
installed = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(installed)


class AuroraPackageRolesTests(unittest.TestCase):
    def inspect(self, replacements):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name in installed.REQUIRED_PACKAGES:
                renamed, provides = replacements.get(name, (name, []))
                path = root / "var/lib/pacman/local" / renamed / "desc"
                path.parent.mkdir(parents=True)
                path.write_text("%NAME%\n" + renamed + "\n\n%VERSION%\n0.4.4.aurora2-1\n\n%PROVIDES%\n"
                                + "\n".join(provides) + "\n\n")
            verification = installed.Verification()
            installed.check_packages(verification, root)
            return verification

    def test_exact_audio_and_bless_replacements_fill_legacy_roles(self):
        result = self.inspect({
            "asahi-audio": ("asahi-audio-aurora", ["asahi-audio=4.1.aurora2"]),
            "alsa-ucm-conf-asahi": ("alsa-ucm-conf-asahi-aurora", ["alsa-ucm-conf-asahi=10.aurora2"]),
            "asahi-bless": ("aurora-bless", ["asahi-bless=0.4.4.aurora2"]),
        })
        self.assertEqual(result.failed, [], result.checks)

    def test_other_package_cannot_claim_audio_role(self):
        result = self.inspect({"asahi-audio": ("impostor", ["asahi-audio=100"])} )
        self.assertIn("packages-required-present", result.failed)


if __name__ == "__main__":
    unittest.main()
