#!/usr/bin/env python3
"""Scores the frame sequences tools/flame_flicker.gd captures. Needs numpy and Pillow.

Per condition: each frame's luma (Rec.709 weights on the 8-bit sRGB values, which is what the
display shows), shifted back by the drift the harness applied and blurred by a Gaussian of
sigma pixels (the compositor's resample into the lens mesh, then the eye), in one Fourier
multiply. A renderer with no aliasing and no resampling gives the same compensated frame every
time, so whatever still differs between frames is flicker:

  flicker  share of the lit mask's light that changes from one frame to the next, percent:
           sum |C_t - C_{t-1}| / sum C_t
  mad      the same change as a mean, in 8-bit code values
  tsd      per-pixel temporal standard deviation over the temporal mean, percent

The mask is every pixel whose compensated mean at sigma 1 is above 4/255, less a border the
drift could have wrapped round. The compensation is checked, not assumed: a phase correlation
of the first and last compensated frames gives the residual shift, and a condition whose
residual is over 0.1 px is flagged, because then the metric is scoring the warp.

  python3 tools/flicker_metric.py [.spike-out/flicker]
"""
import json
import os
import sys

import numpy as np
from PIL import Image

SIGMAS = (0.5, 1.0)
W709 = np.array([0.2126, 0.7152, 0.0722])
THRESH = 4.0 / 255.0
BORDER = 24


def luma(path):
    a = np.asarray(Image.open(path).convert('RGB'), dtype=np.float64) / 255.0
    return a @ W709


def compensate(img, shift, sigma):
    """img(x + shift), blurred by sigma: content the drift moved by +shift goes back."""
    h, w = img.shape
    fy = np.fft.fftfreq(h)[:, None]
    fx = np.fft.rfftfreq(w)[None, :]
    spec = np.fft.rfft2(img)
    spec = spec * np.exp(2j * np.pi * (fx * shift[0] + fy * shift[1]))
    if sigma > 0:
        spec = spec * np.exp(-2.0 * (np.pi * sigma) ** 2 * (fx * fx + fy * fy))
    return np.fft.irfft2(spec, s=(h, w))


def residual_shift(a, b):
    """Sub-pixel translation of b against a, by phase correlation and a parabolic peak."""
    fa = np.fft.fft2(a)
    fb = np.fft.fft2(b)
    r = fa * np.conj(fb)
    r /= np.abs(r) + 1e-12
    c = np.real(np.fft.ifft2(r))
    py, px = np.unravel_index(np.argmax(c), c.shape)
    h, w = c.shape

    def sub(cm, c0, cp):
        d = cm - 2 * c0 + cp
        return 0.0 if d == 0 else 0.5 * (cm - cp) / d

    dy = py + sub(c[(py - 1) % h, px], c[py, px], c[(py + 1) % h, px])
    dx = px + sub(c[py, (px - 1) % w], c[py, px], c[py, (px + 1) % w])
    if dy > h / 2:
        dy -= h
    if dx > w / 2:
        dx -= w
    return float(dx), float(dy)


def score_condition(cdir):
    meta = json.load(open(os.path.join(cdir, 'meta.json')))
    n = int(meta['frames'])
    frames = [luma(os.path.join(cdir, 'f%03d.png' % t)) for t in range(n)]
    shifts = meta['shifts']
    h, w = frames[0].shape
    out = {'name': meta['name'], 'gpu_ms': meta.get('gpu_ms'), 'sim_ms': meta.get('sim_ms'),
           'count': meta.get('count'), 'update_mods': sorted(set(meta.get('update_mods', [])))}

    ref = [compensate(f, s, 1.0) for f, s in zip(frames, shifts)]
    mean_ref = np.mean(ref, axis=0)
    mask = mean_ref > THRESH
    mask[:BORDER, :] = False
    mask[-BORDER:, :] = False
    mask[:, :BORDER] = False
    mask[:, -BORDER:] = False
    out['mask_px'] = int(mask.sum())
    out['mean_code'] = float(mean_ref[mask].mean() * 255.0) if mask.any() else 0.0
    out['residual_px'] = residual_shift(ref[0], ref[-1])
    # A transition changes the shape, so its first and last frames are not a translation.
    out['shape_moves'] = meta.get('settings', {}).get('morph') == 'phases'
    out['framing_px'] = float(meta.get('framing_px', 0.0))
    del ref
    # Sharpness of what stays: the compensated, unblurred temporal mean (under drift it averages
    # every sub-pixel phase, so per-frame speckle drops out and the kernel's own spread is left),
    # less itself blurred by sigma 1, over the mask, relative to the mean. Higher is crisper.
    mean0 = np.mean([compensate(f, s, 0.0) for f, s in zip(frames, shifts)], axis=0)
    soft = compensate(mean0, (0.0, 0.0), 1.0)
    out['crisp'] = float(np.abs(mean0 - soft)[mask].mean() / max(1e-9, mean0[mask].mean())) \
        if mask.any() else 0.0
    del mean0, soft

    static = all(abs(s[0]) < 1e-9 and abs(s[1]) < 1e-9 for s in shifts)
    sig = list(SIGMAS) + ([0.0] if static else [])
    for sigma in sig:
        prev = None
        absdiff = np.zeros((h, w))
        light = np.zeros((h, w))
        s1 = np.zeros((h, w))
        s2 = np.zeros((h, w))
        for f, s in zip(frames, shifts):
            c = compensate(f, s, sigma) if sigma > 0 or not static else f
            if prev is not None:
                absdiff += np.abs(c - prev)
                light += c
            s1 += c
            s2 += c * c
            prev = c
        m = s1 / n
        sd = np.sqrt(np.maximum(0.0, s2 / n - m * m))
        key = 's%.1f' % sigma
        out['flicker_' + key] = float(100.0 * absdiff[mask].sum() / max(1e-9, light[mask].sum()))
        out['mad_' + key] = float(255.0 * absdiff[mask].mean() / (n - 1))
        out['tsd_' + key] = float(100.0 * sd[mask].mean() / max(1e-9, m[mask].mean()))
        if sigma == 1.0:
            np.save(os.path.join(cdir, 'tsd_s1.npy'), np.where(mask, sd / np.maximum(m, 1e-6), 0.0))
    return out


def side_by_side(root, a, b, name, frame=0, crops=True):
    """Frame `frame` of two conditions, full and as 3x crops of a dense and a sparse patch."""
    pa = os.path.join(root, a, 'f%03d.png' % frame)
    pb = os.path.join(root, b, 'f%03d.png' % frame)
    if not (os.path.exists(pa) and os.path.exists(pb)):
        return []
    ia = Image.open(pa).convert('RGB')
    ib = Image.open(pb).convert('RGB')
    w, h = ia.size
    full = Image.new('RGB', (w * 2 + 8, h), (40, 40, 40))
    full.paste(ia, (0, 0))
    full.paste(ib, (w + 8, 0))
    paths = [os.path.join(root, '%s_full.png' % name)]
    full.save(paths[0])
    if not crops:
        return paths
    la = luma(pa)
    k = 96
    best = None
    tiles = []
    for y in range(BORDER, h - BORDER - k, k // 2):
        for x in range(BORDER, w - BORDER - k, k // 2):
            m = la[y:y + k, x:x + k].mean()
            tiles.append((m, x, y))
    tiles.sort()
    lit = [t for t in tiles if t[0] > THRESH * 2]
    if not lit:
        return paths
    picks = {'dense': lit[-1], 'sparse': lit[len(lit) // 4]}
    for label, (m, x, y) in picks.items():
        ca = ia.crop((x, y, x + k, y + k)).resize((k * 3, k * 3), Image.NEAREST)
        cb = ib.crop((x, y, x + k, y + k)).resize((k * 3, k * 3), Image.NEAREST)
        out = Image.new('RGB', (k * 6 + 8, k * 3), (40, 40, 40))
        out.paste(ca, (0, 0))
        out.paste(cb, (k * 3 + 8, 0))
        p = os.path.join(root, '%s_%s_x%d_y%d.png' % (name, label, x, y))
        out.save(p)
        paths.append(p)
    return paths


def heat(root, a, b, name):
    """Per-pixel temporal sd/mean at sigma 1, two conditions side by side, 0..50% as black..white."""
    pa = os.path.join(root, a, 'tsd_s1.npy')
    pb = os.path.join(root, b, 'tsd_s1.npy')
    if not (os.path.exists(pa) and os.path.exists(pb)):
        return None
    ha = np.clip(np.load(pa) / 0.5, 0, 1)
    hb = np.clip(np.load(pb) / 0.5, 0, 1)
    gap = np.full((ha.shape[0], 8), 0.15)
    img = np.concatenate([ha, gap, hb], axis=1)
    p = os.path.join(root, '%s_heat.png' % name)
    Image.fromarray((img * 255).astype(np.uint8), 'L').save(p)
    return p


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        os.path.dirname(os.path.abspath(__file__)), '..', '.spike-out', 'flicker')
    index = json.load(open(os.path.join(root, 'index.json')))
    results = []
    bad = 0
    hdr = '%-26s %8s %8s %8s %8s %7s %7s %6s %7s %11s %s' % (
        'condition', 'flk s0.5', 'flk s1', 'flk raw', 'mad s1', 'tsd s1', 'mean', 'crisp',
        'frame px', 'resid px', 'mods')
    print('FLICKERMETRIC ' + hdr)
    for name in index['conditions']:
        r = score_condition(os.path.join(root, name))
        results.append(r)
        rx, ry = r['residual_px']
        moved = not r['shape_moves'] and (abs(rx) > 0.1 or abs(ry) > 0.1)
        flag = moved or r['mask_px'] < 5000
        bad += flag
        print('FLICKERMETRIC %-26s %8.2f %8.2f %8s %8.2f %7.2f %7.1f %6.3f %7.2f %5.2f,%5.2f %s%s' % (
            name, r['flicker_s0.5'], r['flicker_s1.0'],
            '%.2f' % r['flicker_s0.0'] if 'flicker_s0.0' in r else '-',
            r['mad_s1.0'], r['tsd_s1.0'], r['mean_code'], r['crisp'], r['framing_px'],
            rx, ry, ','.join(str(m) for m in r['update_mods']),
            '  CHECK' if flag else ('  (shape moves)' if r['shape_moves'] else '')))
    json.dump(results, open(os.path.join(root, 'scores.json'), 'w'), indent=1)
    names = set(index['conditions'])
    for a, b, tag in [('d_frozen_legacy', 'd_frozen_new', 'ab_kernel'),
                      ('d_frozen_legacy', 'd_frozen_aa0', 'ab_aa0'),
                      ('d_frozen_legacy', 'd_frozen_aa1', 'ab_aa1'),
                      ('d_frozen_legacy_n060', 'd_frozen_new_n060', 'ab_kernel_n060'),
                      ('g_frozen_legacy', 'g_frozen_new', 'ab_galaxy'),
                      ('s_selfmorph_legacy', 's_selfmorph_new', 'ab_selfmorph')]:
        if a in names and b in names:
            for p in side_by_side(root, a, b, tag):
                print('FLICKERMETRIC still %s' % p)
            h = heat(root, a, b, tag)
            if h:
                print('FLICKERMETRIC heat %s' % h)
    print('FLICKERMETRIC %s checks=%d' % ('PASS' if bad == 0 else 'FAIL', bad))
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
