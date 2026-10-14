#!/bin/bash
# SPDX-License-Identifier: MIT
# Never reset a running device. Repeated modprobe of a loaded module is inert.
set -eu

has_firmware() {
  [ -s "/lib/firmware/vendor/$1" ] || [ -s "/lib/firmware/$1" ]
}

neo=false
if grep -aq 'apple,j700' /sys/firmware/devicetree/base/compatible; then
  neo=true
  for name in \
    apple/j700-aop-als-cal.bin apple/tpmtfw-j700.bin \
    mediatek/mt7932/IZUBA_WIFI_MT7932_patch_mcu_1_2_hdr.bin \
    mediatek/mt7932/IZUBA_W7932_2.bin \
    mediatek/mt7932/ppr.bin mediatek/mt7932/oca2.bin \
    mediatek/mt7932/wcal.bin mediatek/mt7932/config-original.bin \
    mediatek/MT7932B0_OS_TypeB_0.1.44.0_241001003711.bin \
    mediatek/MT7932B1_OS_TypeB_0.1.133.0_260128190103.bin \
    mediatek/MT7932_PTB_IzubaA_0.1.0.0_20251021141303.ptx \
    mediatek/j700-mt7932-btcal.bin mediatek/j700-mt7932-bdaddr.bin \
    mediatek/mt7932/policy/world-XZ.bin; do
    if ! has_firmware "$name"; then
      echo "Aurora: required firmware is missing: $name; peripheral probe deferred" >&2
      exit 1
    fi
  done
fi

modprobe aop
if "$neo"; then
  modprobe mt7932-fullmac
fi
# Bluetooth is deliberately admitted later by its existing gated PCI service,
# after root firmware extraction. It is not necessary to unlock the root disk.
