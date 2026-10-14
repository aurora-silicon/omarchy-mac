"""The Apple image's Limine contract: what a finished image root must hold.

The builder activates Limine with the runtime's own leaves; this module only
reads the result. It checks the loader on the ESP against the installed
package, the UKI's sections against the kernel and the finalized defaults, the
menu entry that boots it, the initramfs the UKI embeds and the hooks that keep
all of it current on later updates. Standard library, plus bsdtar to list an
initramfs.
"""
from __future__ import annotations

import hashlib
import os
from pathlib import Path
import re
import shlex
import struct
import subprocess
import zlib

# Current systemd generates cryptsetup instance units at boot; no static
# systemd-cryptsetup@.service template ships in the pinned systemd package.
# Require the generator, its actual executable target and activation target.
INITRD_EXECUTABLES = (
    "usr/lib/systemd/system-generators/systemd-cryptsetup-generator",
    "usr/bin/systemd-cryptsetup",
)
INITRD_FILES = (
    *INITRD_EXECUTABLES,
    "usr/lib/omarchy/initcpio/omarchy-mac-encrypt",
    "usr/lib/systemd/system/omarchy-mac-encrypt.service",
    "usr/lib/systemd/system/cryptsetup.target",
    r"usr/lib/systemd/system/run-systemd-cryptsetup-keydev\x2droot.mount.d/omarchy-mac-encrypt.conf",
    "usr/lib/omarchy/initcpio/omarchy-vendorfw-initrd.sh",
    "usr/lib/systemd/system/omarchy-vendorfw-initrd.service",
    "usr/lib/systemd/system/omarchy-vendorfw.service",
    "usr/lib/systemd/system/systemd-cryptsetup@.service.d/omarchy-vendorfw-initrd.conf",
)
INITRD_LINKS = {
    "usr/lib/systemd/system/initrd-root-device.target.requires/omarchy-mac-encrypt.service": "../omarchy-mac-encrypt.service",
    "usr/lib/systemd/system/initrd.target.wants/omarchy-vendorfw.service": "../omarchy-vendorfw.service",
    "usr/lib/systemd/system/cryptsetup-pre.target.wants/omarchy-vendorfw-initrd.service": "../omarchy-vendorfw-initrd.service",
    "usr/lib/systemd/system/initrd-root-device.target.wants/omarchy-vendorfw-initrd.service": "../omarchy-vendorfw-initrd.service",
    "usr/lib/systemd/system/sysinit.target.wants/omarchy-vendorfw-initrd.service": "../omarchy-vendorfw-initrd.service",
}
# The pacman hooks and helpers that rebuild the UKI and redeploy Limine on a
# later update, and the package each must come from.
MAINTENANCE_HOOKS = {
    "etc/pacman.d/hooks/90-mkinitcpio-install.hook": (
        "limine-mkinitcpio-hook",
        ("When = PostTransaction", "NeedsTargets",
         "Exec = /usr/share/libalpm/scripts/limine-apple-gate /usr/share/libalpm/scripts/limine-mkinitcpio-install")),
    "usr/share/libalpm/hooks/90-mkinitcpio-apple-install.hook": (
        "limine-mkinitcpio-hook",
        ("When = PostTransaction", "NeedsTargets",
         "Exec = /usr/share/libalpm/scripts/limine-apple-gate --mac /usr/share/libalpm/scripts/mkinitcpio install")),
    "etc/pacman.d/hooks/81-omarchy-mac-limine-deploy.hook": (
        None, ("Target = usr/share/limine/BOOTAA64.EFI", "When = PostTransaction",
               "Exec = /usr/bin/omarchy-mac-limine-deploy")),
    "usr/share/libalpm/hooks/91-omarchy-mac-boot-initramfs.hook": (
        "omarchy-mac-boot", ("Target = usr/lib/omarchy/initcpio/*",
                             "Exec = /usr/share/libalpm/scripts/mkinitcpio install", "NeedsTargets")),
}
MAINTENANCE_HELPERS = {
    "usr/share/libalpm/scripts/limine-apple-gate": "limine-mkinitcpio-hook",
    "usr/share/libalpm/scripts/limine-mkinitcpio-install": "limine-mkinitcpio-hook",
    "usr/bin/limine-update": "limine-mkinitcpio-hook",
    "usr/lib/omarchy/mac-boot/limine-ready": "omarchy-mac-boot",
    "etc/boot/hooks/pre.d/05-omarchy-mac-limine-gate": "omarchy-mac-boot",
    "usr/bin/omarchy-mac-limine-deploy": "omarchy-mac-boot",
    "usr/bin/omarchy-mac-limine-cmdline": "omarchy-mac-boot",
}


class ContractError(RuntimeError):
    pass


def regular(path: Path) -> bytes:
    if path.is_symlink() or not path.is_file():
        raise ContractError(f"boot input is not a regular file: {path}")
    data = path.read_bytes()
    if not data:
        raise ContractError(f"boot input is empty: {path}")
    return data


def pe_sections(path: Path) -> dict[str, bytes]:
    """Read bounded PE32+ ARM64 sections without executing artifact tools."""
    data = regular(path)
    if len(data) < 64 or data[:2] != b"MZ":
        raise ContractError(f"not a PE image: {path}")
    offset = struct.unpack_from("<I", data, 60)[0]
    if offset + 24 > len(data) or data[offset:offset + 4] != b"PE\0\0":
        raise ContractError(f"invalid PE header: {path}")
    machine, count = struct.unpack_from("<HH", data, offset + 4)
    optional_size = struct.unpack_from("<H", data, offset + 20)[0]
    table = offset + 24 + optional_size
    if (machine != 0xAA64 or not 1 <= count <= 96 or optional_size < 112
            or table + count * 40 > len(data)
            or struct.unpack_from("<H", data, offset + 24)[0] != 0x20B):
        raise ContractError(f"not a bounded ARM64 PE32+ image: {path}")
    sections = {}
    for index in range(count):
        entry = table + 40 * index
        name = data[entry:entry + 8].rstrip(b"\0").decode("ascii")
        size, _, raw_size, raw_offset = struct.unpack_from("<IIII", data, entry + 8)
        if name in sections or raw_offset + raw_size > len(data):
            raise ContractError(f"invalid PE section: {path}: {name}")
        # BSS has no file bytes. Required UKI sections below must be populated.
        if raw_size and raw_offset < table + count * 40:
            raise ContractError(f"truncated PE section: {path}: {name}")
        if name in (".linux", ".initrd", ".osrel", ".cmdline", ".uname") and size > raw_size:
            raise ContractError(f"truncated UKI section: {path}: {name}")
        sections[name] = data[raw_offset:raw_offset + min(size, raw_size)] if raw_size else b""
    return sections


def kernel_cmdline(root: Path) -> str:
    text = regular(root / "etc/default/limine").decode()
    lines = re.findall(r'^KERNEL_CMDLINE\[default\]="([^"\n]*)"$', text, re.M)
    if len(lines) != 1:
        raise ContractError("expected one generated Limine kernel command line")
    cmdline = lines[0]
    words = shlex.split(cmdline)
    target = root / "var/lib/omarchy/image/target"
    if target.exists() or target.is_symlink():
        profile = regular(target).decode()
        if re.search(r"^image_target_profile=neo-j700$", profile, re.M) and words.count("arm64.nowfxt") != 1:
            raise ContractError("Neo's UEFI kernel command line requires one arm64.nowfxt token")
    roots = [word for word in words if word.startswith("root=")]
    flags = [word for word in words if word.startswith("rootflags=")]
    if (len(roots) != 1 or not re.fullmatch(r"root=UUID=[0-9a-fA-F-]{36}", roots[0])
            or len(flags) != 1 or "subvol=@" not in flags[0][10:].split(",")
            or "rw" not in words or "rootfstype=btrfs" not in words
            or any(word.startswith(("rd.luks.", "cryptdevice=", "cryptkey=")) for word in words)):
        raise ContractError("fresh image has an unsafe or encrypted kernel command line")
    rows = [line.split() for line in regular(root / "etc/fstab").decode().splitlines()
            if line.strip() and not line.lstrip().startswith("#")]
    root_rows = [row for row in rows if len(row) >= 4 and row[1] == "/"]
    if len(root_rows) != 1 or roots[0][5:] != root_rows[0][0] or root_rows[0][2] != "btrfs":
        raise ContractError("UKI root does not match the target fstab")
    return cmdline


def kernel_release(root: Path, kernel: str) -> Path:
    modules = [path.parent for path in (root / "usr/lib/modules").glob("*/pkgbase")
               if regular(path).decode().strip() == kernel]
    if len(modules) != 1 or not re.fullmatch(r"[A-Za-z0-9._+-]+", modules[0].name):
        raise ContractError("UKI requires one installed kernel release")
    return modules[0]


def validate_artifacts(root: Path, kernel: str) -> dict[str, bytes]:
    """The loader, UKI and menu on the ESP; returns the UKI's sections."""
    esp = root / "boot/efi"
    packaged = root / "usr/share/limine/BOOTAA64.EFI"
    loader = esp / "EFI/BOOT/BOOTAA64.EFI"
    if regular(packaged) != regular(loader):
        raise ContractError("ESP loader differs from the installed Limine package")
    pe_sections(loader)
    uki_path = esp / f"EFI/Linux/omarchy_{kernel}.efi"
    sections = pe_sections(uki_path)
    modules = kernel_release(root, kernel)
    release = modules.name.encode()
    if sections.get(".uname") != release or regular(modules / "vmlinuz") != sections.get(".linux"):
        raise ContractError("UKI release differs from the installed kernel")
    if not sections.get(".initrd"):
        raise ContractError("UKI has no populated initramfs")
    # os-release may be the distro's intentional symlink into /usr/lib.
    os_release = root / "etc/os-release"
    if os_release.is_symlink():
        link = os.readlink(os_release)
        os_release = root / link.lstrip("/") if link.startswith("/") else os_release.parent / link
        if root.resolve() not in os_release.resolve().parents:
            raise ContractError("os-release escapes the image")
    # The mkinitcpio default-preset writer prepends the selected kernel release
    # and removes the distro VERSION_ID. Retain every other byte.
    expected_release = b"VERSION_ID=" + release + b"\n" + b"".join(
        line for line in regular(os_release).splitlines(keepends=True)
        if not line.startswith(b"VERSION_ID="))
    if sections.get(".osrel") != expected_release:
        raise ContractError("UKI os-release differs from installed release")
    expected_cmdline = kernel_cmdline(root)
    # mkinitcpio translates the single input line's newline to a space, then
    # appends its own newline and NUL. Do not discard arbitrary whitespace.
    if sections.get(".cmdline") != expected_cmdline.encode() + b" \n\0":
        raise ContractError("UKI command line differs from finalized defaults")
    menu = regular(esp / "limine.conf").decode()
    entry = re.search(r"^\s*//" + re.escape(kernel) + r"\s*\n((?:(?!\s*/).*(?:\n|$))*)", menu, re.M)
    path_match = re.search(r"^\s*path: boot\(\):/EFI/Linux/omarchy_" + re.escape(kernel)
                           + r"\.efi(?:#([a-fA-F0-9]{128}))?\s*$", entry[1], re.M) if entry else None
    if ("interface_branding: Omarchy Bootloader" not in menu or not entry
            or not re.search(r"^\s*protocol: efi\s*$", entry[1], re.M) or not path_match):
        raise ContractError("Limine menu does not boot the finalized UKI")
    if path_match[1] and path_match[1].lower() != hashlib.blake2b(regular(uki_path)).hexdigest():
        raise ContractError("Limine menu UKI verification hash differs")
    overrides = re.findall(r"^\s*cmdline:\s*(.*)$", entry[1], re.M)
    if overrides and overrides != [expected_cmdline]:
        raise ContractError("Limine menu overrides the verified UKI command line")
    if "machine-id=" in menu:
        raise ContractError("Limine menu carries the builder's machine identity")
    staging = esp / "omarchy"
    if staging.is_symlink() or not staging.is_dir() or any(staging.iterdir()):
        raise ContractError("installer ESP staging must be an empty directory")
    return sections


def initramfs_archives(archive: bytes) -> list[bytes]:
    """Every cpio in an initramfs, early uncompressed ones first."""
    archives: list[bytes] = []
    rest = archive
    while rest:
        rest = rest.lstrip(b"\0")
        if not rest:
            break
        if rest.startswith(b"070701") or rest.startswith(b"070702"):
            # An uncompressed early cpio: walk it to its trailer.
            end = rest.find(b"TRAILER!!!")
            if end < 0:
                raise ContractError("initramfs has an unterminated early archive")
            size = (end + len(b"TRAILER!!!") + 1 + 3) & ~3
            chunk, rest = rest[:size], rest[size:]
        else:
            chunk, rest = rest, b""
        archives.append(chunk)
    return archives


def _bsdtar(chunk: bytes, mode: str, *members: str) -> bytes:
    result = subprocess.run(["bsdtar", mode, "-f", "-", *members], input=chunk, capture_output=True,
                            env={**os.environ, "LC_ALL": "C"})
    if result.returncode != 0:
        raise ContractError("initramfs is not a readable archive: " + result.stderr.decode(errors="replace").strip())
    return result.stdout


def initramfs_listing(archive: bytes) -> list[str]:
    """bsdtar's verbose listing of every cpio in an initramfs, early ones included."""
    listing: list[str] = []
    for chunk in initramfs_archives(archive):
        listing += _bsdtar(chunk, "-tv").decode(errors="replace").splitlines()
    return listing


def initramfs_files(archive: bytes, wanted: set[str]) -> dict[str, bytes]:
    """The bytes of each WANTED regular file the initramfs carries; a later cpio
    overrides an earlier one, as the kernel unpacks them."""
    found: dict[str, bytes] = {}
    for chunk in initramfs_archives(archive):
        for name in _bsdtar(chunk, "-t").decode(errors="replace").splitlines():
            if unescape(name).removeprefix("./") in wanted:
                found[unescape(name).removeprefix("./")] = _bsdtar(chunk, "-xO", name)
    return found


_ESCAPES = {"\\": "\\", "a": "\a", "b": "\b", "f": "\f", "n": "\n", "r": "\r", "t": "\t", "v": "\v"}


def unescape(name: str) -> str:
    """Undoes bsdtar's escaping of listed names (a backslash is shown doubled)."""
    return re.sub(r"\\([\\abfnrtv]|[0-7]{3})",
                  lambda m: _ESCAPES.get(m[1]) or chr(int(m[1], 8)), name)


def unescape_mtree(name: str) -> str:
    """Undoes mtree's octal escapes (\\040 for a space)."""
    return re.sub(r"\\([0-7]{3})", lambda m: chr(int(m[1], 8)), name)


def validate_initramfs(archive: bytes) -> int:
    """The embedded initramfs carries the boot package's hooks; returns its member count."""
    listing = initramfs_listing(archive)
    members = {}
    for line in listing:
        fields = line.split(None, 8)
        if len(fields) < 9:
            continue
        name = fields[8]
        target = None
        if " -> " in name:
            name, target = name.split(" -> ", 1)
        members[unescape(name).removeprefix("./")] = (fields[0], target and unescape(target))
    for required in (*INITRD_FILES, *INITRD_LINKS):
        if required not in members:
            raise ContractError(f"the embedded initramfs lacks {required}")
    for name in INITRD_EXECUTABLES:
        mode = members[name][0]
        if not (mode.startswith("-") and mode[3] == "x"):
            raise ContractError(f"the embedded initramfs cryptsetup binary is not executable: {name}")
    for name, target in INITRD_LINKS.items():
        mode, actual = members[name]
        if not mode.startswith("l") or actual != target:
            raise ContractError(f"the embedded initramfs activation link is invalid: {name}")
    return len(members)


def local_owners(root: Path) -> dict[str, str]:
    """Every file path the local pacman database lists, and its package."""
    owners: dict[str, str] = {}
    for entry in (root / "var/lib/pacman/local").iterdir():
        desc, files = entry / "desc", entry / "files"
        if not desc.is_file() or not files.is_file():
            continue
        lines = desc.read_text().splitlines()
        name = lines[lines.index("%NAME%") + 1]
        section = None
        for line in files.read_text().splitlines():
            if line.startswith("%") and line.endswith("%"):
                section = line
            elif section == "%FILES%" and line and not line.endswith("/"):
                owners[line] = name
    return owners


def validate_maintenance(root: Path, owners: dict[str, str]) -> None:
    for rel, (owner, required) in MAINTENANCE_HOOKS.items():
        lines = {line.strip() for line in regular(root / rel).decode().splitlines()}
        if not set(required) <= lines:
            raise ContractError(f"boot maintenance hook is incomplete: {rel}")
        if owner and owners.get(rel) != owner:
            raise ContractError(f"boot maintenance hook {rel} is not owned by {owner}")
    for rel, owner in MAINTENANCE_HELPERS.items():
        regular(root / rel)
        if not os.access(root / rel, os.X_OK):
            raise ContractError(f"boot maintenance helper is not executable: {rel}")
        if owners.get(rel) != owner:
            raise ContractError(f"boot maintenance helper {rel} is not owned by {owner}")


def gunzip_prefix(data: bytes) -> tuple[bytes, bytes]:
    """Decompresses one gzip member at the start of DATA; returns it and what follows."""
    decompressor = zlib.decompressobj(wbits=31)
    try:
        output = decompressor.decompress(data)
    except zlib.error as error:
        raise ContractError(f"m1n1 stage 2 has no readable U-Boot gzip stream: {error}") from error
    if not decompressor.eof:
        raise ContractError("m1n1 stage 2 ends inside U-Boot's gzip stream")
    return output, decompressor.unused_data

