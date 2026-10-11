#!/usr/bin/env bash
# Measure the comfort tunnel's DIVE and WALK profiles on a grey world; saves .spike-out/comfort_*.png.
set -uo pipefail
source "$(dirname "$0")/env.sh"
mkdir -p "$PROJ/.spike-out"
LOG="$PROJ/.spike-out/comfort_shot.log"
"$GODOT" $GODOT_FLAGS --headless --import >/dev/null 2>&1 || true
"$GODOT" $GODOT_FLAGS --rendering-method mobile --resolution 1000x1040 --position 0,0 \
	--script tools/comfort_shot.gd > "$LOG" 2>&1 &
PID=$!
( sleep 180; kill -9 "$PID" 2>/dev/null ) >/dev/null 2>&1 &
WATCHDOG=$!
trap 'set +e; kill "$WATCHDOG" 2>/dev/null; kill -9 "$PID" 2>/dev/null; true' EXIT
wait "$PID"
RC=$?
grep -a "COMFORTSHOT\|SCRIPT ERROR\|SHADER ERROR" "$LOG" || { tail -20 "$LOG"; exit 1; }
exit $RC
