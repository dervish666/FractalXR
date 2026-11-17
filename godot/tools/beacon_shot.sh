#!/usr/bin/env bash
# BEACONS and TOUR on the Mandelbrot ground. PNGs in .spike-out/beacon/.
set -euo pipefail
source "$(dirname "$0")/env.sh"
mkdir -p "$PROJ/.spike-out/beacon"
LOG="$PROJ/.spike-out/beacon/beacon_shot.log"
"$GODOT" $GODOT_FLAGS --headless --import >/dev/null 2>&1 || true
"$GODOT" $GODOT_FLAGS --rendering-method mobile --resolution 1280x800 --position 0,0 \
	--script tools/beacon_shot.gd > "$LOG" 2>&1 &
PID=$!
# Own only this child. pkill -f on the project path would take out any other run in flight.
( sleep 900; kill -9 "$PID" 2>/dev/null ) >/dev/null 2>&1 &
WATCHDOG=$!
trap 'set +e; kill "$WATCHDOG" 2>/dev/null; kill -9 "$PID" 2>/dev/null; true' EXIT
RC=0
wait "$PID" || RC=$?
kill "$WATCHDOG" 2>/dev/null; wait "$WATCHDOG" 2>/dev/null || true
grep -a "BEACON\|SCRIPT ERROR\|SHADER ERROR\|Parse Error" "$LOG" || { tail -20 "$LOG"; exit 1; }
exit $RC
