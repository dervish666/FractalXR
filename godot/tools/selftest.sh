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
# Import first, ALWAYS. A --script run does not rescan the filesystem, so it happily
# executes the last-imported SPIR-V and reports a pass on shader source that was never
# compiled. That cost an evening: three edits to a compute shader in a row, each
# "verified" against the binary from before the first one.
"$GODOT" $GODOT_FLAGS --headless --import >/dev/null 2>&1 || true
( sleep 240; pkill -9 -f "Godot --xr-mode off --path $PROJ" 2>/dev/null ) &
WATCHDOG=$!
# Under set -e a failing Godot run skips the kill below, and four minutes later the
# orphaned watchdog pkills whatever run of this project is in flight. The trap fires
# on every exit path.
trap 'kill $WATCHDOG 2>/dev/null' EXIT
"$GODOT" $GODOT_FLAGS --rendering-method mobile --resolution 320x240 --position 0,0 \
	--script selftest.gd > "$PROJ/.spike-out/selftest.log" 2>&1
RC=$?
kill $WATCHDOG 2>/dev/null; wait $WATCHDOG 2>/dev/null || true
grep -a "SELFTEST" "$PROJ/.spike-out/selftest.log" || { tail -20 "$PROJ/.spike-out/selftest.log"; exit 1; }
exit $RC
