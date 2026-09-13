#!/usr/bin/env python3
"""
Fix a blank Steam "Controller Settings" panel (Gaming Mode) for one AppID.

Symptom: opening Controller Settings for a game shows only the title bar and
MENU/SELECT/BACK footer -- no "Current Button Layout" card, no View/Edit
Layout buttons. This happens when Steam's per-app controller config
selection has resolved to nothing, so it silently falls back to the generic
built-in template instead of a real personal/Community/developer layout.
See ../CLAUDE.md ("Controller Settings screen is blank") for the full
root-cause writeup.

This talks to Steam's own Chrome DevTools Protocol port (the same one
gamescope/decky-claude use) to call the internal SteamClient.Input API
directly -- no UI clicking required.

Requires: Steam running with its CEF remote-debugging port reachable
(default 8080 on this machine), and the `websockets` python package
(`uv pip install websockets` or `pip install websockets`).

Usage:
    ./fix-blank-controller-config.py <appid> [--port 8080] [--no-reopen]
"""
import argparse
import asyncio
import itertools
import json
import sys
import urllib.request

import websockets


def find_shared_js_context(port: int) -> str:
    with urllib.request.urlopen(f"http://localhost:{port}/json", timeout=5) as r:
        targets = json.load(r)
    for t in targets:
        if t.get("title") == "SharedJSContext":
            return t["webSocketDebuggerUrl"]
    raise RuntimeError(
        "No 'SharedJSContext' CDP target found -- is Steam running with "
        f"remote debugging on port {port}?"
    )


async def eval_js(ws_url: str, expression: str):
    _ids = itertools.count(1)
    async with websockets.connect(ws_url, max_size=None) as ws:
        msg_id = next(_ids)
        await ws.send(json.dumps({
            "id": msg_id,
            "method": "Runtime.evaluate",
            "params": {"expression": expression, "awaitPromise": True},
        }))
        while True:
            reply = json.loads(await ws.recv())
            if reply.get("id") == msg_id:
                return reply


async def main_async(appid: int, port: int, reopen: bool):
    ws_url = find_shared_js_context(port)

    clear_expr = f"SteamClient.Input.ClearSelectedConfigForApp({appid}, 0)"
    result = await eval_js(ws_url, clear_expr)
    if "error" in result:
        print(f"CDP error calling ClearSelectedConfigForApp: {result['error']}", file=sys.stderr)
        sys.exit(1)
    print(f"Cleared stale controller config selection for AppID {appid}.")

    if reopen:
        reopen_expr = f"SteamClient.Apps.ShowControllerConfigurator({appid})"
        await eval_js(ws_url, reopen_expr)
        print("Reopened Controller Settings -- it should now show a real layout "
              "(e.g. 'Using Recommended Template: Official Layout for ...') "
              "instead of a blank panel.")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("appid", type=int, help="Steam AppID of the game with the blank Controller Settings panel")
    parser.add_argument("--port", type=int, default=8080, help="Steam CEF remote-debugging port (default: 8080)")
    parser.add_argument("--no-reopen", dest="reopen", action="store_false", help="Don't reopen Controller Settings after clearing")
    args = parser.parse_args()
    asyncio.run(main_async(args.appid, args.port, args.reopen))


if __name__ == "__main__":
    main()
