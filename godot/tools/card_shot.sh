#!/usr/bin/env bash
# Render the controls card in every mode to .spike-out/help_card_<mode>.png. Imports first,
# for the same reason selftest.sh does: a --script run does not rescan the filesystem.
set -euo pipefail
source "$(dirname "$0")/env.sh"
mkdir -p "$PROJ/.spike-out"
"$GODOT" $GODOT_FLAGS --headless --import >/dev/null 2>&1 || true
"$GODOT" $GODOT_FLAGS --rendering-method mobile --resolution 320x240 --position 0,0 \
	--script tools/card_shot.gd > "$PROJ/.spike-out/card_shot.log" 2>&1 &
PID=$!
# Own only this child. pkill -f on the project path would take out any other run in flight.
( sleep 240; kill -9 "$PID" 2>/dev/null ) >/dev/null 2>&1 &
WATCHDOG=$!
trap 'set +e; kill "$WATCHDOG" 2>/dev/null; kill -9 "$PID" 2>/dev/null; true' EXIT
# RC=0; wait || RC=$?, not a bare wait: under set -e a failing run exited here and the grep
# below never printed why it failed.
RC=0
wait "$PID" || RC=$?
kill "$WATCHDOG" 2>/dev/null; wait "$WATCHDOG" 2>/dev/null || true
grep -a "CARDSHOT\|SCRIPT ERROR\|Parse Error" "$PROJ/.spike-out/card_shot.log" || { tail -20 "$PROJ/.spike-out/card_shot.log"; exit 1; }
exit $RC
