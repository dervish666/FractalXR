#!/usr/bin/env bash
# Numeric checks for FractalIFS. Nonzero exit on any failed check or on a parse error.
set -uo pipefail
source "$(dirname "$0")/env.sh"
mkdir -p "$PROJ/.spike-out"
LOG="$PROJ/.spike-out/ifs_check.log"
"$GODOT" $GODOT_FLAGS --headless --import >/dev/null 2>&1 || true
"$GODOT" $GODOT_FLAGS --headless --script tools/ifs_check.gd > "$LOG" 2>&1
RC=$?
grep -a "IFSCHECK\|^  \|SCRIPT ERROR\|Parse Error" "$LOG" || { tail -20 "$LOG"; exit 1; }
exit $RC
