#!/usr/bin/env bash
# GALAXY, ECHOES and the flame SKY through the real main scene; captures into
# .spike-out/flame-scale-2026-10-10/. Nonzero exit on a failed check, a parse or shader error,
# a missing PNG or the watchdog firing.
set -uo pipefail
source "$(dirname "$0")/env.sh"
OUT="$PROJ/.spike-out/flame-scale-2026-10-10"
LOG="$OUT/flame_scale_shot.log"
mkdir -p "$OUT"
{
	echo "revision: $(git -C "$PROJ" rev-parse --short HEAD 2>/dev/null || echo unknown)"
	echo "dirty:    $(git -C "$PROJ" status --porcelain | wc -l | tr -d ' ') files"
	echo "godot:    $("$GODOT" --version 2>/dev/null | tail -1)"
	echo "renderer: mobile, 1280x800, main.tscn, no XR"
	echo
} > "$LOG"
# Import first: a bare --script run executes the last-imported SPIR-V.
"$GODOT" $GODOT_FLAGS --headless --import >/dev/null 2>&1 || true
"$GODOT" $GODOT_FLAGS --rendering-method mobile --resolution 1280x800 --position 0,0 \
	--script tools/flame_scale_shot.gd >> "$LOG" 2>&1 &
PID=$!
# Own only this child. pkill -f on the project path would take out any other run in flight.
( sleep 420; kill -9 "$PID" 2>/dev/null ) >/dev/null 2>&1 &
WATCHDOG=$!
trap 'set +e; kill "$WATCHDOG" 2>/dev/null; kill -9 "$PID" 2>/dev/null; true' EXIT
wait "$PID"
RC=$?
kill "$WATCHDOG" 2>/dev/null; wait "$WATCHDOG" 2>/dev/null || true
grep -a "FLAMESCALE\|SCRIPT ERROR\|SHADER ERROR\|Parse Error" "$LOG" || { tail -20 "$LOG"; exit 1; }
grep -aq "SCRIPT ERROR\|SHADER ERROR\|Parse Error" "$LOG" && RC=1
for png in flame-home.png galaxy-fwd.png galaxy-up.png galaxy-out.png echoes-off-wide.png \
		echoes-eight-wide.png sky-equirect.png sky-tree.png nosky-tree.png sky-ifs.png sky-ground.png \
		sky-flame.png nosky-flame.png sky-bulb.png nosky-bulb.png; do
	[ -s "$OUT/$png" ] || { echo "FLAMESCALE FAIL missing $OUT/$png"; exit 1; }
done
exit $RC
