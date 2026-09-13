# Blank Controller Settings screen (Steam Input games)

Fixes the **"Controller Settings" panel shows completely empty"** bug for a specific
game in Steam Gaming Mode — no "Current Button Layout" card, no View/Edit Layout
buttons, just the title bar and MENU/SELECT/BACK footer. Steam Input being
"enabled" for the game is irrelevant to this bug and does not fix it.

First confirmed on **HITMAN World of Assassination (AppID 1659040)**, 2026-09-13,
but the bug is generic — it can hit any game, not just this one.

---

## Root cause

Steam's controller subsystem resolves a per-game config in priority order
(personal binding → Community/Valve-verified layout → developer default →
generic built-in template). When that resolution lands on nothing — i.e. it
falls back to the generic template — the gamepadui "Controller Settings" React
panel has no display metadata (title/icon) to render its "Current Button
Layout" card against, and silently renders an empty shell instead of an error
or a "no layout found, browse configs" prompt.

You can confirm this is what's happening (rather than a permissions/lock
issue) by checking which config path Steam actually loaded:

```bash
grep "Loaded Config for Local Selection Path for App ID <APPID>" \
  ~/.steam/steam/logs/controller_ui.txt
```

- **Broken:** resolves to `.../controller_base/templates/controller_neptune_gamepad_fps.vdf`
  (or another file under `controller_base/templates/`) — the generic fallback.
- **Working:** resolves to `.../Steam Controller Configs/<userid>/config/<appid>/...`
  (a personal binding) or `.../steamapps/workshop/content/241100/.../*.bin`
  (a Community/Official layout).

Verified this is **not** a global Steam UI bug and **not** Steam Input being
force-disabled for the game: another installed game's Controller Settings
panel (with a real Workshop config) rendered perfectly in the same session,
and neither `config.vdf` nor `registry.vdf` had a per-app override forcing
Steam Input off for the broken game.

## Fix

Clear the (stale/empty) per-app config selection so Steam re-resolves it from
scratch. This is exposed only through Steam's internal `SteamClient.Input`
JS API — there's no user-facing button for it, since the panel that would
normally expose "change layout" is the very thing that's blank.

```bash
./fix-blank-controller-config.py <APPID>
```

This talks to Steam's own Chrome DevTools Protocol port (same mechanism
gamescope/decky-claude use) and calls:

```js
SteamClient.Input.ClearSelectedConfigForApp(<APPID>, 0)
SteamClient.Apps.ShowControllerConfigurator(<APPID>)   // reopen to verify
```

Requires Steam running with its CEF remote-debugging port reachable (default
`8080` on this machine) and the `websockets` Python package
(`uv pip install websockets`).

After running it, reopen Controller Settings for the game — it should show
"Using Recommended Template: Official Layout for ..." (or your personal
layout, if you'd saved one before) with working View/Edit Layout buttons.

### If clearing the selection doesn't help

That means the game genuinely has **no** config assigned anywhere upstream
(no developer default, no Community/Valve-verified layout) — clearing a
selection can only make Steam re-resolve to something that exists, it can't
conjure a config that was never published. In that case:

1. From **Desktop Mode** (not Gaming Mode), Properties → Controller for the
   game may expose a "Browse Configs" flow the blank gamepadui panel doesn't
   — untested as of 2026-09-13, worth trying first.
2. Manually build and save a personal layout once a config (even a bare
   template) is selectable, which then becomes the real personal binding for
   future sessions.

## Gotchas

- `ClearSelectedConfigForApp` only wipes the *selection pointer* — it does
  **not** delete any saved personal binding. Worst case, Steam re-resolves to
  the exact same generic template it was already using, and you're no worse
  off.
- The CDP port only exposes a `SharedJSContext` target with the full
  `SteamClient` API — a game-specific "Controller Layout" popup window (if
  one happens to be open) only gets a minimal `SteamClient.Input` subset
  (input/touch-menu registration calls), not the config-management calls.
  Always target `SharedJSContext`, not the popup.
- `SteamClient.Input.QueryControllerConfigsForApp(appid, controllerIndex, ...)`
  requires exactly 3 arguments and is fire-and-forget (returns `undefined`,
  not a Promise) — its response comes back through a separate registered
  callback that appears to be scoped per-window, not global. Not needed for
  this fix, but worth knowing if you go spelunking in `SteamClient.Input`
  further.
