#!/usr/bin/env python3
"""Upload a built Mac image to its release destination, never overwriting.

The upload job (`.github/workflows/mac-upload.yml`) runs this after the image
build (`mac-image.yml`) and, once it exists, the VM acceptance job. It takes
the image build's artifact directory, checks the image against the expected
sha256 and the acceptance evidence, stages the files to publish, and hands
them to a destination:

- the image zip, split into `<zip>.partNN` files when the destination limits
  file size (the GitHub release stopgap: 1992294400-byte parts, 2 to 16 of
  them, the convention `publish-m1-release` and the app's catalog parser
  share), or whole when it doesn't (R2, ticket 13);
- `<zip>.sha256`, the build's whole-image digest line;
- the image records: installer_data.json, IMAGE, PROVENANCE, INSPECTION,
  inputs;
- `acceptance-evidence.json` when evidence was given;
- `SHA256SUMS`, last, over every file above and the whole zip.

Every destination path is immutable. Before writing anything the job lists
the destination: a file already there with the same bytes is skipped, a file
with different bytes (or a file this upload doesn't have) refuses the whole
upload. After uploading, every file is downloaded back and its sha256 checked.

A real upload refuses without passing acceptance evidence for the image's
sha256 (`docs/mac-acceptance-evidence.md`). A dry run writes only to a
scratch release whose name starts with `dryrun-`, which it deletes
afterwards.

Destinations implement the small `Destination` interface below; the job's
logic never looks past it. `dir:PATH` is a local directory (tests, local
dry runs); `github-release:OWNER/REPO` is a draft prerelease on GitHub.

Usage:
  mac-upload.py check-inputs --image NAME --sha256 HEX [--dry-run]
                             [--run-id ID]... [--part-bytes N]
  mac-upload.py check-evidence --evidence FILE --sha256 HEX
  mac-upload.py check-run --run-json FILE --repository OWNER/REPO --role ROLE
                          [--current-run-id ID]
  mac-upload.py publish --artifact DIR --image NAME --sha256 HEX
                        --destination DEST --release NAME [--dry-run]
                        [--evidence FILE --evidence-run-url URL]
                        [--part-bytes N] [--target SHA]
                        [--run-url URL] [--report FILE]
  mac-upload.py discard --destination DEST --release NAME
  mac-upload.py make-public --destination github-release:OWNER/REPO --release NAME
  mac-upload.py catalog-inputs --report FILE --destination github-release:OWNER/REPO
                               --release NAME
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import BinaryIO, Protocol

GITHUB_PART_BYTES = 1992294400
MAXIMUM_PART_COUNT = 16
READ_BLOCK_BYTES = 8 * 1024 * 1024
LISTING_ATTEMPTS = 6
IMAGE_NAME = re.compile(r"^omarchy-mac-(edge|rc|stable)-\d{4}\.\d{2}\.\d{2}-[0-9a-f]{12}$")
SHA256_HEX = re.compile(r"^[0-9a-f]{64}$")
COMMIT = re.compile(r"^[0-9a-f]{40}$")
RUN_ID = re.compile(r"^[1-9][0-9]{0,19}$")
REPOSITORY = re.compile(r"^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$")
RELEASE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
PAYLOAD_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]{0,200}\.zip$")
RECORDS = ("installer_data.json", "IMAGE", "PROVENANCE", "INSPECTION", "inputs")
EVIDENCE_NAME = "acceptance-evidence.json"
SUMS_NAME = "SHA256SUMS"
REQUIRED_SCENARIOS = ("first-boot", "conversion", "second-boot")
DRY_RUN_PREFIX = "dryrun-"
PULL_REQUEST_EVENTS = ("pull_request", "pull_request_target")


class Refusal(Exception):
    """The upload must not go ahead; nothing further is written."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise Refusal(message)


def sha256_of(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        while block := stream.read(READ_BLOCK_BYTES):
            value.update(block)
    return value.hexdigest()


class HashSink:
    """A write-only stream that keeps a sha256 and a byte count."""

    def __init__(self) -> None:
        self.hash = hashlib.sha256()
        self.size = 0

    def write(self, block: bytes) -> int:
        self.hash.update(block)
        self.size += len(block)
        return len(block)


# Inputs, evidence and runs


def check_inputs(image: str, sha256: str, dry_run: bool, run_ids: list[str], part_bytes: str) -> None:
    require(IMAGE_NAME.fullmatch(image) is not None, f"{image!r} is not an image name (omarchy-mac-<lane>-<YYYY.MM.DD>-<set id>)")
    require(SHA256_HEX.fullmatch(sha256) is not None, "the expected image sha256 must be 64 lowercase hex digits")
    for run_id in run_ids:
        require(run_id == "" or RUN_ID.fullmatch(run_id) is not None, f"{run_id!r} is not a run id")
    if part_bytes:
        require(dry_run, "a part size override is for dry runs only")
        require(re.fullmatch(r"[1-9][0-9]{0,11}", part_bytes) is not None, "the part size must be a positive integer")
        require(int(part_bytes) <= GITHUB_PART_BYTES, f"the part size can't exceed {GITHUB_PART_BYTES}")


def check_evidence(document: object, expected_sha256: str, expected_run_url: str = "") -> None:
    """Refuse unless the record says the image with this sha256 passed.

    With run_url, the record must also name the run it was downloaded from.
    """
    require(isinstance(document, dict), "the evidence record is not a JSON object")
    sha = document.get("image_sha256")
    require(isinstance(sha, str) and SHA256_HEX.fullmatch(sha) is not None, "the evidence record's image_sha256 is malformed")
    require(sha == expected_sha256, f"the evidence is for image {sha}, not {expected_sha256}")
    require(document.get("result") == "pass", f"the evidence record's result is {document.get('result')!r}, not 'pass'")
    scenarios = document.get("scenarios")
    require(isinstance(scenarios, list) and scenarios, "the evidence record lists no scenarios")
    seen: dict[str, str] = {}
    for scenario in scenarios:
        require(isinstance(scenario, dict), "an evidence scenario is not an object")
        name, result = scenario.get("name"), scenario.get("result")
        require(isinstance(name, str) and name != "", "an evidence scenario has no name")
        require(name not in seen, f"evidence scenario {name} is listed twice")
        require(result == "pass", f"evidence scenario {name} is {result!r}, not 'pass'")
        seen[name] = result
    missing = [name for name in REQUIRED_SCENARIOS if name not in seen]
    require(not missing, f"the evidence record is missing scenarios: {', '.join(missing)}")
    commit = document.get("harness_commit")
    require(isinstance(commit, str) and COMMIT.fullmatch(commit) is not None, "the evidence record's harness_commit is not a commit")
    runner = document.get("runner")
    require(isinstance(runner, str) and runner.strip() != "", "the evidence record names no runner")
    # The catalog's limit: whatever the upload takes, the catalog must take too.
    require(len(runner) <= 200, "the evidence record's runner is longer than 200 characters")
    run_url = document.get("run_url")
    require(isinstance(run_url, str) and run_url.startswith("https://"), "the evidence record's run_url is not an https URL")
    require(not expected_run_url or run_url == expected_run_url,
            f"the evidence record names run {run_url}, not the run it came from ({expected_run_url})")


def load_evidence(path: Path, expected_sha256: str, expected_run_url: str = "") -> dict:
    require(path.is_file() and not path.is_symlink(), f"missing or unsafe evidence record: {path}")
    try:
        document = json.loads(path.read_text())
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise Refusal(f"the evidence record is not JSON: {error}") from error
    check_evidence(document, expected_sha256, expected_run_url)
    return document


def check_run(run: dict, repository: str, role: str, current_run_id: str = "") -> None:
    """Refuse a run that isn't this repository's own main branch.

    Another run must also have succeeded; this run is still in progress.
    """
    require(run.get("repository", {}).get("full_name") == repository, f"the {role} run is not from {repository}")
    require(run.get("head_repository", {}).get("full_name") == repository, f"the {role} run's code is not from {repository}")
    require(run.get("head_branch") == "main", f"the {role} run is from {run.get('head_branch')!r}, not main")
    require(run.get("event") not in PULL_REQUEST_EVENTS, f"the {role} run was triggered by {run.get('event')}")
    if str(run.get("id")) != current_run_id:
        require(run.get("conclusion") == "success", f"the {role} run's conclusion is {run.get('conclusion')!r}, not success")


# Destinations


@dataclass(frozen=True)
class Remote:
    size: int
    sha256: str | None  # None when the destination can't say without a download


class Destination(Protocol):
    """Where an image's files go. One release (directory, prefix) per image.

    `part_bytes` is the largest file the destination takes, or None for no
    limit. `listing` lists the release (empty if it doesn't exist yet) and
    writes nothing. `put` must never replace an existing file; it creates the
    release on first use. `fetch` streams a published file back. `discard`
    deletes a dry run's scratch release and must refuse any other.
    """

    part_bytes: int | None

    def location(self) -> str: ...

    def listing(self) -> dict[str, Remote]: ...

    def put(self, name: str, path: Path) -> None: ...

    def fetch(self, name: str, sink: BinaryIO) -> None: ...

    def discard(self) -> None: ...


def require_scratch(release: str) -> None:
    require(release.startswith(DRY_RUN_PREFIX), f"refusing to delete {release}: only a {DRY_RUN_PREFIX} scratch release is ever deleted")


class DirectoryDestination:
    """A local directory per release: tests and local dry runs."""

    def __init__(self, root: Path, release: str, part_bytes: int | None = GITHUB_PART_BYTES) -> None:
        self.root = root
        self.release = release
        self.part_bytes = part_bytes

    def location(self) -> str:
        return str(self.root / self.release)

    def listing(self) -> dict[str, Remote]:
        directory = self.root / self.release
        if not directory.is_dir():
            return {}
        return {
            path.name: Remote(path.stat().st_size, sha256_of(path))
            for path in sorted(directory.iterdir())
            if path.is_file() and not path.name.startswith(".")
        }

    def put(self, name: str, path: Path) -> None:
        directory = self.root / self.release
        directory.mkdir(parents=True, exist_ok=True)
        partial = directory / f".{name}.partial"
        shutil.copyfile(path, partial)
        # link() fails if the name exists, so a put never replaces a file.
        try:
            os.link(partial, directory / name)
        except FileExistsError as error:
            raise Refusal(f"{name} already exists at {self.location()}") from error
        finally:
            partial.unlink()

    def fetch(self, name: str, sink: BinaryIO) -> None:
        with (self.root / self.release / name).open("rb") as stream:
            while block := stream.read(READ_BLOCK_BYTES):
                sink.write(block)

    def discard(self) -> None:
        require_scratch(self.release)
        shutil.rmtree(self.root / self.release, ignore_errors=True)


class GitHubReleaseDestination:
    """A draft prerelease on GitHub, named and tagged after the release name.

    The release is created as a draft prerelease that is never marked latest;
    `make_public` publishes it (and so creates its tag) once its upload is
    verified, when the release pipeline asks. A draft has no tag yet, so it is
    found by listing releases, which only a token with write access can see.
    """

    part_bytes = GITHUB_PART_BYTES

    def __init__(self, repository: str, release: str, token: str, *, api: str = "https://api.github.com",
                 target: str = "", notes: str = "") -> None:
        require(REPOSITORY.fullmatch(repository) is not None, f"invalid repository: {repository}")
        require(token != "", "no GitHub token (GH_TOKEN)")
        self.repository = repository
        self.release = release
        self.token = token
        self.api = api.rstrip("/")
        self.target = target
        self.notes = notes
        self._release: dict | None = None
        self._assets: dict[str, dict] = {}

    def location(self) -> str:
        return f"github.com/{self.repository} release {self.release} (draft)"

    def _request(self, method: str, url: str, *, body: bytes | BinaryIO | None = None, size: int | None = None,
                 content_type: str = "application/json", accept: str = "application/vnd.github+json"):
        if not url.startswith("https://"):
            url = f"{self.api}{url}"
        request = urllib.request.Request(url, data=body, method=method)
        request.add_header("Accept", accept)
        request.add_header("X-GitHub-Api-Version", "2022-11-28")
        # Unredirected: a release asset download redirects to a signed storage
        # URL, which must not receive the token.
        request.add_unredirected_header("Authorization", f"Bearer {self.token}")
        if body is not None:
            request.add_header("Content-Type", content_type)
            if size is not None:
                request.add_header("Content-Length", str(size))
        return urllib.request.urlopen(request, timeout=600)

    def _json(self, method: str, url: str, document: dict | None = None):
        body = None if document is None else json.dumps(document).encode()
        with self._request(method, url, body=body) as response:
            payload = response.read()
        return json.loads(payload) if payload else None

    def _paged(self, url: str) -> list[dict]:
        items: list[dict] = []
        page = 1
        while True:
            batch = self._json("GET", f"{url}?per_page=100&page={page}")
            items.extend(batch)
            if len(batch) < 100:
                return items
            page += 1

    def _find(self) -> dict | None:
        if self._release is None:
            matches = [item for item in self._paged(f"/repos/{self.repository}/releases") if item.get("tag_name") == self.release]
            require(len(matches) <= 1, f"{len(matches)} releases are tagged {self.release}; resolve that by hand")
            self._release = matches[0] if matches else None
        return self._release

    def listing(self) -> dict[str, Remote]:
        release = self._find()
        if release is None:
            return {}
        remote: dict[str, Remote] = {}
        for asset in self._assets_of(release):
            digest = asset.get("digest") or ""
            remote[asset["name"]] = Remote(int(asset["size"]), digest[7:] if digest.startswith("sha256:") else None)
        return remote

    def _assets_of(self, release: dict) -> list[dict]:
        assets = self._paged(f"/repos/{self.repository}/releases/{release['id']}/assets")
        names = [asset.get("name") for asset in assets]
        require(len(set(names)) == len(names), f"{self.location()} lists an asset name twice; resolve that by hand")
        for asset in assets:
            require(asset.get("state") == "uploaded",
                    f"{asset.get('name')} on {self.location()} is an incomplete upload ({asset.get('state')}); delete it by hand")
            self._assets[asset["name"]] = asset
        return assets

    def _create(self) -> dict:
        document = {
            "tag_name": self.release,
            "name": self.release,
            "body": self.notes,
            "draft": True,
            "prerelease": True,
            "make_latest": "false",
        }
        if self.target:
            document["target_commitish"] = self.target
        created = self._json("POST", f"/repos/{self.repository}/releases", document)
        self._release = created
        # Drafts have no tag yet, so two jobs could each create one. The
        # listing can lag behind the create, so wait for ours to show.
        for attempt in range(LISTING_ATTEMPTS):
            tagged = [item for item in self._paged(f"/repos/{self.repository}/releases") if item.get("tag_name") == self.release]
            require(all(item["id"] == created["id"] for item in tagged), f"another release tagged {self.release} exists")
            if tagged:
                return created
            time.sleep(attempt + 1)
        raise Refusal(f"created {self.release} but it never showed in the release list, so it can't be checked as the only one; re-run to resume")

    def put(self, name: str, path: Path) -> None:
        release = self._find() or self._create()
        # Once published, a release is the catalog's: never add to it.
        require(release.get("draft") is True, f"{self.release} is already published; refusing to add {name} to it")
        upload = release["upload_url"].split("{", 1)[0]
        size = path.stat().st_size
        with path.open("rb") as stream:
            try:
                with self._request("POST", f"{upload}?name={urllib.parse.quote(name)}", body=stream, size=size,
                                   content_type="application/octet-stream") as response:
                    asset = json.loads(response.read())
            except urllib.error.HTTPError as error:
                if error.code == 422:
                    detail = error.read().decode(errors="replace")[:500]
                    raise Refusal(f"GitHub refused {name} on {self.location()} (422, maybe it already exists): {detail}") from error
                raise
        require(asset.get("name") == name, f"GitHub stored {name} as {asset.get('name')}")
        self._assets[name] = asset
        require(int(asset.get("size", -1)) == size, f"GitHub stored {name} with {asset.get('size')} bytes, not {size}")

    def fetch(self, name: str, sink: BinaryIO) -> None:
        if name not in self._assets:
            release = self._find()
            require(release is not None, f"{self.location()} doesn't exist")
            self._assets_of(release)
        require(name in self._assets, f"{name} is missing from {self.location()}")
        with self._request("GET", f"/repos/{self.repository}/releases/assets/{self._assets[name]['id']}",
                           accept="application/octet-stream") as response:
            while block := response.read(READ_BLOCK_BYTES):
                sink.write(block)

    def discard(self) -> None:
        require_scratch(self.release)
        release = self._find()
        if release is None:
            return
        require(release.get("draft") is True, f"refusing to delete {self.release}: it is not a draft")
        require(release.get("tag_name") == self.release, "refusing to delete a release with another tag")
        self._json("DELETE", f"/repos/{self.repository}/releases/{release['id']}")
        self._release = None


    def download_base(self) -> str:
        """Where a published release serves its files: the catalog's URLs."""
        return f"https://github.com/{self.repository}/releases/download/{self.release}/"

    def _tag_commit(self) -> str | None:
        try:
            ref = self._json("GET", f"/repos/{self.repository}/git/ref/tags/{urllib.parse.quote(self.release)}")
        except urllib.error.HTTPError as error:
            if error.code == 404:
                error.close()
                return None
            raise
        target = (ref or {}).get("object") or {}
        require(target.get("type") == "commit", f"the tag {self.release} is not a lightweight tag of a commit")
        return target.get("sha")

    def make_public(self) -> None:
        """Publish the draft as a prerelease, never latest, so the catalog can
        pin its download URLs. Its files are already verified; once published
        nothing is ever added (put refuses). Idempotent."""
        require(not self.release.startswith(DRY_RUN_PREFIX), f"a scratch release is never published: {self.release}")
        release = self._find()
        require(release is not None, f"{self.location()} doesn't exist; nothing to publish")
        require(release.get("tag_name") == self.release, "refusing to publish a release with another tag")
        commit = release.get("target_commitish")
        require(isinstance(commit, str) and COMMIT.fullmatch(commit) is not None,
                f"{self.release} targets {commit!r}, not a commit")
        tagged = self._tag_commit()
        require(tagged in (None, commit), f"the tag {self.release} already names {tagged}, not the uploaded commit {commit}")
        if release.get("draft"):
            self._release = release = self._json("PATCH", f"/repos/{self.repository}/releases/{release['id']}", {
                "draft": False, "prerelease": True, "make_latest": "false"})
        require(release.get("draft") is False and release.get("prerelease") is True,
                f"{self.release} is not a published prerelease after publishing")
        require(self._tag_commit() == commit, f"the tag {self.release} does not name the uploaded commit {commit}")


def open_destination(spec: str, release: str, *, target: str = "", notes: str = "") -> Destination:
    require(RELEASE_NAME.fullmatch(release) is not None, f"invalid release name: {release}")
    kind, _, value = spec.partition(":")
    if kind == "dir" and value:
        return DirectoryDestination(Path(value), release)
    if kind == "github-release" and value:
        return GitHubReleaseDestination(
            value, release, os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN", ""),
            api=os.environ.get("GITHUB_API_URL", "https://api.github.com"), target=target, notes=notes)
    raise Refusal(f"unknown destination {spec!r}; use dir:PATH or github-release:OWNER/REPO")


# Staging and publishing


def find_payload(artifact: Path) -> Path:
    require(artifact.is_dir() and not artifact.is_symlink(), f"missing or unsafe artifact directory: {artifact}")
    zips = sorted(path for path in artifact.iterdir() if path.suffix == ".zip")
    require(len(zips) == 1, f"the artifact holds {len(zips)} image zips, not one")
    require(zips[0].is_file() and not zips[0].is_symlink(), f"unsafe image zip: {zips[0].name}")
    require(PAYLOAD_NAME.fullmatch(zips[0].name) is not None, f"unexpected image zip name: {zips[0].name!r}")
    return zips[0]


def split(payload: Path, part_bytes: int, staging: Path) -> list[Path]:
    size = payload.stat().st_size
    count = -(-size // part_bytes)
    require(count >= 2, "a payload that fits in one part is not split")
    require(count <= MAXIMUM_PART_COUNT, f"the image needs {count} parts of {part_bytes} bytes; the app accepts at most {MAXIMUM_PART_COUNT}")
    parts = []
    with payload.open("rb") as source:
        for index in range(count):
            part = staging / f"{payload.name}.part{index:02d}"
            remaining = part_bytes
            with part.open("wb") as target:
                while remaining and (block := source.read(min(READ_BLOCK_BYTES, remaining))):
                    target.write(block)
                    remaining -= len(block)
            parts.append(part)
    return parts


def stage(artifact: Path, expected_sha256: str, evidence: Path | None, part_bytes: int | None, staging: Path) -> list[Path]:
    """Check the artifact and lay out the files to publish, SHA256SUMS last."""
    payload = find_payload(artifact)
    actual = sha256_of(payload)
    require(actual == expected_sha256, f"{payload.name} is {actual}, not the expected {expected_sha256}")
    digest_file = artifact / f"{payload.name}.sha256"
    require(digest_file.is_file() and not digest_file.is_symlink(), f"the artifact has no {digest_file.name}")
    fields = digest_file.read_text().split()
    require(fields[:1] == [expected_sha256] and fields[1:] in ([payload.name], [f"*{payload.name}"]),
            f"{digest_file.name} doesn't name {payload.name} with the expected sha256")
    for record in RECORDS:
        path = artifact / record
        require(path.is_file() and not path.is_symlink(), f"the artifact has no {record}")

    staging.mkdir(parents=True, exist_ok=True)
    files: list[Path] = []
    if part_bytes is not None and payload.stat().st_size > part_bytes:
        files += split(payload, part_bytes, staging)
    else:
        files.append(payload)
    files += [digest_file] + [artifact / record for record in RECORDS]
    if evidence is not None:
        copy = staging / EVIDENCE_NAME
        shutil.copyfile(evidence, copy)
        files.append(copy)
    names = [path.name for path in files]
    require(len(set(names)) == len(names), "two files to publish share a name")

    sums = staging / SUMS_NAME
    lines = [f"{expected_sha256}  {payload.name}"] if payload not in files else []
    lines += [f"{sha256_of(path)}  {path.name}" for path in files]
    sums.write_text("\n".join(lines) + "\n")
    files.append(sums)
    return files


def plan(files: list[Path], remote: dict[str, Remote], destination: Destination) -> list[Path]:
    """Return the files still to upload; refuse if the destination disagrees."""
    local = {path.name: path for path in files}
    extra = sorted(set(remote) - set(local))
    require(not extra, f"{destination.location()} already holds files this upload doesn't have: {', '.join(extra)}")
    missing = []
    for path in files:
        found = remote.get(path.name)
        if found is None:
            missing.append(path)
            continue
        size = path.stat().st_size
        require(found.size == size, f"{path.name} is already published with {found.size} bytes, not {size}; refusing to overwrite")
        published = found.sha256
        if published is None:
            sink = HashSink()
            destination.fetch(path.name, sink)
            published = sink.hash.hexdigest()
        require(published == sha256_of(path), f"{path.name} is already published with different bytes; refusing to overwrite")
    return missing


def verify(files: list[Path], destination: Destination) -> None:
    for path in files:
        sink = HashSink()
        destination.fetch(path.name, sink)
        expected = sha256_of(path)
        actual = sink.hash.hexdigest()
        require(sink.size == path.stat().st_size and actual == expected,
                f"{path.name} downloaded back as {actual} ({sink.size} bytes), not {expected}")
        print(f"  verified {path.name}")


def probe_refusals(files: list[Path], destination: Destination, staging: Path) -> None:
    """Dry run only: check the destination's listing drives both decisions."""
    names = {path.name for path in files}
    for attempt in range(LISTING_ATTEMPTS):
        remote = destination.listing()
        if names <= set(remote):
            break
        time.sleep(attempt + 1)  # a listing can lag behind the uploads
    require(plan(files, remote, destination) == [], "a second identical upload would write again")
    changed = staging / "probe" / SUMS_NAME
    changed.parent.mkdir()
    data = bytearray(files[-1].read_bytes())
    data[0] ^= 1  # same size, so only the digest can tell
    changed.write_bytes(bytes(data))
    try:
        plan(files[:-1] + [changed], remote, destination)
    except Refusal as refusal:
        print(f"  refused as expected: {refusal}")
    else:
        raise Refusal("a changed file was not refused")


def publish(*, artifact: Path, image: str, sha256: str, destination: Destination, release: str, dry_run: bool,
            evidence: Path | None = None, evidence_run_url: str = "", part_bytes: int | None = None,
            work: Path | None = None) -> dict:
    check_inputs(image, sha256, dry_run, [], str(part_bytes) if part_bytes else "")
    if dry_run:
        require(release.startswith(DRY_RUN_PREFIX), f"a dry run writes only to a {DRY_RUN_PREFIX} scratch release, not {release}")
    else:
        require(release == image, f"a real upload goes to the release named after the image ({image}), not {release}")
    record = None
    if evidence is not None:
        require(dry_run or evidence_run_url != "", "a real upload needs the URL of the run the evidence came from")
        record = load_evidence(evidence, sha256, evidence_run_url)
    else:
        require(dry_run, "refusing to upload: no acceptance evidence for this image")
        print("  dry run without acceptance evidence: a real upload would refuse")

    limit = part_bytes or destination.part_bytes
    with tempfile.TemporaryDirectory(prefix="mac-upload-", dir=work) as scratch:
        staging = Path(scratch)
        try:
            files = stage(artifact, sha256, evidence, limit, staging)
            missing = plan(files, destination.listing(), destination)
            for path in missing:
                print(f"  uploading {path.name} ({path.stat().st_size} bytes)")
                destination.put(path.name, path)
            for path in files:
                if path not in missing:
                    print(f"  already published {path.name}")
            verify(files, destination)
            if dry_run:
                probe_refusals(files, destination, staging)
        finally:
            if dry_run:
                destination.discard()
                print(f"  discarded scratch {destination.location()}")
        return {
            "image": image,
            "sha256": sha256,
            "dry_run": dry_run,
            "destination": destination.location(),
            "files": [{"name": path.name, "size": path.stat().st_size, "sha256": sha256_of(path)} for path in files],
            "uploaded": [path.name for path in missing],
            "evidence": None if record is None else {key: record.get(key) for key in ("result", "harness_commit", "runner", "run_url")},
        }


def release_notes(image: str, sha256: str, run_url: str) -> str:
    return (
        f"Upload of `{image}` by the Mac upload job{f' ({run_url})' if run_url else ''}. "
        "This draft is not a release: the catalog job decides when an image reaches users.\n\n"
        f"Image sha256 `{sha256}`. `SHA256SUMS` lists every file; `.partNN` files concatenate into the image zip.\n"
    )


def catalog_inputs(report: dict, base: str) -> dict:
    """The catalog's payload and installer-data inputs (docs/catalog-release.md)
    for a real upload's report, its files served under BASE."""
    require(report.get("dry_run") is False, "a dry run's files are discarded; only a real upload has catalog inputs")
    require(re.fullmatch(r"https://[A-Za-z0-9.-]+/[A-Za-z0-9._/-]+/", base) is not None and "/../" not in base,
            f"invalid download base: {base}")
    sha256 = report.get("sha256")
    require(isinstance(sha256, str) and SHA256_HEX.fullmatch(sha256) is not None, "the report has no image sha256")
    files = {entry["name"]: entry for entry in report.get("files", [])}
    digests = [name for name in files if name.endswith(".zip.sha256")]
    require(len(digests) == 1, f"the report names {len(digests)} image digest files, not one")
    zip_name = digests[0].removesuffix(".sha256")
    require(PAYLOAD_NAME.fullmatch(zip_name) is not None, f"unexpected image zip name: {zip_name!r}")

    def entry(name: str) -> dict:
        require(name in files, f"the upload has no {name}")
        found = files[name]
        require(isinstance(found.get("size"), int) and found["size"] > 0, f"{name} has no size")
        require(isinstance(found.get("sha256"), str) and SHA256_HEX.fullmatch(found["sha256"]) is not None,
                f"{name} has no sha256")
        return {"url": base + name, "fileName": name, "sizeBytes": found["size"], "sha256": found["sha256"]}

    parts = sorted(name for name in files if re.fullmatch(re.escape(zip_name) + r"\.part[0-9]{2}", name))
    if parts:
        require(zip_name not in files, "the upload holds both the whole image and its parts")
        require(parts == [f"{zip_name}.part{index:02d}" for index in range(len(parts))], "the image parts are not numbered from 00")
        require(2 <= len(parts) <= MAXIMUM_PART_COUNT, f"{len(parts)} image parts; the catalog takes 2 to {MAXIMUM_PART_COUNT}")
        pieces = [entry(name) for name in parts]
        payload = {"url": base + zip_name, "fileName": zip_name, "sizeBytes": sum(piece["sizeBytes"] for piece in pieces),
                   "sha256": sha256, "parts": pieces}
    else:
        payload = entry(zip_name)
        require(payload["sha256"] == sha256, f"{zip_name} is {payload['sha256']}, not the image sha256 {sha256}")
    return {"payload": payload, "installer_data": entry("installer_data.json")}


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    commands = parser.add_subparsers(dest="command", required=True)

    inputs = commands.add_parser("check-inputs")
    inputs.add_argument("--image", required=True)
    inputs.add_argument("--sha256", required=True)
    inputs.add_argument("--dry-run", action="store_true")
    inputs.add_argument("--run-id", action="append", default=[])
    inputs.add_argument("--part-bytes", default="")

    evidence = commands.add_parser("check-evidence")
    evidence.add_argument("--evidence", type=Path, required=True)
    evidence.add_argument("--sha256", required=True)

    run = commands.add_parser("check-run")
    run.add_argument("--run-json", type=Path, required=True)
    run.add_argument("--repository", required=True)
    run.add_argument("--role", required=True)
    run.add_argument("--current-run-id", default="")

    upload = commands.add_parser("publish")
    upload.add_argument("--artifact", type=Path, required=True)
    upload.add_argument("--image", required=True)
    upload.add_argument("--sha256", required=True)
    upload.add_argument("--destination", required=True)
    upload.add_argument("--release", required=True)
    upload.add_argument("--dry-run", action="store_true")
    upload.add_argument("--evidence", type=Path)
    upload.add_argument("--evidence-run-url", default="")
    upload.add_argument("--part-bytes", default="")
    upload.add_argument("--target", default="")
    upload.add_argument("--run-url", default="")
    upload.add_argument("--report", type=Path)

    public = commands.add_parser("make-public")
    public.add_argument("--destination", required=True)
    public.add_argument("--release", required=True)

    describe = commands.add_parser("catalog-inputs")
    describe.add_argument("--report", type=Path, required=True)
    describe.add_argument("--destination", required=True)
    describe.add_argument("--release", required=True)

    discard = commands.add_parser("discard")
    discard.add_argument("--destination", required=True)
    discard.add_argument("--release", required=True)

    args = parser.parse_args(argv)
    try:
        if args.command == "check-inputs":
            check_inputs(args.image, args.sha256, args.dry_run, args.run_id, args.part_bytes)
        elif args.command == "check-evidence":
            load_evidence(args.evidence, args.sha256)
            print(f"evidence passes for {args.sha256}")
        elif args.command == "check-run":
            check_run(json.loads(args.run_json.read_text()), args.repository, args.role, args.current_run_id)
        elif args.command == "publish":
            check_inputs(args.image, args.sha256, args.dry_run, [], args.part_bytes)
            destination = open_destination(args.destination, args.release, target=args.target,
                                           notes=release_notes(args.image, args.sha256, args.run_url))
            report = publish(artifact=args.artifact, image=args.image, sha256=args.sha256, destination=destination,
                             release=args.release, dry_run=args.dry_run, evidence=args.evidence,
                             evidence_run_url=args.evidence_run_url,
                             part_bytes=int(args.part_bytes) if args.part_bytes else None)
            if args.report:
                args.report.write_text(json.dumps(report, indent=2) + "\n")
            print(f"{'dry run ' if args.dry_run else ''}upload of {args.image} complete: "
                  f"{len(report['uploaded'])} uploaded, {len(report['files'])} verified")
        elif args.command in ("make-public", "catalog-inputs"):
            destination = open_destination(args.destination, args.release)
            require(isinstance(destination, GitHubReleaseDestination),
                    f"{args.command} is for the github-release destination (R2 serves uploads as they land)")
            if args.command == "make-public":
                destination.make_public()
                print(f"{args.release} is a published prerelease (never latest)")
            else:
                inputs = catalog_inputs(json.loads(args.report.read_text()), destination.download_base())
                print(f"payload={json.dumps(inputs['payload'], separators=(',', ':'))}")
                print(f"installer-data={json.dumps(inputs['installer_data'], separators=(',', ':'))}")
        elif args.command == "discard":
            open_destination(args.destination, args.release).discard()
    except Refusal as refusal:
        print(f"mac-upload: {refusal}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
