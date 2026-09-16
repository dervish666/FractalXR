#!/usr/bin/env bash
# IFS mode through the real main scene: capture plus the mode-pair and input assertions.
# Nonzero exit on a failed assertion, a parse error, a missing PNG or the watchdog firing.
set -uo pipefail
source "$(dirname "$0")/env.sh"
OUT="$PROJ/.spike-out/ifs-2026-09-16"
LOG="$OUT/ifs_mode_shot.log"
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
	--script tools/ifs_mode_shot.gd >> "$LOG" 2>&1 &
PID=$!
# Own only this child. pkill -f on the project path would take out any other run in flight.
( sleep 420; kill -9 "$PID" 2>/dev/null ) >/dev/null 2>&1 &
WATCHDOG=$!
trap 'kill "$WATCHDOG" 2>/dev/null; kill -9 "$PID" 2>/dev/null' EXIT
wait "$PID"
RC=$?
kill "$WATCHDOG" 2>/dev/null; wait "$WATCHDOG" 2>/dev/null || true
grep -a "IFSMODE\|SCRIPT ERROR\|SHADER ERROR\|Parse Error" "$LOG" || { tail -30 "$LOG"; exit 1; }
for png in mode-ifs.png mode-ifs-reset.png sculpt-guides.png sculpt-drag.png sculpt-undo.png; do
	[ -s "$OUT/$png" ] || { echo "IFSMODE FAIL missing $OUT/$png"; exit 1; }
done
exit $RC
