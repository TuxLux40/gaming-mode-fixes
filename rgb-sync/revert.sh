#!/usr/bin/env bash
# revert.sh
# Stops and removes the rgb-sync user units and the config link. Leaves the
# dotfiles (OpenRGB folder, config.toml backup) and the venv alone, and does
# not reinstall openrazer/polychromatic.

set -euo pipefail

UNIT_DIR="$HOME/.config/systemd/user"

systemctl --user disable --now rgb-screen-sync.service openrgb-server.service 2>/dev/null || true
rm -f "$UNIT_DIR/rgb-screen-sync.service" "$UNIT_DIR/openrgb-server.service"
systemctl --user daemon-reload
[[ -L "$HOME/.config/rgb-sync/config.toml" ]] && rm "$HOME/.config/rgb-sync/config.toml"
rm -f "${XDG_STATE_HOME:-$HOME/.local/state}/rgb-sync/portal_restore_token"

echo "rgb-sync removed. LEDs keep their last color until something else sets them."
