#!/usr/bin/env bash
# setup.sh
# Installs the Game Mode screen-sync for the Leviathan V2 X soundbar and the
# ARGB fans on the Aura USB header. Run as your user, not root.
#
# This script:
#   1. Checks the system packages it needs (OpenRGB 1.1, GStreamer PipeWire
#      source, PyGObject, uv).
#   2. Checks that the OpenRGB config comes from the dotfiles `openrgb` stow
#      package (detectors, 15-LED fan zone).
#   3. Builds the Python venv (with system site-packages for PyGObject).
#   4. Links ~/.config/rgb-sync/config.toml to the dotfiles backup.
#   5. Installs and starts the two user units: openrgb-server (sole device
#      owner) and rgb-screen-sync (capture -> LEDs).
#
# Safe to re-run. Undo with ./revert.sh.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES="${DOTFILES:-$HOME/Projects/dotfiles}"
CONFIG_SRC="$DOTFILES/machines/$(hostname)/rgb-sync/config.toml"
UNIT_DIR="$HOME/.config/systemd/user"

if [[ $EUID -eq 0 ]]; then
    echo "ERROR: run as your user, not root." >&2
    exit 1
fi

echo "[1/5] Checking packages..."
missing=()
for pkg in openrgb gst-plugin-pipewire gst-plugins-base-libs python-gobject; do
    pacman -Q "$pkg" &>/dev/null || missing+=("$pkg")
done
command -v uv &>/dev/null || missing+=("uv")
if ((${#missing[@]})); then
    echo "ERROR: missing packages: ${missing[*]}" >&2
    echo "Install with: sudo pacman -S ${missing[*]}" >&2
    exit 1
fi
if [[ "$(command -v openrgb)" != /usr/bin/openrgb ]]; then
    echo "WARNING: 'openrgb' on PATH is $(command -v openrgb), not /usr/bin/openrgb." >&2
    echo "         The units call /usr/bin/openrgb directly; remove the stray copy to avoid confusion." >&2
fi

echo "[2/5] Checking OpenRGB config..."
if [[ -L "$HOME/.config/OpenRGB" ]]; then
    echo "  ~/.config/OpenRGB -> $(readlink "$HOME/.config/OpenRGB")"
else
    echo "WARNING: ~/.config/OpenRGB is not the dotfiles stow link." >&2
    echo "         Run: stow -d $DOTFILES -t ~ openrgb   (after moving the old folder away)" >&2
fi

echo "[3/5] Building venv..."
cd "$HERE"
if [[ ! -x .venv/bin/python ]]; then
    uv venv -q --python /usr/bin/python3 --system-site-packages
fi
uv sync -q
.venv/bin/python -c "import gi, numpy, openrgb" || { echo "ERROR: venv imports failed" >&2; exit 1; }

echo "[4/5] Linking config..."
mkdir -p "$HOME/.config/rgb-sync"
if [[ -f "$CONFIG_SRC" ]]; then
    ln -sfn "$CONFIG_SRC" "$HOME/.config/rgb-sync/config.toml"
    echo "  ~/.config/rgb-sync/config.toml -> $CONFIG_SRC"
else
    echo "  No $CONFIG_SRC; running on built-in defaults."
fi

echo "[5/5] Installing user units..."
mkdir -p "$UNIT_DIR"
cp "$HERE/systemd/openrgb-server.service" "$HERE/systemd/rgb-screen-sync.service" "$UNIT_DIR/"
systemctl --user daemon-reload
systemctl --user enable --now openrgb-server.service rgb-screen-sync.service

echo ""
sleep 3
systemctl --user --no-pager --lines=0 status openrgb-server.service rgb-screen-sync.service | grep -E '●|Active:'
echo ""
echo "Logs: journalctl --user -u rgb-screen-sync -f"
echo "In Desktop Mode, KDE asks once for screen-sharing permission."
