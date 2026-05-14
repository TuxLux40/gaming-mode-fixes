# Thermalright cooler — TRCC setup

`trcc-linux` (AUR package, Thermalright LCD/LED Control Center for Linux) installs
its config files under `/usr/lib/...` but checks for them at `/etc/...` on every
run. Until a one-time setup runs, `trcc-detect` always greets you with:

```
[TRCC] First run — device permissions need to be configured.
       This requires your password (sudo) to install udev rules.
```

and refuses to drive the device:

```
Device 0416:8001 needs updated udev rules.
Run:  sudo trcc setup-udev
```

## Run setup

```bash
sudo bash setup-trcc.sh
```

This wraps `trcc setup-udev` plus the live module reload steps so neither a
reboot nor a re-plug is needed.

## What it does

1. **`trcc setup-udev`** — copies the package's files to the locations trcc
   expects:
   - `/etc/udev/rules.d/99-trcc-lcd.rules` — `MODE="0666"` on hidraw + libusb
     interfaces for the supported Thermalright VID:PID pairs (`0402:3922`,
     `0416:5302`, `0416:5406`, `0416:8001`, `87cd:70db`).
   - `/etc/modprobe.d/trcc-lcd.conf` — forces `usb-storage` to use
     bulk-only protocol (bypass UAS) for the LCD devices.
   - `/etc/modules-load.d/trcc-sg.conf` — ensures the `sg` (SCSI generic)
     module is loaded so the LCD shows up as `/dev/sgX`.
   - `/etc/polkit-1/rules.d/50-trcc.rules` + the polkit action — lets the
     non-root GUI invoke privileged setup commands.

2. **Live module reload** — applies the usb-storage quirks immediately so
   newly-plugged LCDs work without rebooting:
   ```
   modprobe -r uas usb_storage
   modprobe usb_storage quirks=0402:3922:u,0416:5406:u,87cd:70db:u
   ```

3. **udev reload + trigger** — re-applies the new rules to currently-plugged
   USB devices (LED controller and LCD).

4. **`trcc-detect`** — reports what was found.

## What the AX120R Digital actually exposes over USB

The **Assassin X 120R Digital** uses `0416:8001` for **both** the LED ring and
the 3-digit segment temperature display — they share a single USB HID device.
There is no separate `0416:5406` SCSI/LCD device on this cooler. The segment
display is driven by trcc's `hid_led` / `AX120Display` renderer.

| VID:PID | Role |
|---------|------|
| `0416:8001` | LED ring + 3-digit segment temp display (same device) |

The `0416:5406` (SCSI LCD) entry in trcc's device table is for other Thermalright
coolers (LC1, LC2, LC3, LC5 AIO pump heads) that have a full square LCD panel.

## Daemon metrics loop fix (re-apply after upgrades)

`trccd.service` (`trcc daemon`) discovers devices but never calls
`start_metrics_loop()` — the 50ms tick thread that reads CPU/GPU temps and
sends them to the display. Without it the device connects but shows nothing.

Run this after every `pacman -S trcc-linux` upgrade:

```bash
sudo bash patch-trcc-daemon.sh
```

Or apply manually:
```bash
sudo python3 -c "
import pathlib
p = pathlib.Path('/usr/lib/python3.14/site-packages/trcc/daemon.py')
txt = p.read_text()
old = '    trcc = _build_trcc()\n\n    server = IPCServer'
new = '    trcc = _build_trcc()\n    trcc.start_metrics_loop()\n\n    server = IPCServer'
assert old in txt, 'Pattern not found — daemon layout changed, check manually'
p.write_text(txt.replace(old, new, 1))
print('Patched OK')
"
sudo systemctl restart trccd.service
```

**Root cause:** `run_daemon()` in `daemon.py` sets up the IPC socket and Qt event
loop but never calls `trcc.start_metrics_loop()`. The GUI and API server do call
it (so they work), but the bare daemon does not. This is unfixed through at least
v9.5.11 of trcc-linux.

## OpenRGB and the LED ring

`0416:8001` is a generic HID LED controller. trcc can drive it via the rules
above, but **OpenRGB does not natively support this Thermalright LED ring**
(it appears as "HID Transfer" in lsusb, which OpenRGB skips). Use trcc for the
cooler LED ring, OpenRGB for everything else (motherboard, keyboard, soundbar).

## Verification

After `setup-trcc.sh`:

```bash
trcc-detect          # should show your devices without the first-run banner
trcc                 # CLI help
trcc-gui             # GUI
```

If `trcc-detect` still complains, check that these files now exist:

```bash
ls -l /etc/udev/rules.d/99-trcc-lcd.rules \
      /etc/modprobe.d/trcc-lcd.conf \
      /etc/modules-load.d/trcc-sg.conf \
      /etc/polkit-1/rules.d/50-trcc.rules
```
