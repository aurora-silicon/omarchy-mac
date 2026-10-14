#!/usr/bin/env python3
"""An edge publish starts an image build only when it changed a package the image installs."""
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fixtures  # noqa: E402

ROOT = fixtures.ROOT
FILTER = ROOT / "bin/edge-dispatch-filter"
_loader = importlib.machinery.SourceFileLoader("edge_dispatch_filter", str(FILTER))
edge_filter = importlib.util.module_from_spec(importlib.util.spec_from_loader("edge_dispatch_filter", _loader))
_loader.exec_module(edge_filter)
SET_NAMES = [fixtures.CHANNEL_NAMES.get(role, role) for role in fixtures.VERSIONS]


def write_repo(path: Path, packages: dict[str, dict]) -> Path:
    """A repository database at PATH listing PACKAGES {name: {"provides": [...], "depends": [...]}}, in
    the older layout Arch Linux ARM's databases still use: relations in a depends file beside desc."""
    entries = path.parent / f"{path.stem}-entries"
    entries.mkdir()

    def render(lines):
        return "".join(f"%{k}%\n" + "".join(v + "\n" for v in values) + "\n" for k, values in lines if values)

    for name, fields in packages.items():
        version = fields.get("version", "1.0-1")
        entry = entries / f"{name}-{version}"
        entry.mkdir()
        (entry / "desc").write_text(render([("FILENAME", [f"{name}-{version}-aarch64.pkg.tar.xz"]), ("NAME", [name]),
                                            ("VERSION", [version])]))
        (entry / "depends").write_text(render([("DEPENDS", fields.get("depends", [])),
                                               ("PROVIDES", fields.get("provides", []))]))
    subprocess.run(["bsdtar", "-czf", str(path), "-C", str(entries), *sorted(e.name for e in entries.iterdir())],
                   check=True)
    return path


EDGE_ORDER = ("omarchy", "asahi-alarm", "core", "extra", "alarm", "aur")
CANDIDATE_ORDER = ("asahi-alarm", "core", "extra", "alarm", "aur", "omarchy")


def template(order) -> bytes:
    """An Apple pacman template naming ORDER, laid out like the runtime's."""
    sections = "".join(f"\n[{name}]\nInclude = /etc/pacman.d/mirrorlist\n" for name in order)
    return f"[options]\nArchitecture = aarch64\n{sections}".encode()


def make_edge(directory: Path, order=EDGE_ORDER, template_text=None) -> tuple[Path, Path, Path]:
    """An edge snapshot whose omarchy-settings-dev ships TEMPLATE_TEXT (default: one naming ORDER) as
    its pacman-edge.conf. The fixture runtime's lists: base hyprland, aarch64 zram-generator, Apple
    omarchy-mac and omarchy-mac-boot, x86_64-only obs-studio. omarchy-dev depends on walker>=2, walker
    on elephant and libthing>=3, omarchy-mac-boot on omarchy (which omarchy-dev provides), elephant on
    the virtual vulkan-driver; omarchy-mac provides limine-snapper-sync, which the builder still
    installs as a target. Returns the database, the runtime archive and the settings archive."""
    extra = [("walker", "2.17.2-1"), ("elephant", "2.0-1"), ("zram-generator", "1.2-1"), ("libthing", "2.0-1"),
             ("hyprland", "0.56.2-5"), ("obs-studio", "32.2.2-1"), ("claude-code", "2.1.296-1"),
             ("omarchy", "4.0.4-2"), ("limine-snapper-sync", "1.32.1-2"), ("nvidia-utils", "615.71.09-1")]
    contents = fixtures.channel_contents()
    if template_text is not False:
        contents["omarchy-settings"][edge_filter.TEMPLATE.format(channel="edge")] = (
            template_text if template_text is not None else template(order))

    def edit(name, text):
        if name == "omarchy-mac":
            return text + "%PROVIDES%\nlimine-snapper-sync\n\n"
        return text.replace("%DEPENDS%\n", "%DEPENDS%\nwalker>=2\n") if name == "omarchy-dev" else text

    database, _ = fixtures.make_channel(directory, None, contents=contents, extra=extra, unsigned=SET_NAMES,
                                        entry_edit=edit)
    entries = directory / "entries"
    for name, addition in (("walker-2.17.2-1", "%DEPENDS%\nelephant\nlibthing>=3\n"),
                           ("elephant-2.0-1", "%DEPENDS%\nvulkan-driver\n"),
                           ("nvidia-utils-615.71.09-1", "%PROVIDES%\nvulkan-driver\n")):
        desc = entries / name / "desc"
        desc.write_text(desc.read_text() + addition + "\n")
    subprocess.run(["bsdtar", "-czf", str(database), "-C", str(entries), *sorted(e.name for e in entries.iterdir())],
                   check=True)
    version = fixtures.CHANNEL_VERSIONS["omarchy"]
    packages = directory / "packages"
    return (database, packages / f"omarchy-dev-{version}-aarch64.pkg.tar.xz",
            packages / f"omarchy-settings-dev-{version}-aarch64.pkg.tar.xz")


class EdgeDispatchFilterTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.base = Path(cls.tmp.name)
        # Edge's order, [omarchy] first, and a runtime whose template puts it last.
        cls.database, cls.runtime, cls.settings = make_edge(cls.base / "edge")
        cls.last = make_edge(cls.base / "edge-last", CANDIDATE_ORDER)
        # Arch Linux ARM's extra carries hyprland, a vulkan-driver of its own, a walker too old for
        # omarchy-dev, a libthing new enough for walker and a provider of zram-generator.
        cls.repos = cls.base / "repos"
        cls.repos.mkdir()
        write_repo(cls.repos / "extra.db", {"hyprland": {}, "mesa": {"provides": ["vulkan-driver"]},
                                            "walker": {"version": "1.0-1"}, "libthing": {"version": "3.0-1"},
                                            "zram-tools": {"provides": ["zram-generator"]}})
        for name in ("asahi-alarm", "core", "alarm", "aur"):
            write_repo(cls.repos / f"{name}.db", {f"{name}-placeholder": {}})

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def payload(self, *names, **fields) -> Path:
        body = {"schema": 1, "channel": "edge", "arch": "aarch64",
                "packages": [{"name": n, "version": "1-1"} for n in names], **fields}
        path = Path(tempfile.mkstemp(dir=self.base, suffix=".json")[1])
        path.write_text(json.dumps(body))
        return path

    def decide(self, *names, repos=True, edge=None, **fields) -> dict:
        database, runtime, settings = edge or (self.database, self.runtime, self.settings)
        return edge_filter.decide(database, runtime, settings, self.payload(*names, **fields),
                                  self.repos if repos else None)

    def test_a_channel_set_package_is_relevant(self):
        for name in ("linux-aurora", "m1n1-aurora", "uboot-asahi", "omarchy-dev", "omarchy-settings-dev",
                     "omarchy-mac", "omarchy-mac-boot"):
            decision = self.decide(name, "claude-code")
            self.assertTrue(decision["relevant"], name)
            self.assertEqual(decision["matched"], [name])

    def test_runtime_lists_builder_packages_and_their_dependencies_are_relevant(self):
        self.assertEqual(self.decide("zram-generator")["matched"], ["zram-generator"], "the runtime's aarch64 list")
        self.assertEqual(self.decide("limine-snapper-sync")["matched"], ["limine-snapper-sync"],
                         "the builder's PLATFORM_PACKAGES")
        self.assertEqual(self.decide("walker", "elephant")["matched"], ["elephant", "walker"],
                         "dependencies the runtime pulls in, transitively")

    def test_an_unrelated_publish_is_not(self):
        decision = self.decide("claude-code", "obs-studio")
        self.assertFalse(decision["relevant"])
        self.assertEqual(decision["matched"], [])
        self.assertEqual(decision["published"], ["claude-code", "obs-studio"])
        self.assertFalse(self.decide()["relevant"], "an empty publish")

    def test_a_package_the_runtime_already_provides_is_not(self):
        self.assertFalse(self.decide("omarchy")["relevant"], "omarchy-dev provides omarchy")

    def test_the_runtime_template_orders_the_repositories(self):
        self.assertEqual(self.decide()["repository_order"], list(EDGE_ORDER))
        self.assertEqual(self.decide(edge=self.last)["repository_order"], list(CANDIDATE_ORDER))

    def test_a_package_both_omarchy_and_alarm_carry_is_omarchys_on_edge(self):
        decision = self.decide("hyprland", "nvidia-utils")
        self.assertEqual(decision["matched"], ["hyprland", "nvidia-utils"],
                         "[omarchy] comes first: its hyprland, and its vulkan-driver provider")
        self.assertIn("hyprland", decision["image_packages"])

    def test_an_arch_linux_arm_depends_file_is_read(self):
        extra = edge_filter.read_repo(self.repos / "extra.db")
        self.assertEqual(extra["mesa"]["PROVIDES"], ["vulkan-driver"])
        self.assertEqual(extra["libthing"]["VERSION"], ["3.0-1"])

    def test_with_omarchy_last_an_earlier_repository_wins(self):
        self.assertFalse(self.decide("hyprland", edge=self.last)["relevant"], "extra's hyprland")
        self.assertFalse(self.decide("nvidia-utils", edge=self.last)["relevant"], "extra's mesa provides first")

    def test_a_template_that_does_not_name_the_pinned_repositories_is_refused(self):
        for name, text, message in (
                ("missing", False, "no Apple pacman template"),
                ("short", template(EDGE_ORDER[:-1]), "names the repositories omarchy asahi-alarm core extra alarm, not"),
                ("extra", template(EDGE_ORDER + ("testing",)), "not the pinned"),
                ("crlf-missing", template(EDGE_ORDER[1:]).replace(b"\n", b"\r\n"), "not the pinned")):
            with self.subTest(name), self.assertRaisesRegex(ValueError, message):
                self.decide("linux-aurora", edge=make_edge(self.base / f"edge-{name}", template_text=text))

    def test_a_crlf_template_reads_as_sed_reads_it(self):
        edge = make_edge(self.base / "edge-crlf", template_text=template(EDGE_ORDER).replace(b"\n", b"\r\n"))
        self.assertEqual(self.decide(edge=edge)["repository_order"], list(EDGE_ORDER))

    def test_the_template_is_the_one_build_mac_image_reads(self):
        builder = (ROOT / "bin/build-mac-image").read_text()
        self.assertIn("template=usr/share/omarchy/default/pacman/aarch64-apple/pacman-$(field omarchy_channel).conf",
                      builder)
        self.assertIn("archive=$candidates/$(candidate_archive omarchy-settings)", builder)
        self.assertEqual(edge_filter.TEMPLATE,
                         "usr/share/omarchy/default/pacman/aarch64-apple/pacman-{channel}.conf")
        self.assertIn("repository_order=(" + " ".join(CANDIDATE_ORDER) + ")", builder)

    def test_without_the_other_repositories_it_over_matches(self):
        decision = self.decide("hyprland", "nvidia-utils", "claude-code", repos=False)
        self.assertEqual(decision["matched"], ["hyprland", "nvidia-utils"])
        self.assertEqual(decision["resolved_against"], ["omarchy"])

    def test_the_decision_records_both_database_hashes(self):
        decision = self.decide("linux-aurora", database_sha256="0" * 64)
        self.assertEqual(decision["database_sha256"], fixtures.candidate_set.digest(self.database))
        self.assertEqual(decision["payload_database_sha256"], "0" * 64)
        self.assertEqual(decision["runtime"], self.runtime.name)

    def test_versions_decide_which_repository_a_dependency_comes_from(self):
        decision = self.decide("walker", edge=self.last)
        self.assertEqual(decision["matched"], ["walker"], "extra's walker 1.0 does not meet omarchy-dev's walker>=2")
        self.assertFalse(self.decide("libthing")["relevant"],
                         "omarchy comes first, but its libthing 2.0 does not meet walker's libthing>=3")
        self.assertEqual(self.decide("libthing", edge=self.last)["matched"], [], "nor with omarchy last")
        self.assertEqual(self.decide("zram-generator")["matched"], ["zram-generator"],
                         "a literal name in omarchy wins over an earlier repository's provider")
        self.assertEqual(self.decide("limine-snapper-sync")["matched"], ["limine-snapper-sync"],
                         "a target is installed even when a chosen package provides its name")

    def test_the_resolver_follows_pacman(self):
        def entry(version, provides=(), depends=(), groups=()):
            return {"VERSION": [version], "PROVIDES": list(provides), "DEPENDS": list(depends),
                    "GROUPS": list(groups)}
        early = {"lib": entry("1.0-1"), "virt-old": entry("1-1", provides=["virt=1.0"]),
                 "tool": entry("1-1", provides=["thing"])}
        omarchy = {"app": entry("1-1", depends=["lib>=2", "virt>=2", "unversioned-virt"]),
                   "lib": entry("2.1-1"), "virt-new": entry("1-1", provides=["virt=2.5"]),
                   "plain": entry("1-1", provides=["unversioned-virt"]),
                   "member-a": entry("1-1", groups=["grp"]), "member-b": entry("1-1", groups=["grp"]),
                   "thing": entry("1-1")}
        chosen = edge_filter.resolve([("extra", early), ("omarchy", omarchy)], [], ["app", "grp", "thing"])
        from_omarchy = sorted(n for r, n in chosen if r == "omarchy")
        self.assertEqual(from_omarchy, ["app", "lib", "member-a", "member-b", "plain", "thing", "virt-new"])
        self.assertNotIn(("extra", "lib"), chosen)
        self.assertNotIn(("extra", "tool"), chosen, "a target's literal name wins over a provider")

    def test_a_package_does_not_meet_dependencies_inside_its_own_subtree(self):
        def entry(provides=(), depends=()):
            return {"VERSION": ["1-1"], "PROVIDES": list(provides), "DEPENDS": list(depends), "GROUPS": []}
        omarchy = {"app": entry(depends=["x"]), "provider": entry(provides=["v"])}
        extra = {"x": entry(provides=["v"], depends=["y"]), "y": entry(depends=["v"])}
        chosen = edge_filter.resolve([("omarchy", omarchy), ("extra", extra)], [], ["app"])
        self.assertIn(("omarchy", "provider"), chosen, "x is not in the transaction yet when y needs v")

    def test_vercmp_orders_versions_as_pacman_does(self):
        # vercmp(8)'s example ordering.
        order = "1.0a 1.0b 1.0beta 1.0p 1.0pre 1.0rc 1.0 1.0.a 1.0.1".split()
        for older, newer in zip(order, order[1:]):
            self.assertEqual(edge_filter.vercmp(older, newer), -1, (older, newer))
            self.assertEqual(edge_filter.vercmp(newer, older), 1, (newer, older))
        for a, b, expected in (("1:1.0-1", "2.0-1", 1), ("1.0-1", "1.0-2", -1), ("1.0", "1.0-2", 0),
                               ("7.1.12.aurora2-11", "7.1.12.aurora10-1", -1), ("1.01", "1.1", 0)):
            self.assertEqual(edge_filter.vercmp(a, b), expected, (a, b))

    def test_another_database_than_the_published_one_never_rules_a_publish_out(self):
        own = fixtures.candidate_set.digest(self.database)
        self.assertFalse(self.decide("claude-code", database_sha256=own)["relevant"])
        decision = self.decide("claude-code", database_sha256="0" * 64)
        self.assertTrue(decision["relevant"])
        self.assertEqual(decision["reason"], "other-database")
        self.assertEqual(self.decide("linux-aurora", database_sha256="0" * 64)["reason"], "matched")

    def test_the_whole_channel_set_is_in_the_image(self):
        self.assertTrue(set(SET_NAMES) <= set(self.decide()["image_packages"]))

    def test_a_malformed_payload_is_refused(self):
        for fields, message in (({"schema": 2}, "schema 1"), ({"channel": "rc"}, "edge aarch64"),
                                ({"arch": "x86_64"}, "edge aarch64"), ({"packages": "linux-aurora"}, "package list"),
                                ({"packages": [{"name": "a b", "version": "1-1"}]}, "malformed package"),
                                ({"packages": [{"name": "x"}]}, "malformed package"),
                                ({"database_sha256": "nope"}, "database hash"), ({"schema": True}, "schema 1")):
            with self.subTest(fields=fields), self.assertRaisesRegex(ValueError, message):
                self.decide("linux-aurora", **fields)
        broken = self.base / "broken.json"
        broken.write_text("{")
        with self.assertRaisesRegex(ValueError, "unreadable payload"):
            edge_filter.decide(self.database, self.runtime, self.settings, broken, self.repos)

    def test_a_runtime_archive_the_database_does_not_list_is_refused(self):
        for runtime, settings, name in ((True, False, "omarchy-dev"), (False, True, "omarchy-settings-dev")):
            other = self.base / f"tampered-{name}.pkg.tar.xz"
            other.write_bytes((self.runtime if runtime else self.settings).read_bytes() + b"tampered")
            with self.subTest(name), self.assertRaisesRegex(ValueError, f"not the {name} archive"):
                edge_filter.decide(self.database, other if runtime else self.runtime,
                                   other if settings else self.settings, self.payload("linux-aurora"), self.repos)

    def test_the_builder_arrays_are_read_from_build_mac_image(self):
        builder = ROOT / "bin/build-mac-image"
        script = "".join(f"eval \"$(sed -n '/^{a}=(/,/)/p' \"$1\")\"; printf '%s\\n' \"${{{a}[@]}}\"; "
                         for a in edge_filter.BUILDER_ARRAYS)
        bash = subprocess.run(["bash", "-c", script, "bash", str(builder)], capture_output=True, text=True, check=True)
        self.assertEqual(edge_filter.builder_arrays(builder), bash.stdout.split(), "the arrays as Bash reads them")

    def test_the_command_line(self):
        result = subprocess.run([sys.executable, str(FILTER), "runtime", "--db", str(self.database)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), [
            f"omarchy {self.runtime.name} {fixtures.candidate_set.digest(self.runtime)}",
            f"omarchy-settings {self.settings.name} {fixtures.candidate_set.digest(self.settings)}"])
        result = subprocess.run([sys.executable, str(FILTER), "decide", "--db", str(self.database), "--runtime",
                                 str(self.runtime), "--settings", str(self.settings), "--payload",
                                 str(self.payload("walker")), "--repos", str(self.repos)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["matched"], ["walker"])
        result = subprocess.run([sys.executable, str(FILTER), "decide", "--db", str(self.database), "--runtime",
                                 str(self.runtime), "--settings", str(self.settings), "--payload",
                                 str(self.payload("walker", channel="rc"))],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("edge aarch64", result.stderr)


if __name__ == "__main__":
    unittest.main()
