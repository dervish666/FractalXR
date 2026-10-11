#!/usr/bin/env python3
"""Ring closure and splat shape for the LINES dumps written by tools/line_shot.sh.

For each dump of a LINES run (.spike-out/lines/<tag>.*), per slice plane:
  - links two visible particles when their splats overlap at 1.5 sigma along the ring,
    i.e. distance < 1.5 * (len_i + len_j), len = the drawn sigma along the ring;
  - an ENDPOINT is a particle with linked neighbours on only one side along its ring
    tangent (cross(normal, axis)): where a ring stops instead of continuing;
  - a component with no endpoints is a CLOSED loop; one with endpoints is an open arc.
Prints the share of ring particles in closed loops, gaps per plane, and the dust (tiny
components). Splat dumps get the shape stats only. A grid or cross dump (meta 'families'
2 or 3) is checked per family: particle i is in family i % families, sliced across the
axis bulb.glsl gives it, (axis + 2 f) % 3.

  python3 tools/line_check.py [.spike-out/lines] [tag ...]
"""
import json, os, sys
import numpy as np
from scipy.spatial import cKDTree
from scipy.sparse import coo_matrix
from scipy.sparse.csgraph import connected_components

SIGMA_LINK = 1.5
# splat.gdshader's constants, for the fill model.
MAX_STDDEV2, BLUR_PX2, MAX_PIXEL_RADIUS, SPLAT_THIN = 5.0, 0.3, 192.0, 0.18


def smoothstep(a, b, x):
    t = np.clip((x - a) / (b - a), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def family_axes(meta):
    """Per particle: its slice axis index, as bulb.glsl and splat.gdshader assign it."""
    n, fams = meta['count'], max(1, int(meta.get('families', 1)))
    return (meta['axis'] + 2 * (np.arange(n) % fams)) % 3


def cap_abs(meta):
    """The longest stroke sigma, in state units. Dumps before T-55 stored it in line widths."""
    if 'line_cap_abs' in meta:
        return meta['line_cap_abs']
    return meta.get('line_cap', 3.0) * meta['line_width']


def fill(meta, st, nm, bk):
    """Pixels rasterised per view: every drawn splat's quad, rebuilt with the vertex
    shader's own maths (axes, Jacobian, blur floor, clamps, culls). The quad is shaded in
    full before the fragment discards its corners, so its area is the fill cost. A model,
    not a GPU timer: it says how much fill each mode asks for, not how fast a GPU pays."""
    n = meta['count']
    hidden = nm[:, 3] > 0.5
    nl = nm[:, :3] / np.maximum(np.linalg.norm(nm[:, :3], axis=1), 1e-9)[:, None]
    fit, cov = meta['fit'], meta['coverage']
    bs = cov * fit
    ref = np.where(np.abs(nl[:, 2:3]) < 0.9, np.array([[0, 0, 1.0]]), np.array([[1.0, 0, 0]]))
    t1 = np.cross(nl, ref); t1 /= np.maximum(np.linalg.norm(t1, axis=1), 1e-9)[:, None]
    t2 = np.cross(nl, t1)
    e1 = t1 * bk[:, 0:1] + t2 * bk[:, 1:2]
    e2 = t2 * bk[:, 0:1] - t1 * bk[:, 1:2]
    l1 = bk[:, 2] * bs
    l2 = bk[:, 3] * bs
    a1, a2, a3 = e1 * l1[:, None], e2 * l2[:, None], nl * (SPLAT_THIN * l1)[:, None]
    ring_l = np.zeros(n)
    lines = meta.get('slices', 0) > 0
    if lines:
        axv = np.eye(3)[family_axes(meta)]
        ring = np.cross(nl, axv)
        ring_l = np.linalg.norm(ring, axis=1)
        on = ring_l > 1e-4
        T = ring / np.maximum(ring_l, 1e-9)[:, None]
        B = np.cross(nl, T)
        w = meta['line_width'] * fit
        L1 = np.minimum(bk[:, 2] * bs * meta['line_stretch'], cap_abs(meta) * fit)
        L2 = np.minimum(L1, w)
        a1 = np.where(on[:, None], T * L1[:, None], a1)
        a2 = np.where(on[:, None], B * L2[:, None], a2)
        a3 = np.where(on[:, None], nl * L2[:, None], a3)
    W, H = meta['viewport']
    focal = 0.5 * H / np.tan(np.radians(meta['fov_y']) * 0.5)
    out = {}
    for vname, (deg, offset, sc) in meta['views'].items():
        pl = (st[:, :3] - np.array(meta['center'])) * fit * sc
        c, s_ = np.cos(np.radians(deg)), np.sin(np.radians(deg))
        R = np.array([[1, 0, 0], [0, c, -s_], [0, s_, c]])
        vc = pl @ R.T + np.array(offset)
        A = [(a * sc) @ R.T for a in (a1, a2, a3)]
        cov3 = sum(np.einsum('ni,nj->nij', a, a) for a in A)
        iz = 1.0 / vc[:, 2]
        j1 = focal * iz
        j2x = -(j1 * vc[:, 0]) * iz
        j2y = -(j1 * vc[:, 1]) * iz
        r0 = np.stack([j1, np.zeros(n), j2x], 1)
        r1 = np.stack([np.zeros(n), j1, j2y], 1)
        ca = np.einsum('ni,nij,nj->n', r0, cov3, r0)
        cd = np.einsum('ni,nij,nj->n', r1, cov3, r1)
        cb = np.einsum('ni,nij,nj->n', r0, cov3, r1)
        det0 = ca * cd - cb * cb
        ca += BLUR_PX2; cd += BLUR_PX2
        det = ca * cd - cb * cb
        alpha = meta['opacity'] * np.sqrt(np.maximum(0, det0 / np.maximum(1e-12, det)))
        if lines:
            nv = nl @ R.T
            vn = vc / np.linalg.norm(vc, axis=1)[:, None]
            fade = smoothstep(-0.05, 0.3, np.sum(nv * -vn, axis=1)) * smoothstep(0.2, 0.45, ring_l)
            alpha = alpha * np.where(ring_l > 1e-4, fade, 1.0)
        avg = 0.5 * (ca + cd)
        dl = np.sqrt(np.maximum(0, avg * avg - det))
        s1 = np.minimum(MAX_PIXEL_RADIUS, np.sqrt(MAX_STDDEV2) * np.sqrt(avg + dl))
        s2 = np.minimum(MAX_PIXEL_RADIUS, np.sqrt(MAX_STDDEV2) * np.sqrt(np.maximum(0, avg - dl)))
        drawn = ~hidden & (vc[:, 2] < 0) & (alpha >= 0.002)
        out[vname] = (float(np.sum(4 * s1 * s2 * drawn)), int(drawn.sum()))
    return out


def load(d, tag):
    meta = json.load(open(os.path.join(d, tag + '.json')))
    n = meta['count']
    st = np.fromfile(os.path.join(d, tag + '.state.f32'), dtype='<f4').reshape(n, 4)
    nm = np.fromfile(os.path.join(d, tag + '.normal.f32'), dtype='<f4').reshape(n, 4)
    bk = np.fromfile(os.path.join(d, tag + '.bake.f16'), dtype='<f2').astype(np.float32).reshape(n, 4)
    return meta, st, nm, bk


def check(d, tag):
    meta, st, nm, bk = load(d, tag)
    vis = nm[:, 3] < 0.5
    axes = family_axes(meta) if meta.get('slices', 0) > 0 else np.full(meta['count'], meta['axis'])
    cov = meta['coverage']
    # What splat.gdshader draws: in LINES the major axis is the baked one times the stretch,
    # capped at line_cap line widths, and the minor is the fixed line width.
    s0 = bk[vis, 2] * cov * meta.get('line_stretch', 1.0)
    s1 = bk[vis, 3] * cov
    if meta.get('slices', 0) > 0:
        s0 = np.minimum(s0, cap_abs(meta))   # the shader's cap
        s1 = np.minimum(s0, meta['line_width'])
    h = meta['spacing']
    line = '%-18s visible %6d/%d  sigma major %.4f minor %.4f (median, state units)' % (
        tag, vis.sum(), meta['count'], np.median(s0), np.median(s1))
    if h > 0:
        line += '  = %.2f / %.2f of the ring spacing %.4f' % (
            np.median(s0) / h, np.median(s1) / h, h)
    print(line)
    if 'views' in meta:
        f = fill(meta, st, nm, bk)
        print('   fill model (px rasterised, %dx%d): ' % tuple(meta['viewport']) + '  '.join(
            '%s %.2fM (%dk splats)' % (v, px / 1e6, k // 1000) for v, (px, k) in f.items()))
    print('   DE residual at visible points: median %.5f, p90 %.5f (%.1f%% / %.1f%% of spacing)' % (
        meta['de_median'], meta['de_p90'],
        100 * meta['de_median'] / h if h > 0 else 0, 100 * meta['de_p90'] / h if h > 0 else 0))
    if h <= 0:
        return None
    fams = max(1, int(meta.get('families', 1)))
    out = {}
    for f in range(fams):
        sel = axes[vis] == (meta['axis'] + 2 * f) % 3
        r = closure(meta, st[vis][sel], nm[vis][sel], bk[vis][sel], s0[sel],
                    (meta['axis'] + 2 * f) % 3, 'xyz'[(meta['axis'] + 2 * f) % 3] if fams > 1 else None)
        out['xyz'[(meta['axis'] + 2 * f) % 3]] = r
    return out


def closure(meta, st, nm, bk, s0, ax, label):
    """Closure for one family of planes, all sliced across axis ax."""
    h = meta['spacing']
    other = [i for i in range(3) if i != ax]
    P = st[:, :3].astype(np.float64)
    N = nm[:, :3].astype(np.float64)
    axv = np.zeros(3); axv[ax] = 1.0
    T = np.cross(N, axv)
    tl = np.linalg.norm(T, axis=1)
    T = T / np.maximum(tl, 1e-9)[:, None]
    # How far the drawn splat's major axis is from the ring tangent: the bake measured it from
    # neighbours, the tangent is exact. Rebuild the splat's tangent frame as splat.gdshader does.
    nn = N / np.maximum(np.linalg.norm(N, axis=1), 1e-9)[:, None]
    ref = np.where(np.abs(nn[:, 2:3]) < 0.9, np.array([[0, 0, 1.0]]), np.array([[1.0, 0, 0]]))
    t1 = np.cross(nn, ref); t1 /= np.maximum(np.linalg.norm(t1, axis=1), 1e-9)[:, None]
    t2 = np.cross(nn, t1)
    e1 = t1 * bk[:, 0:1] + t2 * bk[:, 1:2]
    align = np.abs(np.sum(e1 * T, axis=1))
    pre = '   ' if label is None else '   [%s planes, %d visible points] ' % (label, len(P))
    print(pre + 'bake major axis vs ring tangent: median |cos| %.3f, %.0f%% within 25 deg' % (
        np.median(align), 100 * np.mean(align > np.cos(np.radians(25)))))
    pre = '   ' if label is None else '   [%s] ' % label

    k = np.floor(P[:, ax] / h + 1e-6).astype(np.int64)
    reach = np.maximum(s0, 1e-6)
    total = closed = arcs_pts = dust = 0
    endpoints = 0
    planes = 0
    comps_closed = comps_open = 0
    for kk in np.unique(k):
        idx = np.where(k == kk)[0]
        if idx.size < 2:
            dust += idx.size
            continue
        planes += 1
        Q = P[idx][:, other]
        tree = cKDTree(Q)
        rmax = SIGMA_LINK * 2 * reach[idx].max()
        pairs = tree.query_pairs(rmax, output_type='ndarray')
        if pairs.size:
            dd = np.linalg.norm(Q[pairs[:, 0]] - Q[pairs[:, 1]], axis=1)
            lim = SIGMA_LINK * (reach[idx][pairs[:, 0]] + reach[idx][pairs[:, 1]])
            pairs = pairs[dd < lim]
        m = idx.size
        if pairs.size:
            g = coo_matrix((np.ones(len(pairs)), (pairs[:, 0], pairs[:, 1])), shape=(m, m))
            nc, lab = connected_components(g, directed=False)
            # Sides along the tangent, per particle.
            Tq = T[idx][:, other]
            dv = Q[pairs[:, 1]] - Q[pairs[:, 0]]
            s_a = np.sum(dv * Tq[pairs[:, 0]], axis=1)      # j relative to i along i's tangent
            s_b = -np.sum(dv * Tq[pairs[:, 1]], axis=1)     # i relative to j along j's tangent
            plus = np.zeros(m, bool); minus = np.zeros(m, bool)
            np.logical_or.at(plus, pairs[:, 0], s_a > 0); np.logical_or.at(minus, pairs[:, 0], s_a < 0)
            np.logical_or.at(plus, pairs[:, 1], s_b > 0); np.logical_or.at(minus, pairs[:, 1], s_b < 0)
            endp = ~(plus & minus)
        else:
            nc, lab = m, np.arange(m)
            endp = np.ones(m, bool)
        sizes = np.bincount(lab, minlength=nc)
        ends = np.bincount(lab, weights=endp.astype(float), minlength=nc)
        small = sizes <= 3
        dust += sizes[small].sum()
        big = ~small
        closed += sizes[big & (ends == 0)].sum()
        arcs_pts += sizes[big & (ends > 0)].sum()
        comps_closed += int((big & (ends == 0)).sum())
        comps_open += int((big & (ends > 0)).sum())
        endpoints += int(endp[big[lab]].sum())
        total += m
    ring = closed + arcs_pts
    print(pre + 'planes %d  closed loops %d  open arcs %d  endpoints %d (%.2f per plane, %.2f%% of ring points)' % (
        planes, comps_closed, comps_open, endpoints, endpoints / max(1, planes),
        100 * endpoints / max(1, ring)))
    print(pre + 'ring points in closed loops %.1f%%  in open arcs %.1f%%  dust (<=3 linked) %.1f%% of visible' % (
        100 * closed / max(1, ring), 100 * arcs_pts / max(1, ring), 100 * dust / max(1, total)))
    return {'closed_share': closed / max(1, ring), 'endpoints_per_plane': endpoints / max(1, planes)}


def main():
    d = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), '..', '.spike-out', 'lines')
    tags = sys.argv[2:] or sorted(f[:-5] for f in os.listdir(d) if f.endswith('.json'))
    for t in tags:
        check(d, t)


if __name__ == '__main__':
    main()
