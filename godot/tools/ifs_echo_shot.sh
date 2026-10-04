#!/usr/bin/env bash
# ECHOES through the real main scene, captures into .spike-out/ifs-echoes-<date>/. Nonzero exit on a failed
# capture, a parse error, a missing PNG or the watchdog firing.
set -uo pipefail
source "$(dirname "$0")/env.sh"
OUT="$PROJ/.spike-out/ifs-echoes-2026-10-04"
LOG="$OUT/ifs_echo_shot.log"
mkdir -p "$OUT"
{
	echo "revision: $(git -C "$PROJ" rev-parse --short HEAD 2>/dev/null || echo unknown)"
	echo "dirty:    $(git -C "$PROJ" status --porcelain | wc -l | tr -d ' ') files"
	echo "godot:    $("$GODOT" --version 2>/dev/null | tail -1)"
	echo "renderer: mobile, 1280x800, main.tscn, no XR"
	echo
} > "$LOG"
"$GODOT" $GODOT_FLAGS --headless --import >/dev/null 2>&1 || true
"$GODOT" $GODOT_FLAGS --rendering-method mobile --resolution 1280x800 --position 0,0 \
	--script tools/ifs_echo_shot.gd >> "$LOG" 2>&1 &
PID=$!
# Own only this child. pkill -f on the project path would take out any other run in flight.
( sleep 240; kill -9 "$PID" 2>/dev/null ) >/dev/null 2>&1 &
WATCHDOG=$!
trap 'set +e; kill "$WATCHDOG" 2>/dev/null; kill -9 "$PID" 2>/dev/null; true' EXIT
wait "$PID"
RC=$?
kill "$WATCHDOG" 2>/dev/null; wait "$WATCHDOG" 2>/dev/null || true
grep -a "IFSECHO\|SCRIPT ERROR\|SHADER ERROR\|Parse Error" "$LOG" || { tail -20 "$LOG"; exit 1; }
for png in echoes-few.png echoes-many.png echoes-lots.png echoes-host.png echoes-off.png echoes-host-up.png echoes-off-up.png life-plain.png life-zeroed.png life-t600.png echoes-lots-left-up.png echoes-lots-right.png; do
	[ -s "$OUT/$png" ] || { echo "IFSECHO FAIL missing $OUT/$png"; exit 1; }
done
exit $RC
