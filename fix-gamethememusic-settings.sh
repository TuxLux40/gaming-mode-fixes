#!/usr/bin/env bash
set -euo pipefail

CONFIG="/home/oliver/homebrew/settings/SDH-GameThemeMusic/config.json"

if [[ ! -f "$CONFIG" ]]; then
    echo "Config not found: $CONFIG — is SDH-GameThemeMusic installed?" >&2
    exit 1
fi

# Check if the file still has the broken nested structure
if python3 -c "
import json, sys
with open('$CONFIG') as f:
    data = json.load(f)
sys.exit(0 if 'settings' in data and isinstance(data['settings'], dict) else 1)
" 2>/dev/null; then
    echo "Broken nested structure detected — fixing..."
    python3 - <<'PYEOF'
import json

config_path = "/home/oliver/homebrew/settings/SDH-GameThemeMusic/config.json"
with open(config_path) as f:
    data = json.load(f)

flat = data["settings"]
with open(config_path, "w") as f:
    json.dump(flat, f, indent=4, ensure_ascii=False)
    f.write("\n")
print("Fixed.")
PYEOF
else
    echo "Config already has correct flat structure — nothing to do."
fi
