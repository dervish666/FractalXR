#!/usr/bin/env bash
# Render the ground mode on the desktop to .spike-out/ground.png.
set -euo pipefail
source "$(dirname "$0")/env.sh"
mkdir -p "$PROJ/.spike-out"
"$GODOT" $GODOT_FLAGS --headless --import >/dev/null 2>&1 || true
( sleep 600; pkill -9 -f "Godot --xr-mode off --path $PROJ" 2>/dev/null ) &
WATCHDOG=$!
# Under set -e a failing Godot run skips the kill below, and four minutes later the
# orphaned watchdog pkills whatever run of this project is in flight. The trap fires
# on every exit path.
trap 'kill $WATCHDOG 2>/dev/null' EXIT
"$GODOT" $GODOT_FLAGS --rendering-method mobile --resolution 1280x800 --position 0,0 \
	--script tools/ground_shot.gd > "$PROJ/.spike-out/ground_shot.log" 2>&1
RC=$?
kill $WATCHDOG 2>/dev/null; wait $WATCHDOG 2>/dev/null || true
grep -a "GROUNDSHOT\|SCRIPT ERROR\|SHADER ERROR\|Parse Error" "$PROJ/.spike-out/ground_shot.log" || { tail -20 "$PROJ/.spike-out/ground_shot.log"; exit 1; }
exit $RC
