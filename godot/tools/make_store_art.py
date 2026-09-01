#!/usr/bin/env python3
"""Compose the two SideQuest listing images from rendered candidates.

    tools/make_store_art.py art/candidates/vortex.png art/candidates/glacier.png

Writes into art/store/:
    card_1024x576.png        listing artwork: the card shown in the library and on the homepage.
                             Transparent, 16:9, artwork plus wordmark, per SideQuest's guide.
    background_1920x1080.png listing background: atmosphere only. Their guide is explicit that
                             it carries no text and no logo, so this is glow and nothing else.

Screenshots and the trailer are deliberately NOT generated here. Those have to be captured in
the headset (adb shell ls -t /sdcard/Oculus/Screenshots/): a desktop render is not what a
person sees through the lenses, and a listing that promises one and delivers the other earns
exactly the reviews it deserves.
"""
import sys
import pathlib
from PIL import Image, ImageDraw, ImageFont, ImageFilter

FONT = "/System/Library/Fonts/Supplemental/Futura.ttc"
GROUND_IN = (26, 17, 64)
GROUND_OUT = (7, 3, 15)


def font(size: int, index: int = 0) -> ImageFont.FreeTypeFont:
    try:
        return ImageFont.truetype(FONT, size, index=index)
    except OSError:
        return ImageFont.load_default(size)


def ground(w: int, h: int) -> Image.Image:
    n = 96
    g = Image.new("RGB", (n, n))
    px = g.load()
    for y in range(n):
        for x in range(n):
            dx, dy = (x - n / 2) / (n / 2), (y - n / 2) / (n / 2)
            t = min(1.0, (dx * dx + dy * dy) ** 0.5 / 1.3)
            t = t * t * (3 - 2 * t)
            px[x, y] = tuple(int(a + (b - a) * t) for a, b in zip(GROUND_IN, GROUND_OUT))
    return g.resize((w, h), Image.LANCZOS)


def fit(art: Image.Image, edge: int) -> Image.Image:
    return art.resize((edge, edge), Image.LANCZOS)


def card(art: Image.Image, out: pathlib.Path) -> None:
    w, h = 1024, 576
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    glow = fit(art, 520)
    im.alpha_composite(glow, (28, (h - 520) // 2))

    d = ImageDraw.Draw(im)
    # The text block is fitted, not placed: a wordmark that overflows the card is invisible
    # in the library grid, where the card is cropped to whatever the layout wants.
    left, right = 556, w - 40
    title_px, sub_px = 92, 36
    while d.textlength("FractalXR", font=font(title_px)) > right - left and title_px > 40:
        title_px -= 2
    while d.textlength("fractal flames you can fly through", font=font(sub_px)) > right - left and sub_px > 18:
        sub_px -= 1
    d.text((left, 226), "FractalXR", font=font(title_px), fill=(238, 242, 255, 255))
    d.text((left + 4, 226 + title_px + 26), "fractal flames you can fly through",
           font=font(sub_px), fill=(158, 176, 216, 255))
    im.save(out / "card_1024x576.png")


def background(arts: list[Image.Image], out: pathlib.Path) -> None:
    w, h = 1920, 1080
    im = ground(w, h).convert("RGBA")
    # Two clouds, off centre and unequal, so the middle stays clear for the listing's own
    # overlaid text and the eye has somewhere to go.
    a = fit(arts[0], 1180)
    im.alpha_composite(Image.blend(Image.new("RGBA", a.size, (0, 0, 0, 0)), a, 0.85), (-180, -120))
    if len(arts) > 1:
        b = fit(arts[1], 900).filter(ImageFilter.GaussianBlur(2.5))
        im.alpha_composite(Image.blend(Image.new("RGBA", b.size, (0, 0, 0, 0)), b, 0.55), (1180, 320))
    im.convert("RGB").save(out / "background_1920x1080.png")


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    arts = [Image.open(p).convert("RGBA") for p in sys.argv[1:]]
    out = pathlib.Path(__file__).resolve().parent.parent / "art" / "store"
    out.mkdir(parents=True, exist_ok=True)
    card(arts[0], out)
    background(arts, out)
    print(f"art/store/card_1024x576.png, art/store/background_1920x1080.png")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
