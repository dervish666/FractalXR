#!/usr/bin/env bash
# IFS mode through the real main scene: capture plus the mode-pair and input assertions.
# Nonzero exit on a failed assertion, a parse error, a missing PNG or the watchdog firing.
set -uo pipefail
source "$(dirname "$0")/env.sh"
OUT="$PROJ/.spike-out/ifs-2026-09-16"
LOG="$OUT/ifs_mode_shot.log"
mkdir -p "$OUT"
STAMP="$OUT/.run-stamp"
touch "$STAMP"
{
	echo "revision: $(git -C "$PROJ" rev-parse --short HEAD 2>/dev/null || echo unknown)"
	echo "dirty:    $(git -C "$PROJ" status --porcelain | wc -l | tr -d ' ') files"
	echo "godot:    $("$GODOT" --version 2>/dev/null | tail -1)"
	echo "renderer: mobile, 1280x800, main.tscn, no XR"
	echo
} > "$LOG"
"$GODOT" $GODOT_FLAGS --headless --import >/dev/null 2>&1 || true
"$GODOT" $GODOT_FLAGS --rendering-method mobile --resolution 1280x800 --position 0,0 \
	--script tools/ifs_mode_shot.gd >> "$LOG" 2>&1 &
PID=$!
# Own only this child. pkill -f on the project path would take out any other run in flight.
( sleep 420; kill -9 "$PID" 2>/dev/null ) >/dev/null 2>&1 &
WATCHDOG=$!
trap 'set +e; kill "$WATCHDOG" 2>/dev/null; kill -9 "$PID" 2>/dev/null; true' EXIT
wait "$PID"
RC=$?
kill "$WATCHDOG" 2>/dev/null; wait "$WATCHDOG" 2>/dev/null || true
grep -a "IFSMODE\|SCRIPT ERROR\|SHADER ERROR\|Parse Error" "$LOG" || { tail -30 "$LOG"; exit 1; }
# A script error aborts the coroutine it hits, and the checks after it never run, so the
# summary can still say PASS. Any error fails the run.
if grep -aq "SCRIPT ERROR\|SHADER ERROR\|Parse Error" "$LOG"; then
	echo "IFSMODE FAIL errors in $LOG"
	exit 1
fi
# Every capture must be from this run: one per preset (the .gd lists them as it shoots), plus
# the fixed shots, each newer than the log's start.
SHAPES=$(grep -ao "shape-[a-z]*\.png" "$LOG" | sort -u)
[ "$(echo "$SHAPES" | wc -l | tr -d ' ')" -ge 12 ] || { echo "IFSMODE FAIL only $(echo "$SHAPES" | wc -l | tr -d ' ') shape shots"; exit 1; }
for png in mode-ifs.png mode-ifs-reset.png sculpt-guides.png sculpt-drag.png sculpt-undo.png \
	mode-ifs-motion.png $SHAPES; do
	[ -s "$OUT/$png" ] && [ "$OUT/$png" -nt "$STAMP" ] || { echo "IFSMODE FAIL missing or stale $OUT/$png"; exit 1; }
done
exit $RC
