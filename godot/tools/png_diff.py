#!/usr/bin/env python3
"""PNGDIFF a b: mean absolute grey difference (0..1) and the fraction of sampled pixels
that differ by more than 2/255, so a refactor can prove it left the pixels alone."""
import sys
sys.path.insert(0, __file__.rsplit('/', 1)[0])
from png_stats import read_png
def grey(px, o, ch):
    return (px[o] * 0.299 + px[o+1] * 0.587 + px[o+2] * 0.114) if ch >= 3 else px[o]
def main(a, b):
    wa, ha, ca, pa = read_png(a); wb, hb, cb, pb = read_png(b)
    if (wa, ha) != (wb, hb):
        print("PNGDIFF size mismatch %dx%d vs %dx%d" % (wa, ha, wb, hb)); return
    n = wa * ha; tot = 0.0; changed = 0; cnt = 0
    for i in range(0, n, 3):
        d = abs(grey(pa, i * ca, ca) - grey(pb, i * cb, cb))
        tot += d; cnt += 1
        if d > 2.0: changed += 1
    print("PNGDIFF %s vs %s mean_abs=%.4f changed_frac=%.4f" % (a, b, tot / cnt / 255.0, changed / cnt))
if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
