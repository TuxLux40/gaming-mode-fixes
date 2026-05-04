#!/usr/bin/env bash
set -euo pipefail

PLUGIN_DIR="/home/oliver/homebrew/plugins/decky-sunshine/py_modules"
TARGET="$PLUGIN_DIR/sunshine.py"
PATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/patches" && pwd)"

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "This script must be run as root (sudo)." >&2
        exit 1
    fi
}

check_target() {
    if [[ ! -f "$TARGET" ]]; then
        echo "Target not found: $TARGET" >&2
        echo "Is decky-sunshine installed?" >&2
        exit 1
    fi
}

backup() {
    local backup="$TARGET.bak"
    if [[ ! -f "$backup" ]]; then
        cp "$TARGET" "$backup"
        echo "Backed up original to $backup"
    else
        echo "Backup already exists at $backup, skipping."
    fi
}

apply_patch() {
    local patch="$PATCH_DIR/decky-sunshine-native-service.patch"
    if patch --dry-run -p1 -d "$PLUGIN_DIR" < "$patch" &>/dev/null; then
        patch -p1 -d "$PLUGIN_DIR" < "$patch"
        echo "Patch applied successfully."
    else
        echo "Patch cannot be applied cleanly — already applied or file has changed." >&2
        echo "Check $TARGET manually or restore from $TARGET.bak and retry." >&2
        exit 1
    fi
}

restart_service() {
    systemctl restart plugin_loader.service
    echo "plugin_loader.service restarted."
}

check_root
check_target
backup
apply_patch
restart_service

echo ""
echo "Done. Decky Sunshine will now recognise the native Sunshine systemd service."
echo "Switch to gaming mode to verify — Sunshine should appear as running in the plugin."
