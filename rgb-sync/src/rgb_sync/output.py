"""OpenRGB SDK output. Never opens hardware itself: the server owns the devices."""

import logging

import numpy as np
from openrgb import OpenRGBClient
from openrgb.utils import RGBColor

from .color import calibrate

log = logging.getLogger(__name__)


def _find_device(client, match):
    for dev in client.devices:
        if match in dev.name or match in (dev.metadata.description or ""):
            return dev
    raise LookupError(f"no OpenRGB device matches {match!r}")


def _find_zone(dev, name):
    for zone in dev.zones:
        if zone.name == name:
            return zone
    raise LookupError(f"{dev.name}: no zone {name!r}")


def _rgb(colors):
    return [RGBColor(int(r), int(g), int(b)) for r, g, b in colors]


class Output:
    def __init__(self, cfg):
        self.cfg = cfg
        server = cfg["server"]
        self.client = OpenRGBClient(server["host"], server["port"], "rgb-sync")
        fans, bar = cfg["fans"], cfg["soundbar"]

        self.fan_dev = _find_device(self.client, fans["device"])
        self.fan_zone = _find_zone(self.fan_dev, fans["zone"])
        if len(self.fan_zone.leds) != fans["leds"]:
            raise LookupError(
                f"{fans['zone']} has {len(self.fan_zone.leds)} LEDs, config says {fans['leds']}"
            )
        self.board_zone = None
        if fans["mainboard"] != "off":
            self.board_zone = _find_zone(self.fan_dev, fans["mainboard_zone"])

        self.bar_dev = _find_device(self.client, bar["device"])
        self.bar_zone = _find_zone(self.bar_dev, bar["zone"])
        if len(self.bar_zone.leds) != bar["leds"]:
            raise LookupError(
                f"{bar['zone']} has {len(self.bar_zone.leds)} LEDs, config says {bar['leds']}"
            )

        self._last = {}
        for dev in (self.fan_dev, self.bar_dev):
            dev.set_mode("direct")
        log.info("connected: %s, %s", self.fan_dev.name, self.bar_dev.name)

    def send(self, fan_colors, bar_colors):
        """Colors are pre-calibration floats 0..255, one row per LED.

        Only zones whose calibrated bytes changed since the last send go out.
        """
        fans, bar = self.cfg["fans"], self.cfg["soundbar"]
        self._put("fans", self.fan_zone, calibrate(fan_colors, **fans["calibration"]))
        if self.board_zone is not None:
            avg = calibrate([fan_colors.mean(axis=0)], **fans["calibration"])[0]
            self._put("board", self.board_zone, np.repeat([avg], len(self.board_zone.leds), axis=0))
        self._put("bar", self.bar_zone, calibrate(bar_colors, **bar["calibration"]))

    def _put(self, key, zone, colors):
        data = colors.tobytes()
        if self._last.get(key) == data:
            return
        zone.set_colors(_rgb(colors), fast=True)
        self._last[key] = data

    def fill(self, rgb):
        """One color on every managed LED (calibration checks)."""
        color = np.array([rgb], dtype=np.float32)
        self.send(color.repeat(self.cfg["fans"]["leds"], axis=0),
                  color.repeat(self.cfg["soundbar"]["leds"], axis=0))

    def close(self):
        try:
            self.client.disconnect()
        except Exception:
            pass
