#!/usr/bin/env bash
# Parse every GDScript under scripts/ and tools/ with --check-only, plus a deliberately
# broken control that must fail, so a silent "no errors" cannot pass.
# Output is captured, not piped to grep -q: under pipefail an early grep exit gives Godot
# SIGPIPE and the pipeline reads as failure whatever the parse said.
set -uo pipefail
source "$(dirname "$0")/env.sh"
"$GODOT" $GODOT_FLAGS --headless --import >/dev/null 2>&1 || true
check() {
	local out
	out=$("$GODOT" $GODOT_FLAGS --headless --check-only --script "$1" 2>&1)
	grep -aq "Parse Error\|SCRIPT ERROR" <<<"$out"
}
files=0; errors=0
while IFS= read -r f; do
	files=$((files+1))
	if check "$f"; then errors=$((errors+1)); echo "PARSE FAIL $f"; fi
done < <(find scripts tools -name '*.gd' | sort)
printf 'extends Node\nfunc _ready() -> void:\n\tvar x = (\n' > "$PROJ/.spike-out/broken_control.gd"
control=PASS
if check .spike-out/broken_control.gd; then control=FAIL; fi
verdict=PASS; [ "$errors" -eq 0 ] && [ "$control" = FAIL ] || verdict=FAIL
echo "PARSEALL $verdict files=$files errors=$errors control=$control"
