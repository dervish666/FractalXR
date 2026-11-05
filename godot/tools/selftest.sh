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
"$GODOT" $GODOT_FLAGS --rendering-method mobile --resolution 320x240 --position 0,0 \
	--script selftest.gd > "$PROJ/.spike-out/selftest.log" 2>&1 &
PID=$!
# Own only this child. pkill -f on the project path would take out any other run in flight.
( sleep 240; kill -9 "$PID" 2>/dev/null ) >/dev/null 2>&1 &
WATCHDOG=$!
trap 'set +e; kill "$WATCHDOG" 2>/dev/null; kill -9 "$PID" 2>/dev/null; true' EXIT
RC=0
wait "$PID" || RC=$?
kill "$WATCHDOG" 2>/dev/null; wait "$WATCHDOG" 2>/dev/null || true
grep -a "SELFTEST" "$PROJ/.spike-out/selftest.log" || { tail -20 "$PROJ/.spike-out/selftest.log"; exit 1; }
exit $RC
