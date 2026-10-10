#!/usr/bin/env bash
# GPU time, draw calls and primitives for GALAXY, ECHOES and the flame SKY, through main.tscn on
# this Mac. Ratios, not Quest milliseconds. Nonzero exit if the run never finishes.
set -uo pipefail
source "$(dirname "$0")/env.sh"
mkdir -p "$PROJ/.spike-out"
LOG="$PROJ/.spike-out/flame_scale_cost.log"
"$GODOT" $GODOT_FLAGS --headless --import >/dev/null 2>&1 || true
# Vulkan (MoltenVK), not the default Metal: on Metal neither the viewport's GPU timer nor the
# RenderingDevice timestamps report anything on this Mac, and every GPU column reads unavailable.
"$GODOT" $GODOT_FLAGS --rendering-driver vulkan --rendering-method mobile --resolution 1280x800 --position 0,0 \
	--script tools/flame_scale_cost.gd > "$LOG" 2>&1 &
PID=$!
( sleep 420; kill -9 "$PID" 2>/dev/null ) >/dev/null 2>&1 &
WATCHDOG=$!
trap 'set +e; kill "$WATCHDOG" 2>/dev/null; kill -9 "$PID" 2>/dev/null; true' EXIT
wait "$PID"
grep -a "FLAMECOST\|SCRIPT ERROR\|SHADER ERROR" "$LOG"
grep -q "FLAMECOST DONE" "$LOG"
