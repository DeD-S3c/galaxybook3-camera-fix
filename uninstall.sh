#!/bin/bash
set -euo pipefail
KVER="$(uname -r)"

sudo dkms remove -m ov02c10 -v 1.0 --all 2>/dev/null || true
sudo rm -rf /usr/src/ov02c10-1.0
sudo rm -f "/lib/modules/${KVER}/updates/ov02c10.ko.xz"
sudo rm -f "/lib/modules/${KVER}/extra/ov02c10.ko.xz"
sudo rm -f /usr/share/libcamera/ipa/simple/ov02c10.yaml
sudo depmod -a "$KVER"
sudo modprobe -r ov02c10 2>/dev/null || true
sudo modprobe ov02c10 2>/dev/null || true

echo "Removed. The stock in-tree driver is back (it will reject the 26 MHz"
echo "clock, so the camera will not probe until you reinstall)."
