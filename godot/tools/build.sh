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
# The Meta vendors plugin (FB passthrough and friends) is gitignored, so a git worktree has
# no addons/ and exported an APK where passthrough could only ever be refused (2026-10-04
# headset log: eight "start_passthrough() refused", mr=off throughout). Copy the main
# checkout's plugin in, or stop.
VENDORS="addons/godotopenxrvendors"
if [ ! -d "$PROJ/$VENDORS" ]; then
	MAIN_PROJ="$(cd "$(git -C "$PROJ" rev-parse --path-format=absolute --git-common-dir)/.." && pwd)/godot"
	if [ -d "$MAIN_PROJ/$VENDORS" ]; then
		mkdir -p "$PROJ/addons"
		cp -R "$MAIN_PROJ/$VENDORS" "$PROJ/$VENDORS"
		echo "[build] copied $VENDORS from $MAIN_PROJ"
	else
		echo "[build] $VENDORS is missing: no passthrough, no Meta extensions. See README (godot_openxr_vendors)." >&2
		exit 1
	fi
fi
mkdir -p "$PROJ/build"
if [ ! -f "$PROJ/android/build/build.gradle" ]; then
	"$GODOT" $GODOT_FLAGS --headless --install-android-build-template --quit
fi
# Compare against the archive, since android/build may already contain our override.
TEMPLATE_VERSION=$("$GODOT" --version | cut -d. -f1-4)
if [ "$(uname -s)" = Darwin ]; then
	TEMPLATE_ROOT="$HOME/Library/Application Support/Godot/export_templates"
else
	TEMPLATE_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}/godot/export_templates"
fi
python3 "$PROJ/tools/manifest_check.py" template \
	"$TEMPLATE_ROOT/$TEMPLATE_VERSION/android_source.zip" "$PROJ/tools/AndroidManifest.xml"
# The generated variant manifest merges with this checked immersive-app manifest.
cp "$PROJ/tools/AndroidManifest.xml" "$PROJ/android/build/src/main/AndroidManifest.xml"
AAPT2=$(find "$ANDROID_SDK_ROOT/build-tools" -name aapt2 -type f | sort -V | tail -n 1)
if [ -z "$AAPT2" ] || [ ! -x "$AAPT2" ]; then
	echo "[build] export requires aapt2 in Android SDK build-tools" >&2
	exit 1
fi

case "$MODE" in
release)
	OUT="$PROJ/build/fractalxr.apk"
	rm -f "$OUT"
	: "${GODOT_ANDROID_KEYSTORE_RELEASE_PATH:?set it, or run tools/keystore.sh to make one}"
	: "${GODOT_ANDROID_KEYSTORE_RELEASE_USER:?the key alias}"
	: "${GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD:?the key password}"
	if [ ! -f "$GODOT_ANDROID_KEYSTORE_RELEASE_PATH" ]; then
		echo "[build] release keystore does not exist" >&2
		exit 1
	fi
	APKSIGNER=$(find "$ANDROID_SDK_ROOT/build-tools" -name apksigner -type f | sort -V | tail -n 1)
	if [ -z "$APKSIGNER" ] || [ ! -x "$APKSIGNER" ]; then
		echo "[build] release requires apksigner in Android SDK build-tools" >&2
		exit 1
	fi
	"$GODOT" $GODOT_FLAGS --headless --export-release "Quest" "$OUT"
	;;
debug)
	OUT="$PROJ/build/fractalxr-debug.apk"
	rm -f "$OUT"
	"$GODOT" $GODOT_FLAGS --headless --export-debug "Quest" "$OUT"
	;;
*)
	echo "usage: build.sh [debug|release]" >&2; exit 2 ;;
esac

[ -s "$OUT" ] || { echo "[build] export did not produce an APK" >&2; exit 1; }
ls -lh "$OUT"
MANIFEST_DUMP=$(mktemp)
trap 'rm -f "$MANIFEST_DUMP"' EXIT
if ! "$AAPT2" dump xmltree "$OUT" --file AndroidManifest.xml > "$MANIFEST_DUMP" \
	|| ! python3 "$PROJ/tools/manifest_check.py" apk "$MANIFEST_DUMP"; then
	rm -f "$OUT"
	echo "[build] refusing APK with an unchecked manifest" >&2
	exit 1
fi
# A successful export is insufficient. Verify the actual APK before calling it store-signed.
if [ "$MODE" = release ]; then
	if ! SIGNATURE=$("$APKSIGNER" verify -v --print-certs "$OUT" 2>&1); then
		rm -f "$OUT"
		echo "[build] release APK signature verification failed" >&2
		exit 1
	fi
	if ! grep -Fq 'Verified using v2 scheme (APK Signature Scheme v2): true' <<< "$SIGNATURE"; then
		rm -f "$OUT"
		echo "[build] release APK requires a verified v2 signature" >&2
		exit 1
	fi
	if ! grep -qi 'certificate DN:' <<< "$SIGNATURE" \
		|| grep -qi 'certificate DN:.*Android Debug' <<< "$SIGNATURE"; then
		rm -f "$OUT"
		echo "[build] refusing release APK signed with Android Debug certificate" >&2
		exit 1
	fi
	grep -i 'certificate DN:' <<< "$SIGNATURE"
	echo "BUILD PASS release v2=true certificate=release"
else
	echo "BUILD PASS debug"
fi
