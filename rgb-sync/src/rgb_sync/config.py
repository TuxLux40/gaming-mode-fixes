"""Config loading: built-in defaults overlaid with ~/.config/rgb-sync/config.toml."""

import copy
import os
import tomllib
from pathlib import Path

DEFAULTS = {
    "server": {"host": "127.0.0.1", "port": 6742},
    # Output updates per second. The soundbar was tested stable at 30.
    "rate_hz": 20,
    "capture": {
        # Size the frame is downscaled to before sampling (keep 16:9).
        "width": 64,
        "height": 36,
        # GStreamer videoscale method: "nearest-neighbour" is cheapest, "bilinear" smoother.
        "scale_method": "bilinear",
        # PipeWire node gamescope publishes its composited output on.
        "gamescope_node": "gamescope",
        # How often to look for a source while none is up, and for a gamescope
        # node while on the portal.
        "rescan_s": 2,
    },
    "color": {
        # >1 pushes patch colors away from gray; screens are mostly desaturated.
        "saturation": 1.4,
        # Patches whose brightest channel is below lo go dark, above hi stay as is.
        "dark_floor": [12, 40],
        # Exponential smoothing time constant.
        "smoothing_ms": 180,
        # <1 lifts dim colors (0.5: 30->85, 60->124, 100->160) without changing hue.
        "value_gamma": 0.5,
        "brightness": 1.0,
    },
    "fans": {
        # Matched against the OpenRGB device name or description.
        "device": "ASUS Aura USB",
        "zone": "Addressable RGB Header 1",
        "leds": 15,
        # LED 1 position, degrees clockwise from 12 o'clock as seen from the seat.
        "start_angle_deg": -24,
        "clockwise": True,
        # Patch center sits this fraction inside the screen border.
        "band": 0.15,
        # Patch size as a fraction of screen width/height.
        "patch": 0.1,
        # Board LEDs + 12 V headers: "average" of the fan colors, or "off".
        "mainboard": "average",
        "mainboard_zone": "Aura Mainboard",
        "calibration": {"gain": [1.0, 1.0, 1.0], "gamma": [1.0, 1.0, 1.0]},
    },
    "soundbar": {
        "device": "Razer Leviathan V2 X",
        "zone": "Speaker Underglow",
        "leds": 14,
        # "tl-br": LED 1 (leftmost) samples near the top-left corner.
        "diagonal": "tl-br",
        "patch": 0.1,
        "calibration": {"gain": [1.0, 1.0, 1.0], "gamma": [1.0, 1.0, 1.0]},
    },
}


def config_path() -> Path:
    base = os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config"
    return Path(base) / "rgb-sync" / "config.toml"


def state_dir() -> Path:
    base = os.environ.get("XDG_STATE_HOME") or Path.home() / ".local" / "state"
    path = Path(base) / "rgb-sync"
    path.mkdir(parents=True, exist_ok=True)
    return path


def _merge(base: dict, override: dict) -> dict:
    for key, value in override.items():
        if isinstance(value, dict) and isinstance(base.get(key), dict):
            _merge(base[key], value)
        else:
            base[key] = value
    return base


def load(path: Path | None = None) -> dict:
    cfg = copy.deepcopy(DEFAULTS)
    path = path or config_path()
    if path.exists():
        with path.open("rb") as f:
            _merge(cfg, tomllib.load(f))
    return cfg


def parse_hex(color: str) -> tuple[int, int, int]:
    color = color.lstrip("#")
    return tuple(int(color[i : i + 2], 16) for i in (0, 2, 4))
