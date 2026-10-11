# Shared toolchain paths. Source this, don't run it. Works from bash and zsh.
export JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
export ANDROID_SDK_ROOT=/opt/homebrew/share/android-commandlinetools
export PATH="$JAVA_HOME/bin:$ANDROID_SDK_ROOT/platform-tools:$PATH"
export GODOT=${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}
# This file's own path. zsh has no BASH_SOURCE, so it used to fall through to the caller's
# directory and PROJ landed on the repo root, where --import finds nothing and exits 0.
# zsh's ${(%):-%x} is a bash parse error, hence the eval behind the ZSH_VERSION test.
if [ -n "${BASH_SOURCE[0]:-}" ]; then
	_fxr_env_src="${BASH_SOURCE[0]}"
elif [ -n "${ZSH_VERSION:-}" ]; then
	eval '_fxr_env_src="${(%):-%x}"'
else
	_fxr_env_src="$0"
fi
export PROJ="$(cd -P -- "$(dirname -- "$_fxr_env_src")/.." >/dev/null && pwd)"
unset _fxr_env_src
if [ ! -f "$PROJ/project.godot" ]; then
	echo "env.sh: no project.godot in '$PROJ'; refusing to point GODOT_FLAGS at it" >&2
	# Unset, so a caller under set -u stops at its first use instead of running against the
	# wrong folder.
	unset PROJ GODOT_FLAGS
	return 1 2>/dev/null || exit 1
fi
# --xr-mode off is load-bearing on the Mac: the OpenXR loader hangs for minutes
# looking for a runtime that isn't there, and takes the whole process with it.
export GODOT_FLAGS="--xr-mode off --path $PROJ"
