#!/usr/bin/env python3
"""Turn an offline sky bake into a SKY preset.

tools/sky_bake.sh bake writes the live bake's float equirect at 8192 x 4096 and many times the
samples (.spike-out/skies/<name>.rgbah, RGBA half, row 0 = up, -Z forward mid-row). This
resamples it onto the six faces of a cube, divides by the gain (texels above it clip),
sRGB-encodes it, and writes one 3 x 2 image Godot imports as a compressed
Cubemap with mipmaps (art/skies/<name>.webp + .import), and its entry in art/skies/skies.json.

Why a cube: an equirect with mipmaps picks its mip from screen derivatives, and both the pole
(where u races) and the wrap column (where u jumps from 1 to 0) pick the smallest mip, a blur
at the zenith and a one-pixel seam down the back. A cubemap filters across its faces in the
hardware and has neither. It also spends its texels more evenly.

Faces are laid out in Godot's 3x2 order (+X -X +Y / -Y +Z -Z), each face oriented as the
Vulkan cube-map face table has it (s right, t down):
  +X (1, -t, -s)   -X (-1, -t, s)   +Y (s, 1, t)   -Y (s, -1, -t)   +Z (s, -t, 1)   -Z (-s, -t, -1)
tools/sky_bake.sh preview renders the result through the app's sky shader beside the live
equirect from the same directions; a face in the wrong place or the wrong way round shows.

  python3 tools/sky_cube.py NAME [--face 2048] [--gain 1] [--ss 3] [--quality 92]

The gain: the curve puts these skies' mean at 0.03-0.04 and their 99.9th percentile at
0.44-0.69; 0.00-0.03% of texels exceed 1 (Ember, Nautilus, Geode at 8192). So 1 clips only
sparks the 10-bit eye buffer and ACES would have flattened anyway, and spends all 8 bits
below it; 2 would halve the steps in the faint filaments that make the sky.
"""
import argparse, json, os, sys, time
import numpy as np
from PIL import Image

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
SRC = os.path.join(ROOT, '.spike-out', 'skies')
DST = os.path.join(ROOT, 'art', 'skies')
IMPORT = """[remap]

importer="cubemap_texture"
type="CompressedCubemap"

[deps]

source_file="res://art/skies/{file}"

[params]

compress/mode=2
compress/high_quality=false
compress/lossy_quality=0.7
compress/hdr_compression=1
compress/channel_pack=0
mipmaps/generate=true
mipmaps/limit=-1
slices/arrangement=2
"""


def face_dirs(face, s, t):
    """Unnormalised directions for face coordinates s, t in [-1, 1] (s right, t down)."""
    one = np.ones_like(s)
    return {
        0: (one, -t, -s), 1: (-one, -t, s), 2: (s, one, t),
        3: (s, -one, -t), 4: (s, -t, one), 5: (-s, -t, -one),
    }[face]


def sample(eq, x, y, z):
    """Bilinear lookup of the equirect at directions (x, y, z), as flame_sky.gdshader maps it."""
    h, w, _ = eq.shape
    r = np.sqrt(x * x + y * y + z * z)
    u = np.arctan2(x, -z) * (0.5 / np.pi) + 0.5
    v = np.arccos(np.clip(y / r, -1.0, 1.0)) / np.pi
    fx = u * w - 0.5
    fy = np.clip(v * h - 0.5, 0.0, h - 1.0)   # the shader clamps v to the texel centres too
    x0 = np.floor(fx).astype(np.int64)
    y0 = np.floor(fy).astype(np.int64)
    ax = (fx - x0)[..., None]
    ay = (fy - y0)[..., None]
    x1 = (x0 + 1) % w
    x0 = x0 % w
    y1 = np.minimum(y0 + 1, h - 1)
    top = eq[y0, x0] * (1 - ax) + eq[y0, x1] * ax
    bot = eq[y1, x0] * (1 - ax) + eq[y1, x1] * ax
    return top * (1 - ay) + bot * ay


def bake_face(eq, face, n, ss):
    """One face, n x n, each texel the mean of ss x ss bilinear samples over its footprint."""
    out = np.zeros((n, n, 3), np.float32)
    rows = max(1, 2 ** 22 // (n * ss * ss))   # bound the working set to about 4M samples
    for r0 in range(0, n, rows):
        r1 = min(n, r0 + rows)
        acc = np.zeros((r1 - r0, n, 3), np.float32)
        for j in range(ss):
            for i in range(ss):
                cs = (np.arange(n) + (i + 0.5) / ss) / n * 2.0 - 1.0
                ct = (np.arange(r0, r1) + (j + 0.5) / ss) / n * 2.0 - 1.0
                s, t = np.meshgrid(cs, ct)
                acc += sample(eq, *face_dirs(face, s, t))
        out[r0:r1] = acc / (ss * ss)
    return out


def srgb8(lin):
    lin = np.clip(lin, 0.0, 1.0)
    enc = np.where(lin <= 0.0031308, lin * 12.92, 1.055 * np.power(lin, 1.0 / 2.4) - 0.055)
    return np.clip(np.round(enc * 255.0), 0, 255).astype(np.uint8)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('name')
    ap.add_argument('--face', type=int, default=2048)
    ap.add_argument('--gain', type=float, default=1.0)
    ap.add_argument('--ss', type=int, default=3)
    ap.add_argument('--quality', type=int, default=92, help='WebP quality; 101 = lossless')
    a = ap.parse_args()
    key = a.name.lower()
    meta = json.load(open(os.path.join(SRC, key + '.json')))
    w, h = meta['width'], meta['height']
    t0 = time.time()
    eq = np.fromfile(os.path.join(SRC, key + '.rgbah'), dtype='<f2').reshape(h, w, 4)[..., :3].astype(np.float32)
    if not np.isfinite(eq).all():
        sys.exit('sky_cube: %s has non-finite texels' % key)
    clip = float(np.mean(np.max(eq, axis=2) > a.gain))
    n = a.face
    atlas = np.zeros((2 * n, 3 * n, 3), np.uint8)
    for f in range(6):
        lin = bake_face(eq, f, n, a.ss)
        atlas[(f // 3) * n:(f // 3 + 1) * n, (f % 3) * n:(f % 3 + 1) * n] = srgb8(lin / a.gain)
    os.makedirs(DST, exist_ok=True)
    fname = key + '.webp'
    path = os.path.join(DST, fname)
    img = Image.fromarray(atlas, 'RGB')
    if a.quality > 100:
        img.save(path, 'WEBP', lossless=True, method=6)
    else:
        img.save(path, 'WEBP', quality=a.quality, method=6)
    imp = path + '.import'
    if not os.path.exists(imp):
        open(imp, 'w').write(IMPORT.format(file=fname))
    man_path = os.path.join(DST, 'skies.json')
    man = json.load(open(man_path)) if os.path.exists(man_path) else []
    man = [e for e in man if e.get('file') != fname]
    man.append({'name': meta['name'], 'file': fname, 'gain': a.gain, 'face': n,
                'source': '%dx%d equirect, %dM samples' % (w, h, meta['samples'] // 1000000)})
    json.dump(man, open(man_path, 'w'), indent=1)
    print('sky_cube %s: %s %dx%d, %.2f MB, %.2f%% of equirect texels above the gain, %.0f s' % (
        meta['name'], fname, 3 * n, 2 * n, os.path.getsize(path) / 1048576.0, 100 * clip, time.time() - t0))


if __name__ == '__main__':
    main()
