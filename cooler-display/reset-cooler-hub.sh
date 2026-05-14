#!/usr/bin/env bash
# reset-cooler-hub.sh
# Isolates the Thermalright cooler USB hub from every piece of software that
# might be probing it (OpenRGB, the trcc daemon, the trcc autostart GUI),
# disables autosuspend, force-re-enumerates the hub, then reports what's there.
#
# Usage:
#   sudo bash reset-cooler-hub.sh                # full reset, no software restored
#   sudo bash reset-cooler-hub.sh --restart-trcc # also bring trccd back at the end
#
# Diagnostic for the "LCD doesn't enumerate" problem when both OpenRGB and
# the trcc GUI are libusb-poking the cooler at boot.

set -euo pipefail

RESTART_TRCC=0
[[ "${1:-}" == "--restart-trcc" ]] && RESTART_TRCC=1

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Run as root (sudo bash $0 [--restart-trcc])" >&2
    exit 1
fi

# Locate the cooler hub by its USB IDs (Genesys 05e3:0608)
HUB=""
for d in /sys/bus/usb/devices/*; do
    [[ -f "$d/idVendor" ]] || continue
    if [[ "$(cat $d/idVendor)" == "05e3" && "$(cat $d/idProduct)" == "0608" ]]; then
        HUB=$(basename "$d")
        break
    fi
done

[[ -z "$HUB" ]] && { echo "ERROR: Cooler hub (05e3:0608) not found." >&2; exit 1; }
echo "Cooler hub: /sys/bus/usb/devices/$HUB"

# ── Step 1: stop every process that might hold cooler USB devices ─────────────
echo ""
echo "[1/6] Stopping all software that might hold cooler USB devices..."

# System-level trcc daemon
systemctl stop trccd.service 2>/dev/null || true

# User-level trcc GUI from autostart (runs as the login user, not root)
for pid in $(pgrep -f "/usr/bin/trcc"); do
    [[ "$pid" == "$$" ]] && continue
    kill "$pid" 2>/dev/null || true
done

# Any running OpenRGB (server, GUI, plugin)
pkill -f openrgb 2>/dev/null || true

# Give them a moment to release file handles
sleep 2

# Verify nothing still holds the cooler's libusb interface
LED_USB=""
for d in /sys/bus/usb/devices/*; do
    [[ -f "$d/idVendor" ]] || continue
    if [[ "$(cat $d/idVendor)" == "0416" && "$(cat $d/idProduct)" == "8001" ]]; then
        busnum=$(cat "$d/busnum")
        devnum=$(cat "$d/devnum")
        LED_USB=$(printf "/dev/bus/usb/%03d/%03d" "$busnum" "$devnum")
        break
    fi
done
if [[ -n "$LED_USB" ]]; then
    holders=$(lsof "$LED_USB" 2>/dev/null | tail -n +2 | awk '{print $1, $2}' | sort -u || true)
    if [[ -n "$holders" ]]; then
        echo "  WARN: still holding $LED_USB:"
        echo "$holders" | sed 's/^/    /'
        echo "  killing forcefully..."
        lsof -t "$LED_USB" 2>/dev/null | xargs -r kill -9 || true
        sleep 1
    else
        echo "  $LED_USB is free."
    fi
fi

# ── Step 2: disable autosuspend on the hub and its parent ─────────────────────
echo ""
echo "[2/6] Disabling USB autosuspend on the cooler hub..."
echo on > "/sys/bus/usb/devices/$HUB/power/control"
echo "  $HUB/power/control = $(cat /sys/bus/usb/devices/$HUB/power/control)"
PARENT=$(readlink -f "/sys/bus/usb/devices/$HUB/.." | xargs basename)
if [[ -f "/sys/bus/usb/devices/$PARENT/power/control" ]]; then
    echo on > "/sys/bus/usb/devices/$PARENT/power/control"
    echo "  parent $PARENT/power/control = $(cat /sys/bus/usb/devices/$PARENT/power/control)"
fi

# ── Step 3: force the hub to re-enumerate its children ────────────────────────
echo ""
echo "[3/6] Unbinding + rebinding the cooler hub to force re-enumeration..."
echo "$HUB" > /sys/bus/usb/drivers/usb/unbind
sleep 2
echo "$HUB" > /sys/bus/usb/drivers/usb/bind
sleep 4

# ── Step 4: report what came up on each port of the cooler hub ────────────────
echo ""
echo "[4/6] Cooler hub port population:"
for port in 1 2 3 4; do
    p="/sys/bus/usb/devices/$HUB.$port"
    if [[ -d "$p" ]]; then
        vid=$(cat "$p/idVendor" 2>/dev/null)
        pid=$(cat "$p/idProduct" 2>/dev/null)
        prod=$(cat "$p/product" 2>/dev/null || echo "?")
        echo "  Port $port: $vid:$pid  $prod"
    else
        echo "  Port $port: <empty>"
    fi
done

# ── Step 5: full Thermalright-PID listing ─────────────────────────────────────
echo ""
echo "[5/6] All Thermalright-class USB devices on the system:"
lsusb | grep -E '0402:|0416:|87cd:' || echo "  (none found beyond the LED)"

# ── Step 6: trcc detection report ─────────────────────────────────────────────
echo ""
echo "[6/6] trcc-detect:"
trcc-detect 2>&1 | grep -vE 'First run|password|sudo|Y\]es|N\]o|Set up now|Skipped|^$' || true

# Optional: bring trccd back
if [[ "$RESTART_TRCC" == "1" ]]; then
    echo ""
    echo "Restarting trccd (no user GUI)..."
    systemctl start trccd.service
fi

echo ""
echo "Done."
echo ""
echo "Interpretation:"
echo "  - LCD shows up in step 4 or 5  → conflict was software-side. The user-level"
echo "    trcc GUI autostart was claiming the LED in parallel with trccd; killing"
echo "    it + the hub reset cleared the stuck enumeration. Disable the autostart"
echo "    so this doesn't recur:"
echo "      mv ~/.config/autostart/trcc-linux.desktop ~/.config/autostart/trcc-linux.desktop.disabled"
echo ""
echo "  - LCD still missing  → either OpenRGB previously poisoned the LCD's USB"
echo "    state and only a power cycle of the pump will recover it, or the LCD"
echo "    USB sub-cable inside the pump head is loose. Try unplugging the cooler"
echo "    USB cable from the motherboard for 30 seconds, then replug."
