#!/usr/bin/env bash
# Standalone FractalIFS captures into .spike-out/ifs-<date>/. Nonzero exit on a failed
# capture, a parse error, a missing PNG or the watchdog firing.
set -uo pipefail
source "$(dirname "$0")/env.sh"
OUT="$PROJ/.spike-out/ifs-2026-09-16"
LOG="$OUT/ifs_shot.log"
mkdir -p "$OUT"
{
	echo "revision: $(git -C "$PROJ" rev-parse --short HEAD 2>/dev/null || echo unknown)"
	echo "dirty:    $(git -C "$PROJ" status --porcelain | wc -l | tr -d ' ') files"
	echo "godot:    $("$GODOT" --version 2>/dev/null | tail -1)"
	echo "renderer: mobile, 1280x800, unshaded StandardMaterial3D, no XR"
	echo
} > "$LOG"
"$GODOT" $GODOT_FLAGS --headless --import >/dev/null 2>&1 || true
"$GODOT" $GODOT_FLAGS --rendering-method mobile --resolution 1280x800 --position 0,0 \
	--script tools/ifs_shot.gd >> "$LOG" 2>&1 &
PID=$!
# Own only this child. pkill -f on the project path would take out any other run in flight.
( sleep 300; kill -9 "$PID" 2>/dev/null ) >/dev/null 2>&1 &
WATCHDOG=$!
trap 'kill "$WATCHDOG" 2>/dev/null; kill -9 "$PID" 2>/dev/null' EXIT
wait "$PID"
RC=$?
kill "$WATCHDOG" 2>/dev/null; wait "$WATCHDOG" 2>/dev/null || true
grep -a "IFSSHOT\|SCRIPT ERROR\|SHADER ERROR\|Parse Error" "$LOG" || { tail -20 "$LOG"; exit 1; }
# Count only this tool's own captures. ifs_mode_shot.sh writes mode-*.png and sculpt-*.png
# into the same directory, and a floor that another tool can top up is not a floor.
PNGS=$(find "$OUT" -maxdepth 1 -name '*.png' ! -name 'mode-*.png' ! -name 'sculpt-*.png' | wc -l | tr -d ' ')
echo "IFSSHOT pngs=$PNGS in $OUT"
[ "$PNGS" -ge 29 ] || { echo "IFSSHOT FAIL expected 29 PNGs, found $PNGS"; exit 1; }
exit $RC
