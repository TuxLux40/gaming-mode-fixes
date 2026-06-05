# Gaming-box Remote Debug Bridge — Implementation Plan (Phase 1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let oliver debug/fix `os93-steam-pc` live from his phone via OpenWebUI, in both healthy and broken session states, with a full root shell that is audited and cluster-isolated.

**Architecture:** An existing OWU SSH tool on Proxmox connects over Tailscale to a dedicated `otdebug` user on steam-pc. `otdebug`'s SSH access is forced through `debug-shell-wrap` (append-only audit log + advisory confirm-gate on irreversible verbs), then a real shell with `NOPASSWD: ALL` sudo. steam-pc is treated as a disposable node; the security boundary is the wall between it and the encrypted cluster (no creds on `otdebug` + a one-line Tailscale ACL), not the agent's capability.

**Tech Stack:** Bash, OpenSSH (`ForceCommand`, `sshd_config.d`), sudoers, systemd journal, Tailscale ACL (HuJSON), an off-the-shelf OpenWebUI SSH tool.

**Security honesty:** With `otdebug = NOPASSWD: ALL`, the confirm-gate is **advisory** — it stops an accidental/dumb model command in the normal path, not a root agent that deliberately circumvents it. The **hard** guarantees are: (1) append-only audit (`chattr +a`) so actions leave a receipt, (2) no credentials on `otdebug` to reach other hosts, (3) Tailscale ACL limiting who can reach `otdebug@steam-pc:22`. Those protect the expensive thing (the cluster); the disposable box is allowed to be wrecked-and-rebooted.

**Execution-time safety rules (every task that edits `sshd`/`sudoers`/users):**
- Keep a second **root shell open on steam-pc** for the whole run (recovery if SSH breaks).
- Never reload `sshd` without `sshd -t` passing first.
- Never install sudoers without `visudo -c -f <file>` passing first.
- `rm` is aliased to `trash` on this box; installers use explicit `/usr/bin/rm` only where a real delete is intended, otherwise leave files in place.

---

## File structure (all under `remote-debug/` in this repo)

| Path | Responsibility |
|------|----------------|
| `remote-debug/README.md` | Setup recipe + recovery notes |
| `remote-debug/debug-shell-wrap.sh` | `ForceCommand` wrapper: audit-log + advisory gate + passthrough. **The only real logic.** |
| `remote-debug/irreversible-patterns.txt` | Newline list of regex patterns the gate blocks |
| `remote-debug/sshd-otdebug.conf` | `sshd_config.d` drop-in: `Match User otdebug` (key-only, ForceCommand, tailnet source) |
| `remote-debug/sudoers-otdebug` | `/etc/sudoers.d` drop-in: `otdebug ALL=(ALL) NOPASSWD: ALL` |
| `remote-debug/install-debug-bridge.sh` | Idempotent root installer on steam-pc: creates user, deploys the above, sets up `chattr +a` audit log |
| `remote-debug/fixes/restart-decky.sh` | Shortcut: restart Decky Loader |
| `remote-debug/fixes/relaunch-game.sh` | Shortcut: relaunch a Steam appid in game mode |
| `remote-debug/fixes/restart-gamescope-session.sh` | Shortcut: restart the gamescope session |
| `remote-debug/owu-agent-system-prompt.md` | System prompt embedding the systematic-debugging loop |
| `remote-debug/tailscale-acl-stanza.hujson` | The single ACL rule + apply instructions |
| `remote-debug/tests/test-debug-shell-wrap.sh` | Self-contained bash unit tests for the wrapper |
| `remote-debug/tests/assert.sh` | Tiny assert helper (no external dep) |

---

## Task 0: Scaffold `remote-debug/` [steam-pc repo] [claude]

**Files:**
- Create: `remote-debug/README.md`
- Create: `remote-debug/tests/assert.sh`

- [ ] **Step 1: Create the test assert helper**

Create `remote-debug/tests/assert.sh`:

```bash
#!/usr/bin/env bash
# Minimal assert helpers — no external test framework needed.
ASSERT_FAILS=0
assert_eq() { # $1 expected, $2 actual, $3 msg
  if [ "$1" != "$2" ]; then
    printf 'FAIL: %s\n  expected: %q\n  actual:   %q\n' "$3" "$1" "$2" >&2
    ASSERT_FAILS=$((ASSERT_FAILS+1))
  else printf 'ok: %s\n' "$3"; fi
}
assert_contains() { # $1 haystack, $2 needle, $3 msg
  if printf '%s' "$1" | grep -qF -- "$2"; then printf 'ok: %s\n' "$3"
  else printf 'FAIL: %s\n  %q not in output\n' "$3" "$2" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi
}
finish() { [ "$ASSERT_FAILS" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$ASSERT_FAILS FAILED"; exit 1; }; }
```

- [ ] **Step 2: Create README skeleton**

Create `remote-debug/README.md` with a one-paragraph summary pointing at the spec
(`docs/superpowers/specs/2026-06-05-gaming-debug-bridge-design.md`) and a "Recovery"
section noting: keep a root shell open; `sshd -t` before reload; the audit log is at
`/var/log/otdebug/audit.log`.

- [ ] **Step 3: Commit**

```bash
git add remote-debug/README.md remote-debug/tests/assert.sh
git commit -m "remote-debug: scaffold dir + test assert helper"
```

---

## Task 1: `debug-shell-wrap.sh` — audit + advisory gate (TDD) [steam-pc repo] [claude]

This is the core. It runs as `otdebug`'s `ForceCommand`. SSH puts the requested
command in `$SSH_ORIGINAL_COMMAND`. Behaviour:
- Empty command → interactive `bash -l` (human break-glass), after logging a marker.
- Non-empty → append `timestamp | cmd` to audit log; if cmd matches an irreversible
  pattern AND the approval flag `/run/otdebug/allow-irreversible` is absent → refuse
  and log the refusal; else exec the command via `bash -c`.

**Files:**
- Create: `remote-debug/debug-shell-wrap.sh`
- Create: `remote-debug/irreversible-patterns.txt`
- Test: `remote-debug/tests/test-debug-shell-wrap.sh`

- [ ] **Step 1: Write the failing tests**

Create `remote-debug/tests/test-debug-shell-wrap.sh`:

```bash
#!/usr/bin/env bash
# Unit tests for debug-shell-wrap.sh. Runs fully sandboxed: overrides the audit
# log path and approval flag via env so no root / real paths are touched.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/assert.sh"
WRAP="$HERE/../debug-shell-wrap.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export OTDEBUG_AUDIT_LOG="$TMP/audit.log"
export OTDEBUG_FLAG="$TMP/allow-irreversible"
export OTDEBUG_PATTERNS="$HERE/../irreversible-patterns.txt"

run() { SSH_ORIGINAL_COMMAND="$1" bash "$WRAP" 2>&1; }

# 1. benign command runs and its stdout is returned
out="$(run 'echo hello')"
assert_eq "hello" "$out" "benign command executes and returns stdout"

# 2. benign command is recorded in the audit log
assert_contains "$(cat "$OTDEBUG_AUDIT_LOG")" "echo hello" "audit log records benign command"

# 3. irreversible command is blocked when flag absent
out="$(run 'rm -rf /etc')"
assert_contains "$out" "BLOCKED" "irreversible command blocked without approval flag"
assert_contains "$(cat "$OTDEBUG_AUDIT_LOG")" "BLOCKED" "audit log records the block"

# 4. the dangerous command did NOT run (sentinel still present)
touch "$TMP/sentinel"
run "/usr/bin/rm -rf $TMP/sentinel" >/dev/null
assert_eq "yes" "$([ -e "$TMP/sentinel" ] && echo yes || echo no)" "blocked rm did not delete sentinel"

# 5. with approval flag present, irreversible command is allowed through
touch "$OTDEBUG_FLAG"
out="$(run 'echo would-delete')"
assert_eq "would-delete" "$out" "approval flag lets commands through (gate open)"
rm -f "$OTDEBUG_FLAG"

# 6. benign command containing a safe substring is not falsely blocked
out="$(run 'echo formatting the message')"
assert_eq "formatting the message" "$out" "no false-positive on word 'format' in echo"

finish
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `bash remote-debug/tests/test-debug-shell-wrap.sh`
Expected: FAIL (wrap script + patterns file do not exist yet).

- [ ] **Step 3: Write the irreversible patterns**

Create `remote-debug/irreversible-patterns.txt` (extended-regex, one per line; anchored
on command boundaries to limit false positives):

```
(^|[;&|[:space:]])rm[[:space:]]+(-[[:alnum:]]*[rf][[:alnum:]]*[[:space:]]+)+(/|/etc|/usr|/var|/home|/boot|~/\.ssh)
(^|[;&|[:space:]])mkfs([.][[:alnum:]]+)?[[:space:]]
(^|[;&|[:space:]])dd[[:space:]].*of=/dev/
(^|[;&|[:space:]])userdel[[:space:]]
(^|[;&|[:space:]])(shutdown|reboot|systemctl[[:space:]]+(poweroff|reboot))([[:space:]]|$)
([[:space:]]|^)>[[:space:]]*/dev/(sd|nvme|mmcblk)
~/\.ssh
```

- [ ] **Step 4: Write minimal `debug-shell-wrap.sh`**

Create `remote-debug/debug-shell-wrap.sh`:

```bash
#!/usr/bin/env bash
# otdebug ForceCommand wrapper: append-only audit + advisory irreversible-gate.
# Paths overridable via env for testing; production defaults below.
set -u
AUDIT_LOG="${OTDEBUG_AUDIT_LOG:-/var/log/otdebug/audit.log}"
FLAG="${OTDEBUG_FLAG:-/run/otdebug/allow-irreversible}"
PATTERNS="${OTDEBUG_PATTERNS:-/etc/otdebug/irreversible-patterns.txt}"

cmd="${SSH_ORIGINAL_COMMAND:-}"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '%s | %s\n' "$(ts)" "$1" >> "$AUDIT_LOG" 2>/dev/null || true; }

# Interactive break-glass when no one-shot command was given.
if [ -z "$cmd" ]; then
  log "INTERACTIVE shell opened"
  exec bash -l
fi

log "CMD: $cmd"

if [ -r "$PATTERNS" ]; then
  while IFS= read -r pat; do
    [ -z "$pat" ] && continue
    if printf '%s' "$cmd" | grep -Eq -- "$pat"; then
      if [ ! -e "$FLAG" ]; then
        log "BLOCKED (matched /$pat/): $cmd"
        printf 'BLOCKED: irreversible command requires approval (matched a guard pattern).\n' >&2
        printf 'To allow: create %s out-of-band, then retry.\n' "$FLAG" >&2
        exit 13
      fi
      log "ALLOWED-WITH-FLAG (matched /$pat/): $cmd"
      break
    fi
  done < "$PATTERNS"
fi

exec bash -c "$cmd"
```

- [ ] **Step 5: Run tests, verify they pass**

Run: `bash remote-debug/tests/test-debug-shell-wrap.sh`
Expected: `ALL PASS`.

- [ ] **Step 6: Commit**

```bash
git add remote-debug/debug-shell-wrap.sh remote-debug/irreversible-patterns.txt remote-debug/tests/test-debug-shell-wrap.sh
git commit -m "remote-debug: ForceCommand wrapper with audit + advisory irreversible gate (TDD)"
```

---

## Task 2: Fix-script shortcuts [steam-pc repo] [claude]

Optional fast paths the agent may call. Each supports `--dry-run` so it can be
smoke-tested without side effects.

**Files:**
- Create: `remote-debug/fixes/restart-decky.sh`
- Create: `remote-debug/fixes/relaunch-game.sh`
- Create: `remote-debug/fixes/restart-gamescope-session.sh`

- [ ] **Step 1: `restart-decky.sh`**

```bash
#!/usr/bin/env bash
# Restart Decky Loader (plugin_loader.service is a system service on CachyOS).
set -euo pipefail
DRY="${1:-}"
unit="plugin_loader.service"
if [ "$DRY" = "--dry-run" ]; then echo "would: systemctl restart $unit"; exit 0; fi
sudo systemctl restart "$unit"
systemctl is-active "$unit"
```

- [ ] **Step 2: `relaunch-game.sh`**

```bash
#!/usr/bin/env bash
# Relaunch a Steam appid in game mode. Usage: relaunch-game.sh <appid> [--dry-run]
set -euo pipefail
appid="${1:?usage: relaunch-game.sh <appid> [--dry-run]}"
DRY="${2:-}"
launch="steam steam://rungameid/${appid}"
if [ "$DRY" = "--dry-run" ]; then echo "would: $launch (as oliver)"; exit 0; fi
sudo -u oliver env XDG_RUNTIME_DIR=/run/user/1000 DISPLAY=:0 $launch
```

- [ ] **Step 3: `restart-gamescope-session.sh`**

```bash
#!/usr/bin/env bash
# Restart the gamescope session (system-level recovery; works even if session is wedged).
set -euo pipefail
DRY="${1:-}"
if [ "$DRY" = "--dry-run" ]; then echo "would: systemctl restart plasmalogin.service"; exit 0; fi
# plasmalogin owns the seat; restarting it re-runs autologin into gamescope.
sudo systemctl restart plasmalogin.service
```

- [ ] **Step 4: Smoke-test all three in dry-run**

Run:
```bash
bash remote-debug/fixes/restart-decky.sh --dry-run
bash remote-debug/fixes/relaunch-game.sh 203750 --dry-run
bash remote-debug/fixes/restart-gamescope-session.sh --dry-run
```
Expected: each prints a `would: ...` line and exits 0.

- [ ] **Step 5: Commit**

```bash
git add remote-debug/fixes/
git commit -m "remote-debug: add dry-runnable fix shortcuts (decky/relaunch/gamescope)"
```

---

## Task 3: Idempotent installer `install-debug-bridge.sh` [steam-pc repo] [claude]

Deploys everything onto the live system. Idempotent: safe to re-run.

**Files:**
- Create: `remote-debug/install-debug-bridge.sh`
- Create: `remote-debug/sshd-otdebug.conf`
- Create: `remote-debug/sudoers-otdebug`

- [ ] **Step 1: Write the sshd drop-in**

Create `remote-debug/sshd-otdebug.conf` (deployed to `/etc/ssh/sshd_config.d/`).

`ForceCommand` applies to `otdebug` from **all** sources on purpose — so there is no
path where otdebug gets a normal shell. Do NOT add a nested `Match Address` here:
`sshd` would treat it as a separate block, breaking the AND and creating a
shell-fallthrough hole. Source restriction (only the OWU host may connect) is the
Tailscale ACL's job in Task 6 — network layer, defense in depth.

```
Match User otdebug
    PasswordAuthentication no
    PubkeyAuthentication yes
    AuthenticationMethods publickey
    X11Forwarding no
    AllowTcpForwarding no
    PermitTTY yes
    ForceCommand /usr/local/lib/otdebug/debug-shell-wrap.sh
```

- [ ] **Step 2: Write the sudoers drop-in**

Create `remote-debug/sudoers-otdebug` (deployed to `/etc/sudoers.d/otdebug`, mode 0440):

```
# otdebug: full root on the DISPOSABLE gaming box. Audit + gate are in
# debug-shell-wrap.sh; this is intentionally broad (see plan security note).
otdebug ALL=(ALL) NOPASSWD: ALL
```

- [ ] **Step 3: Write the installer**

Create `remote-debug/install-debug-bridge.sh`:

```bash
#!/usr/bin/env bash
# Idempotent. Run as root on steam-pc: sudo bash remote-debug/install-debug-bridge.sh
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
SRC="$(cd "$(dirname "$0")" && pwd)"
LIBDIR=/usr/local/lib/otdebug
ETCDIR=/etc/otdebug
LOGDIR=/var/log/otdebug

# 1. user (no password login; home for authorized_keys)
id otdebug &>/dev/null || useradd --create-home --shell /bin/bash otdebug
passwd -l otdebug || true

# 2. deploy wrapper + patterns
install -d -m 0755 "$LIBDIR" "$ETCDIR"
install -m 0755 "$SRC/debug-shell-wrap.sh" "$LIBDIR/debug-shell-wrap.sh"
install -m 0644 "$SRC/irreversible-patterns.txt" "$ETCDIR/irreversible-patterns.txt"
install -d -m 0755 "$LIBDIR/fixes"
install -m 0755 "$SRC"/fixes/*.sh "$LIBDIR/fixes/"

# 3. append-only audit log (chattr +a survives even root casually; conscious bypass only)
install -d -m 0750 -o otdebug -g otdebug "$LOGDIR"
touch "$LOGDIR/audit.log"; chown otdebug:otdebug "$LOGDIR/audit.log"
chattr +a "$LOGDIR/audit.log" || echo "WARN: chattr +a unsupported on this fs" >&2

# 4. runtime flag dir (default-absent = gate closed)
install -d -m 0755 /run/otdebug

# 5. sshd drop-in (substitute tailnet cidr already correct in file)
install -m 0644 "$SRC/sshd-otdebug.conf" /etc/ssh/sshd_config.d/60-otdebug.conf
sshd -t
systemctl reload sshd

# 6. sudoers (validate before install)
visudo -cf "$SRC/sudoers-otdebug"
install -m 0440 "$SRC/sudoers-otdebug" /etc/sudoers.d/otdebug

echo "install OK. Next: add OWU public key to /home/otdebug/.ssh/authorized_keys (Task 6)."
```

- [ ] **Step 4: Dry validate the scripts (no system change yet)**

Run:
```bash
bash -n remote-debug/install-debug-bridge.sh
visudo -cf remote-debug/sudoers-otdebug
```
Expected: no syntax errors; `sudoers-otdebug: parsed OK`.

- [ ] **Step 5: Commit**

```bash
git add remote-debug/install-debug-bridge.sh remote-debug/sshd-otdebug.conf remote-debug/sudoers-otdebug
git commit -m "remote-debug: idempotent installer + sshd/sudoers drop-ins"
```

---

## Task 4: Run the installer on steam-pc [steam-pc system] [claude — CONFIRM with oliver first]

> Hard-to-reverse system change. Keep a second root shell open. Do not proceed if
> `sshd -t` fails.

- [ ] **Step 1: Open a safety root shell (separate terminal, leave running)**

Run (in a separate terminal): `sudo -i` and leave it. This is the recovery path if
SSH config breaks.

- [ ] **Step 2: Run installer**

Run: `sudo bash remote-debug/install-debug-bridge.sh`
Expected: ends with `install OK.` and no `sshd -t` error.

- [ ] **Step 3: Verify pieces exist**

Run:
```bash
id otdebug
sudo -l -U otdebug | grep -i nopasswd
ls -l /usr/local/lib/otdebug/debug-shell-wrap.sh
lsattr /var/log/otdebug/audit.log | grep -q -- '-a-' && echo "append-only OK"
sshd -T 2>/dev/null | grep -A0 -i forcecommand || sudo sshd -T | grep -i forcecommand
```
Expected: user exists; sudoers shows NOPASSWD: ALL; wrapper present + executable;
audit log is append-only; ForceCommand points at the wrapper.

- [ ] **Step 4: No commit (system state only).** Note completion in the README's recovery section if anything deviated.

---

## Task 5: Provision the OWU SSH key + authorized_keys [Proxmox + steam-pc] [oliver does key-gen; claude wires authorized_keys]

- [ ] **Step 1 [oliver, on Proxmox/OWU host]: Generate a dedicated keypair**

Run:
```bash
ssh-keygen -t ed25519 -f ~/.ssh/otdebug_owu -N "" -C "owu-otdebug-bridge"
cat ~/.ssh/otdebug_owu.pub
```
Give the public-key line to the implementer (paste into chat).

- [ ] **Step 2 [claude, on steam-pc]: Install the public key for otdebug**

Run (substitute the real pubkey string):
```bash
sudo install -d -m 0700 -o otdebug -g otdebug /home/otdebug/.ssh
echo 'ssh-ed25519 AAAA...owu-otdebug-bridge' | sudo tee /home/otdebug/.ssh/authorized_keys
sudo chown otdebug:otdebug /home/otdebug/.ssh/authorized_keys
sudo chmod 0600 /home/otdebug/.ssh/authorized_keys
```
(No `command=` needed in authorized_keys — `ForceCommand` in sshd already forces the wrapper for all of otdebug's sessions.)

- [ ] **Step 3 [oliver, on Proxmox]: Connection smoke test**

Run:
```bash
ssh -i ~/.ssh/otdebug_owu otdebug@<steam-pc-tailnet-ip> 'journalctl -b 0 -n 5 --no-pager'
```
Expected: last 5 journal lines returned. Then test the gate:
```bash
ssh -i ~/.ssh/otdebug_owu otdebug@<steam-pc-tailnet-ip> 'rm -rf /etc'
```
Expected: `BLOCKED: irreversible command requires approval`.

- [ ] **Step 4 [claude, on steam-pc]: Confirm audit captured both**

Run: `sudo cat /var/log/otdebug/audit.log | tail -5`
Expected: shows the `journalctl` CMD line and the `BLOCKED` line.

---

## Task 6: Tailscale ACL containment [Tailscale console] [oliver, or claude with API token]

**Files:**
- Create: `remote-debug/tailscale-acl-stanza.hujson`

- [ ] **Step 1: Write the ACL stanza artifact**

Create `remote-debug/tailscale-acl-stanza.hujson` (merge into the tailnet policy;
adjust tags/hosts to match the real tailnet):

```hujson
// Only the OWU/Proxmox host may reach otdebug on steam-pc over SSH.
// Everything else on the tailnet is denied to steam-pc:22.
{
  "acls": [
    {
      "action": "accept",
      "src":    ["tag:owu"],          // the Proxmox host running OpenWebUI
      "dst":    ["tag:steam-pc:22"],  // steam-pc, port 22 only
    },
    // (existing ollama rule stays: tag:owu -> tag:steam-pc:11434)
  ],
}
```

- [ ] **Step 2 [oliver]: Apply via admin console or API**

Console: paste/merge into Access Controls, save. Or API:
```bash
curl -s -u "tskey-api-XXteam:" -H 'Content-Type: application/hujson' \
  -X POST "https://api.tailscale.com/api/v2/tailnet/-/acl" \
  --data-binary @<merged-policy.hujson>
```

- [ ] **Step 3: Containment verification**

From a **non-OWU** tailnet node:
```bash
ssh -i any_key otdebug@<steam-pc-tailnet-ip> true   # expect: timeout / connection refused
```
From the **OWU host**: the Task 5 smoke test still works.
From steam-pc, confirm `otdebug` has no outbound creds:
```bash
sudo ls -la /home/otdebug/.ssh   # only authorized_keys; NO private keys
```

- [ ] **Step 4: Commit the artifact**

```bash
git add remote-debug/tailscale-acl-stanza.hujson
git commit -m "remote-debug: Tailscale ACL stanza limiting otdebug:22 to the OWU host"
```

---

## Task 7: Wire the OWU SSH tool + agent prompt [OWU] [oliver]

**Files:**
- Create: `remote-debug/owu-agent-system-prompt.md`

- [ ] **Step 1 [claude]: Write the agent system prompt**

Create `remote-debug/owu-agent-system-prompt.md`. It must instruct the model to use
the SSH tool against steam-pc and to follow the systematic-debugging loop:

```markdown
You are a Linux debugging agent with shell access to the gaming PC `os93-steam-pc`
via the SSH tool. The box is a disposable CachyOS gaming node; you have root via sudo.

Method — ALWAYS follow this loop, do not skip steps:
1. Reproduce / observe: read the evidence first (`journalctl -b 0`, `systemctl status`,
   `ps`, relevant configs). Quote the actual error.
2. Hypothesize: state ONE concrete hypothesis and how you'll test it.
3. Test the hypothesis with a read-only command before changing anything.
4. Narrow: rule hypotheses in/out by evidence, not guessing.
5. Fix: prefer a shortcut in /usr/local/lib/otdebug/fixes/ if one fits; otherwise
   apply the minimal change. Explain what you're about to run and why before running it.
6. Verify: re-run the observation from step 1 and confirm the error is gone.

Rules:
- Never run a destructive/irreversible command casually; the wrapper will BLOCK them
  and that block is intentional. Ask the human to approve out-of-band.
- Every command you run is audit-logged. Be transparent: show commands and outputs.
- If the session is storming, work at the system level (`systemctl`, system journal).
```

- [ ] **Step 2 [oliver, in OWU]: Install an existing SSH tool**

In OWU → Workspace → Tools, import a community SSH command tool (e.g. the SSH
Connection Manager). Configure its valves: host = `<steam-pc-tailnet-ip>`, user =
`otdebug`, private key = contents of `~/.ssh/otdebug_owu`. **Review the tool's code
before importing** (it executes shell). Restrict tool creation to admins.

- [ ] **Step 3 [oliver, in OWU]: Create the debug model/agent**

Create a model/preset that (a) uses the SSH tool, (b) has the system prompt from
Step 1. Point it at a capable local ollama model (or an API model for hard cases).

- [ ] **Step 4: Commit the prompt artifact**

```bash
git add remote-debug/owu-agent-system-prompt.md
git commit -m "remote-debug: OWU agent system prompt (systematic-debugging loop)"
```

---

## Task 8: End-to-end acceptance [phone → OWU → steam-pc] [oliver]

- [ ] **Step 1: Healthy-session debug from the phone**

In Conduit → the debug agent: ask *"why won't Binary Domain (203750) start?"*.
Expected: agent reads the journal, reasons, proposes/runs a fix (or the
`fix-binary-domain` path), reports back. Confirm in `/var/log/otdebug/audit.log`.

- [ ] **Step 2: Storm-survival test**

On steam-pc: `sudo systemctl stop plasmalogin.service` (drops game mode). From the
phone, ask the agent to *"bring game mode back"*. Expected: agent runs
`restart-gamescope-session` (or `systemctl restart plasmalogin`) over the still-up
system sshd, session returns.

- [ ] **Step 3: Gate + containment final check**

From the phone, ask the agent to delete a system dir → expect BLOCKED in its output.
From a non-OWU device, SSH to `otdebug@steam-pc` → expect refused.

- [ ] **Step 4: Update README with the verified recipe**

Fill `remote-debug/README.md` with the exact working steps + recovery notes. Commit:
```bash
git add remote-debug/README.md
git commit -m "remote-debug: document verified end-to-end setup"
```

---

## Notes carried from spec (not built in Phase 1)

- LiteLLM multiplexer for model routing/cost (the Hermes "one model" limit).
- Egress firewall steam-pc → cluster (deferred; no-creds + ACL already cover the pivot).
- Dedicated-gaming-user refactor (deeper "games run as oliver" fix).
- A robust (non-advisory) confirm-gate would require the gate to run as an identity
  `otdebug` cannot sudo to, or human-approval on the OWU side — revisit if the
  advisory gate proves insufficient.
