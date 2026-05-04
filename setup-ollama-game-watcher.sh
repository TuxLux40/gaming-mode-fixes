#!/usr/bin/env bash
# Installs the ollama-game-watcher as a systemd user service.
# Does NOT require root — everything goes under ~/.local and ~/.config.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
SERVICE_DIR="$HOME/.config/systemd/user"
SCRIPT_SRC="$REPO_DIR/scripts/ollama-game-watcher"
SERVICE_NAME="ollama-game-watcher.service"

# ── 1. Install script ─────────────────────────────────────────────────────────
mkdir -p "$BIN_DIR"
install -m 755 "$SCRIPT_SRC" "$BIN_DIR/ollama-game-watcher"
echo "Installed watcher to $BIN_DIR/ollama-game-watcher"

# ── 2. Write service unit ─────────────────────────────────────────────────────
mkdir -p "$SERVICE_DIR"
cat > "$SERVICE_DIR/$SERVICE_NAME" << EOF
[Unit]
Description=Evict Ollama models from VRAM when a Steam game starts
After=ollama.service network.target

[Service]
Type=simple
ExecStart=$BIN_DIR/ollama-game-watcher
Restart=always
RestartSec=5
# Log to journal with a clean identifier
SyslogIdentifier=ollama-game-watcher

[Install]
WantedBy=default.target
EOF
echo "Wrote $SERVICE_DIR/$SERVICE_NAME"

# ── 3. Enable and start ───────────────────────────────────────────────────────
systemctl --user daemon-reload
systemctl --user enable --now "$SERVICE_NAME"
echo "Service enabled and started."

echo ""
echo "Status:"
systemctl --user status "$SERVICE_NAME" --no-pager -l
echo ""
echo "Follow logs with:"
echo "  journalctl --user -u ollama-game-watcher -f"
