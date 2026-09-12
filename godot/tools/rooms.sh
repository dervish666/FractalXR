#!/usr/bin/env bash
# Precompute bulb extents and rooms into data/rooms.json. Headless, a few minutes.
set -uo pipefail
source "$(dirname "$0")/env.sh"
"$GODOT" $GODOT_FLAGS --headless --script tools/rooms.gd 2>&1 | grep -a "ROOM\|SCRIPT ERROR\|Parse Error"
