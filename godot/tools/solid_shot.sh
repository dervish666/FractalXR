#!/usr/bin/env bash
# Render the SOLID mesh spike harness; shots in .spike-out/solid/.
set -euo pipefail
source "$(dirname "$0")/env.sh"
mkdir -p "$PROJ/.spike-out"
"$GODOT" $GODOT_FLAGS --headless --import >/dev/null 2>&1 || true
( sleep 900; pkill -9 -f "Godot --xr-mode off --path $PROJ" 2>/dev/null ) &
WATCHDOG=$!
# Under set -e a failing Godot run skips the kill below, and four minutes later the
# orphaned watchdog pkills whatever run of this project is in flight. The trap fires
# on every exit path.
trap 'set +e; kill $WATCHDOG 2>/dev/null; true' EXIT
"$GODOT" $GODOT_FLAGS --rendering-method mobile ${SOLID_DRIVER:+--rendering-driver $SOLID_DRIVER} --resolution 1280x800 --position 0,0 \
	--script tools/solid_shot.gd "$@" > "$PROJ/.spike-out/solid_shot.log" 2>&1
RC=$?
kill $WATCHDOG 2>/dev/null; wait $WATCHDOG 2>/dev/null || true
grep -a "SOLIDSHOT\|SOLIDROW\|\[solid\]\|SCRIPT ERROR\|SHADER ERROR\|Parse Error" "$PROJ/.spike-out/solid_shot.log" || { tail -20 "$PROJ/.spike-out/solid_shot.log"; exit 1; }
exit $RC
