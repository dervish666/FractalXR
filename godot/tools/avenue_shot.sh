#!/usr/bin/env bash
# Render and validate the avenue, standing and walking, through the real main scene.
set -euo pipefail
source "$(dirname "$0")/env.sh"
mkdir -p "$PROJ/.spike-out"
"$GODOT" $GODOT_FLAGS --headless --import >/dev/null 2>&1 || true
( sleep 420; pkill -9 -f "Godot --xr-mode off --path $PROJ" 2>/dev/null ) &
WATCHDOG=$!
trap 'set +e; kill $WATCHDOG 2>/dev/null; true' EXIT
# || RC=$?, not a bare RC=$? after: under set -e a failing run exited here and the grep below
# never printed why it failed.
RC=0
"$GODOT" $GODOT_FLAGS --rendering-method mobile --resolution 1280x800 --position 0,0 \
	--script tools/avenue_shot.gd > "$PROJ/.spike-out/avenue_shot.log" 2>&1 || RC=$?
kill $WATCHDOG 2>/dev/null; wait $WATCHDOG 2>/dev/null || true
grep -a "AVENUESHOT\|SCRIPT ERROR\|SHADER ERROR\|Parse Error" "$PROJ/.spike-out/avenue_shot.log" \
	|| { tail -20 "$PROJ/.spike-out/avenue_shot.log"; exit 1; }
exit $RC
