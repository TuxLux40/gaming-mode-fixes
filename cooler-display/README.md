# Thermalright Assassin X 120R Digital — trcc setup

This folder covers getting the **Thermalright Assassin X 120R Digital** cooler's
temperature display working on CachyOS (and other Arch-based distros) using the
`trcc-linux` AUR package.

**TL;DR — display is blank after fresh install or after a `trcc-linux` upgrade:**
```bash
# Fresh install / first time setup:
sudo bash setup-trcc.sh

# After any pacman upgrade of trcc-linux:
sudo bash patch-trcc-daemon.sh
```

---

## Background: what this cooler is and how it works

The AX120R Digital is a CPU liquid cooler. On its pump head it has:

- **A ring of RGB LEDs** around the edge — decorative lighting
- **A 3-digit segment display** in the centre — shows CPU/GPU temperature, cycling
  through a few readings (like "C72" for 72°C CPU, "G65" for 65°C GPU)

Both of those are controlled by a **single USB cable** that plugs into a USB 2.0
internal header on your motherboard. From the OS point of view, it shows up as
one USB device:

| USB ID | What it is |
|--------|------------|
| `0416:8001` | Winbond HID controller — drives both the LED ring and the segment display |

> **Note:** trcc's docs mention a separate `0416:5406` SCSI/LCD device. That's for
> other Thermalright coolers (the LC1/LC2/LC3 series with a square LCD panel). The
> AX120R Digital does **not** have that. If you don't see `0416:5406` in `lsusb`,
> that's normal — you're not missing anything.

The software that controls it is **trcc-linux** (`trcc` on the command line,
`trccd` as the background service). It reads your CPU/GPU temperatures via the
system sensor APIs and sends them to the cooler over USB every 50ms.

---

## Scripts in this folder

| Script | What it does | When to run |
|--------|-------------|-------------|
| `setup-trcc.sh` | One-time first-install setup (udev rules, permissions, module quirks) | Once after installing trcc-linux for the first time |
| `patch-trcc-daemon.sh` | Fixes the display staying blank (metrics loop bug) | After every `pacman -S trcc-linux` upgrade |

---

## Problem 1: "Device needs udev rules" / first-time setup

### Symptom

You installed `trcc-linux` from the AUR but when you run `trcc` you get something
like:

```
[TRCC] First run — device permissions need to be configured.
Device 0416:8001 needs updated udev rules.
Run:  sudo trcc setup-udev
```

Or you can see the device in `lsusb` but `trcc` says it can't find anything.

### Why it happens

`trcc-linux` ships its permission files (udev rules, kernel module quirks) under
`/usr/lib/...` but the `trcc` program looks for them at `/etc/...`. Until the
files are copied over, Linux won't give `trcc` access to the USB device.

### Fix

```bash
cd ~/Projects/gaming-mode-fixes/cooler-display
sudo bash setup-trcc.sh
```

You do **not** need to reboot or unplug the cooler. The script applies everything
live.

### What the script does (in plain English)

1. Runs `trcc setup-udev` which copies the permission files into place:
   - Tells the kernel "give normal users read/write access to this USB device"
   - Tells the USB storage driver to stay away from the LCD devices so trcc can
     talk to them directly
   - Makes sure the SCSI generic module is loaded (needed for some LCD variants)

2. Reloads the USB driver modules immediately (so you don't have to reboot)

3. Tells udev to re-check all currently plugged-in USB devices with the new rules

4. Runs `trcc-detect` to confirm everything is found

### Verify it worked

```bash
trcc status
# Should show: AX120_DIGITAL connected, LED brightness 100%, global on: True
```

---

## Problem 2: Device is found but the display shows nothing

This is the big one. The cooler is detected, `trcc status` looks fine, `trccd`
service is running — but the segment display on the cooler is completely blank.

### Symptom checklist

- `systemctl status trccd.service` → active (running) ✓
- `lsusb | grep 0416:8001` → device found ✓
- `trcc status` → shows device connected ✓
- Display on the cooler → blank / dark ✗

### Why it happens

`trccd.service` runs `trcc daemon`. That daemon:
1. ✅ Starts up
2. ✅ Finds your cooler over USB
3. ✅ Listens on a socket for commands
4. ❌ **Never starts the loop that sends temperature data to the display**

The temperature-reading and display-updating loop (`start_metrics_loop`) is
responsible for reading your CPU/GPU temps every second and sending the
pixel/segment data to the cooler every 50ms. Without it, the cooler is connected
but receives no instructions — so it shows nothing.

This is a bug in `trcc-linux`'s daemon that exists through at least v9.5.11. The
GUI (`trcc gui`) and API server (`trcc api`) both start this loop correctly — only
the bare daemon that `trccd.service` uses is missing the call.

### Fix

```bash
cd ~/Projects/gaming-mode-fixes/cooler-display
sudo bash patch-trcc-daemon.sh
```

This adds one line to `/usr/lib/python3.14/site-packages/trcc/daemon.py` and
restarts the service. Total effect: the daemon now starts the temperature loop on
boot, just like it should have all along.

### ⚠️ You need to re-run this after every trcc-linux upgrade

`pacman` will overwrite `daemon.py` with the unpatched version every time
`trcc-linux` is updated. After any upgrade:

```bash
sudo bash ~/Projects/gaming-mode-fixes/cooler-display/patch-trcc-daemon.sh
```

Or add a pacman hook (see below).

### Verify it worked

```bash
# Should see "Frame sent: LED" lines streaming in
tail -f ~/.trcc/trcc.log
```

If you see those lines, the loop is running and frames are being sent to the
display. The cooler should now show temperatures within a few seconds of the
service starting.

### Optional: pacman hook to auto-reapply after upgrades

Create `/etc/pacman.d/hooks/trcc-patch.hook`:

```ini
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = trcc-linux

[Action]
Description = Re-applying trcc daemon metrics loop patch...
When = PostTransaction
Exec = /bin/bash /home/oliver/Projects/gaming-mode-fixes/cooler-display/patch-trcc-daemon.sh
```

---

## OpenRGB and the LED ring

`0416:8001` is a generic HID LED controller. trcc drives it via the rules above,
but **OpenRGB does not support this Thermalright LED ring** — it shows up as
"HID Transfer" in lsusb, which OpenRGB skips. This is fine:

- Use **trcc** for the cooler's LED ring and segment display
- Use **OpenRGB** for everything else (ASUS motherboard, Logitech G915, Razer
  Leviathan soundbar)

They don't conflict because OpenRGB doesn't claim `0416:8001`.

---

## Quick reference: what to check when the display stops working

Work through this list top to bottom, stopping when you find the problem:

```bash
# 1. Is the USB device visible to the OS at all?
lsusb | grep 0416:8001
# If missing: physical cable issue — check the USB header inside the case

# 2. Is the daemon running?
systemctl status trccd.service
# If not: sudo systemctl start trccd.service

# 3. Is trcc finding the device?
trcc status
# If "no devices": sudo bash setup-trcc.sh

# 4. Is the daemon sending frames?
tail -20 ~/.trcc/trcc.log | grep "Frame sent"
# If no "Frame sent" lines: sudo bash patch-trcc-daemon.sh

# 5. Nuclear option — full restart
sudo systemctl restart trccd.service && sleep 3 && tail -5 ~/.trcc/trcc.log
```

---

## Technical detail (for future debugging)

The relevant code paths, if you need to dig deeper:

- **`/usr/lib/python3.14/site-packages/trcc/daemon.py`** — the daemon entry point.
  `run_daemon()` is the function that starts everything. After the patch it calls
  `trcc.start_metrics_loop()` just before entering the Qt event loop.

- **`/usr/lib/python3.14/site-packages/trcc/core/trcc.py`** — `start_metrics_loop()`
  lives here. It spawns a background thread that runs every 50ms (tick) and every
  `refresh_interval` seconds (sensor poll). The tick sends LED frames; the poll
  reads temperatures via `system_svc.all_metrics`.

- **`~/.trcc/trcc.log`** — the daemon's log file. `DEBUG` level shows every frame
  sent. `WARNING` level shows transport errors. If you see
  `Frame send failed (LED): Transport not open` spamming continuously, the daemon
  lost the USB connection — `sudo systemctl restart trccd.service` fixes it.

- **`/etc/modprobe.d/trcc-lcd.conf`** — the usb-storage quirks file. Must contain
  `options usb-storage quirks=...,0416:5406:u,...` for SCSI LCD devices to work.
  Not directly relevant to the AX120R Digital (which uses HID, not SCSI) but
  `trcc setup-udev` creates it regardless.
