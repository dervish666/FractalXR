#!/usr/bin/env bash
# Render the wrist menu to .spike-out/menu_*.png. Imports first, for the same reason
# selftest.sh does: a --script run does not rescan the filesystem.
set -euo pipefail
source "$(dirname "$0")/env.sh"
mkdir -p "$PROJ/.spike-out"
"$GODOT" $GODOT_FLAGS --headless --import >/dev/null 2>&1 || true
( sleep 240; pkill -9 -f "Godot --xr-mode off --path $PROJ" 2>/dev/null ) &
WATCHDOG=$!
"$GODOT" $GODOT_FLAGS --rendering-method mobile --resolution 320x240 --position 0,0 \
	--script tools/menu_shot.gd > "$PROJ/.spike-out/menu_shot.log" 2>&1
RC=$?
kill $WATCHDOG 2>/dev/null; wait $WATCHDOG 2>/dev/null || true
grep -a "MENUSHOT\|SCRIPT ERROR\|Parse Error\|ERROR\|WARNING" "$PROJ/.spike-out/menu_shot.log" | grep -v "OpenXR\|xr-mode\|XR" || { tail -20 "$PROJ/.spike-out/menu_shot.log"; exit 1; }
exit $RC
