#!/usr/bin/env bash
# main.gd's logic through the real scene: resume parsing, the splat guard, drift stride, snap turns,
# IFS RESET then UNDO. See tools/logic_check.gd. Windowed, because main.tscn needs a RenderingDevice.
set -uo pipefail
source "$(dirname "$0")/env.sh"
mkdir -p "$PROJ/.spike-out"
LOG="$PROJ/.spike-out/logic_check.log"
# A --script run does not rescan; import first so it runs the scripts on disk.
"$GODOT" $GODOT_FLAGS --headless --import >/dev/null 2>&1 || true
"$GODOT" $GODOT_FLAGS --rendering-method mobile --resolution 320x240 --position 0,0 \
	--script tools/logic_check.gd > "$LOG" 2>&1 &
PID=$!
# Own only this child. pkill -f on the project path would take out any other run in flight.
( sleep 240; kill -9 "$PID" 2>/dev/null ) >/dev/null 2>&1 &
WATCHDOG=$!
trap 'set +e; kill "$WATCHDOG" 2>/dev/null; kill -9 "$PID" 2>/dev/null; true' EXIT
wait "$PID"
RC=$?
kill "$WATCHDOG" 2>/dev/null; wait "$WATCHDOG" 2>/dev/null || true
grep -a "LOGICCHECK\|SCRIPT ERROR\|Parse Error" "$LOG" || { tail -30 "$LOG"; exit 1; }
# A SCRIPT ERROR does not stop the run, so it would otherwise ride along under a PASS.
if grep -aq "SCRIPT ERROR\|Parse Error" "$LOG"; then exit 1; fi
grep -aq "^LOGICCHECK PASS" "$LOG" || exit 1
exit $RC
