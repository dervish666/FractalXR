#!/usr/bin/env bash
# Press every wrist-menu tile in every mode and record what it changed:
# .spike-out/menu_audit.log, one "AUDIT ROW" line per tile per state. Light: 640x400, no timings.
# Imports first, as selftest.sh does: a --script run does not rescan the filesystem.
set -euo pipefail
source "$(dirname "$0")/env.sh"
mkdir -p "$PROJ/.spike-out"
"$GODOT" $GODOT_FLAGS --headless --import >/dev/null 2>&1 || true
"$GODOT" $GODOT_FLAGS --rendering-method mobile --resolution 640x400 --position 0,0 \
	--script tools/menu_audit.gd > "$PROJ/.spike-out/menu_audit.log" 2>&1 &
PID=$!
# Own only this child. pkill -f on the project path would take out any other run in flight.
( sleep 3000; kill -9 "$PID" 2>/dev/null ) >/dev/null 2>&1 &
WATCHDOG=$!
trap 'set +e; kill "$WATCHDOG" 2>/dev/null; kill -9 "$PID" 2>/dev/null; true' EXIT
RC=0
wait "$PID" || RC=$?
kill "$WATCHDOG" 2>/dev/null; wait "$WATCHDOG" 2>/dev/null || true
grep -a "AUDIT DONE\|AUDIT STATE\|SCRIPT ERROR\|Parse Error" "$PROJ/.spike-out/menu_audit.log" || { tail -20 "$PROJ/.spike-out/menu_audit.log"; exit 1; }
exit $RC
