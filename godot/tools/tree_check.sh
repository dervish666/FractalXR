#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/env.sh"
"$GODOT" $GODOT_FLAGS --headless --script tools/tree_check.gd 2>&1 | grep -a "TREECHECK\|  \|SCRIPT ERROR\|Parse Error" | grep -av "^\s*$"
