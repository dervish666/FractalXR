#!/usr/bin/env bash
# Make the release keystore that signs every public build, once, ever.
#
#   tools/keystore.sh                       -> ~/.keys/fractalxr-release.keystore
#   KEYSTORE=/path/to.keystore tools/keystore.sh
#
# It lives OUTSIDE the repo on purpose. Back it up somewhere you will still have in five
# years: if it is lost, the only way to ship an update is a new package id, and every
# existing user has to uninstall and reinstall to get it.
set -euo pipefail
source "$(dirname "$0")/env.sh"
KEYSTORE=${KEYSTORE:-$HOME/.keys/fractalxr-release.keystore}
ALIAS=${ALIAS:-fractalxr}
[ -e "$KEYSTORE" ] && { echo "$KEYSTORE already exists. Refusing to overwrite it."; exit 1; }
mkdir -p "$(dirname "$KEYSTORE")"
# 10000 days ~ 27 years. Android wants a key that outlives the app.
keytool -genkeypair -v \
	-keystore "$KEYSTORE" -alias "$ALIAS" \
	-keyalg RSA -keysize 4096 -validity 10000 \
	-storetype PKCS12
chmod 600 "$KEYSTORE"
cat <<TXT

Keystore written to $KEYSTORE (alias: $ALIAS).

Put these in your shell profile (or a file you source before building), never in the repo:

  export GODOT_ANDROID_KEYSTORE_RELEASE_PATH="$KEYSTORE"
  export GODOT_ANDROID_KEYSTORE_RELEASE_USER="$ALIAS"
  export GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD="<the password you just typed>"

Then: tools/build.sh release
TXT
