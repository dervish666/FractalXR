#!/usr/bin/env bash
# Render and validate a small planted forest through the real main scene.
set -euo pipefail
source "$(dirname "$0")/env.sh"
mkdir -p "$PROJ/.spike-out"
"$GODOT" $GODOT_FLAGS --headless --import >/dev/null 2>&1 || true
( sleep 240; pkill -9 -f "Godot --xr-mode off --path $PROJ" 2>/dev/null ) &
WATCHDOG=$!
trap 'kill $WATCHDOG 2>/dev/null' EXIT
"$GODOT" $GODOT_FLAGS --rendering-method mobile --resolution 1280x800 --position 0,0 \
	--script tools/forest_shot.gd > "$PROJ/.spike-out/forest_shot.log" 2>&1
RC=$?
kill $WATCHDOG 2>/dev/null; wait $WATCHDOG 2>/dev/null || true
grep -a "FORESTSHOT\|SCRIPT ERROR\|SHADER ERROR\|Parse Error" "$PROJ/.spike-out/forest_shot.log" \
	|| { tail -20 "$PROJ/.spike-out/forest_shot.log"; exit 1; }
exit $RC
