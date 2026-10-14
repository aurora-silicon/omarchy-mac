#!/usr/bin/env python3
"""The builder's payload is the one the installer engine takes, read from this repository: the
installer_data.json build-mac-image writes and mac-image-check expects is the engine's bundled
Engine/installer_data.json for that payload, and the engine's full-OS package admission
(omarchy_asahi.AsahiStage1Adapter.preflight) takes the payload mac-image-check passes and refuses
nothing mac-image-check lets through. A change on either side that lets the two disagree on a payload
the builder would publish fails here; the engine admitting more than the builder publishes does not."""
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
import unittest.mock
import warnings
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fixtures  # noqa: E402

ROOT = fixtures.ROOT
ENGINE = ROOT.parent / "Engine"
NAME = "omarchy-2026.10.14-aarch64-apple-silicon-mac-edge-os-package.zip"
LAB_NAME = "omarchy-2026.10.14-aarch64-apple-silicon-mac-edge-lab-os-package.zip"

_loader = importlib.machinery.SourceFileLoader("mac_image_check", str(ROOT / "bin/mac-image-check"))
check = importlib.util.module_from_spec(importlib.util.spec_from_loader("mac_image_check", _loader))
_loader.exec_module(check)


# The engine runs over pinned asahi-installer modules (Engine/source-lock.json, v0.9.2) that this
# repository does not carry. Stand-ins give it what preflight reads from them; psize and min_size are
# upstream's, so the partition sizes the metadata declares are read the way the Mac reads them.
def psize(value, align=None):
    """asahi-installer v0.9.2 src/util.py psize, without alignment."""
    value = value.upper().replace(" ", "")
    base = 1000
    if value[-2] == "I":
        base = 1024
        value = value[:-2] + value[-1]
    for suffix, power in {"TB": 4, "GB": 3, "MB": 2, "KB": 1, "B": 0, "": 0}.items():
        if value.endswith(suffix):
            return int(float(value[:-len(suffix)]) * (base ** power))
    return None


class OSInstaller:
    """What preflight reads of asahi-installer v0.9.2 src/osinstall.py OSInstaller."""

    def __init__(self, dutil, data, template):
        self.template = template

    @property
    def min_size(self):
        return sum(-(-psize(part["size"]) // (1 << 20)) << 20 for part in self.template["partitions"])

    @property
    def min_recommended_size(self):
        expandable = any(part.get("expand", False) for part in self.template["partitions"])
        return self.min_size * 2 if expandable else self.min_size


class StubInstaller:
    def __init__(self, sysinfo, dutil, osinfo):
        self.ipsw = None

    def install_files(self, current_os):
        pass

    def load_ipsw(self, ipsw):
        self.ipsw = ipsw


sys.modules["asahi_firmware"] = SimpleNamespace(core=SimpleNamespace(FWPackage=object))
sys.modules["osinstall"] = SimpleNamespace(OSInstaller=OSInstaller, psize=psize)
sys.modules["stub"] = SimpleNamespace(StubInstaller=StubInstaller)
sys.modules["util"] = SimpleNamespace(align_down=lambda value, align=16384: value & ~(align - 1))
sys.path.insert(0, str(ENGINE / "overlay/src"))
import omarchy_asahi  # noqa: E402


def engine_metadata(package: str) -> dict:
    """The engine's bundled installer_data.json, as the engine loads it, naming PACKAGE."""
    metadata = omarchy_asahi.load_metadata(str(ENGINE / "installer_data.json"))
    templates = [t for t in metadata["os_list"] if t.get("omarchy_target") == omarchy_asahi.TARGET]
    assert len(templates) == 1, "Engine/installer_data.json has exactly one full-OS target"
    templates[0]["package"] = package
    return metadata


def written_metadata(package: str, out: Path) -> dict:
    """The installer_data.json build-mac-image writes for PACKAGE."""
    subprocess.run(["bash", "-c", 'source "$1" && write_installer_data "$2" "$3"', "bash",
                    str(ROOT / "bin/build-mac-image"), package, str(out)], check=True)
    return json.loads(out.read_text())


def engine_admits(metadata: Path, payload: Path) -> list:
    """Runs the engine's preflight on METADATA and PAYLOAD; returns the firmware it chose from."""
    chosen = []
    installer = SimpleNamespace(dutil=None, sysinfo=None, osinfo=None,
                                choose_ipsw=lambda supported: chosen.append(supported) or "ipsw")
    adapter = omarchy_asahi.AsahiStage1Adapter(installer=installer, metadata_path=str(metadata),
                                               payload_path=str(payload), stub_size=0)
    try:
        adapter.preflight(SimpleNamespace(length_bytes=1 << 50))
    finally:
        if adapter.osins is not None and getattr(adapter.osins, "pkg", None) is not None:
            adapter.osins.pkg.close()
    return chosen


class EngineContractTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.out = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_the_builders_metadata_is_the_engines(self):
        for name in (NAME, LAB_NAME):
            with self.subTest(name=name):
                expected = engine_metadata(name)
                self.assertEqual(check.expected_metadata(name), expected,
                                 "mac-image-check expects the engine's installer_data.json")
                self.assertEqual(written_metadata(name, self.out / "installer_data.json"), expected,
                                 "build-mac-image writes the engine's installer_data.json")

    def test_the_engine_admits_the_builders_payload(self):
        for name, profile in ((NAME, "release"), (LAB_NAME, "lab")):
            with self.subTest(name=name):
                payload = self.out / name
                fixtures.write_payload(payload, check.BOOT_UUID, check.ROOT_UUID)
                metadata = self.out / "installer_data.json"
                written_metadata(name, metadata)
                metadata.chmod(0o644)
                check.check_payload("edge", payload, metadata, profile)
                chosen = engine_admits(metadata, payload)
                self.assertEqual(chosen, [list(check.expected_metadata(name)["os_list"][0]["supported_fw"])])

    # Whatever the engine refuses, the builder's check must refuse before the payload is published.
    # The builder may refuse more (it holds the payload to Limine and the UKI too); the engine may
    # admit more. Each probe runs both on one payload and its metadata.
    def assert_builder_refuses(self, payload: Path, metadata: Path, what: str) -> bool:
        metadata.chmod(0o644)
        try:
            engine_admits(metadata, payload)
        except omarchy_asahi.AsahiAdapterError:
            pass
        else:
            return False
        with self.assertRaises(check.CheckError, msg=f"the engine refuses {what}; the builder must too"):
            check.check_payload("edge", payload, metadata)
        return True

    def test_the_builder_refuses_the_payloads_the_engine_refuses(self):
        # Every way a member of the payload build-mac-image packages can fall short.
        fixtures.write_payload(self.out / "full.zip", check.BOOT_UUID, check.ROOT_UUID)
        with zipfile.ZipFile(self.out / "full.zip") as archive:
            members = sorted(info.filename for info in archive.infolist() if not info.is_dir())
        changes = [{"omit": (member,)} for member in members] + [{"empty": (member,)} for member in members]
        # Grown by a byte and by each power of two from a sector to two pages: off every alignment
        # either side might ask of an image, so a looser or stricter one on either side shows.
        changes += [{"grow": {member: count}} for member in members for count in (1, 512, 1024, 2048, 4096, 8192)]
        metadata = self.out / "installer_data.json"
        written_metadata(NAME, metadata)
        payload = self.out / NAME
        refused = 0
        for change in changes:
            with self.subTest(**{k: str(v) for k, v in change.items()}):
                fixtures.write_payload(payload, check.BOOT_UUID, check.ROOT_UUID, **change)
                refused += self.assert_builder_refuses(payload, metadata, str(change))
        self.assertGreater(refused, 0, "the engine refuses some short payloads")

    def test_the_builder_refuses_the_unsafe_members_the_engine_refuses(self):
        metadata = self.out / "installer_data.json"
        written_metadata(NAME, metadata)
        payload = self.out / NAME
        symlink = zipfile.ZipInfo("esp/link")
        symlink.external_attr = (0o120777 << 16)
        refused = 0
        # Inside esp/, where the builder takes members, so only its path checks stand between; the
        # duplicates repeat a member's own bytes, so nothing but the duplicate-name check refuses them.
        for name, info in (("esp/../escape", None), ("/esp/absolute", None), ("esp/back\\slash", None),
                           ("esp/m1n1/boot.bin", None), ("boot.img", None), ("esp/link", symlink)):
            with self.subTest(member=name):
                fixtures.write_payload(payload, check.BOOT_UUID, check.ROOT_UUID)
                with zipfile.ZipFile(payload) as archive:
                    data = archive.read(name) if name in archive.namelist() else b"x"
                with warnings.catch_warnings(), zipfile.ZipFile(payload, "a") as archive:
                    warnings.simplefilter("ignore")  # a duplicate name is the point
                    archive.writestr(info or name, data)
                refused += self.assert_builder_refuses(payload, metadata, f"a member {name}")
        self.assertEqual(refused, 6, "the engine refuses every unsafe member")

    def test_the_builder_refuses_images_over_their_partitions(self):
        # Both sides read the partition sizes the metadata declares; shrunk below the fixture's images,
        # each side's capacity check must refuse the same payload.
        payload = self.out / NAME
        fixtures.write_payload(payload, check.BOOT_UUID, check.ROOT_UUID)
        metadata = self.out / "installer_data.json"
        refused = 0
        for constant, member in (("BOOT_SIZE", "boot.img"), ("ROOT_SIZE", "root.img")):
            with self.subTest(partition=member):
                with zipfile.ZipFile(payload) as archive:
                    size = archive.getinfo(member).file_size
                with unittest.mock.patch.object(check, constant, size - 4096):
                    metadata.write_text(json.dumps(check.expected_metadata(NAME)))
                    refused += self.assert_builder_refuses(payload, metadata, f"{member} over its partition")
        self.assertEqual(refused, 2, "the engine refuses an image over its partition")

    def test_the_builder_refuses_the_metadata_the_engine_refuses(self):
        payload = self.out / NAME
        fixtures.write_payload(payload, check.BOOT_UUID, check.ROOT_UUID)
        metadata = self.out / "installer_data.json"

        def edit(change):
            data = written_metadata(NAME, metadata)
            change(data["os_list"][0])
            metadata.write_text(json.dumps(data))

        changes = {
            "another package": lambda t: t.update(package="other.zip"),
            "another boot object": lambda t: t.update(boot_object="m1n1-other.bin"),
            "another next object": lambda t: t.update(next_object="m1n1/other.bin"),
            "another icon": lambda t: t.update(icon="other.icns"),
            "another target": lambda t: t.update(omarchy_target="other"),
            "no expanding root": lambda t: t["partitions"][2].pop("expand"),
            "an expanding boot": lambda t: t["partitions"][1].update(expand=True),
            "partitions reordered": lambda t: t["partitions"].reverse(),
            "a partition fewer": lambda t: t["partitions"].pop(),
            "another root image": lambda t: t["partitions"][2].update(image="other.img"),
            "an ESP without firmware": lambda t: t["partitions"][0].update(copy_firmware=False),
            "an ESP without installer data": lambda t: t["partitions"][0].update(copy_installer_data=False),
            "an ESP of another format": lambda t: t["partitions"][0].update(format="exfat"),
            "a Boot partition too small": lambda t: t["partitions"][1].update(size="4096B"),
        }
        refused = 0
        for what, change in changes.items():
            with self.subTest(metadata=what):
                edit(change)
                refused += self.assert_builder_refuses(payload, metadata, what)
        self.assertEqual(refused, len(changes), "the engine refuses each of these")

if __name__ == "__main__":
    unittest.main()
