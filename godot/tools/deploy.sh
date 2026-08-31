#!/usr/bin/env bash
# Build, install onto the attached Quest, launch, and stream the perf log.
set -euo pipefail
source "$(dirname "$0")/env.sh"
adb devices | grep -q "device$" || { echo "No Quest attached. Check developer mode and the USB prompt."; exit 1; }
"$(dirname "$0")/build.sh"
adb install -r "$PROJ/build/fractalxr-spike.apk"
adb shell monkey -p uk.fractalxr.spike -c android.intent.category.LAUNCHER 1 >/dev/null
echo "--- streaming [perf] (ctrl-c to stop) ---"
adb logcat -c
adb logcat godot:V '*:S' | grep --line-buffered "\[perf\]"
