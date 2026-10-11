#!/usr/bin/env bash
# CYCLE through the real main scene: the clock, a six-phase strip per mode in .spike-out/cycle/,
# a control that must fail, then GPU cost off against on. See tools/cycle_shot.gd. Nonzero on any failed check, a script
# error or a shader error.
set -uo pipefail
source "$(dirname "$0")/env.sh"
mkdir -p "$PROJ/.spike-out/cycle"
LOG="$PROJ/.spike-out/cycle/cycle_shot.log"
# Import first: a bare --script run executes the last-imported SPIR-V.
"$GODOT" $GODOT_FLAGS --headless --import >/dev/null 2>&1 || true
"$GODOT" $GODOT_FLAGS --rendering-method mobile --resolution 1280x800 --position 0,0 \
	--script tools/cycle_shot.gd > "$LOG" 2>&1 &
PID=$!
# Own only this child, and keep the watchdog off this script's stdout so a caller piping the
# output does not wait out the sleep.
( sleep 900; kill -9 "$PID" 2>/dev/null ) >/dev/null 2>&1 &
WATCHDOG=$!
trap 'set +e; kill "$WATCHDOG" 2>/dev/null; kill -9 "$PID" 2>/dev/null; true' EXIT
wait "$PID"
RC=$?
grep -a "CYCLESHOT\|SCRIPT ERROR\|SHADER ERROR\|Parse Error" "$LOG" || { tail -20 "$LOG"; exit 1; }
grep -aq "SCRIPT ERROR\|Parse Error" "$LOG" && RC=1
grep -aq "SHADER ERROR" "$LOG" && RC=1
grep -aq "CYCLESHOT PASS" "$LOG" || RC=1
# The cost pass, as its own process under Vulkan (MoltenVK): Metal reports no GPU time here.
CLOG="$PROJ/.spike-out/cycle/cycle_cost.log"
"$GODOT" $GODOT_FLAGS --rendering-driver vulkan --rendering-method mobile --resolution 1280x800 \
	--position 0,0 --script tools/cycle_shot.gd -- cost > "$CLOG" 2>&1 &
CPID=$!
( sleep 900; kill -9 "$CPID" 2>/dev/null ) >/dev/null 2>&1 &
CWATCH=$!
wait "$CPID" || RC=1
kill "$CWATCH" 2>/dev/null; wait "$CWATCH" 2>/dev/null || true
grep -a "CYCLESHOT cost\|SCRIPT ERROR\|SHADER ERROR" "$CLOG"
grep -aq "CYCLESHOT cost" "$CLOG" || RC=1
grep -aq "SCRIPT ERROR\|SHADER ERROR" "$CLOG" && RC=1
exit $RC
