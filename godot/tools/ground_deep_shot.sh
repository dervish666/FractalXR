#!/usr/bin/env bash
# Deep-zoom captures and fill cost: tools/ground_deep_shot.gd through the real main scene.
# Nonzero exit on a failed check, a parse or shader error, or the watchdog firing.
set -uo pipefail
source "$(dirname "$0")/env.sh"
mkdir -p "$PROJ/.spike-out"
LOG="$PROJ/.spike-out/ground_deep_shot.log"
"$GODOT" $GODOT_FLAGS --headless --import >/dev/null 2>&1 || true
# Vulkan (MoltenVK), not the Mac's default Metal: Metal returns no GPU timestamps, so
# ground_us reads 0 there and the fill cost would be a silent zero.
"$GODOT" $GODOT_FLAGS --rendering-driver "${GROUND_DRIVER:-vulkan}" --rendering-method mobile --resolution 1280x800 --position 0,0 \
	--script tools/ground_deep_shot.gd -- "$@" > "$LOG" 2>&1 &
PID=$!
# Own only this child. pkill -f on the project path would take out any other run in flight.
( sleep 900; kill -9 "$PID" 2>/dev/null ) >/dev/null 2>&1 &
WATCHDOG=$!
wait "$PID"
RC=$?
kill "$WATCHDOG" 2>/dev/null; wait "$WATCHDOG" 2>/dev/null || true
grep -a "GROUNDDEEP\|^  \|SCRIPT ERROR\|SHADER ERROR\|Parse Error" "$LOG" || { tail -20 "$LOG"; exit 1; }
exit $RC
