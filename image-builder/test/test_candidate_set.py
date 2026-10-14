#!/usr/bin/env python3
"""The candidate importer accepts exactly a set its pinned key signed, and nothing else."""
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fixtures  # noqa: E402

c = fixtures.candidate_set


class CandidateSetTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.base = Path(cls.tmp.name)
        cls.signer = fixtures.Signer(cls.base / "signer")
        cls.stranger = fixtures.Signer(cls.base / "stranger", uid="Stranger <stranger@example.invalid>")
        cls.good = cls.base / "good"
        cls.receipt = fixtures.make_set(cls.good, cls.signer)

    @classmethod
    def tearDownClass(cls):
        cls.signer.close()
        cls.stranger.close()
        for path in cls.base.rglob("*"):
            if path.is_dir() and not path.is_symlink():
                path.chmod(0o700)
        cls.tmp.cleanup()

    def setUp(self):
        self.work = Path(tempfile.mkdtemp(dir=self.base))
        self.input = self.work / "input"
        shutil.copytree(self.good, self.input)

    def verify(self, directory=None, receipt=None, source=fixtures.SOURCE, trust=None, manifest=None):
        return c.snapshot(directory or self.input, self.work / "output", receipt or self.receipt, source,
                          manifest, trust or self.signer.trust)

    def variant(self, **changes):
        directory = self.work / "variant"
        return directory, fixtures.make_set(directory, self.signer, **changes)

    def test_signed_set_creates_readonly_snapshot(self):
        summary = self.verify()
        self.assertEqual(len(summary["packages"]), 9)
        self.assertEqual(summary["signer"], self.signer.fingerprint)
        self.assertEqual((self.work / "output").stat().st_mode & 0o777, 0o555)
        imported = json.loads((self.work / "output/import.json").read_text())
        self.assertEqual({p["group"] for p in imported["packages"]}, {"runtime", "boot"})
        self.assertFalse((self.work / "output/candidate-signing-key.asc").exists())

    def test_output_is_created_exclusively(self):
        (self.work / "output").mkdir()
        with self.assertRaises(FileExistsError):
            self.verify()

    def test_tampered_archive(self):
        next(self.input.glob("linux-aurora-7*.pkg.tar.xz")).write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "checksum"):
            self.verify()

    def test_receipt_manifest_and_source_must_match_the_inputs(self):
        for change, pattern in (("signature", "signature"), ("receipt", "receipt checksum"),
                                ("manifest", "build manifest"), ("source", "wrong build manifest"),
                                ("symlink", "")):
            with self.subTest(change=change):
                work = self.work / change
                shutil.copytree(self.good, work)
                if change == "signature":
                    (work / "signing.json.sig").unlink()
                if change == "symlink":
                    (work / "manifest.json").unlink()
                    (work / "manifest.json").symlink_to(self.good / "manifest.json")
                with self.assertRaisesRegex((ValueError, OSError), pattern):
                    c.snapshot(work, self.work / (change + "-out"),
                               "0" * 64 if change == "receipt" else self.receipt,
                               "c" * 40 if change == "source" else fixtures.SOURCE,
                               "0" * 64 if change == "manifest" else None, self.signer.trust)

    def test_runtime_source_names_either_policy_repository(self):
        def name_source(repository):
            def edit(manifest):
                manifest["source"]["repository"] = repository
                for package in manifest["packages"]:
                    if package["source"].get("commit") == fixtures.SOURCE:
                        package["source"]["repository"] = repository
            return edit
        for repository in ("omacom/omarchy", "omacom/omarchy-mac"):
            with self.subTest(repository=repository):
                directory = self.work / repository.replace("/", "-")
                receipt = fixtures.make_set(directory, self.signer, manifest_edit=name_source(repository))
                c.snapshot(directory, self.work / (directory.name + "-out"), receipt, fixtures.SOURCE, None, self.signer.trust)
        directory = self.work / "elsewhere"
        receipt = fixtures.make_set(directory, self.signer, manifest_edit=name_source("someone/omarchy"))
        with self.assertRaisesRegex(ValueError, "wrong build manifest"):
            c.snapshot(directory, self.work / "elsewhere-out", receipt, fixtures.SOURCE, None, self.signer.trust)

    def test_set_cannot_supply_its_own_trust_anchor(self):
        trust = self.work / "trust"
        shutil.copytree(self.signer.trust, trust)
        (trust / "public.asc").write_bytes((self.stranger.trust / "public.asc").read_bytes())
        with self.assertRaisesRegex(ValueError, "trust anchor"):
            self.verify(trust=trust)

    def test_key_travelling_with_the_set_is_ignored(self):
        directory = self.work / "stranger-set"
        receipt = fixtures.make_set(directory, self.signer, key_signer=self.stranger)
        # The set carries the key that signed it; only the pinned key is ever used.
        self.assertEqual((directory / "candidate-signing-key.asc").read_bytes(),
                         (self.stranger.trust / "public.asc").read_bytes())
        with self.assertRaisesRegex(ValueError, "invalid signature: signing.json"):
            self.verify(directory, receipt)

    def test_missing_or_extra_package(self):
        directory, receipt = self.variant(names=[n for n in fixtures.VERSIONS if n != "uboot-asahi"])
        with self.assertRaisesRegex(ValueError, "wrong package set"):
            self.verify(directory, receipt)

    def test_closure_and_channel_packages(self):
        contents = fixtures.default_contents()
        contents["omarchy-mac-boot"]["usr/share/omarchy-mac/boot-source-revision"] = ("d" * 40 + "\n").encode()
        versions = {"hyprland": "0.56.2-3", "omarchy-keyring": "20251027-1", "asdcontrol": "1:0.6.0-2"}
        directory, receipt = self.variant(
            versions=versions, contents=contents, names=[*fixtures.VERSIONS, *versions],
            channel=("omarchy-mac-boot", "linux-aurora", "linux-aurora-headers"), arches={"omarchy-keyring": "any"})
        summary = self.verify(directory, receipt)
        packages = {p["name"]: p for p in summary["packages"]}
        self.assertEqual(len(packages), 12)
        self.assertTrue(summary["candidate_only"])
        self.assertEqual({n: p["origin"] for n, p in packages.items() if p["group"] == "runtime"},
                         {"omarchy": "commit", "omarchy-settings": "commit", "omarchy-mac": "commit",
                          "omarchy-mac-boot": "channel " + "d" * 40})
        self.assertEqual(packages["linux-aurora"]["origin"], "channel")
        self.assertEqual(packages["uboot-asahi"]["origin"], "pull-request")
        self.assertEqual({n for n, p in packages.items() if p["group"] == "closure"}, set(versions))
        self.assertEqual(packages["asdcontrol"]["filename"], "asdcontrol-1.0.6.0-2-aarch64.pkg.tar.xz")

    def test_package_sources_outside_the_plan(self):
        def point(name, source):
            return lambda m: next(p for p in m["packages"] if p["name"] == name).update(source=source)

        closure = [*fixtures.VERSIONS, "hyprland"]
        cases = (
            ("closure from a commit", dict(manifest_edit=point("hyprland", {"repository": "omacom/omarchy-pkgs",
                                                                           "commit": "e" * 40})),
             "unknown closure package source: hyprland"),
            ("closure from another file", dict(manifest_edit=point(
                "hyprland", fixtures.channel_source("hyprland-0.56.1-1-aarch64.pkg.tar.xz"))),
             "unknown closure package source: hyprland"),
            ("closure from another host", dict(manifest_edit=point("hyprland", dict(
                fixtures.channel_source("hyprland-0.56.2-3-aarch64.pkg.tar.xz"),
                url="https://example.invalid/edge/aarch64/hyprland-0.56.2-3-aarch64.pkg.tar.xz"))),
             "unknown closure package source: hyprland"),
            ("runtime from a channel", dict(channel=("omarchy-mac",)), "mixed package sources: omarchy-mac"),
            ("boot package any-arch", dict(arches={"uboot-asahi": "any"}), "package metadata mismatch: uboot-asahi"),
        )
        for name, change, pattern in cases:
            with self.subTest(name):
                directory = self.work / name.replace(" ", "-")
                receipt = fixtures.make_set(directory, self.signer, versions={"hyprland": "0.56.2-3"},
                                            names=closure, **change)
                with self.assertRaisesRegex(ValueError, pattern):
                    self.verify(directory, receipt)
                shutil.rmtree(self.work / "output", ignore_errors=True)

    def test_refused_package(self):
        versions = dict(fixtures.VERSIONS, m1n1="1.5.0-1")
        contents = fixtures.default_contents()
        directory = self.work / "refused"
        receipt = fixtures.make_set(directory, self.signer, versions=versions, contents=contents,
                                    names=[*fixtures.VERSIONS, "m1n1"])
        with self.assertRaisesRegex(ValueError, "refused package"):
            self.verify(directory, receipt)

    def test_version_below_a_minimum(self):
        for name, low in (("limine-mkinitcpio-hook", "1.38.0-1.1"), ("omarchy-mac-boot", "20260921-9")):
            with self.subTest(name=name):
                directory = self.work / name
                receipt = fixtures.make_set(directory, self.signer, versions={name: low})
                with self.assertRaisesRegex(ValueError, "below the minimum"):
                    self.verify(directory, receipt)
                shutil.rmtree(self.work / "output", ignore_errors=True)

    def test_file_with_two_owners(self):
        contents = fixtures.default_contents()
        contents["omarchy-mac"]["usr/lib/asahi-boot/m1n1.bin"] = b"another m1n1"
        directory, receipt = self.variant(contents=contents)
        with self.assertRaisesRegex(ValueError, "ownership conflict"):
            self.verify(directory, receipt)

    def test_boot_payload_in_the_wrong_package(self):
        contents = fixtures.default_contents()
        contents["omarchy-mac"]["usr/lib/omarchy/initcpio/omarchy-mac-encrypt"] = \
            contents["omarchy-mac-boot"].pop("usr/lib/omarchy/initcpio/omarchy-mac-encrypt")
        directory, receipt = self.variant(contents=contents)
        with self.assertRaisesRegex(ValueError, "is not in omarchy-mac-boot"):
            self.verify(directory, receipt)

    def test_runtime_package_from_another_commit(self):
        contents = fixtures.default_contents()
        contents["omarchy-mac"]["usr/share/omarchy-mac/source-revision"] = ("c" * 40 + "\n").encode()
        directory, receipt = self.variant(contents=contents)
        with self.assertRaisesRegex(ValueError, "mixed package sources"):
            self.verify(directory, receipt)

    def platform_set(self, label, declared, revisions=None, sources=None, channel=(),
                     repository="omacom/omarchy-mac-pkgs"):
        """A set whose omarchy-mac and omarchy-mac-boot were built from their own
        commits of REPOSITORY: REVISIONS in the archives, SOURCES in the
        manifest, DECLARED as its platform_sources."""
        revisions = revisions or {"omarchy-mac": "d" * 40, "omarchy-mac-boot": "e" * 40}
        sources = revisions if sources is None else sources
        contents = fixtures.default_contents()
        files = {"omarchy-mac": "usr/share/omarchy-mac/source-revision",
                 "omarchy-mac-boot": "usr/share/omarchy-mac/boot-source-revision"}
        for name, revision in revisions.items():
            contents[name][files[name]] = (revision + "\n").encode()

        def edit(manifest):
            for package in manifest["packages"]:
                if package["name"] in sources and package["name"] not in channel:
                    package["source"] = {"repository": repository, "commit": sources[package["name"]]}
            if declared is not None:
                manifest["platform_sources"] = declared

        directory = self.work / label.replace(" ", "-")
        return directory, fixtures.make_set(directory, self.signer, contents=contents, manifest_edit=edit, channel=channel)

    def test_platform_packages_declared_from_their_own_commits(self):
        declared = {"omarchy-mac": "d" * 40, "omarchy-mac-boot": "e" * 40}
        directory, receipt = self.platform_set("declared", declared)
        summary = self.verify(directory, receipt)
        packages = {p["name"]: p for p in summary["packages"]}
        self.assertEqual({n: (p["origin"], p["source_commit"]) for n, p in packages.items() if p["group"] == "runtime"},
                         {"omarchy": ("commit", fixtures.SOURCE), "omarchy-settings": ("commit", fixtures.SOURCE),
                          "omarchy-mac": ("platform " + "d" * 40, "d" * 40),
                          "omarchy-mac-boot": ("platform " + "e" * 40, "e" * 40)})
        self.assertNotIn("source_commit", packages["linux-aurora"])
        self.assertEqual(fixtures.test_image_pin.pinned(summary), ["omarchy", "omarchy-mac", "omarchy-mac-boot", "omarchy-settings"])

    def test_platform_packages_from_the_repository_they_moved_from(self):
        declared = {"omarchy-mac": "d" * 40, "omarchy-mac-boot": "e" * 40}
        directory, receipt = self.platform_set("moved from", declared, repository="omacom/omarchy-mac")
        packages = {p["name"]: p for p in self.verify(directory, receipt)["packages"]}
        self.assertEqual(packages["omarchy-mac"]["origin"], "platform " + "d" * 40)

    def test_one_platform_package_declared(self):
        directory, receipt = self.platform_set("one", {"omarchy-mac": "d" * 40}, revisions={"omarchy-mac": "d" * 40})
        packages = {p["name"]: p for p in self.verify(directory, receipt)["packages"]}
        self.assertEqual((packages["omarchy-mac"]["origin"], packages["omarchy-mac-boot"]["origin"]),
                         ("platform " + "d" * 40, "commit"))

    def test_platform_sources_that_do_not_hold(self):
        d, e = "d" * 40, "e" * 40
        both = {"omarchy-mac": d, "omarchy-mac-boot": e}
        cases = (
            ("undeclared", None, {}, "mixed package sources: omarchy-mac"),
            ("half declared", {"omarchy-mac": d}, {}, "mixed package sources: omarchy-mac-boot"),
            ("revision differs", both, dict(revisions={"omarchy-mac": "f" * 40, "omarchy-mac-boot": e}, sources=both),
             "mixed package sources: omarchy-mac"),
            ("manifest commit differs", both, dict(sources={"omarchy-mac": "f" * 40, "omarchy-mac-boot": e}),
             "mixed package sources: omarchy-mac"),
            ("from the channel", both, dict(channel=("omarchy-mac-boot",)), "mixed package sources: omarchy-mac-boot"),
            ("runtime package", dict(both, omarchy=d), {}, "not a platform package: omarchy"),
            ("boot package", dict(both, **{"linux-aurora": d}), {}, "not a platform package: linux-aurora"),
            ("own commit", dict(both, **{"omarchy-mac": fixtures.SOURCE}), {}, "the set's own commit: omarchy-mac"),
            ("short commit", dict(both, **{"omarchy-mac": "d" * 12}), {}, "invalid platform source commit: omarchy-mac"),
            ("not a map", [["omarchy-mac", d]], {}, "invalid platform sources"),
            ("another repository", both, dict(repository="example/omarchy-mac-fork"), "mixed package sources: omarchy-mac"),
        )
        for label, declared, change, pattern in cases:
            with self.subTest(label):
                directory, receipt = self.platform_set(label, declared, **change)
                with self.assertRaisesRegex(ValueError, pattern):
                    self.verify(directory, receipt)
                shutil.rmtree(self.work / "output", ignore_errors=True)

    def test_set_digest_must_match_its_packages(self):
        directory, receipt = self.variant(manifest_edit=lambda m: m.update(set_sha256="0" * 64))
        with self.assertRaisesRegex(ValueError, "set digest"):
            self.verify(directory, receipt)

    def test_boot_package_pins_the_sets_runtime(self):
        directory = self.work / "pin"
        versions = dict(fixtures.VERSIONS)
        contents = fixtures.default_contents()
        original = fixtures.depends
        fixtures.depends = lambda name, v: ["omarchy=3.9.0-1"] if name == "omarchy-mac-boot" else original(name, v)
        try:
            receipt = fixtures.make_set(directory, self.signer, versions=versions, contents=contents)
        finally:
            fixtures.depends = original
        with self.assertRaisesRegex(ValueError, "pins another omarchy"):
            self.verify(directory, receipt)

    def apple_layout(self, directory, lists):
        contents = fixtures.default_contents()
        install = "usr/share/omarchy/install/"
        del contents["omarchy"][install + "omarchy-apple-silicon.packages"]
        contents["omarchy"].update({install + name: data for name, data in lists.items()})
        output = self.work / "output"
        if output.exists():
            output.chmod(0o700)
            shutil.rmtree(output)
        return fixtures.make_set(self.work / directory, self.signer, contents=contents)

    def test_apple_package_list_by_either_name(self):
        apple = b"# Apple\nomarchy-mac\nomarchy-mac-boot\n"
        layouts = {
            "e1b0e5e9b": {"omarchy-aarch64-apple.packages": apple},
            "5397950a2": {"omarchy-apple-silicon.packages": apple},
            "older": {"omarchy-apple.packages": apple},
            "platform-link": {"omarchy-apple-silicon.packages": apple,
                              "omarchy-aarch64-apple.packages": "omarchy-apple-silicon.packages"},
            "compatibility-link": {"omarchy-apple-silicon.packages": apple,
                                   "omarchy-apple.packages": "omarchy-apple-silicon.packages"},
            "reverse-link": {"omarchy-apple.packages": apple,
                             "omarchy-apple-silicon.packages": "omarchy-apple.packages"},
        }
        for directory, lists in layouts.items():
            with self.subTest(layout=directory):
                receipt = self.apple_layout(directory, lists)
                self.verify(self.work / directory, receipt)

    def test_apple_package_list_prefers_upstreams_name(self):
        receipt = self.apple_layout("both", {"omarchy-apple-silicon.packages": b"omarchy-mac\nomarchy-mac-boot\n",
                                             "omarchy-apple.packages": b"omarchy-mac\n"})
        self.verify(self.work / "both", receipt)
        receipt = self.apple_layout("both-stale", {"omarchy-apple-silicon.packages": b"omarchy-mac\n",
                                                   "omarchy-apple.packages": b"omarchy-mac\nomarchy-mac-boot\n"})
        with self.assertRaisesRegex(ValueError, "lacks the add-on or boot package"):
            self.verify(self.work / "both-stale", receipt)
        # The platform's name (omacom/omarchy e1b0e5e9b) wins over apple-silicon's.
        receipt = self.apple_layout("platform", {"omarchy-aarch64-apple.packages": b"omarchy-mac\nomarchy-mac-boot\n",
                                                 "omarchy-apple-silicon.packages": b"omarchy-mac\n"})
        self.verify(self.work / "platform", receipt)
        receipt = self.apple_layout("platform-stale", {"omarchy-aarch64-apple.packages": b"omarchy-mac\n",
                                                       "omarchy-apple-silicon.packages": b"omarchy-mac\nomarchy-mac-boot\n"})
        with self.assertRaisesRegex(ValueError, "lacks the add-on or boot package"):
            self.verify(self.work / "platform-stale", receipt)

    def test_each_runtime_layout_verifies(self):
        for layout in fixtures.RUNTIME_LAYOUTS:
            with self.subTest(layout=layout):
                output = self.work / "output"
                if output.exists():
                    output.chmod(0o700)
                    shutil.rmtree(output)
                receipt = fixtures.make_set(self.work / layout, self.signer, contents=fixtures.default_contents(layout))
                self.assertEqual(self.verify(self.work / layout, receipt)["source_commit"], fixtures.SOURCE)

    def test_apple_package_list_missing(self):
        for directory, lists in (("none", {}), ("link-only", {"omarchy-apple.packages": "omarchy-apple-silicon.packages"}),
                                 ("platform-link-only", {"omarchy-aarch64-apple.packages": "omarchy-apple.packages"})):
            with self.subTest(layout=directory):
                receipt = self.apple_layout(directory, lists)
                with self.assertRaisesRegex(ValueError, "the runtime ships no Apple package list"):
                    self.verify(self.work / directory, receipt)

    def test_describe_prints_what_an_inputs_record_pins(self):
        summary = c.describe(self.input, self.signer.trust)
        self.assertEqual(summary["receipt_sha256"], self.receipt)
        self.assertEqual(summary["source_commit"], fixtures.SOURCE)


class VercmpTest(unittest.TestCase):
    def test_pacman_ordering(self):
        for a, b, expected in (
            ("1.39.0-2", "1.39.0-2", 0), ("1.38.0-1.1", "1.39.0-2", -1),
            ("20260921-10.361203357120001", "20260921-10", 1), ("1.0a", "1.0", -1), ("1.0", "1.0.1", -1),
            ("1:1.0", "2.0", 1), ("1.0-1", "1.0-2", -1), ("1.0", "1.0-5", 0), ("1.0.a", "1.0.1", -1),
            ("4.0.0.alpha.quattro.r1-1", "4.0.2-1", -1), ("2026.07.asahi2-4", "2026.07.asahi1-1", 1),
        ):
            with self.subTest(a=a, b=b):
                self.assertEqual(c.vercmp(a, b), expected)
                self.assertEqual(c.vercmp(b, a), -expected)


if __name__ == "__main__":
    unittest.main()
