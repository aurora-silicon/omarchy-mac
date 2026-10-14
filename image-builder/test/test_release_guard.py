#!/usr/bin/env python3
"""The release guard passes a public image and refuses anything of the lab lane in one, however it got there."""
import base64
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fixtures  # noqa: E402
import test_mac_image_check as records  # noqa: E402

ROOT = fixtures.ROOT
GUARD = ROOT / "bin/mac-release-guard"
loader = importlib.machinery.SourceFileLoader("mac_release_guard", str(GUARD))
spec = importlib.util.spec_from_loader("mac_release_guard", loader)
guard = importlib.util.module_from_spec(spec)
loader.exec_module(guard)
lab_access = fixtures.load("lab_access", "builder/lab_access.py")

LAB_KEY = (ROOT / "builder/lab-catalog-key.ed25519.pub").read_bytes()
TEST_KEY_ARMORED = (ROOT / "builder/candidate-trust/public.asc").read_bytes()
POLICY = json.loads((ROOT / "builder/candidate-trust/policy.json").read_text())
ENTITLEMENTS = b"""<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>com.apple.security.get-task-allow</key><true/></dict></plist>
"""


def run_guard(*arguments: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, str(GUARD), *arguments], capture_output=True, text=True)


def lab_access_dir(base: Path) -> Path:
    directory = base / "lab-access"
    fixtures.write(directory, "authorized_keys",
                   "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKm3ZIe3P3NW/VLwzdZ6vgFvk4OAabP02rnxiZKmXG2r lab-controller\n")
    fixtures.write(directory, "thunderbolt", "*M2 Max*|10.77.0.3/24\n")
    return directory


class ImageTreeTest(unittest.TestCase):
    """The scan of an image's trees, from a public image root that passes inspection."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.base = Path(cls.tmp.name)
        cls.candidate = fixtures.Signer(cls.base / "candidate")
        cls.channel = fixtures.Signer(cls.base / "channel", "Omarchy fixture <pkgs@example.invalid>")
        cls.trust = fixtures.channel_trust(cls.base, cls.candidate, cls.channel)
        database, sha256 = fixtures.make_channel(cls.base / "edge", cls.channel)
        channel_set = fixtures.load("channel_set", "builder/channel_set.py")
        cls.summary = channel_set.snapshot(database, sha256, "edge", cls.base / "edge/packages", cls.base / "set",
                                           cls.trust)
        cls.good = cls.base / "root"
        fixtures.make_root(cls.good, cls.base / "set", "e1b0e5e9b")
        # A test image of a candidate set, as the lab lane builds it.
        test_set = cls.base / "test-set"
        receipt = fixtures.make_set(test_set, cls.candidate)
        fixtures.import_set(test_set, cls.base / "test-candidates", cls.candidate, receipt)
        cls.test_image = cls.base / "test-root"
        fixtures.make_root(cls.test_image, cls.base / "test-candidates", "e1b0e5e9b")
        cls.patterns = guard.key_patterns()

    @classmethod
    def tearDownClass(cls):
        for signer in (cls.candidate, cls.channel):
            signer.close()
        for path in cls.base.rglob("*"):
            if path.is_dir() and not path.is_symlink():
                path.chmod(0o700)
        cls.tmp.cleanup()

    def setUp(self):
        self.work = Path(tempfile.mkdtemp(dir=self.base))
        self.root = self.work / "root"
        shutil.copytree(self.good, self.root, symlinks=True)

    def scan(self, root=None):
        return guard.scan_tree(root or self.root, self.patterns)

    def assertFinds(self, what, root=None):
        found = self.scan(root)
        self.assertTrue(any(what in finding for _, finding in found), f"{what!r} not in {found}")

    def test_a_public_image_passes(self):
        self.assertEqual(self.scan(), [])
        factory = self.work / "factory"
        fixtures.make_factory(factory, self.root, self.summary)
        self.assertEqual(self.scan(factory), [])
        result = run_guard("tree", str(self.root), str(factory))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_a_tree_with_lab_access_is_refused(self):
        fixtures.write(self.root, "usr/lib/systemd/system/sshd.service", "[Service]\n")
        lab_access.apply(lab_access.load(lab_access_dir(self.work)), self.root)
        found = dict(self.scan())
        self.assertEqual(found["etc/sudoers.d/omarchy-lab"], "a passwordless sudo grant for every command")
        self.assertIn("an authorized_keys file", found.values())
        self.assertIn("sshd enabled", found.values())
        self.assertIn("a lab host (10.77.0.3)", found.values())
        result = run_guard("tree", str(self.root))
        self.assertEqual(result.returncode, 1)
        self.assertIn("/etc/sudoers.d/omarchy-lab (a passwordless sudo grant for every command)", result.stderr)
        self.assertIn("refused", result.stderr)

    def test_a_test_image_of_a_candidate_set_is_refused(self):
        found = {what for _, what in self.scan(self.test_image)}
        self.assertIn("the test image pin", found)
        self.assertIn("an image target naming a candidate set", found)
        self.assertIn("an image target with the test profile", found)

    def test_lab_access_however_it_got_there(self):
        cases = {
            "a passwordless sudo grant": ("etc/sudoers.d/10-builder", b"builder ALL=(ALL) NOPASSWD: ALL\n"),
            "a passwordless sudo grant of a shell": ("etc/sudoers.d/10-lab", b"maralc ALL=(root) NOPASSWD: /usr/bin/bash\n"),
            "an authorized_keys file": ("home/maralc/.ssh/authorized_keys", b"ssh-ed25519 AAAA x\n"),
            "a lab file": ("run/omarchy-lab/authorized_keys", b"ssh-ed25519 AAAA x\n"),
            "Tailscale state": ("var/lib/tailscale/tailscaled.state", b"{}"),
            "a lab host (omarchy-m2-max)": ("etc/hosts", b"127.0.0.1 localhost\n10.0.0.9 omarchy-m2-max\n"),
            "a lab host (10.77.0.4)": ("etc/NetworkManager/system-connections/bridge.nmconnection",
                                       b"[ipv4]\naddress1=10.77.0.4/24\n"),
            "a lab host (box.tail1234.ts.net)": ("root/.ssh/config", b"Host box\n  HostName box.tail1234.ts.net\n"),
            "a lab host (192.168.0.197)": ("usr/local/bin/bootstrap", b"curl http://192.168.0.197:8765/s | bash\n"),
            "a lab host (omarchy-m1-pro)": ("boot/efi/limine.conf", b"comment: built on omarchy-m1-pro\n"),
        }
        for what, (relative, body) in cases.items():
            with self.subTest(what=what):
                root = Path(tempfile.mkdtemp(dir=self.work))
                shutil.copytree(self.good, root / "r", symlinks=True)
                fixtures.write(root / "r", relative, body)
                self.assertFinds(what, root / "r")

    def test_a_passwordless_command_that_is_not_a_shell_passes(self):
        fixtures.write(self.root, "etc/sudoers.d/20-tz", "%wheel ALL=(root) NOPASSWD: /usr/bin/timedatectl set-timezone *\n")
        self.assertEqual(self.scan(), [])

    def test_linked_configuration_is_scanned_where_it_points(self):
        # systemd ships its sshd drop-in as a link into /usr/lib.
        fixtures.write(self.root, "usr/lib/systemd/sshd_config.d/20-systemd-userdb.conf",
                       "AuthorizedKeysCommand /usr/bin/userdbctl ssh-authorized-keys %u\n")
        (self.root / "etc/ssh/sshd_config.d").mkdir(parents=True, exist_ok=True)
        (self.root / "etc/ssh/sshd_config.d/20-systemd-userdb.conf").symlink_to(
            "/usr/lib/systemd/sshd_config.d/20-systemd-userdb.conf")
        self.assertEqual(self.scan(), [])
        fixtures.write(self.root, "usr/share/lab/sudo", b"maralc ALL=(ALL) NOPASSWD: ALL\n")
        (self.root / "etc/sudoers.d").mkdir(parents=True, exist_ok=True)
        (self.root / "etc/sudoers.d/lab").symlink_to("../../usr/share/lab/sudo")
        found = dict(self.scan())
        self.assertEqual(found["etc/sudoers.d/lab (linked)"], "a passwordless sudo grant for every command")

    def test_configuration_hidden_from_the_scan_is_refused(self):
        (self.root / "etc/sudoers.d").mkdir(parents=True, exist_ok=True)
        (self.root / "etc/sudoers.d/out").symlink_to("../../../../../../../../../../../tmp/lab-sudo")
        (self.root / "etc/sudoers.d/loop").symlink_to("loop")
        fixtures.write(self.root, "etc/ssh/sshd_config", b"#" * (2 << 20) + b"\nAuthorizedKeysFile /lab/keys\n")
        found = dict(self.scan())
        for where in ("etc/sudoers.d/out", "etc/sudoers.d/loop", "etc/ssh/sshd_config"):
            self.assertIn("cannot read", found[where])

    def test_an_armored_test_key_in_a_large_binary(self):
        root = Path(tempfile.mkdtemp(dir=self.work))
        fixtures.write(root, "usr/bin/tool", b"\0" * (guard.TEXT_LIMIT + 1) + TEST_KEY_ARMORED)
        self.assertFinds("the test candidate key (armored)", root)
        fixtures.write(root, "usr/bin/tool", b"\0" * (guard.TEXT_LIMIT + 1)
                       + (ROOT / "builder/candidate-trust/omarchy-channel.asc").read_bytes())
        self.assertEqual(self.scan(root), [])

    def test_the_lab_catalog_key_in_any_form_and_any_file(self):
        cases = {
            "raw": ("usr/share/omarchy/catalog.pub", LAB_KEY),
            "hex": ("usr/lib/python3/omarchy.py", b"KEY = '" + LAB_KEY.hex().encode() + b"'\n"),
            "base64": ("etc/omarchy/release.json", b'{"key": "' + base64.b64encode(LAB_KEY) + b'"}\n'),
            "fingerprint": ("usr/share/doc/omarchy/README", b"sha256:" + guard.hashlib.sha256(LAB_KEY).hexdigest().encode()),
        }
        for form, (relative, body) in cases.items():
            with self.subTest(form=form):
                root = Path(tempfile.mkdtemp(dir=self.work))
                fixtures.write(root, relative, body)
                self.assertFinds("the lab catalog key", root)

    def test_the_key_is_found_across_a_chunk_boundary(self):
        root = Path(tempfile.mkdtemp(dir=self.work))
        fixtures.write(root, "usr/lib/big.bin", b"\0" * (guard.CHUNK - 10) + LAB_KEY + b"\0" * 10)
        self.assertFinds("the lab catalog key", root)

    def test_the_test_candidate_key_binary_armored_or_by_fingerprint(self):
        binary = guard.dearmor(guard.ARMOR.search(TEST_KEY_ARMORED).group(1))
        cases = {
            "the test candidate key": ("usr/share/pacman/keyrings/lab.gpg", binary),
            "the test candidate key (armored)": ("usr/share/pacman/keyrings/lab.asc", TEST_KEY_ARMORED),
            "the test candidate key's fingerprint": ("usr/share/pacman/keyrings/lab-trusted",
                                                     POLICY["primary_fingerprint"].encode() + b":4:\n"),
        }
        for what, (relative, body) in cases.items():
            with self.subTest(what=what):
                root = Path(tempfile.mkdtemp(dir=self.work))
                fixtures.write(root, relative, body)
                self.assertFinds(what, root)

    def test_the_channel_key_is_not_a_finding(self):
        root = Path(tempfile.mkdtemp(dir=self.work))
        fixtures.write(root, "usr/share/pacman/keyrings/omarchy.asc",
                       (ROOT / "builder/candidate-trust/omarchy-channel.asc").read_bytes())
        fixtures.write(root, "usr/share/pacman/keyrings/omarchy-trusted",
                       POLICY["channel"]["primary_fingerprint"] + ":4:\n")
        self.assertEqual(self.scan(root), [])

    def test_test_candidate_pins(self):
        conf = (self.root / "etc/pacman.conf").read_text()
        cases = {
            "a pin of the runtime": ("etc/pacman.conf", conf.replace("[options]", "[options]\nIgnorePkg = omarchy-dev", 1)),
            "the candidate repository": ("etc/pacman.d/candidates.conf",
                                         "[omarchy-candidates]\nServer = file:///var/cache/candidates\n"),
            "an image target with the lab profile": (
                "var/lib/omarchy/image/target",
                (self.root / "var/lib/omarchy/image/target").read_text().replace("image_profile=release", "image_profile=lab")),
        }
        for what, (relative, body) in cases.items():
            with self.subTest(what=what):
                root = Path(tempfile.mkdtemp(dir=self.work))
                shutil.copytree(self.good, root / "r", symlinks=True)
                fixtures.write(root / "r", relative, body)
                self.assertFinds(what, root / "r")

    def test_get_task_allow(self):
        root = Path(tempfile.mkdtemp(dir=self.work))
        fixtures.write(root, "usr/lib/omarchy/tool.entitlements", ENTITLEMENTS)
        self.assertFinds("a get-task-allow entitlement", root)

    def test_lab_hosts_count_only_where_an_image_keeps_configuration_and_state(self):
        fixtures.write(self.root, "usr/share/doc/networking/example.txt", b"route add 10.77.0.1 via box.example.ts.net\n")
        self.assertEqual(self.scan(), [])

    def test_the_initramfs_and_command_line(self):
        initrd = fixtures.initramfs({"etc/ssh/authorized_keys": b"ssh-ed25519 AAAA x\n",
                                     "etc/hosts": b"10.77.0.2 omarchy-m1-thunderbolt\n"})
        uki = self.work / "omarchy_linux-aurora.efi"
        uki.write_bytes(fixtures.pe_image({".cmdline": b"quiet splash ip=10.77.0.5\0", ".initrd": initrd}))
        found = {what for _, what in guard.uki_findings(uki, self.patterns)}
        self.assertIn("lab access in the initramfs", found)
        self.assertIn("a lab host (omarchy-m1-thunderbolt)", found)
        self.assertIn("a lab host (10.77.0.5)", found)
        uki.write_bytes(fixtures.pe_image({".cmdline": b"quiet splash\0", ".initrd": fixtures.good_initramfs()}))
        self.assertEqual(guard.uki_findings(uki, self.patterns), [])


class RecordsTest(unittest.TestCase):
    """A build directory's records must describe a public image built from the channel."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.out = Path(self.tmp.name) / "out"

    def tearDown(self):
        self.tmp.cleanup()

    def build(self, **options):
        if self.out.exists():
            shutil.rmtree(self.out)
        self.out.mkdir()
        settings = dict(packages=records.CHANNEL_PACKAGES, candidates=records.CHANNEL_PACKAGES[:2],
                        inputs=records.CHANNEL_INPUTS, pin="", sources=(("omarchy-mac", "b" * 40),))
        records.build(self.out, **{**settings, **options})

    def test_a_public_build_passes(self):
        self.build()
        self.assertEqual(guard.records_findings(self.out), [])
        result = run_guard("records", str(self.out))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_lab_and_test_builds_are_refused(self):
        cases = {
            "names a candidate set": dict(inputs=records.INPUTS, packages=records.PACKAGES,
                                          candidates=records.PACKAGES[:2], sources=(("omarchy", "a" * 40),), pin=None),
            "lab profile for a channel image": dict(profile=records.LAB),
            "test image pin for a channel image": dict(pin="omarchy omarchy-mac omarchy-settings"),
            "not signed by the Omarchy package key": dict(
                inputs=dict(records.CHANNEL_INPUTS, channel_signer=POLICY["primary_fingerprint"])),
        }
        for message, options in cases.items():
            with self.subTest(message=message):
                self.build(**options)
                found = guard.records_findings(self.out)
                self.assertTrue(any(message in finding for finding in found), found)
                self.assertEqual(run_guard("records", str(self.out)).returncode, 1)

    def test_a_build_directory_without_records(self):
        self.out.mkdir()
        self.assertEqual(run_guard("records", str(self.out)).returncode, 1)
        self.assertEqual(run_guard("build", str(self.out)).returncode, 1, "records come before any mount")


class PinnedKeysTest(unittest.TestCase):
    def test_the_lab_catalog_key_is_an_ed25519_key(self):
        self.assertEqual(len(LAB_KEY), 32)

    def test_the_test_key_packet_is_the_policys_key(self):
        packet = guard.test_key_packet()
        # A v4 key's fingerprint is the SHA-1 of 0x99, the two-byte length and the packet body.
        fingerprint = guard.hashlib.sha1(b"\x99" + len(packet).to_bytes(2, "big") + packet).hexdigest().upper()
        self.assertEqual(fingerprint, POLICY["primary_fingerprint"])


if __name__ == "__main__":
    unittest.main()
