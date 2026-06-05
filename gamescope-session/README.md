# Gamescope session boot-loop fix

Stops the intermittent **"boot stuck, had to force restart"** hang on the Steam
Game Mode (gamescope) session, and the related **"non-Gamescope swapchain"**
Vulkan popup seen in games (Pragmata, Resident Evil 9 / REquiem, etc.).

Both symptoms are the **same bug**.

## Symptoms

1. **Boot hangs at game mode.** Sometimes boots fine, sometimes the screen sits
   there forever and only a hard power-cycle recovers. In the journal:
   ```
   gamescope-session[…]: Failed to connect to wayland socket: wayland-0.
   systemd[…]: gamescope-session.service: Main process exited, code=exited, status=1/FAILURE
   systemd[…]: Failed to start Gamescope Session.
   plasmalogin[…]: Session "…/gamescope-session.desktop" selected, command: "start-gamescope-session"
   ```
   …repeating once a second (plasmalogin relaunch storm).

2. **Vulkan popup in games:**
   ```
   CreateSwapchainKHR: Creating swapchain for non-Gamescope swapchain.
   Hooking has failed somewhere!
   You may have a bad Vulkan layer interfering.
   Press OK to try to power through this error, or Cancel to stop.
   ```

## Root cause

The stock unit `/usr/lib/systemd/user/gamescope-session.service` does:

```ini
UnsetEnvironment=DISPLAY XAUTHORITY
```

…but it **forgets `WAYLAND_DISPLAY`**.

KDE Plasma leaks `WAYLAND_DISPLAY=wayland-0` into the persistent
`systemctl --user` manager environment. When `gamescope-session.service` starts,
it inherits that var. gamescope's backend auto-detection sees `WAYLAND_DISPLAY`
set and chooses the **nested wayland backend** — it tries to connect to a parent
compositor at `wayland-0`, which doesn't exist at the DRM/greeter level, so it
fails and exits 1. plasmalogin immediately relaunches the session, which fails
again → boot appears hung.

It's **intermittent** because it's a race on whether the leaked var is present in
the service's inherited environment at exec time: a fully clean reboot often
works, but any boot following a Plasma session tends to hang.

The Vulkan popup is the **same bug downstream**: when the boot drops out of game
mode, games launch on plain Plasma instead of inside gamescope. The global
gamescope WSI implicit layer (`VkLayer_FROG_gamescope_wsi`) is still loaded, sees
it is *not* running under gamescope, and throws the "non-Gamescope swapchain"
warning. It is **not** a corrupt Proton prefix — deleting Proton files does
nothing. Fix the boot so games run inside gamescope and the popup disappears.

## Fix

Add `WAYLAND_DISPLAY` to the unset list via a per-user systemd drop-in:

```bash
./apply-gamescope-boot-fix.sh
```

The script installs `gamescope-session.service.d/override.conf`:

```ini
[Service]
UnsetEnvironment=DISPLAY XAUTHORITY WAYLAND_DISPLAY
```

reloads the user manager, and clears any currently-leaked vars from the running
session. With `WAYLAND_DISPLAY` gone, gamescope's backend auto-detection falls
through to **DRM/KMS**, which is correct for the embedded game-mode session.

## Verify

Reboot, then:

```bash
journalctl -b 0 | grep -iE 'Started Gamescope Session|wayland socket'
```

You want **`Started Gamescope Session`** — not `Failed to connect to wayland
socket`.

## Notes

- This is a per-user drop-in (`~/.config/systemd/user/...`); it survives
  `gamescope-session` package updates, unlike editing the stock unit.
- If RE9 / Pragmata still carry a `DISABLE_GAMESCOPE_WSI=1` launch option from an
  earlier band-aid attempt, it's harmless but now unnecessary. Leaving it on
  disables gamescope's VRR/HDR/scaling handoff inside game mode, so you can drop
  it once the boot fix is confirmed.
