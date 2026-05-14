#!/usr/bin/env bash
# apply-binary-domain-on-steam-exit.sh
# Waits for Steam to close, then applies Binary Domain config fixes.
# Runs in the background (launched automatically by fix-binary-domain.sh
# when Steam is open).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIX_SCRIPT="$SCRIPT_DIR/fix-binary-domain.sh"
LOGFILE="/tmp/binary-domain-fix-watcher.log"
TIMEOUT_HOURS=24
TIMEOUT_SECS=$(( TIMEOUT_HOURS * 3600 ))
DEADLINE=$(( $(date +%s) + TIMEOUT_SECS ))

echo "[$(date)] Watcher started. Waiting for Steam to close (timeout: ${TIMEOUT_HOURS}h)." | tee -a "$LOGFILE"

while pgrep -x steam &>/dev/null; do
    if (( $(date +%s) >= DEADLINE )); then
        echo "[$(date)] Timeout reached after ${TIMEOUT_HOURS}h. Watcher exiting without applying fix." | tee -a "$LOGFILE"
        exit 1
    fi
    sleep 5
done

echo "[$(date)] Steam has closed. Applying Binary Domain fix..." | tee -a "$LOGFILE"
bash "$FIX_SCRIPT" 2>&1 | tee -a "$LOGFILE"
echo "[$(date)] Done." | tee -a "$LOGFILE"

# Notify via libnotify if available
if command -v notify-send &>/dev/null; then
    notify-send "Binary Domain Fix" "Steam config applied successfully (SteamInput disabled, launch options updated)." --icon=steam 2>/dev/null || true
fi
