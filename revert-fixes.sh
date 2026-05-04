#!/usr/bin/env bash
set -euo pipefail

TARGET="/home/oliver/homebrew/plugins/decky-sunshine/py_modules/sunshine.py"
BACKUP="$TARGET.bak"

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (sudo)." >&2
    exit 1
fi

if [[ ! -f "$BACKUP" ]]; then
    echo "No backup found at $BACKUP — nothing to revert." >&2
    exit 1
fi

cp "$BACKUP" "$TARGET"
echo "Restored original sunshine.py from backup."

systemctl restart plugin_loader.service
echo "plugin_loader.service restarted."
