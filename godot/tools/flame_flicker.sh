#!/usr/bin/env bash
# Flame flicker: captures every condition in tools/flame_flicker.gd through the real main scene
# into .spike-out/flicker/, then scores them with tools/flicker_metric.py (numpy, Pillow).
# Nonzero exit on a failed capture check, a parse or shader error, a metric check (residual
# shift after compensation, an empty mask) or the watchdog firing.
#
#   tools/flame_flicker.sh                 every condition, the cost pass, then the metric
#   tools/flame_flicker.sh --only=d_frozen  just the conditions whose name starts with that
#   tools/flame_flicker.sh --preset=5      another flame (index into data/presets.json)
set -uo pipefail
source "$(dirname "$0")/env.sh"
OUT="$PROJ/.spike-out/flicker"
LOG="$OUT/flame_flicker.log"
mkdir -p "$OUT"
python3 -c "import numpy, PIL" 2>/dev/null || { echo "FLICKER FAIL python3 needs numpy and Pillow"; exit 1; }
{
	echo "revision: $(git -C "$PROJ" rev-parse --short HEAD 2>/dev/null || echo unknown)"
	echo "dirty:    $(git -C "$PROJ" status --porcelain | wc -l | tr -d ' ') files"
	echo "godot:    $("$GODOT" --version 2>/dev/null | tail -1)"
	echo "renderer: mobile, 1280x800, main.tscn, no XR, fixed 72 fps"
	echo "args:     $*"
	echo
} > "$LOG"
# Import first: a bare --script run executes the last-imported SPIR-V.
"$GODOT" $GODOT_FLAGS --headless --import >/dev/null 2>&1 || true
# --fixed-fps: every frame advances the clocks by exactly 1/72 s however long a capture takes,
# so spin, morphs and drift run at headset speed in frames.
"$GODOT" $GODOT_FLAGS --rendering-method mobile --resolution 1280x800 --position 0,0 \
	--fixed-fps 72 --script tools/flame_flicker.gd -- "$@" >> "$LOG" 2>&1 &
PID=$!
# Own only this child. pkill -f on the project path would take out any other run in flight.
( sleep 1800; kill -9 "$PID" 2>/dev/null ) >/dev/null 2>&1 &
WATCHDOG=$!
trap 'set +e; kill "$WATCHDOG" 2>/dev/null; kill -9 "$PID" 2>/dev/null; true' EXIT
wait "$PID"
RC=$?
kill "$WATCHDOG" 2>/dev/null; wait "$WATCHDOG" 2>/dev/null || true
grep -a "FLICKER\|SCRIPT ERROR\|SHADER ERROR\|Parse Error" "$LOG" || { tail -20 "$LOG"; exit 1; }
grep -aq "SCRIPT ERROR\|SHADER ERROR\|Parse Error" "$LOG" && RC=1
grep -aq "FLICKER PASS" "$LOG" || RC=1
# Cost on the full run only, as its own process under Vulkan (MoltenVK): on Metal neither the
# viewport's GPU timer nor the RenderingDevice timestamps report anything on this Mac.
case " $* " in *" --only="*) ;; *)
	CLOG="$OUT/flame_flicker_cost.log"
	"$GODOT" $GODOT_FLAGS --rendering-driver vulkan --rendering-method mobile --resolution 1280x800 \
		--position 0,0 --script tools/flame_flicker.gd -- --cost "$@" > "$CLOG" 2>&1 &
	CPID=$!
	( sleep 600; kill -9 "$CPID" 2>/dev/null ) >/dev/null 2>&1 &
	CWATCH=$!
	wait "$CPID" || RC=1
	kill "$CWATCH" 2>/dev/null; wait "$CWATCH" 2>/dev/null || true
	grep -a "FLICKER cost\|SCRIPT ERROR\|SHADER ERROR" "$CLOG" | tee -a "$LOG"
	grep -aq "FLICKER cost" "$CLOG" || RC=1
	;;
esac
python3 "$PROJ/tools/flicker_metric.py" "$OUT" | tee -a "$LOG"
MRC=${PIPESTATUS[0]}
[ "$MRC" -eq 0 ] || RC=1
exit $RC
