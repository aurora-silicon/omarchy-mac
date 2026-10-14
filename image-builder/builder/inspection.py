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
import shutil
import tarfile
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
IDENTITY_FIELDS = ("package_set_sha256", "built")
TARGET_PROFILE_FIELDS = ("image_target_profile", "board")
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
    """The frozen, imported candidate set: import.json and its archives."""

    def __init__(self, directory: Path) -> None:
        self.directory = directory
        self.summary = json.loads((directory / "import.json").read_text())
        self.packages = {p["name"]: p for p in self.summary["packages"]}
        self._listings: dict[str, list[str]] = {}
        self._cache = tempfile.TemporaryDirectory(prefix="inspect-archives-")
        self._unpacked: dict[str, Path] = {}
        self._identities: dict[str, tuple] = {}

    def close(self) -> None:
        self._cache.cleanup()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()

    def unpacked(self, name: str) -> Path:
        archive = self.archive(name)
        info = archive.lstat()
        require(stat.S_ISREG(info.st_mode), "candidate archive is not regular")
        require(0 < info.st_size <= 8 * 1024**3, "candidate compressed archive exceeds inspection budget")
        identity = (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)
        if name in self._unpacked:
            require(identity == self._identities[name], "candidate archive changed during inspection")
            return self._unpacked[name]
        require(PurePosixPath(name).name == name and name not in (".", ".."), "unsafe package name")
        destination = Path(self._cache.name) / name
        destination.mkdir()
        snapshot = Path(self._cache.name) / (name + ".archive")
        try:
            with archive.open('rb') as source, snapshot.open('xb') as output:
                opened = os.fstat(source.fileno())
                require((opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns, opened.st_ctime_ns) == identity,
                        "candidate archive changed before snapshot")
                shutil.copyfileobj(source, output)
            require(candidate_set.digest(snapshot) == self.packages[name]['sha256'], "candidate archive hash differs from import")
            after = archive.lstat()
            require((after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns) == identity,
                    "candidate archive changed during snapshot")
            self._identities[name] = identity
            try:
                self._listings[name] = _unpack_archive(snapshot, destination)
            finally:
                snapshot.unlink()
            self._unpacked[name] = destination
            return destination
        except BaseException:
            shutil.rmtree(destination, ignore_errors=True)
            snapshot.unlink(missing_ok=True)
            self._identities.pop(name, None)
            self._listings.pop(name, None)
            self._unpacked.pop(name, None)
            raise

    def archive(self, name: str) -> Path:
        filename = self.packages[name]["filename"]
        require(PurePosixPath(filename).name == filename and filename not in (".", ".."), "unsafe candidate archive filename")
        return self.directory / filename

    def member(self, name: str, path: str) -> bytes:
        root = self.unpacked(name)
        relative = _archive_path(path)
        target = root / relative
        require(all(not parent.is_symlink() for parent in target.parents if parent == root or root in parent.parents),
                "candidate member follows a symlink")
        require(target.is_file() and not target.is_symlink(), "candidate member is not regular: " + path)
        return target.read_bytes()

    def listing(self, name: str) -> list[str]:
        self.unpacked(name)
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
    package. The installed package records it too."""
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


def check_apple_packages(root: Path, report: dict) -> str:
    """Every package the image's Apple list names is installed, reading the list
    build-mac-image took: omarchy-apple-silicon.packages, else an older
    runtime's omarchy-apple.packages, never a link."""
    path = next((root / name for name in candidate_set.APPLE_LISTS
                 if (root / name).is_file() and not (root / name).is_symlink()), None)
    require(path is not None,
            "the image ships no Apple package list (omarchy-apple-silicon.packages or omarchy-apple.packages)")
    names = [fields[0] for fields in map(str.split, path.read_text().splitlines())
             if fields and not fields[0].startswith("#")]
    require(bool(names), f"{path.name} names no package")
    versions = installed_versions(root)
    report["apple_package_list"] = path.name
    missing = [name for name in names if name not in versions]
    require(not missing, f"{path.name} names packages that are not installed: {' '.join(missing)}")
    return f"all {len(names)} packages of {path.name} installed"


def check_stock_packages(root: Path, policy: dict, report: dict) -> str:
    stock = candidate_set.stock_packages(policy)
    versions = installed_versions(root)
    for name, package in stock.items():
        require(versions.get(name) == package['version'], f"required stock package {name} is missing or has another version")
    report['required_stock_packages'] = stock
    return f"all {len(stock)} operator-required stock packages installed; archive provenance checked during build"


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
    if candidates.summary.get("image_target_profile") == "neo-j700":
        require(candidate_set.STAGE1_MAGIC not in m1n1, "the ESP Stage2 component carries a Stage1 config block")
        require(any(PurePosixPath(path).name == "t8140-j700.dtb" for path in candidates.dtbs()),
                "the Neo stage2 carries no package-owned J700 device tree")
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


def check_common_stage1(root: Path, candidates: Candidates, report: dict) -> str:
    source = candidates.member("m1n1-aurora", candidate_set.STAGE1_PATH)
    digest = candidate_set.bare_stage1(source)
    require(limine.regular(root / candidate_set.STAGE1_PATH) == source,
            "the installed bare Stage1 differs from the signed package")
    staged = limine.regular(root / "boot/efi/aurora/stage1.bin")
    require(staged == source, "the ESP common Stage1 differs from the signed package")
    report["common_stage1"] = {"sha256": digest, "bytes": len(source),
                              "config": "unfilled version 1; zero UUID/path and CRC sentinel"}
    return "bare common Stage1 equals its package; installer fills UUID/path and CRC without changing its length"


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


def _archive_path(path: str) -> str:
    path = path.removeprefix("./").rstrip("/")
    require(bool(path) and not path.startswith("/") and all(part not in ("", ".", "..") for part in path.split("/"))
            and "\\" not in path and "\x00" not in path, "unsafe candidate archive path")
    return path


def _unpack_archive(archive: Path, destination: Path) -> list[str]:
    # libarchive handles package compression once; tarfile only reads its plain
    # tar stream. Write regular bytes first, then links, never follow a link.
    names, link_paths, links, listing = set(), set(), [], []
    total = 0
    with tempfile.TemporaryFile() as errors:
        process = subprocess.Popen(["bsdtar", "-cPf", "-", "@" + str(archive)], stdout=subprocess.PIPE, stderr=errors)
        try:
            with tarfile.open(fileobj=process.stdout, mode="r|") as stream:
                for member in stream:
                    if member.name in (".", "./"):
                        continue
                    name = _archive_path(member.name)
                    require(name not in names, "duplicate candidate archive path")
                    names.add(name)
                    if not member.isdir():
                        listing.append(name)
                    require(member.size >= 0, "negative candidate archive member size")
                    total += member.size
                    require(len(names) <= 250000 and total <= 8 * 1024**3, "candidate archive exceeds inspection budget")
                    target = destination / name
                    require(not any(parent in link_paths for parent in target.parents),
                            "candidate path has a link parent")
                    if member.isdir():
                        target.mkdir(parents=True, exist_ok=True)
                        target.chmod(member.mode)
                    elif member.isfile():
                        target.parent.mkdir(parents=True, exist_ok=True)
                        with target.open('xb') as output:
                            shutil.copyfileobj(stream.extractfile(member), output)
                        target.chmod(member.mode)
                    elif member.issym() or member.islnk():
                        links.append((name, member.linkname, member.islnk()))
                        link_paths.add(target)
                    else:
                        raise InspectionError("unsupported candidate archive member type")
            require(process.wait() == 0, "could not read candidate archive")
            hardlinks = {name: link for name, link, hard in links if hard}
            active, resolved = set(), set()

            def resolve_hardlink(name, depth=0):
                if name in resolved:
                    return
                require(depth <= 256 and name not in active, "cyclic or excessive candidate hardlink chain")
                active.add(name)
                source_name = _archive_path(hardlinks[name])
                if source_name in hardlinks:
                    resolve_hardlink(source_name, depth + 1)
                source, target = destination / source_name, destination / name
                require(not any(parent in link_paths for parent in (*source.parents, *target.parents)),
                        "candidate hardlink has a link parent")
                require(source.is_file() and not source.is_symlink(), "unsafe candidate hardlink")
                target.parent.mkdir(parents=True, exist_ok=True)
                require(not target.exists(), "candidate link collides with another path")
                shutil.copy2(source, target)
                active.remove(name)
                resolved.add(name)

            for name in hardlinks:
                resolve_hardlink(name)
            for name, link, hard in links:
                if hard:
                    continue
                target = destination / name
                require(not any(parent in link_paths for parent in target.parents), "candidate link has a link parent")
                target.parent.mkdir(parents=True, exist_ok=True)
                require(not target.exists(), "candidate link collides with another path")
                target.symlink_to(link)
            return listing
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            process.stdout.close()


def check_candidate_files(root: Path, candidates: Candidates, report: dict) -> str:
    """Every file every runtime and boot package of the set carries is in the
    image with the set's bytes. The closure's packages are held to the set's
    versions and archives (candidate-versions, PROVENANCE): the runtime may
    change their files, as it restyles the Yaru icons."""
    counts, changed = 0, []
    planned = sorted(name for name, p in candidates.packages.items()
                     if p.get("group", "runtime") != "closure"
                     or name in ('aurora-sep', 'omarchy-apple-firmware-order'))
    for name in planned:
        unpacked = candidates.unpacked(name)
        for directory, subdirectories, files in os.walk(unpacked):
            # os.walk lists a link to a directory with the directories and never follows it.
            links = [name for name in subdirectories if Path(directory, name).is_symlink()]
            for file in (*files, *links):
                source = Path(directory, file)
                relative = source.relative_to(unpacked)
                if relative.parts[0] in (".PKGINFO", ".BUILDINFO", ".MTREE", ".INSTALL", ".CHANGELOG"):
                    continue
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
    report["candidate_files"] = counts
    require(not changed, f"{len(changed)} files differ from the set: " + ", ".join(sorted(changed)[:12]))
    family = 'runtime and boot'
    if any(name in planned for name in ('aurora-sep', 'omarchy-apple-firmware-order')):
        family = 'runtime, boot and firmware-ordering'
    return f"all {counts} files and links of the {len(planned)} {family} packages carry the set's bytes and modes"


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


def check_sep_firmware_order(root: Path, candidates: Candidates, report: dict) -> str:
    require('aurora-sep' in candidates.packages, 'the Neo firmware-ordering package requires the signed SEP package')
    alias = 'usr/lib/modprobe.d/aurora-sep-firmware-order.conf'
    dropin = 'usr/lib/systemd/system/aurora-sep.service.d/50-aurora-sep-vendor-firmware.conf'
    blacklist = limine.regular(root / alias)
    require(b'blacklist apple_sep' in blacklist.splitlines(), 'the SEP alias blacklist is missing')
    expected = b'[Unit]\nRequires=omarchy-vendor-firmware.service\nAfter=omarchy-vendor-firmware.service\n'
    require(limine.regular(root / dropin) == expected, 'SEP does not follow ordinary vendor firmware extraction')
    sections = limine.pe_sections(root / f'boot/efi/EFI/Linux/omarchy_{KERNEL}.efi')
    embedded = sections.get('.initrd') or b''
    expected_files = {alias: blacklist}
    for path in ('usr/lib/omarchy/initcpio/aurora-peripheral-firmware.sh',
                 'usr/lib/systemd/system/aurora-peripheral-firmware.service',
                 'usr/lib/modprobe.d/aurora-firmware-order.conf'):
        expected_files[path] = limine.regular(root / path)
    cryptsetup = 'usr/lib/systemd/system/systemd-cryptsetup@.service.d/aurora-vendor-order.conf'
    expected_files[cryptsetup] = limine.regular(root / 'usr/lib/omarchy/initcpio/aurora-vendor-order-cryptsetup.conf')
    files = limine.initramfs_files(embedded, set(expected_files))
    for path, expected_content in expected_files.items():
        require(files.get(path) == expected_content, f'the UKI initramfs lacks installed firmware ordering: {path}')
    links = {}
    for line in limine.initramfs_listing(embedded):
        fields = line.split(None, 8)
        if len(fields) == 9 and fields[0].startswith('l') and ' -> ' in fields[8]:
            name, destination = fields[8].split(' -> ', 1)
            links[limine.unescape(name).removeprefix('./')] = limine.unescape(destination)
    for target in ('sysinit.target', 'initrd-root-device.target'):
        link = f'usr/lib/systemd/system/{target}.wants/aurora-peripheral-firmware.service'
        require(links.get(link) == '../aurora-peripheral-firmware.service',
                f'the UKI initramfs lacks firmware activation link: {link}')
    root_dropin = 'usr/lib/systemd/system/omarchy-vendor-firmware.service.d/20-aurora-vendor-order.conf'
    require(limine.regular(root / root_dropin) == candidates.member('omarchy-apple-firmware-order', root_dropin),
            'the root vendor-firmware service lacks package-owned peripheral ordering')
    report['sep_firmware_order'] = 'package-owned alias blacklist in root and UKI; ordinary SEP unit follows vendor firmware'
    return report['sep_firmware_order']


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


def read_image_target(path: Path) -> dict[str, str]:
    """TARGET_FIELDS from a manifest read as the runtime reads it: comments and
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
        if key in (*TARGET_FIELDS, *TARGET_PROFILE_FIELDS):
            require(key not in fields, f"/var/lib/omarchy/image/target names {key} twice")
            fields[key] = value
    missing = [key for key in TARGET_FIELDS if key not in fields]
    if all(key in missing for key in IDENTITY_FIELDS):
        missing = [key for key in missing if key not in IDENTITY_FIELDS]
    require(not missing, f"/var/lib/omarchy/image/target does not record {', '.join(missing)}")
    return fields


def check_image_target(root: Path, candidates: Candidates, profile: str, report: dict,
                       target_profile: str = "generic") -> str:
    directory = root / "var/lib/omarchy/image"
    root_owned(directory, 0o755)
    path = directory / "target"
    require(path.is_file(), "/var/lib/omarchy/image/target is missing")
    root_owned(path, 0o644)
    fields = read_image_target(path)
    require(fields["format"] == "1" and fields["platform"] == PLATFORM,
            f"/var/lib/omarchy/image/target does not name {PLATFORM}")
    require(CANDIDATE_SET_NAME.fullmatch(fields["candidate_set"]) is not None
            and fields["candidate_set"] == candidates.summary["set"]
            and fields["candidate_source_commit"] == candidates.summary["source_commit"],
            "/var/lib/omarchy/image/target records another candidate set")
    require(re.fullmatch(r"[0-9a-f]{40}", fields["builder_commit"]) is not None,
            "/var/lib/omarchy/image/target names no builder commit")
    require(fields["builder_tree_clean"] in ("true", "false"),
            "/var/lib/omarchy/image/target does not say whether the builder tree was clean")
    expected = image_profile(profile, candidates)
    require(fields["image_profile"] == expected, f"/var/lib/omarchy/image/target does not record the {expected} profile")
    if target_profile == "generic":
        require(not any(key in fields for key in TARGET_PROFILE_FIELDS), "generic image carries a board-specific target")
    else:
        require(fields.get("image_target_profile") == target_profile
                and fields.get("board") == candidate_set.IMAGE_TARGET_PROFILES[target_profile]["board"],
                "image target board/profile differs from operator policy")
    report["image_target"] = {key: fields[key] for key in (*TARGET_FIELDS, *TARGET_PROFILE_FIELDS)
                              if key in fields and key not in ("format", "platform")}
    detail = (f"/var/lib/omarchy/image/target names {PLATFORM}, root-owned, {expected} image of "
              f"{fields['candidate_set']} from builder {fields['builder_commit'][:12]}")
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
    # The Apple template as build-mac-image picks it: omarchy-mac's, else an
    # older runtime's apple-silicon one, else an even older runtime's aarch64
    # one; and the runtime's aarch64 mirror list, per channel or single.
    runtime = root / "usr/share/omarchy/default/pacman"
    choices = (("omarchy-mac's apple-silicon", root / f"usr/share/omarchy-mac/pacman/pacman-{channel}.conf"),
               ("the runtime's apple-silicon", runtime / f"apple-silicon/pacman-{channel}.conf"),
               ("the runtime's aarch64", runtime / f"aarch64/pacman-{channel}.conf"))
    kind, template = next((choice for choice in choices if choice[1].is_file()), choices[-1])
    mirrorlist = runtime / f"aarch64/mirrorlist-{channel}"
    if not mirrorlist.is_file():
        mirrorlist = runtime / "mirrorlist-aarch64"
    return kind, template, mirrorlist


def check_pacman_config(root: Path, channel: str, candidates: Candidates) -> str:
    kind, template, mirrorlist = pacman_templates(root, channel)
    require(template.is_file(), f"the image ships no Apple Silicon pacman configuration for {channel}")
    pinned = test_image_pin.pinned(candidates.summary)
    require((root / "etc/pacman.conf").read_bytes() == test_image_pin.render(limine.regular(template), pinned, ensure_asahi=True),
            f"/etc/pacman.conf is not {kind} {channel} configuration"
            + (" with the test image's pin" if pinned else ""))
    require((root / "etc/pacman.d/mirrorlist").read_bytes() == limine.regular(mirrorlist),
            f"/etc/pacman.d/mirrorlist is not the runtime's aarch64 {channel} mirror list")
    return (f"{kind} {channel} pacman.conf and the runtime's aarch64 mirror list"
            + (f"; test image pin: IgnorePkg = {' '.join(pinned)}" if pinned else ""))


def check_installed_system(root: Path, report: dict) -> str:
    verification = installed_system.verify(root)
    report["installed_system"] = verification.checks
    require(not verification.failed, "installed-system checks failed: " + ", ".join(verification.failed))
    return f"{len(verification.checks)} installed-system checks"


def check_factory(factory: Path, root: Path, candidates: Candidates) -> str:
    sealed = factory / "var/lib/omarchy/factory-sealed"
    require(sealed.is_file() and not sealed.is_symlink(), "@factory is not sealed")
    body = sealed.read_text()
    require(body == f"format=2\ncandidate_set={candidates.summary['set']}\n"
                    f"candidate_source_commit={candidates.summary['source_commit']}\n",
            "@factory records another candidate set")
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
    with Candidates(candidates_dir) as candidates:
        return _inspect(root, candidates, channel, factory, trust, profile, policy)


def _inspect(root, candidates, channel, factory, trust, profile, policy):
    target_profile = candidate_set.image_target_profile(policy)
    require(candidates.summary.get("image_target_profile", "generic") == target_profile,
            "candidate import image target differs from operator policy")
    trust_fields = {'candidate_trust_policy_sha256': candidate_set.digest(trust / 'policy.json'),
                    'candidate_trust_public_key_sha256': policy['public_key_sha256']}
    if any(key in candidates.summary for key in trust_fields):
        require(all(candidates.summary.get(key) == value for key, value in trust_fields.items()),
                'inspection candidate trust differs from the imported policy or public key')
    report: dict = {
        "schema": 1,
        "kind": "apple-image-inspection",
        "set": candidates.summary["set"],
        "source_commit": candidates.summary["source_commit"],
        "signer": candidates.summary["signer"],
        **trust_fields,
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
        ("image-target", lambda: check_image_target(root, candidates, profile, report, target_profile)),
        ("first-boot", lambda: check_first_boot(root, report)),
        ("snapshots", lambda: check_snapshots(root)),
        ("pacman-config", lambda: check_pacman_config(root, channel, candidates)),
        ("installed-system", lambda: check_installed_system(root, report)),
    ]
    if candidate_set.stock_packages(policy):
        checks.append(("required-stock-packages", lambda: check_stock_packages(root, policy, report)))
    if target_profile == 'neo-j700' and 'omarchy-apple-firmware-order' in candidates.packages:
        checks.append(('sep-firmware-order', lambda: check_sep_firmware_order(root, candidates, report)))
    if target_profile != "generic":
        report["image_target_profile"] = target_profile
        checks.append(("common-stage1", lambda: check_common_stage1(root, candidates, report)))
    if factory is not None:
        checks.append(("factory", lambda: check_factory(factory, root, candidates)))
    for identifier, check in checks:
        try:
            detail = check()
            report["checks"][identifier] = {"result": "passed", "detail": detail}
        except (InspectionError, limine.ContractError, OSError, ValueError, KeyError, IndexError, TypeError,
                zlib.error, tarfile.TarError, subprocess.CalledProcessError) as error:
            report["checks"][identifier] = {"result": "failed", "detail": str(error)}
    report["failed_checks"] = sorted(k for k, v in report["checks"].items() if v["result"] != "passed")
    report["result"] = "failed" if report["failed_checks"] else "passed"
    return report


def write_report(report: dict, path: Path) -> None:
    text = json.dumps(report, indent=2, sort_keys=True) + "\n"
    tmp = path.with_name(path.name + ".partial")
    tmp.write_text(text)
    os.replace(tmp, path)
