#!/usr/bin/env bash
# switch-to-user-service.sh — replace trccd.service with a user-level trcc.service
#
# Why: The system daemon (trccd.service) requires sudo to stop/start, which means
# the trcc GUI can't take control of the device without a wrapper script.
# A user-level service (trcc gui --resume) is cleaner: it starts hidden in the
# system tray, handles the display headlessly, and you can open/close the GUI
# window at any time without touching sudo.
#
# What this does:
#   1. Disables and stops trccd.service (system daemon — needs sudo)
#   2. Creates ~/.config/systemd/user/trcc.service
#   3. Enables and starts it immediately
#
# After this, the display is driven by trcc gui --resume running as your user.
# To open the GUI window: click the tray icon, or run `trcc gui`
# (The second launch detects the running instance and raises its window.)
#
# Usage: sudo bash switch-to-user-service.sh

set -euo pipefail

echo "[1/3] Disabling system daemon (trccd.service)..."
systemctl disable --now trccd.service || true

echo "[2/3] Creating user service..."
mkdir -p /home/oliver/.config/systemd/user

cat > /home/oliver/.config/systemd/user/trcc.service << 'EOF'
[Unit]
Description=TRCC cooler display (trcc gui --resume)
After=graphical-session.target
PartOf=graphical-session.target

[Service]
Type=exec
ExecStart=/usr/bin/trcc gui --resume
Restart=on-failure
RestartSec=5
# Pick up DISPLAY/WAYLAND_DISPLAY from gamescope session when running in gaming mode
EnvironmentFile=-%t/gamescope-environment

[Install]
WantedBy=graphical-session.target
EOF

chown oliver:oliver /home/oliver/.config/systemd/user/trcc.service

echo "[3/3] Enabling and starting user service..."
sudo -u oliver systemctl --user daemon-reload
sudo -u oliver systemctl --user enable --now trcc.service

echo ""
echo "Done. Checking status..."
sleep 3
sudo -u oliver systemctl --user status trcc.service --no-pager | head -10
echo ""
echo "Check ~/.trcc/trcc.log for activity."
