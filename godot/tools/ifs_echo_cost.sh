#!/usr/bin/env bash
# GPU time, draw calls and primitives per ECHOES rung, through main.tscn on this Mac.
# Ratios between rungs, not Quest milliseconds. Nonzero exit if the run never finishes.
set -uo pipefail
source "$(dirname "$0")/env.sh"
mkdir -p "$PROJ/.spike-out"
LOG="$PROJ/.spike-out/ifs_echo_cost.log"
"$GODOT" $GODOT_FLAGS --headless --import >/dev/null 2>&1 || true
"$GODOT" $GODOT_FLAGS --rendering-method mobile --resolution 1280x800 --position 0,0 \
	--script tools/ifs_echo_cost.gd > "$LOG" 2>&1 &
PID=$!
( sleep 300; kill -9 "$PID" 2>/dev/null ) >/dev/null 2>&1 &
WATCHDOG=$!
trap 'kill "$WATCHDOG" 2>/dev/null; kill -9 "$PID" 2>/dev/null' EXIT
wait "$PID"
grep -a "IFSCOST\|SCRIPT ERROR\|Parse Error" "$LOG"
grep -q "IFSCOST DONE" "$LOG"
