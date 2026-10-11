#!/usr/bin/env python3
"""A SKY preset against the live equirect it was made from, look by look.

tools/sky_bake.sh bake writes baked_<name>_<look>.png (the 8192 equirect through the live
path) and tools/sky_bake.sh preview writes cube_<name>_<look>.png (the imported cubemap
through the preset path), from the same camera. For each look this prints the correlation of
their luminance after a small blur (the cube is 2048 a face, so detail finer than that is
expected to differ) and the mean absolute difference, plus a CONTROL row pairing each cube
look with a different baked look, which has to score far lower or the check proves nothing.
Writes compare_<name>.png: the pairs side by side, baked left, cube right.

  python3 tools/sky_compare.py vortex [glacier ...]
"""
import os, sys
import numpy as np
from PIL import Image, ImageFilter

D = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '.spike-out', 'skies')
LOOKS = ['fwd', 'up', 'back', 'down', 'edge', 'corner']


def lum(path):
    im = Image.open(path).convert('RGB').filter(ImageFilter.GaussianBlur(2))
    a = np.asarray(im).astype(np.float64) / 255.0
    return a @ np.array([0.2126, 0.7152, 0.0722])


def corr(a, b):
    a = a - a.mean()
    b = b - b.mean()
    return float((a * b).sum() / np.sqrt((a * a).sum() * (b * b).sum() + 1e-12))


def main():
    worst = 1.0
    for name in sys.argv[1:]:
        rows = []
        tiles = []
        for k in LOOKS:
            pa = os.path.join(D, 'baked_%s_%s.png' % (name, k))
            pb = os.path.join(D, 'cube_%s_%s.png' % (name, k))
            if not (os.path.exists(pa) and os.path.exists(pb)):
                print('SKYCOMPARE %s %s MISSING' % (name, k))
                worst = -1.0
                continue
            a, b = lum(pa), lum(pb)
            c = corr(a, b)
            worst = min(worst, c)
            rows.append((k, c, float(np.abs(a - b).mean()), float(a.mean()), float(b.mean())))
            tiles.append((Image.open(pa).convert('RGB'), Image.open(pb).convert('RGB')))
        for k, c, mad, ma, mb in rows:
            print('SKYCOMPARE %-8s %-6s corr %.3f  mean_abs %.4f  mean baked %.4f cube %.4f' % (name, k, c, mad, ma, mb))
        # Control: every cube look against the next look's baked picture.
        ctl = []
        for i, k in enumerate(LOOKS):
            j = LOOKS[(i + 1) % len(LOOKS)]
            pa = os.path.join(D, 'baked_%s_%s.png' % (name, j))
            pb = os.path.join(D, 'cube_%s_%s.png' % (name, k))
            if os.path.exists(pa) and os.path.exists(pb):
                ctl.append(corr(lum(pa), lum(pb)))
        if ctl:
            print('SKYCOMPARE %-8s CONTROL mismatched looks corr max %.3f mean %.3f' % (name, max(ctl), np.mean(ctl)))
        if tiles:
            w, h = tiles[0][0].size
            s = 0.5
            tw, th = int(w * s), int(h * s)
            sheet = Image.new('RGB', (2 * tw, th * len(tiles)))
            for r, (a, b) in enumerate(tiles):
                sheet.paste(a.resize((tw, th)), (0, r * th))
                sheet.paste(b.resize((tw, th)), (tw, r * th))
            sheet.save(os.path.join(D, 'compare_%s.png' % name))
    print('SKYCOMPARE worst corr %.3f' % worst)


if __name__ == '__main__':
    main()
