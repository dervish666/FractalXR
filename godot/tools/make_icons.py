#!/usr/bin/env python3
"""Turn one rendered candidate into every icon the Android export and the store need.

    tools/make_icons.py art/candidates/vortex.png [--keep 0.9] [--floor 45] [--out art]

Writes into art/:
    icon_192.png        legacy launcher icon (full bleed: ground + fractal)
    icon_fg_432.png     adaptive foreground, transparent, inside the 66/108 safe circle
    icon_bg_432.png     adaptive background, the deep-space ground
    icon_512.png        project icon and the square the store listing crops from

The source is a real engine render with a straight alpha derived from glow luminance
(src/bake/icon.ts), so the only work here is framing: crop to where the light actually is,
lift the alpha floor so isolated single-pixel dust does not survive being shrunk to 48px,
and centre it in each canvas.
"""
import sys
import pathlib
from PIL import Image

GROUND_IN = (26, 17, 64)    # centre of the radial ground
GROUND_OUT = (7, 3, 15)     # its edge
DUST_FLOOR = 45             # alpha below this is dust, not structure
FG_FILL = 0.62              # adaptive safe zone is a 66dp circle inside 108dp
LEGACY_FILL = 0.84          # legacy icons are masked by the launcher, so they run fuller


def clean(im: Image.Image, floor: int = DUST_FLOOR) -> Image.Image:
    """Drop the dust, keep the glow. Everything faint is rescaled rather than clipped, so
    the soft outer falloff survives instead of gaining a hard edge."""
    r, g, b, a = im.split()
    a = a.point(lambda v: 0 if v < floor else int((v - floor) * 255 / (255 - floor)))
    return Image.merge("RGBA", (r, g, b, a))


def crop_to_light(im: Image.Image, keep: float = 0.72, air: float = 2.15) -> Image.Image:
    """Square crop centred on the bright core, not on the dust.

    A chaos game throws a wide halo of single-pixel outliers. Weighting by alpha alone puts the
    centre in the middle of that halo and the crop ends up framing speckle, so the weight here is
    alpha cubed: the dense core decides both the centre and the radius. `keep` is the fraction of
    that weighted mass the radius must contain, `air` how much wider than that radius the crop
    runs, which is what sets how big the fractal sits in the icon.
    """
    n = 256
    a = im.split()[3].resize((n, n), Image.LANCZOS)
    w = [v ** 3 for v in a.tobytes()]
    total = sum(w) or 1
    cx = sum(w[y * n + x] * x for y in range(n) for x in range(n)) / total
    cy = sum(w[y * n + x] * y for y in range(n) for x in range(n)) / total

    # Radial mass histogram around that centre, in whole pixels of the 256 proxy.
    bins = [0.0] * (n + 1)
    for y in range(n):
        for x in range(n):
            wt = w[y * n + x]
            if wt:
                bins[min(n, int(((x - cx) ** 2 + (y - cy) ** 2) ** 0.5))] += wt
    acc, radius = 0.0, n
    for r, v in enumerate(bins):
        acc += v
        if acc >= keep * total:
            radius = r
            break

    scale = im.size[0] / n
    cx, cy, half = cx * scale, cy * scale, max(radius * scale * air, im.size[0] * 0.12)
    return im.crop((int(cx - half), int(cy - half), int(cx + half), int(cy + half)))


def ground(size: int) -> Image.Image:
    """Radial ground, drawn small and upscaled: a 64px gradient resampled to 432 is smooth
    and costs nothing, where per-pixel Python is neither."""
    n = 64
    g = Image.new("RGB", (n, n))
    px = g.load()
    for y in range(n):
        for x in range(n):
            dx, dy = (x - (n - 1) / 2) / (n / 2), (y - (n - 1) / 2) / (n / 2)
            t = min(1.0, (dx * dx + dy * dy) ** 0.5 / 1.25)
            t = t * t * (3 - 2 * t)
            px[x, y] = tuple(int(a + (b - a) * t) for a, b in zip(GROUND_IN, GROUND_OUT))
    return g.resize((size, size), Image.LANCZOS)


def placed(art: Image.Image, canvas: int, fill: float) -> Image.Image:
    edge = int(canvas * fill)
    scaled = art.resize((edge, edge), Image.LANCZOS)
    out = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    off = (canvas - edge) // 2
    out.paste(scaled, (off, off), scaled)
    return out


def main() -> int:
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return 2
    src = pathlib.Path(args[0])
    opt = dict(zip(args[1::2], args[2::2]))
    keep = float(opt.get("--keep", 0.72))
    floor = int(opt.get("--floor", DUST_FLOOR))
    art = crop_to_light(clean(Image.open(src).convert("RGBA"), floor), keep,
                        float(opt.get("--air", 2.15)))
    out = pathlib.Path(opt.get("--out", pathlib.Path(__file__).resolve().parent.parent / "art"))
    out.mkdir(exist_ok=True)

    fg = placed(art, 432, FG_FILL)
    fg.save(out / "icon_fg_432.png")
    ground(432).save(out / "icon_bg_432.png")

    for size, name in ((192, "icon_192.png"), (512, "icon_512.png")):
        base = ground(size).convert("RGBA")
        base.alpha_composite(placed(art, size, LEGACY_FILL))
        base.save(out / name)

    print(f"{src.name} -> art/icon_192.png, icon_512.png, icon_fg_432.png, icon_bg_432.png")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
