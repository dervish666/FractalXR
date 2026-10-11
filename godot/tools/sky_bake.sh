#!/usr/bin/env bash
# SKY bakes through the real main scene (tools/sky_bake.gd has the detail):
#   tools/sky_bake.sh measure [2560,4096,6144] [Ember]   live bake cost per SKY RES
#   tools/sky_bake.sh bake Vortex,Glacier [8192] [48]     offline bakes to .spike-out/skies/
# then tools/sky_cube.py turns the offline bakes into the art/skies/ presets.
set -uo pipefail
source "$(dirname "$0")/env.sh"
mkdir -p "$PROJ/.spike-out/skies"
LOG="$PROJ/.spike-out/sky_bake.log"
"$GODOT" $GODOT_FLAGS --headless --import >/dev/null 2>&1 || true
# Vulkan (MoltenVK), not Metal: on Metal the RenderingDevice timestamps report nothing on this
# Mac, and the bake's GPU time is half of what this measures.
"$GODOT" $GODOT_FLAGS --rendering-driver vulkan --rendering-method mobile --resolution 1280x800 --position 0,0 \
	--script tools/sky_bake.gd -- "$@" > "$LOG" 2>&1 &
PID=$!
( sleep 1800; kill -9 "$PID" 2>/dev/null ) >/dev/null 2>&1 &
WATCHDOG=$!
trap 'set +e; kill "$WATCHDOG" 2>/dev/null; kill -9 "$PID" 2>/dev/null; true' EXIT
wait "$PID"
grep -a "SKYBAKE\|SCRIPT ERROR\|SHADER ERROR\|Parse Error" "$LOG"
grep -q "SKYBAKE DONE PASS" "$LOG"
