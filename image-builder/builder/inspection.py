"""Inspect a finished Apple image root against the candidate set it was built from.

Every boot component the Mac runs is compared with the bytes the signed set
carries, read from the frozen archives rather than from the image: m1n1's
stage 2 on the ESP (m1n1, the Aurora device trees in C order, U-Boot), the
installed boot payloads, the Limine loader, menu and UKI, the initramfs the
UKI embeds, the hooks that keep them current, the installed versions against
the set and its minimums, and the markers a fresh image's first boot needs.
A missing or mismatched component fails the inspection.
"""
from __future__ import annotations

from datetime import datetime
import gzip
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import tempfile
import zlib

HERE = Path(__file__).resolve().parent
KERNEL = "linux-aurora"
PLATFORM = "apple-silicon"
LIMINE_STEP = "install/hardware/apple/limine-boot.sh"
# An older runtime's Apple leaf that appends the unsigned [omarchy-aarch64] to pacman.conf.
UNSIGNED_REPOSITORY_STEP = "install/hardware/apple/pacman.sh"
PLYMOUTH_THEME = "omarchy"
PLYMOUTH_CONFIG = "etc/plymouth/plymouthd.conf"
PLYMOUTH_DEFAULTS = "usr/share/plymouth/plymouthd.defaults"
PLYMOUTH_THEME_FILE = f"usr/share/plymouth/themes/{PLYMOUTH_THEME}/{PLYMOUTH_THEME}.plymouth"
# The splash words of mx-mac's qualified boot line: the Mac's device tree
# registers a serial console, and Plymouth shows its text view while one is active.
SPLASH_WORDS = ("quiet", "splash", "plymouth.ignore-serial-consoles")
# The m1n1 options update-m1n1 copies from /etc/m1n1.conf into stage 2.
M1N1_OPTION = re.compile(r"(chosen\.[^=]*|display|mitigations)=.*")
# What the image-target manifest records, in the order the builder writes it.
# The runtime reads format and platform; the rest ties a Mac to its image:
# package_set_sha256 and built, the build identity, name the build's IMAGE and
# PROVENANCE. An image built before the identity was recorded has neither, and
# is still inspected: the identity is both keys or none.
TARGET_FIELDS = ("format", "platform", "candidate_set", "candidate_source_commit", "builder_commit",
                 "builder_tree_clean", "image_profile", "package_set_sha256", "built")
# A channel image names its set and the channel database it came from instead.
CHANNEL_TARGET_FIELDS = ("format", "platform", "channel_set", "channel_db_sha256", "builder_commit",
                         "builder_tree_clean", "image_profile", "package_set_sha256", "built")
IDENTITY_FIELDS = ("package_set_sha256", "built")
# The candidate set's name and the build time, as the builder writes them.
CANDIDATE_SET_NAME = re.compile(r"[A-Za-z0-9._-]+")
BUILT = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z")


def build_time(value: str) -> bool:
    """VALUE is a UTC build time as the builder writes it: YYYY-MM-DDTHH:MM:SSZ, a real instant."""
    if BUILT.fullmatch(value) is None:
        return False
    try:
        datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        return False
    return True


def _load(name: str, file: str):
    spec = importlib.util.spec_from_file_location(name, HERE / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


candidate_set = _load("candidate_set", "candidate_set.py")
limine = _load("apple_limine", "apple_limine.py")
installed_system = _load("verify_installed_system", "verify_installed_system.py")
test_image_pin = _load("test_image_pin", "test_image_pin.py")


class InspectionError(RuntimeError):
    pass


def require(ok: bool, message: str) -> None:
    if not ok:
        raise InspectionError(message)


class Candidates:
    """The frozen, imported set: import.json and its archives. A candidate set
    (candidate_set.py), or a channel set (channel_set.py, kind "channel"), whose
    runtime packages name the role they fill (omarchy-dev fills omarchy)."""

    def __init__(self, directory: Path) -> None:
        self.directory = directory
        self.summary = json.loads((directory / "import.json").read_text())
        self.packages = {p["name"]: p for p in self.summary["packages"]}
        self.kind = self.summary.get("kind", "candidate")
        require(self.kind in ("candidate", "channel"), f"the set is of an unknown kind: {self.kind}")
        self.roles = {p.get("role", p["name"]): p["name"] for p in self.summary["packages"]}
        self._listings: dict[str, list[str]] = {}

    def target_fields(self) -> tuple[str, ...]:
        return CHANNEL_TARGET_FIELDS if self.kind == "channel" else TARGET_FIELDS

    def target_set(self) -> dict[str, str]:
        """The set's lines in the image-target manifest and the factory seal."""
        if self.kind == "channel":
            return {"channel_set": self.summary["set"], "channel_db_sha256": self.summary["database_sha256"]}
        return {"candidate_set": self.summary["set"], "candidate_source_commit": self.summary["source_commit"]}

    def runtime_names(self) -> set[str]:
        """Runtime packages named apart from their role: a channel's -dev desktop."""
        return {name for role, name in self.roles.items() if role != name}

    def archive(self, name: str) -> Path:
        return self.directory / self.packages[name]["filename"]

    def member(self, name: str, path: str) -> bytes:
        return subprocess.check_output(["bsdtar", "-xOf", str(self.archive(name)), path])

    def listing(self, name: str) -> list[str]:
        if name not in self._listings:
            output = subprocess.check_output(["bsdtar", "-tf", str(self.archive(name))], text=True)
            self._listings[name] = [p.removeprefix("./") for p in output.splitlines() if not p.endswith("/")]
        return self._listings[name]

    def kernel_release(self) -> str:
        kernels = [p for p in self.listing(KERNEL) if PurePosixPath(p).match("usr/lib/modules/*/vmlinuz")]
        require(len(kernels) == 1, "the candidate kernel carries no single vmlinuz")
        return PurePosixPath(kernels[0]).parts[3]

    def dtbs(self) -> list[str]:
        release = self.kernel_release()
        names = [p for p in self.listing(KERNEL) if PurePosixPath(p).match(f"usr/lib/modules/{release}/dtbs/*.dtb")]
        # update-m1n1 concatenates its glob in C collation: bytewise.
        return sorted(names, key=lambda path: path.encode())


def installed_versions(root: Path) -> dict[str, str]:
    versions = {}
    for entry in (root / "var/lib/pacman/local").iterdir():
        desc = entry / "desc"
        if desc.is_file():
            lines = desc.read_text().splitlines()
            versions[lines[lines.index("%NAME%") + 1]] = lines[lines.index("%VERSION%") + 1]
    return versions


def check_candidate_versions(root: Path, candidates: Candidates, report: dict) -> str:
    versions = installed_versions(root)
    report["installed_versions"] = {name: versions.get(name) for name in sorted(candidates.packages)}
    for name, package in candidates.packages.items():
        require(versions.get(name) == package["version"],
                f"{name} is {versions.get(name) or 'not installed'}, the set has {package['version']}")
    return f"all {len(candidates.packages)} candidate packages installed at the set's versions"


def check_runtime_sources(root: Path, candidates: Candidates, report: dict) -> str:
    """The commit each runtime package was built from, as the importer verified
    it: the set's source commit, or the one the set declares for a platform
    package. The installed package records it too. A channel set's runtime
    records a commit where its package ships a source revision (the platform
    packages); the -dev desktop ships none and is held to one version, the set's
    archives and the channel database instead."""
    if candidates.kind == "channel":
        return check_channel_runtime_sources(root, candidates, report)
    sources = {}
    for name, package in sorted(candidates.packages.items()):
        if package.get("group") != "runtime":
            continue
        commit = package.get("source_commit", "")
        require(re.fullmatch(r"[0-9a-f]{40}", commit) is not None, f"the candidate set records no source commit for {name}")
        path = root / candidate_set.REVISION_FILES[name]
        require(path.is_file() and path.read_text().strip() == commit, f"/{candidate_set.REVISION_FILES[name]} does not name {commit}")
        sources[name] = commit
    require(sources.get("omarchy") == sources.get("omarchy-settings") == candidates.summary["source_commit"],
            "the runtime is not built from the set's source commit")
    report["runtime_sources"] = sources
    others = sorted(f"{name} {commit[:12]}" for name, commit in sources.items() if commit != candidates.summary["source_commit"])
    return f"runtime from {candidates.summary['source_commit'][:12]}" + (f"; {', '.join(others)}" if others else "")


def check_channel_runtime_sources(root: Path, candidates: Candidates, report: dict) -> str:
    sources = {}
    for name, package in sorted(candidates.packages.items()):
        if package.get("group") != "runtime" or "source_commit" not in package:
            continue
        commit = package["source_commit"]
        relative = candidate_set.REVISION_FILES[package["role"]]
        require(re.fullmatch(r"[0-9a-f]{40}", commit) is not None, f"the channel set records no source commit for {name}")
        require((root / relative).is_file() and (root / relative).read_text().strip() == commit,
                f"/{relative} does not name {commit}")
        sources[name] = commit
    desktop = candidates.packages[candidates.roles["omarchy"]], candidates.packages[candidates.roles["omarchy-settings"]]
    require(desktop[0]["version"] == desktop[1]["version"], "the runtime and its settings are not one version")
    require(sources, "the channel set records no runtime source commit")
    report["runtime_sources"] = sources
    return (f"runtime {desktop[0]['name']} {desktop[0]['version']} from the channel database "
            f"{candidates.summary['database_sha256'][:12]}; " + ", ".join(f"{n} {c[:12]}" for n, c in sources.items()))


def check_apple_packages(root: Path, report: dict) -> str:
    """Every package the image's Apple list names is installed, reading the list
    build-mac-image took: omarchy-aarch64-apple.packages, else an older
    runtime's omarchy-apple-silicon.packages or omarchy-apple.packages, never a
    link."""
    path = next((root / name for name in candidate_set.APPLE_LISTS
                 if (root / name).is_file() and not (root / name).is_symlink()), None)
    require(path is not None, "the image " + candidate_set.NO_APPLE_LIST)
    names = [fields[0] for fields in map(str.split, path.read_text().splitlines())
             if fields and not fields[0].startswith("#")]
    require(bool(names), f"{path.name} names no package")
    versions = installed_versions(root)
    report["apple_package_list"] = path.name
    missing = [name for name in names if name not in versions]
    require(not missing, f"{path.name} names packages that are not installed: {' '.join(missing)}")
    return f"all {len(names)} packages of {path.name} installed"


def check_minimum_versions(root: Path, policy: dict) -> str:
    versions = installed_versions(root)
    details = []
    for name, minimum in sorted(policy["minimum_versions"].items()):
        installed = versions.get(name)
        require(installed is not None, f"{name} is not installed")
        require(candidate_set.vercmp(installed, minimum) >= 0, f"{name} {installed} is below the minimum {minimum}")
        details.append(f"{name} {installed} >= {minimum}")
    return "; ".join(details)


def check_refused(root: Path, policy: dict) -> str:
    present = sorted(set(policy["refused_packages"]) & set(installed_versions(root)))
    require(not present, "refused packages are installed: " + ", ".join(present))
    return "none of " + ", ".join(policy["refused_packages"]) + " installed"


def check_installed_payloads(root: Path, candidates: Candidates) -> str:
    release = candidates.kernel_release()
    expected = {
        "usr/lib/asahi-boot/m1n1.bin": "m1n1-aurora",
        "usr/lib/asahi-boot/u-boot-nodtb.bin": "uboot-asahi",
        f"usr/lib/modules/{release}/vmlinuz": KERNEL,
    }
    expected.update({path: KERNEL for path in candidates.dtbs()})
    for path, package in expected.items():
        installed = root / path
        require(installed.is_file() and not installed.is_symlink(), f"/{path} is missing")
        require(installed.read_bytes() == candidates.member(package, path), f"/{path} is not {package}'s from the set")
    return f"m1n1, U-Boot, the kernel and {len(candidates.dtbs())} device trees match the set's archives"


def m1n1_stage2(root: Path, candidates: Candidates, report: dict) -> str:
    """m1n1/boot.bin is the set's m1n1, then every Aurora device tree in C
    order, then the set's U-Boot gzipped, then m1n1 options only."""
    data = limine.regular(root / "boot/efi/m1n1/boot.bin")
    m1n1 = candidates.member("m1n1-aurora", "usr/lib/asahi-boot/m1n1.bin")
    require(data.startswith(m1n1), "m1n1/boot.bin does not start with the set's m1n1")
    offset = len(m1n1)
    names = candidates.dtbs()
    for path in names:
        dtb = candidates.member(KERNEL, path)
        require(data[offset:offset + len(dtb)] == dtb,
                f"m1n1/boot.bin does not carry {PurePosixPath(path).name} from the set's kernel at its place")
        offset += len(dtb)
    require(data[offset:offset + 4] != b"\xd0\x0d\xfe\xed", "m1n1/boot.bin carries a device tree the set's kernel lacks")
    uboot, rest = limine.gunzip_prefix(data[offset:])
    require(uboot == candidates.member("uboot-asahi", "usr/lib/asahi-boot/u-boot-nodtb.bin"),
            "m1n1/boot.bin's U-Boot is not the set's")
    options = m1n1_options(root)
    require(rest == options, "m1n1/boot.bin does not end with exactly the image's m1n1 options")
    report["m1n1_stage2"] = {"device_trees": len(names), "bytes": len(data),
                             "options": options.decode(errors="replace").splitlines()}
    return f"m1n1 + {len(names)} device trees (C order) + U-Boot, all from the set"


def m1n1_options(root: Path) -> bytes:
    """What update-m1n1 appends from the image's /etc/m1n1.conf: sh's `read line`
    drops an unterminated last line, strips blanks and removes backslashes."""
    config = root / "etc/m1n1.conf"
    if not config.exists() and not config.is_symlink():
        return b""
    text = limine.regular(config).decode()
    text = re.sub(r"\\\n", "", text)
    lines = text.split("\n")[:-1]
    kept = []
    for line in lines:
        line = re.sub(r"\\(.)", r"\1", line).strip(" \t")
        if M1N1_OPTION.fullmatch(line):
            kept.append(line + "\n")
    return "".join(kept).encode()


def extract(candidates: Candidates, name: str, into: Path) -> Path:
    destination = into / name
    destination.mkdir()
    subprocess.run(["bsdtar", "-xpf", str(candidates.archive(name)), "-C", str(destination),
                    "--exclude", ".PKGINFO", "--exclude", ".BUILDINFO", "--exclude", ".MTREE",
                    "--exclude", ".INSTALL", "--exclude", ".CHANGELOG"], check=True)
    return destination


def check_candidate_files(root: Path, candidates: Candidates, report: dict) -> str:
    """Every file every runtime and boot package of the set carries is in the
    image with the set's bytes. The closure's packages are held to the set's
    versions and archives (candidate-versions, PROVENANCE): the runtime may
    change their files, as it restyles the Yaru icons."""
    counts, changed = 0, []
    planned = sorted(name for name, p in candidates.packages.items() if p.get("group", "runtime") != "closure")
    with tempfile.TemporaryDirectory(prefix="inspect-") as scratch:
        for name in planned:
            unpacked = extract(candidates, name, Path(scratch))
            for directory, subdirectories, files in os.walk(unpacked):
                # os.walk lists a link to a directory with the directories and never follows it.
                links = [name for name in subdirectories if Path(directory, name).is_symlink()]
                for file in (*files, *links):
                    source = Path(directory, file)
                    relative = source.relative_to(unpacked)
                    installed = root / relative
                    counts += 1
                    if source.is_symlink():
                        if not installed.is_symlink() or os.readlink(installed) != os.readlink(source):
                            changed.append(f"/{relative} ({name}, link)")
                    elif (installed.is_symlink() or not installed.is_file()
                            or installed.stat().st_size != source.stat().st_size
                            or installed.read_bytes() != source.read_bytes()):
                        changed.append(f"/{relative} ({name})")
                    elif stat.S_IMODE(installed.stat().st_mode) & 0o7555 != stat.S_IMODE(source.stat().st_mode) & 0o7555:
                        changed.append(f"/{relative} ({name}, mode)")
            subprocess.run(["rm", "-rf", str(unpacked)], check=True)
    report["candidate_files"] = counts
    require(not changed, f"{len(changed)} files differ from the set: " + ", ".join(sorted(changed)[:12]))
    return f"all {counts} files and links of the {len(planned)} runtime and boot packages carry the set's bytes and modes"


def mtree_digests(root: Path, package: str) -> dict[str, str]:
    """The sha256 the local pacman database recorded for each of PACKAGE's files at install."""
    entries = [e for e in (root / "var/lib/pacman/local").iterdir() if (e / "desc").is_file()
               and e.name.rsplit("-", 2)[0] == package]
    require(len(entries) == 1, f"{package} is not installed once")
    digests = {}
    for line in gzip.decompress((entries[0] / "mtree").read_bytes()).decode().splitlines():
        if not line.startswith("./") or "sha256digest=" not in line:
            continue
        path = line.split(" ", 1)[0][2:]
        digests[limine.unescape_mtree(path)] = re.search(r"sha256digest=([0-9a-f]{64})", line)[1]
    return digests


def check_supported_models(root: Path, candidates: Candidates, report: dict) -> str:
    """Every Mac U-Boot supports has its Aurora device tree in stage 2."""
    kernel_dtbs = {PurePosixPath(p).name for p in candidates.dtbs()}
    models = sorted(PurePosixPath(p).name for p in candidates.listing("uboot-asahi")
                    if PurePosixPath(p).match("usr/lib/asahi-boot/dtb/*.dtb"))
    require(models, "the set's U-Boot names no Mac")
    missing = [name for name in models if name not in kernel_dtbs]
    require(not missing, "the Aurora kernel lacks device trees for " + ", ".join(missing))
    report["supported_models"] = [name.removesuffix(".dtb") for name in models]
    return f"{len(models)} Macs: " + " ".join(name.removesuffix(".dtb") for name in models)


def check_limine(root: Path, candidates: Candidates, report: dict) -> str:
    sections = limine.validate_artifacts(root, KERNEL)
    release = candidates.kernel_release()
    require(sections[".linux"] == candidates.member(KERNEL, f"usr/lib/modules/{release}/vmlinuz"),
            "the UKI's kernel is not the set's")
    report["uki"] = {"release": release, "initramfs_bytes": len(sections[".initrd"]),
                     "cmdline": sections[".cmdline"].rstrip(b"\0 \n").decode(errors="replace")}
    return f"Limine at BOOTAA64.EFI boots omarchy_{KERNEL}.efi ({release}) with the set's kernel"


def check_embedded_initramfs(root: Path, report: dict) -> str:
    sections = limine.pe_sections(root / f"boot/efi/EFI/Linux/omarchy_{KERNEL}.efi")
    count = limine.validate_initramfs(sections.get(".initrd") or b"")
    report["initramfs_members"] = count
    return f"{count} members, including the encryption and vendor firmware units and their activation links"


def plymouth_theme(config: bytes | None, defaults: bytes | None) -> str | None:
    """The theme plymouthd shows: [Daemon] Theme= in plymouthd.conf, else in the
    packaged defaults. A file naming two themes names none."""
    for text in (config, defaults):
        themes, section = set(), None
        for line in (text or b"").decode(errors="replace").splitlines():
            line = line.strip()
            if line.startswith("[") and line.endswith("]"):
                section = line[1:-1].strip()
            elif section == "Daemon" and "=" in line and line.split("=", 1)[0].strip() == "Theme":
                themes.add(line.split("=", 1)[1].strip())
        if themes:
            return themes.pop() if len(themes) == 1 else None
    return None


def optional_bytes(path: Path) -> bytes | None:
    return limine.regular(path) if path.exists() or path.is_symlink() else None


def check_boot_splash(root: Path, report: dict) -> str:
    """The encrypted Mac's unlock screen is Plymouth in the UKI's initramfs: the
    Omarchy theme, on a splash boot line that ignores the serial console."""
    theme = plymouth_theme(optional_bytes(root / PLYMOUTH_CONFIG), optional_bytes(root / PLYMOUTH_DEFAULTS))
    require(theme == PLYMOUTH_THEME, f"the image's Plymouth theme is {theme or 'unset'}, not {PLYMOUTH_THEME}")
    require((root / PLYMOUTH_THEME_FILE).is_file(), f"/{PLYMOUTH_THEME_FILE} is missing")
    sections = limine.pe_sections(root / f"boot/efi/EFI/Linux/omarchy_{KERNEL}.efi")
    words = sections.get(".cmdline", b"").rstrip(b"\0 \n").decode(errors="replace").split()
    missing = [word for word in SPLASH_WORDS if word not in words]
    require(not missing, "the UKI's command line lacks " + " ".join(missing))
    files = limine.initramfs_files(sections.get(".initrd") or b"",
                                   {PLYMOUTH_CONFIG, PLYMOUTH_DEFAULTS, PLYMOUTH_THEME_FILE})
    embedded = plymouth_theme(files.get(PLYMOUTH_CONFIG), files.get(PLYMOUTH_DEFAULTS))
    require(embedded == PLYMOUTH_THEME,
            f"the UKI's initramfs shows the {embedded or 'unset'} Plymouth theme, not {PLYMOUTH_THEME}")
    require(PLYMOUTH_THEME_FILE in files, f"the UKI's initramfs lacks /{PLYMOUTH_THEME_FILE}")
    report["plymouth_theme"] = embedded
    return f"Plymouth shows {PLYMOUTH_THEME} from the UKI's initramfs; the command line has " + " ".join(SPLASH_WORDS)


def is_subvolume(path: Path) -> bool:
    """A btrfs subvolume's root is inode 256 on a device of its own."""
    status = path.lstat()
    return stat.S_ISDIR(status.st_mode) and status.st_ino == 256 and status.st_dev != path.parent.lstat().st_dev


def check_snapshots(root: Path) -> str:
    """Snapper keeps its snapshots in a /.snapshots subvolume nested in @. A copy
    that flattened it leaves a plain directory, and snapper fails on the Mac."""
    snapshots = root / ".snapshots"
    queue = root / "var/lib/omarchy/image/deferred-steps"
    if snapshots.is_symlink() or snapshots.exists():
        require(snapshots.is_dir() and not snapshots.is_symlink(), "/.snapshots is not a directory")
        require(is_subvolume(snapshots), "/.snapshots is a plain directory, not a btrfs subvolume: the copy flattened it")
        require(not any(snapshots.iterdir()), "/.snapshots holds snapshots taken during the build")
        require((root / "etc/snapper/configs/root").is_file(), "/.snapshots has no snapper root configuration")
        return "/.snapshots is an empty btrfs subvolume under snapper's root configuration"
    steps = queue.read_text().split() if queue.is_file() and not queue.is_symlink() else []
    deferred = [step for step in steps if "snapshots" in PurePosixPath(step).name]
    require(deferred, "/.snapshots is missing and no deferred hardware step creates it")
    return f"/.snapshots is created on first boot by {deferred[0]}"


def check_maintenance(root: Path) -> str:
    owners = limine.local_owners(root)
    limine.validate_maintenance(root, owners)
    require(owners.get("usr/share/limine/BOOTAA64.EFI") == "limine", "BOOTAA64.EFI is not the limine package's")
    # limine is not in the set: its loader must be the bytes its pinned archive
    # installed (PROVENANCE traces that archive to the pinned database).
    recorded = mtree_digests(root, "limine").get("usr/share/limine/BOOTAA64.EFI")
    loader = hashlib.sha256(limine.regular(root / "usr/share/limine/BOOTAA64.EFI")).hexdigest()
    require(recorded == loader, "the installed Limine loader is not the one its package installed")
    return "the UKI rebuild, Limine redeploy and activation gate hooks come from their packages; Limine is its package's"


# The image's owner of its root-owned state; fixtures built unprivileged set their own.
OWNER_UID = 0


def root_owned(path: Path, mode: int) -> None:
    status = path.lstat()
    require(not stat.S_ISLNK(status.st_mode), f"{path} is a symlink")
    require(status.st_uid == OWNER_UID and status.st_gid == (0 if OWNER_UID == 0 else status.st_gid),
            f"{path} is not owned by root")
    require(stat.S_IMODE(status.st_mode) == mode, f"{path} is not mode {mode:o}")


def image_profile(profile: str, candidates: Candidates) -> str:
    """The profile the image records: lab, else test for a candidate-only set, else release."""
    if profile == "lab":
        return "lab"
    return "test" if candidates.summary.get("candidate_only") is True else "release"


def read_image_target(path: Path, known: tuple[str, ...] = TARGET_FIELDS) -> dict[str, str]:
    """KNOWN fields from a manifest read as the runtime reads it: comments and
    unknown keys ignored, any other line refused. Each known key appears once."""
    fields: dict[str, str] = {}
    # Lines end at a newline only, as the runtime's read -r splits them: a carriage
    # return stays in its value.
    with path.open(newline="") as stream:
        text = stream.read()
    for line in text.split("\n"):
        if not line or line.startswith("#"):
            continue
        require("=" in line, f"/var/lib/omarchy/image/target is malformed: {line}")
        key, value = line.split("=", 1)
        if key in known:
            require(key not in fields, f"/var/lib/omarchy/image/target names {key} twice")
            fields[key] = value
    missing = [key for key in known if key not in fields]
    if all(key in missing for key in IDENTITY_FIELDS):
        missing = [key for key in missing if key not in IDENTITY_FIELDS]
    require(not missing, f"/var/lib/omarchy/image/target does not record {', '.join(missing)}")
    return fields


def read_target_keys(path: Path) -> set[str]:
    return {line.split("=", 1)[0] for line in path.read_text().split("\n") if "=" in line and not line.startswith("#")}


def check_image_target(root: Path, candidates: Candidates, profile: str, report: dict) -> str:
    directory = root / "var/lib/omarchy/image"
    root_owned(directory, 0o755)
    path = directory / "target"
    require(path.is_file(), "/var/lib/omarchy/image/target is missing")
    root_owned(path, 0o644)
    known = candidates.target_fields()
    fields = read_image_target(path, known)
    require(fields["format"] == "1" and fields["platform"] == PLATFORM,
            f"/var/lib/omarchy/image/target does not name {PLATFORM}")
    if candidates.kind == "channel":
        require(not set(TARGET_FIELDS[2:4]) & set(read_target_keys(path)),
                "/var/lib/omarchy/image/target of a channel image names a candidate set")
    set_fields = candidates.target_set()
    name = next(iter(set_fields))
    require(CANDIDATE_SET_NAME.fullmatch(fields[name]) is not None
            and all(fields[key] == value for key, value in set_fields.items()),
            f"/var/lib/omarchy/image/target records another {candidates.kind} set")
    require(re.fullmatch(r"[0-9a-f]{40}", fields["builder_commit"]) is not None,
            "/var/lib/omarchy/image/target names no builder commit")
    require(fields["builder_tree_clean"] in ("true", "false"),
            "/var/lib/omarchy/image/target does not say whether the builder tree was clean")
    expected = image_profile(profile, candidates)
    require(fields["image_profile"] == expected, f"/var/lib/omarchy/image/target does not record the {expected} profile")
    report["image_target"] = {key: fields[key] for key in known
                              if key in fields and key not in ("format", "platform")}
    detail = (f"/var/lib/omarchy/image/target names {PLATFORM}, root-owned, {expected} image of "
              f"{fields[name]} from builder {fields['builder_commit'][:12]}")
    if "built" not in fields:
        return detail + ", built before images recorded their build identity"
    require(re.fullmatch(r"[0-9a-f]{64}", fields["package_set_sha256"]) is not None,
            "/var/lib/omarchy/image/target names no package set digest")
    require(build_time(fields["built"]), "/var/lib/omarchy/image/target names no UTC build time")
    return f"{detail}, package set {fields['package_set_sha256'][:12]}, built {fields['built']}"


def empty_marker(path: Path, what: str) -> None:
    require(path.is_file() and not path.is_symlink() and path.stat().st_size == 0, f"{what} is not armed")
    require(stat.S_IMODE(path.stat().st_mode) == 0o644, f"{what} is not mode 0644")


def check_first_boot(root: Path, report: dict) -> str:
    state = root / "var/lib/omarchy"
    empty_marker(state / "mac-first-boot/pending", "first boot")
    empty_marker(state / "provisioning/pending", "owner provisioning")
    gate = state / "limine.enabled"
    require(gate.is_file() and not gate.is_symlink(), "the Limine gate is missing")
    first_boot = limine.regular(root / "usr/lib/omarchy/mac-first-boot/omarchy-mac-first-boot").decode()
    steps = state / "mac-first-boot/deferred-steps"
    if f"'{LIMINE_STEP}'" in first_boot:
        require(steps.is_file() and not steps.is_symlink() and steps.read_text() == LIMINE_STEP + "\n",
                "deferred-steps is not the boot package's fresh-image contract")
        contract = "deferred-steps names the Limine leaf"
    else:
        require(not steps.exists(), "deferred-steps is written for a first boot that does not read it")
        contract = "no deferred-steps contract"
    for unit in ("omarchy-mac-first-boot.service", "omarchy-provision-owner.service"):
        require((root / "etc/systemd/system/multi-user.target.wants" / unit).is_symlink(), f"{unit} is not enabled")
    queue = state / "image/deferred-steps"
    if (root / "usr/bin/omarchy-provision-hardware").exists():
        require(queue.is_file() and (root / "etc/systemd/system/multi-user.target.wants/"
                                     "omarchy-provision-hardware.service").is_symlink(),
                "the runtime defers hardware setup but first boot has no queue to run")
        require(UNSIGNED_REPOSITORY_STEP not in queue.read_text().splitlines(),
                f"first boot would run {UNSIGNED_REPOSITORY_STEP}, which adds the unsigned [omarchy-aarch64]")
        report["hardware_setup"] = "deferred"
    else:
        require(not queue.exists(), "a hardware queue exists that this runtime never runs")
        report["hardware_setup"] = "build"
    return f"first boot and owner provisioning armed, Limine gate set, {contract}, hardware setup {report['hardware_setup']}"


def pacman_templates(root: Path, channel: str) -> tuple[str, Path, Path]:
    # The Apple template as build-mac-image picks it: the runtime's
    # aarch64-apple one, else omarchy-mac's, else an older runtime's
    # apple-silicon one, else an even older runtime's aarch64 one; and the
    # mirror list beside the runtime's aarch64-apple template, else its aarch64
    # one, per channel or single.
    runtime = root / "usr/share/omarchy/default/pacman"
    choices = (("the runtime's aarch64-apple", runtime / f"aarch64-apple/pacman-{channel}.conf"),
               ("omarchy-mac's apple-silicon", root / f"usr/share/omarchy-mac/pacman/pacman-{channel}.conf"),
               ("the runtime's apple-silicon", runtime / f"apple-silicon/pacman-{channel}.conf"),
               ("the runtime's aarch64", runtime / f"aarch64/pacman-{channel}.conf"))
    kind, template = next((choice for choice in choices if choice[1].is_file()), choices[-1])
    mirrorlist = next((path for path in (runtime / f"aarch64-apple/mirrorlist-{channel}",
                                         runtime / f"aarch64/mirrorlist-{channel}") if path.is_file()),
                      runtime / "mirrorlist-aarch64")
    return kind, template, mirrorlist


def check_pacman_config(root: Path, channel: str, candidates: Candidates) -> str:
    kind, template, mirrorlist = pacman_templates(root, channel)
    mirrors = "aarch64-apple" if mirrorlist.parent.name == "aarch64-apple" else "aarch64"
    require(template.is_file(), f"the image ships no Apple Silicon pacman configuration for {channel}")
    pinned = test_image_pin.pinned(candidates.summary)
    require((root / "etc/pacman.conf").read_bytes() == test_image_pin.render(limine.regular(template), pinned),
            f"/etc/pacman.conf is not {kind} {channel} configuration"
            + (" with the test image's pin" if pinned else ""))
    require((root / "etc/pacman.d/mirrorlist").read_bytes() == limine.regular(mirrorlist),
            f"/etc/pacman.d/mirrorlist is not the runtime's {mirrors} {channel} mirror list")
    return (f"{kind} {channel} pacman.conf and the runtime's {mirrors} mirror list"
            + (f"; test image pin: IgnorePkg = {' '.join(pinned)}" if pinned else ""))


def check_installed_system(root: Path, report: dict, candidates: Candidates) -> str:
    # A channel set's -dev desktop is its runtime, not a stray development package.
    verification = installed_system.verify(root, runtime_packages=candidates.runtime_names())
    report["installed_system"] = verification.checks
    require(not verification.failed, "installed-system checks failed: " + ", ".join(verification.failed))
    return f"{len(verification.checks)} installed-system checks"


def check_factory(factory: Path, root: Path, candidates: Candidates) -> str:
    sealed = factory / "var/lib/omarchy/factory-sealed"
    require(sealed.is_file() and not sealed.is_symlink(), "@factory is not sealed")
    body = sealed.read_text()
    require(body == "format=2\n" + "".join(f"{key}={value}\n" for key, value in candidates.target_set().items()),
            f"@factory records another {candidates.kind} set")
    for rel in ("var/lib/omarchy/mac-first-boot/pending", "var/lib/omarchy/mac-first-boot/deferred-steps",
                "var/lib/omarchy/provisioning/pending", "etc/pacman.d/gnupg", "boot/efi/omarchy/install.conf"):
        require(not (factory / rel).exists(), f"@factory carries /{rel}")
    for rel in ("var/lib/omarchy/image/target", "var/lib/omarchy/limine.enabled", "etc/default/limine"):
        require((factory / rel).is_file(), f"@factory lacks /{rel}")
    target = factory / "var/lib/omarchy/image/target"
    root_owned(target, 0o644)
    require(target.read_bytes() == (root / "var/lib/omarchy/image/target").read_bytes(),
            "@factory's image target is not the image's")
    return "sealed for the set, without fresh-image or owner state, keeping the image target and Limine setup"


def inspect(root: Path, candidates_dir: Path, channel: str, factory: Path | None = None,
            trust: Path = candidate_set.TRUST, profile: str = "release") -> dict:
    policy = candidate_set.load_policy(trust)
    candidates = Candidates(candidates_dir)
    report: dict = {
        "schema": 1,
        "kind": "apple-image-inspection",
        "set": candidates.summary["set"],
        "source_commit": candidates.summary["source_commit"],
        "signer": candidates.summary["signer"],
        **({"set_kind": "channel", "database_sha256": candidates.summary["database_sha256"]}
           if candidates.kind == "channel" else {}),
        "channel": channel,
        "checks": {},
    }
    checks = [
        ("candidate-versions", lambda: check_candidate_versions(root, candidates, report)),
        ("runtime-sources", lambda: check_runtime_sources(root, candidates, report)),
        ("minimum-versions", lambda: check_minimum_versions(root, policy)),
        ("refused-packages", lambda: check_refused(root, policy)),
        ("apple-packages", lambda: check_apple_packages(root, report)),
        ("installed-boot-payloads", lambda: check_installed_payloads(root, candidates)),
        ("candidate-files", lambda: check_candidate_files(root, candidates, report)),
        ("m1n1-stage2", lambda: m1n1_stage2(root, candidates, report)),
        ("aurora-device-trees", lambda: check_supported_models(root, candidates, report)),
        ("limine-uki", lambda: check_limine(root, candidates, report)),
        ("embedded-initramfs", lambda: check_embedded_initramfs(root, report)),
        ("boot-splash", lambda: check_boot_splash(root, report)),
        ("boot-maintenance", lambda: check_maintenance(root)),
        ("image-target", lambda: check_image_target(root, candidates, profile, report)),
        ("first-boot", lambda: check_first_boot(root, report)),
        ("snapshots", lambda: check_snapshots(root)),
        ("pacman-config", lambda: check_pacman_config(root, channel, candidates)),
        ("installed-system", lambda: check_installed_system(root, report, candidates)),
    ]
    if factory is not None:
        checks.append(("factory", lambda: check_factory(factory, root, candidates)))
    for identifier, check in checks:
        try:
            detail = check()
            report["checks"][identifier] = {"result": "passed", "detail": detail}
        except (InspectionError, limine.ContractError, OSError, ValueError, KeyError, IndexError, TypeError,
                zlib.error, subprocess.CalledProcessError) as error:
            report["checks"][identifier] = {"result": "failed", "detail": str(error)}
    report["failed_checks"] = sorted(k for k, v in report["checks"].items() if v["result"] != "passed")
    report["result"] = "failed" if report["failed_checks"] else "passed"
    return report


def write_report(report: dict, path: Path) -> None:
    text = json.dumps(report, indent=2, sort_keys=True) + "\n"
    tmp = path.with_name(path.name + ".partial")
    tmp.write_text(text)
    os.replace(tmp, path)
