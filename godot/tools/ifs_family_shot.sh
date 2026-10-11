#!/usr/bin/env bash
# FAMILY, room size and DIVE through the real main scene, captures into
# .spike-out/ifs-family-<date>/. Nonzero exit on a failed check, a parse or shader error, a
# missing PNG or the watchdog firing.
set -uo pipefail
source "$(dirname "$0")/env.sh"
OUT="$PROJ/.spike-out/ifs-family-2026-10-10"
LOG="$OUT/ifs_family_shot.log"
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
	--script tools/ifs_family_shot.gd >> "$LOG" 2>&1 &
PID=$!
# Own only this child. pkill -f on the project path would take out any other run in flight.
( sleep 300; kill -9 "$PID" 2>/dev/null ) >/dev/null 2>&1 &
WATCHDOG=$!
trap 'set +e; kill "$WATCHDOG" 2>/dev/null; kill -9 "$PID" 2>/dev/null; true' EXIT
wait "$PID"
RC=$?
kill "$WATCHDOG" 2>/dev/null; wait "$WATCHDOG" 2>/dev/null || true
grep -a "IFSFAMILY\|SCRIPT ERROR\|SHADER ERROR\|Parse Error" "$LOG" || { tail -20 "$LOG"; exit 1; }
grep -aq "SHADER ERROR\|SCRIPT ERROR" "$LOG" && RC=1
for png in table-scatter.png table-family.png table-family-up.png table-family-left.png \
		room-family.png room-family-up.png room-family-left.png room-scatter.png \
		dive-0.png dive-25.png dive-60.png dive-pre-snap.png dive-snap.png dive-landed.png \
		dive-2-50.png room-dive-50.png; do
	[ -s "$OUT/$png" ] || { echo "IFSFAMILY FAIL missing $OUT/$png"; exit 1; }
done
exit $RC
