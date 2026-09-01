#!/usr/bin/env bash
# Export the Quest APK. First run also installs the gradle build template.
#
#   tools/build.sh            debug build, debug-signed, for the local dev loop
#   tools/build.sh release    release build, signed with the release keystore (what SideQuest gets)
#
# Release signing reads three env vars (see tools/keystore.sh):
#   GODOT_ANDROID_KEYSTORE_RELEASE_PATH / _USER / _PASSWORD
# Keep the keystore and its password outside this repo, and keep them forever: a
# different signature means every installed user has to uninstall before they can update.
set -euo pipefail
source "$(dirname "$0")/env.sh"
MODE=${1:-debug}
mkdir -p "$PROJ/build"
EXTRA=""
[ -d "$PROJ/android/build" ] || EXTRA="--install-android-build-template"

case "$MODE" in
release)
	: "${GODOT_ANDROID_KEYSTORE_RELEASE_PATH:?set it, or run tools/keystore.sh to make one}"
	: "${GODOT_ANDROID_KEYSTORE_RELEASE_USER:?the key alias}"
	: "${GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD:?the key password}"
	OUT="$PROJ/build/fractalxr.apk"
	"$GODOT" $GODOT_FLAGS --headless $EXTRA --export-release "Quest" "$OUT"
	;;
debug)
	OUT="$PROJ/build/fractalxr-debug.apk"
	"$GODOT" $GODOT_FLAGS --headless $EXTRA --export-debug "Quest" "$OUT"
	;;
*)
	echo "usage: build.sh [debug|release]" >&2; exit 2 ;;
esac

ls -lh "$OUT"
# Prove what actually signed it. A debug-signed APK on a store listing is a bug, not a detail.
APKSIGNER=$(ls "$ANDROID_SDK_ROOT"/build-tools/*/apksigner 2>/dev/null | tail -1 || true)
[ -n "$APKSIGNER" ] && "$APKSIGNER" verify --print-certs "$OUT" | grep -i "signer #1 certificate DN" || true
