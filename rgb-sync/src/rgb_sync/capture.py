"""PipeWire video capture into small numpy frames via GStreamer."""

import json
import logging
import subprocess

import gi
import numpy as np

gi.require_version("Gst", "1.0")
gi.require_version("GstApp", "1.0")
from gi.repository import Gst, GstApp  # noqa: E402,F401  (GstApp adds appsink methods)

Gst.init(None)
log = logging.getLogger(__name__)


class SourceLost(Exception):
    pass


def find_gamescope_node(name):
    """PipeWire node id of gamescope's screen stream, or None."""
    try:
        out = subprocess.run(["pw-dump"], capture_output=True, text=True, timeout=5).stdout
        objects = json.loads(out or "[]")
    except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError):
        return None
    for obj in objects:
        if obj.get("type") != "PipeWire:Interface:Node":
            continue
        props = (obj.get("info") or {}).get("props") or {}
        if props.get("node.name") == name and props.get("media.class") == "Video/Source":
            return obj["id"]
    return None


class Capture:
    """Pulls the newest frame from a PipeWire node, downscaled to width x height RGB.

    videorate drops surplus frames before scaling, so a 144 Hz source costs no
    more than max_rate. gamescope only sends frames on screen damage; a timeout
    on pull() therefore means "unchanged", not "lost". Loss shows up as a bus
    error or EOS.
    """

    def __init__(self, source, width, height, max_rate, scale_method="bilinear"):
        self.width, self.height = width, height
        self.pipeline = Gst.parse_launch(
            f"{source} ! video/x-raw,max-framerate={max_rate}/1 ! videorate drop-only=true max-rate={max_rate} "
            f"! videoscale method={scale_method} add-borders=false ! video/x-raw,width={width},height={height} "
            f"! videoconvert ! video/x-raw,format=RGB "
            f"! appsink name=sink max-buffers=1 drop=true sync=false"
        )
        self.sink = self.pipeline.get_by_name("sink")
        self.bus = self.pipeline.get_bus()

    def start(self):
        if self.pipeline.set_state(Gst.State.PLAYING) == Gst.StateChangeReturn.FAILURE:
            raise SourceLost("pipeline failed to start")

    def pull(self, timeout_s):
        msg = self.bus.pop_filtered(Gst.MessageType.ERROR | Gst.MessageType.EOS)
        if msg is not None:
            if msg.type == Gst.MessageType.ERROR:
                err, _ = msg.parse_error()
                raise SourceLost(err.message)
            raise SourceLost("end of stream")
        sample = self.sink.try_pull_sample(int(timeout_s * Gst.SECOND))
        if sample is None:
            return None
        buf = sample.get_buffer()
        ok, info = buf.map(Gst.MapFlags.READ)
        if not ok:
            return None
        try:
            caps = sample.get_caps().get_structure(0)
            w, h = caps.get_value("width"), caps.get_value("height")
            # Rows may be padded to 4 bytes; slice the stride away.
            stride = len(info.data) // h
            rows = np.frombuffer(info.data, dtype=np.uint8).reshape(h, stride)
            return rows[:, : w * 3].reshape(h, w, 3).copy()
        finally:
            buf.unmap(info)

    def stop(self):
        self.pipeline.set_state(Gst.State.NULL)


def gamescope_capture(node_id, width, height, max_rate, scale_method):
    return Capture(f"pipewiresrc path={node_id}", width, height, max_rate, scale_method)


def portal_capture(fd, node_id, width, height, max_rate, scale_method):
    return Capture(f"pipewiresrc fd={fd} path={node_id}", width, height, max_rate, scale_method)
