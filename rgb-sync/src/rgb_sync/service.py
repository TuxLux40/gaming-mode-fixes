"""Main loop: pick a capture source, map frames to LEDs, push through OpenRGB."""

import logging
import signal
import time

from . import config as config_mod
from .capture import SourceLost, find_gamescope_node, gamescope_capture, portal_capture
from .color import ColorPipeline
from .mapping import Sampler, diagonal_points, ring_points
from .output import Output
from .portal import PortalDenied, PortalError, ScreenCastSession

log = logging.getLogger(__name__)

# After the user declines the screen-sharing dialog, wait this long before
# asking again. Technical failures (KDE not up yet) retry on every rescan.
PORTAL_DENIED_RETRY_S = 600


class SwitchSource(Exception):
    pass


class Service:
    def __init__(self, cfg):
        self.cfg = cfg
        cap = cfg["capture"]
        w, h = cap["width"], cap["height"]
        fans, bar = cfg["fans"], cfg["soundbar"]
        self.fan_sampler = Sampler(
            ring_points(fans["leds"], w, h, fans["start_angle_deg"], fans["clockwise"], fans["band"]),
            w, h, fans["patch"])
        self.bar_sampler = Sampler(diagonal_points(bar["leds"], w, h, bar["diagonal"]), w, h, bar["patch"])
        col = cfg["color"]
        args = (col["saturation"], col["dark_floor"], col["smoothing_ms"], col["brightness"], col["value_gamma"])
        self.fan_pipe = ColorPipeline(*args)
        self.bar_pipe = ColorPipeline(*args)
        self.token_file = config_mod.state_dir() / "portal_restore_token"
        self.out = None
        self.stopping = False
        self.portal_retry_at = 0.0

    def _stop(self, *_):
        self.stopping = True

    def _connect(self):
        while not self.stopping:
            try:
                return Output(self.cfg)
            except Exception as e:  # server still starting, or devices missing
                log.warning("OpenRGB not ready: %s", e)
                self._sleep(3)
        return None

    def _sleep(self, seconds):
        end = time.monotonic() + seconds
        while not self.stopping and time.monotonic() < end:
            time.sleep(min(0.2, end - time.monotonic()))

    def _open_source(self):
        cap = self.cfg["capture"]
        args = (cap["width"], cap["height"], self.cfg["rate_hz"], cap["scale_method"])
        node = find_gamescope_node(cap["gamescope_node"])
        if node is not None:
            log.info("source: gamescope node %s", node)
            return "gamescope", gamescope_capture(node, *args), None
        if time.monotonic() < self.portal_retry_at:
            return None, None, None
        session = ScreenCastSession(self.token_file)
        try:
            fd, node = session.start()
        except PortalDenied as e:
            log.info("no portal screencast: %s", e)
            session.close()
            self.portal_retry_at = time.monotonic() + PORTAL_DENIED_RETRY_S
            return None, None, None
        except PortalError as e:
            log.info("no portal screencast yet: %s", e)
            session.close()
            return None, None, None
        log.info("source: portal node %s", node)
        return "portal", portal_capture(fd, node, *args), session

    def _stream(self, kind, cap):
        period = 1.0 / self.cfg["rate_hz"]
        rescan = self.cfg["capture"]["rescan_s"]
        next_rescan = time.monotonic() + rescan
        frame, last = None, time.monotonic()
        cap.start()
        while not self.stopping:
            tick = time.monotonic()
            new = cap.pull(period)
            if new is not None:
                frame = new
            now = time.monotonic()
            dt, last = now - last, now
            unchanged = new is None and self.fan_pipe.settled and self.bar_pipe.settled
            if frame is not None and not unchanged:
                fans = self.fan_pipe.process(self.fan_sampler.sample(frame), dt)
                bar = self.bar_pipe.process(self.bar_sampler.sample(frame), dt)
                self.out.send(fans, bar)
            if kind == "portal" and now >= next_rescan:
                next_rescan = now + rescan
                if find_gamescope_node(self.cfg["capture"]["gamescope_node"]) is not None:
                    raise SwitchSource("gamescope appeared")
            time.sleep(max(0.0, period - (time.monotonic() - tick)))

    def run(self):
        signal.signal(signal.SIGTERM, self._stop)
        signal.signal(signal.SIGINT, self._stop)
        while not self.stopping:
            if self.out is None:
                self.out = self._connect()
                if self.out is None:
                    break
            kind, cap, session = self._open_source()
            if cap is None:
                self._sleep(self.cfg["capture"]["rescan_s"])
                continue
            try:
                self._stream(kind, cap)
            except (SourceLost, SwitchSource) as e:
                # LEDs keep the last screen colors until a source is back.
                log.info("%s source ended: %s", kind, e)
            except Exception as e:  # SDK connection dropped (server restart)
                log.warning("output error: %s", e)
                self.out = None
            finally:
                cap.stop()
                if session is not None:
                    session.close()
        if self.out is not None:
            self.out.close()
        log.info("stopped")
