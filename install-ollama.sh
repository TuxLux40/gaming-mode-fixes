#!/usr/bin/env bash
# Installs Ollama with AMD GPU acceleration, bound to the Tailscale interface.
# Run as root: sudo bash install-ollama.sh
set -euo pipefail

TAILSCALE_IP="100.66.239.31"
OLLAMA_PORT="11434"
DROPIN_DIR="/etc/systemd/system/ollama.service.d"
DROPIN_FILE="$DROPIN_DIR/gaming-server.conf"

if [[ $EUID -ne 0 ]]; then
    echo "Run as root (sudo)." >&2
    exit 1
fi

# ── 1. Install ────────────────────────────────────────────────────────────────
echo "==> Installing ollama..."
pacman -S --noconfirm ollama

# ── 2. GPU group membership ───────────────────────────────────────────────────
# /dev/kfd and /dev/dri/renderD128 are both group 'render' on this system.
echo "==> Adding ollama user to render group (GPU access)..."
usermod -aG render ollama

# ── 3. Systemd drop-in ───────────────────────────────────────────────────────
# - OLLAMA_HOST: bind only to the Tailscale IP so it's not exposed on LAN
# - OLLAMA_KEEP_ALIVE=0: unload model from VRAM immediately after inference,
#   freeing the RX 7600's 8 GB for games when Ollama is idle
# - After/Wants tailscaled: don't try to bind before the Tailscale IP is up
echo "==> Writing systemd drop-in to $DROPIN_FILE..."
mkdir -p "$DROPIN_DIR"
cat > "$DROPIN_FILE" << EOF
[Unit]
After=tailscaled.service
Wants=tailscaled.service

[Service]
Environment="OLLAMA_HOST=${TAILSCALE_IP}:${OLLAMA_PORT}"
Environment="OLLAMA_KEEP_ALIVE=0"
# Give Tailscale a moment to bring the interface up before Ollama tries to bind
ExecStartPre=/bin/sh -c 'for i in \$(seq 30); do ip addr show tailscale0 2>/dev/null | grep -q ${TAILSCALE_IP} && exit 0; sleep 1; done; echo "Tailscale IP not available after 30s" >&2; exit 1'
EOF

# ── 4. Enable and start ───────────────────────────────────────────────────────
echo "==> Enabling and starting ollama.service..."
systemctl daemon-reload
systemctl enable --now ollama.service

echo ""
echo "Done. Ollama is listening on ${TAILSCALE_IP}:${OLLAMA_PORT}"
echo "Test from another Tailscale node:"
echo "  curl http://${TAILSCALE_IP}:${OLLAMA_PORT}/api/tags"
echo ""
echo "Point OpenWebUI's Ollama URL at: http://${TAILSCALE_IP}:${OLLAMA_PORT}"
