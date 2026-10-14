#!/usr/bin/env python3
"""Focused tests for the unsigned catalog generator."""
from __future__ import annotations

import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "make-unsigned-catalog.py"
TEMPLATE = Path(__file__).resolve().parents[1] / "release-inputs.template.json"
MANIFEST = Path(__file__).resolve().parents[1] / "supported-models.json"
M3_MACS = [
    "apple,j433", "apple,j434", "apple,j504", "apple,j613", "apple,j615",
    "apple,j514s", "apple,j514c", "apple,j514m", "apple,j516s", "apple,j516c",
    "apple,j516m",
]
BASE_URL = "https://downloads.example.test/releases/os-v1.0.0-mac.1.20260902"
NOW = "2026-09-04T00:00:00Z"


class CatalogGeneratorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = Path(
            tempfile.mkdtemp(prefix="omarchy-catalog-test-")
        )
        self.assets = self.directory / "assets"
        self.assets.mkdir()
        self.inputs = json.loads(TEMPLATE.read_text())
        for key in ("engine_name", "metadata_name", "payload_name"):
            (self.assets / self.inputs[key]).write_bytes(key.encode() * 64)

    def write_inputs(self, document: dict | None = None) -> Path:
        path = self.directory / "inputs.json"
        path.write_text(json.dumps(document or self.inputs, indent=2))
        return path

    def generate(
        self,
        document: dict | None = None,
        output: str = "catalog.json",
        developer: bool = False,
        only: list[str] | None = None,
    ):
        return subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--base-url",
                BASE_URL,
                "--assets-dir",
                str(self.assets),
                "--inputs",
                str(self.write_inputs(document)),
                "--output",
                str(self.directory / output),
                "--now",
                NOW,
                *(["--developer"] if developer else []),
                *[item for board in (only or []) for item in ("--developer-only-model", board)],
            ],
            capture_output=True,
            text=True,
        )

    def with_neo(self) -> dict:
        """The inputs plus a MacBook Neo group with its own split payload."""
        document = json.loads(json.dumps(self.inputs))
        neo = {
            "payload_name": "neo-os-package.zip",
            "metadata_name": "installer_data-neo.json",
            "device_identifiers": ["apple,j700"],
        }
        (self.assets / neo["metadata_name"]).write_bytes(b"neo-metadata" * 8)
        content = b"neo-payload" * 64
        (self.assets / neo["payload_name"]).write_bytes(content)
        (self.assets / f"{neo['payload_name']}.part00").write_bytes(content[:300])
        (self.assets / f"{neo['payload_name']}.part01").write_bytes(content[300:])
        document["developer_models"] = [neo]
        return document

    def assertRejected(self, document: dict, fragment: str, developer: bool = False) -> None:
        result = self.generate(document, developer=developer)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(fragment, result.stderr)

    def test_recommendation_engine_rejects_old_installer_minimum(self):
        self.inputs["installer"]["minimum_version"] = "2.0.10"
        self.assertRejected(self.inputs, "requires installer.minimum_version >= 2.1.0")

    def test_emits_schema_four_without_an_expiry(self) -> None:
        result = self.generate()
        self.assertEqual(result.returncode, 0, result.stderr)
        catalog = json.loads((self.directory / "catalog.json").read_text())
        self.assertEqual(catalog["schemaVersion"], 4)
        self.assertNotIn("expiresAt", catalog)
        self.assertEqual(catalog["issuedAt"], NOW)
        self.assertEqual(catalog["sequence"], 1788480000)
        self.assertEqual(len(catalog["models"]), len(self.inputs["device_identifiers"]))

    def test_carries_the_installer_compatibility_block(self) -> None:
        self.inputs["installer"]["minimum_version"] = "2.1.0"
        self.inputs["installer"]["latest_version"] = "2.3.0"
        result = self.generate()
        self.assertEqual(result.returncode, 0, result.stderr)
        catalog = json.loads((self.directory / "catalog.json").read_text())
        self.assertEqual(
            catalog["installer"],
            {
                "minimumVersion": "2.1.0",
                "latestVersion": "2.3.0",
                "downloadURL": self.inputs["installer"]["download_url"],
            },
        )

    def test_artifact_urls_sit_under_the_base_url(self) -> None:
        self.generate()
        catalog = json.loads((self.directory / "catalog.json").read_text())
        model = catalog["models"][0]
        for role in ("engineArtifact", "metadataArtifact", "payloadArtifact"):
            self.assertTrue(model[role]["sourceURL"].startswith(f"{BASE_URL}/"))

    def test_the_same_inputs_produce_the_same_bytes(self) -> None:
        self.generate(output="first.json")
        self.generate(output="second.json")
        self.assertEqual(
            (self.directory / "first.json").read_bytes(),
            (self.directory / "second.json").read_bytes(),
        )

    def test_a_split_payload_proves_its_parts_concatenate(self) -> None:
        payload = self.assets / self.inputs["payload_name"]
        content = payload.read_bytes()
        half = len(content) // 2
        (self.assets / f"{payload.name}.part00").write_bytes(content[:half])
        (self.assets / f"{payload.name}.part01").write_bytes(content[half:])
        self.generate()
        catalog = json.loads((self.directory / "catalog.json").read_text())
        parts = catalog["models"][0]["payloadArtifact"]["parts"]
        self.assertEqual([part["fileName"] for part in parts],
                         [f"{payload.name}.part00", f"{payload.name}.part01"])
        self.assertEqual(
            sum(part["sizeBytes"] for part in parts),
            catalog["models"][0]["payloadArtifact"]["sizeBytes"],
        )

    def test_a_corrupt_part_is_rejected(self) -> None:
        payload = self.assets / self.inputs["payload_name"]
        content = payload.read_bytes()
        half = len(content) // 2
        (self.assets / f"{payload.name}.part00").write_bytes(content[:half])
        (self.assets / f"{payload.name}.part01").write_bytes(b"x" * (len(content) - half))
        result = self.generate()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("do not concatenate", result.stderr)

    def test_an_unknown_inputs_key_is_rejected(self) -> None:
        document = dict(self.inputs)
        document["unexpected"] = "value"
        self.assertRejected(document, "unknown keys")

    def test_a_missing_inputs_key_is_rejected(self) -> None:
        document = dict(self.inputs)
        del document["engine_version"]
        self.assertRejected(document, "missing keys")

    def test_a_minimum_newer_than_the_latest_is_rejected(self) -> None:
        document = json.loads(json.dumps(self.inputs))
        document["installer"]["minimum_version"] = "3.0.0"
        self.assertRejected(document, "newer than")

    def test_a_plain_http_download_url_is_rejected(self) -> None:
        document = json.loads(json.dumps(self.inputs))
        document["installer"]["download_url"] = "http://downloads.example.test/a.pkg"
        self.assertRejected(document, "must be https")

    def test_a_malformed_installer_version_is_rejected(self) -> None:
        document = json.loads(json.dumps(self.inputs))
        document["installer"]["latest_version"] = "2.0"
        self.assertRejected(document, "installer.latest_version")

    def test_a_malformed_device_identifier_is_rejected(self) -> None:
        document = json.loads(json.dumps(self.inputs))
        document["device_identifiers"] = ["apple,j314s", "Apple,J999"]
        self.assertRejected(document, "invalid device identifier")

    def test_duplicate_device_identifiers_are_rejected(self) -> None:
        document = json.loads(json.dumps(self.inputs))
        document["device_identifiers"] = ["apple,j314s", "apple,j314s"]
        self.assertRejected(document, "duplicates")

    def test_every_m3_mac_is_required(self) -> None:
        for identifier in M3_MACS:
            document = json.loads(json.dumps(self.inputs))
            document["device_identifiers"].remove(identifier)
            self.assertRejected(document, f"missing {identifier}")

    def test_an_m1_and_m2_only_list_is_rejected(self) -> None:
        document = json.loads(json.dumps(self.inputs))
        document["device_identifiers"] = [
            identifier
            for identifier in document["device_identifiers"]
            if identifier not in M3_MACS
        ]
        self.assertRejected(document, "every M1, M2 and M3 Mac must be enabled")

    def test_refused_and_unknown_macs_are_rejected_with_a_reason(self) -> None:
        for identifier, fragment in (
            ("apple,j575d", "no j575dap device or T6032 chip"),
            ("apple,j614s", "M4 and later"),
            ("apple,j604", "not in scripts/supported-models.json"),
        ):
            document = json.loads(json.dumps(self.inputs))
            document["device_identifiers"].append(identifier)
            self.assertRejected(document, fragment)

    def test_the_manifest_is_every_m1_m2_and_m3_mac(self) -> None:
        manifest = json.loads(MANIFEST.read_text())
        self.assertEqual(len(manifest["supported"]), 34)
        self.assertTrue(set(M3_MACS) <= set(manifest["supported"]))
        self.assertEqual(set(manifest["refused"]), {"apple,j575d", "apple,j614s"})
        self.assertEqual(set(manifest["developer"]), {"apple,j700"})
        for template in sorted(MANIFEST.parent.glob("release-inputs*.template.json")):
            identifiers = json.loads(template.read_text())["device_identifiers"]
            self.assertEqual(
                sorted(identifiers), sorted(manifest["supported"]), template.name
            )

    def test_the_generated_catalog_enables_every_supported_mac(self) -> None:
        result = self.generate()
        self.assertEqual(result.returncode, 0, result.stderr)
        catalog = json.loads((self.directory / "catalog.json").read_text())
        check = subprocess.run(
            [
                sys.executable,
                str(SCRIPT.with_name("supported_models.py")),
                "check-catalog",
                str(self.directory / "catalog.json"),
            ],
            capture_output=True,
            text=True,
        )
        self.assertEqual(check.returncode, 0, check.stderr)
        self.assertTrue(all(m["status"] == "enabled" for m in catalog["models"]))

    def test_an_uppercase_evidence_revision_is_rejected(self) -> None:
        document = json.loads(json.dumps(self.inputs))
        document["evidence_revision"] = "4.0.2-MAC.1"
        self.assertRejected(document, "evidence_revision")

    def test_a_payload_name_with_a_path_is_rejected(self) -> None:
        document = json.loads(json.dumps(self.inputs))
        document["payload_name"] = "../escape.zip"
        self.assertRejected(document, "plain file name")

    def test_a_short_revision_is_rejected(self) -> None:
        document = json.loads(json.dumps(self.inputs))
        document["downstream_revision"] = "abc123"
        self.assertRejected(document, "40-character hex")

    def test_the_committed_template_is_valid(self) -> None:
        result = self.generate()
        self.assertEqual(result.returncode, 0, result.stderr)
        catalog = json.loads((self.directory / "catalog.json").read_text())
        digest = hashlib.sha256(
            (self.assets / self.inputs["payload_name"]).read_bytes()
        ).hexdigest()
        self.assertEqual(
            catalog["models"][0]["payloadDigest"], f"sha256:{digest}"
        )

    def test_explicit_neo_only_catalog_needs_no_main_assets(self) -> None:
        document = self.with_neo()
        for key in ("metadata_name", "payload_name"):
            (self.assets / document[key]).unlink()
        result = self.generate(document, developer=True, only=["apple,j700"])
        self.assertEqual(result.returncode, 0, result.stderr)
        models = json.loads((self.directory / "catalog.json").read_text())["models"]
        self.assertEqual([m["deviceIdentifier"] for m in models], ["apple,j700"])
        self.assertEqual(models[0]["payloadArtifact"]["fileName"], "neo-os-package.zip")
        self.assertEqual(len(models[0]["payloadArtifact"]["parts"]), 2)

    def test_model_selection_requires_explicit_developer_mode(self) -> None:
        result = self.generate(only=["apple,j700"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires --developer", result.stderr)

    def test_model_selection_rejects_undeclared_or_production_boards_and_duplicates(self) -> None:
        for boards in (["apple,j700"], ["apple,j613"], ["apple,j700", "apple,j700"]):
            document = self.inputs if boards == ["apple,j700"] else self.with_neo()
            result = self.generate(document, developer=True, only=boards)
            self.assertNotEqual(result.returncode, 0, boards)

    def test_model_selection_keeps_input_coverage_and_selected_asset_validation(self) -> None:
        document = self.with_neo()
        document["device_identifiers"].remove("apple,j613")
        result = self.generate(document, developer=True, only=["apple,j700"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing apple,j613", result.stderr)
        document = self.with_neo()
        (self.assets / "neo-os-package.zip").unlink()
        result = self.generate(document, developer=True, only=["apple,j700"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unsafe or missing asset", result.stderr)

    def test_a_developer_catalog_gives_the_neo_its_own_payload(self) -> None:
        result = self.generate(self.with_neo(), developer=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        models = json.loads((self.directory / "catalog.json").read_text())["models"]
        self.assertEqual(
            [m["deviceIdentifier"] for m in models],
            self.inputs["device_identifiers"] + ["apple,j700"],
        )
        main, neo = models[0], models[-1]
        self.assertEqual(main["payloadArtifact"]["fileName"], self.inputs["payload_name"])
        self.assertNotIn("parts", main["payloadArtifact"])
        self.assertEqual(neo["payloadArtifact"]["fileName"], "neo-os-package.zip")
        self.assertEqual(neo["metadataArtifact"]["fileName"], "installer_data-neo.json")
        self.assertEqual(len(neo["payloadArtifact"]["parts"]), 2)
        self.assertEqual(neo["engineArtifact"], main["engineArtifact"])
        neo_digest = hashlib.sha256((self.assets / "neo-os-package.zip").read_bytes()).hexdigest()
        self.assertEqual(neo["payloadDigest"], f"sha256:{neo_digest}")

    def test_developer_models_need_the_developer_flag(self) -> None:
        self.assertRejected(self.with_neo(), "unknown keys")

    def test_a_developer_group_takes_only_developer_boards(self) -> None:
        for identifier, fragment in (
            ("apple,j293", "lists apple,j293 twice"),
            ("apple,j614s", "not a developer board"),
            ("apple,j604", "not a developer board"),
        ):
            document = self.with_neo()
            document["developer_models"][0]["device_identifiers"] = [identifier]
            self.assertRejected(document, fragment, developer=True)

    def test_a_developer_group_can_give_supported_macs_their_own_metadata(self) -> None:
        document = self.with_neo()
        airs = ["apple,j613", "apple,j615"]
        for identifier in airs:
            document["device_identifiers"].remove(identifier)
        (self.assets / "installer_data-m3air.json").write_bytes(b"air-metadata" * 8)
        document["developer_models"].append({
            "payload_name": self.inputs["payload_name"],
            "metadata_name": "installer_data-m3air.json",
            "device_identifiers": airs,
        })
        result = self.generate(document, developer=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        models = {
            m["deviceIdentifier"]: m
            for m in json.loads((self.directory / "catalog.json").read_text())["models"]
        }
        self.assertEqual(len(models), len(self.inputs["device_identifiers"]) + 1)
        main = models["apple,j293"]
        for identifier in airs:
            self.assertEqual(models[identifier]["metadataArtifact"]["fileName"], "installer_data-m3air.json")
            self.assertEqual(models[identifier]["payloadArtifact"], main["payloadArtifact"])
            self.assertEqual(models[identifier]["payloadDigest"], main["payloadDigest"])
        self.assertEqual(main["metadataArtifact"]["fileName"], self.inputs["metadata_name"])

    def test_a_moved_mac_cannot_stay_in_the_main_group(self) -> None:
        document = self.with_neo()
        document["developer_models"][0]["device_identifiers"] = ["apple,j613"]
        self.assertRejected(document, "lists apple,j613 twice", developer=True)

    def test_a_developer_group_reuses_no_file_name(self) -> None:
        document = self.with_neo()
        document["developer_models"][0]["metadata_name"] = self.inputs["metadata_name"]
        self.assertRejected(document, "reuses the file name", developer=True)

    def test_the_main_group_still_covers_every_mac_in_a_developer_catalog(self) -> None:
        document = self.with_neo()
        document["device_identifiers"].remove("apple,j613")
        self.assertRejected(document, "missing apple,j613", developer=True)

    def test_a_developer_catalog_never_passes_the_channel_check(self) -> None:
        self.generate(self.with_neo(), developer=True)
        check = subprocess.run(
            [
                sys.executable,
                str(SCRIPT.with_name("supported_models.py")),
                "check-catalog",
                str(self.directory / "catalog.json"),
            ],
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(check.returncode, 0)
        self.assertIn("apple,j700 is not in scripts/supported-models.json", check.stderr)


if __name__ == "__main__":
    unittest.main()
