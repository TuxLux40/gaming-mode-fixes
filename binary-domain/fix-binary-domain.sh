#!/usr/bin/env bash
# fix-binary-domain.sh
# Applies Steam config fixes for Binary Domain (AppID 203750):
#   1. Updates launch options (audio DLL override, disable gamescope WSI)
#   2. Disables Steam Input so gamepad XInput events reach the game directly
#
# Must be run while Steam is CLOSED.

set -euo pipefail

APP_ID="203750"
LOCALCONFIG="$HOME/.local/share/Steam/userdata/1331516600/config/localconfig.vdf"
NEW_LAUNCH_OPTS='DISABLE_GAMESCOPE_WSI=1 PULSE_LATENCY_MSEC=60 WINEDLLOVERRIDES=xaudio2_7=n,b %command%'

# ── Guards ──────────────────────────────────────────────────────────────────

if pgrep -x steam &>/dev/null; then
    echo "ERROR: Steam is currently running." >&2
    echo "Please close Steam completely, then re-run this script." >&2
    exit 1
fi

if [[ ! -f "$LOCALCONFIG" ]]; then
    echo "ERROR: localconfig.vdf not found at: $LOCALCONFIG" >&2
    exit 1
fi

# ── Backup ───────────────────────────────────────────────────────────────────

BACKUP="${LOCALCONFIG}.bak-$(date +%Y%m%d%H%M%S)"
cp "$LOCALCONFIG" "$BACKUP"
echo "Backed up localconfig.vdf to: $BACKUP"

# ── Apply changes via Python ─────────────────────────────────────────────────

python3 - "$LOCALCONFIG" "$APP_ID" "$NEW_LAUNCH_OPTS" <<'PYEOF'
import sys, re

localconfig_path = sys.argv[1]
app_id           = sys.argv[2]
new_launch_opts  = sys.argv[3]

with open(localconfig_path, 'r', encoding='utf-8') as f:
    lines = f.readlines()

# Line-by-line state machine to find the game-data "203750" block.
# The block we want contains "LastPlayed" (and optionally "LaunchOptions").
# There are other "203750" occurrences (token hashes) that are plain key=value lines.

state       = 'searching'
depth       = 0
in_target   = False
target_start_i = -1
launch_opts_i  = -1
steam_input_i  = -1
block_end_i    = -1

i = 0
while i < len(lines):
    line    = lines[i]
    stripped = line.strip()

    if state == 'searching':
        # Match a line that is ONLY the app_id key (no value on same line)
        if re.match(r'^\s+"' + re.escape(app_id) + r'"\s*$', line):
            state = 'found_id'
            target_start_i = i

    elif state == 'found_id':
        if stripped == '{':
            state = 'in_block'
            depth = 1
        elif stripped != '':
            # Not a block opener – false alarm, keep searching
            state = 'searching'
            target_start_i = -1

    elif state == 'in_block':
        if stripped == '{':
            depth += 1
        elif stripped == '}':
            depth -= 1
            if depth == 0:
                block_end_i = i
                state = 'done'
                break
        # Capture positions at depth==1 (direct children of our block)
        if depth == 1:
            if '"LaunchOptions"' in stripped:
                launch_opts_i = i
            if '"SteamInput"' in stripped:
                steam_input_i = i

    i += 1

if state != 'done' or block_end_i == -1:
    print(f"ERROR: Could not locate app {app_id} game-data block", file=sys.stderr)
    sys.exit(1)

# --- Determine indentation from surrounding lines ---
indent = re.match(r'^(\s+)', lines[block_end_i]).group(1) if re.match(r'^(\s+)', lines[block_end_i]) else '\t\t\t\t\t'

# --- Update or insert LaunchOptions ---
new_lo_line = indent + '"LaunchOptions"\t\t"' + new_launch_opts + '"\n'
if launch_opts_i != -1:
    lines[launch_opts_i] = new_lo_line
    insert_after = launch_opts_i
else:
    # Insert just before the closing brace
    lines.insert(block_end_i, new_lo_line)
    block_end_i += 1  # closing brace shifted
    insert_after = block_end_i - 1

# --- Update or insert SteamInput ---
if steam_input_i != -1:
    lines[steam_input_i] = indent + '"SteamInput"\t\t"2"\n'
else:
    lines.insert(insert_after + 1, indent + '"SteamInput"\t\t"2"\n')

with open(localconfig_path, 'w', encoding='utf-8') as f:
    f.writelines(lines)

print(f"Updated app {app_id}:")
print(f"  LaunchOptions → {new_launch_opts}")
print(f"  SteamInput    → 2 (disabled)")
PYEOF

echo ""
echo "Done. You can now start Steam and launch Binary Domain."
