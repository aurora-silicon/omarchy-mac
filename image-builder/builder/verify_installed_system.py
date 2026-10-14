#!/usr/bin/env python3
"""Validate the installed-system configuration of a built Apple Silicon image.

Runs against the finalized root tree, mounted read-only or extracted. Every
check here corresponds to a way a built image installed fine but broke on
first use:

- /etc/pacman.conf missing [asahi-alarm] broke Apple package updates;
- a build-only repository or file:// server left in pacman.conf broke them too;
- a SigLevel with TrustAll lets pacman install packages signed by keys nobody
  trusts, which the unsigned [omarchy-aarch64] fork repository relied on;
- speakersafetyd left disabled keeps the built-in speakers silent;
- without alsa-ucm-conf-asahi and asahi-audio the default sink is
  stereo-fallback, not the model's DSP convolver;
- without vulkan-asahi the deferred Vulkan step tried to install it on a
  first boot with no package databases, often offline, and stopped every
  hardware step after it;
- asahi-bless older than 0.4.4 cannot handle Neo's 29-bank NVRAM;
- bluetooth.service left disabled leaves Bluetooth off;
- NetworkManager without the iwd backend leaves Apple Wi-Fi unmanaged.

Emits canonical JSON evidence on stdout and exits non-zero when any check
fails. Standard library only.
"""

from __future__ import annotations

import argparse
import configparser
import json
import re
import sys
from pathlib import Path

REQUIRED_PACMAN_SECTIONS = ("asahi-alarm", "core", "extra", "alarm", "aur", "omarchy")
# Repositories an image must never be left pointing at: the mx-mac fork's
# channels and the builder's own candidate repository.
FORBIDDEN_PACMAN_SECTIONS = ("omarchy-aurora", "omarchy-aarch64", "omarchy-candidates")
REQUIRED_PACKAGES = (
    "linux-aurora",
    "m1n1-aurora",
    "uboot-asahi",
    "omarchy",
    "omarchy-settings",
    "omarchy-mac",
    "omarchy-mac-boot",
    "limine",
    "limine-mkinitcpio-hook",
    "limine-snapper-sync",
    "asahi-fwextract",
    "speakersafetyd",
    "alsa-ucm-conf-asahi",
    "asahi-audio",
    "vulkan-asahi",
    "asahi-bless",
    "iwd",
    "networkmanager",
    "bluez",
    "wireplumber",
)
REQUIRED_MULTI_USER_UNITS = (
    "NetworkManager.service",
    "omarchy-vendor-firmware.service",
)


class Verification:
    def __init__(self) -> None:
        self.checks: dict[str, dict[str, str]] = {}

    def record(self, identifier: str, passed: bool, detail: str) -> None:
        if identifier in self.checks:
            raise RuntimeError(f"duplicate check identifier: {identifier}")
        self.checks[identifier] = {
            "result": "passed" if passed else "failed",
            "detail": detail,
        }

    @property
    def failed(self) -> list[str]:
        return sorted(
            identifier
            for identifier, check in self.checks.items()
            if check["result"] != "passed"
        )


def parse_pacman_sections(text: str) -> dict[str, list[str]]:
    sections: dict[str, list[str]] = {}
    current: list[str] | None = None
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        match = re.fullmatch(r"\[([^]]+)\]", stripped)
        if match:
            current = sections.setdefault(match.group(1), [])
            continue
        if current is not None:
            current.append(stripped)
    return sections


def check_pacman(verification: Verification, root: Path) -> None:
    config = root / "etc/pacman.conf"
    if not config.is_file():
        verification.record("pacman-conf-present", False, "/etc/pacman.conf is missing")
        return
    verification.record("pacman-conf-present", True, "/etc/pacman.conf exists")
    text = config.read_text(errors="replace")
    sections = parse_pacman_sections(text)

    missing = [name for name in REQUIRED_PACMAN_SECTIONS if name not in sections]
    verification.record(
        "pacman-required-repositories",
        not missing,
        "all required repositories configured" if not missing else "missing repositories: " + ", ".join(missing),
    )
    forbidden = [name for name in FORBIDDEN_PACMAN_SECTIONS if name in sections]
    verification.record(
        "pacman-no-fork-or-build-repositories",
        not forbidden,
        "no fork or build repository" if not forbidden else "configured: " + ", ".join(forbidden),
    )

    trust_all = [line.strip() for line in text.splitlines()
                 if "TrustAll" in line and not line.strip().startswith("#")]
    verification.record(
        "pacman-no-trust-all",
        not trust_all,
        "no SigLevel trusts every key" if not trust_all else "TrustAll: " + "; ".join(trust_all),
    )

    asahi_servers = [line for line in sections.get("asahi-alarm", []) if line.startswith("Server")]
    verification.record(
        "pacman-asahi-alarm-server",
        any("https://github.com/asahi-alarm/" in line for line in asahi_servers),
        asahi_servers[0] if asahi_servers else "no Server entry under [asahi-alarm]",
    )

    build_only = re.search(r"^\s*Server\s*=\s*file://", text, flags=re.MULTILINE) or re.search(
        r"^\s*DisableSandbox", text, flags=re.MULTILINE)
    verification.record(
        "pacman-no-build-only-settings",
        not build_only,
        "no file:// servers or sandbox exceptions" if not build_only
        else "a build-only server or sandbox exception leaked into the image",
    )


def networkmanager_config(root: Path) -> configparser.ConfigParser:
    """NetworkManager's merged configuration: NetworkManager.conf, then the
    conf.d fragments by name, /etc/NetworkManager/conf.d shadowing
    /usr/lib/NetworkManager/conf.d."""
    fragments: dict[str, Path] = {}
    for directory in ("usr/lib/NetworkManager/conf.d", "etc/NetworkManager/conf.d"):
        for path in sorted((root / directory).glob("*.conf")):
            fragments[path.name] = path
    config = configparser.ConfigParser(interpolation=None, strict=False)
    main = root / "etc/NetworkManager/NetworkManager.conf"
    if main.is_file():
        config.read_string(main.read_text(errors="replace"))
    for name in sorted(fragments):
        path = fragments[name]
        if path.is_symlink() and str(path.readlink()) == "/dev/null":
            continue
        config.read_string(path.read_text(errors="replace"))
    return config


def check_network(verification: Verification, root: Path) -> None:
    try:
        config = networkmanager_config(root)
        backends = {section: config.get(section, "wifi.backend") for section in config.sections()
                    if section.startswith("device") and config.has_option(section, "wifi.backend")}
        valid = config.get("device", "wifi.backend", fallback="") == "iwd" and set(backends.values()) == {"iwd"}
    except (OSError, configparser.Error):
        valid = False
    verification.record("network-wifi-backend-iwd", valid,
                        "effective NetworkManager configuration must select iwd without a conflicting device override")


BLUETOOTH_STEP = "install/hardware/bluetooth.sh"


def deferred_steps(root: Path) -> list[str]:
    """The hardware steps an image queued for the Mac's first boot (omacom/omarchy-mac#528)."""
    queue = root / "var/lib/omarchy/image/deferred-steps"
    if queue.is_symlink() or not queue.is_file():
        return []
    return queue.read_text(errors="replace").splitlines()


def check_enabled_units(verification: Verification, root: Path) -> None:
    system = root / "etc/systemd/system"
    wants = system / "multi-user.target.wants"
    for unit in REQUIRED_MULTI_USER_UNITS:
        link = wants / unit
        verification.record(
            f"unit-enabled-{unit.removesuffix('.service')}",
            link.is_symlink() or link.is_file(),
            f"{unit} enabled in multi-user.target" if link.is_symlink() or link.is_file() else f"{unit} is not enabled",
        )

    speaker = [wants / "speakersafetyd.service" for wants in system.glob("*.target.wants")
               if (wants / "speakersafetyd.service").is_symlink()]
    verification.record("unit-enabled-speakersafetyd", bool(speaker),
                        "speakersafetyd.service is enabled" if speaker else "speakersafetyd.service is not enabled")

    bluetooth_alias = system / "dbus-org.bluez.service"
    bluetooth_wants = system / "bluetooth.target.wants/bluetooth.service"
    bluetooth_enabled = bluetooth_alias.is_symlink() or bluetooth_wants.is_symlink() or bluetooth_wants.is_file()
    # An image with deferred hardware setup enables it on the Mac's first boot.
    bluetooth_deferred = not bluetooth_enabled and BLUETOOTH_STEP in deferred_steps(root)
    verification.record(
        "unit-enabled-bluetooth",
        bluetooth_enabled or bluetooth_deferred,
        "bluetooth.service is enabled" if bluetooth_enabled
        else f"bluetooth.service is enabled on first boot by the deferred {BLUETOOTH_STEP}" if bluetooth_deferred
        else "bluetooth.service is not enabled",
    )

    firmware_unit = system / "omarchy-vendor-firmware.service"
    firmware_text = firmware_unit.read_text(errors="replace") if firmware_unit.is_file() else ""
    verification.record(
        "unit-vendor-firmware-content",
        "/boot/efi/vendorfw/firmware.tar" in firmware_text,
        "vendor firmware unit extracts the ESP firmware archive"
        if "/boot/efi/vendorfw/firmware.tar" in firmware_text
        else "omarchy-vendor-firmware.service is missing or does not reference vendorfw",
    )


def installed_package_names(root: Path) -> set[str]:
    return set(installed_provides(root))


def installed_provides(root: Path) -> dict[str, set[str]]:
    """Each installed package's name and the names it provides, without versions."""
    database = root / "var/lib/pacman/local"
    packages: dict[str, set[str]] = {}
    if not database.is_dir():
        return packages
    for entry in database.iterdir():
        desc = entry / "desc"
        if desc.is_file():
            lines = desc.read_text().splitlines()
            provides = set()
            if "%PROVIDES%" in lines:
                for line in lines[lines.index("%PROVIDES%") + 1:]:
                    if not line:
                        break
                    provides.add(re.split(r"[<>=]", line, maxsplit=1)[0])
            packages[lines[lines.index("%NAME%") + 1]] = provides
    return packages


def check_packages(verification: Verification, root: Path, runtime_packages: frozenset[str] = frozenset()) -> None:
    """RUNTIME_PACKAGES are the image's runtime named apart from their role (a
    channel image's omarchy-dev provides omarchy): they fill the roles they
    provide and are not stray development packages. No other package fills a
    required name by providing it."""
    packages = installed_provides(root)
    installed = set(packages)
    filled = installed | {role for name in runtime_packages & installed for role in packages[name]}
    # Exact Aurora replacements only. An arbitrary package claiming a required
    # role must not satisfy image inspection. Candidate signature/source checks
    # still happen independently before this installed-system check.
    replacements = {
        "aura": {"m1n1-aurora"}, "uboot-aurora": {"uboot-asahi"},
        "mesa-aurora": {"mesa"}, "vulkan-asahi-aurora": {"vulkan-asahi"},
        "aurora-bless": {"asahi-bless"},
        "asahi-audio-aurora": {"asahi-audio"},
        "alsa-ucm-conf-asahi-aurora": {"alsa-ucm-conf-asahi"},
    }
    for name, roles in replacements.items():
        if name in installed:
            filled.update(roles & packages[name])
    missing = [name for name in REQUIRED_PACKAGES if name not in filled]
    verification.record(
        "packages-required-present",
        not missing,
        f"all {len(REQUIRED_PACKAGES)} required packages installed" if not missing
        else "missing packages: " + ", ".join(missing),
    )
    legacy = sorted(({"linux-asahi", "omarchy-apple-boot", "omarchy-first-boot", "omarchy-dev",
                      "omarchy-settings-dev"} - runtime_packages) & installed)
    verification.record("packages-no-legacy", not legacy,
                        "no legacy or development package" if not legacy else "installed: " + ", ".join(legacy))
    versions = []
    for desc in (root / "var/lib/pacman/local").glob("*/desc"):
        fields = desc.read_text().splitlines()
        if "%NAME%" in fields and fields[fields.index("%NAME%") + 1] in ("asahi-bless", "aurora-bless"):
            if "%VERSION%" in fields:
                versions.append(fields[fields.index("%VERSION%") + 1])
    match = re.match(r"^(?:\d+:)?(\d+)\.(\d+)(?:\.(\d+))?", versions[0]) if len(versions) == 1 else None
    version = tuple(int(part or "0") for part in match.groups()) if match else (0, 0, 0)
    verification.record(
        "asahi-bless-neo-nvram",
        version >= (0, 4, 4),
        "asahi-bless 0.4.4 or newer is required for Neo's 29-bank NVRAM; installed: "
        + (", ".join(versions) or "missing"),
    )


def check_identity(verification: Verification, root: Path) -> None:
    version_file = root / "usr/share/omarchy/version"
    version = version_file.read_text(errors="replace").strip() if version_file.is_file() else ""
    verification.record(
        "omarchy-version",
        version.startswith("4."),
        f"Omarchy version {version}" if version else "version file is missing",
    )


def verify(root: Path, runtime_packages=frozenset()) -> Verification:
    verification = Verification()
    check_pacman(verification, root)
    check_network(verification, root)
    check_enabled_units(verification, root)
    check_packages(verification, root, frozenset(runtime_packages))
    check_identity(verification, root)
    return verification


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root-tree", required=True, type=Path)
    arguments = parser.parse_args()

    if not arguments.root_tree.is_dir():
        print(f"ERROR: root tree is not a directory: {arguments.root_tree}", file=sys.stderr)
        return 2

    verification = verify(arguments.root_tree)
    evidence = {
        "schema_version": 2,
        "verification_kind": "apple-installed-system-config-v2",
        "root_tree": str(arguments.root_tree),
        "checks": verification.checks,
        "failed_checks": verification.failed,
        "result": "failed" if verification.failed else "passed",
    }
    json.dump(evidence, sys.stdout, sort_keys=True, indent=2)
    sys.stdout.write("\n")

    if verification.failed:
        print("ERROR: installed-system validation failed: " + ", ".join(verification.failed), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
