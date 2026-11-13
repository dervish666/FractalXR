#!/usr/bin/env bash
# First rendered loading view and world-locked composition-layer lifecycle.
set -uo pipefail
source "$(dirname "$0")/env.sh"
mkdir -p "$PROJ/.spike-out"
LOG="$PROJ/.spike-out/startup_check.log"
# A --script run does not rescan; import first so it runs the scripts on disk.
"$GODOT" $GODOT_FLAGS --headless --import >/dev/null 2>&1 || true
run() {
	local log="$1"; shift
	"$GODOT" $GODOT_FLAGS --rendering-method mobile --resolution 960x720 --position 0,0 \
		--script tools/startup_check.gd -- "$@" > "$log" 2>&1 &
	PID=$!
	( sleep 120; kill -9 "$PID" 2>/dev/null ) >/dev/null 2>&1 &
	WATCHDOG=$!
	trap 'set +e; kill "$WATCHDOG" 2>/dev/null; kill -9 "$PID" 2>/dev/null; true' EXIT
	local rc=0
	wait "$PID" || rc=$?
	kill "$WATCHDOG" 2>/dev/null; wait "$WATCHDOG" 2>/dev/null || true
	if grep -aq "ERROR:" "$log"; then tail -30 "$log"; return 2; fi
	return "$rc"
}
if ! run "$LOG" "$@"; then
	grep -a "STARTUPCHECK\|ERROR:" "$LOG" || tail -30 "$LOG"
	exit 1
fi
grep -a "STARTUPCHECK" "$LOG"
grep -aq "^STARTUPCHECK PASS" "$LOG" || exit 1
# Both controls must reject the same assertions as the positive run. A crash or a
# script error does not count as a rejecting control.
for control in eager signals-only; do
	CONTROL_LOG="$PROJ/.spike-out/startup_${control}_control.log"
	run "$CONTROL_LOG" "--${control}-control"
	RC=$?
	if [ "$RC" -ne 1 ] || ! grep -aq "^STARTUPCHECK FAIL failures=" "$CONTROL_LOG"; then
		tail -30 "$CONTROL_LOG"; echo "STARTUP CONTROLS FAIL $control"; exit 1
	fi
	case "$control" in
	eager) EXPECTED="main load preceded boot draw" ;;
	signals-only) EXPECTED="focus before attachment was missed" ;;
	esac
	grep -aq "$EXPECTED" "$CONTROL_LOG" || { echo "STARTUP CONTROLS FAIL wrong assertion"; exit 1; }
done
echo "STARTUP CONTROLS PASS eager=FAIL signals-only=FAIL"
