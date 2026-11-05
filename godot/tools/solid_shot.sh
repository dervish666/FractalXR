#!/usr/bin/env bash
# Render the SOLID mesh spike harness; shots in .spike-out/solid/.
set -euo pipefail
source "$(dirname "$0")/env.sh"
mkdir -p "$PROJ/.spike-out"
"$GODOT" $GODOT_FLAGS --headless --import >/dev/null 2>&1 || true
"$GODOT" $GODOT_FLAGS --rendering-method mobile ${SOLID_DRIVER:+--rendering-driver $SOLID_DRIVER} --resolution 1280x800 --position 0,0 \
	--script tools/solid_shot.gd "$@" > "$PROJ/.spike-out/solid_shot.log" 2>&1 &
PID=$!
# Own only this child. pkill -f on the project path would take out any other run in flight.
( sleep 900; kill -9 "$PID" 2>/dev/null ) >/dev/null 2>&1 &
WATCHDOG=$!
trap 'set +e; kill "$WATCHDOG" 2>/dev/null; kill -9 "$PID" 2>/dev/null; true' EXIT
RC=0
wait "$PID" || RC=$?
kill "$WATCHDOG" 2>/dev/null; wait "$WATCHDOG" 2>/dev/null || true
grep -a "SOLIDSHOT\|SOLIDROW\|\[solid\]\|SCRIPT ERROR\|SHADER ERROR\|Parse Error" "$PROJ/.spike-out/solid_shot.log" || { tail -20 "$PROJ/.spike-out/solid_shot.log"; exit 1; }
exit $RC
