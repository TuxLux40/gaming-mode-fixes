#!/usr/bin/env bash
# patch-trcc-daemon.sh — fix trccd.service not starting the metrics loop
#
# Root cause: trcc daemon (trccd.service) discovers devices but never calls
# start_metrics_loop(). That 50ms tick thread is what reads CPU/GPU temps and
# sends them to the AX120R Digital segment display. Without it the device is
# connected but shows nothing.
#
# This is unfixed in trcc-linux through at least v9.5.11. Re-run after upgrades.
#
# NOTE: If you followed the setup guide and switched to the user service
# (trcc.service), you do NOT need this script. It's only needed if you're
# using trccd.service (the system daemon).
#
# Usage: sudo bash patch-trcc-daemon.sh

set -euo pipefail

DAEMON=$(python3 -c "import importlib.util; print(importlib.util.find_spec('trcc.daemon').origin)")
echo "Patching: $DAEMON"

cp "$DAEMON" "$DAEMON.bak"

python3 - <<'PYEOF'
import sys, pathlib, importlib.util

spec = importlib.util.find_spec('trcc.daemon')
p = pathlib.Path(spec.origin)
txt = p.read_text()

old = '    trcc = _build_trcc()\n\n    server = IPCServer'
new = '    trcc = _build_trcc()\n    trcc.start_metrics_loop()\n\n    server = IPCServer'

if new in txt:
    print("Already patched — nothing to do.")
    sys.exit(0)

if old not in txt:
    print("ERROR: expected pattern not found. daemon.py layout may have changed.")
    print("Search manually for '_build_trcc()' and add 'trcc.start_metrics_loop()' after it.")
    sys.exit(1)

p.write_text(txt.replace(old, new, 1))
print("Patched OK — added trcc.start_metrics_loop() after _build_trcc()")
PYEOF

systemctl restart trccd.service
echo "trccd.service restarted"

sleep 2
echo ""
echo "--- Last 5 log lines ---"
journalctl -u trccd.service -n 5 --no-pager
echo ""
echo "Check ~/.trcc/trcc.log for 'Frame sent: LED' to confirm the loop is running."
