#!/usr/bin/env bash
# FLOOR and BARK through the real main scene: shots and GPU time per configuration on this Mac.
# Ratios, not Quest milliseconds. Nonzero exit if the run never finishes.
set -uo pipefail
source "$(dirname "$0")/env.sh"
mkdir -p "$PROJ/.spike-out"
LOG="$PROJ/.spike-out/look.log"
"$GODOT" $GODOT_FLAGS --headless --import >/dev/null 2>&1 || true
# Vulkan (MoltenVK), not the default Metal: on Metal the viewport's GPU timer reads nothing here.
"$GODOT" $GODOT_FLAGS --rendering-driver vulkan --rendering-method mobile --resolution 1280x800 --position 0,0 \
	--script tools/tree_look_shot.gd > "$LOG" 2>&1 &
PID=$!
( sleep 600; kill -9 "$PID" 2>/dev/null ) >/dev/null 2>&1 &
WATCHDOG=$!
trap 'set +e; kill "$WATCHDOG" 2>/dev/null; kill -9 "$PID" 2>/dev/null; true' EXIT
wait "$PID"
grep -a "LOOKSHOT\|SCRIPT ERROR\|SHADER ERROR" "$LOG"
grep -q "LOOKSHOT DONE" "$LOG"
