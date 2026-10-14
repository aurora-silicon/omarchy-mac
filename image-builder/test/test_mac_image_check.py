#!/usr/bin/env python3
"""A build directory's payload, PROVENANCE and IMAGE must describe the same image and candidate set."""
import hashlib
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import uuid

ROOT = Path(__file__).resolve().parents[1]
loader = importlib.machinery.SourceFileLoader("mac_image_check", str(ROOT / "bin/mac-image-check"))
spec = importlib.util.spec_from_loader("mac_image_check", loader)
check = importlib.util.module_from_spec(spec)
loader.exec_module(check)

NAME = "omarchy-2026.09.25-aarch64-apple-silicon-mac-edge-os-package.zip"
LAB = ["profile=lab", "lab_access_sha256=" + "d" * 64]
LAB_NAME = "omarchy-2026.09.25-aarch64-apple-silicon-mac-edge-lab-os-package.zip"
BUILT = "2026-09-25T03:04:05Z"
INPUTS = {
    "candidate_set": "apple-test-fixture",
    "candidate_source_commit": "a" * 40,
    "candidate_signer": "E" * 40,
    "candidate_receipt_sha256": "1" * 64,
    "candidate_manifest_sha256": "2" * 64,
    "omarchy_channel": "edge",
}
PACKAGES = [
    ("omarchy", "4.0.0-1", "omarchy-candidates", "omarchy-4.0.0-1-aarch64.pkg.tar.xz", "3" * 64),
    ("uboot-asahi", "2026.07-1", "omarchy-candidates", "uboot-asahi-2026.07-1-aarch64.pkg.tar.zst", "4" * 64),
    ("glibc", "2.43-1", "core", "glibc-2.43-1-aarch64.pkg.tar.xz", "5" * 64),
]


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def pe(extra: bytes) -> bytes:
    data = bytearray(0x200)
    data[:2] = b"MZ"
    struct.pack_into("<I", data, 0x3C, 0x80)
    data[0x80:0x84] = b"PE\0\0"
    struct.pack_into("<H", data, 0x84, 0xAA64)
    return bytes(data) + extra


def package_set(packages) -> str:
    lines = sorted((f"{n}|{v}|{s}\n" for n, v, _, _, s in packages), key=str.encode)
    return hashlib.sha256("".join(lines).encode()).hexdigest()


def build(out: Path, packages=PACKAGES, candidates=PACKAGES[:2], inspection="passed", image_edit=None,
          profile=(), provenance_profile=None, name=None, inspection_digest=None, target_edit=None,
          sources=(("omarchy", "a" * 40),), runtime_sources=None, provenance_edit=None, legacy=False, target_profile="generic") -> None:
    """A build directory as build-mac-image writes it; LEGACY, as a build before builds recorded their identity."""
    inputs = dict(INPUTS)
    if target_profile != "generic":
        inputs["image_target_profile"] = target_profile
    lab = "profile=lab" in profile
    name = name or (LAB_NAME if lab else NAME)
    payload = out / "payload"
    for directory in ("esp/EFI/BOOT", "esp/EFI/Linux", "esp/m1n1", "esp/omarchy"):
        (payload / directory).mkdir(parents=True)
    boot = bytearray(1 << 16)
    boot[0x438:0x43A] = b"\x53\xef"
    boot[0x468:0x478] = uuid.UUID(check.BOOT_UUID).bytes
    boot[0x478:0x484] = b"OMARCHY_BOOT"
    (payload / "boot.img").write_bytes(boot)
    root = bytearray(1 << 17)
    root[0x10020:0x10030] = uuid.UUID(check.ROOT_UUID).bytes
    root[0x10040:0x10048] = b"_BHRfS_M"
    root[0x1012B:0x1012B + 12] = b"OMARCHY_ROOT"
    (payload / "root.img").write_bytes(root)
    (payload / "esp/EFI/BOOT/BOOTAA64.EFI").write_bytes(pe(b"Limine 12.9.0\n"))
    (payload / "esp/EFI/Linux/omarchy_linux-aurora.efi").write_bytes(pe(b".linux\0.initrd\0"))
    (payload / "esp/limine.conf").write_text("interface_branding: Omarchy Bootloader\n//linux-aurora\n"
                                             "  protocol: efi\n  path: boot():/EFI/Linux/omarchy_linux-aurora.efi\n")
    (payload / "esp/m1n1/boot.bin").write_bytes(b"m1n1" * 64)
    if target_profile == "neo-j700":
        c = check._module("candidate_set")
        stage1 = payload / "esp/aurora/stage1.bin"
        stage1.parent.mkdir()
        stage1.write_bytes(b"bare Aura" + c.STAGE1_MAGIC + c.STAGE1_BODY.pack(1, 0, b"", b"")
                          + struct.pack("<I", 0) + b"STACKBOT")
    shutil.copy(ROOT / "builder/omarchy-volume.icns", payload / "omarchy-volume.icns")
    zip_path = out / name
    subprocess.run(["bsdtar", "--format", "zip", "-cf", str(zip_path), "esp", "boot.img", "root.img",
                    "omarchy-volume.icns"], cwd=payload, check=True)
    (out / "installer_data.json").write_text(json.dumps(check.expected_metadata(name, target_profile)))
    target = {"candidate_set": inputs["candidate_set"], "candidate_source_commit": inputs["candidate_source_commit"],
              "builder_commit": "c" * 40, "builder_tree_clean": "true", "image_profile": "lab" if lab else "test",
              "package_set_sha256": package_set(packages), "built": BUILT}
    if target_profile != "generic":
        target["image_target_profile"] = target_profile
        target["board"] = "apple,j700"
    if legacy:
        del target["package_set_sha256"], target["built"]
    if target_edit:
        target = target_edit(target)
    report = {"result": inspection, "runtime_sources": dict(sources) if runtime_sources is None else runtime_sources}
    if target is not None:
        report["image_target"] = target
    digest = inspection_digest or next((l.split("=", 1)[1] for l in profile if l.startswith("lab_access_sha256=")), None)
    if digest:
        report.update(profile="lab", lab_access_sha256=digest)
    (out / "INSPECTION").write_text(json.dumps(report))
    (out / "inputs").write_text("format=2\n" + "".join(f"{k}={v}\n" for k, v in inputs.items()))
    lines = ["format=2", "kind=mac-image", "lane=edge", "kernel=linux-aurora", "platform=apple-silicon",
             "builder_commit=" + "c" * 40, "builder_tree_clean=true", f"inputs_sha256={sha(out / 'inputs')}"]
    lines += [f"input.{k}={v}" for k, v in inputs.items()]
    lines += [f"candidate={n}|{v}|{f}|{s}" for n, v, _, f, s in candidates]
    lines += [f"candidate_source={n}|{c}" for n, c in sources]
    if target_profile != "generic":
        lines += ["image_target_profile=" + target_profile]
    lines += ["hardware_setup=build", *(profile if provenance_profile is None else provenance_profile),
              f"package_set_sha256={package_set(packages)}", *([] if legacy else [f"built={BUILT}"]),
              f"package_count={len(packages)}"]
    lines += [f"package={i}|{'|'.join(p)}" for i, p in enumerate(packages, 1)]
    lines += [f"installer_data_sha256={sha(out / 'installer_data.json')}", f"inspection_sha256={sha(out / 'INSPECTION')}",
              f"payload={name}|{zip_path.stat().st_size}|{sha(zip_path)}"]
    if provenance_edit:
        lines = provenance_edit(lines)
    (out / "PROVENANCE").write_text("\n".join(lines) + "\n")
    digests = check.check_payload("edge", zip_path, out / "installer_data.json", "lab" if name == LAB_NAME else "release", target_profile)
    image = ["format=2", "lane=edge", "platform=apple-silicon", "builder_commit=" + "c" * 40, "builder_tree_clean=true",
             *[f"{k}={v}" for k, v in inputs.items()],
             "hardware_setup=build", *profile, f"package_set_sha256={package_set(packages)}",
             *([] if legacy else [f"built={BUILT}"]),
             *[f"image_sha256={m}|{d}" for m, d in sorted(digests.items())], f"input_digest={sha(out / 'inputs')}"]
    if image_edit:
        image = image_edit(image)
    (out / "IMAGE").write_text("\n".join(image) + "\n")
    shutil.rmtree(payload)


class BuildDirectoryTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.out = Path(self.tmp.name) / "out"
        self.out.mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def test_neo_profile_roundtrip_and_receipt_substitution_rejection(self):
        build(self.out, target_profile="neo-j700")
        check.check_descriptor("edge", self.out)
        check.check_provenance("edge", self.out)
        image = self.out / "IMAGE"
        image.write_text(image.read_text().replace("image_target_profile=neo-j700\n", ""))
        with self.assertRaisesRegex(check.CheckError, "target profile"):
            check.check_descriptor("edge", self.out)

    def test_a_consistent_build_directory_passes(self):
        build(self.out)
        check.check_provenance("edge", self.out)
        check.check_descriptor("edge", self.out)

    def test_a_candidate_installed_from_another_repository(self):
        packages = [PACKAGES[0], ("uboot-asahi", "2026.07-1", "asahi-alarm", PACKAGES[1][3], PACKAGES[1][4]), PACKAGES[2]]
        build(self.out, packages=packages)
        with self.assertRaisesRegex(check.CheckError, "uboot-asahi from the candidate set"):
            check.check_provenance("edge", self.out)

    def test_a_failed_inspection(self):
        build(self.out, inspection="failed")
        with self.assertRaisesRegex(check.CheckError, "INSPECTION did not pass"):
            check.check_provenance("edge", self.out)

    def test_image_names_another_candidate_set(self):
        build(self.out, image_edit=lambda lines: [l.replace("apple-test-fixture", "apple-test-other") for l in lines])
        with self.assertRaisesRegex(check.CheckError, "candidate_set"):
            check.check_descriptor("edge", self.out)

    def test_image_names_another_builder(self):
        build(self.out, image_edit=lambda lines: [("builder_commit=" + "d" * 40) if l.startswith("builder_commit")
                                                  else l for l in lines])
        with self.assertRaisesRegex(check.CheckError, "builder_commit"):
            check.check_descriptor("edge", self.out)

    def test_image_from_an_uncommitted_tree_says_so(self):
        build(self.out, image_edit=lambda lines: [l.replace("builder_tree_clean=true", "builder_tree_clean=false")
                                                  for l in lines])
        with self.assertRaisesRegex(check.CheckError, "builder_tree_clean"):
            check.check_descriptor("edge", self.out)

    def test_image_names_another_package_set(self):
        build(self.out, image_edit=lambda lines: [("package_set_sha256=" + "0" * 64) if l.startswith("package_set")
                                                  else l for l in lines])
        with self.assertRaisesRegex(check.CheckError, "package_set_sha256"):
            check.check_descriptor("edge", self.out)

    def test_image_and_provenance_record_one_build_time(self):
        def replace_built(value):
            return lambda lines: [f"built={value}" if l.startswith("built=") else l for l in lines]
        cases = (
            ("descriptor", dict(image_edit=replace_built("2026-09-25T03:04:06Z")), "IMAGE built does not match"),
            ("descriptor", dict(image_edit=lambda lines: [l for l in lines if not l.startswith("built=")]),
             "IMAGE built does not match PROVENANCE"),
            ("descriptor", dict(image_edit=lambda lines: lines + [f"built={BUILT}"]), "does not name built once"),
            ("descriptor", dict(image_edit=replace_built("2026-09-25 03:04:05")), "IMAGE names no UTC build time"),
            ("provenance", dict(provenance_edit=lambda lines: [l for l in lines if not l.startswith("built=")]),
             "records a build identity that PROVENANCE does not"),
            ("provenance", dict(provenance_edit=lambda lines: lines + [f"built={BUILT}"]), "does not name built once"),
            ("provenance", dict(provenance_edit=replace_built("2026-02-30T03:04:05Z")),
             "PROVENANCE names no UTC build time"),
        )
        for mode, options, message in cases:
            with self.subTest(message=message, mode=mode):
                shutil.rmtree(self.out)
                self.out.mkdir()
                build(self.out, **options)
                with self.assertRaisesRegex(check.CheckError, message):
                    getattr(check, f"check_{mode}")("edge", self.out)

    def test_a_build_from_before_builds_recorded_their_identity_passes(self):
        # Published images (preview-3-f22c43fb7903, the m1 and m2 lab kits) carry no
        # built= in IMAGE or PROVENANCE, and no identity in INSPECTION's image target.
        for profile in ((), LAB):
            with self.subTest(lab=bool(profile)):
                shutil.rmtree(self.out)
                self.out.mkdir()
                build(self.out, legacy=True, profile=profile)
                check.check_provenance("edge", self.out)
                check.check_descriptor("edge", self.out)

    def test_a_partial_build_identity_is_refused(self):
        without_built = lambda lines: [l for l in lines if not l.startswith("built=")]
        cases = (
            ("provenance", dict(legacy=True, target_edit=lambda t: {**t, "package_set_sha256": package_set(PACKAGES)}),
             "records a build identity that PROVENANCE does not"),
            ("provenance", dict(legacy=True, target_edit=lambda t: {**t, "built": BUILT}),
             "records a build identity that PROVENANCE does not"),
            ("provenance", dict(target_edit=lambda t: {k: v for k, v in t.items() if k != "package_set_sha256"}),
             "image target's package_set_sha256 does not match"),
            ("provenance", dict(legacy=True, provenance_edit=lambda lines: lines + [f"built={BUILT}"]),
             "image target's package_set_sha256 does not match"),
            ("descriptor", dict(legacy=True, image_edit=lambda lines: lines + [f"built={BUILT}"]),
             "IMAGE built does not match PROVENANCE"),
            ("descriptor", dict(image_edit=without_built), "IMAGE built does not match PROVENANCE"),
            ("descriptor", dict(provenance_edit=without_built), "IMAGE built does not match PROVENANCE"),
        )
        for mode, options, message in cases:
            with self.subTest(message=message, mode=mode, options=sorted(options)):
                shutil.rmtree(self.out)
                self.out.mkdir()
                build(self.out, **options)
                with self.assertRaisesRegex(check.CheckError, message):
                    getattr(check, f"check_{mode}")("edge", self.out)

    def test_inspection_must_read_this_builds_provenance_in_the_image(self):
        cases = {
            "does not record the image target": lambda t: None,
            "candidate_set does not match": lambda t: {**t, "candidate_set": "apple-test-other"},
            "candidate_source_commit does not match": lambda t: {**t, "candidate_source_commit": "b" * 40},
            "builder_commit does not match": lambda t: {**t, "builder_commit": "d" * 40},
            "builder_tree_clean does not match": lambda t: {**t, "builder_tree_clean": "false"},
            "profile does not match": lambda t: {**t, "image_profile": "lab"},
            "package_set_sha256 does not match": lambda t: {**t, "package_set_sha256": "0" * 64},
            "built does not match": lambda t: {**t, "built": "2026-09-25T03:04:06Z"},
            "image target's built does not match": lambda t: {k: v for k, v in t.items() if k != "built"},
        }
        for message, edit in cases.items():
            with self.subTest(message):
                shutil.rmtree(self.out)
                self.out.mkdir()
                build(self.out, target_edit=edit)
                with self.assertRaisesRegex(check.CheckError, message):
                    check.check_provenance("edge", self.out)

    def test_runtime_sources_must_be_inspections_and_the_sets(self):
        cases = {
            "no source": dict(sources=(), runtime_sources={}),
            "twice": dict(sources=(("omarchy", "a" * 40), ("omarchy", "a" * 40)), runtime_sources={"omarchy": "a" * 40}),
            "not a set package": dict(sources=(("omarchy", "a" * 40), ("glibc", "a" * 40))),
            "not a commit": dict(sources=(("omarchy", "a" * 39),)),
            "not inspection's": dict(runtime_sources={"omarchy": "a" * 40, "uboot-asahi": "b" * 40}),
            "another runtime commit": dict(sources=(("omarchy", "b" * 40),)),
        }
        for label, change in cases.items():
            with self.subTest(label):
                shutil.rmtree(self.out)
                self.out.mkdir()
                build(self.out, **change)
                with self.assertRaisesRegex(check.CheckError, "candidate source|runtime"):
                    check.check_provenance("edge", self.out)
        shutil.rmtree(self.out)
        self.out.mkdir()
        build(self.out, sources=(("omarchy", "a" * 40), ("uboot-asahi", "b" * 40)))
        check.check_provenance("edge", self.out)

    def test_a_changed_payload(self):
        build(self.out)
        with (self.out / NAME).open("ab") as stream:
            stream.write(b"\0")
        with self.assertRaises(check.CheckError):
            check.check_provenance("edge", self.out)

    def test_a_lab_image_on_edge_passes(self):
        build(self.out, profile=LAB)
        check.check_provenance("edge", self.out)
        check.check_descriptor("edge", self.out)

    def test_lab_and_release_payloads_are_told_apart_by_name(self):
        build(self.out, profile=LAB)
        with self.assertRaisesRegex(check.CheckError, "names a lab image"):
            check.check_payload("edge", self.out / LAB_NAME, self.out / "installer_data.json", "release")
        shutil.rmtree(self.out)
        self.out.mkdir()
        build(self.out)
        with self.assertRaisesRegex(check.CheckError, "does not name a lab image"):
            check.check_payload("edge", self.out / NAME, self.out / "installer_data.json", "lab")
        for mode in ("provenance", "descriptor"):
            with self.subTest(mode=mode):
                shutil.rmtree(self.out)
                self.out.mkdir()
                build(self.out, name=LAB_NAME)
                with self.assertRaisesRegex(check.CheckError, "names a lab image"):
                    getattr(check, f"check_{mode}")("edge", self.out)

    def test_inspection_must_carry_the_recorded_lab_digest(self):
        build(self.out, profile=LAB, inspection_digest="e" * 64)
        with self.assertRaisesRegex(check.CheckError, "INSPECTION's lab access digest"):
            check.check_provenance("edge", self.out)

    def test_a_lab_record_must_be_whole_and_agree(self):
        cases = {
            "names no lab access digest": dict(profile=["profile=lab"]),
            "not one profile=lab": dict(profile=["profile=release"]),
            "lab access on a release image": dict(profile=[LAB[1]]),
            "profile does not match PROVENANCE": dict(profile=LAB, provenance_profile=[]),
            "lab_access_sha256 does not match PROVENANCE": dict(
                profile=LAB, provenance_profile=["profile=lab", "lab_access_sha256=" + "e" * 64]),
        }
        for message, options in cases.items():
            with self.subTest(message=message):
                shutil.rmtree(self.out)
                self.out.mkdir()
                build(self.out, **options)
                with self.assertRaisesRegex(check.CheckError, message):
                    check.check_descriptor("edge", self.out)

    def test_tree_cli_forwards_operator_trust_only_to_inspection(self):
        trust = self.out / "operator-trust"
        with patch.object(check, "check_tree", return_value=""), patch.object(check, "inspect_tree") as inspect:
            self.assertEqual(check.main(["mac-image-check", "tree", "edge", str(self.out),
                                         "--candidates", str(self.out), "--trust-dir", str(trust)]), 0)
            self.assertEqual(inspect.call_args.args[-1], trust)
        self.assertEqual(check.main(["mac-image-check", "payload", "edge", "a", "b",
                                     "--trust-dir", str(trust)]), 64)

    def test_a_lab_image_is_refused_on_release_lanes(self):
        for lane in ("rc", "stable"):
            with self.subTest(lane=lane):
                with self.assertRaisesRegex(check.CheckError, f"refused on the {lane} lane"):
                    check.check_recorded_profile(lane, {"profile": ["lab"], "lab_access_sha256": ["f" * 64]}, "IMAGE")
                with self.assertRaisesRegex(check.CheckError, f"refused on the {lane} lane"):
                    check.check_profile(lane, "lab")
                self.assertEqual(check.main(["mac-image-check", "tree", lane, str(self.out), "--candidates",
                                             str(self.out), "--profile", "lab"]), 1)
        self.assertEqual(check.main(["mac-image-check", "provenance", "edge", str(self.out), "--profile", "lab"]), 64)

    def test_payload_without_limine(self):
        build(self.out)
        payload = self.out / "unpacked"
        payload.mkdir()
        subprocess.run(["bsdtar", "-xf", str(self.out / NAME), "-C", str(payload)], check=True)
        (payload / "esp/EFI/BOOT/BOOTAA64.EFI").write_bytes(pe(b"GRUB 2.12\n"))
        (self.out / NAME).unlink()
        subprocess.run(["bsdtar", "--format", "zip", "-cf", str(self.out / NAME), "esp", "boot.img", "root.img",
                        "omarchy-volume.icns"], cwd=payload, check=True)
        with self.assertRaisesRegex(check.CheckError, "not Limine"):
            check.check_payload("edge", self.out / NAME, self.out / "installer_data.json")


class SubvolumeTest(unittest.TestCase):
    def test_the_five_subvolumes_and_snappers(self):
        check.check_subvolumes(["@", "@home", "@log", "@pkg", "@factory"])
        check.check_subvolumes(["@", "@home", "@log", "@pkg", "@factory", "@/.snapshots"])

    def test_a_missing_extra_or_other_nested_subvolume(self):
        for listed in (["@", "@home", "@log", "@factory"],
                       ["@", "@home", "@log", "@pkg", "@factory", "@swap"],
                       ["@", "@home", "@log", "@pkg", "@factory", "@/.snapshots", "@/.snapshots/1/snapshot"],
                       ["@", "@home", "@log", "@pkg", "@factory", "@factory/.snapshots"]):
            with self.subTest(listed), self.assertRaisesRegex(check.CheckError, "subvolumes"):
                check.check_subvolumes(listed)



class BootTreeTest(unittest.TestCase):
    """The installed /boot and ESP of a fresh image: Limine only, no GRUB."""

    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root)
        boot = self.root / "boot"
        for name in (f"vmlinuz-{check.KERNEL}", f"initramfs-{check.KERNEL}.img", "efi/EFI/BOOT/BOOTAA64.EFI",
                     "efi/m1n1/boot.bin", "efi/limine.conf", f"efi/EFI/Linux/omarchy_{check.KERNEL}.efi"):
            (boot / name).parent.mkdir(parents=True, exist_ok=True)
            (boot / name).write_bytes(b"x")
        (boot / "efi/omarchy").mkdir()
        (boot / "omarchy").mkdir()
        (self.root / "etc/default").mkdir(parents=True)
        (self.root / "etc/default/limine").write_text(
            f'ESP_PATH="/boot/efi"\nKERNEL_CMDLINE[default]="root=UUID={check.ROOT_UUID} rw '
            'rootflags=subvol=@,x-systemd.device-timeout=0 zswap.enabled=0 rootfstype=btrfs quiet splash"\n')

    def test_limine_only(self):
        check.check_boot(self.root)

    def test_grub_leftovers_fail(self):
        for name in ("boot/grub", "etc/default/update-grub"):
            with self.subTest(name=name):
                path = self.root / name
                path.mkdir() if name == "boot/grub" else path.write_text('TARGET="/boot/grub/grub-aa64.efi"\n')
                with self.assertRaisesRegex(check.CheckError, "without GRUB"):
                    check.check_boot(self.root)
                path.rmdir() if path.is_dir() else path.unlink()

    def test_command_line_without_the_root_fails(self):
        (self.root / "etc/default/limine").write_text('KERNEL_CMDLINE[default]="quiet splash"\n')
        with self.assertRaisesRegex(check.CheckError, "lacks root=UUID="):
            check.check_boot(self.root)


class SyncDatabasesTest(unittest.TestCase):
    """First boot resolves packages offline from the sync databases the image keeps."""

    REPOSITORIES = ("omarchy", "asahi-alarm", "core", "extra", "alarm", "aur")

    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root)
        (self.root / "etc").mkdir()
        (self.root / "etc/pacman.conf").write_text(
            "[options]\nSigLevel = Required DatabaseOptional\n"
            + "".join(f"\n[{name}]\nInclude = /etc/pacman.d/mirrorlist\n" for name in self.REPOSITORIES)
            + "\n# [core-debug]\n")
        self.sync = self.root / "var/lib/pacman/sync"
        self.sync.mkdir(parents=True)
        for name in self.REPOSITORIES:
            (self.sync / f"{name}.db").write_bytes(b"db")

    def test_one_database_per_configured_repository(self):
        check.check_sync_databases(self.root)

    def test_refusals(self):
        cases = (
            ("no sync databases", lambda: shutil.rmtree(self.sync), "keeps no pacman sync databases"),
            ("a missing one", lambda: (self.sync / "aur.db").unlink(), "are not its pacman.conf's"),
            ("the build's candidates", lambda: (self.sync / "omarchy-candidates.db").write_bytes(b"db"),
             "are not its pacman.conf's"),
            ("the empty fork placeholder", lambda: (self.sync / "omarchy-aarch64.db").write_bytes(b"db"),
             "are not its pacman.conf's"),
            ("a leftover lock", lambda: (self.sync / "db.lck").write_bytes(b""), "are not its pacman.conf's"),
            ("an empty database", lambda: (self.sync / "core.db").write_bytes(b""), "not a regular, non-empty file"),
            ("a linked database", lambda: ((self.sync / "core.db").unlink(), (self.sync / "core.db").symlink_to("extra.db")),
             "not a regular, non-empty file"),
        )
        for label, edit, message in cases:
            with self.subTest(label):
                self.setUp()
                edit()
                with self.assertRaisesRegex(check.CheckError, message):
                    check.check_sync_databases(self.root)

if __name__ == "__main__":
    unittest.main()
