# Binary Domain Linux Fix — Handoff for Claude Code

## Context

OS: CachyOS Linux (Arch-based), kernel 6.x  
GPU: AMD Radeon RX 7600 (RADV NAVI33) — vendorid=4098 (0x1002), deviceid=29824 (0x7480)  
Audio: PipeWire 1.6.4, default sink = Razer Leviathan V2 X soundbar  
Steam: running, user ID `1331516600`  
Proton: GE-Proton10-34 (`~/.local/share/Steam/compatibilitytools.d/GE-Proton10-34/`)  
Game: **Binary Domain** — AppID `203750`, installed at:
```
~/.local/share/Steam/steamapps/common/Binary Domain/
```
Proton prefix: `~/.local/share/Steam/steamapps/compatdata/203750/`

---

## Three Problems to Fix

### 1. ❌ "Critical Error! Graphics device is invalid, please run the configuration tool."

The game shows this every launch. It reads `savedata/UserCFG.txt`, validates the stored adapter
GUID against what DXVK currently returns from `IDirect3D9::GetAdapterIdentifier()`, and fails
if they don't match.

**What happened:**
- The original `UserCFG.txt` (backed up at `UserCFG.txt.bak`) had:
  ```xml
  guid="00000000-0003-0000-0000-000000000000"
  adapterid="MONITOR\ACR0507\{4D36E96E-E325-11CE-BFC1-08002BE10318}\0000"
  name="\\.\DISPLAY1"
  ```
- A previous attempt cleared those fields to empty/zeros:
  ```xml
  guid="00000000-0000-0000-0000-000000000000"
  adapterid=""
  name=""
  ```
- The error persists — the game still rejects it. All-zeros GUID is not a valid fallback.

**What needs to happen:**  
Run the game's own config tool (`BinaryDomainConfiguration.exe`) under the game's Proton
environment so it re-enumerates D3D9 adapters and writes a fresh, valid `UserCFG.txt`.

```bash
protontricks-launch --appid 203750 \
  "$HOME/.local/share/Steam/steamapps/common/Binary Domain/BinaryDomainConfiguration.exe"
```

`protontricks-launch` is installed (`/usr/bin/protontricks-launch`). Steam must be running.
After this, `UserCFG.txt` should have the current DXVK GUID and correct adapter info.

**Then** restore graphics to max (the config tool defaults to low settings):
```xml
<options aa="2" vsync="1" windowed="0" motionblur="1" ssao="1" shadow="1"
         reflection="1" inversion="0" control_layout="0" vibration="1"
         fov_norm="38" fov_aim="26" volume="100" voice_language="0" />
<resolution width="2560" height="1440" refresh="60" />
```
`UserCFG.txt` is at `~/.local/share/Steam/steamapps/common/Binary Domain/savedata/UserCFG.txt`

---

### 2. ❌ No sound

**Current state (already good):**
- XACT/XAudio2 DLLs (xaudio2_0–7, xactengine2_0–8, xactengine3_0–7) are installed in the
  Proton prefix and set to `native,builtin` in the Wine registry. ✅
- `PULSE_LATENCY_MSEC=60` is already in the launch options. ✅

**Still needed:**
- `WINEDLLOVERRIDES=xaudio2_7=n,b` should be added to launch options as an explicit env var
  (belt-and-suspenders alongside the registry override).
- Steam Input should be **disabled** for this game (`SteamInput = 2` in localconfig.vdf).

---

### 3. ❌ Gamepad works in menus but not during gameplay

**Root cause:** Steam Input intercepts raw XInput events. Binary Domain's menu system uses
a different input path that survives the interception; the gameplay input code expects raw
XInput and gets nothing.

**Fix:** Set `SteamInput = 2` (disabled) in `localconfig.vdf` for app 203750.

---

## Files to Modify

### A. `~/.local/share/Steam/steamapps/common/Binary Domain/savedata/UserCFG.txt`

Let the config tool regenerate this (see Problem 1), then patch graphics settings back to max.

### B. `~/.local/share/Steam/userdata/1331516600/config/localconfig.vdf`

**Must be done while Steam is CLOSED** (Steam overwrites this file on exit).

Find the `"203750"` block that contains `"LastPlayed"` (not the token-hash occurrence at the
top of the file). Update/add two entries:

```
"LaunchOptions"    "DISABLE_GAMESCOPE_WSI=1 PULSE_LATENCY_MSEC=60 WINEDLLOVERRIDES=xaudio2_7=n,b %command%"
"SteamInput"       "2"
```

A script `fix-binary-domain.sh` in this repo already does this correctly — just run it with
Steam closed.

---

## Script Already Written

`./fix-binary-domain.sh` — handles the localconfig.vdf edit (Problems 2 & 3).  
Run it with Steam closed. It backs up the file before modifying.

---

## Key Facts / Gotchas

- **DefaultCFG.txt** lists only Intel GPUs — the game is NOT whitelist-checking vendorid; the
  actual validation is GUID-based via D3D9.
- **DXVK** (`v2.7.1-509-g1676dcaf342a9b1`) correctly finds the AMD GPU:
  `"Found device: AMD Radeon RX 7600 (RADV NAVI33) (radv 26.1.0)"` — Vulkan/D3D9 layer is fine.
- **`xaudio2_9` is intentionally disabled** in the Wine registry
  (`"xaudio2_9"="disabled"`) — this is GE-Proton's default to avoid FAudio conflicts. Don't
  change it; Binary Domain uses xaudio2_7.
- **`control_layout="0"`** in UserCFG.txt = gamepad/XInput mode — keep it.
- **UserCFG.txt is in the steamapps directory**, NOT inside the Proton prefix. It is shared
  across Proton versions.
- The Proton log for the last launch is at `~/steam-203750.log` (PROTON_LOG=1 is set).
- The watcher `apply-binary-domain-on-steam-exit.sh` may still be running in the background
  (check with `pgrep -f apply-binary-domain`). Kill it before doing manual work.

---

## Recommended Order of Operations

1. Kill any stale watcher: `pkill -f apply-binary-domain-on-steam-exit.sh`
2. With **Steam running**, run the config tool to regenerate UserCFG.txt:
   ```bash
   protontricks-launch --appid 203750 \
     "$HOME/.local/share/Steam/steamapps/common/Binary Domain/BinaryDomainConfiguration.exe"
   ```
   Select the AMD GPU in the dialog, apply, close.
3. Immediately patch UserCFG.txt back to max graphics / 2560×1440 / 60Hz.
4. **Close Steam.**
5. Run `./fix-binary-domain.sh` to update localconfig.vdf.
6. Start Steam, launch Binary Domain.
