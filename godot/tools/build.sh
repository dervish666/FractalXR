#!/usr/bin/env bash
# Export the Quest APK. First run also installs the gradle build template.
set -euo pipefail
source "$(dirname "$0")/env.sh"
mkdir -p "$PROJ/build"
EXTRA=""
[ -d "$PROJ/android/build" ] || EXTRA="--install-android-build-template"
"$GODOT" $GODOT_FLAGS --headless $EXTRA --export-debug "Quest" "$PROJ/build/fractalxr-spike.apk"
ls -lh "$PROJ/build/fractalxr-spike.apk"
