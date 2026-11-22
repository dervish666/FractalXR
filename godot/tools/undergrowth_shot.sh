#!/usr/bin/env bash
# Render, verify and time TREE's fractal undergrowth (grove, avenue, walk, far tier, clear, mode switch).
set -euo pipefail
source "$(dirname "$0")/env.sh"
mkdir -p "$PROJ/.spike-out"
LOG="$PROJ/.spike-out/undergrowth_shot.log"
"$GODOT" $GODOT_FLAGS --headless --import >/dev/null 2>&1 || true
# Vulkan (MoltenVK), not the default Metal: on Metal the viewport's GPU timer reads nothing here.
"$GODOT" $GODOT_FLAGS --rendering-driver vulkan --rendering-method mobile --resolution 1280x800 --position 0,0 \
	--script tools/undergrowth_shot.gd > "$LOG" 2>&1 &
PID=$!
# Own only this child. pkill -f on the project path would take out any other run in flight.
( sleep 420; kill -9 "$PID" 2>/dev/null ) >/dev/null 2>&1 &
WATCHDOG=$!
trap 'set +e; kill "$WATCHDOG" 2>/dev/null; kill -9 "$PID" 2>/dev/null; true' EXIT
RC=0
wait "$PID" || RC=$?
kill "$WATCHDOG" 2>/dev/null; wait "$WATCHDOG" 2>/dev/null || true
grep -a "UGSHOT\|SCRIPT ERROR\|SHADER ERROR\|Parse Error" "$LOG" || { tail -20 "$LOG"; exit 1; }
exit $RC
