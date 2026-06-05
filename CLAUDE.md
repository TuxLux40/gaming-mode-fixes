# gaming-mode-fixes — Handoff for Claude Code

Patches and scripts for a CachyOS gaming setup (Decky Loader + Sunshine + Steam Game
Mode) and per-game fixes.

## Layout

```
gaming-mode-fixes/
├── README.md                                  # Decky/Sunshine + Ollama + Game Theme Music fixes
├── apply-fixes.sh                             # Decky Sunshine patch installer (sudo)
├── revert-fixes.sh                            # Decky Sunshine patch reverter (sudo)
├── fix-gamethememusic-settings.sh             # Game Theme Music config.json fix
├── sync-models-to-nas.sh                      # Ollama model NAS sync
├── patches/
│   └── decky-sunshine-native-service.patch
├── fix-gamescope-vulkan-layers.sh             # Gamescope swapchain hook fix (diagnose/disable/enable)
├── scripts/                                   # (placeholder for future helpers)
├── binary-domain/                             # ← Binary Domain (AppID 203750) fix
│   ├── README.md                              #     full recipe + root-cause notes
│   ├── fix-binary-domain-guid.sh              #     run the config tool to regen GUID
│   ├── fix-binary-domain.sh                   #     set launch options + disable Steam Input
│   └── apply-binary-domain-on-steam-exit.sh   #     optional background watcher
└── cooler-display/                            # ← Thermalright cooler TRCC setup
    ├── README.md                              #     trcc-linux setup + cooler USB notes
    └── setup-trcc.sh                          #     sudo wrapper around `trcc setup-udev`
```

## Gamescope Vulkan layer fix

**Symptom:** "CreateSwapchainKHR … Hooking has failed somewhere! You may have a bad Vulkan layer interfering."

**Root cause:** A Vulkan implicit layer (MangoHud, Mesa overlay, OBS vkcapture, AMD switchable graphics) intercepts `vkCreateSwapchainKHR` before Gamescope's hook, wrapping the swapchain object into a foreign type that Gamescope rejects.

Script: `fix-gamescope-vulkan-layers.sh` — diagnose (default), disable (`--disable`, needs sudo for `/usr` layers), or re-enable (`--enable`).

## Per-game fixes

### Binary Domain (AppID 203750)

Documented in `binary-domain/README.md`. Three issues addressed:

1. **"Graphics device is invalid"** — `UserCFG.txt` stored an all-zeros D3D9 adapter
   GUID. Fix: run `BinaryDomainConfiguration.exe` via `protontricks-launch` so DXVK
   writes a real GUID. Script: `binary-domain/fix-binary-domain-guid.sh`.
2. **No sound** — CRI Audio middleware loads `xaudio2_7.dll` at runtime. Fix:
   `protontricks 203750 xact` installs native Microsoft DLLs, and
   `WINEDLLOVERRIDES=xaudio2_7=n,b` is set as a runtime backup. The DSOUND import in
   `BinaryDomain.exe` is a red herring — actual audio path is XAudio2 via CRI.
3. **Gamepad fails in gameplay (works in menus)** — Steam Input intercepts XInput. Fix:
   `SteamInput=2` in `localconfig.vdf`. Script: `binary-domain/fix-binary-domain.sh`.

Even with the gamepad fix the game has only partial controller support — known issue
with the PC port itself, not the Linux port.

## Peripheral fixes

### Thermalright cooler (TRCC)

Documented in `cooler-display/README.md`. The AUR package `trcc-linux` ships udev
rules / modprobe quirks / polkit policy under `/usr/lib/...`, but `trcc-detect`
checks for them at `/etc/...` and refuses to run until they're copied there.
Script: `cooler-display/setup-trcc.sh` (wraps `trcc setup-udev` + live module
reload so no reboot is needed).

Current hardware state: only the LED ring (`0416:8001`) enumerates over USB —
the LCD interface (`0416:5406` or similar) is not connected. After running the
setup script, replugging the LCD cable should bring it up.

#### ⚠️ Known fork-bomb bug (trcc-linux ≤ 9.6.5, filed upstream)

**Symptom:** Dozens of `trcc daemon` processes running, memory climbing.

**Root cause (introduced 2026-05-14 in this repo):** `/etc/profile.d/trcc.sh`
sets `TRCC_DAEMON=1` globally. `ensure_daemon()` spawns `trcc daemon` via
`subprocess.Popen` without clearing this env var. The daemon inherits it,
`run_daemon()` calls `_build_trcc()` → `_boot.trcc()` sees `TRCC_DAEMON=1` →
tries `ensure_daemon()` before its own socket is bound → spawns another daemon →
infinite fork chain.

**Upstream fix (filed as GitHub issue #162, pending):** `run_daemon()` must
`os.environ.pop('TRCC_DAEMON', None)` before calling `_build_trcc()`.

**Immediate recovery:**
```bash
systemctl --user stop trccd.service
systemctl --user stop 'app-trcc\x2dlinux@autostart.service'
# kill any surviving daemons:
# ps aux | grep "trcc daemon" | awk '{print $2}' | xargs kill
systemctl --user start trccd.service   # clean restart
```

**Prevention until upstream fix lands:** The fork bomb only triggers when
`TRCC_DAEMON=1` is in the environment AND something calls `trcc daemon` directly
(e.g. the XDG autostart, honcho, or any agent session spawner that starts a new
login-shell environment). Currently mitigated by the XDG autostart running
`trcc gui --resume` which calls `ensure_daemon()` once — the race only manifests
when multiple concurrent spawns happen before the socket is ready.

### OpenRGB

Working. Detects Razer Leviathan V2 X soundbar, ASUS TUF B550M motherboard, and
Logitech G915 keyboard. Writes are confirmed working (`openrgb --device 0 --mode
Static --color FFFFFF` lights the soundbar underglow). No script needed.

Known sharp edges:
- The Thermalright cooler LED ring is not supported by OpenRGB — use trcc.
- OpenRGB can hang briefly when a USB peripheral is disconnected during a poll
  cycle. Workaround: avoid disconnecting USB devices while the OpenRGB GUI or
  server is actively writing.

## System context

| Component | Value |
|-----------|-------|
| OS | CachyOS Linux (Arch-based), kernel 7.0.5 |
| GPU | AMD Radeon RX 7600 (RADV NAVI33) — vendor `0x1002`, device `0x7480` |
| Audio | PipeWire 1.6.4 — default sink: Razer Leviathan V2 X soundbar |
| Steam userdata | `1331516600` |
| Proton | GE-Proton10-34 (`~/.local/share/Steam/compatibilitytools.d/GE-Proton10-34/`) |

## Working assumptions

- Use `protontricks` / `protontricks-launch` for any per-prefix work. `protontricks` for
  packages, `protontricks-launch` for executing binaries inside the prefix.
- For files Steam owns (`localconfig.vdf`), Steam must be closed before editing —
  Steam overwrites them on exit.
- Wine registry DLL overrides in `pfx/user.reg` apply prefix-wide; `WINEDLLOVERRIDES`
  in Steam launch options is a per-launch runtime override.
- Per-game lives under `<game>/` subfolders to keep root flat.
