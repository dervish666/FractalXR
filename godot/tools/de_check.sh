#!/usr/bin/env bash
# CPU-vs-shader distance estimate check and the hollow finder. Needs a window (renders
# a 64x1 viewport), so it runs like the shot harnesses.
set -uo pipefail
source "$(dirname "$0")/env.sh"
"$GODOT" $GODOT_FLAGS --headless --import >/dev/null 2>&1 || true
( sleep 180; pkill -9 -f "Godot --xr-mode off --path $PROJ" 2>/dev/null ) &
WATCHDOG=$!
# Under set -e a failing Godot run skips the kill below, and four minutes later the
# orphaned watchdog pkills whatever run of this project is in flight. The trap fires
# on every exit path.
trap 'kill $WATCHDOG 2>/dev/null' EXIT
"$GODOT" $GODOT_FLAGS --rendering-method mobile --resolution 320x200 --position 0,0 \
	--script tools/de_check.gd > "$PROJ/.spike-out/de_check.log" 2>&1
RC=$?
kill $WATCHDOG 2>/dev/null; wait $WATCHDOG 2>/dev/null || true
grep -a "DECHECK\|HOLLOW\|  \|SCRIPT ERROR\|Parse Error\|SHADER ERROR" "$PROJ/.spike-out/de_check.log" | grep -av "^\s*$" | head -30
exit $RC
