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
done < <(cd "$PROJ" && find scripts tools -name '*.gd' | sort)
# A fresh checkout (CI) has no .spike-out yet; without the directory the control file
# was never written and its "parse" read as clean, which is exactly the failure this
# control exists to catch.
mkdir -p "$PROJ/.spike-out"
printf 'extends Node\nfunc _ready() -> void:\n\tvar x = (\n' > "$PROJ/.spike-out/broken_control.gd"
if [ ! -s "$PROJ/.spike-out/broken_control.gd" ]; then echo "PARSEALL FAIL could not write the control file"; exit 1; fi
control=PASS
if check .spike-out/broken_control.gd; then control=FAIL; fi
# Zero files parsed is not a clean run, it is a run that never happened. The find above
# used to be relative to the caller's directory, so invoking this from the repo root (which
# is how every other tool here is invoked) printed PASS files=0 and checked nothing.
verdict=PASS; [ "$errors" -eq 0 ] && [ "$control" = FAIL ] && [ "$files" -gt 0 ] || verdict=FAIL
echo "PARSEALL $verdict files=$files errors=$errors control=$control"
