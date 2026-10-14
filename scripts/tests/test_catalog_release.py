#!/usr/bin/env python3
"""The Mac catalog release: build, evidence gate, CI signing, hosts, dry run,
and promotion to rc and stable.

Driven through scripts/catalog_release.py's command line, as the workflow
runs it, with a throwaway Ed25519 key. Signing needs OpenSSL 3; on a Mac the
signatures are also checked with catalog-signing.swift verify.
"""
from __future__ import annotations

import base64
import contextlib
import datetime
import hashlib
import importlib.util
import io
import json
import os
import platform
import shutil
import subprocess
import sys
import tempfile
import unittest
import urllib.error
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "catalog_release.py"
SIGNING_TOOL = ROOT / "scripts" / "catalog-signing.swift"
WORKFLOWS = ROOT / ".github" / "workflows"
WORKFLOW = WORKFLOWS / "mac-catalog.yml"
SIGN_WORKFLOW = WORKFLOWS / "mac-catalog-sign.yml"
PROMOTE_WORKFLOW = WORKFLOWS / "mac-promote.yml"
FIXTURE = ROOT / "Tests" / "OmarchyAppleInstallerTrustCoreTests" / "Fixtures" / "ci-signed-catalog"

spec = importlib.util.spec_from_file_location("catalog_release", SCRIPT)
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)

try:
    OPENSSL = release.find_openssl()
except release.Refusal:
    OPENSSL = None
if OPENSSL is None and os.environ.get("CI"):
    raise SystemExit("CI must provide OpenSSL 3 for the catalog signing tests")

IMAGE = "omarchy-mac-edge-2026.10.14-0123456789ab"
NOW = "2026-10-14T00:00:00Z"
SEQUENCE = int(datetime.datetime(2026, 10, 14, tzinfo=datetime.timezone.utc).timestamp())
REVISION = "1" * 40


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def release_base(tag: str) -> str:
    return f"https://github.com/{release.stopgap_repo()}/releases/download/{tag}"


def artifact(tag: str, name: str, data: bytes) -> dict:
    return {"url": f"{release_base(tag)}/{name}", "fileName": name, "sizeBytes": len(data), "sha256": sha(data)}


PAYLOAD_PARTS = [b"payload-part-zero" * 50, b"payload-part-one" * 40]
PAYLOAD = b"".join(PAYLOAD_PARTS)
ENGINE = b"engine-tarball" * 30
METADATA = b'{"os_list": []}\n'
ZIP = f"{IMAGE}.zip"


def payload_document() -> dict:
    document = artifact(IMAGE, ZIP, PAYLOAD)
    document["parts"] = [
        artifact(IMAGE, f"{ZIP}.part{index:02d}", part) for index, part in enumerate(PAYLOAD_PARTS)
    ]
    return document


def engine_document() -> dict:
    return dict(
        artifact("engine-v0.9.2-omarchy.28", "installer-v0.9.2-omarchy.28.tar.gz", ENGINE),
        version="v0.9.2-omarchy.28",
        downstreamRevision=REVISION,
    )


def installer_document() -> dict:
    return {"minimumVersion": "2.1.0", "latestVersion": "2.1.0",
            "downloadURL": f"{release_base('app-v2.1.0')}/Omarchy-Installer.dmg"}


def evidence_document(image_sha256: str = sha(PAYLOAD)) -> dict:
    return {
        "image_sha256": image_sha256,
        "result": "pass",
        "scenarios": [
            {"name": "first-boot", "result": "pass"},
            {"name": "conversion", "result": "pass"},
            {"name": "second-boot", "result": "pass"},
        ],
        "harness_commit": "2" * 40,
        "runner": "namespace linux-on-apple arm64",
        "run_url": "https://github.com/example/acceptance/actions/runs/1",
    }


def generate_key(directory: Path) -> tuple[str, Path]:
    """A throwaway key: its base64 seed and its trust-root file."""
    der = subprocess.run(
        [OPENSSL, "genpkey", "-algorithm", "ed25519", "-outform", "DER"], capture_output=True, check=True
    ).stdout
    seed = der[-32:]
    trust_root = directory / "trust-root.ed25519.pub"
    trust_root.write_bytes(release.openssl_public_key(OPENSSL, seed))
    return base64.b64encode(seed).decode(), trust_root


class ReleaseTestCase(unittest.TestCase):
    """A throwaway key, host tools that record and fail, and the CLI."""

    def setUp(self) -> None:
        self.directory = Path(tempfile.mkdtemp(prefix="omarchy-catalog-release-"))
        self.addCleanup(shutil.rmtree, self.directory)
        self.key, self.trust_root = generate_key(self.directory)
        self.bin = self.directory / "bin"
        self.bin.mkdir()
        self.calls = self.directory / "calls.log"
        self.calls.write_text("")
        # Anything that would reach a real host records itself and fails.
        for tool in ("gh", "curl", "aws", "wget"):
            shim = self.bin / tool
            shim.write_text(f'#!/bin/bash\nprintf "%s\\n" "{tool} $*" >>"{self.calls}"\nexit 97\n')
            shim.chmod(0o755)
        self.environment = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}", OMARCHY_OPENSSL=OPENSSL)
        self.environment.pop("CATALOG_SIGNING_KEY", None)
        self.environment.pop("GITHUB_REPOSITORY", None)

    def write(self, name: str, document: object) -> Path:
        path = self.directory / name
        path.write_text(json.dumps(document))
        return path

    def run_tool(self, *arguments: str, environment: dict | None = None) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, str(SCRIPT), *arguments],
            capture_output=True, text=True, env=environment or self.environment,
        )

    def prepare(self, evidence: object = "default", payload: dict | None = None, out: str = "out",
                *extra: str) -> subprocess.CompletedProcess:
        arguments = [
            "prepare", "--channel", "edge", "--image", IMAGE,
            "--payload", str(self.write("payload.json", payload or payload_document())),
            "--engine", str(self.write("engine.json", engine_document())),
            "--installer-data", str(self.write("metadata.json", artifact(IMAGE, "installer_data.json", METADATA))),
            "--installer", str(self.write("installer.json", installer_document())),
            "--now", NOW, "--out", str(self.directory / out), *extra,
        ]
        if evidence is not None:
            document = evidence_document() if evidence == "default" else evidence
            arguments += ["--evidence", str(self.write("evidence.json", document))]
        return self.run_tool(*arguments)

    def sign(self, catalog: Path, key: str | None = None, trust_root: Path | None = None,
             out: str = "signed") -> subprocess.CompletedProcess:
        environment = dict(self.environment, CATALOG_SIGNING_KEY=self.key if key is None else key)
        return self.run_tool(
            "sign", "--key-env", "CATALOG_SIGNING_KEY", "--catalog", str(catalog),
            "--trust-root", str(trust_root or self.trust_root), "--out", str(self.directory / out),
            environment=environment,
        )

    def assert_refused(self, result: subprocess.CompletedProcess, reason: str) -> None:
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("refused", result.stderr)
        self.assertIn(reason, result.stderr)

    def built_catalog(self) -> Path:
        result = self.prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        return self.directory / "out" / "catalog-edge.json"

    def signed_at(self, now: str, out: str) -> Path:
        result = self.prepare("default", None, out, "--now", now)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.sign(self.directory / out / "catalog-edge.json", out=f"{out}-signed").returncode, 0)
        return self.directory / f"{out}-signed" / "catalog-edge.signed.json"


@unittest.skipIf(OPENSSL is None, "OpenSSL 3 is required")
class CatalogReleaseTests(ReleaseTestCase):
    # ── build, sign, verify ──────────────────────────────────────────────────

    def test_round_trip_enables_every_mac_and_pins_the_digests(self) -> None:
        catalog_path = self.built_catalog()
        catalog = json.loads(catalog_path.read_text())
        supported, _ = release.supported_models.load()
        untested = release.supported_models.untested()
        self.assertEqual([model["deviceIdentifier"] for model in catalog["models"]], supported)
        self.assertEqual(catalog["schemaVersion"], 4)
        self.assertEqual(catalog["sequence"], SEQUENCE)
        self.assertNotIn("expiresAt", catalog)
        for model in catalog["models"]:
            self.assertEqual(model["status"], "enabled")
            self.assertEqual(model["payloadDigest"], f"sha256:{sha(PAYLOAD)}")
            self.assertEqual(model["engineDigest"], f"sha256:{sha(ENGINE)}")
            self.assertEqual(model["metadataDigest"], f"sha256:{sha(METADATA)}")
            self.assertEqual(model["evidenceRevision"], IMAGE)
            self.assertEqual(
                [part["sha256"] for part in model["payloadArtifact"]["parts"]],
                [f"sha256:{sha(part)}" for part in PAYLOAD_PARTS],
            )
            self.assertEqual(model.get("previewNote"), untested.get(model["deviceIdentifier"]))
        self.assertTrue(untested, "M3 Macs are marked untested")

        signed = self.sign(catalog_path)
        self.assertEqual(signed.returncode, 0, signed.stderr)
        self.assertNotIn(self.key, signed.stdout + signed.stderr)
        envelope = self.directory / "signed" / "catalog-edge.signed.json"
        verified = self.run_tool("verify-envelope", "--envelope", str(envelope), "--trust-root", str(self.trust_root),
                                 "--expect-sha256", sha(catalog_path.read_bytes()))
        self.assertEqual(verified.returncode, 0, verified.stderr)
        self.assertIn("catalog_signature=passed", verified.stdout)
        document = json.loads(envelope.read_text())
        self.assertEqual(set(document), {"schema_version", "catalog", "signature"})
        self.assertEqual(base64.b64decode(document["catalog"]), catalog_path.read_bytes())
        self.assertEqual(self.calls.read_text(), "")

        if platform.system() == "Darwin" and shutil.which("xcrun"):
            signature = self.directory / "signed" / "catalog-edge.json.sig"
            swift = subprocess.run(
                ["xcrun", "swift", str(SIGNING_TOOL), "verify", str(self.trust_root), str(catalog_path),
                 str(signature)], capture_output=True, text=True,
            )
            self.assertEqual(swift.stdout.strip(), "catalog_signature=passed", swift.stderr)

    def test_a_tampered_envelope_does_not_verify(self) -> None:
        self.assertEqual(self.sign(self.built_catalog()).returncode, 0)
        envelope = self.directory / "signed" / "catalog-edge.signed.json"
        document = json.loads(envelope.read_text())
        catalog = base64.b64decode(document["catalog"]).replace(b'"enabled"', b'"disabled"', 1)
        document["catalog"] = base64.b64encode(catalog).decode()
        envelope.write_text(json.dumps(document))
        result = self.run_tool("verify-envelope", "--envelope", str(envelope), "--trust-root", str(self.trust_root))
        self.assert_refused(result, "does not verify")

    def test_the_app_fixture_verifies_and_covers_every_mac(self) -> None:
        trust_root = (FIXTURE / "trust-root.ed25519.pub").read_bytes()
        document = release.verify_envelope((FIXTURE / "catalog-edge.signed.json").read_bytes(), trust_root, OPENSSL)
        self.assertEqual(release.supported_models.catalog_errors(document), [])

    # ── the evidence gate ────────────────────────────────────────────────────

    def test_refuses_without_evidence(self) -> None:
        self.assert_refused(self.prepare(evidence=None), "no VM evidence record")
        self.assertFalse((self.directory / "out").exists())

    def test_refuses_failed_evidence(self) -> None:
        self.assert_refused(self.prepare(evidence=dict(evidence_document(), result="fail")), "did not pass")

    def test_refuses_evidence_for_another_image(self) -> None:
        self.assert_refused(self.prepare(evidence=evidence_document("f" * 64)), "not " + sha(PAYLOAD))

    def test_refuses_evidence_missing_a_required_scenario(self) -> None:
        evidence = evidence_document()
        evidence["scenarios"] = evidence["scenarios"][:2]
        self.assert_refused(self.prepare(evidence=evidence), "no passing second-boot")

    def test_refuses_a_pass_with_a_failed_scenario(self) -> None:
        evidence = evidence_document()
        evidence["scenarios"].append({"name": "update", "result": "fail"})
        self.assert_refused(self.prepare(evidence=evidence), "scenarios failed: update")

    def test_refuses_malformed_evidence(self) -> None:
        self.assert_refused(self.prepare(evidence=dict(evidence_document(), harness_commit="main")), "harness_commit")
        self.assert_refused(self.prepare(evidence=["pass"]), "JSON object")
        missing = evidence_document()
        del missing["run_url"]
        self.assert_refused(self.prepare(evidence=missing), "no run_url")

    def test_the_signing_job_rechecks_the_evidence(self) -> None:
        catalog = self.built_catalog()
        ok = self.run_tool("check-evidence", "--catalog", str(catalog),
                           "--evidence", str(self.write("e.json", evidence_document())))
        self.assertEqual(ok.returncode, 0, ok.stderr)
        other = self.run_tool("check-evidence", "--catalog", str(catalog),
                              "--evidence", str(self.write("e.json", evidence_document("e" * 64))))
        self.assert_refused(other, "not " + sha(PAYLOAD))
        self.assert_refused(self.run_tool("check-evidence", "--catalog", str(catalog)), "no VM evidence")
        renamed = self.directory / "catalog-rc.json"
        shutil.copyfile(catalog, renamed)
        self.assert_refused(self.run_tool("check-evidence", "--catalog", str(renamed),
                                          "--evidence", str(self.write("e.json", evidence_document()))),
                            "rc and stable come from promotion")

    # ── inputs ───────────────────────────────────────────────────────────────

    def test_refuses_artifacts_outside_the_release_locations(self) -> None:
        payload = payload_document()
        payload["parts"][0]["url"] = payload["parts"][0]["url"].replace("github.com", "example.com")
        self.assert_refused(self.prepare(payload=payload), "not under an allowed release location")
        payload = payload_document()
        payload["url"] = f"{release_base('catalog-edge')}/{ZIP}"
        self.assert_refused(self.prepare(payload=payload), "immutable release tag")
        payload = payload_document()
        payload["url"] = payload["url"] + "?x=1"
        self.assert_refused(self.prepare(payload=payload), "plain https URL")

    def test_refuses_inconsistent_parts(self) -> None:
        payload = payload_document()
        payload["sizeBytes"] += 1
        self.assert_refused(self.prepare(payload=payload), "parts sum to")
        payload = payload_document()
        payload["parts"][1]["fileName"] = "other.zip"
        self.assert_refused(self.prepare(payload=payload), "must end with its fileName")

    def test_refuses_another_channel_or_image_name(self) -> None:
        result = self.run_tool("prepare", "--channel", "stable", "--image", IMAGE, "--payload", "x",
                               "--engine", "x", "--installer-data", "x", "--out", str(self.directory / "o"))
        self.assert_refused(result, "rc and stable come from promotion")
        with self.assertRaisesRegex(release.Refusal, "image must be"):
            release.check_image_name("omarchy-mac-edge-latest", "edge")

    # ── signing ──────────────────────────────────────────────────────────────

    def test_refuses_a_key_that_is_not_the_trust_root(self) -> None:
        other = self.directory / "other"
        other.mkdir()
        other_key, _ = generate_key(other)
        self.assert_refused(self.sign(self.built_catalog(), key=other_key), "does not match the trust root")
        self.assertFalse((self.directory / "signed").exists())

    def test_refuses_a_malformed_or_missing_key(self) -> None:
        catalog = self.built_catalog()
        self.assert_refused(self.sign(catalog, key="not-a-key"), "is not base64")
        # 32 characters in the variable are base64 text, never a raw key.
        self.assert_refused(self.sign(catalog, key="A" * 32), "not a 32-byte")
        self.assert_refused(self.sign(catalog, key=base64.b64encode(b"short").decode()), "not a 32-byte")
        self.assert_refused(self.sign(catalog, key=""), "empty or unset")

    def test_the_key_file_form_signs_the_same_bytes(self) -> None:
        catalog = self.built_catalog()
        key_file = self.directory / "key.raw"
        key_file.write_bytes(base64.b64decode(self.key))
        result = self.run_tool("sign", "--key-file", str(key_file), "--catalog", str(catalog),
                               "--trust-root", str(self.trust_root), "--out", str(self.directory / "from-file"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.sign(catalog).returncode, 0)
        # Ed25519 is deterministic: one key, one catalog, one signature.
        self.assertEqual((self.directory / "from-file" / "catalog-edge.signed.json").read_bytes(),
                         (self.directory / "signed" / "catalog-edge.signed.json").read_bytes())

    # ── hosts and the dry run ────────────────────────────────────────────────

    def test_a_dry_run_touches_nothing_but_scratch(self) -> None:
        """The workflow's dry run: prepare, sign, publish to a scratch host."""
        scratch = self.directory / "scratch-host"
        result = self.prepare("default", None, "out", "--check-live", "--host", f"scratch:{scratch}",
                              "--trust-root", str(self.trust_root))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.sign(self.directory / "out" / "catalog-edge.json").returncode, 0)
        envelope = self.directory / "signed" / "catalog-edge.signed.json"
        published = self.run_tool("publish", "--channel", "edge", "--envelope", str(envelope),
                                  "--host", f"scratch:{scratch}", "--trust-root", str(self.trust_root))
        self.assertEqual(published.returncode, 0, published.stderr)
        self.assertEqual((scratch / "catalog-edge.signed.json").read_bytes(), envelope.read_bytes())
        self.assertEqual(self.calls.read_text(), "", "a dry run must not call any host tool")

    def test_publish_refuses_a_sequence_that_does_not_move_forward(self) -> None:
        scratch = self.directory / "scratch-host"

        def publish(envelope: Path) -> subprocess.CompletedProcess:
            return self.run_tool("publish", "--channel", "edge", "--envelope", str(envelope),
                                 "--host", f"scratch:{scratch}", "--trust-root", str(self.trust_root))

        newer = self.signed_at(NOW, "newer")
        older = self.signed_at("2026-10-13T00:00:00Z", "older")
        self.assertEqual(publish(newer).returncode, 0)
        self.assert_refused(publish(older), f"does not follow the published {SEQUENCE}")
        self.assertEqual((scratch / "catalog-edge.signed.json").read_bytes(), newer.read_bytes())
        (scratch / "catalog-edge.signed.json").write_text("{}")
        self.assert_refused(publish(newer), "does not verify")

    def fake_github(self) -> Path:
        """A gh stand-in holding one repository's releases in a directory."""
        state = self.directory / "github"
        (state / "assets").mkdir(parents=True)
        gh = self.bin / "gh"
        gh.write_text(f"""#!{sys.executable}
import json, os, shutil, sys
from pathlib import Path
state = Path({str(state)!r})
arguments = sys.argv[1:]
with open({str(self.calls)!r}, "a") as log:
    log.write("gh " + " ".join(arguments) + "\\n")
release = state / "release.json"
def load():
    return json.loads(release.read_text())
def save(document):
    release.write_text(json.dumps(document))
if arguments[:1] == ["api"] and "/releases/tags/" in arguments[1]:
    if not release.exists():
        sys.stderr.write("gh: Not Found (HTTP 404)\\n")
        sys.exit(1)
    print(release.read_text())
elif arguments[:2] == ["release", "create"]:
    save({{"draft": False, "prerelease": True, "assets": []}})
elif arguments[:2] == ["release", "upload"]:
    if (state / "upload-fails").exists():
        sys.exit(1)
    source = Path(arguments[3])
    document = load()
    identifier = 1 + max([asset["id"] for asset in document["assets"]] + [0])
    document["assets"].append({{"id": identifier, "name": source.name}})
    shutil.copyfile(source, state / "assets" / source.name)
    save(document)
elif arguments[:3] == ["api", "-X", "PATCH"] and (state / "rename-fails").exists():
    sys.exit(1)
elif arguments[:3] in (["api", "-X", "DELETE"], ["api", "-X", "PATCH"]):
    identifier = int(arguments[3].rsplit("/", 1)[1])
    document = load()
    asset = next(asset for asset in document["assets"] if asset["id"] == identifier)
    if arguments[2] == "DELETE":
        document["assets"].remove(asset)
        (state / "assets" / asset["name"]).unlink()
    else:
        name = arguments[5].split("=", 1)[1]
        os.replace(state / "assets" / asset["name"], state / "assets" / name)
        asset["name"] = name
    save(document)
else:
    sys.exit(97)
""")
        return state

    def publish_to_fake_github(self, envelope: Path, state: Path) -> tuple[int, str]:
        host = release.GitHubReleaseHost(release.stopgap_repo())
        served = state / "assets" / "catalog-edge.signed.json"

        def fake_open(url, timeout=60):
            self.assertEqual(url, host.describe("edge"))
            if not served.exists():
                raise urllib.error.HTTPError(url, 404, "Not Found", {}, io.BytesIO())
            return contextlib.closing(io.BytesIO(served.read_bytes()))

        arguments = ["publish", "--channel", "edge", "--envelope", str(envelope), "--host", "github-release",
                     "--trust-root", str(self.trust_root)]
        saved = release.open_url, dict(os.environ)
        release.open_url = fake_open
        os.environ.update(PATH=self.environment["PATH"], OMARCHY_OPENSSL=OPENSSL)
        os.environ.pop("GITHUB_REPOSITORY", None)
        try:
            output = io.StringIO()
            with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
                status = release.main(arguments)
            return status, output.getvalue()
        finally:
            release.open_url = saved[0]
            os.environ.clear()
            os.environ.update(saved[1])

    def test_the_github_release_host_swaps_the_catalog_in(self) -> None:
        state = self.fake_github()
        served = state / "assets" / "catalog-edge.signed.json"
        first = self.signed_at("2026-10-14T00:00:00Z", "first")
        status, output = self.publish_to_fake_github(first, state)
        self.assertEqual(status, 0, output)
        calls = self.calls.read_text().splitlines()
        self.assertTrue(any(c.startswith("gh release create catalog-edge") and "--prerelease --latest=false" in c
                            for c in calls), calls)
        self.assertFalse(any("--clobber" in c for c in calls))
        self.assertEqual(served.read_bytes(), first.read_bytes())

        # A retry of the same envelope is a no-op, not a sequence refusal.
        status, output = self.publish_to_fake_github(first, state)
        self.assertEqual(status, 0, output)
        self.assertIn("already live", output)

        # A failed upload leaves the published catalog in place.
        second = self.signed_at("2026-10-15T00:00:00Z", "second")
        (state / "upload-fails").touch()
        status, output = self.publish_to_fake_github(second, state)
        self.assertEqual(status, 1, output)
        self.assertEqual(served.read_bytes(), first.read_bytes())
        (state / "upload-fails").unlink()
        status, output = self.publish_to_fake_github(second, state)
        self.assertEqual(status, 0, output)
        self.assertEqual(served.read_bytes(), second.read_bytes())
        self.assertEqual(sorted(p.name for p in (state / "assets").iterdir()), ["catalog-edge.signed.json"])

    def test_a_failed_swap_blocks_every_later_publish(self) -> None:
        state = self.fake_github()
        saved_sleep = release.time.sleep
        release.time.sleep = lambda seconds: None
        try:
            self.assertEqual(self.publish_to_fake_github(self.signed_at("2026-10-14T00:00:00Z", "a"), state)[0], 0)
            newer = self.signed_at("2026-10-16T00:00:00Z", "c")
            (state / "rename-fails").touch()
            status, output = self.publish_to_fake_github(newer, state)
            self.assertEqual(status, 1, output)
            self.assertIn("rename it by hand", output)
            (state / "rename-fails").unlink()
            # The channel now serves nothing; an older envelope must not slip in.
            status, output = self.publish_to_fake_github(self.signed_at("2026-10-15T00:00:00Z", "b"), state)
            self.assertEqual(status, 1, output)
            self.assertIn("left catalog-edge.signed.json.next", output)
            self.assertEqual((state / "assets" / "catalog-edge.signed.json.next").read_bytes(), newer.read_bytes())
        finally:
            release.time.sleep = saved_sleep

    def test_the_github_release_host_refuses_a_draft(self) -> None:
        state = self.fake_github()
        (state / "release.json").write_text('{"draft": true, "prerelease": true, "assets": []}')
        status, output = self.publish_to_fake_github(self.signed_at(NOW, "draft"), state)
        self.assertEqual(status, 1)
        self.assertIn("must be a published prerelease", output)

    def test_only_this_repository_releases_catalogs(self) -> None:
        environment = dict(self.environment, GITHUB_REPOSITORY="someone/fork")
        result = self.run_tool("publish", "--channel", "edge", "--envelope", "x", "--host", "scratch:/nonexistent",
                               environment=environment)
        self.assert_refused(result, "not someone/fork")

    # ── remote verification ──────────────────────────────────────────────────

    def test_remote_verification_checks_every_part_and_the_whole(self) -> None:
        served = {part["url"]: data for part, data in zip(payload_document()["parts"], PAYLOAD_PARTS)}
        saved = release.open_url
        release.open_url = lambda url, timeout=60: contextlib.closing(io.BytesIO(served[url]))
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                release.verify_remote_artifact(payload_document(), "payload")
            first = payload_document()["parts"][0]["url"]
            served[first] = served[first][:-1] + b"X"
            with self.assertRaisesRegex(release.Refusal, "not the pinned"):
                release.verify_remote_artifact(payload_document(), "payload")
            served[first] = PAYLOAD_PARTS[0] + b"extra"
            with self.assertRaisesRegex(release.Refusal, "more than its pinned"):
                release.verify_remote_artifact(payload_document(), "payload")
        finally:
            release.open_url = saved

    # ── the workflows ────────────────────────────────────────────────────────

    def test_the_key_is_read_in_one_approved_step_of_one_workflow(self) -> None:
        texts = {path.name: path.read_text() for path in sorted(WORKFLOWS.glob("*.y*ml"))}
        # The release pipeline only passes the key on to mac-catalog.yml by name
        # (test_release_pipeline.py checks it passes nothing else, to nothing else).
        self.assertEqual([name for name, text in texts.items() if "CATALOG_SIGNING_KEY }}" in text],
                         ["mac-catalog-sign.yml", "mac-release-pipeline.yml"])
        self.assertEqual([name for name, text in texts.items() if "environment: catalog-release" in text],
                         ["mac-catalog-sign.yml"])
        text = texts["mac-catalog-sign.yml"]
        self.assertEqual(text.count("secrets."), 1)
        self.assertEqual(text.count("environment: catalog-release"), 1)
        self.assertIn("on:\n  workflow_call:\n", text)
        self.assertNotIn("workflow_dispatch", text)
        sign_job = text.split("\n  sign:\n")[1].split("\n  publish:\n")[0]
        self.assertIn("environment: catalog-release", sign_job)
        self.assertIn("secrets.CATALOG_SIGNING_KEY", sign_job)
        self.assertIn("contents: read", sign_job)
        self.assertIn("github.repository == 'omacom/omarchy-mac-installer'", sign_job)
        self.assertIn("github.ref == 'refs/heads/main'", sign_job)
        # Each gate runs only for its own channels, before the key is read.
        gate_step = sign_job.split("Check the catalog")[1].split("- name: Sign")[0]
        self.assertIn("evidence:edge)", gate_step)
        self.assertIn("promotion:rc | promotion:stable)", gate_step)
        publish_job = text.split("\n  publish:\n")[1]
        self.assertIn("needs.sign.result == 'success' && !inputs.dry-run", publish_job)
        self.assertNotIn("secrets.", publish_job)

    def test_both_catalog_writers_sign_through_the_shared_job(self) -> None:
        for workflow, gate in ((WORKFLOW, "evidence"), (PROMOTE_WORKFLOW, "promotion")):
            text = workflow.read_text()
            self.assertNotIn("pull_request", text)
            self.assertNotIn("secrets.", text)
            release_job = text.split("\n  release:\n")[1]
            self.assertIn("uses: ./.github/workflows/mac-catalog-sign.yml", release_job)
            self.assertIn(f"gate: {gate}", release_job)
            self.assertIn("dry-run: ${{ inputs.dry-run }}", release_job)
            self.assertIn("secrets: inherit", release_job)

    def test_promotion_is_parked_behind_approval_and_an_explicit_input(self) -> None:
        text = PROMOTE_WORKFLOW.read_text()
        self.assertIn("PARKED", text.split("\non:\n")[0])
        triggers = text.split("\non:\n")[1].split("\npermissions:")[0]
        self.assertIn("  workflow_dispatch:\n", triggers)
        for trigger in ("push:", "schedule:", "workflow_call:", "repository_dispatch:", "pull_request"):
            self.assertNotIn(trigger, triggers)
        dry_run = triggers.split("      dry-run:\n")[1].split("\n      confirm:")[0]
        self.assertIn("default: true", dry_run)
        self.assertIn("default: ''", triggers.split("      confirm:\n")[1])
        approve = text.split("\n  approve:\n")[1].split("\n  release:\n")[0]
        self.assertIn("environment: promote", approve)
        self.assertIn('promote-$CHANNEL', approve)
        self.assertIn("needs: [prepare, approve]", text.split("\n  release:\n")[1])
        prepare = text.split("\n  prepare:\n")[1].split("\n  approve:\n")[0]
        self.assertIn("--real --confirm", prepare)
        self.assertIn("--verify-remote --check-live", prepare)


LATER = "2026-10-20T00:00:00Z"
LATEST = "2026-10-21T00:00:00Z"


@unittest.skipIf(OPENSSL is None, "OpenSSL 3 is required")
class PromotionTests(ReleaseTestCase):
    """Promotion re-signs a published catalog's pins for rc or stable."""

    def setUp(self) -> None:
        super().setUp()
        self.host = self.directory / "scratch-host"

    def publish(self, channel: str, envelope: Path) -> subprocess.CompletedProcess:
        return self.run_tool("publish", "--channel", channel, "--envelope", str(envelope),
                             "--host", f"scratch:{self.host}", "--trust-root", str(self.trust_root))

    def published_edge(self) -> Path:
        envelope = self.signed_at(NOW, "edge")
        self.assertEqual(self.publish("edge", envelope).returncode, 0)
        return envelope

    def promote(self, channel: str = "rc", source: str = "edge", now: str = LATER, out: str = "promoted",
                *extra: str) -> subprocess.CompletedProcess:
        return self.run_tool("promote", "--channel", channel, "--source", source, "--host", f"scratch:{self.host}",
                             "--trust-root", str(self.trust_root), "--check-live", "--now", now,
                             "--out", str(self.directory / out), *extra)

    def signed_catalog(self, envelope: Path) -> tuple[bytes, dict]:
        catalog, _ = release.decode_envelope(envelope.read_bytes())
        return catalog, json.loads(catalog)

    def test_a_dry_run_promotes_the_edge_bytes_to_rc_then_stable(self) -> None:
        edge = self.published_edge()
        edge_bytes, edge_catalog = self.signed_catalog(edge)
        envelopes = {}
        for channel, source, now in (("rc", "edge", LATER), ("stable", "rc", LATEST)):
            result = self.promote(channel, source, now, f"{channel}-unsigned")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("mode=dry-run", result.stdout)
            catalog = self.directory / f"{channel}-unsigned" / f"catalog-{channel}.json"
            self.assertEqual((self.directory / f"{channel}-unsigned" / "channel").read_text(), f"{channel}\n")
            checked = self.run_tool("check-promotion", "--channel", channel, "--source-channel", source,
                                    "--catalog", str(catalog), "--trust-root", str(self.trust_root),
                                    "--source", str(self.directory / f"{channel}-unsigned" / "source.signed.json"))
            self.assertEqual(checked.returncode, 0, checked.stderr)
            self.assertEqual(self.sign(catalog, out=f"{channel}-signed").returncode, 0)
            envelopes[channel] = self.directory / f"{channel}-signed" / f"catalog-{channel}.signed.json"
            published = self.publish(channel, envelopes[channel])
            self.assertEqual(published.returncode, 0, published.stderr)

        sequences = [edge_catalog["sequence"]]
        for channel, now in (("rc", LATER), ("stable", LATEST)):
            verified = self.run_tool("verify-envelope", "--envelope", str(envelopes[channel]),
                                     "--trust-root", str(self.trust_root))
            self.assertIn("catalog_signature=passed", verified.stdout)
            _, catalog = self.signed_catalog(envelopes[channel])
            sequences.append(catalog["sequence"])
            self.assertEqual(catalog["issuedAt"], now)
            # The same models, pins, digests and installer block as edge.
            for key in set(edge_catalog) | set(catalog):
                if key not in ("sequence", "issuedAt"):
                    self.assertEqual(catalog.get(key), edge_catalog.get(key), key)
            for model in catalog["models"]:
                self.assertEqual(model["payloadDigest"], f"sha256:{sha(PAYLOAD)}")
                self.assertEqual(model["engineDigest"], f"sha256:{sha(ENGINE)}")
                self.assertEqual(model["metadataDigest"], f"sha256:{sha(METADATA)}")
                self.assertEqual(model["evidenceRevision"], IMAGE)
        self.assertEqual(sequences, sorted(set(sequences)))
        # Edge is untouched and nothing reached a real host.
        self.assertEqual((self.host / "catalog-edge.signed.json").read_bytes(), edge.read_bytes())
        self.assertEqual(sorted(path.name for path in self.host.iterdir()),
                         ["catalog-edge.signed.json", "catalog-rc.signed.json", "catalog-stable.signed.json"])
        self.assertEqual(self.calls.read_text(), "", "a dry run must not call any host tool")

    def test_promotion_rereads_every_pinned_artifact_and_uploads_nothing(self) -> None:
        self.published_edge()
        served = {part["url"]: data for part, data in zip(payload_document()["parts"], PAYLOAD_PARTS)}
        served[engine_document()["url"]] = ENGINE
        served[artifact(IMAGE, "installer_data.json", METADATA)["url"]] = METADATA
        requested = []

        def fake_open(url, timeout=60):
            requested.append(url)
            return contextlib.closing(io.BytesIO(served[url]))

        arguments = ["promote", "--channel", "rc", "--source", "edge", "--host", f"scratch:{self.host}",
                     "--trust-root", str(self.trust_root), "--verify-remote", "--now", LATER,
                     "--out", str(self.directory / "remote")]
        saved = release.open_url, dict(os.environ)
        release.open_url = fake_open
        os.environ.update(PATH=self.environment["PATH"], OMARCHY_OPENSSL=OPENSSL)
        os.environ.pop("GITHUB_REPOSITORY", None)
        try:
            output = io.StringIO()
            with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
                self.assertEqual(release.main(arguments), 0, output.getvalue())
            self.assertEqual(sorted(requested), sorted(served))
            first = payload_document()["parts"][0]["url"]
            served[first] = served[first][:-1] + b"X"
            with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
                self.assertEqual(release.main(arguments), 1)
            self.assertIn("not the pinned", output.getvalue())
        finally:
            release.open_url = saved[0]
            os.environ.clear()
            os.environ.update(saved[1])
        self.assertEqual(self.calls.read_text(), "")

    def test_a_tampered_source_catalog_is_refused(self) -> None:
        self.assert_refused(self.promote(), "no edge catalog is published")
        edge = self.published_edge()
        served = self.host / "catalog-edge.signed.json"

        document = json.loads(edge.read_text())
        catalog = base64.b64decode(document["catalog"]).replace(
            f"sha256:{sha(PAYLOAD)}".encode(), f"sha256:{'f' * 64}".encode())
        document["catalog"] = base64.b64encode(catalog).decode()
        served.write_text(json.dumps(document))
        self.assert_refused(self.promote(), "does not verify")

        other = self.directory / "other"
        other.mkdir()
        other_key, _ = generate_key(other)
        result = self.prepare("default", None, "foreign")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.sign(self.directory / "foreign" / "catalog-edge.json", key=other_key,
                                   trust_root=other / "trust-root.ed25519.pub", out="foreign-signed").returncode, 0)
        shutil.copyfile(self.directory / "foreign-signed" / "catalog-edge.signed.json", served)
        self.assert_refused(self.promote(), "does not verify")

        shutil.copyfile(edge, served)
        edge_sha256 = sha(self.signed_catalog(edge)[0])
        self.assert_refused(self.promote("rc", "edge", LATER, "promoted", "--source-sha256", "e" * 64),
                            f"sha256 {edge_sha256}, not the pinned")
        self.assertFalse((self.directory / "promoted").exists())
        self.assertEqual(self.promote("rc", "edge", LATER, "promoted", "--source-sha256", edge_sha256).returncode, 0)

    def test_real_promotion_is_parked_without_the_explicit_input(self) -> None:
        edge = self.published_edge()
        edge_sha256 = sha(self.signed_catalog(edge)[0])
        pin = ("--source-sha256", edge_sha256)
        self.assert_refused(self.promote("rc", "edge", LATER, "real", "--real", *pin), "promotion is parked")
        self.assert_refused(self.promote("rc", "edge", LATER, "real", "--real", "--confirm", "promote-stable", *pin),
                            "--confirm promote-rc")
        self.assert_refused(self.promote("rc", "edge", LATER, "real", "--real", "--confirm", "promote-rc"),
                            "must pin the source catalog")
        self.assertFalse((self.directory / "real").exists())
        result = self.promote("rc", "edge", LATER, "real", "--real", "--confirm", "promote-rc", *pin)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("mode=real", result.stdout)

    def test_the_signing_job_rechecks_the_promotion(self) -> None:
        self.published_edge()
        self.assertEqual(self.promote().returncode, 0)
        out = self.directory / "promoted"
        catalog_path = out / "catalog-rc.json"
        original = json.loads(catalog_path.read_text())

        def check(document: dict | None = None, source: Path = out / "source.signed.json",
                  name: str = "catalog-rc.json") -> subprocess.CompletedProcess:
            path = catalog_path if document is None else self.write(name, document)
            return self.run_tool("check-promotion", "--channel", "rc", "--source-channel", "edge",
                                 "--catalog", str(path), "--source", str(source), "--trust-root", str(self.trust_root))

        self.assertEqual(check().returncode, 0)
        source_sha256 = sha(release.decode_envelope((out / "source.signed.json").read_bytes())[0])
        pinned = self.run_tool("check-promotion", "--channel", "rc", "--source-channel", "edge",
                               "--catalog", str(catalog_path), "--source", str(out / "source.signed.json"),
                               "--trust-root", str(self.trust_root), "--source-sha256", source_sha256)
        self.assertEqual(pinned.returncode, 0, pinned.stderr)
        mispinned = self.run_tool("check-promotion", "--channel", "rc", "--source-channel", "edge",
                                  "--catalog", str(catalog_path), "--source", str(out / "source.signed.json"),
                                  "--trust-root", str(self.trust_root), "--source-sha256", "d" * 64)
        self.assert_refused(mispinned, "not the pinned")
        changed = json.loads(json.dumps(original))
        changed["models"][0]["engineDigest"] = f"sha256:{'a' * 64}"
        self.assert_refused(check(changed, name="catalog-rc.json"), "changes more than sequence and issuedAt: models")
        changed = json.loads(json.dumps(original))
        changed["models"][0]["payloadArtifact"]["parts"][0]["sourceURL"] = f"{release_base('other')}/{ZIP}.part00"
        self.assert_refused(check(changed, name="catalog-rc.json"), "models")
        changed = dict(original, installer=dict(original["installer"], minimumVersion="2.0.0"))
        self.assert_refused(check(changed, name="catalog-rc.json"), "installer")
        changed = dict(original, models=original["models"][1:])
        self.assert_refused(check(changed, name="catalog-rc.json"), "models")
        changed = dict(original, sequence=SEQUENCE)
        self.assert_refused(check(changed, name="catalog-rc.json"), "does not follow")
        self.assert_refused(check(original, name="catalog-stable.json"), "must be catalog-rc.json")
        tampered = json.loads((out / "source.signed.json").read_text())
        tampered["signature"] = base64.b64encode(b"\0" * 64).decode()
        self.assert_refused(check(source=self.write("source.signed.json", tampered)), "does not verify")

    def test_promotion_only_moves_forward(self) -> None:
        for channel, source in (("rc", "rc"), ("rc", "stable"), ("edge", "edge"), ("stable", "stable"),
                                ("beta", "edge"), ("rc", "nightly")):
            result = self.promote(channel, source)
            self.assertEqual(result.returncode, 1, (channel, source))
            self.assertIn("refused", result.stderr)

    def test_a_promotion_must_follow_the_published_target(self) -> None:
        self.published_edge()
        self.assertEqual(self.promote("rc", "edge", LATEST, "newer").returncode, 0)
        self.assertEqual(self.sign(self.directory / "newer" / "catalog-rc.json", out="newer-signed").returncode, 0)
        self.assertEqual(self.publish("rc", self.directory / "newer-signed" / "catalog-rc.signed.json").returncode, 0)
        self.assert_refused(self.promote("rc", "edge", LATER, "older"), "does not follow the published rc")


if __name__ == "__main__":
    unittest.main()
