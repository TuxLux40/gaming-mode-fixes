#!/usr/bin/env bash
# Diagnose and fix Vulkan implicit layers that cause Gamescope's swapchain hook to fail.
#
# Symptom: "CreateSwapchainKHR: Creating swapchain for non-Gamescope swapchain.
#           Hooking has failed somewhere! You may have a bad Vulkan layer interfering."
#
# Usage:
#   bash fix-gamescope-vulkan-layers.sh              # diagnose and print Steam launch opts
#   bash fix-gamescope-vulkan-layers.sh --disable    # rename layer JSONs to .disabled (needs sudo for /usr)
#   bash fix-gamescope-vulkan-layers.sh --enable     # restore renamed layer JSONs

set -euo pipefail

MODE="${1:-}"

LAYER_DIRS=(
  "/etc/vulkan/implicit_layers.d"
  "/usr/share/vulkan/implicit_layers.d"
  "/usr/local/share/vulkan/implicit_layers.d"
  "$HOME/.local/share/vulkan/implicit_layers.d"
)

# These layer names are known to interfere with Gamescope's VkSwapchainKHR hook.
KNOWN_BAD=(
  "VK_LAYER_MANGOHUD_overlay_x86_64"
  "VK_LAYER_MANGOHUD_overlay_x86"
  "VK_LAYER_MANGOHUD_overlay"
  "VK_LAYER_MESA_overlay"
  "VK_LAYER_OBS_hook"
  "VK_LAYER_AMD_switchable_graphics_1"
)

declare -a FOUND_LAYERS=()
declare -a FOUND_FILES=()
declare -a FOUND_DISABLE_ENVS=()
declare -a BAD_LAYERS=()
declare -a BAD_FILES=()
declare -a BAD_DISABLE_ENVS=()

parse_layer_json() {
  local file="$1"
  local name="" disable_env=""

  if command -v jq &>/dev/null; then
    name=$(jq -r '.layer.name // empty' "$file" 2>/dev/null || true)
    disable_env=$(jq -r '.layer.disable_environment | to_entries[0].key // empty' "$file" 2>/dev/null || true)
  else
    name=$(grep -oP '"name"\s*:\s*"\K[^"]+' "$file" 2>/dev/null | head -1 || true)
    disable_env=$(grep -oP '"disable_environment"\s*:\s*\{\s*"\K[^"]+' "$file" 2>/dev/null | head -1 || true)
  fi

  echo "${name}|${disable_env}"
}

is_known_bad() {
  local name="$1"
  for bad in "${KNOWN_BAD[@]}"; do
    [[ "$bad" == "$name" ]] && return 0
  done
  return 1
}

# ── Scan ────────────────────────────────────────────────────────────────────
for dir in "${LAYER_DIRS[@]}"; do
  [[ -d "$dir" ]] || continue
  for file in "$dir"/*.json; do
    [[ -f "$file" ]] || continue
    result=$(parse_layer_json "$file")
    name="${result%%|*}"
    disable_env="${result##*|}"
    [[ -z "$name" ]] && continue

    FOUND_LAYERS+=("$name")
    FOUND_FILES+=("$file")
    FOUND_DISABLE_ENVS+=("$disable_env")

    if is_known_bad "$name"; then
      BAD_LAYERS+=("$name")
      BAD_FILES+=("$file")
      BAD_DISABLE_ENVS+=("$disable_env")
    fi
  done
done

# ── --disable mode ────────────────────────────────────────────────────────
if [[ "$MODE" == "--disable" ]]; then
  if [[ ${#BAD_FILES[@]} -eq 0 ]]; then
    echo "No known-problematic layers found. Nothing to disable."
    exit 0
  fi
  for file in "${BAD_FILES[@]}"; do
    target="${file%.json}.json.disabled"
    if [[ "$file" == /usr/* || "$file" == /etc/* ]]; then
      echo "Disabling (sudo): $file"
      sudo mv "$file" "$target"
    else
      echo "Disabling: $file"
      mv "$file" "$target"
    fi
  done
  echo ""
  echo "Done. Layers disabled. Run with --enable to restore."
  echo "You do NOT need to reboot — relaunch Steam or Gamescope to pick up the change."
  exit 0
fi

# ── --enable mode ─────────────────────────────────────────────────────────
if [[ "$MODE" == "--enable" ]]; then
  found_any=0
  for dir in "${LAYER_DIRS[@]}"; do
    [[ -d "$dir" ]] || continue
    for file in "$dir"/*.json.disabled; do
      [[ -f "$file" ]] || continue
      target="${file%.disabled}"
      if [[ "$file" == /usr/* || "$file" == /etc/* ]]; then
        echo "Restoring (sudo): $file → $target"
        sudo mv "$file" "$target"
      else
        echo "Restoring: $file → $target"
        mv "$file" "$target"
      fi
      found_any=1
    done
  done
  if [[ $found_any -eq 0 ]]; then
    echo "No disabled layer files found (looking for *.json.disabled in layer dirs)."
  else
    echo ""
    echo "Done. Relaunch Steam or Gamescope to pick up the change."
  fi
  exit 0
fi

# ── Diagnose (default) ────────────────────────────────────────────────────
echo "═══ Vulkan implicit layers found ════════════════════════════════════════"
if [[ ${#FOUND_LAYERS[@]} -eq 0 ]]; then
  echo "  (none)"
else
  for i in "${!FOUND_LAYERS[@]}"; do
    name="${FOUND_LAYERS[$i]}"
    file="${FOUND_FILES[$i]}"
    disable="${FOUND_DISABLE_ENVS[$i]}"
    marker=""
    is_known_bad "$name" && marker=" ← ⚠ known Gamescope-breaker"
    printf "  %-55s %s\n" "$name" "$marker"
    printf "    file:    %s\n" "$file"
    [[ -n "$disable" ]] && printf "    disable: %s=1\n" "$disable"
  done
fi

echo ""
echo "═══ Recommended action ══════════════════════════════════════════════════"

if [[ ${#BAD_LAYERS[@]} -eq 0 ]]; then
  echo "  No known-problematic layers found."
  echo "  If you're still seeing the Gamescope swapchain error, one of the"
  echo "  unlisted layers above may be the culprit. Try disabling them one"
  echo "  by one with --disable (after adding their names to KNOWN_BAD above)."
  exit 0
fi

echo ""
echo "  Option A — Per-game Steam launch option (safest, per-title):"
echo "  Add this to Properties → Launch Options for the affected game:"
echo ""

launch_opts=""
for i in "${!BAD_LAYERS[@]}"; do
  env="${BAD_DISABLE_ENVS[$i]}"
  name="${BAD_LAYERS[$i]}"
  if [[ -n "$env" ]]; then
    launch_opts="${launch_opts}${env}=1 "
  else
    # Fallback: generate a plausible disable var from the layer name
    # VK_LAYER_MANGOHUD_overlay_x86_64 → MANGOHUD=0
    case "$name" in
      *MANGOHUD*) launch_opts="${launch_opts}MANGOHUD=0 " ;;
      *MESA_overlay*) launch_opts="${launch_opts}VK_LAYER_MESA_overlay=0 " ;;
      *OBS*) launch_opts="${launch_opts}OBS_VKCAPTURE=0 " ;;
    esac
  fi
done

if [[ -n "$launch_opts" ]]; then
  echo "    ${launch_opts}%command%"
else
  echo "  (no disable env vars known for these layers — use Option B)"
fi

echo ""
echo "  Option B — Disable layer files system-wide (requires sudo for /usr layers):"
echo ""
echo "    bash fix-gamescope-vulkan-layers.sh --disable"
echo "    # restore later:"
echo "    bash fix-gamescope-vulkan-layers.sh --enable"
echo ""
echo "  Note: --disable renames the .json files to .json.disabled — no data is lost."
