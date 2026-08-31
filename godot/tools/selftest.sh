#!/usr/bin/env bash
# Headless-ish ground truth: runs the real compute chain on this machine's GPU,
# writes .spike-out/selftest.png, and passes only if the frame looks like a live
# chaos game. The fast loop for shader edits, no headset needed.
#
# Needs a window (a true --headless run has no RenderingDevice), so it flashes a
# 320x240 window for a second.
set -euo pipefail
source "$(dirname "$0")/env.sh"
mkdir -p "$PROJ/.spike-out"
( sleep 240; pkill -9 -f "Godot --xr-mode off --path $PROJ" 2>/dev/null ) &
WATCHDOG=$!
"$GODOT" $GODOT_FLAGS --rendering-method mobile --resolution 320x240 --position 0,0 \
	--script selftest.gd > "$PROJ/.spike-out/selftest.log" 2>&1
RC=$?
kill $WATCHDOG 2>/dev/null; wait $WATCHDOG 2>/dev/null || true
grep -a "SELFTEST" "$PROJ/.spike-out/selftest.log" || { tail -20 "$PROJ/.spike-out/selftest.log"; exit 1; }
exit $RC
