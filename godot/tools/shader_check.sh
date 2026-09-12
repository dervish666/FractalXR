#!/usr/bin/env bash
# Compile-check shaders headless: tools/shader_check.sh shaders/a.gdshader [shaders/b.gdshader ...]
set -uo pipefail
source "$(dirname "$0")/env.sh"
"$GODOT" $GODOT_FLAGS --headless --script tools/shader_check.gd -- "$@" 2>&1 | grep -a "SHADERCHECK\|SHADER ERROR" 
