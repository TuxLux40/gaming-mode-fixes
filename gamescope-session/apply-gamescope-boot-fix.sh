#!/usr/bin/env bash
# apply-gamescope-boot-fix.sh
# Stops the intermittent gaming-mode boot hang where plasmalogin relogin-storms
# the gamescope session and the machine appears stuck (requires a force restart).
#
# Root cause: the stock user unit
#   /usr/lib/systemd/user/gamescope-session.service
# does `UnsetEnvironment=DISPLAY XAUTHORITY` but NOT WAYLAND_DISPLAY. A prior
# Plasma session leaks WAYLAND_DISPLAY=wayland-0 into the `systemctl --user`
# manager environment; gamescope inherits it, auto-selects the NESTED wayland
# backend, fails with "Failed to connect to wayland socket: wayland-0", exits 1,
# and the login manager relaunches it in a tight loop.
#
# Same root cause produces the "CreateSwapchainKHR: Creating swapchain for
# non-Gamescope swapchain. Hooking has failed somewhere!" Vulkan popup: when the
# boot drops out of game mode, games run on plain Plasma and the global gamescope
# WSI implicit layer fires that warning. Fix the boot -> games run in gamescope
# -> popup gone. (It is NOT a corrupt Proton prefix; deleting Proton files does
# nothing.)
#
# This script installs a per-user systemd drop-in that adds WAYLAND_DISPLAY to
# the unset list, then clears any currently-leaked vars from the running user
# manager so even a logout->greeter (without a reboot) is covered.
#
# Runs as your normal user (NOT root). No reboot strictly required, but a reboot
# is the real test.

set -euo pipefail

DROPIN_DIR="$HOME/.config/systemd/user/gamescope-session.service.d"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Install the drop-in ───────────────────────────────────────────────────────

mkdir -p "$DROPIN_DIR"
install -m 0644 "$SRC_DIR/gamescope-session.service.d/override.conf" \
    "$DROPIN_DIR/override.conf"
echo "Installed drop-in: $DROPIN_DIR/override.conf"

# ── Reload + clear the live leak ──────────────────────────────────────────────

systemctl --user daemon-reload
systemctl --user unset-environment WAYLAND_DISPLAY DISPLAY XAUTHORITY 2>/dev/null || true

# ── Verify ────────────────────────────────────────────────────────────────────

echo
echo "Effective UnsetEnvironment for gamescope-session.service:"
systemctl --user show gamescope-session.service -p UnsetEnvironment

echo
echo "Done. Reboot to test. After boot, confirm with:"
echo "  journalctl -b 0 | grep -iE 'Started Gamescope Session|wayland socket'"
echo "Want 'Started Gamescope Session', NOT 'Failed to connect to wayland socket'."
