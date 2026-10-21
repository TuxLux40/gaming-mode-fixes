import numpy as np

from rgb_sync.color import ColorPipeline, calibrate
from rgb_sync.mapping import Sampler, diagonal_points, ring_points

W, H = 64, 36
RED, BLUE, GREEN, MAGENTA = (255, 0, 0), (0, 0, 255), (0, 255, 0), (255, 0, 255)


def ring(start=-24, clockwise=True, n=15):
    return ring_points(n, W, H, start, clockwise, 0.15)


def test_ring_led2_is_top_center_and_runs_clockwise():
    pts = ring()
    x, y = pts[1]  # LED 2 at 12 o'clock with start -24°
    assert abs(x - W / 2) < 1 and y < H * 0.2
    x3, _ = pts[2]
    assert x3 > x  # clockwise from the top moves right


def test_split_screen_left_red_right_blue():
    frame = np.zeros((H, W, 3), np.uint8)
    frame[:, : W // 2] = RED
    frame[:, W // 2 :] = BLUE
    pts = ring()
    colors = Sampler(pts, W, H, 0.1).sample(frame)
    for (x, _), c in zip(pts, colors):
        if x < W / 2 - 4:
            assert c[0] > 200 and c[2] < 50, (x, c)
        elif x > W / 2 + 4:
            assert c[2] > 200 and c[0] < 50, (x, c)


def test_counter_clockwise_mirrors_ring():
    cw, ccw = ring(start=0), ring(start=0, clockwise=False)
    for (x1, y1), (x2, y2) in zip(cw[1:], ccw[1:]):
        assert abs((x1 - W / 2) + (x2 - W / 2)) < 1e-6 and abs(y1 - y2) < 1e-6


def test_diagonal_gradient_green_to_magenta():
    frame = np.zeros((H, W, 3), np.uint8)
    yy, xx = np.mgrid[0:H, 0:W]
    top_left = (xx / W + yy / H) < 1.0
    frame[top_left] = GREEN
    frame[~top_left] = MAGENTA
    colors = Sampler(diagonal_points(14, W, H, "tl-br"), W, H, 0.1).sample(frame)
    assert colors[0][1] > 200 and colors[0][0] < 50  # leftmost LED green
    assert colors[-1][0] > 200 and colors[-1][1] < 50  # rightmost LED magenta


def test_static_scene_converges_and_stays_constant():
    pipe = ColorPipeline(1.4, [12, 40], 180, 1.0)
    colors = np.array([[200, 120, 40]] * 5, np.float32)
    for _ in range(100):
        out = pipe.process(colors, 0.05)
    before = out.copy()
    for _ in range(20):
        out = pipe.process(colors, 0.05)
    assert np.allclose(before, out, atol=0.01)


def test_dark_floor_turns_near_black_off():
    pipe = ColorPipeline(1.0, [12, 40], 0, 1.0)
    out = pipe.process(np.array([[8, 8, 8], [200, 200, 200]], np.float32), 0.05)
    assert out[0].max() == 0 and out[1].max() > 190


def test_calibration_gain_and_gamma():
    out = calibrate([[255, 255, 255], [128, 128, 128]], [1.0, 0.5, 1.0], [1.0, 1.0, 2.0])
    assert out[0].tolist() == [255, 128, 255]
    assert out[1][2] < out[1][0]  # gamma 2 darkens blue mid-tones


def test_value_gamma_lifts_dim_colors_and_keeps_hue():
    pipe = ColorPipeline(1.0, [0, 1], 0, 1.0, value_gamma=0.5)
    out = pipe.process(np.array([[60, 30, 15]], np.float32), 0.05)[0]
    assert 120 < out.max() < 130  # 60 -> ~124
    assert abs(out[1] / out[0] - 0.5) < 0.01 and abs(out[2] / out[0] - 0.25) < 0.01
