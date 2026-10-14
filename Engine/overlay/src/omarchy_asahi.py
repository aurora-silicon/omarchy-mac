# SPDX-License-Identifier: MIT
"""Concrete stage-1 adapter over pinned upstream Asahi primitives."""

import collections
import contextlib
import hashlib
import io
import json
import logging
import os
import plistlib
import re
import stat
import shutil
import struct
import subprocess
import sys
import tempfile
import zipfile
import zlib
from pathlib import PurePosixPath

import asahi_firmware
import osinstall
import stub

import omarchy_apple_aea
import omarchy_mesa
import omarchy_mt7932
import omarchy_als
import omarchy_isp
import omarchy_recovery
import omarchy_planner
from omarchy_image import (
    WRITE_VERIFICATION, flush_device, hash_target, open_target, timing, write_image,
)


TARGET = "apple-silicon-full-os"
MAXIMUM_PASSWORD_BYTES = 1_024
MACHINE_OWNER_PATTERN = re.compile(r"^[A-Za-z0-9._-]{1,255}$")
INSTALLER_TITLE_PATTERN = re.compile(r"^[A-Za-z0-9 ._()-]{1,64}$")
VOLUME_GROUP_PATTERN = re.compile(r"^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$")
PARTITION_PATTERN = re.compile(r"^disk[0-9]+s[0-9]+$")
READBACK_CHUNK_BYTES = 1024 * 1024
# Where every macOS through 14 named its restore bundle in bootcaches.plist,
# and where macOS 26 still keeps it in Preboot, though its bless2 no longer
# names it.
RESTORE_BUNDLE_PATH = "./Restore"
# From macOS 15 the recovery image in a restore image is an Apple Encrypted
# Archive, which hdiutil cannot attach without Apple's key.
AEA_MAGIC = b"AEA1"


class AsahiAdapterError(RuntimeError):
    pass


def verify_default_boot(dutil, group_uuid):
    """Read back the selected APFS group; bless exit status is insufficient."""
    try:
        result = subprocess.run(
            ["/usr/sbin/bless", "--getBoot", "--plist"], check=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        selected = plistlib.loads(result.stdout).get("Boot Volume")
        if not isinstance(selected, str) or not selected:
            raise ValueError("missing startup volume")
        info = dutil.get("info", "-plist", selected)
        actual = info.get("APFSVolumeGroupID", "")
        if not isinstance(actual, str) or actual.upper() != group_uuid.upper():
            raise ValueError("another startup volume is selected")
    except (OSError, ValueError, TypeError, AttributeError, subprocess.CalledProcessError) as error:
        raise AsahiAdapterError(
            "Omarchy was not confirmed as the startup disk. Retry Recovery authorization."
        ) from error


# The Recovery setup that the stub's "Finish Installation" app opens in
# Terminal, replacing asahi-installer's step2.sh: the installer's own name, one
# password prompt and one confirmation. bputil and bless take the owner and
# password as arguments; kmutil has no credential options, so the script
# answers its prompts on a hidden terminal.
STEP2_SCRIPT = """#!/bin/sh
# SPDX-License-Identifier: MIT
# ##TITLE##, second step. Runs in the new install's own recoveryOS.

set -e

VGID="##VGID##"
PREBOOT="##PREBOOT##"
OWNER="##OWNER##"

self="$0"
cd "${self%%step2.sh}"
system_dir="$(cd ../../../; pwd)"
os_name="${system_dir##*/}"

BOLD="$(printf '\\033[1m')"
RST="$(printf '\\033[m')"

LOGS="/tmp/bp.txt /tmp/bless.log /tmp/bputil.log /tmp/bputil.status
/tmp/kmutil.log /tmp/kmutil.status /tmp/kmutil.pid /tmp/kmutil.done"
spinner_pid=""

# Stop the kmutil whose ID is in file $1, and wait until it is gone. A process
# that has since reused the ID is left alone.
stop_pid_in() {
    [ -s "$1" ] || return 0
    pid="$(cat "$1")"
    if command -v ps >/dev/null 2>&1; then
        case "$(ps -p "$pid" -o args= 2>/dev/null)" in
            *kmutil*configure-boot*) ;;
            *) return 0 ;;
        esac
    fi
    kill "$pid" 2>/dev/null || return 0
    waited=0
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$waited" -eq 20 ]; then
            kill -9 "$pid" 2>/dev/null || true
        fi
        sleep 0.1
        waited=$((waited + 1))
    done
}

# On any exit: stop what this script started, restore the terminal, and
# forget the password and the logs.
cleanup() {
    if [ -n "$spinner_pid" ]; then
        kill "$spinner_pid" 2>/dev/null || true
        spinner_pid=""
    fi
    stop_pid_in /tmp/kmutil.pid
    stty echo 2>/dev/null || true
    PASSWORD=""
    rm -f $LOGS
}
trap cleanup EXIT
# bputil runs in the foreground, so Ctrl-C reaches it. kmutil runs under
# script on a hidden terminal; cleanup stops it through its PID file.
trap 'echo; echo "Stopped. Run this again to finish setting up $os_name."; exit 130' INT TERM HUP

# Spin after the current line until file $1 exists. After $2 seconds, stop
# the process whose ID is in file $3, if one is given. Runs in the background.
spin_until() {
    spun=0
    printf ' '
    while [ ! -e "$1" ]; do
        if [ "$spun" -eq $(($2 * 4)) ] && [ -n "$3" ]; then
            stop_pid_in "$3"
        fi
        case $((spun % 4)) in
            0) c='|' ;;
            1) c='/' ;;
            2) c='-' ;;
            *) c='\\' ;;
        esac
        printf '\\b%s' "$c"
        sleep 0.25
        spun=$((spun + 1))
    done
    printf '\\b '
}

# Run the rest of the line with a spinner after the current line, which the
# caller ends. Its exit status lands in file $1; after $2 seconds the process
# in file $3 is stopped.
run_with_spinner() {
    status_file=$1
    deadline=$2
    pid_file=$3
    shift 3
    rm -f "$status_file"
    spin_until "$status_file" "$deadline" "$pid_file" &
    spinner_pid=$!
    status=0
    "$@" || status=$?
    echo "$status" >"$status_file"
    wait "$spinner_pid" 2>/dev/null || true
    spinner_pid=""
    return "$status"
}

bputil_now() {
    bputil -nc -v "$VGID" -u "$OWNER" -p "$PASSWORD" >/tmp/bputil.log 2>&1
}

read_password() {
    printf "Password for %s: " "$OWNER"
    stty -echo
    IFS= read -r PASSWORD
    stty echo
    echo
}

printf '\\033[2J\\033[H'
echo "${BOLD}##TITLE##${RST}"
echo

bputil -d -v "$VGID" >/tmp/bp.txt

if [ -z "$OWNER" ]; then
    printf "Your macOS user name: "
    read -r OWNER
fi

# Whether the startup disk is this Omarchy: bless names a volume of its group.
omarchy_is_startup() {
    boot="$(bless --getBoot 2>/dev/null)" || return 1
    [ -n "$boot" ] || return 1
    diskutil info "$boot" 2>/dev/null | grep -Eiq "^ *APFS Volume Group: +$VGID *\\$" && return 0
    [ "$boot" = "$(diskutil info "$system_dir" 2>/dev/null | sed -n 's/^ *Device Node: *//p')" ]
}

if ! grep -q ': Paired' /tmp/bp.txt; then
    if omarchy_is_startup; then
        echo "This step needs $os_name's own Recovery. $os_name is already the"
        echo "startup disk, so the next start opens it."
    else
        echo "This step needs $os_name's own Recovery. Making $os_name the startup"
        echo "disk so that the next start opens it."
        echo
        # bless takes the known owner and the password on stdin. It exits 0
        # even when it rejects the password, so check the startup disk instead.
        # After three failures, let bless ask on its own.
        tries=0
        while :; do
            read_password
            printf '%s\\n' "$PASSWORD" | bless --setBoot --mount "$system_dir" --user "$OWNER" --stdinpass >/tmp/bless.log 2>&1 || true
            if omarchy_is_startup; then
                break
            fi
            tries=$((tries + 1))
            if [ "$tries" -ge 3 ]; then
                echo "macOS asks itself now. Type your user name and password."
                until bless --setBoot --mount "$system_dir" && omarchy_is_startup; do
                    echo "That didn't work. Press Enter to try again."
                    read -r _
                done
                break
            fi
            echo "That password didn't work for $OWNER. Try again."
            echo
        done
        PASSWORD=""
    fi
    echo
    echo "Press Enter to shut down. Then hold the power button until you see"
    echo "'Loading startup options', choose $os_name, and log in."
    read -r _
    shutdown -h now
    exit 1
fi

if ! grep -q 'one true recoveryOS' /tmp/bp.txt; then
    echo "The power button was released too early to finish setting up."
    echo
    echo "Press Enter to shut down. Then hold the power button, without letting"
    echo "go, until you see 'Loading startup options', and choose $os_name."
    read -r _
    shutdown -h now
    exit 1
fi

echo "This lets $os_name start Linux by lowering the security level of"
echo "$os_name only. ${BOLD}macOS keeps Full Security.${RST}"
echo
# Ask before anything changes: bputil lowers the security level at once.
printf "Are you sure you want to do this? (y or n) "
read -r answer
case "$answer" in
    y|Y|yes|Yes|YES) ;;
    *)
        echo "Nothing was changed. Run this again when you're ready."
        exit 1
        ;;
esac
echo

tries=0
while :; do
    read_password
    printf "Updating %s's security settings..." "$os_name"
    if run_with_spinner /tmp/bputil.status 0 "" bputil_now; then
        echo
        break
    fi
    # Nothing was updated: replace that line. bputil's log opens with its own
    # disclaimer, so don't show it here.
    printf '\\r\\033[K'
    tries=$((tries + 1))
    if [ "$tries" -ge 3 ]; then
        echo "macOS asks itself now. Type your user name and password."
        while ! bputil -nc -v "$VGID"; do
            echo "That didn't work. Press Enter to try again."
            read -r _
        done
        # The typed password was rejected: never offer it to kmutil.
        PASSWORD=""
        break
    fi
    echo "That password didn't work for $OWNER. Try again."
    echo
done

if [ -e "/System/Volumes/iSCPreboot/$VGID/boot" ]; then
    # An external volume: kmutil looks for AdminUserRecoveryInfo.plist in the
    # wrong place.
    diskutil mount "$PREBOOT"
    preboot="$(diskutil info "$PREBOOT" | grep "Mount Point" | sed 's, *Mount Point: *,,')"
    cp -R "$preboot/$VGID/var" "/System/Volumes/iSCPreboot/$VGID/"
fi

printf "Installing Omarchy's boot loader..."
# kmutil asks "are you sure" on stdin, then reads a user name and password
# from its terminal, discarding anything typed ahead. So run it on a hidden
# terminal (script) and type each answer once its prompt appears. The
# password is typed with echo off, so the log never holds it. A small
# wrapper records kmutil's own process ID, so that if kmutil fails or is
# still running after a minute, it is stopped and the owner answers it.
kmutil_log=/tmp/kmutil.log
kmutil_status=/tmp/kmutil.status
kmutil_wait_for() {
    tries=0
    while ! grep -q "$1" "$kmutil_log" 2>/dev/null; do
        [ ! -e /tmp/kmutil.done ] && [ "$tries" -lt 600 ] || return 1
        sleep 0.1
        tries=$((tries + 1))
    done
}
kmutil_answers() {
    kmutil_wait_for 'enter y or n' && printf 'y\\n' &&
        kmutil_wait_for 'Username:' && printf '%s\\n' "$OWNER" &&
        kmutil_wait_for 'Password:' && printf '%s\\n' "$PASSWORD"
    # Keep kmutil's input open until it exits.
    while [ ! -e /tmp/kmutil.done ]; do
        sleep 0.1
    done
}
hidden_kmutil() {
    rm -f /tmp/kmutil.done
    kmutil_answers 2>/dev/null | {
        status=0
        script -q -t 0 "$kmutil_log" \\
            /bin/sh -c 'echo $$ >/tmp/kmutil.pid; exec kmutil configure-boot -c boot.bin --raw --entry-point 2048 --lowest-virtual-address 0 -v "$1"' \\
            sh "$system_dir" >/dev/null 2>&1 || status=$?
        # kmutil must not outlive script: stop it if it did, then forget its ID.
        stop_pid_in /tmp/kmutil.pid
        rm -f /tmp/kmutil.pid
        touch /tmp/kmutil.done
        exit "$status"
    }
}
kmutil_ok=no
if [ -n "$PASSWORD" ] && command -v script >/dev/null 2>&1; then
    rm -f "$kmutil_log" /tmp/kmutil.pid
    if run_with_spinner "$kmutil_status" 60 /tmp/kmutil.pid hidden_kmutil; then
        kmutil_ok=yes
    fi
    echo
    stop_pid_in /tmp/kmutil.pid
fi
PASSWORD=""
if [ "$kmutil_ok" != yes ]; then
    echo
    echo "macOS asks once more. Type y, then your user name and password."
    while ! kmutil configure-boot -c boot.bin --raw --entry-point 2048 --lowest-virtual-address 0 -v "$system_dir"; do
        echo "That didn't work. Press Enter to try again."
        read -r _
    done
fi

mount -u -w "$system_dir"
if [ -e "$system_dir/.IAPhysicalMedia" ]; then
    mv "$system_dir/.IAPhysicalMedia" "$system_dir/IAPhysicalMedia-disabled.plist"
fi
if [ -e "$system_dir/System/Library/CoreServices/SystemVersion-disabled.plist" ]; then
    mv -f "$system_dir/System/Library/CoreServices/SystemVersion-disabled.plist" \\
        "$system_dir/System/Library/CoreServices/SystemVersion.plist"
fi
cleanup

echo
echo "${BOLD}Done.${RST} Press Enter to restart into $os_name."
read -r _
reboot
"""


def _write_step2(installer):
    owner = os.environ.get("OMARCHY_MACHINE_OWNER", "")
    if owner and MACHINE_OWNER_PATTERN.fullmatch(owner) is None:
        raise AsahiAdapterError("machine owner name is invalid for the Recovery setup")
    # The app passes its configured name (Packaging/identity.conf).
    title = os.environ.get("OMARCHY_INSTALLER_NAME") or (
        os.environ.get("DISTRO", "Omarchy") + " installer"
    )
    if INSTALLER_TITLE_PATTERN.fullmatch(title) is None:
        raise AsahiAdapterError("installer name is invalid for the Recovery setup")
    for name, value in (("volume group", installer.osi.vgid), ("Preboot volume group", installer.osi.preboot_vgid)):
        if VOLUME_GROUP_PATTERN.fullmatch(value or "") is None:
            raise AsahiAdapterError(f"{name} is invalid for the Recovery setup")
    script = (
        STEP2_SCRIPT.replace("##TITLE##", title)
        .replace("##VGID##", installer.osi.vgid)
        .replace("##PREBOOT##", installer.osi.preboot_vgid)
        .replace("##OWNER##", owner)
    )
    with open(installer.step2_sh, "w") as fd:
        fd.write(script)
    os.chmod(installer.step2_sh, 0o755)
# Aurora's board Stage 1 images carry one versioned config block that names
# the ESP and the Stage 2 path; it is filled in place so the image keeps its
# length and STACKBOT tail (port of aurora-silicon/m1n1
# tools/fill_stage1_config.py, MIT).
STAGE1_MAGIC = b"AURORA-S1-CFG01\0"
STAGE1_BODY = struct.Struct("<II40s192s")
STAGE1_BLOCK = len(STAGE1_MAGIC) + STAGE1_BODY.size + 4
CANONICAL_UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\Z")
# Checks an image before any disk changes, when there is no ESP yet.
PLACEHOLDER_UUID = "00000000-0000-0000-0000-000000000000"

BoardStage1 = collections.namedtuple("BoardStage1", "member window_ms os_firmware macs")
COMMON_STAGE1 = BoardStage1("esp/aurora/stage1.bin", 0, None, "all admitted Apple Silicon Macs")

# Boards that boot through Aurora's own Stage 1 instead of asahi's. os_firmware
# is the only OS firmware the image boots, or None for any.
BOARD_STAGE1 = {
    "j700ap": BoardStage1("esp/aurora/stage1-j700.bin", 5000, None, "the MacBook Neo"),
    # The m3next Stage 1 boots only a J613 with 26.6.2 OS firmware and stays in
    # proxy mode on anything else, so older firmware keeps asahi's. asahi's
    # Stage 1 makes iBoot panic on 26.6.2 before m1n1 runs.
    "j613ap": BoardStage1(
        "esp/aurora/stage1-j613.bin", 0, "26.6.2",
        "a 13-inch M3 MacBook Air on macOS 26.6.2",
    ),
}


def fill_aurora_stage1(image, uuid, path, window_ms):
    if not CANONICAL_UUID.fullmatch(uuid):
        raise AsahiAdapterError("ESP PARTUUID must be canonical lowercase")
    if not path or any(not 0x20 <= ord(c) < 0x7F or c in ";\\" for c in path) or any(
        component in ("", ".", "..") for component in path.split("/")
    ):
        raise AsahiAdapterError("Stage 2 path must be relative to the ESP root")
    encoded = b";" + path.encode("ascii")
    if len(encoded) >= 192:
        raise AsahiAdapterError("Stage 2 path is too long")
    if not 0 <= window_ms <= 99999:
        raise AsahiAdapterError("proxy window must be 0..99999 ms")
    if not image.endswith(b"STACKBOT"):
        raise AsahiAdapterError("Aurora Stage 1 does not end at STACKBOT")
    if image.count(STAGE1_MAGIC) != 1:
        raise AsahiAdapterError("Aurora Stage 1 config block must occur exactly once")
    offset = image.index(STAGE1_MAGIC)
    if offset + STAGE1_BLOCK > len(image) - 8:
        raise AsahiAdapterError("Aurora Stage 1 config block extends past the image")
    if struct.unpack_from("<I", image, offset + len(STAGE1_MAGIC))[0] != 1:
        raise AsahiAdapterError("unsupported Aurora Stage 1 config version")
    body = STAGE1_BODY.pack(
        1, window_ms, uuid.encode("ascii").ljust(40, b"\0"), encoded.ljust(192, b"\0")
    )
    block = STAGE1_MAGIC + body + struct.pack("<I", zlib.crc32(body))
    return image[:offset] + block + image[offset + STAGE1_BLOCK:]


def board_stage1(device_class, os_firmware, members=()):
    """The Aurora Stage 1 this Mac and OS firmware boot through, or None."""
    if COMMON_STAGE1.member in members:
        return COMMON_STAGE1
    board = BOARD_STAGE1.get(device_class)
    if board is None or board.os_firmware not in (None, os_firmware):
        return None
    return board


def read_board_stage1(board, read_member, next_object="m1n1/boot.bin"):
    """The board's Stage 1 image from the payload, refused unless fillable."""
    try:
        image = read_member(board.member)
    except KeyError as error:
        raise AsahiAdapterError(f"this image has no {board.member} for {board.macs}") from error
    fill_aurora_stage1(image, PLACEHOLDER_UUID, next_object, board.window_ms)
    return image


def install_board_stage1(
    device_class, os_firmware, read_member, esp_uuid, boot_object, next_object="m1n1/boot.bin"
):
    """Use the common image when supplied, with legacy image compatibility."""
    try:
        common_image = read_member(COMMON_STAGE1.member)
    except KeyError:
        common_image = None
    board = COMMON_STAGE1 if common_image is not None else board_stage1(device_class, os_firmware)
    if board is None:
        return
    image = common_image if common_image is not None else read_board_stage1(board, read_member, next_object)
    filled = fill_aurora_stage1(image, esp_uuid.lower(), next_object, board.window_ms)
    with open(boot_object, "wb") as fd:
        fd.write(filled)


ESP_SOURCE = "esp"
ESP_STAGE2 = "esp/m1n1/boot.bin"

# Boards whose Stage 2 is not the image's generic m1n1/boot.bin. One image
# carries every board's prebuilt Stage 2: on its own board the file replaces
# m1n1/boot.bin, and every other board drops it, so no ESP ever holds another
# board's Stage 2.
BOARD_STAGE2 = {"j700ap": "esp/m1n1/boot-j700.bin"}


def esp_board_layout(device_class, members):
    """Each payload ESP member's path on this board's ESP; absent ones are not installed."""
    members = set(members)
    common = COMMON_STAGE1.member in members
    if common and ESP_STAGE2 not in members:
        raise AsahiAdapterError(f"this common image has no {ESP_STAGE2}")
    own = None if common else BOARD_STAGE2.get(device_class)
    if own is not None and own not in members:
        board = BOARD_STAGE1.get(device_class)
        macs = board.macs if board is not None else device_class
        raise AsahiAdapterError(f"this image has no {own} for {macs}")
    prefix = ESP_SOURCE + "/"
    layout = {}
    for member in members:
        if not member.startswith(prefix):
            raise AsahiAdapterError("ESP member is outside the ESP source")
        if member == own:
            layout[member] = ESP_STAGE2[len(prefix):]
        elif (member in BOARD_STAGE2.values()
              or (common and member in {board.member for board in BOARD_STAGE1.values()})
              or (own is not None and member == ESP_STAGE2)):
            continue
        else:
            layout[member] = member[len(prefix):]
    return layout


def install_esp_board_layout(device_class, members, esp_root):
    """Turn the copied payload ESP into this board's ESP."""
    layout = esp_board_layout(device_class, members)
    prefix = ESP_SOURCE + "/"
    installed = set(layout.values())
    for member in sorted(set(members)):
        copied = member[len(prefix):]
        target = layout.get(member)
        if target == copied:
            continue
        copied_path = os.path.join(esp_root, *PurePosixPath(copied).parts)
        if target is not None:
            os.replace(copied_path, os.path.join(esp_root, *PurePosixPath(target).parts))
        elif copied not in installed:
            os.unlink(copied_path)


class _WithoutRecoveryMount:
    """subprocess for stub, minus attaching or detaching its recovery image."""

    def __init__(self, module):
        self._module = module

    def __getattr__(self, name):
        return getattr(self._module, name)

    def run(self, command, *args, **kwargs):
        if command[:1] == ["hdiutil"] and "recovery" in command:
            return self._module.CompletedProcess(command, 0)
        return self._module.run(command, *args, **kwargs)


class _WithDecryptedImage:
    """subprocess for stub, attaching IMAGE's decrypted copy in its place."""

    def __init__(self, module, image, decrypted):
        self._module, self._image, self._decrypted = module, image, decrypted

    def __getattr__(self, name):
        return getattr(self._module, name)

    def run(self, command, *args, **kwargs):
        if command[:2] == ["hdiutil", "attach"]:
            command = [self._decrypted if part == self._image else part for part in command]
        return self._module.run(command, *args, **kwargs)


class _WithNeoFirmwareArchive(_WithoutRecoveryMount):
    """Preserve the newer camera daemon and raw ALS input in fallback data."""

    def __init__(self, module, raw_directory):
        super().__init__(module)
        self.raw_directory = raw_directory

    def run(self, command, *args, **kwargs):
        if command[:3] == ["tar", "czf", "all_firmware.tar.gz"]:
            command = list(command)
            camera_directory = os.path.abspath("recovery/usr/sbin")
            if os.path.isfile(os.path.join(camera_directory, "appleh16camerad")):
                command += ["-C", camera_directory, "appleh16camerad"]
            command += ["-C", self.raw_directory, "j700-exbright-LSCI.bin"]
        # Mount handling remains delegated to the original stub module (or
        # the encrypted-Recovery wrapper), not suppressed by this wrapper.
        return self._module.run(command, *args, **kwargs)


@contextlib.contextmanager
def _neo_peripheral_collectors(installer):
    """Patch only the Neo's collectors; retain the inherited legacy paths."""
    if getattr(getattr(installer, "sysinfo", None), "device_class", "") != "j700ap":
        yield
        return
    try:
        raw = omarchy_als.read_lsci()
        als = omarchy_als.calibration(raw)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        raise AsahiAdapterError(f"MacBook Neo ALS calibration collection failed: {error}") from error

    class NeoAlsCollection:
        def files(self):
            name = omarchy_als.FIRMWARE_NAME
            return [(name, asahi_firmware.core.FWFile(name, als))]

    upgraded_isp = omarchy_isp.collection_class(asahi_firmware.isp)

    class NeoIspCollection(upgraded_isp):
        def __init__(self, source_path):
            super().__init__(source_path)
            names = {name for name, _ in self.files()}
            required = {"apple/isp_" + sensor + ".dat" for sensor in (
                "1921_01XX", "1922_02XX", "1925_03XX",
            )}
            missing = required - names
            if missing:
                raise AsahiAdapterError("MacBook Neo camera firmware is missing: " + ", ".join(sorted(missing)))

    old_als, old_isp, old_process = stub.AlsFWCollection, stub.ISPFWCollection, stub.subprocess
    with tempfile.TemporaryDirectory(prefix="omarchy-neo-firmware-") as directory:
        with open(os.path.join(directory, "j700-exbright-LSCI.bin"), "wb") as output:
            output.write(raw)
        try:
            stub.AlsFWCollection = NeoAlsCollection
            stub.ISPFWCollection = NeoIspCollection
            stub.subprocess = _WithNeoFirmwareArchive(old_process, directory)
            yield
        except omarchy_isp.IspError as error:
            raise AsahiAdapterError(f"MacBook Neo camera firmware collection failed: {error}") from error
        finally:
            stub.AlsFWCollection, stub.ISPFWCollection, stub.subprocess = old_als, old_isp, old_process


def stub_installer(sysinfo, dutil, osinfo):
    """A StubInstaller that reads macOS 26 firmware's bootcaches.plist and
    writes Omarchy's own step2.sh as its Recovery setup."""
    installer = stub.StubInstaller(sysinfo, dutil, osinfo)
    load_identity = installer.load_identity

    def load_identity_naming_the_restore_bundle():
        identity = load_identity()
        installer.bootcaches["bless2"].setdefault(
            "RestoreBundlePath", RESTORE_BUNDLE_PATH
        )
        return identity

    installer.load_identity = load_identity_naming_the_restore_bundle

    collect_firmware = installer.collect_firmware

    def collect_firmware_from_an_encrypted_recovery(pkg):
        with _newer_trackpad_keys(), _neo_peripheral_collectors(installer):
            result = _collect_firmware(pkg)
        _collect_neo_radios(installer, pkg)
        _collect_neo_touch_id(installer, pkg)
        if getattr(getattr(installer, "sysinfo", None), "device_class", "") == "j700ap":
            _validate_neo_firmware_package(pkg)
        return result

    def _collect_firmware(pkg):
        image = os.path.join(
            installer.osi.recovery,
            installer.osi.vgid,
            "usr/standalone/firmware/arm64eBaseSystem.dmg",
        )
        if not _is_encrypted(image):
            return collect_firmware(pkg)
        # The recovery image's firmware is its own build's, so it is read
        # from the image itself, decrypted, whichever macOS this Mac runs.
        decrypted = _decrypted_copy(installer, image)
        module = stub.subprocess
        try:
            # Only stub's own name is rebound, never the shared module.
            stub.subprocess = _WithDecryptedImage(module, image, decrypted)
            return collect_firmware(pkg)
        finally:
            stub.subprocess = module

    installer.collect_firmware = collect_firmware_from_an_encrypted_recovery

    install_files = installer.install_files

    def install_files_with_decrypted_images_and_omarchys_step2(cur_os):
        result = install_files(cur_os)
        _use_decrypted_images(installer, cur_os)
        _write_step2(installer)
        return result

    installer.install_files = install_files_with_decrypted_images_and_omarchys_step2
    return installer


def _validate_neo_firmware_package(pkg):
    """Verify legacy collection did not silently omit Neo's trackpad."""
    names = {entry.split()[1] for entry in pkg.manifest if len(entry.split()) >= 2}
    required = {"apple/tpmtfw-j700.bin", omarchy_als.FIRMWARE_NAME} | {
        "apple/isp_" + sensor + ".dat" for sensor in (
            "1921_01XX", "1922_02XX", "1925_03XX",
        )
    }
    missing = required - names
    if missing:
        raise AsahiAdapterError("MacBook Neo firmware package is incomplete: " + ", ".join(sorted(missing)))


def _collect_neo_radios(installer, pkg, collect=None):
    """Require the Neo's complete MT7932 Wi-Fi and Bluetooth input set.

    The model-wide files are Apple's pinned 25G83 ones, fetched by the
    bundled decoder; the calibration and address are this Mac's own.
    """
    if getattr(getattr(installer, "sysinfo", None), "device_class", "") != "j700ap":
        return
    try:
        if collect is None:
            with omarchy_apple_aea.neo_radio_root() as root:
                files = omarchy_mt7932.collect(root)
        else:
            files = collect()
        required = {
            "mediatek/mt7932/" + name for name in (
                omarchy_mt7932.WIFI_PATCH, omarchy_mt7932.WIFI_RAM,
                "ppr.bin", "oca2.bin", "wcal.bin", "config-original.bin",
            )
        } | {"mediatek/" + name for name in omarchy_mt7932.BT_FIRMWARE} | {
            "mediatek/" + omarchy_mt7932.BT_PTX,
            "mediatek/j700-mt7932-btcal.bin", "mediatek/j700-mt7932-bdaddr.bin",
        }
        missing = sorted(name for name in required if not files.get(name))
        if missing:
            raise omarchy_mt7932.Mt7932Error("missing required files: " + ", ".join(missing))
    except (OSError, ValueError, subprocess.CalledProcessError, omarchy_mt7932.Mt7932Error,
            omarchy_apple_aea.AppleInputError) as error:
        raise AsahiAdapterError(f"MacBook Neo radio firmware collection failed: {error}") from error
    for name, data in sorted(files.items()):
        pkg.add_file(name, asahi_firmware.core.FWFile(name, data))
    logging.info("MacBook Neo radio firmware: %d files", len(files))


def _iboot_system_container(dutil):
    """The raw device of the system disk's iBoot System Container, its first
    partition (asahi-installer's find_system_disk test)."""
    partition = dutil.disk_parts[dutil.find_system_disk()]["Partitions"][0]
    if partition.get("Content") != "Apple_APFS_ISC":
        raise omarchy_mesa.MesaError("the system disk does not start with its iBoot System Container")
    return "/dev/r" + partition["DeviceIdentifier"]


def _collect_neo_touch_id(installer, pkg, collect=omarchy_mesa.collect,
                          sensor_present=omarchy_mesa.has_builtin_sensor):
    """Require calibration on sensor-equipped Neos; skip absent hardware."""
    if getattr(getattr(installer, "sysinfo", None), "device_class", "") != "j700ap":
        return
    try:
        if not sensor_present():
            logging.info("MacBook Neo has no built-in Touch ID sensor; skipping calibration")
            return
        files = collect(_iboot_system_container(installer.dutil))
        if not files.get(omarchy_mesa.FIRMWARE_NAME):
            raise omarchy_mesa.MesaError("sensor is present but calibration is missing")
    except (OSError, KeyError, IndexError, subprocess.CalledProcessError, omarchy_mesa.MesaError) as error:
        raise AsahiAdapterError(f"MacBook Neo Touch ID collection failed: {error}") from error
    for name, data in sorted(files.items()):
        pkg.add_file(name, asahi_firmware.core.FWFile(name, data))
    logging.info("MacBook Neo Touch ID calibration: %d bytes", sum(map(len, files.values())))


@contextlib.contextmanager
def _newer_trackpad_keys():
    """Count C1FE multitouch keys (the J700's trackpad) as trackpads.

    asahi_firmware knows C1FD trackpads and C1FB Touch Bars; the MacBook Neo's
    J700_Multitouch.im4p keys its trackpad C1FE0,0, which converts the same way.
    """
    multitouch = getattr(asahi_firmware, "multitouch", None)
    if multitouch is None:
        yield
        return
    original = multitouch.device_key_to_kind

    def device_key_to_kind(key):
        if key.startswith("C1FE"):
            return multitouch.DEVICE_KIND_TRACKPAD
        return original(key)

    multitouch.device_key_to_kind = device_key_to_kind
    try:
        yield
    finally:
        multitouch.device_key_to_kind = original


def _is_encrypted(path):
    with open(path, "rb") as fd:
        return fd.read(len(AEA_MAGIC)) == AEA_MAGIC


def _decrypted_copy(installer, image):
    """IMAGE's AEA archive decrypted into the engine's working directory, once.

    The copy lives beside the engine's other downloads, not in the stub,
    whose container has room for one copy of each image at a time.
    """
    copies = installer.__dict__.setdefault("_omarchy_decrypted", {})
    if image not in copies:
        destination = os.path.abspath(f"decrypted-{len(copies)}-{os.path.basename(image)}")
        try:
            omarchy_apple_aea.decrypt(image, destination)
        except (OSError, subprocess.CalledProcessError, omarchy_apple_aea.AppleInputError) as error:
            raise AsahiAdapterError(f"could not decrypt {os.path.basename(image)}: {error}") from error
        copies[image] = destination
    return copies[image]


def _use_decrypted_images(installer, cur_os):
    """Decrypt the stub's AEA images in place.

    A macOS 26 restore image ships its recoveryOS and ExclaveOS images
    encrypted; the stub's recoveryOS kernel cannot mount them ("Failed to
    mount root image"). Decrypting an archive yields Apple's own image, whose
    signed root hash is the one the stub's boot objects are personalized for,
    whichever macOS this Mac runs.
    """
    image = "usr/standalone/firmware/arm64eBaseSystem.dmg"
    stub_image = os.path.join(installer.osi.recovery, installer.osi.vgid, image)
    if not _is_encrypted(stub_image):
        return
    host_image = _decrypted_copy(installer, stub_image)
    # A UDIF image ends in its 512-byte "koly" trailer.
    with open(host_image, "rb") as fd:
        fd.seek(0, os.SEEK_END)
        trailer = b""
        if fd.tell() >= 512:
            fd.seek(-512, os.SEEK_END)
            trailer = fd.read(4)
    if trailer != b"koly":
        raise AsahiAdapterError(
            "the decrypted recovery image is not a disk image"
        )
    copies = [(host_image, stub_image)]
    bless2 = installer.bootcaches["bless2"]
    restore = os.path.join(
        installer.pb_vgid, bless2.get("RestoreBundlePath", RESTORE_BUNDLE_PATH)
    )
    for name in sorted(os.listdir(restore)):
        path = os.path.join(restore, name)
        if not os.path.isfile(path) or not _is_encrypted(path):
            continue
        copies.append((_decrypted_copy(installer, path), path))
    for source, target in copies:
        # Removed first: the stub container has room for one copy at a time.
        os.unlink(target)
        shutil.copyfile(source, target)
        os.unlink(source)


class AsahiInPlaceRepairAdapter:
    """Non-partitioning adapter for one manifest-bound installed system."""

    def __init__(
        self,
        *,
        installer,
        manifest,
        metadata_path,
        payload_path,
        raw_partition_opener=None,
        boot_policy_authorizer=None,
    ):
        self.installer = installer
        self.manifest = manifest
        self.metadata_path = metadata_path
        self.payload_path = payload_path
        self.raw_partition_opener = (
            raw_partition_opener or self._open_raw_partition
        )
        self.boot_policy_authorizer = (
            boot_policy_authorizer or self._authorize_boot_policy
        )

    def validate_existing_install(self, plan):
        return self._content_evidence(
            plan,
            self.manifest["existing_content"],
            "existing",
        )

    def rewrite_existing_content(self, plan):
        rewritten = []
        try:
            payload = zipfile.ZipFile(self.payload_path)
        except (OSError, zipfile.BadZipFile) as error:
            raise AsahiAdapterError("invalid repair payload") from error
        with payload:
            names = payload.namelist()
            if len(names) != len(set(names)):
                raise AsahiAdapterError("ambiguous repair payload")
            for role in ("stub", "efi", "boot", "root"):
                expected = self.manifest["replacement_content"][role]
                member = expected["payload_member"]
                if member is None:
                    if expected != {
                        **self.manifest["existing_content"][role],
                        "payload_member": None,
                    }:
                        raise AsahiAdapterError(
                            "preserved repair content changed"
                        )
                    continue
                if (
                    not isinstance(member, str)
                    or member not in names
                    or PurePosixPath(member).is_absolute()
                    or ".." in PurePosixPath(member).parts
                ):
                    raise AsahiAdapterError("invalid repair payload member")
                info = payload.getinfo(member)
                if info.file_size != expected["size_bytes"]:
                    raise AsahiAdapterError("repair payload size changed")
                identifier = self._partition_identifier(role)
                digest = hashlib.sha256()
                written = 0
                with payload.open(info) as source, self.raw_partition_opener(
                    identifier,
                    "r+b",
                ) as target:
                    target.seek(0)
                    while True:
                        chunk = source.read(READBACK_CHUNK_BYTES)
                        if not chunk:
                            break
                        digest.update(chunk)
                        written += len(chunk)
                        if target.write(chunk) != len(chunk):
                            raise AsahiAdapterError(
                                "incomplete repair content write"
                            )
                    target.flush()
                    try:
                        os.fsync(target.fileno())
                    except (AttributeError, io.UnsupportedOperation):
                        pass
                if (
                    written != expected["size_bytes"]
                    or "sha256:" + digest.hexdigest() != expected["sha256"]
                ):
                    raise AsahiAdapterError("repair payload digest changed")
                rewritten.append(role)
        return self._canonical_evidence(
            plan,
            {"rewritten_roles": rewritten},
        )

    def validate_repaired_content(self, plan):
        return self._content_evidence(
            plan,
            self.manifest["replacement_content"],
            "repaired",
        )

    def authorize_existing_boot_policy(self, plan):
        evidence = self.boot_policy_authorizer(
            plan,
            self._partition_identifier("stub"),
        )
        if not isinstance(evidence, bytes) or not evidence:
            raise AsahiAdapterError("invalid repair authorization evidence")
        return evidence

    def _content_evidence(self, plan, expected_by_role, state):
        observed = {}
        preserved_roles = [
            role
            for role in ("stub", "efi", "boot", "root")
            if self.manifest["replacement_content"][role]["payload_member"]
            is None
        ]
        rewritten_roles = [
            role
            for role in ("stub", "efi", "boot", "root")
            if role not in preserved_roles
        ]
        for role in rewritten_roles:
            expected = expected_by_role[role]
            size = expected["size_bytes"]
            digest = hashlib.sha256()
            remaining = size
            with self.raw_partition_opener(
                self._partition_identifier(role),
                "rb",
            ) as stream:
                stream.seek(0)
                while remaining:
                    chunk = stream.read(min(remaining, READBACK_CHUNK_BYTES))
                    if not chunk:
                        raise AsahiAdapterError("repair content changed")
                    digest.update(chunk)
                    remaining -= len(chunk)
            actual = "sha256:" + digest.hexdigest()
            if actual != expected["sha256"]:
                raise AsahiAdapterError("repair content changed")
            observed[role] = {"size_bytes": size, "sha256": actual}
        return self._canonical_evidence(
            plan,
            {
                "state": state,
                "content": observed,
                "preserved_roles": preserved_roles,
            },
        )

    def _partition_identifier(self, role):
        matches = [
            item["identifier"]
            for item in self.manifest["partitions"]
            if item["role"] == role
        ]
        if len(matches) != 1 or PARTITION_PATTERN.fullmatch(matches[0]) is None:
            raise AsahiAdapterError("repair partition identity changed")
        return matches[0]

    @staticmethod
    def _canonical_evidence(plan, evidence):
        return json.dumps(
            {"plan_digest": plan.plan_digest, **evidence},
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")

    @staticmethod
    def _open_raw_partition(identifier, mode):
        if PARTITION_PATTERN.fullmatch(identifier or "") is None:
            raise AsahiAdapterError("invalid raw partition identity")
        return open("/dev/r" + identifier, mode, buffering=0)

    def _authorize_boot_policy(self, plan, stub_identifier):
        owner = os.environ.get("OMARCHY_MACHINE_OWNER", "")
        if MACHINE_OWNER_PATTERN.fullmatch(owner) is None:
            raise AsahiAdapterError("machine owner is unavailable")
        password_input = sys.stdin.buffer.read(MAXIMUM_PASSWORD_BYTES + 2)
        if not password_input.endswith(b"\n"):
            raise AsahiAdapterError("machine owner password is unavailable")
        password = password_input[:-1]
        if (
            not password
            or len(password) > MAXIMUM_PASSWORD_BYTES
            or b"\x00" in password
            or b"\n" in password
            or b"\r" in password
        ):
            raise AsahiAdapterError("machine owner password is invalid")

        matches = [
            part
            for part in self.installer.parts
            if part.name == stub_identifier and not part.free
        ]
        if len(matches) != 1:
            raise AsahiAdapterError("repair stub identity changed")
        target = matches[0]
        existing = stub_installer(
            self.installer.sysinfo,
            self.installer.dutil,
            self.installer.osinfo,
        )
        existing.check_volume(target)
        existing.prepare_for_bless()
        try:
            subprocess.run(
                [
                    "/usr/sbin/bless",
                    "--setBoot",
                    "--device",
                    "/dev/" + existing.osi.sys_volume,
                    "--user",
                    owner,
                    "--stdinpass",
                ],
                input=password_input,
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except (OSError, subprocess.CalledProcessError) as error:
            raise AsahiAdapterError(
                "Recovery handoff authorization failed"
            ) from error
        verify_default_boot(self.installer.dutil, existing.osi.vgid)
        existing.prepare_for_step2()
        return self._canonical_evidence(
            plan,
            {"outcome": "awaiting_recovery"},
        )


class OmarchyOSInstaller(osinstall.OSInstaller):
    def extract_tree(self, source, destination):
        # ZIPs need not contain directory entries, and any entries they do
        # contain can follow the files. Asahi's extractor only creates the
        # directories it encounters, so prepare parents for the validated
        # payload tree before delegating its file copying and CRC checks.
        prefix = self.path(source).rstrip("/") + "/"
        for member in self.pkg.infolist():
            if member.filename.startswith(prefix):
                relative = member.filename[len(prefix):]
                parent = os.path.dirname(os.path.join(destination, relative))
                os.makedirs(parent, exist_ok=True)
        return super().extract_tree(source, destination)

    def install_raw_image(self, image, info):
        self.image_receipts[image] = write_image(
            self.pkg, image, info,
            opener=self.image_opener, flush=self.image_flush,
        )


class AsahiStage1Adapter:
    def __init__(
        self,
        *,
        installer,
        metadata_path,
        payload_path,
        stub_size,
        raw_partition_opener=None,
        raw_partition_writer=None,
        image_flush=flush_device,
        full_readback=False,
    ):
        self.installer = installer
        self.metadata_path = metadata_path
        self.payload_path = payload_path
        self.stub_size = stub_size
        self.raw_partition_opener = (
            raw_partition_opener or self._open_raw_partition
        )
        self.image_writer = raw_partition_writer or open_target
        self.image_flush = image_flush
        self.full_readback = full_readback
        self.template = None
        self.osins = None
        self.os_firmware = None
        self.target_part = None
        self.preflight_complete = False

    def preflight(self, plan):
        if self.preflight_complete:
            return
        metadata = self._load_metadata()
        templates = [
            template
            for template in metadata["os_list"]
            if template.get("omarchy_target") == TARGET
        ]
        if len(templates) != 1:
            raise AsahiAdapterError(
                "metadata must contain exactly one Omarchy full-OS target"
            )
        self.installer.data = metadata
        self.template = templates[0]
        self.osins = OmarchyOSInstaller(
            self.installer.dutil,
            metadata,
            self.template,
        )
        self.osins.image_receipts = {}
        self.osins.image_opener = self.image_writer
        self.osins.image_flush = self.image_flush
        # min_size is the partition floor the images fit in.
        # min_recommended_size doubles an expandable root for later upgrades,
        # and a tight disk is allowed to install at the floor instead.
        partition_floor = getattr(
            self.osins, "min_size", self.osins.min_recommended_size
        )
        if plan.length_bytes < self.stub_size + partition_floor:
            raise AsahiAdapterError(
                "approved extent is smaller than Asahi minimum"
            )
        try:
            self.osins.pkg = zipfile.ZipFile(self.payload_path)
            # Authenticated package admission precedes this adapter. CRC is
            # checked during extraction; avoid a separate full expansion.
        except (OSError, zipfile.BadZipFile) as error:
            raise AsahiAdapterError("invalid Omarchy payload") from error
        self._validate_full_os_package()
        ipsw = self.installer.choose_ipsw(
            self.template.get("supported_fw"),
        )
        self.installer.ins = stub_installer(
            self.installer.sysinfo,
            self.installer.dutil,
            self.installer.osinfo,
        )
        self.installer.ins.load_ipsw(ipsw)
        self.os_firmware = ipsw.version.split(maxsplit=1)[0]
        esp_members = self._esp_members()
        board = board_stage1(self.installer.sysinfo.device_class, self.os_firmware, esp_members)
        if board is not None:
            read_board_stage1(board, self.osins.pkg.read, self.template["next_object"])
        device_class = self.installer.sysinfo.device_class
        esp_board_layout(device_class, esp_members)
        stage2 = ESP_STAGE2 if COMMON_STAGE1.member in esp_members else BOARD_STAGE2.get(device_class)
        if stage2 is not None and self.osins.pkg.getinfo(stage2).file_size <= 0:
            raise AsahiAdapterError(f"this image has an empty {stage2}")
        self.installer.osins = self.osins
        self.preflight_complete = True

    def remove_existing_install(self, plan):
        """Free the exact partitions of the approved existing install.

        Runs against the partition table the admission just validated: the
        candidate identity digest is re-derived from the live parts and must
        equal the approved plan's before anything is erased. Erasure
        addresses partitions by UUID because identifiers shift as space is
        released. Afterwards one free extent must cover the approved extent.
        """
        self._require_preflight()
        if plan.candidate_kind != "replace":
            raise AsahiAdapterError("removal requires a replace candidate")
        if not plan.candidate_identity_digest:
            raise AsahiAdapterError("replace plan carries no identity")
        self.installer.check_cur_os()

        os_label = self.template.get("default_os_name")
        candidates = omarchy_planner.collect_existing_installs(
            self.installer,
            os_label,
            plan.minimum_install_bytes,
            1,
        )
        matches = [
            candidate
            for candidate in candidates
            if candidate["source_identifier"] == plan.source_identifier
            and candidate["offset_bytes"] == plan.offset_bytes
            and candidate["length_bytes"] >= plan.length_bytes
            and candidate["identity_digest"]
            == plan.candidate_identity_digest
        ]
        if len(matches) != 1:
            raise AsahiAdapterError("approved existing install changed")

        stub_index = next(
            index
            for index, part in enumerate(self.installer.parts)
            if not part.free and part.name == plan.source_identifier
        )
        members = self.installer.parts[stub_index : stub_index + 4]
        observed = omarchy_planner.replace_identity_digest(
            members,
            os_label,
            next(
                getattr(os_info, "vgid", None)
                for os_info in members[0].os
                if getattr(os_info, "stub", False)
                and getattr(os_info, "label", None) == os_label
            ),
        )
        if observed != plan.candidate_identity_digest:
            raise AsahiAdapterError("approved existing install changed")

        container = getattr(members[0], "container", None) or {}
        reference = container.get("ContainerReference")
        if not isinstance(reference, str) or not reference:
            raise AsahiAdapterError("existing stub container is unreadable")
        # Keep the APFS store alive until its neighbouring partitions have
        # been removed. deleteContainer may free that store outright or
        # replace it with a new HFS partition identity.
        for member in reversed(members[1:]):
            self.installer.dutil.action(
                "eraseVolume", "free", "none", member.uuid, verbose=True
            )
        self.installer.dutil.action(
            "apfs", "deleteContainer", reference, verbose=True
        )
        self._refresh_parts()
        stub = members[0]
        remaining = [part for part in self.installer.parts
                     if not part.free and part.offset < stub.offset + stub.size
                     and part.offset + part.size > stub.offset]
        if remaining:
            if (len(remaining) != 1 or remaining[0].offset != stub.offset
                    or remaining[0].size != stub.size
                    or remaining[0].type not in ("Apple_HFS", "Apple_HFSX")
                    or remaining[0].os or not remaining[0].uuid):
                raise AsahiAdapterError("deleted stub left an unexpected partition")
            self.installer.dutil.action(
                "eraseVolume", "free", "none", remaining[0].uuid, verbose=True
            )
        self._refresh_parts()
        freed = self._find_free_extent(plan)
        return json.dumps(
            {
                "plan_digest": plan.plan_digest,
                "removed": [
                    {
                        "name": member.name,
                        "offset_bytes": member.offset,
                        "size_bytes": member.size,
                        "type": member.type,
                        "uuid": member.uuid,
                    }
                    for member in members
                ],
                "free_offset_bytes": freed.offset,
                "free_size_bytes": freed.size,
            },
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")

    def prepare_target(self, plan):
        self._require_preflight()
        self.installer.check_cur_os()
        self._refresh_parts()
        if plan.candidate_kind == "resize":
            source = self._find_partition(
                name=plan.source_identifier,
                free=False,
            )
            new_size = source.size - plan.length_bytes
            if new_size < plan.minimum_container_bytes:
                raise AsahiAdapterError(
                    "resize would cross the approved minimum"
                )
            self.installer.dutil.resizeContainer(source.name, new_size)
            self._refresh_parts()
        free = self._find_free_extent(plan)
        self.target_part = self.installer.dutil.addPartition(
            free.name,
            "apfs",
            self.osins.name,
            self.stub_size,
        )
        self.installer.part = self.target_part
        return self._target_evidence(plan)

    def install_stub_and_esp(self, plan):
        self._require_preflight()
        if self.target_part is None:
            self._refresh_parts()
            self.target_part = self._find_prepared_target(plan)
            self.installer.part = self.target_part

        self.installer.ins.prepare_volume(self.target_part)
        self.installer.ins.check_volume()
        self.installer.ins.install_files(self.installer.cur_os)
        os_size = plan.length_bytes - self.stub_size
        self.osins.partition_disk(self.target_part.name, os_size)

        firmware_package = None
        if self.osins.needs_firmware:
            os.makedirs("vendorfw", exist_ok=True)
            firmware_package = asahi_firmware.core.FWPackage(
                "vendorfw"
            )
            self.installer.ins.collect_firmware(firmware_package)
            firmware_package.close()
            self.osins.firmware_package = firmware_package

        self.osins.install(self.installer.ins)
        install_board_stage1(
            self.installer.sysinfo.device_class,
            self.os_firmware,
            self.osins.pkg.read,
            self.osins.efi_part.uuid,
            self.installer.ins.boot_obj_path,
            self.template.get("next_object", "m1n1/boot.bin"),
        )
        install_esp_board_layout(
            self.installer.sysinfo.device_class,
            self._esp_members(),
            self.installer.dutil.mount(self.osins.efi_part.name),
        )
        if self.native_recovery_gui:
            omarchy_recovery.stage(
                self.installer.ins, self.osins.efi_part.uuid,
                self.installer.dutil.mount(self.osins.efi_part.name),
                source_os=self.installer.cur_os,
            )
        for target in self.osins.idata_targets:
            self.installer.ins.collect_installer_data(target)
            shutil.copy(
                "installer.log",
                os.path.join(target, "installer.log"),
            )
        return self._installed_evidence(plan)

    def validate_installed_checkpoint(
        self,
        plan,
        target_evidence,
        installed_evidence,
    ):
        """Re-read the exact completed stage-one state without mutation."""
        self._require_preflight()
        target = self._parse_checkpoint_evidence(
            target_evidence,
            {
                "plan_digest",
                "partition_identifier",
                "offset_bytes",
                "size_bytes",
                "uuid",
            },
        )
        installed = self._parse_checkpoint_evidence(
            installed_evidence,
            {
                "plan_digest",
                "apfs_vgid",
                "system_volume",
                "efi_partition",
                "startup_volume_icon",
                "populated_partitions",
            },
        )
        if (
            target["plan_digest"] != plan.plan_digest
            or installed["plan_digest"] != plan.plan_digest
        ):
            raise AsahiAdapterError("installed checkpoint plan changed")

        self._refresh_parts()
        self.target_part = self._find_prepared_target(plan)
        self.installer.part = self.target_part
        if self._target_evidence(plan) != target_evidence:
            raise AsahiAdapterError("prepared target identity changed")

        recorded = installed["populated_partitions"]
        if (
            not isinstance(recorded, list)
            or len(recorded) != len(self.template["partitions"])
        ):
            raise AsahiAdapterError("installed partition count changed")
        expected_keys = {
            "name",
            "partition_identifier",
            "partition_uuid",
            "partition_size_bytes",
            "population",
            "installed_bytes",
            "verification",
            "content_sha256",
        }
        identifiers = []
        for item, partition in zip(
            recorded,
            self.template["partitions"],
            strict=True,
        ):
            if not isinstance(item, dict) or set(item) != expected_keys:
                raise AsahiAdapterError(
                    "installed checkpoint shape changed"
                )
            expected_population = partition.get("image") or partition.get(
                "source"
            )
            if (
                item["name"] != partition["name"]
                or item["population"] != expected_population
            ):
                raise AsahiAdapterError(
                    "installed checkpoint metadata changed"
                )
            identifiers.append(item["partition_identifier"])

        extent_end = plan.offset_bytes + plan.length_bytes
        physical = [
            part
            for part in self.installer.parts
            if not part.free
            and part.offset >= self.target_part.offset + self.target_part.size
            and part.offset < extent_end
        ]
        physical.sort(key=lambda part: part.offset)
        if [part.name for part in physical] != identifiers:
            raise AsahiAdapterError("installed partition identity changed")

        for item, part in zip(recorded, physical, strict=True):
            if (
                not isinstance(part.uuid, str)
                or part.uuid.lower() != item["partition_uuid"]
                or part.size != item["partition_size_bytes"]
                or part.offset + part.size > extent_end
            ):
                raise AsahiAdapterError(
                    "installed partition identity changed"
                )

        self.osins.part_info = physical
        self.osins.efi_part = next(
            (
                part
                for partition, part in zip(
                    self.template["partitions"],
                    physical,
                    strict=True,
                )
                if partition["type"] == "EFI"
            ),
            None,
        )
        self.installer.ins.check_volume(self.target_part)
        if self._installed_evidence(plan, recorded=recorded) != installed_evidence:
            raise AsahiAdapterError("installed content checkpoint changed")

    def prepare_recovery_handoff(self, plan):
        self._require_preflight()
        owner = os.environ.get("OMARCHY_MACHINE_OWNER", "")
        if MACHINE_OWNER_PATTERN.fullmatch(owner) is None:
            raise AsahiAdapterError("machine owner is unavailable")

        password_input = sys.stdin.buffer.read(MAXIMUM_PASSWORD_BYTES + 2)
        if not password_input.endswith(b"\n"):
            raise AsahiAdapterError("machine owner password is unavailable")
        password = password_input[:-1]
        if (
            not password
            or len(password) > MAXIMUM_PASSWORD_BYTES
            or b"\x00" in password
            or b"\n" in password
            or b"\r" in password
        ):
            raise AsahiAdapterError("machine owner password is invalid")

        if self.target_part is None:
            self._refresh_parts()
            self.target_part = self._find_prepared_target(plan)
            self.installer.part = self.target_part
        if not hasattr(self.installer.ins, "osi"):
            self.installer.ins.check_volume(self.target_part)

        self.installer.ins.prepare_for_bless()
        try:
            subprocess.run(
                [
                    "/usr/sbin/bless",
                    "--setBoot",
                    "--device",
                    "/dev/" + self.installer.ins.osi.sys_volume,
                    "--user",
                    owner,
                    "--stdinpass",
                ],
                input=password_input,
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except (OSError, subprocess.CalledProcessError) as error:
            raise AsahiAdapterError(
                "Recovery handoff authorization failed"
            ) from error

        verify_default_boot(self.installer.dutil, self.installer.ins.osi.vgid)
        self.installer.ins.prepare_for_step2()
        return json.dumps(
            {
                "plan_digest": plan.plan_digest,
                "outcome": "awaiting_recovery",
            },
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")

    def _load_metadata(self):
        return load_metadata(self.metadata_path)

    def _parse_checkpoint_evidence(self, evidence, expected_keys):
        try:
            payload = json.loads(evidence)
        except (UnicodeDecodeError, json.JSONDecodeError, TypeError) as error:
            raise AsahiAdapterError(
                "installed checkpoint is invalid"
            ) from error
        if (
            not isinstance(payload, dict)
            or set(payload) != expected_keys
            or json.dumps(
                payload,
                sort_keys=True,
                separators=(",", ":"),
            ).encode("utf-8")
            != evidence
        ):
            raise AsahiAdapterError("installed checkpoint is invalid")
        return payload

    def _refresh_parts(self):
        self.installer.dutil.get_info()
        self.installer.parts = self.installer.dutil.get_partitions(
            self.installer.sys_disk
        )

    def _find_partition(self, *, name, free):
        matches = [
            part
            for part in self.installer.parts
            if part.name == name and part.free is free
        ]
        if len(matches) != 1:
            raise AsahiAdapterError("approved source partition changed")
        return matches[0]

    def _find_free_extent(self, plan):
        matches = [
            part
            for part in self.installer.parts
            if part.free
            and part.offset == plan.offset_bytes
            and part.size >= plan.length_bytes
        ]
        if len(matches) != 1:
            raise AsahiAdapterError("approved free extent changed")
        return matches[0]

    def _find_prepared_target(self, plan):
        minimum = int(self.stub_size * 0.95)
        maximum = int(self.stub_size * 1.05)
        matches = [
            part
            for part in self.installer.parts
            if not part.free
            and part.offset == plan.offset_bytes
            and minimum <= part.size <= maximum
            and isinstance(part.type, str)
            and "APFS" in part.type
        ]
        if len(matches) != 1:
            raise AsahiAdapterError(
                "prepared APFS target cannot be reconciled"
            )
        return matches[0]

    def _target_evidence(self, plan):
        return json.dumps(
            {
                "plan_digest": plan.plan_digest,
                "partition_identifier": self.target_part.name,
                "offset_bytes": self.target_part.offset,
                "size_bytes": self.target_part.size,
                "uuid": self.target_part.uuid,
            },
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")

    def _installed_evidence(self, plan, recorded=None):
        osi = self.installer.ins.osi
        startup_volume_icon = self._verify_installed_file(
            self.template["icon"],
            self.installer.ins.icon_path,
        )
        populated_partitions = []
        if len(self.template["partitions"]) != len(self.osins.part_info):
            raise AsahiAdapterError("installed partition count changed")
        for partition, info in zip(
            self.template["partitions"],
            self.osins.part_info,
        ):
            image = partition.get("image")
            source = partition.get("source")
            if image:
                previous = next((item for item in (recorded or [])
                                 if item["population"] == image), None)
                receipt = previous or self.osins.image_receipts.get(image)
                if receipt is None:
                    raise AsahiAdapterError("completed image write receipt missing")
                installed_bytes = self.osins.pkg.getinfo(image).file_size
                if (receipt["partition_identifier"] != info.name
                        or receipt["partition_uuid"] != info.uuid.lower()
                        or receipt["partition_size_bytes"] != info.size
                        or receipt["installed_bytes"] != installed_bytes
                        or installed_bytes <= 0 or installed_bytes > info.size
                        or re.fullmatch(r"[0-9a-f]{64}", receipt["content_sha256"]) is None):
                    raise AsahiAdapterError("installed image receipt changed")
                content_digest = receipt["content_sha256"]
                verification = (previous["verification"] if previous else
                                WRITE_VERIFICATION if image == "root.img"
                                and not self.full_readback else "raw-prefix-sha256")
                if verification not in (WRITE_VERIFICATION, "raw-prefix-sha256"):
                    raise AsahiAdapterError("unknown image verification method")
                # On exceptional Recovery retry, recheck all installed images
                # against their recorded hashes without decompressing source.
                if previous or image != "root.img" or self.full_readback:
                    observed = hash_target(self.raw_partition_opener, info.name,
                                           installed_bytes)
                    if observed != content_digest:
                        raise AsahiAdapterError("installed content does not match payload")
                population = image
            else:
                installed_bytes, content_digest = self._verify_copied_tree(
                    source,
                    info,
                )
                population = source
                verification = "copied-tree-sha256"
            if installed_bytes <= 0:
                raise AsahiAdapterError("installed partition is empty")
            populated_partitions.append(
                {
                    "name": partition["name"],
                    "partition_identifier": info.name,
                    "partition_uuid": info.uuid.lower(),
                    "partition_size_bytes": info.size,
                    "population": population,
                    "installed_bytes": installed_bytes,
                    "verification": verification,
                    "content_sha256": content_digest,
                }
            )
        return json.dumps(
            {
                "plan_digest": plan.plan_digest,
                "apfs_vgid": osi.vgid,
                "system_volume": osi.sys_volume,
                "efi_partition": (
                    self.osins.efi_part.uuid.lower()
                    if self.osins.efi_part is not None
                    else None
                ),
                "startup_volume_icon": startup_volume_icon,
                "populated_partitions": populated_partitions,
            },
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")

    def _verify_raw_image(self, image, info):
        if (
            PARTITION_PATTERN.fullmatch(info.name) is None
            or not isinstance(info.size, int)
        ):
            raise AsahiAdapterError("installed partition identity changed")
        member = self.osins.pkg.getinfo(image)
        if member.file_size <= 0 or member.file_size > info.size:
            raise AsahiAdapterError("installed image does not fit partition")
        try:
            with self.osins.pkg.open(member) as source:
                with self.raw_partition_opener(info.name) as target:
                    digest = self._matching_stream_digest(
                        source,
                        target,
                        member.file_size,
                    )
        except (OSError, KeyError, zipfile.BadZipFile) as error:
            raise AsahiAdapterError("installed image read-back failed") from error
        return member.file_size, digest

    def _verify_installed_file(self, member_name, target_path):
        try:
            member = self.osins.pkg.getinfo(member_name)
            target_status = os.lstat(target_path)
            if (
                not stat.S_ISREG(target_status.st_mode)
                or stat.S_ISLNK(target_status.st_mode)
                or target_status.st_size != member.file_size
                or member.file_size <= 0
            ):
                raise AsahiAdapterError("installed branding changed")
            flags = os.O_RDONLY
            if hasattr(os, "O_CLOEXEC"):
                flags |= os.O_CLOEXEC
            if hasattr(os, "O_NOFOLLOW"):
                flags |= os.O_NOFOLLOW
            descriptor = os.open(target_path, flags)
            with os.fdopen(descriptor, "rb") as observed, self.osins.pkg.open(
                member
            ) as expected:
                digest = self._matching_stream_digest(
                    expected,
                    observed,
                    member.file_size,
                )
        except (OSError, KeyError, zipfile.BadZipFile) as error:
            raise AsahiAdapterError("installed branding read-back failed") from error
        return {
            "member": member_name,
            "installed_bytes": member.file_size,
            "verification": "stub-file-sha256",
            "content_sha256": digest,
        }

    def _verify_copied_tree(self, source, info):
        if PARTITION_PATTERN.fullmatch(info.name) is None:
            raise AsahiAdapterError("installed partition identity changed")
        try:
            mountpoint = self.installer.dutil.mount(info.name)
            mount_status = os.lstat(mountpoint)
        except OSError as error:
            raise AsahiAdapterError("installed tree read-back failed") from error
        if not stat.S_ISDIR(mount_status.st_mode) or stat.S_ISLNK(
            mount_status.st_mode
        ):
            raise AsahiAdapterError("installed tree mount is unsafe")

        prefix = source.rstrip("/") + "/"
        members = sorted(
            (
                member
                for member in self.osins.pkg.infolist()
                if not member.is_dir()
                and member.filename.startswith(prefix)
            ),
            key=lambda member: member.filename,
        )
        if not members:
            raise AsahiAdapterError("installed tree source is empty")
        # The ESP holds this board's layout of the payload tree, so the
        # install step and every later recheck expect the same files.
        if source == ESP_SOURCE:
            layout = esp_board_layout(
                self.installer.sysinfo.device_class,
                (member.filename for member in members),
            )
        else:
            layout = {
                member.filename: member.filename[len(prefix) :] for member in members
            }
        for member in members:
            relative = member.filename[len(prefix) :]
            if relative in layout.values():
                continue
            # A dropped or moved member must leave no copy behind.
            try:
                os.lstat(os.path.join(mountpoint, *PurePosixPath(relative).parts))
            except FileNotFoundError:
                continue
            except OSError as error:
                raise AsahiAdapterError("installed tree read-back failed") from error
            raise AsahiAdapterError("installed tree holds a dropped member")
        members = [member for member in members if member.filename in layout]
        tree_digest = hashlib.sha256()
        installed_bytes = 0
        for member in members:
            relative = layout[member.filename]
            target_path = os.path.join(mountpoint, *PurePosixPath(relative).parts)
            try:
                target_status = os.lstat(target_path)
                if (
                    not stat.S_ISREG(target_status.st_mode)
                    or stat.S_ISLNK(target_status.st_mode)
                    or target_status.st_size != member.file_size
                ):
                    raise AsahiAdapterError(
                        "installed tree member changed"
                    )
                flags = os.O_RDONLY
                if hasattr(os, "O_CLOEXEC"):
                    flags |= os.O_CLOEXEC
                if hasattr(os, "O_NOFOLLOW"):
                    flags |= os.O_NOFOLLOW
                descriptor = os.open(target_path, flags)
                with os.fdopen(descriptor, "rb") as observed, self.osins.pkg.open(
                    member
                ) as expected:
                    member_digest = self._matching_stream_digest(
                        expected,
                        observed,
                        member.file_size,
                    )
            except (OSError, KeyError, zipfile.BadZipFile) as error:
                raise AsahiAdapterError(
                    "installed tree read-back failed"
                ) from error
            encoded_name = member.filename.encode("utf-8")
            tree_digest.update(len(encoded_name).to_bytes(8, "big"))
            tree_digest.update(encoded_name)
            tree_digest.update(bytes.fromhex(member_digest))
            installed_bytes += member.file_size
        return installed_bytes, tree_digest.hexdigest()

    def _matching_stream_digest(self, expected, observed, expected_bytes):
        digest = hashlib.sha256()
        remaining = expected_bytes
        while remaining:
            chunk = expected.read(min(READBACK_CHUNK_BYTES, remaining))
            if not chunk:
                raise AsahiAdapterError("installed content is truncated")
            observed_chunk = bytearray()
            while len(observed_chunk) < len(chunk):
                addition = observed.read(len(chunk) - len(observed_chunk))
                if not addition:
                    raise AsahiAdapterError("installed content is truncated")
                observed_chunk.extend(addition)
            if chunk != observed_chunk:
                raise AsahiAdapterError("installed content differs from payload")
            digest.update(chunk)
            remaining -= len(chunk)
        if expected.read(1):
            raise AsahiAdapterError("payload member size changed")
        return digest.hexdigest()

    @staticmethod
    def _open_raw_partition(name):
        return open("/dev/r" + name, "rb", buffering=0)

    def _validate_full_os_package(self):
        if self.template.get("package") != os.path.basename(
            self.payload_path
        ):
            raise AsahiAdapterError("metadata package does not match payload")
        if (
            self.template.get("boot_object") != "m1n1.bin"
            or self.template.get("next_object") != "m1n1/boot.bin"
        ):
            raise AsahiAdapterError("invalid Omarchy boot chain metadata")
        if self.template.get("icon") != "omarchy-volume.icns":
            raise AsahiAdapterError(
                "invalid Omarchy Startup Options icon metadata"
            )

        partitions = self.template.get("partitions")
        expected = (
            ("EFI", "EFI", "esp", None, False),
            ("Boot", "Linux", None, "boot.img", False),
            ("Root", "Linux", None, "root.img", True),
        )
        if not isinstance(partitions, list) or len(partitions) != len(expected):
            raise AsahiAdapterError("invalid Omarchy full-OS partitions")
        for partition, contract in zip(partitions, expected):
            name, part_type, source, image, expand = contract
            if (
                partition.get("name") != name
                or partition.get("type") != part_type
                or partition.get("source") != source
                or partition.get("image") != image
                or bool(partition.get("expand", False)) is not expand
            ):
                raise AsahiAdapterError("invalid Omarchy full-OS partitions")
        efi = partitions[0]
        if (
            efi.get("format") != "fat"
            or efi.get("copy_firmware") is not True
            or efi.get("copy_installer_data") is not True
        ):
            raise AsahiAdapterError("invalid Omarchy ESP metadata")

        required = {
            "boot.img",
            "root.img",
            "esp/m1n1/boot.bin",
            "esp/EFI/BOOT/BOOTAA64.EFI",
            "omarchy-volume.icns",
        }
        members = {}
        for member in self.osins.pkg.infolist():
            path = PurePosixPath(member.filename)
            file_type = (member.external_attr >> 16) & 0o170000
            if (
                not member.filename
                or "\\" in member.filename
                or path.is_absolute()
                or ".." in path.parts
                or file_type == 0o120000
                or member.filename in members
            ):
                raise AsahiAdapterError("unsafe Omarchy payload member")
            members[member.filename] = member
        if not required.issubset(members):
            raise AsahiAdapterError("incomplete Omarchy full-OS payload")
        recovery_manifest = (
            "esp/" + omarchy_recovery.PAYLOAD_DIRECTORY + "/" + omarchy_recovery.MANIFEST_NAME
        )
        recovery_mode = self.template.get("recovery_gui")
        if recovery_mode not in (None, "omarchy-native-v1"):
            raise AsahiAdapterError("unknown Recovery GUI contract")
        self.native_recovery_gui = recovery_mode is not None or recovery_manifest in members
        if self.native_recovery_gui:
            try:
                omarchy_recovery.validate_payload(self.osins.pkg)
            except omarchy_recovery.RecoveryError as error:
                raise AsahiAdapterError(str(error)) from error
        for name in required:
            if members[name].file_size <= 0:
                raise AsahiAdapterError("empty Omarchy full-OS payload member")
        for partition in partitions[1:]:
            try:
                capacity = osinstall.psize(partition["size"])
            except (KeyError, TypeError, ValueError) as error:
                raise AsahiAdapterError("invalid Omarchy partition capacity") from error
            if capacity <= 0 or members[partition["image"]].file_size > capacity:
                raise AsahiAdapterError("Omarchy image exceeds partition capacity")
        for name in ("boot.img", "root.img"):
            if members[name].file_size % 4096 != 0:
                raise AsahiAdapterError("Omarchy image size is not 4KiB aligned")

    def _esp_members(self):
        prefix = ESP_SOURCE + "/"
        return [
            member.filename
            for member in self.osins.pkg.infolist()
            if not member.is_dir() and member.filename.startswith(prefix)
        ]

    def _require_preflight(self):
        if not self.preflight_complete:
            raise AsahiAdapterError("adapter preflight is required")


def load_metadata(path):
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise AsahiAdapterError("metadata is unavailable") from error
    try:
        status = os.fstat(descriptor)
        if (
            not stat.S_ISREG(status.st_mode)
            or status.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
            or status.st_size < 1
            or status.st_size > 65_536
        ):
            raise AsahiAdapterError("metadata is invalid")
        data = os.read(descriptor, status.st_size + 1)
    finally:
        os.close(descriptor)
    if not data or len(data) > 65_536:
        raise AsahiAdapterError("metadata is invalid")
    try:
        metadata = json.loads(data)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise AsahiAdapterError("metadata is invalid") from error
    if (
        not isinstance(metadata, dict)
        or set(metadata) != {"os_list"}
        or not isinstance(metadata["os_list"], list)
    ):
        raise AsahiAdapterError("metadata is invalid")
    return metadata
