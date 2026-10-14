#!/usr/bin/env python3
"""Channel mode takes only the pinned edge database's archives, each signed by the Omarchy package key."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fixtures  # noqa: E402

ROOT = fixtures.ROOT
channel_set = fixtures.load("channel_set", "builder/channel_set.py")
candidate_set = fixtures.candidate_set


class ChannelSetTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.base = Path(cls.tmp.name)
        cls.candidate = fixtures.Signer(cls.base / "candidate")
        cls.channel = fixtures.Signer(cls.base / "channel", "Omarchy fixture <pkgs@example.invalid>")
        cls.other = fixtures.Signer(cls.base / "other", "Someone else <other@example.invalid>")
        cls.trust = fixtures.channel_trust(cls.base, cls.candidate, cls.channel)

    @classmethod
    def tearDownClass(cls):
        for signer in (cls.candidate, cls.channel, cls.other):
            signer.close()
        cls.tmp.cleanup()

    def setUp(self):
        self.work = Path(tempfile.mkdtemp(dir=self.base))

    def snapshot(self, **options) -> tuple[Path, str]:
        return fixtures.make_channel(self.work / "edge", self.channel, **options)

    def freeze(self, database: Path, sha256: str, lane: str = "edge") -> dict:
        return channel_set.snapshot(database, sha256, lane, self.work / "edge/packages", self.work / "set", self.trust)

    def refused(self, message: str, database: Path, sha256: str, lane: str = "edge") -> None:
        with self.assertRaisesRegex(ValueError, message):
            self.freeze(database, sha256, lane)

    def test_a_pinned_database_and_signed_archives_make_a_public_set(self):
        database, sha256 = self.snapshot(extra=[("omarchy-keyring", "20251027-1")])
        summary = self.freeze(database, sha256)
        self.assertEqual(summary["kind"], "channel")
        self.assertIs(summary["candidate_only"], False)
        self.assertEqual(summary["set"], f"omarchy-edge-{sha256[:12]}")
        self.assertEqual(summary["database_sha256"], sha256)
        self.assertEqual(summary["signer"], self.channel.fingerprint.upper())
        packages = {p["name"]: p for p in summary["packages"]}
        expected = {fixtures.CHANNEL_NAMES.get(role, role) for role in fixtures.VERSIONS}
        self.assertEqual(set(packages), expected, "the set is the policy's runtime and boot packages, nothing else")
        for name, package in packages.items():
            self.assertEqual(package["sha256"], candidate_set.digest(self.work / "edge/packages" / package["filename"]))
            self.assertEqual(package["origin"], "channel")
        self.assertEqual(packages["omarchy-dev"]["role"], "omarchy")
        self.assertEqual(packages["omarchy-settings-dev"]["role"], "omarchy-settings")
        self.assertNotIn("source_commit", packages["omarchy-dev"], "the -dev runtime ships no source revision")
        self.assertEqual(packages["omarchy-mac"]["source_commit"], fixtures.SOURCE)
        self.assertEqual(packages["omarchy-mac-boot"]["source_commit"], fixtures.SOURCE)
        manifest = self.work / "set/manifest.json"
        self.assertEqual(candidate_set.digest(manifest), summary["manifest_sha256"])
        self.assertEqual(json.loads(manifest.read_text())["database_sha256"], sha256)
        self.assertEqual(json.loads((self.work / "set/import.json").read_text()), summary)
        self.assertFalse(any(path.stat().st_mode & 0o222 for path in (self.work / "set").iterdir()),
                         "the frozen set is read-only")
        self.assertEqual(fixtures.test_image_pin.pinned(summary), [], "a public image carries no test image pin")

    def test_files_lists_the_archives_the_set_needs(self):
        database, sha256 = self.snapshot()
        result = subprocess.run([sys.executable, str(ROOT / "builder/channel_set.py"), "files", "--db", str(database),
                                 "--lane", "edge"], capture_output=True, text=True)
        # The real policy pins the Omarchy key; listing reads only the database and the policy's names.
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sorted(result.stdout.split()), sorted(p.name for p in (self.work / "edge/packages").glob("*.xz")))

    def test_an_unsigned_package_is_refused(self):
        database, sha256 = self.snapshot(unsigned=("omarchy-mac",))
        self.refused("unsigned package: omarchy-mac-", database, sha256)

    def test_a_package_signed_by_another_key_is_refused(self):
        database, sha256 = self.snapshot(signers={"linux-aurora": self.other})
        self.refused("invalid signature: linux-aurora-", database, sha256)

    def test_a_package_signed_by_the_candidate_test_key_is_refused(self):
        database, sha256 = self.snapshot(signers={"omarchy-dev": self.candidate})
        self.refused("invalid signature: omarchy-dev-", database, sha256)

    def test_a_tampered_package_is_refused(self):
        database, sha256 = self.snapshot()
        archive = next((self.work / "edge/packages").glob("uboot-asahi-*.xz"))
        archive.write_bytes(archive.read_bytes() + b"\0")
        self.refused("is not the archive the channel database lists", database, sha256)

    def test_a_tampered_package_signed_again_is_refused(self):
        database, sha256 = self.snapshot()
        archive = next((self.work / "edge/packages").glob("m1n1-aurora-*.xz"))
        fixtures.write_archive(archive, "m1n1-aurora", fixtures.VERSIONS["m1n1-aurora"],
                               {"usr/lib/asahi-boot/m1n1.bin": b"another m1n1"}, [])
        self.channel.sign(archive)
        self.refused("is not the archive the channel database lists", database, sha256)

    def test_a_database_changed_after_pinning_is_refused(self):
        database, pinned = self.snapshot()
        shutil.rmtree(self.work / "edge")
        database, _ = self.snapshot(versions={"omarchy-mac": "0.1.5-1"})
        self.refused("the channel database changed since it was pinned", database, pinned)

    def test_a_runtime_that_does_not_provide_its_role_is_refused(self):
        database, sha256 = self.snapshot(entry_edit=lambda name, text: text.replace("%PROVIDES%\nomarchy\n\n", "")
                                         if name == "omarchy-dev" else text)
        self.refused("omarchy-dev does not provide omarchy", database, sha256)

    def test_a_database_without_a_set_package_is_refused(self):
        database, sha256 = self.snapshot(entry_edit=lambda name, text: text.replace("%NAME%\nuboot-asahi", "%NAME%\nuboot")
                                         if name == "uboot-asahi" else text)
        self.refused("uboot-asahi", database, sha256)

    def test_archive_metadata_must_match_the_database(self):
        database, sha256 = self.snapshot(entry_edit=lambda name, text: text.replace("%ARCH%\naarch64", "%ARCH%\nany")
                                         if name == "linux-aurora" else text)
        self.refused("linux-aurora is not an aarch64 package", database, sha256)

    def test_only_the_policys_lanes_are_built(self):
        database, sha256 = self.snapshot()
        self.refused("channel mode does not build stable", database, sha256, "stable")

    def test_the_candidate_import_never_accepts_the_channel_key(self):
        receipt = fixtures.make_set(self.work / "set-dir", self.candidate, key_signer=self.channel)
        with self.assertRaisesRegex(ValueError, "invalid signature: signing.json"):
            candidate_set.snapshot(self.work / "set-dir", self.work / "imported", receipt, fixtures.SOURCE,
                                   trust=self.trust)

    def test_installed_channel_packages_are_verified_against_the_pinned_database(self):
        database, sha256 = self.snapshot(extra=[("omarchy-keyring", "20251027-1")])
        cache = self.work / "edge/packages"
        keyring = next(cache.glob("omarchy-keyring-*"))
        self.channel.sign(keyring)
        lines = [f"omarchy-keyring|20251027-1|omarchy|{keyring.name}|{candidate_set.digest(keyring)}",
                 f"glibc|2.43-1|core|glibc-2.43-1-aarch64.pkg.tar.xz|{'5' * 64}"]
        records = self.work / "packages"
        records.write_text("\n".join(lines) + "\n")
        self.assertEqual(channel_set.verify_installed(database, sha256, records, cache, self.trust), 1)
        Path(str(keyring) + ".sig").unlink()
        with self.assertRaisesRegex(ValueError, "unsigned package"):
            channel_set.verify_installed(database, sha256, records, cache, self.trust)
        self.other.sign(keyring)
        with self.assertRaisesRegex(ValueError, "invalid signature"):
            channel_set.verify_installed(database, sha256, records, cache, self.trust)
        with self.assertRaisesRegex(ValueError, "changed since it was pinned"):
            channel_set.verify_installed(database, "0" * 64, records, cache, self.trust)
        records.write_text(lines[0].replace(candidate_set.digest(keyring), "6" * 64) + "\n")
        with self.assertRaisesRegex(ValueError, "is not the pinned channel database's"):
            channel_set.verify_installed(database, sha256, records, cache, self.trust)


class ChannelTrustTest(unittest.TestCase):
    def test_the_policy_pins_the_omarchy_package_key(self):
        policy, channel = channel_set.load_policy()
        listing = subprocess.check_output(["gpg", "--batch", "--show-keys", "--with-colons",
                                           str(ROOT / "builder/keys/omarchy-repository.gpg")], text=True,
                                          stderr=subprocess.DEVNULL)
        fingerprint = next(line.split(":")[9] for line in listing.splitlines() if line.startswith("fpr:"))
        self.assertEqual(channel["primary_fingerprint"], fingerprint, "the channel key is the image's repository key")
        self.assertEqual(channel["signing_fingerprint"], fingerprint)
        self.assertNotEqual(policy["primary_fingerprint"], fingerprint, "the candidate test key is another key")
        self.assertEqual(channel["runtime_packages"]["omarchy"], "omarchy-dev")
        self.assertEqual(channel["lanes"], ["edge"])


if __name__ == "__main__":
    unittest.main()
