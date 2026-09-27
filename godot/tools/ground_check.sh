#!/usr/bin/env bash
# ground.glsl's df32 and f32 fills against a 64-bit CPU port; see tools/ground_check.gd.
# Windowed, because a local RenderingDevice needs a real driver.
set -uo pipefail
source "$(dirname "$0")/env.sh"
mkdir -p "$PROJ/.spike-out"
# The float32-only fill from before df32 (ae1ab62), as the shallow baseline and the bench's
# reference. Compiled at runtime by the check, so it needs no import.
git -C "$PROJ" show ae1ab62:godot/shaders/ground.glsl > "$PROJ/.spike-out/ground_base.glsl" 2>/dev/null || rm -f "$PROJ/.spike-out/ground_base.glsl"
# Compute shaders compile on import only; a stale import has passed a check before.
"$GODOT" $GODOT_FLAGS --headless --import >/dev/null 2>&1 || true
"$GODOT" $GODOT_FLAGS --rendering-method mobile --resolution 320x200 \
	--script tools/ground_check.gd -- "$@" > "$PROJ/.spike-out/ground_check.log" 2>&1
RC=$?
grep -a "GROUNDCHECK\|SWEEP\|BENCH\|^  \|SCRIPT ERROR\|Parse Error" "$PROJ/.spike-out/ground_check.log" || { tail -20 "$PROJ/.spike-out/ground_check.log"; exit 1; }
exit $RC
