"""The app release guard refuses an app that carries anything of the lab lane."""
from __future__ import annotations

import hashlib
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest

GUARD = Path(__file__).resolve().parents[1] / "release-guard"


def load_guard():
    loader = importlib.machinery.SourceFileLoader("release_guard", str(GUARD))
    spec = importlib.util.spec_from_loader("release_guard", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


guard = load_guard()
VALUES = guard.identity()
TEAM = VALUES["INSTALLER_TEAM_ID"]
APP_ID = VALUES["INSTALLER_APP_IDENTIFIER"]
HELPER_ID = VALUES["INSTALLER_HELPER_IDENTIFIER"]


def team_requirement(identifier: str) -> str:
    return f'anchor apple generic and identifier "{identifier}" and certificate leaf[subject.OU] = "{TEAM}"'


class ReleaseGuardTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.app = Path(self.temp.name) / f"{VALUES['INSTALLER_APP_NAME']}.app"
        self.make_app()

    def tearDown(self) -> None:
        self.temp.cleanup()

    # ── a public app, as build-app.sh assembles it for the Developer ID ──────
    def make_app(self, trust_root: bytes | None = None) -> None:
        contents = self.app / "Contents"
        for directory in ("MacOS", "Resources/Release", "Resources/Engine/artifacts", "Library/LaunchDaemons",
                          "Library/LaunchServices"):
            (contents / directory).mkdir(parents=True, exist_ok=True)
        self.write_plist(contents / "Info.plist", {
            "CFBundleIdentifier": APP_ID,
            "CFBundleShortVersionString": "2.2.0",
            "SMPrivilegedExecutables": {HELPER_ID: team_requirement(HELPER_ID)},
        })
        self.write_plist(contents / f"Library/LaunchDaemons/{HELPER_ID}.plist", {
            "Label": HELPER_ID,
            "EnvironmentVariables": {"OMARCHY_CLIENT_CODE_SIGNING_REQUIREMENT": team_requirement(APP_ID)},
        })
        (contents / "MacOS/OmarchyAppleInstallerApp").write_bytes(b"\xcf\xfa\xed\xfe" + b"\0" * 64 + b"app code")
        (contents / f"Library/LaunchServices/{HELPER_ID}").write_bytes(b"\xcf\xfa\xed\xfe" + b"\0" * 64)
        self.set_trust_root(trust_root or bytes(range(1, 33)))
        self.write_engine({"installer/main.py": b"print('engine')\n"})

    def set_trust_root(self, key: bytes, **overrides) -> None:
        release = self.app / "Contents/Resources/Release"
        (release / "trust-root.ed25519.pub").write_bytes(key)
        base = VALUES["INSTALLER_CATALOG_BASE"]
        descriptor = {
            "schema_version": 3,
            "default_channel": "edge",
            "channels": {c: {"catalog_url": f"{base}/catalog-{c}.signed.json"} for c in ("stable", "rc", "edge")},
            "trust_root_fingerprint": f"sha256:{hashlib.sha256(key).hexdigest()}",
            "helper_mach_service_name": HELPER_ID,
            "helper_code_signing_requirement": team_requirement(HELPER_ID),
        }
        descriptor.update(overrides)
        (release / "release.json").write_text(json.dumps(descriptor, indent=2))

    def write_engine(self, members: dict[str, bytes]) -> None:
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode="w:gz") as archive:
            for name, data in members.items():
                info = tarfile.TarInfo(name)
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))
        (self.app / "Contents/Resources/Engine/artifacts/installer-test.tar.gz").write_bytes(buffer.getvalue())

    @staticmethod
    def write_plist(path: Path, value: dict) -> None:
        with path.open("wb") as output:
            plistlib.dump(value, output)

    def edit_plist(self, relative: str, change) -> None:
        path = self.app / relative
        value = plistlib.loads(path.read_bytes())
        change(value)
        self.write_plist(path, value)

    def findings(self) -> list[str]:
        scan = guard.Guard()
        scan.scan_path(self.app)
        return scan.findings

    def assertRefused(self, fragment: str) -> None:
        findings = self.findings()
        self.assertTrue(any(fragment in finding for finding in findings),
                        f"no finding mentions {fragment!r}: {findings}")

    # ── the cases ───────────────────────────────────────────────────────────
    def test_a_public_app_is_clean(self) -> None:
        self.assertEqual(self.findings(), [])

    def test_the_command_exits_zero_for_a_clean_app_and_one_for_a_finding(self) -> None:
        run = [sys.executable, str(GUARD), str(self.app)]
        self.assertEqual(subprocess.run(run, capture_output=True).returncode, 0)
        (self.app / "Contents/Resources/debug.entitlements").write_bytes(
            b"<plist><dict><key>com.apple.security.get-task-allow</key><true/></dict></plist>")
        refused = subprocess.run(run, capture_output=True, text=True)
        self.assertEqual(refused.returncode, 1)
        self.assertIn("get-task-allow", refused.stderr)

    def test_get_task_allow_in_an_entitlements_plist_is_refused(self) -> None:
        (self.app / "Contents/Resources/app.entitlements").write_bytes(
            b"<plist><dict><key>get-task-allow</key><true/></dict></plist>")
        self.assertRefused("get-task-allow")

    def test_get_task_allow_in_a_signature_blob_is_refused(self) -> None:
        binary = self.app / "Contents/MacOS/OmarchyAppleInstallerApp"
        binary.write_bytes(binary.read_bytes() + b"\x30\x1d\x0c\x0eget-task-allow\x01\x01\xff")
        self.assertRefused("get-task-allow")

    def test_get_task_allow_in_a_binary_plist_is_refused(self) -> None:
        (self.app / "Contents/Resources/app.entitlements").write_bytes(
            plistlib.dumps({"com.apple.security.get-task-allow": True}, fmt=plistlib.FMT_BINARY))
        self.assertRefused("get-task-allow")

    @unittest.skipUnless(shutil.which("cc") and shutil.which("codesign"), "needs cc and codesign (macOS)")
    def test_get_task_allow_signed_into_an_archived_binary_is_refused(self) -> None:
        work = Path(self.temp.name)
        (work / "tool.c").write_text("int main(void) { return 0; }\n")
        (work / "debug.plist").write_bytes(plistlib.dumps({"com.apple.security.get-task-allow": True}))
        subprocess.run(["cc", "-o", str(work / "tool"), str(work / "tool.c")], check=True)
        subprocess.run(["codesign", "--force", "--sign", "-", "--entitlements", str(work / "debug.plist"),
                        str(work / "tool")], check=True, capture_output=True)
        self.write_engine({"bin/tool": (work / "tool").read_bytes()})
        self.assertRefused("installer-test.tar.gz!bin/tool: a get-task-allow entitlement in its signature")

    def test_a_symlinked_release_input_is_refused(self) -> None:
        release = self.app / "Contents/Resources/Release"
        (release / "trust-root.ed25519.pub").rename(Path(self.temp.name) / "key")
        os.symlink(Path(self.temp.name) / "key", release / "trust-root.ed25519.pub")
        self.assertRefused("a symbolic link Release/trust-root.ed25519.pub")

    def test_the_lab_catalog_key_as_trust_root_is_refused(self) -> None:
        self.set_trust_root(guard.LAB_CATALOG_KEY.read_bytes())
        self.assertRefused("the lab catalog key")
        self.assertRefused("the lab catalog key's fingerprint")

    def test_the_lab_catalog_key_in_hex_anywhere_is_refused(self) -> None:
        (self.app / "Contents/Resources/notes.txt").write_text(guard.LAB_CATALOG_KEY.read_bytes().hex())
        self.assertRefused("the lab catalog key (hex)")

    def test_the_test_candidate_key_is_refused(self) -> None:
        policy = json.loads((guard.CANDIDATE_TRUST / "policy.json").read_text())
        (self.app / "Contents/Resources/keys.txt").write_text(policy["primary_fingerprint"])
        self.assertRefused("the test candidate key's fingerprint")

    def test_a_lab_host_name_in_a_binary_is_refused(self) -> None:
        binary = self.app / "Contents/MacOS/OmarchyAppleInstallerApp"
        binary.write_bytes(binary.read_bytes() + b"\0ssh lab@omarchy-m2-max.local\0")
        self.assertRefused("a lab host name")

    def test_the_lab_thunderbolt_network_is_refused(self) -> None:
        (self.app / "Contents/Resources/hosts").write_text("10.77.0.2 builder\n")
        self.assertRefused("a lab host name")

    def test_an_ssh_public_key_is_refused(self) -> None:
        (self.app / "Contents/Resources/access").write_text(
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeFakeFakeFakeFakeFakeFakeFake lab@m4\n")
        self.assertRefused("lab access (ssh-ed25519")

    def test_an_authorized_keys_file_is_refused(self) -> None:
        (self.app / "Contents/Resources/authorized_keys").write_text("\n")
        self.assertRefused("a lab access file")

    def test_lab_access_inside_the_bundled_engine_is_refused(self) -> None:
        self.write_engine({"etc/sudoers.d/omarchy-lab": b"lab ALL=(ALL) NOPASSWD: ALL\n"})
        self.assertRefused("installer-test.tar.gz!etc/sudoers.d/omarchy-lab: a lab file")
        self.assertRefused("lab access (NOPASSWD)")

    def test_a_private_test_profile_is_refused(self) -> None:
        self.edit_plist("Contents/Info.plist", lambda info: info.update(OmarchyPrivatePlainTest=True))
        self.assertRefused("private test profile flag")

    def test_a_sealed_catalog_is_refused(self) -> None:
        (self.app / "Contents/Resources/Release/catalog.json").write_text("{}")
        self.assertRefused("a sealed private input Release/catalog.json")

    def test_another_bundle_identifier_is_refused(self) -> None:
        self.edit_plist("Contents/Info.plist", lambda info: info.update(CFBundleIdentifier=f"{APP_ID}.lab"))
        self.assertRefused("bundle identifier")

    def test_an_identifier_only_helper_requirement_is_refused(self) -> None:
        self.set_trust_root(bytes(range(1, 33)), helper_code_signing_requirement=f'identifier "{HELPER_ID}"')
        self.assertRefused("release.json's helper requirement")

    def test_a_cdhash_pinned_helper_requirement_is_refused(self) -> None:
        self.edit_plist("Contents/Info.plist", lambda info: info.update(
            SMPrivilegedExecutables={HELPER_ID: f'identifier "{HELPER_ID}" and cdhash H"{"0" * 40}"'}))
        self.assertRefused("SMPrivilegedExecutables")

    def test_a_switched_off_client_check_is_refused(self) -> None:
        self.edit_plist(f"Contents/Library/LaunchDaemons/{HELPER_ID}.plist", lambda daemon: daemon.update(
            EnvironmentVariables={"OMARCHY_CLIENT_CODE_SIGNING_REQUIREMENT": "never"}))
        self.assertRefused("client requirement")

    def test_a_catalog_outside_the_catalog_base_is_refused(self) -> None:
        self.set_trust_root(bytes(range(1, 33)), channels={
            "edge": {"catalog_url": "https://example.invalid/catalog-edge.signed.json"}})
        self.assertRefused("the edge catalog")

    def test_the_stopgap_catalogs_are_accepted(self) -> None:
        stopgap = f"https://github.com/{VALUES['INSTALLER_CATALOG_STOPGAP_REPO']}/releases/download"
        self.set_trust_root(bytes(range(1, 33)), channels={
            c: {"catalog_url": f"{stopgap}/catalog-{c}/catalog-{c}.signed.json"} for c in ("stable", "rc", "edge")})
        self.assertEqual(self.findings(), [])

    def test_another_channels_stopgap_catalog_is_refused(self) -> None:
        stopgap = f"https://github.com/{VALUES['INSTALLER_CATALOG_STOPGAP_REPO']}/releases/download"
        base = VALUES["INSTALLER_CATALOG_BASE"]
        self.set_trust_root(bytes(range(1, 33)), channels={
            "stable": {"catalog_url": f"{stopgap}/catalog-edge/catalog-edge.signed.json"},
            "rc": {"catalog_url": f"{base}/catalog-rc.signed.json"},
            "edge": {"catalog_url": f"{base}/catalog-edge.signed.json"}})
        self.assertRefused("the stable catalog")

    def test_a_catalog_on_another_github_repository_is_refused(self) -> None:
        base = VALUES["INSTALLER_CATALOG_BASE"]
        self.set_trust_root(bytes(range(1, 33)), channels={
            "stable": {"catalog_url": f"{base}/catalog-stable.signed.json"},
            "rc": {"catalog_url": f"{base}/catalog-rc.signed.json"},
            "edge": {"catalog_url": "https://github.com/someone/fork/releases/download/catalog-edge/catalog-edge.signed.json"}})
        self.assertRefused("the edge catalog")

    def test_an_unpinned_trust_root_is_refused(self) -> None:
        self.set_trust_root(bytes(range(1, 33)), trust_root_fingerprint="sha256:" + "0" * 64)
        self.assertRefused("does not pin the bundled trust root")

    def test_symbolic_links_are_not_followed(self) -> None:
        os.symlink("/", self.app / "Contents/Resources/root")
        self.assertEqual(self.findings(), [])


if __name__ == "__main__":
    unittest.main()
