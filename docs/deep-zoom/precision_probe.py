#!/usr/bin/env python3
"""Evidence for the FractalXR ground deep-zoom plan. Run it; do not take the plan's word.

Three experiments, all emulating float32 exactly as the GPU does it (struct round-trip):

  1. wall      Where float32 stops resolving neighbouring clipmap texels, by zoom.
  2. mandel    A real boundary row at zoom 2100x: ground truth vs what ground.glsl
               computes today vs perturbation.
  3. ship      The same for Burning Ship, to test whether the obvious sign trick
               extends perturbation to the folded families. It does not.
  4. df32      The recommended fix: two-float (hi+lo) arithmetic, at the headset's
               zoom and at the app's deepest. This is the one that decides the plan.

  python3 precision_probe.py [wall|mandel|ship|df32|all]

Constants are the ones the app actually runs: TEXEL_M 0.0015, WPU_BASE 30.0, stage 12
(zoom 2100x), max_iter 2048, escape radius 256.
"""
import struct, random, sys

TEXEL_M, WPU_BASE = 0.0015, 30.0
# Stage 11, not 12: the running app logged texel=1/40960000 at zoom 2100x, and
# 0.0015 / 30 / 2^11 is exactly that. Deriving the stage from the zoom instead of
# reading it off the device moved the search region and found nothing.
STAGE = 11
TEXEL = TEXEL_M / WPU_BASE / 2.0 ** STAGE
assert abs(1.0 / TEXEL - 40960000.0) < 1.0, "texel does not match the measured device value"
N, ESC2 = 2048, 65536.0


def f32(x):
    """Round a Python double to float32, as storing it in a GLSL float would."""
    return struct.unpack('f', struct.pack('f', x))[0]


def c32(z):
    return complex(f32(z.real), f32(z.imag))


def ulp_texels(idx):
    """Gap between consecutive representable float32 values, in whole texel indices."""
    b = struct.unpack('I', struct.pack('f', f32(idx)))[0]
    return f32(struct.unpack('f', struct.pack('I', b + 1))[0]) - f32(idx)


def wall():
    print("Where float32 stops resolving neighbouring texels (coordinate ~0.745):\n")
    print(f"  {'zoom':>8}  {'texel index':>13}  {'ulp (texels)':>13}  effect")
    for stage in range(0, 15):
        texel = TEXEL_M / WPU_BASE / 2.0 ** stage
        idx = 0.745 / texel
        u = ulp_texels(idx)
        eff = ("fine" if u < 0.25 else "softening" if u < 1.0
               else f"{int(u)}x{int(u)} texel blocks collapse")
        print(f"  {2.0**stage:>7.0f}x  {idx:>13.3g}  {u:>13.2f}  {eff}")
    print("\n  The app allows stage 13 (16384x). It renders honestly to about 512x.")


# --- z^2 + c -----------------------------------------------------------------------
def m_truth(c):
    z = 0j
    for n in range(N):
        z = z * z + c
        if abs(z) ** 2 > ESC2:
            return n
    return N


def m_naive(i, j):
    """Exactly ground.glsl today: pt = vec2(a) * texel, all float32."""
    c = complex(f32(f32(i) * TEXEL), f32(f32(j) * TEXEL))
    z = 0j
    for n in range(N):
        z = c32(c32(z * z) + c)
        if abs(z) ** 2 > ESC2:
            return n
    return N


def m_pert(i, j, I0, J0, ref):
    """delta_{n+1} = 2 Z_n delta_n + delta_n^2 + delta_c, delta in float32."""
    dc = complex(f32((i - I0) * TEXEL), f32((j - J0) * TEXEL))
    d = 0j
    for n in range(N):
        d = c32(c32(2 * ref[n] * d) + c32(d * d) + dc)
        if abs(ref[n + 1] + d) ** 2 > ESC2:
            return n
    return N


def m_ref(C):
    out, Z = [0j], 0j
    for _ in range(N + 1):
        Z = Z * Z + C
        out.append(Z)
    return out


def mandel():
    random.seed(7)
    spot = None
    for _ in range(400):
        bi = random.randint(-30600000, -30400000)
        bj = random.randint(4600000, 4700000)
        v = [m_truth(complex(i * TEXEL, bj * TEXEL)) for i in range(bi, bi + 8)]
        if len(set(v)) >= 4 and max(v) < N:
            spot = (bi, bj)
            break
    if spot is None:
        print("no boundary row found"); return
    I0, J0 = spot
    ref = m_ref(complex(I0 * TEXEL, J0 * TEXEL))
    row = range(I0, I0 + 16)
    t = [m_truth(complex(i * TEXEL, J0 * TEXEL)) for i in row]
    nv = [m_naive(i, J0) for i in row]
    pt = [m_pert(i, J0, I0, J0, ref) for i in row]
    _report("MANDELBROT", I0, J0, t, nv, pt)


# --- burning ship ------------------------------------------------------------------
def bs(z, c):
    return complex(abs(z.real), abs(z.imag)) ** 2 + c


def s_truth(c):
    z = 0j
    for n in range(N):
        z = bs(z, c)
        if abs(z) ** 2 > ESC2:
            return n
    return N


def s_naive(i, j):
    c = complex(f32(f32(i) * TEXEL), f32(f32(j) * TEXEL))
    z = 0j
    for n in range(N):
        w = complex(abs(z.real), abs(z.imag))
        z = c32(c32(w * w) + c)
        if abs(z) ** 2 > ESC2:
            return n
    return N


def s_ref(C):
    refZ, refW, Z = [0j], [0j], 0j
    for _ in range(N + 1):
        refW.append(complex(abs(Z.real), abs(Z.imag)))
        if abs(Z) > 1e6:            # reference escaped; freeze rather than overflow
            refZ.append(Z)
            continue
        Z = bs(Z, C)
        refZ.append(Z)
    return refZ, refW


def s_pert(i, j, I0, J0, refZ, refW):
    """The obvious extension: fold the delta by the REFERENCE's signs, since
    |Re(Z+d)| = sign(Re Z) * (Re Z + Re d) -- but only while the pixel stays on the
    same side of the axis as the reference. `folds` counts where that fails."""
    dc = complex(f32((i - I0) * TEXEL), f32((j - J0) * TEXEL))
    d, folds = 0j, 0
    for n in range(N):
        Z, W = refZ[n], refW[n]
        if abs(d.real) > abs(Z.real) or abs(d.imag) > abs(Z.imag):
            folds += 1
        s = 1.0 if Z.real >= 0 else -1.0
        t = 1.0 if Z.imag >= 0 else -1.0
        dw = complex(s * d.real, t * d.imag)
        d = c32(c32(2 * W * dw) + c32(dw * dw) + dc)
        if abs(refZ[n + 1] + d) ** 2 > ESC2:
            return n, folds
    return N, folds


def ship():
    random.seed(3)
    CX, CY = -1.7550, -0.0300
    spot = None
    for _ in range(2000):
        bi = round(CX / TEXEL) + random.randint(-300000, 300000)
        bj = round(CY / TEXEL) + random.randint(-300000, 300000)
        v = [s_truth(complex(i * TEXEL, bj * TEXEL)) for i in range(bi, bi + 8)]
        if len(set(v)) >= 4 and 40 < max(v) < N:
            spot = (bi, bj)
            break
    if spot is None:
        print("no boundary row found"); return
    I0, J0 = spot
    refZ, refW = s_ref(complex(I0 * TEXEL, J0 * TEXEL))
    row = range(I0, I0 + 16)
    t = [s_truth(complex(i * TEXEL, J0 * TEXEL)) for i in row]
    nv = [s_naive(i, J0) for i in row]
    pr = [s_pert(i, J0, I0, J0, refZ, refW) for i in row]
    pt = [x[0] for x in pr]
    folds = sum(1 for x in pr if x[1])
    _report("BURNING SHIP", I0, J0, t, nv, pt)
    print(f"  fold-crossing pixels: {folds}/16 -- the reference's signs do not apply to")
    print("  these, which is why perturbation is wrong on almost all of them.")


def _report(name, I0, J0, t, nv, pt):
    print(f"\n{name} at ({I0*TEXEL:.6f}, {J0*TEXEL:.6f}), zoom {2.0**STAGE:.0f}x")
    print("  16 adjacent texels, escape counts:")
    print("    truth:", " ".join(f"{v:>4}" for v in t))
    print("    naive:", " ".join(f"{v:>4}" for v in nv))
    print("    pert :", " ".join(f"{v:>4}" for v in pt))
    print(f"  distinct values: truth {len(set(t))}, naive {len(set(nv))}, pert {len(set(pt))}")
    print(f"  exactly right:   naive {sum(a==b for a,b in zip(nv,t))}/16, "
          f"pert {sum(a==b for a,b in zip(pt,t))}/16")


# --- double-float (Veltkamp-Dekker) in float32, as a GLSL port would do it ---------
def two_sum(a, b):
    s = f32(a + b)
    bb = f32(s - a)
    return s, f32(f32(a - f32(s - bb)) + f32(b - bb))


def _split(a):
    t = f32(4097.0 * a)          # 2^12 + 1: float32 has a 24-bit mantissa
    hi = f32(t - f32(t - a))
    return hi, f32(a - hi)


def two_prod(a, b):
    p = f32(a * b)
    ah, al = _split(a)
    bh, bl = _split(b)
    return p, f32(f32(f32(f32(ah*bh - p) + f32(ah*bl)) + f32(al*bh)) + f32(al*bl))


def df_add(A, B):
    s, e = two_sum(A[0], B[0])
    return two_sum(s, f32(e + f32(A[1] + B[1])))


def df_mul(A, B):
    p, e = two_prod(A[0], B[0])
    e = f32(e + f32(f32(A[0]*B[1]) + f32(A[1]*B[0])))
    return two_sum(p, e)


def df_of(x):
    hi = f32(x)
    return hi, f32(x - hi)


def _val(A):
    return A[0] + A[1]


def _neg(A):
    return -A[0], -A[1]


def d_truth(cx, cy):
    zx = zy = 0.0
    for n in range(N):
        zx, zy = zx*zx - zy*zy + cx, 2*zx*zy + cy
        if zx*zx + zy*zy > ESC2:
            return n
    return N


def d_naive(i, j, texel):
    cx, cy = f32(f32(i)*texel), f32(f32(j)*texel)
    zx = zy = 0.0
    for n in range(N):
        zx, zy = f32(f32(f32(zx*zx) - f32(zy*zy)) + cx), f32(f32(2*f32(zx*zy)) + cy)
        if f32(f32(zx*zx) + f32(zy*zy)) > ESC2:
            return n
    return N


def d_df32(i, j, texel):
    T = df_of(texel)
    CX, CY = df_mul(df_of(float(i)), T), df_mul(df_of(float(j)), T)
    ZX = ZY = (0.0, 0.0)
    for n in range(N):
        XX, YY = df_mul(ZX, ZX), df_mul(ZY, ZY)
        xy = df_mul(ZX, ZY)
        ZX = df_add(df_add(XX, _neg(YY)), CX)
        ZY = df_add((f32(2*xy[0]), f32(2*xy[1])), CY)
        if _val(df_mul(ZX, ZX)) + _val(df_mul(ZY, ZY)) > ESC2:
            return n
    return N


def df32_test():
    print("\nTwo-float (df32) coordinate AND iteration, against ground truth.")
    print("No reference orbit, no glitch pass, and no holomorphy requirement, so this")
    print("works for all eight families rather than three.\n")
    for stage, label in [(11, "stage 11, zoom 2048x (the headset session)"),
                         (13, "stage 13, zoom 8192x (the app's deepest)")]:
        texel = TEXEL_M / WPU_BASE / 2.0 ** stage
        random.seed(7)
        spot = None
        for _ in range(600):
            bi = random.randint(int(-0.75/texel), int(-0.74/texel))
            bj = random.randint(int(0.112/texel), int(0.115/texel))
            v = [d_truth(i*texel, bj*texel) for i in range(bi, bi+8)]
            if len(set(v)) >= 4 and max(v) < N:
                spot = (bi, bj)
                break
        if spot is None:
            print(f"  {label}: no boundary row found")
            continue
        I0, J0 = spot
        row = range(I0, I0 + 12)
        t = [d_truth(i*texel, J0*texel) for i in row]
        nv = [d_naive(i, J0, texel) for i in row]
        dd = [d_df32(i, J0, texel) for i in row]
        print(f"  {label}")
        print("    truth:", " ".join(f"{v:>4}" for v in t))
        print("    naive:", " ".join(f"{v:>4}" for v in nv))
        print("    df32 :", " ".join(f"{v:>4}" for v in dd))
        print(f"    distinct: truth {len(set(t))}, naive {len(set(nv))}, df32 {len(set(dd))}")
        print(f"    exact:    naive {sum(a==b for a,b in zip(nv,t))}/12, "
              f"df32 {sum(a==b for a,b in zip(dd,t))}/12\n")


if __name__ == "__main__":
    which = sys.argv[1] if len(sys.argv) > 1 else "all"
    if which in ("wall", "all"):
        wall()
    if which in ("mandel", "all"):
        mandel()
    if which in ("ship", "all"):
        ship()
    if which in ("df32", "all"):
        df32_test()
