# SPDX-License-Identifier: MIT
from dataclasses import dataclass
from pathlib import Path
import re
import sys
from types import SimpleNamespace
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from omarchy_firmware import available_ipsws, default_ipsw, stub_size  # noqa: E402

PATCH = Path(__file__).resolve().parents[2] / "patches/0001-omarchy-engine-runtime.patch"
GB = 1000**3
STUB_SIZE = int(2.5 * GB)
STUB_SIZE_MACOS26 = 6 * GB


# Upstream util.split_ver and main.IPSW at the locked asahi-installer commit.
def split_ver(s):
    parts = re.split(r"[-,. ]", s)
    parts2 = []
    for i in parts:
        try:
            parts2.append(int(i))
        except ValueError:
            parts2.append(i)
    if len(parts2) > 3 and parts2[-2] == "beta":
        parts2[-3] -= 1
        parts2[-2] = 99
    return tuple(parts2)


@dataclass
class IPSW:
    version: str
    min_macos: str
    min_iboot: str
    min_sfr: str
    expert_only: bool
    devices: list
    url: str


def patched_ipsws():
    """The entries the downstream patch puts before upstream's, as shipped."""
    added = []
    for line in PATCH.read_text().split("diff --git a/src/main.py")[1].splitlines():
        if line.startswith("+    IPSW(") or (added and not added[-1].endswith("),")):
            if line.startswith("+"):
                added.append(line[1:].strip())
    source = "[" + " ".join(added) + "]"
    return eval(source, {"IPSW": IPSW})  # noqa: S307 - the repository's own patch


UPSTREAM_IPSWS = [
    IPSW("12.3.1", "12.1", "iBoot-7459.101.3", "21.5.258.0.0,0", False, None, "12.3.1"),
    IPSW("12.3", "12.1", "iBoot-7459.101.2", "21.5.230.0.0,0", False, None, "12.3"),
    IPSW("13.5", "13.0", "iBoot-8422.141.2", "22.7.74.0.0,0", False, None, "13.5"),
    IPSW("14.8.3", "14.6", "iBoot-10151.140.19", "23.10.220.0.0,0", False,
         ["j433ap", "j434ap", "j504ap", "j613ap", "j615ap", "j514sap", "j514cap",
          "j514map", "j516sap", "j516cap", "j516map"], "14.8.3"),
]
IPSW_VERSIONS = patched_ipsws() + UPSTREAM_IPSWS
CHIP_MIN_VER = {0x8103: "11.0", 0x8112: "12.4", 0x8122: "14.8.3", 0x8140: "26.6"}
DEVICE_MIN = {"j313ap": "11.0", "j413ap": "12.4", "j613ap": "14.8.3",
              "j615ap": "14.8.3", "j700ap": "26.6"}
TODAY = ["13.5", "14.8.3", "26.6"]
ON_26_6_2 = dict(sys_firmware="mBoot-18000.161.10", macos_ver="26.6.2",
                 sfr_full_ver="25.7.83.0.0,0")


def mac(device_class, chip_id, **versions):
    sysinfo = SimpleNamespace(device_class=device_class, chip_id=chip_id,
                              **{**ON_26_6_2, **versions})
    return sysinfo, SimpleNamespace(min_ver=DEVICE_MIN[device_class])


def metadata(supported_fw):
    return {"os_list": [{"omarchy_target": "apple-silicon-full-os",
                         "supported_fw": supported_fw}]}


def choose(sysinfo, device, supported_fw):
    ipsw = default_ipsw(IPSW_VERSIONS, CHIP_MIN_VER, sysinfo, device,
                        metadata(supported_fw), split_ver)
    size = stub_size(IPSW_VERSIONS, CHIP_MIN_VER, sysinfo, device,
                     metadata(supported_fw), split_ver,
                     default_size=STUB_SIZE, macos26_size=STUB_SIZE_MACOS26)
    return (ipsw.version if ipsw else None), size


class PatchedFirmwareTableTests(unittest.TestCase):
    def test_the_airs_26_6_2_entry_follows_the_neos_26_6_entry(self):
        neo, air = IPSW_VERSIONS[:2]
        self.assertEqual((neo.version, neo.devices), ("26.6", ["j700ap"]))
        self.assertEqual(air, IPSW(
            "26.6.2", "26.0", "mBoot-18000.161.10", "25.7.83.0.0,0", False,
            ["j613ap", "j615ap", "j700ap"],
            "https://updates.cdn-apple.com/2026SummerFCS/fullrestores/140-75212/"
            "A2A24B94-1FC1-45A3-93F7-C51B02AF1F4D/UniversalMac_26.6.2_25G83_Restore.ipsw"))

    def test_the_patch_sizes_the_stub_and_chooses_firmware_here(self):
        main = PATCH.read_text().split("diff --git a/src/main.py")[1]
        main = main.split("diff --git")[0]
        self.assertIn("+        minver, avail = omarchy_firmware.available_ipsws(", main)
        self.assertIn("+                stub_size=omarchy_firmware.stub_size(", main)
        self.assertNotIn("+                stub_size=(STUB_SIZE_MACOS26", main)


class DefaultFirmwareTests(unittest.TestCase):
    def test_an_air_offered_only_26_6_2_takes_it_and_the_larger_stub(self):
        for device_class in ("j613ap", "j615ap"):
            sysinfo, device = mac(device_class, 0x8122)
            self.assertEqual(choose(sysinfo, device, ["26.6.2"]),
                             ("26.6.2", STUB_SIZE_MACOS26))

    def test_an_air_with_todays_metadata_keeps_14_8_3_and_the_small_stub(self):
        for device_class in ("j613ap", "j615ap"):
            sysinfo, device = mac(device_class, 0x8122)
            self.assertEqual(choose(sysinfo, device, TODAY), ("14.8.3", STUB_SIZE))

    def test_listing_26_6_2_beside_14_8_3_does_not_make_it_the_default(self):
        sysinfo, device = mac("j613ap", 0x8122)
        self.assertEqual(choose(sysinfo, device, ["14.8.3", "26.6.2"]),
                         ("14.8.3", STUB_SIZE))

    def test_an_air_whose_firmware_predates_26_6_2_cannot_take_it(self):
        sysinfo, device = mac("j613ap", 0x8122, sys_firmware="iBoot-11881.140.96",
                              macos_ver="15.6", sfr_full_ver="24.6.69.0.0,0")
        self.assertEqual(choose(sysinfo, device, ["26.6.2"]), (None, STUB_SIZE))

    def test_m1_and_m2_are_unchanged(self):
        for device_class, chip_id in (("j313ap", 0x8103), ("j413ap", 0x8112)):
            sysinfo, device = mac(device_class, chip_id)
            self.assertEqual(choose(sysinfo, device, TODAY), ("13.5", STUB_SIZE))
            # 26.6.2 is not theirs, so offering it alone changes nothing.
            self.assertEqual(choose(sysinfo, device, ["26.6.2"]), (None, STUB_SIZE))

    def test_the_neo_is_unchanged(self):
        sysinfo, device = mac("j700ap", 0x8140)
        self.assertEqual(choose(sysinfo, device, TODAY), ("26.6", STUB_SIZE_MACOS26))
        # Its chip alone sizes the stub, as with the bundled 13.5/14.8.3 list.
        self.assertEqual(choose(sysinfo, device, ["13.5", "14.8.3"]),
                         (None, STUB_SIZE_MACOS26))

    def test_neo_26_6_2_selects_verified_25g83_and_keeps_legacy_available(self):
        sysinfo, device = mac("j700ap", 0x8140)
        selected = default_ipsw(
            IPSW_VERSIONS, CHIP_MIN_VER, sysinfo, device,
            metadata(["26.6", "26.6.2"]), split_ver)
        self.assertEqual(selected.version, "26.6.2")
        self.assertTrue(selected.url.endswith("UniversalMac_26.6.2_25G83_Restore.ipsw"))
        self.assertEqual(choose(sysinfo, device, ["26.6.2"]),
                         ("26.6.2", STUB_SIZE_MACOS26))
        self.assertEqual(choose(sysinfo, device, ["26.6"]),
                         ("26.6", STUB_SIZE_MACOS26))

    def test_an_unreadable_sfr_version_keeps_the_size_the_mac_had(self):
        sysinfo, device = mac("j613ap", 0x8122, sfr_full_ver=None)
        size = stub_size(IPSW_VERSIONS, CHIP_MIN_VER, sysinfo, device,
                         metadata(["26.6.2"]), split_ver,
                         default_size=STUB_SIZE, macos26_size=STUB_SIZE_MACOS26)
        self.assertEqual(size, STUB_SIZE)

    def test_metadata_without_one_omarchy_target_offers_every_version(self):
        sysinfo, device = mac("j613ap", 0x8122)
        ipsw = default_ipsw(IPSW_VERSIONS, CHIP_MIN_VER, sysinfo, device,
                            {"os_list": []}, split_ver)
        self.assertEqual(ipsw.version, "14.8.3")

    def test_avail_keeps_table_order_for_the_last_element_pick(self):
        sysinfo, device = mac("j613ap", 0x8122)
        minver, avail = available_ipsws(IPSW_VERSIONS, CHIP_MIN_VER, sysinfo, device,
                                        None, False, split_ver)
        self.assertEqual([i.version for i in avail], ["26.6.2", "14.8.3"])
        self.assertEqual(minver, avail)


if __name__ == "__main__":
    unittest.main()
