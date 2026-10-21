"""Screen geometry: which pixels each LED averages.

Points are computed in pixel coordinates of the downscaled frame. Each LED owns a
small rectangular patch around its point; sampling is one matrix multiply.
"""

import math

import numpy as np


def ring_points(n, width, height, start_deg, clockwise, band):
    """Fan ring: LED i looks outward from the screen center at its clock angle.

    Angles are laid out on a square normalized to the screen, so 45° hits a
    corner whatever the aspect ratio. The patch center sits `band` inside the
    border along that ray.
    """
    step = 360.0 / n * (1 if clockwise else -1)
    points = []
    for i in range(n):
        theta = math.radians(start_deg + i * step)
        dx, dy = math.sin(theta), -math.cos(theta)  # screen y grows downward
        t = 1.0 / max(abs(dx), abs(dy))
        nx, ny = dx * t * (1 - band), dy * t * (1 - band)
        points.append(((nx + 1) / 2 * width, (ny + 1) / 2 * height))
    return points


def diagonal_points(n, width, height, direction):
    """Soundbar: n evenly spaced points along a screen diagonal, LED 1 first."""
    points = []
    for k in range(n):
        u = (k + 0.5) / n
        y = u if direction == "tl-br" else 1 - u
        points.append((u * width, y * height))
    return points


class Sampler:
    def __init__(self, points, width, height, patch):
        half_w = max(1.0, patch * width / 2)
        half_h = max(1.0, patch * height / 2)
        weights = np.zeros((len(points), width * height), dtype=np.float32)
        for i, (x, y) in enumerate(points):
            x0, x1 = int(max(0, math.floor(x - half_w))), int(min(width, math.ceil(x + half_w)))
            y0, y1 = int(max(0, math.floor(y - half_h))), int(min(height, math.ceil(y + half_h)))
            mask = np.zeros((height, width), dtype=np.float32)
            mask[y0:y1, x0:x1] = 1.0
            weights[i] = mask.ravel() / mask.sum()
        self.weights = weights
        self.shape = (height, width)

    def sample(self, frame):
        """frame: (height, width, 3) uint8 -> (n, 3) float32 mean colors."""
        assert frame.shape[:2] == self.shape, (frame.shape, self.shape)
        return self.weights @ frame.reshape(-1, 3).astype(np.float32)
