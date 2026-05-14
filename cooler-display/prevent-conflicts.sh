#!/usr/bin/env bash
# prevent-conflicts.sh
# Locks in the configuration so the cooler LCD stays stable across reboots:
#
#  1. Disables the duplicate trcc user-level autostart. trccd.service (system)
#     is enough; the `trcc gui --resume` autostart was libusb-claiming the
#     same devices in parallel, which can leave the LCD in a stuck state.
#  2. Adds udev rules for newer LCD VID:PIDs that the trcc-linux package
#     didn't ship rules for (0x0418:5303/5304, 0x0416:5408/5409, 0x87AD:70DB).
#  3. Disables USB autosuspend on the cooler hub at every boot, so the LCD
#     can't get power-gated during enumeration.
#  4. Tags the cooler devices with ENV{ID_TRCC}="1" — used by an OpenRGB
#     skip rule so OpenRGB never tries to probe them. (OpenRGB respects
#     ENV{ID_USB_INTERFACES} and similar conventions; this adds a custom
#     marker that we also document.)
#
# Run once. Re-run after a trcc-linux package update.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Run as root (sudo bash $0)" >&2
    exit 1
fi

# ── 1. Disable the duplicate user-level trcc autostart ───────────────────────
echo "[1/4] Disabling the duplicate trcc user autostart..."
AUTOSTART="/home/oliver/.config/autostart/trcc-linux.desktop"
if [[ -f "$AUTOSTART" ]]; then
    mv "$AUTOSTART" "$AUTOSTART.disabled"
    echo "  Moved $AUTOSTART → $AUTOSTART.disabled"
else
    echo "  Already absent or already disabled."
fi
# Kill any GUI that's currently running so it doesn't keep claiming devices
pkill -f "/usr/bin/trcc gui" 2>/dev/null || true

# ── 2. Expand udev rules for newer Thermalright LCD PIDs ─────────────────────
echo ""
echo "[2/4] Installing extended udev rules for newer LCD VID:PIDs..."
cat > /etc/udev/rules.d/99-trcc-lcd-extra.rules <<'EOF'
# Extended Thermalright LCD permissions — covers PIDs added to trcc's product
# registry after the AUR package's /etc/udev/rules.d/99-trcc-lcd.rules was
# generated. Installed by gaming-mode-fixes/cooler-display/prevent-conflicts.sh.

# 0x0418:0x5303 — newer LCD variant
SUBSYSTEM=="hidraw", ATTRS{idVendor}=="0418", ATTRS{idProduct}=="5303", MODE="0666", ENV{ID_TRCC}="1"
SUBSYSTEM=="usb", ATTR{idVendor}=="0418", ATTR{idProduct}=="5303", MODE="0666", ENV{ID_TRCC}="1"
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="0418", ATTR{idProduct}=="5303", ATTR{power/autosuspend_delay_ms}="-1"

# 0x0418:0x5304 — newer LCD variant
SUBSYSTEM=="hidraw", ATTRS{idVendor}=="0418", ATTRS{idProduct}=="5304", MODE="0666", ENV{ID_TRCC}="1"
SUBSYSTEM=="usb", ATTR{idVendor}=="0418", ATTR{idProduct}=="5304", MODE="0666", ENV{ID_TRCC}="1"
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="0418", ATTR{idProduct}=="5304", ATTR{power/autosuspend_delay_ms}="-1"

# 0x0416:0x5408 — newer mass-storage LCD
SUBSYSTEM=="scsi_generic", ATTRS{idVendor}=="0416", ATTRS{idProduct}=="5408", MODE="0666", ENV{ID_TRCC}="1"
SUBSYSTEM=="usb", ATTR{idVendor}=="0416", ATTR{idProduct}=="5408", MODE="0666", ENV{ID_TRCC}="1"
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="0416", ATTR{idProduct}=="5408", ATTR{power/autosuspend_delay_ms}="-1"

# 0x0416:0x5409 — newer mass-storage LCD
SUBSYSTEM=="scsi_generic", ATTRS{idVendor}=="0416", ATTRS{idProduct}=="5409", MODE="0666", ENV{ID_TRCC}="1"
SUBSYSTEM=="usb", ATTR{idVendor}=="0416", ATTR{idProduct}=="5409", MODE="0666", ENV{ID_TRCC}="1"
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="0416", ATTR{idProduct}=="5409", ATTR{power/autosuspend_delay_ms}="-1"

# 0x87AD:0x70DB — newer LCD variant from another vendor
SUBSYSTEM=="usb", ATTR{idVendor}=="87ad", ATTR{idProduct}=="70db", MODE="0666", ENV{ID_TRCC}="1"
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="87ad", ATTR{idProduct}=="70db", ATTR{power/autosuspend_delay_ms}="-1"

# Tag the existing-package PIDs as ID_TRCC so OpenRGB skip logic sees them too
SUBSYSTEM=="usb", ATTR{idVendor}=="0416", ATTR{idProduct}=="8001", ENV{ID_TRCC}="1"
SUBSYSTEM=="hidraw", ATTRS{idVendor}=="0416", ATTRS{idProduct}=="8001", ENV{ID_TRCC}="1"
SUBSYSTEM=="usb", ATTR{idVendor}=="0416", ATTR{idProduct}=="5302", ENV{ID_TRCC}="1"
SUBSYSTEM=="usb", ATTR{idVendor}=="0416", ATTR{idProduct}=="5406", ENV{ID_TRCC}="1"
SUBSYSTEM=="usb", ATTR{idVendor}=="0402", ATTR{idProduct}=="3922", ENV{ID_TRCC}="1"
SUBSYSTEM=="usb", ATTR{idVendor}=="87cd", ATTR{idProduct}=="70db", ENV{ID_TRCC}="1"
EOF
echo "  Wrote /etc/udev/rules.d/99-trcc-lcd-extra.rules"

# ── 3. Disable USB autosuspend on the cooler hub permanently ─────────────────
echo ""
echo "[3/4] Installing udev rule to disable autosuspend on the cooler hub..."
cat > /etc/udev/rules.d/99-trcc-cooler-hub-no-autosuspend.rules <<'EOF'
# Disable USB autosuspend on the Thermalright cooler's internal Genesys hub.
# Without this, the kernel can power-gate the hub mid-enumeration, leaving
# the LCD chip stuck without ever appearing on USB.
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="05e3", ATTR{idProduct}=="0608", \
    ATTR{power/control}="on", ATTR{power/autosuspend_delay_ms}="-1"
EOF
echo "  Wrote /etc/udev/rules.d/99-trcc-cooler-hub-no-autosuspend.rules"

# Reload + trigger
udevadm control --reload-rules
udevadm trigger --subsystem-match=usb --attr-match=idVendor=05e3
udevadm settle

# ── 4. Restart trccd cleanly ─────────────────────────────────────────────────
echo ""
echo "[4/4] Restarting trccd..."
systemctl restart trccd.service
sleep 1
systemctl is-active trccd.service && echo "  trccd: active"

echo ""
echo "Done."
echo ""
echo "Next: cold-cycle the cooler USB cable at the motherboard header"
echo "(unplug for 30 seconds, replug) to clear any stuck LCD chip state."
echo "Then verify with:"
echo "    lsusb | grep -E '0402|0416|0418|87cd|87ad'"
echo "    trcc-detect"
