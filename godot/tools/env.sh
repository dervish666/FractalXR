# Shared toolchain paths. Source this, don't run it.
export JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
export ANDROID_SDK_ROOT=/opt/homebrew/share/android-commandlinetools
export PATH="$JAVA_HOME/bin:$ANDROID_SDK_ROOT/platform-tools:$PATH"
export GODOT=${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}
export PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# --xr-mode off is load-bearing on the Mac: the OpenXR loader hangs for minutes
# looking for a runtime that isn't there, and takes the whole process with it.
export GODOT_FLAGS="--xr-mode off --path $PROJ"
