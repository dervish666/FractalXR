#!/usr/bin/env bash
# Scrape a thermal soak into CSV. Run for at least 15 minutes from a cold headset:
# Quest 3 throttling is guaranteed after 5-15 minutes and invisible to every API,
# so a cold-start reading measures nothing you can ship.
#
#   tools/soak.sh 900 > soak-compute.csv
set -euo pipefail
source "$(dirname "$0")/env.sh"
DURATION=${1:-900}
echo "t_s,fps,draw_ms,sim_ms,vp,preset,count,iters,eye"
adb logcat -c
timeout_at=$(( $(date +%s) + DURATION ))
adb logcat godot:V '*:S' | while read -r line; do
	case "$line" in *"[perf]"*)
		# sed knows \1 to \9 only, so nine fields: the ones the thermal curve needs.
		row=$(echo "$line" | sed -nE 's/.*\[perf\] t=([0-9.]+) fps=([0-9.]+) draw_ms=([0-9.]+) sim_ms=([0-9.]+) fov=[0-9]+ dyn=[a-z]+ rt=\([^)]*\) vp=([0-9x]+) scale3d=[0-9.]+ preset=([^ ]+) count=([0-9]+) point=[0-9.]+ iters=([0-9]+) eye=([0-9x]+).*/\1,\2,\3,\4,\5,\6,\7,\8,\9/p')
		if [ -z "$row" ]; then echo "soak: perf line did not match the expected format: $line" >&2; exit 2; fi
		echo "$row"
	;; esac
	[ "$(date +%s)" -ge "$timeout_at" ] && break
done
