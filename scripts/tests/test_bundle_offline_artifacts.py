import hashlib
import json
from pathlib import Path
import runpy
import tempfile
import unittest


bundle = runpy.run_path(str(Path(__file__).resolve().parents[2] / "Packaging/bundle-offline-artifacts.py"))["bundle"]


class OfflineArtifactsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "source"
        self.source.mkdir()
        self.destination = self.root / "result"
        self.catalog = self.root / "catalog.json"
        self.model = {"status": "enabled"}
        for role in ("engine", "metadata", "payload"):
            data = ("offline " + role).encode()
            (self.source / role).write_bytes(data)
            self.model[role + "Artifact"] = {"fileName": role, "sizeBytes": len(data)}
            self.model[role + "Digest"] = "sha256:" + hashlib.sha256(data).hexdigest()
        self.write_catalog()

    def write_catalog(self, models=None):
        self.catalog.write_text(json.dumps({"models": models or [self.model]}))

    def test_complete_bundle_is_verified_and_sources_remain(self):
        self.assertEqual(bundle(self.catalog, self.source, self.destination), 3)
        for role in ("engine", "metadata", "payload"):
            self.assertEqual((self.source / role).read_bytes(), (self.destination / role).read_bytes())
            self.assertEqual((self.destination / role).stat().st_mode & 0o777, 0o444)

    def test_corrupt_file_does_not_publish_partial_bundle(self):
        (self.source / "payload").write_bytes(b"corrupt")
        with self.assertRaises(ValueError):
            bundle(self.catalog, self.source, self.destination)
        self.assertFalse(self.destination.exists())

    def test_missing_file_does_not_publish_partial_bundle(self):
        (self.source / "metadata").unlink()
        with self.assertRaises(ValueError):
            bundle(self.catalog, self.source, self.destination)
        self.assertFalse(self.destination.exists())

    def test_symlink_is_not_accepted(self):
        (self.source / "payload").rename(self.source / "outside")
        (self.source / "payload").symlink_to(self.source / "outside")
        with self.assertRaises(ValueError):
            bundle(self.catalog, self.source, self.destination)
        self.assertFalse(self.destination.exists())

    def test_conflicting_same_named_payload_is_rejected(self):
        other = dict(self.model)
        other["payloadDigest"] = "sha256:" + "0" * 64
        self.write_catalog([self.model, other])
        with self.assertRaises(ValueError):
            bundle(self.catalog, self.source, self.destination)
        self.assertFalse(self.destination.exists())

    def test_disabled_model_needs_no_artifacts(self):
        self.write_catalog([self.model, {"status": "disabled"}])
        self.assertEqual(bundle(self.catalog, self.source, self.destination), 3)


if __name__ == "__main__":
    unittest.main()
