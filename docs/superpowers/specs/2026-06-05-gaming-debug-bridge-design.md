# Gaming-box remote debug bridge — design

> Status: design / approved-pending-review · Date: 2026-06-05 · Repo: gaming-mode-fixes

## Purpose

Let oliver debug and fix the CachyOS gaming box (`os93-steam-pc`) **from his phone**,
through OpenWebUI, including while it is in Steam game mode (no terminal/desktop
available) and while its graphical session is broken or boot-looping.

The driving pain: in game mode there is no way to run an agent or read errors. But
the errors already exist — `journald` captures gamescope, every game's stdout/err,
and systemd. The missing piece is **remote hands-and-eyes** into steam-pc that a
model (driven from the phone) can use to investigate *novel* problems live — not
just replay canned fixes.

Concrete target cases:
- "Binary Domain won't start" / "Decky Loader is crashing again" — diagnose and fix.
- A *new* failure with no existing script (e.g. today's linger boot-loop, which
  required open-ended investigation: `fuser`, `loginctl`, log reading, hypothesis
  killing). The agent must be able to do that kind of work, not only run scripts.

## Threat model (why the design is shaped this way)

**steam-pc is the disposable node.** It is deliberately unencrypted, first GRUB
entry, auto-boots into game mode, and is power-cyclable remotely without unlocking
LUKS. A trashed steam-pc costs ~nothing — reboot/reimage. Therefore:

- Do **not** spend the security budget handcuffing the agent *on* steam-pc.
- Spend it on the **wall between steam-pc and the encrypted Proxmox cluster** —
  the only thing whose compromise is expensive.

Game-originated risk is low (oliver rarely plays multiplayer / untrusted titles),
so the guardrails are sized for "a local model does something dumb," not "a hostile
game pivots into the network."

**Irreducible fact accepted by this design:** "debug anything, then and there" =
root-equivalent power. No command allowlist can grant open-ended investigation
without also granting open-ended damage — they are the same capability. So the
agent gets a real root shell on steam-pc, and safety is **damage control**, not
capability limits.

## Architecture

```
 PHONE          PROXMOX (always-on, encrypted)          STEAM-PC (disposable)
 Conduit ──ws──▶ OpenWebUI                               sshd  (system unit —
 (OWU client)      │  model picks the SSH tool             │    survives session storm)
                   ▼                                        ▼
                existing OWU SSH tool  ──ssh/tailnet──▶  otdebug  (dedicated user,
                (holds PRIVATE key,                         │      NOT oliver, no creds
                 host = steam-pc tailnet IP)                │      to other hosts)
                                                            ▼
                                                    debug-shell-wrap
                                                    (login shell / ForceCommand)
                                                       ├ audit-log every command+output
                                                       ├ confirm-gate irreversible verbs
                                                       └ otherwise: full shell + sudo
```

- **Front end (already solved):** phone → **Conduit** (native OWU client) → **OWU**
  on Proxmox. Nothing to build; install the app, point it at OWU.
- **Brain:** an OWU model. System prompt embeds the **systematic-debugging** loop
  (reproduce → hypothesis → check evidence → narrow → fix → verify) so a small
  local model investigates methodically instead of flailing with root. Model
  routing/cost (local ollama vs API) is a Phase-2 concern (LiteLLM).
- **Transport (install, do not build):** an existing community OWU SSH tool. The
  OWU side is only an SSH client; it needs no custom code. The private key lives
  in OWU's valves on Proxmox.
- **Target:** `otdebug` on steam-pc, reached over Tailscale, key-only.

## Components (each one job)

1. **OWU SSH tool** (Proxmox) — existing community tool, configured with host + key.
   Turns model intent into one SSH invocation. *Not built by us.*
2. **`otdebug` user + `authorized_keys`** (steam-pc) — the single constrained door.
   `sshd` `Match User otdebug`: key-only, source restricted to the OWU host.
   No SSH keys or secrets to any other host live in this account.
3. **`debug-shell-wrap`** (steam-pc, new, in this repo) — `otdebug`'s login shell /
   `ForceCommand`. A **transparent** wrapper, not a filter:
   - appends every command + output to an append-only audit log (+ journal);
   - intercepts a small deny-by-default list of **irreversible** verbs and requires
     a one-tap approval flag before running them;
   - otherwise passes the command through to a real shell with sudo available.
4. **sudoers drop-in** — `otdebug` gets broad `NOPASSWD` sudo (root-equivalent on
   steam-pc). Capability is intentionally wide; damage control is in (3) and the ACL.
5. **Tailscale ACL stanza** — only the OWU/Proxmox host may reach
   `otdebug@steam-pc:22`. One rule. Applied via admin console paste or Tailscale API.
6. **Repo fix scripts** (optional shortcuts, not a cage) — existing
   `binary-domain/fix-*.sh` and new `restart-decky` / `relaunch-game <appid>` /
   `restart-gamescope-session`. The agent *may* call them as known-good fast paths;
   it is never limited to them.

## Capability & guardrail model

- **Capability:** full interactive shell as `otdebug` + broad `sudo` =
  root-equivalent on steam-pc. Free investigation and free fixing.
- **Guardrail 1 — containment wall (protects the cluster):** `otdebug` holds no
  creds to other hosts; inbound ACL limits who can reach it to the OWU host. Worst
  realistic case = a trashed disposable box, not a cluster pivot. *(Egress firewall
  steam-pc→cluster is deferred: heavy, fights normal ollama↔OWU traffic, and
  "no creds" already covers the pivot risk.)*
- **Guardrail 2 — audit:** every command + output logged, reviewable from the phone.
  Receipts for when a local model misbehaves.
- **Guardrail 3 — confirm-gate irreversibles only:** deny-by-default on
  `rm -rf` of system paths, `mkfs`/`dd` to block devices, `userdel`, rebooting other
  hosts, reading/writing `~/.ssh`. These need a one-tap approval; everything else
  runs instantly so investigation is never slowed.

## Survival behaviour

- **Session healthy:** wrapper reads the user journal, relaunches games, edits the
  session's configs (via sudo to oliver/root as needed).
- **Session storming / down:** wrapper still runs under the **system** `sshd`, reads
  the system journal, and can `sudo systemctl restart gamescope-session`, apply the
  linger/gamescope fixes, etc.
- **Kernel reboot-looping:** nothing on-box is reachable — irreducible, out of scope.

## What we install vs build

- **Install / configure (no code):** Conduit on phone; an existing OWU SSH tool;
  the Tailscale ACL stanza.
- **Build (steam-pc system config + small scripts, in this repo):** `otdebug` user,
  `sshd` match block, `debug-shell-wrap`, sudoers drop-in, the new fix-script
  shortcuts, and the agent's systematic-debugging system prompt.
- **Do NOT use:** open-terminal (sandbox, wrong fit); a custom OWU tool; a Tailscale
  MCP (one ACL rule doesn't justify it).

## Phasing

- **Phase 1 (buildable now):** otdebug + sshd match + `debug-shell-wrap`
  (audit + confirm-gate) + broad sudo + ACL + existing OWU SSH tool wired up +
  systematic-debugging system prompt. Result: full live remote debugging from the
  phone, in both session states.
- **Phase 2 (later, noted not built):** new fix-script shortcuts as they emerge;
  LiteLLM multiplexer for model routing/cost (addresses the Hermes "one model"
  limit); optional egress firewall; optional Tailscale MCP for ongoing automation.

## Out of scope

- Kernel-reboot-loop recovery (nothing on-box survives it).
- Securing OWU's own auth (owned separately; Conduit→OWU is the front door).
- The dedicated-gaming-user refactor (the deeper "games run as oliver" fix) — flagged
  for later, not required given low game risk.

## Open implementation decisions (resolve in the plan)

- Which existing OWU SSH tool (Wes Caldwell SSH Connection Manager vs an
  `execute_bash`-over-SSH variant) — pick on auth/maintenance fit.
- `debug-shell-wrap` as `ForceCommand` vs login shell, and exact audit-log location
  + phone-readable surface.
- Confirm-gate approval mechanism (flag file toggled via a separate read-only
  command the agent can't set itself, vs an OWU-side confirmation).
- ACL application method (console paste vs API token).

## Test plan

- From Proxmox: `ssh otdebug@steam-pc` → read journal; run a fix; verify an
  irreversible verb is gated; verify audit log captured all of it.
- From phone (Conduit→OWU→model): "why won't Binary Domain start" → model reads
  journal, reasons, applies a fix, reports back.
- Storm simulation: stop the graphical session, confirm the bridge still reaches in
  and can restart it.
- Containment: confirm `otdebug` cannot SSH to any cluster host and is unreachable
  from any tailnet node except the OWU host.
