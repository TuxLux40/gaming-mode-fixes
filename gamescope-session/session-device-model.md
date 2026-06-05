# How seats, sessions, and devices fit together

A mental model for *why* the gaming PC couldn't get into game mode — and the same
shape that explains the cooler display and keyboard RGB conflicts.

## The one idea

> **A physical device can only be owned by one program at a time, and something
> has to decide who.** Find the arbiter and the conflict stops being mysterious.

```
  PHYSICAL                LOGICAL                       ARBITER
  ────────                ───────                       ───────
  GPU = /dev/dri/card1    "DRM master" = the ONE        systemd-logind
  (draws pixels)          program allowed to draw       = the bouncer
        │                       ▲
        │                       │ "may I draw?"
   ┌────┴─────┐                 │
   │  seat0   │  ← a seat = monitor + keyboard + mouse + GPU
   │ (this PC │     bundled as "one physical workstation"
   │ has ONE) │
   └──────────┘
```

| Term | Plain meaning |
|------|---------------|
| **Device** | `/dev/dri/card1` — the RX 7600. Only one program may drive the screen at once. |
| **DRM master** | The name for that "I'm the one drawing" privilege. |
| **Seat** | A bundle of *monitor + keyboard + mouse + GPU* = one physical place a human sits. This PC has exactly one: `seat0`. |
| **Session** | One login's worth of activity. There can be several, but only **one is "active"** on the seat (the one on screen). |
| **logind** | The bouncer. Hands DRM master **only to the session that is active on the seat.** Everyone else gets `Device or resource busy`. |
| **User manager** (`user@1000`) | Your personal systemd. Runs your background user services (trccd, honcho). gamescope runs *under* it — and **inherits its parent session's seat status.** |
| **Linger** | "Keep my user manager running even when I'm logged out." Side effect: the manager is born at **boot** from a seatless ghost session instead of from your real login. |

## The boot bug — broken vs fixed

```
BROKEN  (linger = yes)                    FIXED  (linger = no)
─────────────────────                     ────────────────────
boot                                      boot
 │                                         │
 ├─ logind makes a GHOST session           ├─ plasmalogin autologins you
 │   class=manager, seat = NONE            │      │
 │      │                                  │      └─ session on seat0, ACTIVE
 │      └─ starts user@1000  ◀── born      │             │
 │                from seatless ghost      │             └─ starts user@1000 ◀── born
 │                                         │                      from the ACTIVE seat0 session
 ├─ plasmalogin autologins (seat0)         │
 │                                         │
 └─ gamescope starts under user@1000       └─ gamescope starts under user@1000
        │                                         │
        │ "logind, give me card1"                 │ "logind, give me card1"
        ▼                                         ▼
   bouncer: your parent session            bouncer: your parent session
   has NO seat → DENIED, "busy"            IS the active seat0 → GRANTED ✓
        │                                         │
        ▼                                         ▼
   gamescope: can't open KMS →             gamescope draws → game mode boots
   crash → plasmalogin relaunches →
   crash → … = the hang/storm
```

**Warm vs cold reboot** is a race over who births the manager first. Warm reboot
(caches warm) → ghost wins → broken. Cold boot (slower) → real login wins → works.
Disabling linger deletes the ghost, so there's no race.

## Same pattern, the other "dark" problems

Every hardware headache on this box is the same shape — *device → single-owner
privilege → arbiter → conflict when two things want it.*

| | Device | Arbiter | The conflict |
|---|---|---|---|
| **Boot** | `/dev/dri/card1` (GPU) | logind → DRM master | seatless ghost session vs your login |
| **Cooler display** | `/dev/hidraw*` (USB `0416:5406`) | the single `trcc` daemon that may hold the USB endpoint | two `trcc daemon`s fighting = the fork-bomb |
| **Keyboard RGB** | USB HID endpoint | first program to grab the HID interface | OpenRGB vs other RGB software polling the same device |

When something "doesn't work," ask: **who is holding the device, and who is the
arbiter saying no?** Tools that answer it:

```bash
sudo fuser -v /dev/dri/card1      # who holds the GPU right now
loginctl list-sessions            # which sessions exist, which seat, which active
loginctl show-user oliver -p Linger
journalctl -b -1 | grep -i 'busy\|TakeDevice\|seat'   # the bouncer's refusals last boot
```
