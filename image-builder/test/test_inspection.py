#!/usr/bin/env python3
"""Inspection fails an image whose boot components are missing or differ from the set."""
import hashlib
import os
import re
from pathlib import Path
import shutil
import sys
import tempfile
from types import SimpleNamespace
import unittest
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fixtures  # noqa: E402

inspection = fixtures.load("inspection", "builder/inspection.py")
inspection.OWNER_UID = os.geteuid()
CHECKS = ("candidate-versions", "runtime-sources", "minimum-versions", "refused-packages", "apple-packages", "installed-boot-payloads",
          "candidate-files",
          "m1n1-stage2", "aurora-device-trees", "limine-uki", "embedded-initramfs", "boot-splash", "boot-maintenance",
          "image-target", "first-boot", "snapshots", "pacman-config", "installed-system", "factory")
# Fixture roots live on whatever filesystem the tests run on: these paths stand in for btrfs subvolumes.
SUBVOLUMES: set[Path] = set()
real_is_subvolume = inspection.is_subvolume
inspection.is_subvolume = lambda path: path in SUBVOLUMES


class InspectionTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.base = Path(cls.tmp.name)
        cls.signer = fixtures.Signer(cls.base / "signer")
        receipt = fixtures.make_set(cls.base / "set", cls.signer)
        cls.candidates = cls.base / "candidates"
        fixtures.import_set(cls.base / "set", cls.candidates, cls.signer, receipt)
        cls.good = cls.base / "root"
        fixtures.make_root(cls.good, cls.candidates)
        cls.summary = __import__("json").loads((cls.candidates / "import.json").read_text())

    @classmethod
    def tearDownClass(cls):
        cls.signer.close()
        for path in cls.base.rglob("*"):
            if path.is_dir() and not path.is_symlink():
                path.chmod(0o700)
        cls.tmp.cleanup()

    def setUp(self):
        work = Path(tempfile.mkdtemp(dir=self.base))
        self.root = work / "root"
        shutil.copytree(self.good, self.root, symlinks=True)
        self.factory = work / "factory"
        fixtures.make_factory(self.factory, self.root, self.summary)
        SUBVOLUMES.clear()
        SUBVOLUMES.add(self.root / ".snapshots")

    def inspect(self, candidates=None):
        return inspection.inspect(self.root, candidates or self.candidates, "edge", self.factory,
                                  trust=self.signer.trust)

    def test_inspection_rejects_changed_operator_policy(self):
        trust = self.root.parent / "changed-trust"
        shutil.copytree(self.signer.trust, trust)
        (trust / "policy.json").write_text((trust / "policy.json").read_text() + "\n")
        with self.assertRaisesRegex(inspection.InspectionError, "inspection candidate trust differs"):
            inspection.inspect(self.root, self.candidates, "edge", self.factory, trust=trust)

    def test_required_stock_packages_must_have_the_exact_version(self):
        package = {'repository': 'asahi-alarm', 'version': '20260318-1', 'sha256': 'a' * 64}
        policy = dict(fixtures.POLICY, required_stock_packages={'fex-emu-rootfs-arch': package})
        with self.assertRaisesRegex(inspection.InspectionError, 'required stock package'):
            inspection.check_stock_packages(self.root, policy, {})
        fixtures.local_package(self.root, 'fex-emu-rootfs-arch', '20260318-1', [])
        self.assertIn('1 operator-required stock', inspection.check_stock_packages(self.root, policy, {}))

    def sep_order_fixture(self, missing=None):
        source = fixtures.ROOT / 'firmware-ordering'
        files = {
            'usr/lib/modprobe.d/aurora-sep-firmware-order.conf': b'blacklist apple_sep\n',
            'usr/lib/omarchy/initcpio/aurora-peripheral-firmware.sh': (source / 'aurora-peripheral-firmware.sh').read_bytes(),
            'usr/lib/systemd/system/aurora-peripheral-firmware.service': (source / 'aurora-peripheral-firmware.service').read_bytes(),
            'usr/lib/modprobe.d/aurora-firmware-order.conf': (source / 'aurora-firmware-order.conf').read_bytes(),
            'usr/lib/omarchy/initcpio/aurora-vendor-order-cryptsetup.conf': (source / 'aurora-vendor-order-cryptsetup.conf').read_bytes(),
            'usr/lib/systemd/system/omarchy-vendor-firmware.service.d/20-aurora-vendor-order.conf': (source / '20-aurora-vendor-order.conf').read_bytes(),
            'usr/lib/systemd/system/aurora-sep.service.d/50-aurora-sep-vendor-firmware.conf': (source / '50-aurora-sep-vendor-firmware.conf').read_bytes(),
        }
        for path, content in files.items():
            fixtures.write(self.root, path, content)
        embedded = {name: b'#!/bin/sh\n' for name in inspection.limine.INITRD_FILES}
        embedded.update(inspection.limine.INITRD_LINKS)
        embedded.update({path: files[path] for path in (
            'usr/lib/modprobe.d/aurora-sep-firmware-order.conf',
            'usr/lib/omarchy/initcpio/aurora-peripheral-firmware.sh',
            'usr/lib/systemd/system/aurora-peripheral-firmware.service',
            'usr/lib/modprobe.d/aurora-firmware-order.conf')})
        embedded['usr/lib/systemd/system/systemd-cryptsetup@.service.d/aurora-vendor-order.conf'] = \
            files['usr/lib/omarchy/initcpio/aurora-vendor-order-cryptsetup.conf']
        for target in ('sysinit.target', 'initrd-root-device.target'):
            embedded[f'usr/lib/systemd/system/{target}.wants/aurora-peripheral-firmware.service'] = \
                '../aurora-peripheral-firmware.service'
        if missing:
            embedded.pop(missing)
        uki = self.root / 'boot/efi/EFI/Linux/omarchy_linux-aurora.efi'
        sections = inspection.limine.pe_sections(uki)
        sections['.initrd'] = fixtures.initramfs(embedded)
        uki.write_bytes(fixtures.pe_image(sections))
        return SimpleNamespace(packages={'aurora-sep': {}, 'omarchy-apple-firmware-order': {}},
                               member=lambda package, path: files[path])

    def test_neo_sep_firmware_order_matches_root_and_embedded_files_and_activation_graph(self):
        candidates = self.sep_order_fixture()
        self.assertIn('alias blacklist in root and UKI', inspection.check_sep_firmware_order(self.root, candidates, {}))

    def test_neo_sep_firmware_order_refuses_missing_initrd_files_or_activation_links(self):
        for missing in ('usr/lib/modprobe.d/aurora-sep-firmware-order.conf',
                        'usr/lib/omarchy/initcpio/aurora-peripheral-firmware.sh',
                        'usr/lib/systemd/system/sysinit.target.wants/aurora-peripheral-firmware.service',
                        'usr/lib/systemd/system/initrd-root-device.target.wants/aurora-peripheral-firmware.service'):
            with self.subTest(missing=missing):
                candidates = self.sep_order_fixture(missing)
                with self.assertRaisesRegex(inspection.InspectionError, 'UKI initramfs lacks'):
                    inspection.check_sep_firmware_order(self.root, candidates, {})

    def test_neo_sep_firmware_order_requires_normal_sep_package_and_vendor_dependency(self):
        candidates = self.sep_order_fixture()
        candidates.packages.pop('aurora-sep')
        with self.assertRaisesRegex(inspection.InspectionError, 'requires the signed SEP package'):
            inspection.check_sep_firmware_order(self.root, candidates, {})
        candidates.packages['aurora-sep'] = {}
        (self.root / 'usr/lib/systemd/system/aurora-sep.service.d/50-aurora-sep-vendor-firmware.conf').write_text('[Unit]\nAfter=local-fs.target\n')
        with self.assertRaisesRegex(inspection.InspectionError, 'ordinary vendor firmware'):
            inspection.check_sep_firmware_order(self.root, candidates, {})

    def test_direct_inspection_refuses_symlinked_trust_key(self):
        trust = self.root.parent / "symlinked-trust"
        shutil.copytree(self.signer.trust, trust)
        (trust / "public.asc").unlink()
        (trust / "public.asc").symlink_to(self.signer.trust / "public.asc")
        with self.assertRaises(OSError):
            inspection.inspect(self.root, self.candidates, "edge", self.factory, trust=trust)

    def assertFails(self, check, pattern, candidates=None):
        report = self.inspect(candidates)
        self.assertEqual(report["result"], "failed")
        self.assertEqual(report["checks"][check]["result"], "failed", report["checks"][check])
        self.assertRegex(report["checks"][check]["detail"], pattern)
        return report

    def stage2(self, m1n1=None, dtbs=None, uboot=None, tail=b""):
        m1n1 = m1n1 if m1n1 is not None else fixtures.default_contents()["m1n1-aurora"]["usr/lib/asahi-boot/m1n1.bin"]
        uboot = uboot if uboot is not None else fixtures.default_contents()["uboot-asahi"]["usr/lib/asahi-boot/u-boot-nodtb.bin"]
        if dtbs is None:
            dtbs = sorted(["s8000-n66", *fixtures.MODELS], key=str.encode)
        compressor = zlib.compressobj(wbits=31)
        data = m1n1 + b"".join(fixtures.dtb(name) for name in dtbs) + compressor.compress(uboot) + compressor.flush() + tail
        (self.root / "boot/efi/m1n1/boot.bin").write_bytes(data)

    def test_image_built_from_the_set_passes_inspection(self):
        report = self.inspect()
        self.assertEqual(sorted(report["checks"]), sorted(CHECKS))
        for check in CHECKS:
            self.assertEqual(report["checks"][check]["result"], "passed", (check, report["checks"][check]))
        self.assertEqual(report["result"], "passed")
        self.assertEqual(report["m1n1_stage2"]["device_trees"], 3)
        self.assertEqual(report["supported_models"], list(fixtures.MODELS))
        self.assertEqual(report["hardware_setup"], "build")

    def test_m1n1_stage2_mismatches(self):
        cases = {
            "another m1n1": dict(m1n1=b"some other m1n1 build"),
            "a missing device tree": dict(dtbs=["s8000-n66", "t6000-j314s"]),
            "device trees out of C order": dict(dtbs=["t6000-j314s", "s8000-n66", "t8103-j274"]),
            "an extra device tree": dict(dtbs=[*sorted(["s8000-n66", *fixtures.MODELS]), "t6020-j414s"]),
            "another U-Boot": dict(uboot=b"stock asahi u-boot"),
            "trailing bytes": dict(tail=b"\x00\x01binary"),
            "options the image does not set": dict(tail=b"chosen.bootargs=init=/bin/sh\n"),
            "junk before U-Boot": dict(uboot=b"", tail=b""),
        }
        for name, change in cases.items():
            with self.subTest(name):
                self.stage2(**change)
                self.assertFails("m1n1-stage2", "m1n1|device tree|U-Boot")

    def test_missing_stage2(self):
        (self.root / "boot/efi/m1n1/boot.bin").unlink()
        self.assertFails("m1n1-stage2", "not a regular file")

    def test_installed_payload_differs_from_the_set(self):
        (self.root / "usr/lib/asahi-boot/u-boot-nodtb.bin").write_bytes(b"patched")
        self.assertFails("installed-boot-payloads", "u-boot-nodtb.bin")

    def test_a_set_file_rewritten_during_the_build(self):
        for rel in ("usr/lib/omarchy/initcpio/omarchy-mac-encrypt", "usr/share/libalpm/scripts/limine-apple-gate",
                    "usr/share/omarchy/default/limine/limine.conf"):
            with self.subTest(rel):
                self.setUp()
                (self.root / rel).write_bytes(b"#!/bin/bash\nexit 0\n")
                self.assertFails("candidate-files", re.escape(rel))

    def test_a_set_file_with_another_mode(self):
        (self.root / "usr/lib/omarchy/initcpio/omarchy-mac-encrypt").chmod(0o644)
        self.assertFails("candidate-files", "omarchy-mac-encrypt.*mode")

    def test_a_set_link_retargeted_or_replaced(self):
        cases = (("retargeted", lambda link: (link.unlink(), link.symlink_to("elsewhere"))),
                 ("replaced by a directory", lambda link: (link.unlink(), link.mkdir())))
        for name, change in cases:
            with self.subTest(name):
                self.setUp()
                change(self.root / f"usr/lib/modules/{fixtures.RELEASE}/source")
                self.assertFails("candidate-files", "source.*link")

    def test_m1n1_options_as_update_m1n1_reads_them(self):
        (self.root / "etc/m1n1.conf").write_text("chosen.asahi,efi-system-partition=EFI\ndisplay=1920x1080")
        self.assertEqual(self.inspect()["checks"]["m1n1-stage2"]["result"], "passed")

    def test_a_set_file_missing(self):
        (self.root / "usr/share/omarchy-mac/source-revision").unlink()
        self.assertFails("candidate-files", "source-revision")

    def test_limine_loader_is_not_its_packages(self):
        loader = fixtures.pe_image({".text": b"Another loader"})
        for rel in ("usr/share/limine/BOOTAA64.EFI", "boot/efi/EFI/BOOT/BOOTAA64.EFI"):
            (self.root / rel).write_bytes(loader)
        self.assertFails("boot-maintenance", "Limine loader")

    def test_mac_without_an_aurora_device_tree(self):
        contents = fixtures.default_contents()
        contents["uboot-asahi"]["usr/lib/asahi-boot/dtb/t6020-j414s.dtb"] = b"uboot t6020"
        work = Path(tempfile.mkdtemp(dir=self.base))
        receipt = fixtures.make_set(work / "set", self.signer, contents=contents)
        fixtures.import_set(work / "set", work / "candidates", self.signer, receipt)
        self.assertFails("aurora-device-trees", "t6020-j414s", work / "candidates")

    def test_limine_loader_menu_and_uki(self):
        esp = type("Esp", (), {"__truediv__": lambda _, rel: self.root / "boot/efi" / rel})()
        cases = {
            "loader": (lambda: (esp / "EFI/BOOT/BOOTAA64.EFI").write_bytes(fixtures.pe_image({".text": b"GRUB"})),
                       "ESP loader"),
            "menu": (lambda: (esp / "limine.conf").write_text("interface_branding: Omarchy Bootloader\n"),
                     "menu does not boot"),
            "hash": (lambda: (esp / "limine.conf").write_text(re.sub(r"#[0-9a-f]{128}", "#" + "0" * 128,
                                                                         (esp / "limine.conf").read_text())),
                     "hash differs"),
            "kernel": (lambda: (self.root / f"usr/lib/modules/{fixtures.RELEASE}/vmlinuz").write_bytes(b"MZ other"),
                       "release differs"),
            "identity": (lambda: (esp / "limine.conf").write_text(
                (esp / "limine.conf").read_text() + "comment: machine-id=" + "1" * 32 + "\n"), "machine identity"),
        }
        for name, (change, pattern) in cases.items():
            with self.subTest(name):
                self.setUp()
                change()
                self.assertFails("limine-uki", pattern)

    def test_embedded_initramfs_without_the_boot_packages_hooks(self):
        limine = inspection.limine
        members = {name: b"x" for name in limine.INITRD_FILES if "omarchy-mac-encrypt" not in name}
        members.update(limine.INITRD_LINKS)
        uki = self.root / "boot/efi/EFI/Linux/omarchy_linux-aurora.efi"
        sections = limine.pe_sections(uki)
        sections[".initrd"] = fixtures.initramfs(members)
        data = fixtures.pe_image(sections)
        uki.write_bytes(data)
        menu = self.root / "boot/efi/limine.conf"
        menu.write_text(menu.read_text().split("#")[0] + "#" + hashlib.blake2b(data).hexdigest() + "\n")
        self.assertFails("embedded-initramfs", "omarchy-mac-encrypt")

    def replace_uki(self, initrd=None, cmdline=None):
        """Rebuilds the UKI with another initramfs or command line, keeping the menu's hash and
        /etc/default/limine in step so only the splash is wrong."""
        limine = inspection.limine
        uki = self.root / "boot/efi/EFI/Linux/omarchy_linux-aurora.efi"
        sections = limine.pe_sections(uki)
        if initrd is not None:
            sections[".initrd"] = initrd
        if cmdline is not None:
            sections[".cmdline"] = cmdline.encode() + b" \n\0"
            fixtures.write(self.root, "etc/default/limine", f'KERNEL_CMDLINE[default]="{cmdline}"\n')
        data = fixtures.pe_image(sections)
        uki.write_bytes(data)
        menu = self.root / "boot/efi/limine.conf"
        menu.write_text(menu.read_text().split("#")[0] + "#" + hashlib.blake2b(data).hexdigest() + "\n")

    def test_boot_splash(self):
        bgrt = b"# Administrator customizations go in this file\n[Daemon]\nTheme=bgrt\n"
        cmdline = self.inspect()["uki"]["cmdline"]
        cases = (
            ("the image's own theme", lambda: fixtures.write(self.root, "etc/plymouth/plymouthd.conf", bgrt),
             "image's Plymouth theme is bgrt"),
            ("no theme chosen, so the packaged bgrt",
             lambda: fixtures.write(self.root, "etc/plymouth/plymouthd.conf",
                                    b"# Administrator customizations go in this file\n#[Daemon]\n#Theme=fade-in\n"),
             "image's Plymouth theme is bgrt"),
            ("the initramfs's theme", lambda: self.replace_uki(
                initrd=fixtures.good_initramfs(fixtures.plymouth_members(config=bgrt))), "initramfs shows the bgrt"),
            ("an initramfs without the configuration", lambda: self.replace_uki(
                initrd=fixtures.good_initramfs(fixtures.plymouth_members(config=None))), "initramfs shows the bgrt"),
            ("an initramfs without Plymouth", lambda: self.replace_uki(initrd=fixtures.good_initramfs({})),
             "initramfs shows the unset"),
            ("an initramfs without the theme", lambda: self.replace_uki(
                initrd=fixtures.good_initramfs(fixtures.plymouth_members(theme=False))), "initramfs lacks"),
            ("a boot line that lets Plymouth fall back to text",
             lambda: self.replace_uki(cmdline=cmdline.replace(" plymouth.ignore-serial-consoles", "")),
             "lacks plymouth.ignore-serial-consoles"),
            ("a boot line without the splash", lambda: self.replace_uki(cmdline=cmdline.replace(" splash", "")),
             "lacks splash"),
        )
        for name, change, pattern in cases:
            with self.subTest(name):
                self.setUp()
                change()
                report = self.assertFails("boot-splash", pattern)
                self.assertEqual(report["failed_checks"], ["boot-splash"])

    def test_snapshots(self):
        snapshots = lambda: self.root / ".snapshots"
        cases = (
            ("flattened by the image copy", lambda: SUBVOLUMES.clear(), "plain directory"),
            ("carrying the build's snapshots", lambda: (snapshots() / "1/snapshot").mkdir(parents=True),
             "taken during the build"),
            ("without snapper's configuration", lambda: (self.root / "etc/snapper/configs/root").unlink(),
             "no snapper root configuration"),
            ("a file", lambda: (snapshots().rmdir(), snapshots().write_text("")), "not a directory"),
            ("missing, with nothing to create it", lambda: snapshots().rmdir(), "no deferred hardware step"),
        )
        for name, change, pattern in cases:
            with self.subTest(name):
                self.setUp()
                change()
                self.assertFails("snapshots", pattern)

    def test_snapshots_created_on_first_boot(self):
        (self.root / ".snapshots").rmdir()
        fixtures.write(self.root, "var/lib/omarchy/image/deferred-steps", "install/hardware/apple/snapshots-subvolume.sh\n")
        fixtures.write(self.root, "usr/bin/omarchy-provision-hardware", "#!/bin/bash\n", 0o755)
        (self.root / "etc/systemd/system/multi-user.target.wants/omarchy-provision-hardware.service").symlink_to(
            "/etc/systemd/system/omarchy-provision-hardware.service")
        report = self.inspect()
        self.assertEqual(report["checks"]["snapshots"]["result"], "passed", report["checks"]["snapshots"])
        self.assertIn("snapshots-subvolume.sh", report["checks"]["snapshots"]["detail"])

    def test_a_plain_directory_is_not_a_subvolume(self):
        self.assertFalse(real_is_subvolume(self.root / ".snapshots"))
        self.assertFalse(real_is_subvolume(self.root / "etc"))

    def test_audio_stack_missing(self):
        for name in ("alsa-ucm-conf-asahi", "asahi-audio"):
            with self.subTest(name):
                self.setUp()
                shutil.rmtree(next((self.root / "var/lib/pacman/local").glob(f"{name}-1.0-1")))
                report = self.assertFails("installed-system", "packages-required-present")
                self.assertIn(name, report["installed_system"]["packages-required-present"]["detail"])

    def test_first_boot_packages_missing(self):
        for name in ("vulkan-asahi", "asahi-bless"):
            with self.subTest(name):
                self.setUp()
                shutil.rmtree(next((self.root / "var/lib/pacman/local").glob(f"{name}-1.0-1")))
                report = self.assertFails("installed-system", "packages-required-present")
                self.assertIn(name, report["installed_system"]["packages-required-present"]["detail"])

    def test_bluetooth_enabled_by_a_deferred_hardware_step(self):
        (self.root / "etc/systemd/system/dbus-org.bluez.service").unlink()
        report = self.assertFails("installed-system", "unit-enabled-bluetooth")
        queue = self.root / "var/lib/omarchy/image/deferred-steps"
        queue.write_text("install/hardware/apple/audio.sh\ninstall/hardware/bluetooth.sh\n")
        report = self.inspect()
        self.assertEqual(report["checks"]["installed-system"]["result"], "passed", report["checks"]["installed-system"])
        self.assertIn("deferred install/hardware/bluetooth.sh",
                      report["installed_system"]["unit-enabled-bluetooth"]["detail"])

    def test_apple_package_list_by_either_name(self):
        install = self.root / "usr/share/omarchy/install"
        report = self.inspect()
        self.assertEqual(report["checks"]["apple-packages"]["result"], "passed", report["checks"]["apple-packages"])
        self.assertEqual(report["apple_package_list"], "omarchy-apple-silicon.packages")
        # omarchy-mac's compatibility link beside upstream's name.
        (install / "omarchy-apple.packages").symlink_to("omarchy-apple-silicon.packages")
        self.assertEqual(self.inspect()["apple_package_list"], "omarchy-apple-silicon.packages")
        # An older runtime's name alone.
        (install / "omarchy-apple.packages").unlink()
        (install / "omarchy-apple-silicon.packages").rename(install / "omarchy-apple.packages")
        report = self.inspect()
        self.assertEqual(report["checks"]["apple-packages"]["result"], "passed", report["checks"]["apple-packages"])
        self.assertEqual(report["apple_package_list"], "omarchy-apple.packages")
        self.assertIn("omarchy-apple.packages", report["checks"]["apple-packages"]["detail"])

    def test_apple_package_list_prefers_upstreams_name(self):
        install = self.root / "usr/share/omarchy/install"
        (install / "omarchy-apple.packages").write_text("omarchy-mac\nnot-installed\n")
        report = self.inspect()
        self.assertEqual(report["checks"]["apple-packages"]["result"], "passed", report["checks"]["apple-packages"])
        (install / "omarchy-apple-silicon.packages").write_text("# Apple\nomarchy-mac\n  # indented\nwf-recorder\n")
        self.assertFails("apple-packages", "omarchy-apple-silicon.packages names packages that are not installed: wf-recorder$")

    def test_apple_package_list_missing(self):
        install = self.root / "usr/share/omarchy/install"
        (install / "omarchy-apple-silicon.packages").unlink()
        self.assertFails("apple-packages", "the image ships no Apple package list")
        (install / "omarchy-apple.packages").symlink_to("omarchy-apple-silicon.packages")
        self.assertFails("apple-packages", "the image ships no Apple package list")
        (install / "omarchy-apple.packages").unlink()
        (install / "omarchy-apple-silicon.packages").write_text("# Apple\n\n")
        self.assertFails("apple-packages", "omarchy-apple-silicon.packages names no package")

    def test_installed_version_below_the_minimum(self):
        local = self.root / "var/lib/pacman/local"
        entry = next(local.glob("limine-mkinitcpio-hook-*"))
        (entry / "desc").write_text("%NAME%\nlimine-mkinitcpio-hook\n\n%VERSION%\n1.38.0-1.1\n\n")
        report = self.assertFails("minimum-versions", "below the minimum")
        self.assertEqual(report["checks"]["candidate-versions"]["result"], "failed")

    def test_runtime_sources_are_the_installed_revisions(self):
        report = self.inspect()
        self.assertEqual(report["runtime_sources"], {name: fixtures.SOURCE for name in
                                                     ("omarchy", "omarchy-mac", "omarchy-mac-boot", "omarchy-settings")})
        (self.root / "usr/share/omarchy-mac/source-revision").write_text("d" * 40 + "\n")
        self.assertFails("runtime-sources", "does not name")

    def test_refused_package_installed(self):
        fixtures.local_package(self.root, "linux-asahi", "6.16-1", [])
        self.assertFails("refused-packages", "linux-asahi")

    def test_grub_installed(self):
        fixtures.local_package(self.root, "grub", "2:2.16-1", [])
        self.assertFails("refused-packages", "grub")

    def test_maintenance_hook_without_the_apple_gate(self):
        hook = self.root / "etc/pacman.d/hooks/90-mkinitcpio-install.hook"
        hook.write_text("[Action]\nExec = /usr/share/libalpm/scripts/limine-mkinitcpio-install\n")
        self.assertFails("boot-maintenance", "incomplete")

    def test_image_target_manifest(self):
        good = fixtures.image_target(self.summary)
        for name, change, pattern in (
            ("missing", lambda p: p.unlink(), "missing"),
            ("another platform", lambda p: p.write_text(good.replace("apple-silicon", "qualcomm")), "apple-silicon"),
            ("writable", lambda p: p.chmod(0o666), "mode"),
            ("an older image's two lines", lambda p: p.write_text("format=1\nplatform=apple-silicon\n"),
             "does not record candidate_set, candidate_source_commit, builder_commit, builder_tree_clean, image_profile$"),
            ("a package set digest without a build time", lambda p: p.write_text(good.replace(f"built={fixtures.BUILT}\n", "")),
             "does not record built$"),
            ("a build time without a package set digest", lambda p: p.write_text(
                good.replace(f"package_set_sha256={fixtures.PACKAGE_SET_SHA256}\n", "")),
             "does not record package_set_sha256$"),
            ("a short package set digest", lambda p: p.write_text(
                good.replace(fixtures.PACKAGE_SET_SHA256, fixtures.PACKAGE_SET_SHA256[:12])), "package set digest"),
            ("an uppercase package set digest", lambda p: p.write_text(
                good.replace(fixtures.PACKAGE_SET_SHA256, "A" * 64)), "package set digest"),
            ("a local build time", lambda p: p.write_text(
                good.replace(fixtures.BUILT, "2026-09-28T13:04:05+10:00")), "UTC build time"),
            ("a build time without seconds", lambda p: p.write_text(
                good.replace(fixtures.BUILT, "2026-09-28T03:04Z")), "UTC build time"),
            ("an impossible build time", lambda p: p.write_text(
                good.replace(fixtures.BUILT, "2026-13-40T25:04:05Z")), "UTC build time"),
            ("a build time with a carriage return", lambda p: p.write_text(
                good.replace(fixtures.BUILT, fixtures.BUILT + "\r")), "UTC build time"),
            ("an empty build time", lambda p: p.write_text(good.replace(fixtures.BUILT, "")), "UTC build time"),
            ("a candidate set name with a space", lambda p: p.write_text(
                good.replace(f"candidate_set={self.summary['set']}", f"candidate_set={self.summary['set']} x")),
             "another candidate set"),
            ("another set", lambda p: p.write_text(good.replace(self.summary["set"], "apple-test-other")),
             "another candidate set"),
            ("another source commit", lambda p: p.write_text(
                good.replace(self.summary["source_commit"], "b" * 40)), "another candidate set"),
            ("no builder commit", lambda p: p.write_text(good.replace("c" * 40, "unknown")), "builder commit"),
            ("an unknown tree state", lambda p: p.write_text(good.replace("clean=true", "clean=yes")), "clean"),
            ("the lab profile", lambda p: p.write_text(good.replace("=test", "=lab")), "test profile"),
            ("a field twice", lambda p: p.write_text(good + "image_profile=test\n"), "twice"),
            ("a line without a value", lambda p: p.write_text(good + "stray\n"), "malformed"),
        ):
            with self.subTest(name):
                self.setUp()
                change(self.root / "var/lib/omarchy/image/target")
                self.assertFails("image-target", pattern)

    def test_image_target_records_the_images_provenance(self):
        report = self.inspect()
        self.assertEqual(report["checks"]["image-target"]["result"], "passed")
        self.assertEqual(report["image_target"], {
            "candidate_set": self.summary["set"], "candidate_source_commit": self.summary["source_commit"],
            "builder_commit": "c" * 40, "builder_tree_clean": "true", "image_profile": "test",
            "package_set_sha256": fixtures.PACKAGE_SET_SHA256, "built": fixtures.BUILT})
        self.assertIn(f"package set {fixtures.PACKAGE_SET_SHA256[:12]}, built {fixtures.BUILT}",
                      report["checks"]["image-target"]["detail"])

    def test_an_image_built_before_the_build_identity_passes(self):
        legacy = fixtures.image_target(self.summary).split("package_set_sha256=")[0]
        for tree in (self.root, self.factory):
            (tree / "var/lib/omarchy/image/target").write_text(legacy)
        report = self.inspect()
        self.assertEqual(report["checks"]["image-target"]["result"], "passed", report["checks"]["image-target"])
        self.assertEqual(report["checks"]["factory"]["result"], "passed", report["checks"]["factory"])
        self.assertIn("built before images recorded their build identity", report["checks"]["image-target"]["detail"])
        self.assertNotIn("package_set_sha256", report["image_target"])
        self.assertNotIn("built", report["image_target"])

    def test_image_target_keeps_the_runtimes_reading_rules(self):
        target = self.root / "var/lib/omarchy/image/target"
        target.write_text("# comment\n" + target.read_text() + "later_key=ignored\n")
        (self.factory / "var/lib/omarchy/image/target").write_bytes(target.read_bytes())
        self.assertEqual(self.inspect()["checks"]["image-target"]["result"], "passed")

    def test_image_target_profile_follows_the_build(self):
        target = self.root / "var/lib/omarchy/image/target"
        target.write_text(target.read_text().replace("=test", "=lab"))
        (self.factory / "var/lib/omarchy/image/target").write_bytes(target.read_bytes())
        report = inspection.inspect(self.root, self.candidates, "edge", self.factory, trust=self.signer.trust,
                                    profile="lab")
        self.assertEqual(report["checks"]["image-target"]["result"], "passed", report["checks"]["image-target"])
        release = dict(self.summary, candidate_only=False)
        self.assertEqual(inspection.image_profile("release", type("C", (), {"summary": release})()), "release")

    def test_factory(self):
        for name, change in (
            ("fresh-image state", lambda f: fixtures.write(f, "var/lib/omarchy/mac-first-boot/pending", b"")),
            ("owner state", lambda f: fixtures.write(f, "var/lib/omarchy/provisioning/pending", b"")),
            ("another set", lambda f: fixtures.write(f, "var/lib/omarchy/factory-sealed", "format=2\ncandidate_set=x\n")),
            ("no image target", lambda f: (f / "var/lib/omarchy/image/target").unlink()),
            ("another image target", lambda f: fixtures.write(f, "var/lib/omarchy/image/target",
                                                              fixtures.image_target(self.summary, "lab"))),
            ("another build's identity", lambda f: fixtures.write(f, "var/lib/omarchy/image/target",
                fixtures.image_target(self.summary).replace(fixtures.BUILT, "2026-09-29T00:00:00Z"))),
            ("no build identity", lambda f: fixtures.write(f, "var/lib/omarchy/image/target",
                fixtures.image_target(self.summary).split("package_set_sha256=")[0])),
            ("a keyring", lambda f: (f / "etc/pacman.d/gnupg").mkdir(parents=True)),
        ):
            with self.subTest(name):
                self.setUp()
                change(self.factory)
                self.assertFails("factory", "@factory")

    def test_first_boot_contract(self):
        for rel, change, pattern in (
            ("var/lib/omarchy/mac-first-boot/deferred-steps", lambda p: p.write_text("install/hardware/all.sh\n"),
             "contract"),
            ("var/lib/omarchy/mac-first-boot/pending", lambda p: p.unlink(), "first boot"),
            ("var/lib/omarchy/limine.enabled", lambda p: p.unlink(), "Limine gate"),
            ("var/lib/omarchy/image/deferred-steps", lambda p: p.write_text("install/hardware/apple/audio.sh\n"),
             "never runs"),
        ):
            with self.subTest(rel):
                self.setUp()
                change(self.root / rel)
                self.assertFails("first-boot", pattern)

    def test_first_boot_never_adds_the_unsigned_repository(self):
        fixtures.write(self.root, "var/lib/omarchy/image/deferred-steps",
                       "install/hardware/vulkan.sh\ninstall/hardware/apple/pacman.sh\ninstall/hardware/apple/audio.sh\n")
        fixtures.write(self.root, "usr/bin/omarchy-provision-hardware", "#!/bin/bash\n", 0o755)
        (self.root / "etc/systemd/system/multi-user.target.wants/omarchy-provision-hardware.service").symlink_to(
            "/etc/systemd/system/omarchy-provision-hardware.service")
        self.assertFails("first-boot", "unsigned \\[omarchy-aarch64\\]")
        fixtures.write(self.root, "var/lib/omarchy/image/deferred-steps",
                       "install/hardware/vulkan.sh\ninstall/hardware/apple/audio.sh\n")
        report = self.inspect()
        self.assertEqual(report["checks"]["first-boot"]["result"], "passed", report["checks"]["first-boot"])

    def test_installed_pacman_config_trusts_no_unsigned_repository(self):
        conf = self.root / "etc/pacman.conf"
        good = conf.read_text()
        for name, extra, check in (
                ("fork repository", "\n[omarchy-aarch64]\nServer = https://github.com/omarchy-mac/"
                 "omarchy-pkgs-aarch64/releases/download/edge\n", "pacman-no-fork-or-build-repositories"),
                ("TrustAll", "\n[extra-trust]\nSigLevel = Optional TrustAll\nServer = https://example.invalid\n",
                 "pacman-no-trust-all")):
            with self.subTest(name):
                conf.write_text(good + extra)
                report = self.assertFails("installed-system", check)
                self.assertEqual(report["installed_system"][check]["result"], "failed")
        conf.write_text(good + "\n# SigLevel = Optional TrustAll\n")
        report = self.inspect()
        self.assertEqual(report["installed_system"]["pacman-no-trust-all"]["result"], "passed",
                         report["installed_system"]["pacman-no-trust-all"])

    def test_pacman_config_is_the_runtimes(self):
        (self.root / "etc/pacman.conf").write_text("[omarchy-candidates]\nServer = file:///work/repos\n")
        self.assertFails("pacman-config", "pacman.conf")

    def test_pacman_config_follows_the_runtimes_apple_silicon_template(self):
        templates = self.root / "usr/share/omarchy/default/pacman"
        apple = "[options]\nArchitecture = auto\n\n[omarchy]\nServer = https://pkgs.omarchy.org/edge/$arch\n"
        apple += "\n[asahi-alarm]\nServer = https://github.com/asahi-alarm/asahi-alarm/releases/download/aarch64\n"
        apple += "".join(f"\n[{r}]\nInclude = /etc/pacman.d/mirrorlist\n" for r in ("core", "extra", "alarm", "aur"))
        (templates / "apple-silicon").mkdir()
        (templates / "apple-silicon/pacman-edge.conf").write_text(apple)
        self.assertFails("pacman-config", "apple-silicon edge configuration")
        pinned = fixtures.test_image_pin.pinned(self.summary)
        (self.root / "etc/pacman.conf").write_bytes(fixtures.test_image_pin.render(apple.encode(), pinned))
        report = self.inspect()
        self.assertEqual(report["checks"]["pacman-config"]["result"], "passed", report["checks"]["pacman-config"])
        self.assertIn("apple-silicon edge pacman.conf", report["checks"]["pacman-config"]["detail"])

    def test_pacman_config_prefers_omarchy_macs_template(self):
        runtime = self.root / "usr/share/omarchy/default/pacman"
        apple = "[options]\nArchitecture = auto\n\n[omarchy]\nServer = https://pkgs.omarchy.org/edge/$arch\n"
        apple += "\n[asahi-alarm]\nServer = https://github.com/asahi-alarm/asahi-alarm/releases/download/aarch64\n"
        apple += "".join(f"\n[{r}]\nInclude = /etc/pacman.d/mirrorlist\n" for r in ("core", "extra", "alarm", "aur"))
        (runtime / "apple-silicon").mkdir()
        (runtime / "apple-silicon/pacman-edge.conf").write_text(apple)
        package = self.root / "usr/share/omarchy-mac/pacman"
        package.mkdir(parents=True)
        (package / "pacman-edge.conf").write_text(apple + "\n# omarchy-mac\n")
        pinned = fixtures.test_image_pin.pinned(self.summary)
        (self.root / "etc/pacman.conf").write_bytes(fixtures.test_image_pin.render(apple.encode(), pinned))
        self.assertFails("pacman-config", "omarchy-mac's apple-silicon edge configuration")
        (self.root / "etc/pacman.conf").write_bytes(fixtures.test_image_pin.render((apple + "\n# omarchy-mac\n").encode(), pinned))
        report = self.inspect()
        self.assertEqual(report["checks"]["pacman-config"]["result"], "passed", report["checks"]["pacman-config"])
        self.assertIn("omarchy-mac's apple-silicon edge pacman.conf", report["checks"]["pacman-config"]["detail"])

    def test_pacman_config_needs_a_template(self):
        (self.root / "usr/share/omarchy/default/pacman/aarch64/pacman-edge.conf").unlink()
        self.assertFails("pacman-config", "the image ships no Apple Silicon pacman configuration for edge")

    def test_pacman_config_takes_a_single_aarch64_mirror_list(self):
        runtime = self.root / "usr/share/omarchy/default/pacman"
        mirrors = (runtime / "aarch64/mirrorlist-edge").read_text()
        (runtime / "aarch64/mirrorlist-edge").unlink()
        (runtime / "mirrorlist-aarch64").write_text(mirrors + "# one list for every channel\n")
        self.assertFails("pacman-config", "aarch64 edge mirror list")
        (self.root / "etc/pacman.d/mirrorlist").write_text(mirrors + "# one list for every channel\n")
        report = self.inspect()
        self.assertEqual(report["checks"]["pacman-config"]["result"], "passed", report["checks"]["pacman-config"])
        # With both layouts, the channel's own list wins, as build-mac-image writes it.
        (runtime / "aarch64/mirrorlist-edge").write_text(mirrors)
        self.assertFails("pacman-config", "aarch64 edge mirror list")
        (self.root / "etc/pacman.d/mirrorlist").write_text(mirrors)
        report = self.inspect()
        self.assertEqual(report["checks"]["pacman-config"]["result"], "passed", report["checks"]["pacman-config"])

    def test_test_image_keeps_the_sets_runtime(self):
        conf = (self.root / "etc/pacman.conf").read_text()
        self.assertIn("[options]\n" + fixtures.test_image_pin.MARK + "\n", conf)
        self.assertIn("\nIgnorePkg = omarchy omarchy-mac omarchy-mac-boot omarchy-settings\n", conf)
        self.assertRegex(self.inspect()["checks"]["pacman-config"]["detail"], "IgnorePkg = omarchy ")
        template = self.root / "usr/share/omarchy/default/pacman/aarch64/pacman-edge.conf"
        for name, text in (("unpinned", template.read_text()),
                           ("another pin", conf.replace("IgnorePkg = omarchy ", "IgnorePkg = "))):
            with self.subTest(name):
                (self.root / "etc/pacman.conf").write_text(text)
                self.assertFails("pacman-config", "with the test image's pin")


class ClosureInspectionTest(unittest.TestCase):
    """A set that carries the Apple default set's closure from a channel."""

    def test_sep_and_firmware_ordering_closure_files_remain_immutable(self):
        with tempfile.TemporaryDirectory() as scratch:
            base = Path(scratch)
            signer = fixtures.Signer(base / 'signer')
            try:
                contents = fixtures.default_contents()
                names = ('aurora-sep', 'omarchy-apple-firmware-order')
                for name in names:
                    contents[name] = {f'usr/lib/{name}/guard': b'public package-owned guard\n'}
                receipt = fixtures.make_set(base / 'set', signer, versions={name: '1-1' for name in names},
                                            contents=contents, names=[*fixtures.VERSIONS, *names])
                fixtures.import_set(base / 'set', base / 'candidates', signer, receipt)
                root = base / 'root'
                fixtures.make_root(root, base / 'candidates')
                candidates = inspection.Candidates(base / 'candidates')
                inspection.check_candidate_files(root, candidates, {})
                for name in names:
                    with self.subTest(name=name):
                        guard = root / f'usr/lib/{name}/guard'
                        guard.write_bytes(b'changed after install\n')
                        with self.assertRaisesRegex(inspection.InspectionError, 'files differ from the set'):
                            inspection.check_candidate_files(root, candidates, {})
                        guard.write_bytes(contents[name][f'usr/lib/{name}/guard'])
            finally:
                signer.close()
                for path in base.rglob('*'):
                    if path.is_dir() and not path.is_symlink():
                        path.chmod(0o700)

    def test_runtime_may_change_a_closure_packages_files(self):
        with tempfile.TemporaryDirectory() as scratch:
            base = Path(scratch)
            signer = fixtures.Signer(base / "signer")
            try:
                contents = fixtures.default_contents()
                contents["yaru-icon-theme"] = {"usr/share/icons/Yaru/scalable/actions/go-next-symbolic.svg": b"<svg/>"}
                receipt = fixtures.make_set(base / "set", signer, versions={"yaru-icon-theme": "26.04-1"},
                                            contents=contents, names=[*fixtures.VERSIONS, "yaru-icon-theme"])
                candidates = base / "candidates"
                fixtures.import_set(base / "set", candidates, signer, receipt)
                root = base / "root"
                fixtures.make_root(root, candidates)
                (root / ".snapshots").chmod(0o750)
                SUBVOLUMES.clear()
                SUBVOLUMES.add(root / ".snapshots")
                (root / "usr/share/icons/Yaru/scalable/actions/go-next-symbolic.svg").write_bytes(b"<svg restyled/>")
                report = inspection.inspect(root, candidates, "edge", trust=signer.trust)
                self.assertEqual(report["checks"]["candidate-files"]["result"], "passed", report["checks"]["candidate-files"])
                self.assertEqual(report["checks"]["candidate-versions"]["result"], "passed")
                self.assertIn("of the 9 runtime and boot packages", report["checks"]["candidate-files"]["detail"])
                (root / "usr/share/icons/Yaru/scalable/actions/go-next-symbolic.svg").unlink()
                local = next((root / "var/lib/pacman/local").glob("yaru-icon-theme-*"))
                (local / "desc").write_text((local / "desc").read_text().replace("26.04-1", "26.04-2"))
                report = inspection.inspect(root, candidates, "edge", trust=signer.trust)
                self.assertEqual(report["checks"]["candidate-versions"]["result"], "failed")
            finally:
                signer.close()
                for path in base.rglob("*"):
                    if path.is_dir() and not path.is_symlink():
                        path.chmod(0o700)


class TestImagePinTest(unittest.TestCase):
    TEMPLATE = b"# pacman\n\n[options]\nArchitecture = auto\n\n[core]\nInclude = /etc/pacman.d/mirrorlist\n"

    def summary(self, candidate_only=True):
        return {"candidate_only": candidate_only, "packages": [
            {"name": "omarchy", "origin": "commit"}, {"name": "omarchy-settings", "origin": "commit"},
            {"name": "omarchy-mac", "origin": "commit"}, {"name": "omarchy-mac-boot", "origin": "channel " + "b" * 40},
            {"name": "linux-aurora", "origin": "channel"}, {"name": "uboot-asahi", "origin": "pull-request"},
            {"name": "hyprland", "origin": "channel"}]}

    def test_pins_only_what_the_source_commit_built(self):
        pin = fixtures.test_image_pin
        names = pin.pinned(self.summary())
        self.assertEqual(names, ["omarchy", "omarchy-mac", "omarchy-settings"])
        rendered = pin.render(self.TEMPLATE, names).decode()
        self.assertEqual(rendered, "# pacman\n\n[options]\n" + pin.MARK + "\n" + pin.REASON
                         + "\nIgnorePkg = omarchy omarchy-mac omarchy-settings\nArchitecture = auto\n\n[core]\n"
                         "Include = /etc/pacman.d/mirrorlist\n")

    def test_no_pin_outside_a_test_set(self):
        pin = fixtures.test_image_pin
        self.assertEqual(pin.pinned(self.summary(candidate_only=False)), [])
        self.assertEqual(pin.render(self.TEMPLATE, []), self.TEMPLATE)

    def test_template_needs_one_options_section(self):
        with self.assertRaisesRegex(ValueError, "options"):
            fixtures.test_image_pin.render(b"[core]\n", ["omarchy"])

    def test_apple_adds_public_asahi_without_changing_signature_policy(self):
        pin = fixtures.test_image_pin
        template = self.TEMPLATE.replace(b"Architecture = auto", b"Architecture = auto\nSigLevel = Required DatabaseOptional")
        result = pin.render(template, [], ensure_asahi=True)
        self.assertTrue(result.startswith(template))
        self.assertEqual(result.count(b"[asahi-alarm]"), 1)
        self.assertIn(("Server = " + pin.ASAHI_ALARM_SERVER).encode(), result)
        self.assertNotIn(b"TrustAll", result)
        self.assertNotIn(b"file://", result)
        self.assertEqual(pin.render(result, [], ensure_asahi=True), result)

    def test_apple_preserves_existing_asahi_repository_bytes(self):
        template = self.TEMPLATE + b"\n[asahi-alarm]\nServer = https://github.com/asahi-alarm/asahi-alarm/releases/download/aarch64\n"
        self.assertEqual(fixtures.test_image_pin.render(template, [], ensure_asahi=True), template)

    def test_apple_refuses_duplicate_asahi_sections(self):
        with self.assertRaisesRegex(ValueError, "repeats"):
            fixtures.test_image_pin.render(self.TEMPLATE + b"[asahi-alarm]\n[asahi-alarm]\n", [], ensure_asahi=True)


class NeoStage1InspectionTest(unittest.TestCase):
    def test_common_stage1_exact_bytes_and_unfilled_role(self):
        import struct
        from types import SimpleNamespace
        c = inspection.candidate_set
        bare = b"bare Aura" + c.STAGE1_MAGIC + c.STAGE1_BODY.pack(1, 0, b"", b"") + struct.pack("<I", 0) + b"STACKBOT"
        candidate = SimpleNamespace(member=lambda package, path: bare)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            installed = root / c.STAGE1_PATH
            staged = root / "boot/efi/aurora/stage1.bin"
            for path in (installed, staged):
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(bare)
            report = {}
            inspection.check_common_stage1(root, candidate, report)
            self.assertEqual(report["common_stage1"]["sha256"], hashlib.sha256(bare).hexdigest())
            staged.write_bytes(bare + b"patched")
            with self.assertRaisesRegex(inspection.InspectionError, "ESP common Stage1"):
                inspection.check_common_stage1(root, candidate, {})
            staged.unlink()
            staged.symlink_to(installed)
            with self.assertRaises(inspection.limine.ContractError):
                inspection.check_common_stage1(root, candidate, {})


if __name__ == "__main__":
    unittest.main()
