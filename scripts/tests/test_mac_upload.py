#!/usr/bin/env python3
"""Tests for the Mac image upload job, through a local fake destination."""
from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import io
import json
import subprocess
import sys
import tempfile
import unittest
import urllib.error
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


upload = load("mac_upload", SCRIPTS / "mac-upload.py")
fixture = load("mac_upload_fixture", SCRIPTS / "tests/make-mac-upload-fixture.py")
PART = 1024 * 1024
RUN_URL = "https://example.invalid/run"


class RecordingDestination(upload.DirectoryDestination):
    """The local destination, counting writes and optionally corrupting reads."""

    def __init__(self, root: Path, release: str, part_bytes: int | None = PART) -> None:
        super().__init__(root, release, part_bytes)
        self.puts: list[str] = []
        self.corrupt: str | None = None
        self.discarded = False

    def put(self, name, path):
        self.puts.append(name)
        super().put(name, path)

    def fetch(self, name, sink):
        if name == self.corrupt:
            sink.write(b"not the bytes that were uploaded")
            return
        super().fetch(name, sink)

    def discard(self):
        self.discarded = True
        super().discard()


class UploadTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = Path(tempfile.mkdtemp(prefix="omarchy-mac-upload-test-"))
        self.addCleanup(lambda: subprocess.run(["rm", "-rf", str(self.directory)], check=True))
        self.artifact = self.directory / "artifact"
        self.image, self.sha256 = fixture.make(self.artifact, 3 * PART + 77, "test")
        self.evidence = self.write_evidence(fixture.evidence(self.sha256, "https://example.invalid/run"))
        self.published = self.directory / "published"

    def write_evidence(self, document: dict, name: str = "evidence.json") -> Path:
        path = self.directory / name
        path.write_text(json.dumps(document))
        return path

    def destination(self, release: str | None = None, part_bytes: int | None = PART) -> RecordingDestination:
        return RecordingDestination(self.published, release or self.image, part_bytes)

    def run_publish(self, destination, *, dry_run=False, evidence="default", part_bytes=None):
        with contextlib.redirect_stdout(io.StringIO()):
            return upload.publish(
                artifact=self.artifact, image=self.image, sha256=self.sha256, destination=destination,
                release=destination.release, dry_run=dry_run,
                evidence=self.evidence if evidence == "default" else evidence,
                evidence_run_url=RUN_URL, part_bytes=part_bytes)

    def assertRefused(self, pattern: str, function, *args, **kwargs):
        with self.assertRaisesRegex(upload.Refusal, pattern):
            function(*args, **kwargs)

    def test_uploads_parts_records_and_sums_then_verifies(self):
        destination = self.destination()
        report = self.run_publish(destination)
        zip_name = next(self.artifact.glob("*.zip")).name
        parts = [f"{zip_name}.part{index:02d}" for index in range(4)]
        expected = parts + [f"{zip_name}.sha256", *upload.RECORDS, upload.EVIDENCE_NAME, upload.SUMS_NAME]
        self.assertEqual(destination.puts, expected)
        self.assertEqual(report["uploaded"], expected)
        release = self.published / self.image
        whole = b"".join((release / part).read_bytes() for part in parts)
        self.assertEqual(hashlib.sha256(whole).hexdigest(), self.sha256)
        self.assertTrue(all((release / part).stat().st_size <= PART for part in parts))
        sums = dict(reversed(line.split("  ")) for line in (release / upload.SUMS_NAME).read_text().splitlines())
        self.assertEqual(sums[zip_name], self.sha256)
        for name in expected[:-1]:
            self.assertEqual(sums[name], hashlib.sha256((release / name).read_bytes()).hexdigest())
        self.assertFalse(destination.discarded)

    def test_a_payload_within_the_limit_is_uploaded_whole(self):
        destination = self.destination(part_bytes=None)
        self.run_publish(destination)
        zip_name = next(self.artifact.glob("*.zip")).name
        self.assertIn(zip_name, destination.puts)
        self.assertFalse(any(".part" in name for name in destination.puts))

    def test_an_identical_reupload_writes_nothing(self):
        self.run_publish(self.destination())
        again = self.destination()
        report = self.run_publish(again)
        self.assertEqual(again.puts, [])
        self.assertEqual(report["uploaded"], [])

    def test_an_interrupted_upload_resumes_with_the_missing_files(self):
        first = self.destination()
        self.run_publish(first)
        (self.published / self.image / upload.SUMS_NAME).unlink()
        again = self.destination()
        self.run_publish(again)
        self.assertEqual(again.puts, [upload.SUMS_NAME])

    def test_different_bytes_at_a_published_path_are_refused(self):
        self.run_publish(self.destination())
        published = self.published / self.image / "IMAGE"
        before = published.read_bytes()
        (self.artifact / "IMAGE").write_text("a rebuilt image record\n")
        again = self.destination()
        self.assertRefused("IMAGE is already published .*refusing to overwrite", self.run_publish, again)
        self.assertEqual(again.puts, [])
        self.assertEqual(published.read_bytes(), before)

    def test_a_same_size_change_is_refused_by_digest(self):
        self.run_publish(self.destination())
        record = self.artifact / "INSPECTION"
        record.write_bytes(record.read_bytes().upper())
        self.assertRefused("INSPECTION is already published with different bytes", self.run_publish, self.destination())

    def test_a_release_holding_other_files_is_refused(self):
        stray = self.published / self.image / "notes.txt"
        stray.parent.mkdir(parents=True)
        stray.write_text("left by hand\n")
        destination = self.destination()
        self.assertRefused("already holds files this upload doesn't have: notes.txt", self.run_publish, destination)
        self.assertEqual(destination.puts, [])

    def test_a_put_never_replaces_a_file(self):
        destination = self.destination()
        source = self.directory / "IMAGE"
        source.write_text("one\n")
        destination.put("IMAGE", source)
        source.write_text("two\n")
        self.assertRefused("already exists", destination.put, "IMAGE", source)
        self.assertEqual((self.published / self.image / "IMAGE").read_text(), "one\n")

    def test_a_failed_verification_fails_the_upload(self):
        destination = self.destination()
        destination.corrupt = "PROVENANCE"
        self.assertRefused("PROVENANCE downloaded back as", self.run_publish, destination)

    def test_a_real_upload_without_evidence_is_refused(self):
        destination = self.destination()
        self.assertRefused("no acceptance evidence", self.run_publish, destination, evidence=None)
        self.assertEqual(destination.puts, [])
        self.assertFalse((self.published / self.image).exists())

    def test_failing_or_mismatched_evidence_is_refused(self):
        cases = {
            "result is 'fail'": {"result": "fail"},
            "evidence is for image": {"image_sha256": "f" * 64},
            "image_sha256 is malformed": {"image_sha256": "F" * 64},
            "second-boot is 'fail'": {"scenarios": [
                {"name": "first-boot", "result": "pass"},
                {"name": "conversion", "result": "pass"},
                {"name": "second-boot", "result": "fail"}]},
            "missing scenarios: conversion": {"scenarios": [
                {"name": "first-boot", "result": "pass"}, {"name": "second-boot", "result": "pass"}]},
            "lists no scenarios": {"scenarios": []},
            "harness_commit is not a commit": {"harness_commit": "main"},
            "names no runner": {"runner": " "},
            "run_url is not an https URL": {"run_url": "http://example.invalid"},
        }
        for message, change in cases.items():
            with self.subTest(message):
                document = {**fixture.evidence(self.sha256, "https://example.invalid/run"), **change}
                evidence = self.write_evidence(document, "bad.json")
                destination = self.destination()
                self.assertRefused(message, self.run_publish, destination, evidence=evidence)
                self.assertEqual(destination.puts, [])

    def test_the_catalog_takes_the_same_evidence_records(self):
        # One record goes to both gates; a name only one of them knows would
        # let no image through (the harness's fresh-install scenarios).
        catalog = load("catalog_release", SCRIPTS / "catalog_release.py")
        self.assertEqual(upload.REQUIRED_SCENARIOS, catalog.REQUIRED_SCENARIOS)
        document = fixture.evidence(self.sha256, RUN_URL)
        upload.check_evidence(document, self.sha256, RUN_URL)
        self.assertEqual(catalog.check_evidence(document, self.sha256), document)
        for change in ({"result": "fail"}, {"scenarios": document["scenarios"][:2]}, {"runner": "x" * 201},
                       {"harness_commit": "main"}, {"image_sha256": "f" * 64},
                       {"scenarios": document["scenarios"] + [{"name": "update", "result": "fail"}]}):
            with self.subTest(change):
                failing = {**document, **change}
                self.assertRaises(upload.Refusal, upload.check_evidence, failing, self.sha256)
                self.assertRaises(catalog.Refusal, catalog.check_evidence, failing, self.sha256)

    def test_evidence_must_name_the_run_it_came_from(self):
        destination = self.destination()
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertRefused("names run https://example.invalid/run, not the run it came from", upload.publish,
                               artifact=self.artifact, image=self.image, sha256=self.sha256, destination=destination,
                               release=self.image, dry_run=False, evidence=self.evidence,
                               evidence_run_url="https://example.invalid/other")
            self.assertRefused("needs the URL of the run", upload.publish,
                               artifact=self.artifact, image=self.image, sha256=self.sha256, destination=destination,
                               release=self.image, dry_run=False, evidence=self.evidence)
        self.assertEqual(destination.puts, [])

    def test_evidence_that_is_not_json_is_refused(self):
        evidence = self.directory / "broken.json"
        evidence.write_text("{")
        self.assertRefused("not JSON", self.run_publish, self.destination(), evidence=evidence)

    def test_an_image_that_does_not_match_the_expected_sha256_is_refused(self):
        self.sha256 = "0" * 64
        self.evidence = self.write_evidence(fixture.evidence(self.sha256, "https://example.invalid/run"))
        self.assertRefused("not the expected", self.run_publish, self.destination())

    def test_an_artifact_missing_a_record_is_refused(self):
        (self.artifact / "PROVENANCE").unlink()
        self.assertRefused("no PROVENANCE", self.run_publish, self.destination())

    def test_a_real_upload_goes_only_to_the_image_release(self):
        self.assertRefused("named after the image", self.run_publish, self.destination(f"dryrun-{self.image}"))
        self.assertRefused("dry runs only", self.run_publish, self.destination(), part_bytes=PART)

    def test_a_dry_run_writes_only_to_a_scratch_release_and_discards_it(self):
        self.assertRefused("scratch release", self.run_publish, self.destination(), dry_run=True)
        scratch = self.destination(f"dryrun-{self.image}-1-1")
        report = self.run_publish(scratch, dry_run=True, evidence=None, part_bytes=PART)
        self.assertTrue(report["dry_run"])
        self.assertIn(upload.SUMS_NAME, scratch.puts)
        self.assertTrue(scratch.discarded)
        self.assertEqual(list(self.published.iterdir()), [])

    def test_a_dry_run_still_checks_evidence_it_is_given(self):
        evidence = self.write_evidence({**fixture.evidence(self.sha256, "https://example.invalid/run"), "result": "fail"}, "f.json")
        scratch = self.destination(f"dryrun-{self.image}-1-1")
        self.assertRefused("result is 'fail'", self.run_publish, scratch, dry_run=True, evidence=evidence)
        self.assertEqual(scratch.puts, [])

    def test_a_dry_run_discards_its_scratch_release_after_a_failure(self):
        scratch = self.destination(f"dryrun-{self.image}-1-1")
        scratch.corrupt = "IMAGE"
        self.assertRefused("IMAGE downloaded back", self.run_publish, scratch, dry_run=True)
        self.assertTrue(scratch.discarded)
        self.assertFalse((self.published / scratch.release).exists())

    def test_only_scratch_releases_are_ever_discarded(self):
        self.run_publish(self.destination())
        self.assertRefused("only a dryrun- scratch release", self.destination().discard)
        self.assertTrue((self.published / self.image / upload.SUMS_NAME).is_file())

    def test_too_many_parts_are_refused(self):
        self.assertRefused("at most 16", self.run_publish, self.destination(f"dryrun-{self.image}"),
                           dry_run=True, part_bytes=PART // 8)

    def test_inputs_are_checked(self):
        good = dict(image=self.image, sha256=self.sha256, dry_run=False, run_ids=["123"], part_bytes="")
        upload.check_inputs(**good)
        for message, change in {
            "not an image name": {"image": "omarchy-mac-edge-latest"},
            "64 lowercase hex": {"sha256": "abc"},
            "not a run id": {"run_ids": ["12; rm -rf /"]},
            "dry runs only": {"part_bytes": "1024"},
            "positive integer": {"dry_run": True, "part_bytes": "-1"},
        }.items():
            with self.subTest(message):
                self.assertRefused(message, upload.check_inputs, **{**good, **change})

    def test_only_this_repositorys_main_branch_runs_are_trusted(self):
        repository = "omacom/omarchy-mac-installer"
        run = {"id": 7, "repository": {"full_name": repository}, "head_repository": {"full_name": repository},
               "head_branch": "main", "event": "workflow_dispatch", "conclusion": "success"}
        upload.check_run(run, repository, "image")
        upload.check_run({**run, "conclusion": None}, repository, "image", current_run_id="7")
        for message, change in {
            "conclusion is 'failure'": {"conclusion": "failure"},
            "conclusion is None": {"conclusion": None},
            "not main": {"head_branch": "mac-upload"},
            "triggered by pull_request": {"event": "pull_request"},
            "code is not from": {"head_repository": {"full_name": "someone/fork"}},
        }.items():
            with self.subTest(message):
                self.assertRefused(message, upload.check_run, {**run, **change}, repository, "image")

    def test_the_command_line_refuses_without_evidence(self):
        result = subprocess.run(
            [sys.executable, str(SCRIPTS / "mac-upload.py"), "publish", "--artifact", str(self.artifact),
             "--image", self.image, "--sha256", self.sha256, "--destination", f"dir:{self.published}",
             "--release", self.image],
            capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("no acceptance evidence", result.stderr)
        self.assertFalse(self.published.exists())

    def test_the_command_line_dry_run_leaves_nothing_behind(self):
        report = self.directory / "report.json"
        result = subprocess.run(
            [sys.executable, str(SCRIPTS / "mac-upload.py"), "publish", "--artifact", str(self.artifact),
             "--image", self.image, "--sha256", self.sha256, "--destination", f"dir:{self.published}",
             "--release", f"dryrun-{self.image}-9-1", "--dry-run", "--part-bytes", str(PART),
             "--evidence", str(self.evidence), "--report", str(report)],
            capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("refused as expected", result.stdout)
        self.assertEqual(list(self.published.iterdir()), [])
        self.assertEqual(json.loads(report.read_text())["evidence"]["result"], "pass")


class CatalogInputTests(unittest.TestCase):
    """What the upload hands the catalog: its pinned URLs, sizes and digests."""

    setUp = UploadTests.setUp
    write_evidence = UploadTests.write_evidence
    destination = UploadTests.destination
    run_publish = UploadTests.run_publish
    assertRefused = UploadTests.assertRefused

    BASE = "https://github.com/omacom/omarchy-mac-installer/releases/download/{}/"

    def report(self, part_bytes=PART):
        destination = self.destination(part_bytes=part_bytes)
        return self.run_publish(destination), self.BASE.format(self.image)

    def test_a_split_image_becomes_a_payload_with_parts_the_catalog_accepts(self):
        report, base = self.report()
        inputs = upload.catalog_inputs(report, base)
        payload = inputs["payload"]
        self.assertEqual(payload["sha256"], self.sha256)
        self.assertEqual(payload["fileName"], next(self.artifact.glob("*.zip")).name)
        self.assertEqual(payload["sizeBytes"], 3 * PART + 77)
        self.assertEqual([part["fileName"] for part in payload["parts"]],
                         [f"{payload['fileName']}.part{index:02d}" for index in range(4)])
        joined = b"".join((self.published / self.image / part["fileName"]).read_bytes() for part in payload["parts"])
        self.assertEqual(hashlib.sha256(joined).hexdigest(), self.sha256)
        for part in payload["parts"]:
            self.assertEqual(part["url"], base + part["fileName"])
        self.assertEqual(inputs["installer_data"]["url"], base + "installer_data.json")
        catalog = load("catalog_release", SCRIPTS / "catalog_release.py")
        engine = json.loads((SCRIPTS.parent / ".github" / "mac-release-pipeline.json").read_text())["engine"]
        installer = {"minimumVersion": "2.1.0", "latestVersion": "2.1.0", "downloadURL": self.BASE.format("v2.1.0") + "app.dmg"}
        document = catalog.build_catalog("edge", self.image, payload, engine, inputs["installer_data"],
                                         fixture.evidence(self.sha256, RUN_URL), installer,
                                         catalog.datetime.datetime(2026, 10, 14, tzinfo=catalog.datetime.timezone.utc))
        self.assertIn(self.sha256, json.dumps(document))

    def test_a_whole_image_becomes_a_payload_without_parts(self):
        report, base = self.report(part_bytes=None)
        payload = upload.catalog_inputs(report, base)["payload"]
        self.assertNotIn("parts", payload)
        self.assertEqual((payload["sha256"], payload["url"]), (self.sha256, base + payload["fileName"]))

    def test_a_dry_run_or_a_bad_base_has_no_catalog_inputs(self):
        report, base = self.report()
        self.assertRefused("only a real upload", upload.catalog_inputs, {**report, "dry_run": True}, base)
        self.assertRefused("invalid download base", upload.catalog_inputs, report, "http://example.invalid/x/")
        files = [entry for entry in report["files"] if not entry["name"].endswith(".part01")]
        self.assertRefused("not numbered from 00", upload.catalog_inputs, {**report, "files": files}, base)


class FakeGitHub(upload.GitHubReleaseDestination):
    """The GitHub destination over canned API answers, no network."""

    def __init__(self, releases: list[dict], assets: list[dict] | None = None) -> None:
        super().__init__("omacom/omarchy-mac-installer", "omarchy-mac-edge-2026.10.14-0123456789ab", "token")
        self.releases = releases
        self.assets = assets or []
        self.calls: list[tuple[str, str]] = []

    def _paged(self, url):
        return self.assets if url.endswith("/assets") else self.releases

    def _json(self, method, url, document=None):
        self.calls.append((method, url))
        if method == "POST":
            return {"id": 99, "tag_name": self.release, "draft": True, "upload_url": "https://uploads.invalid/x{?name}"}
        return None


class GitHubDestinationTests(unittest.TestCase):
    TAG = "omarchy-mac-edge-2026.10.14-0123456789ab"

    def release(self, **change):
        return {"id": 1, "tag_name": self.TAG, "draft": True, "upload_url": "https://uploads.invalid/x{?name}", **change}

    def test_a_published_release_is_never_added_to(self):
        github = FakeGitHub([self.release(draft=False)])
        with self.assertRaisesRegex(upload.Refusal, "already published; refusing to add IMAGE"):
            github.put("IMAGE", Path(__file__))

    def test_a_published_release_is_never_deleted(self):
        github = FakeGitHub([self.release(draft=False, tag_name=f"dryrun-{self.TAG}")])
        github.release = f"dryrun-{self.TAG}"
        with self.assertRaisesRegex(upload.Refusal, "not a draft"):
            github.discard()
        self.assertEqual(github.calls, [])

    def test_two_releases_with_the_tag_are_refused(self):
        github = FakeGitHub([self.release(), self.release(id=2)])
        with self.assertRaisesRegex(upload.Refusal, "2 releases are tagged"):
            github.listing()

    def test_a_duplicated_or_incomplete_asset_is_refused(self):
        asset = {"name": "IMAGE", "size": 3, "state": "uploaded", "digest": "sha256:" + "a" * 64, "id": 5}
        with self.assertRaisesRegex(upload.Refusal, "lists an asset name twice"):
            FakeGitHub([self.release()], [asset, {**asset, "id": 6}]).listing()
        with self.assertRaisesRegex(upload.Refusal, "incomplete upload"):
            FakeGitHub([self.release()], [{**asset, "state": "starter"}]).listing()
        listing = FakeGitHub([self.release()], [asset]).listing()
        self.assertEqual(listing, {"IMAGE": upload.Remote(3, "a" * 64)})

    def test_a_created_release_that_never_lists_fails_closed(self):
        github = FakeGitHub([])
        sleep, upload.time.sleep = upload.time.sleep, lambda seconds: None
        self.addCleanup(setattr, upload.time, "sleep", sleep)
        with self.assertRaisesRegex(upload.Refusal, "never showed in the release list"):
            github.put("IMAGE", Path(__file__))

    def test_another_draft_with_the_tag_is_refused_after_create(self):
        github = FakeGitHub([])
        original = github._json

        def create_then_race(method, url, document=None):
            created = original(method, url, document)
            if method == "POST":
                github.releases = [created, self.release(id=3)]
            return created
        github._json = create_then_race
        with self.assertRaisesRegex(upload.Refusal, "another release tagged"):
            github.put("IMAGE", Path(__file__))



class PublishingGitHub(FakeGitHub):
    """Answers the tag and publish calls make_public makes."""

    def __init__(self, release: dict, tag: str | None) -> None:
        super().__init__([release])
        self.tag = tag

    def _json(self, method, url, document=None):
        self.calls.append((method, url))
        if "/git/ref/tags/" in url:
            if self.tag is None:
                raise urllib.error.HTTPError(url, 404, "Not Found", None, None)
            return {"object": {"type": "commit", "sha": self.tag}}
        if method == "PATCH":
            self.patched = document
            self.tag = self.tag or self.releases[0]["target_commitish"]
            self.releases[0] = {**self.releases[0], **document}
            return self.releases[0]
        raise AssertionError(f"unexpected call {method} {url}")


class MakePublicTests(unittest.TestCase):
    TAG = GitHubDestinationTests.TAG
    COMMIT = "c" * 40

    def release(self, **change):
        return {"id": 1, "tag_name": self.TAG, "draft": True, "prerelease": True, "target_commitish": self.COMMIT, **change}

    def test_a_draft_becomes_a_prerelease_never_latest_tagged_at_its_commit(self):
        github = PublishingGitHub(self.release(), None)
        github.make_public()
        self.assertEqual(github.patched, {"draft": False, "prerelease": True, "make_latest": "false"})
        self.assertEqual(github.tag, self.COMMIT)
        self.assertEqual(github.download_base(),
                         f"https://github.com/omacom/omarchy-mac-installer/releases/download/{self.TAG}/")

    def test_publishing_again_changes_nothing(self):
        github = PublishingGitHub(self.release(draft=False), self.COMMIT)
        github.make_public()
        self.assertNotIn("PATCH", [method for method, _ in github.calls])

    def test_a_tag_naming_another_commit_is_refused_before_publishing(self):
        github = PublishingGitHub(self.release(), "d" * 40)
        with self.assertRaisesRegex(upload.Refusal, "already names"):
            github.make_public()
        self.assertNotIn("PATCH", [method for method, _ in github.calls])

    def test_scratch_missing_or_branch_targeted_releases_are_refused(self):
        scratch = PublishingGitHub(self.release(tag_name=f"dryrun-{self.TAG}"), None)
        scratch.release = f"dryrun-{self.TAG}"
        with self.assertRaisesRegex(upload.Refusal, "never published"):
            scratch.make_public()
        missing = PublishingGitHub(self.release(), None)
        missing.releases = []
        with self.assertRaisesRegex(upload.Refusal, "doesn't exist"):
            missing.make_public()
        with self.assertRaisesRegex(upload.Refusal, "not a commit"):
            PublishingGitHub(self.release(target_commitish="main"), None).make_public()

    def test_the_command_line_takes_only_the_github_destination(self):
        result = subprocess.run(
            [sys.executable, "-I", str(SCRIPTS / "mac-upload.py"), "make-public", "--destination", "dir:/nonexistent",
             "--release", self.TAG], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("is for the github-release destination", result.stderr)


if __name__ == "__main__":
    unittest.main()
