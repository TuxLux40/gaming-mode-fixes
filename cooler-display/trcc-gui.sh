#!/usr/bin/env bash
# trcc-gui.sh — launch trcc gui without conflicting with trccd.service
#
# Problem: trccd.service holds the USB device and runs the metrics loop.
# If you also run `trcc gui` directly, two processes fight over the same
# USB device — the GUI's changes get overwritten by the daemon within 50ms.
#
# This wrapper:
#   1. Stops trccd.service so the GUI has exclusive USB access
#   2. Runs trcc gui (you can change themes, configure display, etc.)
#   3. Restarts trccd.service when the GUI closes
#
# Usage:  bash trcc-gui.sh
# Or add to your app launcher / keyboard shortcut.

set -euo pipefail

DAEMON=trccd.service

echo "[trcc-gui] Stopping $DAEMON..."
sudo systemctl stop "$DAEMON"

echo "[trcc-gui] Launching trcc gui — close the window when done."
trcc gui || true   # don't fail the script if the GUI exits non-zero

echo "[trcc-gui] GUI closed. Restarting $DAEMON..."
sudo systemctl start "$DAEMON"

echo "[trcc-gui] Done — daemon is running, display should show temps shortly."
