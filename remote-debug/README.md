# Remote Debug Bridge

This directory implements a remote debug bridge allowing oliver to debug and fix `os93-steam-pc` live from his phone via OpenWebUI. See the full spec and design at `docs/superpowers/specs/2026-06-05-gaming-debug-bridge-design.md`.

The bridge works by providing a dedicated `otdebug` SSH user whose shell is forced through `debug-shell-wrap.sh` — an append-only auditing layer with an advisory gate that blocks irreversible commands unless explicitly approved. The user has `NOPASSWD: ALL` sudo for full root access to the (disposable) gaming box.

## Layout

| File | Purpose |
|------|---------|
| `debug-shell-wrap.sh` | `ForceCommand` wrapper: audit log + advisory irreversible gate + passthrough |
| `irreversible-patterns.txt` | Extended-regex patterns the gate blocks (one per line) |
| `sshd-otdebug.conf` | `sshd_config.d` drop-in: key-only auth + ForceCommand for `otdebug` |
| `sudoers-otdebug` | `/etc/sudoers.d` drop-in: `NOPASSWD: ALL` for `otdebug` |
| `install-debug-bridge.sh` | Idempotent root installer: creates user, deploys files, sets up audit log |
| `fixes/` | Quick-fix scripts (each supports `--dry-run`) |
| `tests/` | Bash unit tests for the wrapper |

## Recovery Notes

**Always keep a second root shell open on steam-pc** during any install/sshd/sudoers work.

Before reloading sshd: `sshd -t` must pass cleanly.

Before installing sudoers: `visudo -cf <file>` must pass cleanly.

The audit log lives at `/var/log/otdebug/audit.log` and is set `chattr +a` (append-only) so commands cannot be silently erased — even by root.

If SSH config breaks and you are locked out, use the standing root shell or physical/console access to revert `/etc/ssh/sshd_config.d/60-otdebug.conf`.
