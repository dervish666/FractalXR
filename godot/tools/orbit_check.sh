#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/env.sh"
"$GODOT" $GODOT_FLAGS --headless --script tools/orbit_check.gd 2>&1 | grep -a "MAPCHECK\|ORBITCHECK\|SCRIPT ERROR\|Parse Error"
