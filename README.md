# gaming-mode-fixes

Patches and scripts for CachyOS Deckify (and similar SteamOS-like distros) where Decky Loader and Sunshine are both installed but don't play well together out of the box.

> **Already applied:** The Game Theme Music settings fix (`fix-gamethememusic-settings.sh`) has already been run — `config.json` is correct. The decky-sunshine patch still needs `! sudo bash apply-fixes.sh`.

## Issues fixed

### 1. Decky Loader appearing broken / slow to initialise in gaming mode

**Symptom:** Decky's quick-access menu takes ~60 seconds to become usable after booting into gaming mode, or plugins show errors immediately.

**Root cause:** The `decky-sunshine` plugin calls `drm_info -j` every second to wait for a display before starting Sunshine. On CachyOS Deckify, `drm_info` is not installed, so every call raises `FileNotFoundError`. After 60 failed attempts the plugin gives up, having wasted a full minute during Decky's startup window.

**Evidence in journal:**
```
journalctl -u plugin_loader.service | grep drm_info
# → FileNotFoundError: [Errno 2] No such file or directory: 'drm_info'  (×60)
```

---

### 2. Sunshine not available / shown as "not running" in gaming mode

**Symptom:** The Decky Sunshine plugin shows Sunshine as not running even though `systemctl --user status sunshine.service` reports it active.

**Root cause:** `decky-sunshine` detects Sunshine by running `flatpak ps --columns=application` and looking for `dev.lizardbyte.app.Sunshine`. On this system Sunshine is installed as a native package (not Flatpak), so the plugin always thinks Sunshine is stopped and tries to start the Flatpak version — which triggers the `drm_info` wait loop and ultimately fails.

The Flatpak version of Sunshine (`dev.lizardbyte.app.Sunshine`) may also be installed alongside the native package. The plugin starts the wrong one (or none at all) and never connects to the native instance already listening on port 47990.

---

### 3. Game Theme Music settings not persisting / always resetting to defaults

**Symptom:** Changes made in the Game Theme Music plugin (volume, mute state, invidious instance, etc.) don't survive a plugin reload — everything reverts to defaults.

**Root cause:** Decky's `SettingsManager` stores settings as a flat JSON object `{"key": value, ...}` and `getSetting(key)` calls `self.settings.get(key, default)` directly on that top-level dict. The `config.json` written by a previous version of the plugin wrapped everything one level deeper:

```json
{
    "settings": {          ← extra nesting the SettingsManager doesn't expect
        "defaultMuted": false,
        "volume": 1,
        ...
    }
}
```

So every `getSetting("defaultMuted")` lookup found nothing at the top level and returned the hardcoded default. Any `setSetting(...)` call then wrote the key at the top level alongside the stale `"settings"` blob, making the file a mix of both formats.

**Fix:** Flatten `config.json` by promoting the inner object to the top level. Already applied — the file is now:

```json
{
    "defaultMuted": false,
    "useYtDlp": false,
    "downloadAudio": true,
    "invidiousInstance": "https://yewtu.be",
    "volume": 1
}
```

Run `bash fix-gamethememusic-settings.sh` if the file ever gets corrupted back to the nested format (e.g. after a plugin reinstall that ships a broken default).

---

## Fix (decky-sunshine)

Patch `decky-sunshine`'s `sunshine.py` to:

1. **`isSunshineRunning()`** — after checking `flatpak ps`, also query `systemctl --user is-active sunshine.service`. Returns `True` immediately when the native service is active, so `start_async()` short-circuits before ever touching `drm_info`.

2. **`_isDisplayAvailable()`** — guard the `drm_info` call with `shutil.which("drm_info")`. When `drm_info` is absent, fall back to reading `/sys/class/drm/*/status` for connected outputs. This keeps the display-wait logic functional for users who don't have a native Sunshine service and do want to start the Flatpak version.

---

## Usage

### Apply

```bash
sudo bash apply-fixes.sh
```

The script:
- Requires root (the plugin files are root-owned)
- Backs up the original to `sunshine.py.bak` before patching
- Validates the patch applies cleanly (dry-run first)
- Restarts `plugin_loader.service` to pick up the change

### Revert

```bash
sudo bash revert-fixes.sh
```

Restores the original from the `.bak` file and restarts the service.

---

## Verification

After applying, check the journal on next boot or after a service restart:

```bash
journalctl -u plugin_loader.service -f
```

You should see `Decky Sunshine loaded` within a second or two of startup (no 60-second wait), and in gaming mode the Sunshine plugin should report Sunshine as running.

---

---

### 4. Ollama as a background server (gaming mode + Tailscale)

**Goal:** Run Ollama on the gaming machine so that OpenWebUI on Proxmox can reach it via Tailscale — even while Steam gaming mode is active. When Ollama is idle the GPU VRAM is fully released so games are not starved.

**Setup:**

- Installed via `pacman -S ollama` (CachyOS `cachyos-extra-v3/ollama 0.23.0`, bundles its own ROCm runtime)
- Bound to `0.0.0.0:11434` — reachable on all interfaces (LAN at `192.168.178.100`, Tailscale at `100.66.239.31`, loopback)
- Default `OLLAMA_KEEP_ALIVE` (5 minutes) — model stays loaded in VRAM between requests so follow-up questions are instant; evicted after 5 minutes of inactivity
- `ollama` user added to the `render` group — required to access `/dev/kfd` and `/dev/dri/renderD128` for ROCm/GPU inference

**Install:**

```bash
sudo bash install-ollama.sh
```

**Point OpenWebUI at** (use whichever reaches this machine from Proxmox):
```
http://100.66.239.31:11434   ← Tailscale
http://192.168.178.100:11434 ← LAN
```

**Verify GPU is being used:**
```bash
journalctl -u ollama -f
# should show "AMD Radeon RX 7600" or similar on first model load
```

**VRAM note:** The RX 7600 has 8 GB. Common model sizes at Q4_K_M quantisation:
| Model | VRAM |
|-------|------|
| 7B | ~4.5 GB |
| 13B | ~8 GB (tight) |
| 3B | ~2 GB |

With `OLLAMA_KEEP_ALIVE=0`, VRAM is freed as soon as the response finishes — games get the full 8 GB back within seconds of the last request.

---

## Files

```
gaming-mode-fixes/
├── README.md
├── apply-fixes.sh                              # apply decky-sunshine patch + restart service (needs sudo)
├── revert-fixes.sh                             # restore decky-sunshine original + restart service (needs sudo)
├── fix-gamethememusic-settings.sh              # flatten Game Theme Music config.json (no sudo needed)
├── install-ollama.sh                           # install + configure Ollama for Tailscale + GPU (needs sudo)
└── patches/
    └── decky-sunshine-native-service.patch     # the actual diff
```

---

## Affected versions

| Component | Version tested |
|-----------|---------------|
| OS | CachyOS Deckify 7.0.3-1 |
| Decky Loader | v3.2.3 |
| decky-sunshine plugin | 2025.10.27-dddf365 |
| Sunshine (native) | system package via pacman |
| Sunshine (Flatpak) | `dev.lizardbyte.app.Sunshine` 2025.924.154138 |
| Ollama | 0.23.0 (CachyOS cachyos-extra-v3) |
| GPU | AMD Radeon RX 7600 (gfx1102 / Navi 33) |
