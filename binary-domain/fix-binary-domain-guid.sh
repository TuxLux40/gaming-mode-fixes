#!/usr/bin/env bash
# fix-binary-domain-guid.sh
# Runs BinaryDomainConfiguration.exe under its Proton environment so DXVK
# writes a valid D3D9 adapter GUID into savedata/UserCFG.txt, then restores
# max graphics settings which the config tool resets to low.
#
# Requires: Steam running, protontricks-launch installed (/usr/bin/protontricks-launch)

set -euo pipefail

APP_ID="203750"
GAME_DIR="$HOME/.local/share/Steam/steamapps/common/Binary Domain"
CFG="$GAME_DIR/savedata/UserCFG.txt"

# ── Guards ───────────────────────────────────────────────────────────────────

if ! pgrep -x steam &>/dev/null; then
    echo "ERROR: Steam must be running (protontricks-launch requires it)." >&2
    exit 1
fi

if [[ ! -f "$CFG" ]]; then
    echo "ERROR: UserCFG.txt not found at: $CFG" >&2
    exit 1
fi

# ── Kill stale watcher ────────────────────────────────────────────────────────

if pgrep -f "apply-binary-domain-on-steam-exit" &>/dev/null; then
    echo "Stopping stale apply-binary-domain-on-steam-exit watcher..."
    pkill -f "apply-binary-domain-on-steam-exit" || true
fi

# ── Backup ───────────────────────────────────────────────────────────────────

BACKUP="${CFG}.bak-$(date +%Y%m%d%H%M%S)"
cp "$CFG" "$BACKUP"
echo "Backed up UserCFG.txt to: $BACKUP"

# ── Launch config tool ────────────────────────────────────────────────────────

echo ""
echo "Launching BinaryDomainConfiguration.exe..."
echo "  → Select your AMD Radeon RX 7600 in the dropdown."
echo "  → Click OK or Apply, then close the window."
echo ""

protontricks-launch --appid "$APP_ID" \
    "$GAME_DIR/BinaryDomainConfiguration.exe"

echo ""
echo "Config tool closed. Restoring max graphics settings..."

# ── Restore max settings ──────────────────────────────────────────────────────
# The config tool re-writes the <adapter> block with the correct GUID, but
# resets <options> and <resolution> to low defaults. Patch them back.

python3 - "$CFG" <<'PYEOF'
import sys, re

path = sys.argv[1]
with open(path, 'r', encoding='utf-8') as f:
    content = f.read()

# Verify the adapter GUID was actually updated (not still all-zeros)
guid_match = re.search(r'guid="([^"]+)"', content)
if guid_match:
    guid = guid_match.group(1)
    if guid == "00000000-0000-0000-0000-000000000000":
        print("WARNING: GUID is still all-zeros — did you select a GPU and click OK?", file=sys.stderr)
        print(f"         UserCFG.txt has been patched to max settings anyway.", file=sys.stderr)
        print(f"         Re-run this script if the graphics device error persists.", file=sys.stderr)
    else:
        print(f"  GUID written: {guid}")
else:
    print("WARNING: Could not find guid= attribute in UserCFG.txt", file=sys.stderr)

# Replace <options .../> with max settings
options_max = (
    '<options aa="2" vsync="1" windowed="0" motionblur="1" ssao="1" shadow="1" '
    'reflection="1" inversion="0" control_layout="0" vibration="1" '
    'fov_norm="38" fov_aim="26" volume="100" voice_language="0" />'
)
content, n_opts = re.subn(r'<options\b[^/]*/>', options_max, content)
if n_opts == 0:
    # Handle rare case where options tag spans multiple lines or has no self-close
    content, n_opts = re.subn(r'<options\b.*?>', options_max, content, flags=re.DOTALL)

# Replace <resolution .../> with target resolution
resolution_target = '<resolution width="2560" height="1440" refresh="60" />'
content, n_res = re.subn(r'<resolution\b[^/]*/>', resolution_target, content)

with open(path, 'w', encoding='utf-8') as f:
    f.write(content)

print(f"  Options restored to max (aa=2, all effects on)")
print(f"  Resolution set to 2560×1440 @ 60 Hz")
PYEOF

echo ""
echo "Done. Launch Binary Domain via Steam."
