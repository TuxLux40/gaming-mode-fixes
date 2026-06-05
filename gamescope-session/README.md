# Gamescope session boot-loop fix

Stops the intermittent **"boot stuck, had to force restart"** hang on the Steam
Game Mode (gamescope) session, and the related **"non-Gamescope swapchain"**
Vulkan popup seen in games (Pragmata, Resident Evil 9 / REquiem, etc.).

Both symptoms are the **same bug**: gamescope can't get the GPU at boot, crashes,
and the login manager relaunch-storms.

> **Root cause (confirmed 2026-06-05): user lingering was enabled.**
> `loginctl enable-linger oliver` (set 2026-05-29) makes the user systemd manager
> start at boot from a **seatless `manager` session**, so gamescope — running under
> that manager — is denied DRM master on `/dev/dri/card1` by logind
> (`Device or resource busy`). See [the mental-model diagram](session-device-model.md)
> for how seats, sessions, and DRM master fit together.
>
> **Fix = reverse the change:**
> ```bash
> loginctl disable-linger oliver
> ```
> Safe on this box: it autologins every boot, so user services (trccd, honcho)
> still start — linger only matters for keeping them alive with *nobody* logged in,
> which never happens on an autologin gaming PC.

## Symptoms

1. **Boot hangs at game mode.** Sometimes boots fine, sometimes the screen sits
   there forever and only a hard power-cycle recovers. Deterministic tell:
   **warm reboot (Ctrl+Alt+Del) hangs, only a forced power-off boots** — that's a
   race for who births the user manager (see root cause). In the journal:
   ```
   gamescope-session[…]: drm: opening DRM node '/dev/dri/card1'
   gamescope-session[…]: wlserver: [libseat] Could not take device: Device or resource busy
   gamescope-session[…]: drm: Could not open KMS device
   gamescope-session[…]: Failed to create backend.
   kernel: gamescope-shdr[…]: segfault …
   systemd[…]: gamescope-session.service: Main process exited, code=dumped, status=11/SEGV
   systemd-logind[…]: New session '2' of user 'oliver' … type 'wayland'.
   systemd-logind[…]: Removed session 2.            ← created + killed same second
   ```
   …repeating once a second (plasmalogin `Relogin=true` relaunch storm).

2. **Vulkan popup in games:**
   ```
   CreateSwapchainKHR: Creating swapchain for non-Gamescope swapchain.
   Hooking has failed somewhere!
   You may have a bad Vulkan layer interfering.
   ```

## Root cause — the real one (linger)

The chain, top to bottom:

- `loginctl enable-linger oliver` was set on 2026-05-29 (likely to keep `trccd` /
  honcho user services alive headless).
- With linger on, `user@1000.service` (your personal systemd manager) starts at
  **boot**, parented to a logind session of class `manager` that has **no seat**
  — *before* plasmalogin autologins you onto `seat0`.
- There is only **one** user manager. `gamescope-session.service` runs under it.
- gamescope asks logind (`TakeDevice`) for DRM master on `/dev/dri/card1`. logind
  grants the GPU **only to the session that is active on `seat0`**. gamescope's
  controlling session is the seatless `manager` one → **denied**, `Device or
  resource busy` → `Could not open KMS device` → `Failed to create backend` →
  **SIGSEGV**.
- gamescope dies; plasmalogin (`Relogin=true`) immediately re-fires; same failure;
  loop. The machine appears hung at boot.

**Why warm reboot fails but cold boot works:** it's a race over which session
births the user manager. Warm reboot (caches warm) → the lingering manager wins
→ gamescope ends up seatless → hang. Cold boot (slower) → plasmalogin's `seat0`
session wins → gamescope is on the active seat → works. Disabling linger removes
the seatless contender entirely, so there's no race left.

The Vulkan popup is the **same bug downstream**: when boot drops out of game
mode, games launch on plain Plasma; the global gamescope WSI implicit layer
(`VkLayer_FROG_gamescope_wsi`) sees it isn't under gamescope and throws the
"non-Gamescope swapchain" warning. Not a corrupt Proton prefix.

## Fix

```bash
loginctl disable-linger oliver
```

That's the whole fix. Verify next boot:

```bash
journalctl -b 0 | grep -iE 'Started Gamescope Session|Could not open KMS|Device or resource busy'
```

You want **`Started Gamescope Session`** and **no** `Device or resource busy`.

## Secondary insurance: the WAYLAND_DISPLAY drop-in

`apply-gamescope-boot-fix.sh` installs `gamescope-session.service.d/override.conf`:

```ini
[Service]
UnsetEnvironment=DISPLAY XAUTHORITY WAYLAND_DISPLAY
```

This is **not** the fix for the linger bug, but it is kept as defence against a
*separate* failure mode: KDE Plasma can leak `WAYLAND_DISPLAY=wayland-0` into the
`systemctl --user` manager environment. The stock unit unsets `DISPLAY XAUTHORITY`
but not `WAYLAND_DISPLAY`; if the leak is present, gamescope's backend
auto-detection picks the **nested wayland backend**, tries to connect to a parent
compositor that doesn't exist, and exits 1. Unsetting `WAYLAND_DISPLAY` forces
fall-through to DRM/KMS. Harmless no-op when the var isn't leaked.

## Notes

- This is a per-user drop-in (`~/.config/systemd/user/...`); it survives package
  updates, unlike editing the stock unit.
- All 41 files of `gamescope-session-cachyos` are stock/unmodified — the bug was
  never in the package, only in user config (linger).
- If RE9 / Pragmata still carry a `DISABLE_GAMESCOPE_WSI=1` launch option from an
  earlier band-aid attempt, it's harmless but unnecessary. Leaving it on disables
  gamescope's VRR/HDR/scaling handoff inside game mode, so drop it once boot is
  confirmed.
