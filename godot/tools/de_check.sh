#!/usr/bin/env bash
# CPU-vs-shader distance estimate check and the hollow finder. Needs a window (renders
# a 64x1 viewport), so it runs like the shot harnesses.
set -uo pipefail
source "$(dirname "$0")/env.sh"
"$GODOT" $GODOT_FLAGS --headless --import >/dev/null 2>&1 || true
"$GODOT" $GODOT_FLAGS --rendering-method mobile --resolution 320x200 --position 0,0 \
	--script tools/de_check.gd > "$PROJ/.spike-out/de_check.log" 2>&1 &
PID=$!
# Own only this child. pkill -f on the project path would take out any other run in flight.
( sleep 180; kill -9 "$PID" 2>/dev/null ) >/dev/null 2>&1 &
WATCHDOG=$!
trap 'set +e; kill "$WATCHDOG" 2>/dev/null; kill -9 "$PID" 2>/dev/null; true' EXIT
RC=0
wait "$PID" || RC=$?
kill "$WATCHDOG" 2>/dev/null; wait "$WATCHDOG" 2>/dev/null || true
grep -a "DECHECK\|HOLLOW\|  \|SCRIPT ERROR\|Parse Error\|SHADER ERROR" "$PROJ/.spike-out/de_check.log" | grep -av "^\s*$" | head -30
exit $RC
