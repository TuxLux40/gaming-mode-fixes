"""Turns sampled patch colors into LED colors."""

import math

import numpy as np

LUMA = np.array([0.2126, 0.7152, 0.0722], dtype=np.float32)


class ColorPipeline:
    """saturation boost -> dark floor -> value curve -> brightness -> smoothing."""

    def __init__(self, saturation, dark_floor, smoothing_ms, brightness, value_gamma=1.0):
        self.saturation = saturation
        self.value_gamma = value_gamma
        self.floor_lo, self.floor_hi = dark_floor
        self.tau = smoothing_ms / 1000.0
        self.brightness = brightness
        self.state = None
        self.settled = False

    def process(self, colors, dt):
        c = np.asarray(colors, dtype=np.float32)
        luma = (c @ LUMA)[:, None]
        c = np.clip(luma + (c - luma) * self.saturation, 0, 255)
        peak = c.max(axis=1)
        span = max(1e-6, self.floor_hi - self.floor_lo)
        c *= np.clip((peak - self.floor_lo) / span, 0, 1)[:, None]
        # Lift each LED's brightness (its brightest channel) along a gamma curve
        # while keeping hue and saturation: dim movie frames would otherwise
        # leave linear LEDs (the fans) nearly off.
        peak = c.max(axis=1)
        lifted = 255.0 * (peak / 255.0) ** self.value_gamma
        c *= np.where(peak > 0, lifted / np.maximum(peak, 1e-6), 0)[:, None]
        c *= self.brightness
        if self.state is None or self.tau <= 0:
            self.state = c
        else:
            self.state = self.state + (1 - math.exp(-dt / self.tau)) * (c - self.state)
        self.settled = bool(np.abs(c - self.state).max() < 0.5)
        return self.state


def calibrate(colors, gain, gamma):
    """Per-device correction applied last: per-channel gamma, then gain."""
    x = np.clip(np.asarray(colors, dtype=np.float32) / 255.0, 0, 1)
    x = x ** np.asarray(gamma, dtype=np.float32) * np.asarray(gain, dtype=np.float32)
    return np.clip(np.rint(x * 255), 0, 255).astype(np.uint8)
