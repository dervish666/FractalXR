#!/usr/bin/env bash
# Render every tree species to .spike-out/species/*.png and tile them into
# .spike-out/species.png.
set -euo pipefail
source "$(dirname "$0")/env.sh"
mkdir -p "$PROJ/.spike-out/species"
"$GODOT" $GODOT_FLAGS --headless --import >/dev/null 2>&1 || true
( sleep 240; pkill -9 -f "Godot --xr-mode off --path $PROJ" 2>/dev/null ) &
WATCHDOG=$!
trap 'kill $WATCHDOG 2>/dev/null' EXIT
"$GODOT" $GODOT_FLAGS --rendering-method mobile --resolution 800x800 --position 0,0 \
	--script tools/species_shot.gd > "$PROJ/.spike-out/species_shot.log" 2>&1
RC=$?
kill $WATCHDOG 2>/dev/null; wait $WATCHDOG 2>/dev/null || true
grep -a "SPECIES\|SCRIPT ERROR\|SHADER ERROR\|Parse Error" "$PROJ/.spike-out/species_shot.log" \
	|| { tail -20 "$PROJ/.spike-out/species_shot.log"; exit 1; }
python3 - "$PROJ/.spike-out" <<'EOF'
import sys, os
from PIL import Image, ImageDraw
out = sys.argv[1]
names = sorted(f for f in os.listdir(f"{out}/species") if f.endswith(".png"))
tiles = [Image.open(f"{out}/species/{n}").convert("RGB").resize((360, 360)) for n in names]
cols = 5
rows = (len(tiles) + cols - 1) // cols
sheet = Image.new("RGB", (cols * 360, rows * 360))
d = ImageDraw.Draw(sheet)
for i, (n, t) in enumerate(zip(names, tiles)):
    x, y = (i % cols) * 360, (i // cols) * 360
    sheet.paste(t, (x, y))
    d.text((x + 8, y + 8), n[:-4], fill=(255, 255, 255))
sheet.save(f"{out}/species.png")
print(f"SHEET {out}/species.png {len(tiles)} tiles")
EOF
exit $RC
