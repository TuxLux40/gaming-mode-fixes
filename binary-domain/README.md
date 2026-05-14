# Binary Domain — Linux / Proton fix

Get Binary Domain (Steam AppID 203750) running on CachyOS with an AMD Radeon GPU under
GE-Proton, with working graphics, audio, and gamepad-in-menus.

Tested on:

| Component | Version |
|-----------|---------|
| OS | CachyOS 7.0.5-1 |
| GPU | AMD Radeon RX 7600 (RADV NAVI33), Mesa 26.1.0 |
| Audio | PipeWire 1.6.4, default sink: Razer Leviathan V2 X |
| Steam | userdata `1331516600` |
| Proton | GE-Proton10-34 |

---

## Problems and root causes

### 1. `Critical Error! Graphics device is invalid, please run the configuration tool.`

`BinaryDomain.exe` reads `savedata/UserCFG.txt` and validates the stored Direct3D 9 adapter
GUID against what DXVK returns from `IDirect3D9::GetAdapterIdentifier()`. The game refuses
to launch if the GUIDs don't match, **including when the stored GUID is all-zeros**.

A previous attempt to "clear" the GUID left it as `00000000-0000-0000-0000-000000000000` —
not a valid fallback. The fix is to run `BinaryDomainConfiguration.exe` under the same
Proton/DXVK environment so DXVK enumerates the AMD GPU and the tool writes a real GUID.

### 2. No sound

Binary Domain uses **CRI Audio middleware** (visible in the binary as `CriAuVoice`,
`ADXXAUDIO2`) which loads XAudio 2.7 at runtime via `LoadLibrary("xaudio2_7.dll")`. Wine /
GE-Proton ships FAudio as a substitute, but FAudio's xaudio2_7 doesn't satisfy CRI cleanly.

Fix: install the real Microsoft `xact` redistributable into the Proton prefix via
protontricks (sets `xaudio2_0-7` and `xactengine*` to `native,builtin`), and add a
runtime DLL override as belt-and-suspenders.

Once the GUID error is resolved and the game reaches audio init, this stack works.

### 3. Gamepad works in menus but not in gameplay

Binary Domain's menu input and gameplay input use different paths. The gameplay path
expects raw XInput events. With Steam Input enabled, Steam intercepts XInput and re-emits
through its own virtual device — the gameplay code receives nothing.

Fix: disable Steam Input for app 203750 (`SteamInput = 2` in `localconfig.vdf`).

> Note: even with this fix, Binary Domain has only partial controller support — the game
> itself has known controller bugs on PC. If gameplay still misbehaves, falling back to
> keyboard + mouse may be necessary.

---

## One-time setup recipe

### Prerequisites

- `protontricks` and `protontricks-launch` installed (`pacman -S protontricks` on
  CachyOS/Arch).
- Game installed via Steam — at least one failed launch so Proton creates the prefix at
  `~/.local/share/Steam/steamapps/compatdata/203750/`.

### Step 1 — Install XACT/XAudio2 into the prefix

With Steam running:

```bash
protontricks 203750 xact
```

This installs the Microsoft DirectX SDK XAudio2 / XACT DLLs (xaudio2_0 through
xaudio2_7, xactengine2_*, xactengine3_*, x3daudio1_7, xapofx1_*) into both
`drive_c/windows/system32` and `syswow64` and sets them all to `native,builtin` in the
Wine registry.

`xaudio2_8` and `xaudio2_9` stay as the FAudio implementations bundled with Proton.
`xaudio2_9` is intentionally `"disabled"` in the registry (GE-Proton default) — leave it.

### Step 2 — Generate a valid graphics device GUID

With Steam still running:

```bash
./fix-binary-domain-guid.sh
```

This launches `BinaryDomainConfiguration.exe` via `protontricks-launch`. In the
dialog:

1. Select **AMD Radeon RX 7600** (or whatever your AMD GPU is) from the dropdown.
2. Click **OK** / **Apply**.
3. Close the window.

When the dialog closes, the script:

- Verifies the new GUID is non-zero
- Restores `<options>` to max quality (`aa=2`, all effects on)
- Restores `<resolution>` to `2560×1440 @ 60Hz`

The script also kills any stale `apply-binary-domain-on-steam-exit.sh` watcher so it
doesn't fight you.

### Step 3 — Set Steam launch options + disable Steam Input

Close Steam fully (the file is rewritten by Steam on exit). Then:

```bash
./fix-binary-domain.sh
```

This edits `~/.local/share/Steam/userdata/1331516600/config/localconfig.vdf` for app
`203750` and sets:

```
LaunchOptions  →  DISABLE_GAMESCOPE_WSI=1 PULSE_LATENCY_MSEC=60 WINEDLLOVERRIDES=xaudio2_7=n,b %command%
SteamInput     →  2  (disabled)
```

| Variable | Why |
|----------|-----|
| `DISABLE_GAMESCOPE_WSI=1` | Bypass Gamescope/Wayland WSI for the DXVK D3D9 surface — matters on CachyOS/Wayland and inside Steam Game Mode. |
| `PULSE_LATENCY_MSEC=60` | Higher latency hint to PipeWire's PulseAudio compat layer; avoids crackle/drops. |
| `WINEDLLOVERRIDES=xaudio2_7=n,b` | Runtime override to ensure the `LoadLibrary("xaudio2_7.dll")` call resolves to the native Microsoft DLL installed in Step 1. |
| `SteamInput=2` | Disabled per-game so raw XInput reaches the gameplay code. |

The file is backed up before modification (`localconfig.vdf.bak-<timestamp>`).

### Step 4 — Launch the game

Start Steam. Launch Binary Domain. Done.

---

## Scripts in this folder

| Script | Run when | Steam state | What it does |
|--------|----------|-------------|--------------|
| `fix-binary-domain-guid.sh` | One-time, after `protontricks xact` | **Running** | Launches the in-game config tool via Proton, restores max graphics after |
| `fix-binary-domain.sh` | After `fix-binary-domain-guid.sh` | **Closed** | Writes launch options + `SteamInput=2` into `localconfig.vdf` |
| `apply-binary-domain-on-steam-exit.sh` | Optional background watcher | Either | Polls until Steam exits, then auto-runs `fix-binary-domain.sh` (useful if Steam keeps overwriting localconfig.vdf) |

---

## Verification

After Step 4, the game should:

- Reach the SEGA / Yakuza Studio splash screens without the "Graphics device is invalid"
  popup.
- Play music and sound effects in the main menu and during gameplay.
- Accept controller input throughout the menus.

If audio is still silent, run with `PROTON_LOG=1` prepended to launch options and check
`~/steam-203750.log` for `LoadLibrary` calls for `xaudio2_7.dll` — it should be
`native`, not `builtin`.

If the GUID error returns after a Proton update, re-run `fix-binary-domain-guid.sh`
(DXVK's reported GUID is stable across versions on the same GPU, but a major Proton
overhaul could change things).

---

## Critical paths

| Path | Contents |
|------|----------|
| `~/.local/share/Steam/steamapps/common/Binary Domain/savedata/UserCFG.txt` | Game graphics/audio/input config — holds the adapter GUID and max settings |
| `~/.local/share/Steam/steamapps/compatdata/203750/pfx/` | Proton/Wine prefix where xact DLLs land and DLL overrides live |
| `~/.local/share/Steam/userdata/1331516600/config/localconfig.vdf` | Steam per-user config — launch options + SteamInput per app |

---

## Gotchas

- **The config tool resets graphics to low** every time it saves. `fix-binary-domain-guid.sh`
  patches them back automatically. If you run `BinaryDomainConfiguration.exe` manually,
  edit `UserCFG.txt` afterwards or re-run the script.
- **`UserCFG.txt` lives in the steamapps directory**, not inside the Proton prefix. It
  persists across Proton versions and prefix wipes.
- **DefaultCFG.txt lists only Intel GPUs.** It's a defaults reference, not a whitelist —
  the actual graphics check is GUID-based via D3D9. Don't waste time editing it.
- **Steam rewrites `localconfig.vdf` on exit.** Always close Steam before running
  `fix-binary-domain.sh`, or use the watcher.
- **Binary Domain is a 32-bit game.** The xact installer drops DLLs into both `system32`
  and `syswow64`, which is what we want — the 32-bit exe loads from `syswow64`.
- The watcher logs to `/tmp/binary-domain-fix-watcher.log`.
