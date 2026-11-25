#!/usr/bin/env bash
# Store screenshots, posed by script through the real main scene: data/store_shots.json, one
# Godot per shot (tools/trailer.gd, kind "still"), 1920x1080 PNGs and a labelled contact sheet
# in .spike-out/store/. No wrist menu, controllers, HUD or help card in any frame.
#
#   tools/store_shots.sh                       every shot
#   tools/store_shots.sh --only flame-vortex   one shot (comma-separated ids)
set -euo pipefail
source "$(dirname "$0")/env.sh"
exec python3 "$PROJ/tools/trailer.py" --stills --fps 30 --resolution 1920x1080 \
	--shots "$PROJ/data/store_shots.json" --output "$PROJ/.spike-out/store" "$@"
