#!/usr/bin/env bash
# Fixed-step desktop Movie Maker, H.264/AAC master and labelled contact sheet.
set -euo pipefail
source "$(dirname "$0")/env.sh"
exec python3 "$PROJ/tools/trailer.py" "$@"
