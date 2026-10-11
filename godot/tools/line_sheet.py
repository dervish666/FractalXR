#!/usr/bin/env python3
"""Side-by-side contact sheet of tools/line_shot.sh PNGs: one row per view (side, 45,
axial), one column per mode, cropped to the bulb. Labels are drawn in, so a sheet read
on its own still says what is what.

  python3 tools/line_sheet.py <bulb> <out.png> [mode ...]     e.g. classic sheet.png splats lines48
"""
import os, sys
from PIL import Image, ImageDraw

D = os.path.join(os.path.dirname(__file__), '..', '.spike-out', 'lines')
VIEWS = [('side', 'side: axis 90 deg off view'), ('45', 'axis 45 deg off view'), ('axial', 'axial: down the axis'),
         ('toy', 'toy: hand-held, 30 deg down')]


def main():
    bulb, out = sys.argv[1], sys.argv[2]
    modes = sys.argv[3:] or ['splats', 'lines24', 'lines48', 'lines96']
    first = Image.open(os.path.join(D, '%s_%s_%s.png' % (bulb, modes[0], 'side')))
    w, h = first.size
    c = min(w, h) * 0.5
    box = (int(w / 2 - c), int(h / 2 - c - 0.07 * h), int(w / 2 + c), int(h / 2 + c - 0.07 * h))
    tw = box[2] - box[0]
    sheet = Image.new('RGB', (tw * len(modes), tw * len(VIEWS)), 'black')
    dr = ImageDraw.Draw(sheet)
    for ci, m in enumerate(modes):
        for ri, (v, label) in enumerate(VIEWS):
            p = os.path.join(D, '%s_%s_%s.png' % (bulb, m, v))
            if not os.path.exists(p):
                continue
            sheet.paste(Image.open(p).convert('RGB').crop(box), (ci * tw, ri * tw))
            dr.text((ci * tw + 8, ri * tw + 8), '%s %s | %s' % (bulb, m, label), fill=(255, 255, 255))
    sheet.save(out)
    print(out, sheet.size)


if __name__ == '__main__':
    main()
