#!/usr/bin/env bash
# setup-trcc.sh
# Brings the Thermalright LCD/LED Control Center (trcc-linux) into a working
# state on CachyOS. The AUR/pacman install only drops files in /usr/lib/...,
# but trcc looks for them in /etc/... — so until `trcc setup-udev` runs,
# trcc-detect refuses to drive the device.
#
# This script:
#   1. Runs the official `trcc setup-udev` (copies rules to /etc, installs
#      polkit policy, reloads udev).
#   2. Applies the usb-storage quirks live so any plugged-in LCD shows up
#      as /dev/sgX without a reboot.
#   3. Triggers udev on the cooler USB devices so permissions update on
#      the running session.
#   4. Reports detection status.
#
# Re-run any time after a trcc-linux package update.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Run as root (sudo bash $0)" >&2
    exit 1
fi

if ! command -v trcc &>/dev/null; then
    echo "ERROR: trcc not installed. Install the AUR package 'trcc-linux' first." >&2
    exit 1
fi

# 1. Install /etc/ files via trcc's own routine
echo "[1/4] Running trcc setup-udev..."
trcc setup-udev

# 2. Apply usb-storage quirks live (so LCD shows as /dev/sgX without reboot)
echo ""
echo "[2/4] Applying usb-storage quirks live..."
modprobe sg
modprobe -r uas 2>/dev/null || true   # UAS hangs on these devices — remove first
modprobe -r usb_storage 2>/dev/null || true
modprobe usb_storage quirks=0402:3922:u,0416:5406:u,87cd:70db:u
echo "  Current quirks: $(cat /sys/module/usb_storage/parameters/quirks 2>/dev/null)"

# 3. Reload udev + trigger on cooler USB devices
echo ""
echo "[3/4] Reloading udev rules and triggering on cooler devices..."
udevadm control --reload-rules
for vid_pid in 0402:3922 0416:5302 0416:5406 0416:8001 87cd:70db; do
    vid="${vid_pid%:*}"
    pid="${vid_pid#*:}"
    udevadm trigger --subsystem-match=usb \
        --attr-match="idVendor=$vid" --attr-match="idProduct=$pid" 2>/dev/null || true
    udevadm trigger --subsystem-match=hidraw 2>/dev/null || true
done
udevadm settle

# 4. Detection report
echo ""
echo "[4/4] Detection report:"
trcc-detect 2>&1 | grep -vE "^\[TRCC\] First run|password|sudo|Y]es|N]o|Set up now|Skipped" || true

echo ""
echo "Done."
echo ""
echo "If your LCD shows 'CPU Cooler with LCD' in trcc-detect, run:"
echo "    trcc-lcd"
echo ""
echo "If only the LED ring shows up, check that the LCD USB cable is"
echo "physically connected. The LCD is a separate USB endpoint (vid 0402/0416,"
echo "pid 3922/5406/5302). After plugging it in, re-run this script."
