#!/usr/bin/env bash
# Displaced ground under head turns: tools/ground_turn.gd through the real main scene.
# Nonzero exit on a failed check, a parse or shader error, or the watchdog firing.
set -uo pipefail
source "$(dirname "$0")/env.sh"
mkdir -p "$PROJ/.spike-out"
LOG="$PROJ/.spike-out/ground_turn.log"
"$GODOT" $GODOT_FLAGS --headless --import >/dev/null 2>&1 || true
# Fixed frame rate, so the reference's lag runs on the same clock every time.
"$GODOT" $GODOT_FLAGS --rendering-method mobile --resolution 960x600 --position 0,0 \
	--fixed-fps 30 --script tools/ground_turn.gd > "$LOG" 2>&1 &
PID=$!
# Own only this child. pkill -f on the project path would take out any other run in flight.
( sleep 600; kill -9 "$PID" 2>/dev/null ) &
WATCHDOG=$!
wait "$PID"
RC=$?
kill "$WATCHDOG" 2>/dev/null; wait "$WATCHDOG" 2>/dev/null || true
grep -a "GROUNDTURN\|^  \|SCRIPT ERROR\|SHADER ERROR\|Parse Error" "$LOG" || { tail -20 "$LOG"; exit 1; }
exit $RC
