#!/usr/bin/env bash
# LINES vs splats: PNGs at three views, Mac GPU and sim ms, and particle dumps for
# tools/line_check.py, all to .spike-out/lines/. Ratios between modes, not Quest ms.
#   tools/line_shot.sh [Classic,Citadel] [0,24,48,96]
set -uo pipefail
source "$(dirname "$0")/env.sh"
mkdir -p "$PROJ/.spike-out/lines"
LOG="$PROJ/.spike-out/line_shot.log"
"$GODOT" $GODOT_FLAGS --headless --import >/dev/null 2>&1 || true
# Vulkan (MoltenVK), not Metal: on Metal neither the viewport GPU timer nor the
# RenderingDevice timestamps report anything on this Mac (see flame_scale_cost.sh).
"$GODOT" $GODOT_FLAGS --rendering-driver vulkan --rendering-method mobile --resolution 1280x800 --position 0,0 \
	--script tools/line_shot.gd -- "$@" > "$LOG" 2>&1 &
PID=$!
( sleep 900; kill -9 "$PID" 2>/dev/null ) >/dev/null 2>&1 &
WATCHDOG=$!
trap 'set +e; kill "$WATCHDOG" 2>/dev/null; kill -9 "$PID" 2>/dev/null; true' EXIT
wait "$PID"
grep -a "LINESHOT\|SCRIPT ERROR\|SHADER ERROR\|Parse Error" "$LOG"
grep -q "LINESHOT DONE PASS" "$LOG"
