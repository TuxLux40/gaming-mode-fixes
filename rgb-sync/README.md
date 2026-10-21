# rgb-sync — screen-reactive RGB for Game Mode

The Razer Leviathan V2 X soundbar and the two ARGB fans follow what is on
screen, region by region, in Steam Game Mode (gamescope) and in KDE Desktop
Mode. It needs no per-game setup and never shows a fixed "idle" color.

```
 screen ──PipeWire──▶ rgb-sync ──SDK 127.0.0.1:6742──▶ openrgb --server (only program on the hardware)
 Game Mode: gamescope's own stream     zones + color          ├─▶ fans: 15 LEDs around the screen edge
 Desktop:   KDE screen-sharing portal  processing             └─▶ soundbar: 14 LEDs along the diagonal
```

## Why it is built this way

RGB on this PC used to have several owners at once: openrazer (a custom build
that Arch's package later replaced without notice), Polychromatic, OpenRGB, and
a stale 0.9 OpenRGB build. Each opened the same hidraw devices, which caused
blinking and sudden loss of control. Now:

- **One owner.** `openrgb-server.service` is the only process that opens the
  devices. Everything else, including this bridge and the OpenRGB window,
  connects through the SDK. The OpenRGB GUI started while the server runs
  auto-connects as a client and does not open the hardware (verified), so
  opening it for the Effects plugin is safe.
- **Never script with `openrgb --client …`.** That CLI mode also runs its own
  device detection and becomes a second owner.
- **Proton opens HID devices too.** Wine's winebus opens every hidraw node the
  user may access, including these two. For apps with their own RGB
  integration (Wallpaper Engine: Razer Chroma/iCUE/LightSync), turn that
  integration off and add `PROTON_DISABLE_HIDRAW=1 %command%` to their launch
  options.

### Why not the OpenRGB Effects plugin's "Ambient"?

It only captures through the xdg-desktop-portal ScreenCast API, which has no
backend under gamescope, so it does nothing in Game Mode. Its default "Scaled
average" mode blends the whole screen into one color. "Screen copy" mode maps
columns to LEDs, but cannot do a ring around the screen edge or a diagonal. It
stays installed for manual effects in the GUI (and is the zoning tool on the
other, desktop-only CachyOS install).

## How it works

| Piece | What it does |
|---|---|
| `capture.py` | `pipewiresrc ! max-framerate ! videorate ! videoscale ! videoconvert ! appsink` → 64×36 RGB frames. Frames are dropped to the update rate *before* scaling. In Game Mode it connects straight to gamescope's `Video/Source` node named `gamescope`, with no permission prompt. |
| `portal.py` | Desktop Mode: ScreenCast portal with `persist_mode=2`. KDE asks once, and the restore token in `~/.local/state/rgb-sync/` skips the dialog afterwards. |
| `mapping.py` | Fans: LED *i* looks outward from the screen center at `start_angle + i·24°` (clockwise from 12 o'clock) and samples a patch just inside the border. Soundbar: 14 patches along the top-left → bottom-right diagonal, LED 1 = leftmost. |
| `color.py` | Saturation boost → near-black dims to off → brightness lift (`value_gamma`, keeps hue; without it dark movie frames leave the linear fans nearly off) → exponential smoothing → per-device gain/gamma. |
| `service.py` | Prefers the gamescope node, falls back to the portal, rescans every 2 s while there is no source, and switches to gamescope when one appears. In gaps the LEDs keep the last screen colors. Only changed zones are sent. |
| `output.py` | Finds devices by name/description, sets Direct mode, sends per-LED colors. |

Hardware facts it relies on (measured 2026-10-21):

- Aura USB (0b05:1939) "Addressable RGB Header 1" = **15 LEDs**. The two fans hang
  on a pass-through chain, so both show the same 15 LEDs. LED 1 is at about
  11 o'clock as seen from the seat, numbered clockwise.
- Leviathan V2 X "Speaker Underglow" = **14 LEDs**, LED 1 = leftmost. It clips
  hard near full brightness (255 vs 128 vs 100/100/255 look alike), so color
  calibration has no visible effect on it. A slight warm tint seen head-on
  comes from its separate R/G/B dies.
- Fan patches sit 30 % inside the screen border (`band = 0.3`); at 0.15 they mostly hit panels, HUD and letterbox bars.
- Cost: ~3 % of one core at 20 Hz with constantly changing frames (main
  Python thread ~2 %, PipeWire thread ~0.9 %).

## Files and config

| What | Where |
|---|---|
| Code, units, setup/revert | this folder |
| Bridge config (mapping, color, calibration) | `~/.config/rgb-sync/config.toml` → symlink to `TuxLux40/dotfiles` `machines/<host>/rgb-sync/config.toml` (backup only; dotfiles' `install.sh` never stows `machines/`) |
| OpenRGB config (2 detectors, 15-LED zone, profiles, Effects settings) | `~/.config/OpenRGB` → dotfiles `openrgb` stow package |
| Portal permission token | `~/.local/state/rgb-sync/portal_restore_token` |

OpenRGB 1.1 converted the 0.9-era files on first start: `*.orp` → `profiles/*.json`,
`sizes.ors` → `Configuration.json` (originals kept as `*.bak`, git-ignored).

Defaults for every config key are in `src/rgb_sync/config.py`.

## Usage

```bash
./setup.sh                                # deps check, venv, config link, enable both units
journalctl --user -u rgb-screen-sync -f   # watch it
.venv/bin/rgb-sync probe                  # which source would be used + one frame's LED colors
.venv/bin/rgb-sync show '#8000ff'         # one calibrated color on everything (stop the service first)
uv run pytest                             # mapping/color tests with synthetic frames
./revert.sh                               # stop + remove units, config link and portal token
```

`setup.sh` needs: `openrgb` 1.1, `gst-plugin-pipewire`, `gst-plugins-base-libs`
(videoconvert/videoscale/videorate/appsink + GstApp typelib), `python-gobject`, `uv`.
The venv uses `--system-site-packages` so PyGObject comes from the system.

## Rollback

`./revert.sh` stops both units. The LEDs keep their last color. The dotfiles and
the venv stay. openrazer was removed on purpose (it only served the
non-RGB Basilisk mouse and was a second Razer driver stack); reinstall with
`sudo pacman -S openrazer-daemon openrazer-driver-dkms python-openrazer` only if needed.
