#!/usr/bin/env bash
# Stale texels on screen while the clipmap refills: tools/ground_fill.gd through the real
# main scene. CONTROL=1 runs the probe blind and must report no red.
# Nonzero exit on a failed check, a parse or shader error, or the watchdog firing.
set -uo pipefail
source "$(dirname "$0")/env.sh"
mkdir -p "$PROJ/.spike-out"
LOG="$PROJ/.spike-out/ground_fill${CONTROL:+_control}.log"
"$GODOT" $GODOT_FLAGS --headless --import >/dev/null 2>&1 || true
# Vulkan (MoltenVK) for real GPU timestamps, so the fill budget adapts as on the Quest.
# Fixed 72 fps, the Quest's rate, so motion per frame matches the headset.
"$GODOT" $GODOT_FLAGS --rendering-driver "${GROUND_DRIVER:-vulkan}" --rendering-method mobile \
	--resolution 960x600 --position 0,0 --fixed-fps 72 --script tools/ground_fill.gd > "$LOG" 2>&1 &
PID=$!
# Own only this child. pkill -f on the project path would take out any other run in flight.
( sleep 1500; kill -9 "$PID" 2>/dev/null ) >/dev/null 2>&1 &
WATCHDOG=$!
wait "$PID"
RC=$?
kill "$WATCHDOG" 2>/dev/null; wait "$WATCHDOG" 2>/dev/null || true
grep -a "GROUNDFILL\|^  \|SCRIPT ERROR\|SHADER ERROR\|Parse Error" "$LOG" || { tail -20 "$LOG"; exit 1; }
exit $RC
