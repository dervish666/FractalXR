#!/usr/bin/env bash
# Scrape a thermal soak into CSV. Run for at least 15 minutes from a cold headset:
# Quest 3 throttling is guaranteed after 5-15 minutes and invisible to every API,
# so a cold-start reading measures nothing you can ship.
#
#   tools/soak.sh 900 > soak-compute.csv
set -euo pipefail
source "$(dirname "$0")/env.sh"
DURATION=${1:-900}
echo "t_s,fps,gpu_ms,cpu_ms,path,stamp,count,iters,eye"
adb logcat -c
timeout_at=$(( $(date +%s) + DURATION ))
adb logcat godot:V '*:S' | while read -r line; do
	case "$line" in *"[perf]"*)
		echo "$line" | sed -E 's/.*\[perf\] t=([0-9.]+) fps=([0-9.]+) gpu_ms=([0-9.]+) cpu_ms=([0-9.]+) path=([^ ]+) stamp=([0-9]+) count=([0-9]+) iters=([0-9]+) eye=([0-9x]+).*/\1,\2,\3,\4,\5,\6,\7,\8,\9/'
	;; esac
	[ "$(date +%s)" -ge "$timeout_at" ] && break
done
