"""xdg-desktop-portal ScreenCast session (Desktop Mode).

Asks KDE once for screen-sharing permission; persist_mode=2 returns a restore
token that skips the dialog on later starts. Under gamescope there is no
ScreenCast backend, so every call here fails fast with PortalError.
"""

import logging
import secrets

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

log = logging.getLogger(__name__)

BUS_NAME = "org.freedesktop.portal.Desktop"
OBJ_PATH = "/org/freedesktop/portal/desktop"
IFACE = "org.freedesktop.portal.ScreenCast"
SOURCE_MONITOR = 1
CURSOR_HIDDEN = 1
PERSIST_UNTIL_REVOKED = 2


class PortalError(Exception):
    pass


class PortalDenied(PortalError):
    """The user declined or cancelled the screen-sharing dialog."""


class ScreenCastSession:
    def __init__(self, token_file, response_timeout_s=180):
        self.token_file = token_file
        self.timeout = response_timeout_s
        self.bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        self.sender = self.bus.get_unique_name()[1:].replace(".", "_")
        self.session = None

    def _request(self, method, params_before_options, options):
        """Call a portal method and wait for its Request::Response signal."""
        token = "rgbsync" + secrets.token_hex(4)
        options["handle_token"] = GLib.Variant("s", token)
        path = f"{OBJ_PATH}/request/{self.sender}/{token}"
        result = {}
        ctx = GLib.MainContext.default()

        def on_response(_conn, _sender, _path, _iface, _signal, params):
            code, results = params.unpack()
            result["code"], result["results"] = code, results

        sub = self.bus.signal_subscribe(
            BUS_NAME, "org.freedesktop.portal.Request", "Response", path, None,
            Gio.DBusSignalFlags.NONE, on_response,
        )
        try:
            args = GLib.Variant(f"({''.join(t for t, _ in params_before_options)}a{{sv}})",
                                (*[v for _, v in params_before_options], options))
            self.bus.call_sync(BUS_NAME, OBJ_PATH, IFACE, method, args, None,
                               Gio.DBusCallFlags.NONE, -1, None)
            deadline = GLib.get_monotonic_time() + self.timeout * 1_000_000
            while "code" not in result and GLib.get_monotonic_time() < deadline:
                ctx.iteration(True)
        except GLib.Error as e:
            raise PortalError(f"{method}: {e.message}") from e
        finally:
            self.bus.signal_unsubscribe(sub)
        if "code" not in result:
            raise PortalError(f"{method}: no response within {self.timeout}s")
        if result["code"] == 1:
            raise PortalDenied(f"{method}: declined in the dialog")
        if result["code"] != 0:
            raise PortalError(f"{method}: failed (code {result['code']})")
        return result["results"]

    def start(self):
        """Returns (pipewire_fd, node_id)."""
        res = self._request("CreateSession", [], {
            "session_handle_token": GLib.Variant("s", "rgbsync" + secrets.token_hex(4)),
        })
        self.session = res["session_handle"]

        select = {
            "types": GLib.Variant("u", SOURCE_MONITOR),
            "multiple": GLib.Variant("b", False),
            "cursor_mode": GLib.Variant("u", CURSOR_HIDDEN),
            "persist_mode": GLib.Variant("u", PERSIST_UNTIL_REVOKED),
        }
        if self.token_file.exists():
            select["restore_token"] = GLib.Variant("s", self.token_file.read_text().strip())
        self._request("SelectSources", [("o", self.session)], select)

        res = self._request("Start", [("o", self.session), ("s", "")], {})
        if res.get("restore_token"):
            self.token_file.write_text(res["restore_token"])
        streams = res.get("streams") or []
        if not streams:
            raise PortalError("Start returned no streams")
        node_id = streams[0][0]

        try:
            reply, fds = self.bus.call_with_unix_fd_list_sync(
                BUS_NAME, OBJ_PATH, IFACE, "OpenPipeWireRemote",
                GLib.Variant("(oa{sv})", (self.session, {})),
                GLib.VariantType("(h)"), Gio.DBusCallFlags.NONE, -1, None, None,
            )
        except GLib.Error as e:
            raise PortalError(f"OpenPipeWireRemote: {e.message}") from e
        fd = fds.get(reply.unpack()[0])
        log.info("portal screencast: node %s", node_id)
        return fd, node_id

    def close(self):
        if self.session:
            try:
                self.bus.call_sync(BUS_NAME, self.session, "org.freedesktop.portal.Session",
                                   "Close", None, None, Gio.DBusCallFlags.NONE, -1, None)
            except GLib.Error:
                pass
            self.session = None
