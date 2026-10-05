#!/usr/bin/env bash
# Bake the wrist menu's gallery pictures to art/thumbs/thumbs.png + thumbs.json, through the
# real main scene. Re-run after changing presets, bulbs, ground families, tree species or IFS
# shapes, then commit both files (and the .import Godot writes next to the PNG).
# Raw frames land in .spike-out/thumbs/ for checking the framing.
# Imports first, as selftest.sh does: a --script run does not rescan the filesystem.
set -euo pipefail
source "$(dirname "$0")/env.sh"
mkdir -p "$PROJ/.spike-out" "$PROJ/art/thumbs"
"$GODOT" $GODOT_FLAGS --headless --import >/dev/null 2>&1 || true
( sleep 900; pkill -9 -f "Godot --xr-mode off --path $PROJ" 2>/dev/null ) &
WATCHDOG=$!
trap 'set +e; kill $WATCHDOG 2>/dev/null; true' EXIT
set +e
"$GODOT" $GODOT_FLAGS --rendering-method mobile --resolution 640x640 --position 0,0 \
	--script tools/thumb_bake.gd > "$PROJ/.spike-out/thumb_bake.log" 2>&1
RC=$?
set -e
kill $WATCHDOG 2>/dev/null; wait $WATCHDOG 2>/dev/null || true
# Import the new atlas so the next run (and the export) sees it, not the previous one.
"$GODOT" $GODOT_FLAGS --headless --import >/dev/null 2>&1 || true
grep -a "THUMBBAKE\|SCRIPT ERROR\|Parse Error" "$PROJ/.spike-out/thumb_bake.log" || { tail -20 "$PROJ/.spike-out/thumb_bake.log"; exit 1; }
exit $RC
