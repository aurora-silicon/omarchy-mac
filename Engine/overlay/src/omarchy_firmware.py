# SPDX-License-Identifier: MIT
"""Which macOS OS firmware a Mac gets, and the stub size it needs.

Upstream choose_ipsw prints, prompts and exits. The engine must size the
stub before that runs, so the filtering lives here as pure functions and
choose_ipsw keeps only its prompts.
"""

TARGET = "apple-silicon-full-os"
MACOS26 = "26.0"


def available_ipsws(
    ipsw_versions,
    chip_min_versions,
    sysinfo,
    device,
    supported_fw,
    expert,
    version_key,
):
    """Return upstream's (minver, avail), both in ipsw_versions order.

    minver holds the versions this Mac and payload may use at all; avail
    those its current system firmware can boot. Non-expert installs take
    the last element of avail.
    """
    sys_iboot = version_key(sysinfo.sys_firmware)
    sys_macos = version_key(sysinfo.macos_ver)
    sys_sfr = version_key(sysinfo.sfr_full_ver)
    chip_min = version_key(chip_min_versions.get(sysinfo.chip_id, "0"))
    device_min = version_key(device.min_ver)
    minver = [
        ipsw for ipsw in ipsw_versions
        if version_key(ipsw.version) >= max(chip_min, device_min)
        and (supported_fw is None or ipsw.version in supported_fw)
        and (ipsw.devices is None or sysinfo.device_class in ipsw.devices)
    ]
    avail = [
        ipsw for ipsw in minver
        if version_key(ipsw.min_iboot) <= sys_iboot
        and version_key(ipsw.min_macos) <= sys_macos
        and version_key(ipsw.min_sfr) <= sys_sfr
        and (not ipsw.expert_only or expert)
    ]
    return minver, avail


def target_supported_fw(metadata):
    """The supported_fw list of the one Omarchy full-OS template."""
    templates = [
        template
        for template in metadata.get("os_list", [])
        if template.get("omarchy_target") == TARGET
    ]
    if len(templates) != 1:
        return None
    return templates[0].get("supported_fw")


def default_ipsw(
    ipsw_versions,
    chip_min_versions,
    sysinfo,
    device,
    metadata,
    version_key,
):
    """The firmware a non-expert install would choose, or None."""
    _, avail = available_ipsws(
        ipsw_versions,
        chip_min_versions,
        sysinfo,
        device,
        target_supported_fw(metadata),
        False,
        version_key,
    )
    return avail[-1] if avail else None


def stub_size(
    ipsw_versions,
    chip_min_versions,
    sysinfo,
    device,
    metadata,
    version_key,
    *,
    default_size,
    macos26_size,
):
    """A stub made from macOS 26 firmware needs the larger size.

    That is every Mac whose chip needs macOS 26, and any other Mac whose
    payload makes macOS 26 firmware the default choice.
    """
    chip_min = chip_min_versions.get(sysinfo.chip_id, "0")
    if version_key(chip_min) >= version_key(MACOS26):
        return macos26_size
    try:
        ipsw = default_ipsw(
            ipsw_versions,
            chip_min_versions,
            sysinfo,
            device,
            metadata,
            version_key,
        )
    except (AttributeError, TypeError, ValueError):
        # An unreadable firmware version (upstream reads a missing SFR
        # RestoreVersion.plist as None) keeps the size this Mac always had;
        # choose_ipsw reports the problem when the install needs firmware.
        ipsw = None
    if ipsw is not None and version_key(ipsw.version) >= version_key(MACOS26):
        return macos26_size
    return default_size
