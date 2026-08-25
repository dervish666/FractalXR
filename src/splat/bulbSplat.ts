/**
 * Mandelbulb → Gaussian splats, in the browser.
 *
 * A faithful port of `.spike/bulb-to-splat.mjs`, which was written as an offline Node script.
 * Moving it into the page is what lets the splat viewer ship without a 26MB `.ply` in the
 * repo and in the deploy: the whole premise of this spike is that FractalXR already computes
 * the fractal as an explicit point cloud, so there was never a reason to bake the result to a
 * file and download it back.
 *
 * The maths is unchanged from the validated script. What changed is Node's `Buffer` for a
 * `DataView`, and the sampling loop being sliceable so it can run across several workers —
 * one point costs about 0.4ms, so 200k of them is a minute and a half on one thread.
 */

// ---- Mandelbulb params (a classic power-8 bulb) ----------------------------
export const POWER = 8
export const BOUND = 1.25
/**
 * Cost knobs. Sampling is by far the dominant cost of the whole pipeline, and inside it the
 * Newton projection dominates: every step needs a distance estimate plus a 4-tap gradient,
 * so a step is 5 DE evaluations and a DE evaluation is BULB_ITERS of trigonometry.
 *
 * `fine` is the original offline script's settings. `fast` projects with a shallower DE and
 * reuses each gradient for two steps, which is fine because Newton is converging on a surface
 * rather than tracking a curve — and then re-tests the result at full depth so accepted points
 * are exactly as accurate as before, just found more cheaply.
 */
export type Quality = 'fast' | 'fine'
interface Knobs { iters: number; projIters: number; newton: number; gradEvery: number }
const KNOBS: Record<Quality, Knobs> = {
  fine: { iters: 16, projIters: 16, newton: 14, gradEvery: 1 },
  fast: { iters: 16, projIters: 10, newton: 10, gradEvery: 2 },
}
const BULB_ITERS = 16 // the live engine uses 8; offline we go deeper for finer surface filigree
const GEPS = 0.0012 * BOUND
const SURF_EPS = 0.0025 * BOUND
const GRAD_MIN = 0.2 // reject flat interior; a real surface has |grad d| ~ 1

/** Rainbow palette in linear RGB — full hue travel, for iridescent orbit-trap colour. */
const PALETTE: number[][] = [
  [0.5, 0.0, 0.7],
  [0.0, 0.35, 1.0],
  [0.0, 0.92, 0.35],
  [1.0, 0.88, 0.0],
  [1.0, 0.12, 0.15],
]

/** mulberry32 — deterministic, and seedable per worker so slices do not duplicate points. */
function makeRng(seed: number): () => number {
  let s = seed >>> 0
  return () => {
    s = (s + 0x6d2b79f5) >>> 0
    let t = s
    t = Math.imul(t ^ (t >>> 15), t | 1)
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

interface DE {
  d: number
  trapR: number
  trapY: number
}

/** Mandelbulb distance estimate — a verbatim port of the engine's `mandelbulbDE`. */
function bulbDE(px: number, py: number, pz: number, iters = BULB_ITERS): DE {
  let zx = px
  let zy = py
  let zz = pz
  let dr = 1.0
  let r = Math.hypot(zx, zy, zz)
  let trapR = 1e10
  let trapY = 1e10
  for (let i = 0; i < iters; i++) {
    r = Math.hypot(zx, zy, zz)
    if (r > 2.0) break
    const rr = Math.max(r, 1e-9)
    let theta = Math.acos(Math.max(-1, Math.min(1, zz / rr)))
    let phi = Math.atan2(zy, zx)
    dr = Math.pow(rr, POWER - 1) * POWER * dr + 1
    const zr = Math.pow(rr, POWER)
    theta *= POWER
    phi *= POWER
    const st = Math.sin(theta)
    zx = zr * st * Math.cos(phi) + px
    zy = zr * st * Math.sin(phi) + py
    zz = zr * Math.cos(theta) + pz
    const lz = Math.hypot(zx, zy, zz)
    if (lz < trapR) trapR = lz
    if (Math.abs(zy) < trapY) trapY = Math.abs(zy)
  }
  return { d: (0.5 * Math.log(Math.max(r, 1e-9)) * r) / Math.max(dr, 1e-6), trapR, trapY }
}

/**
 * Tetrahedral 4-tap gradient. The 4-tap magnitude is about 4·eps·|grad d|, so it gets divided
 * back out — `grad` is then in true |grad d| units, which is what GRAD_MIN is expressed in.
 */
function deGrad(px: number, py: number, pz: number, iters = BULB_ITERS): { nx: number; ny: number; nz: number; grad: number } {
  const d1 = bulbDE(px + GEPS, py - GEPS, pz - GEPS, iters).d
  const d2 = bulbDE(px - GEPS, py - GEPS, pz + GEPS, iters).d
  const d3 = bulbDE(px - GEPS, py + GEPS, pz - GEPS, iters).d
  const d4 = bulbDE(px + GEPS, py + GEPS, pz + GEPS, iters).d
  const gx = d1 - d2 - d3 + d4
  const gy = -d1 - d2 + d3 + d4
  const gz = -d1 + d2 - d3 + d4
  const mag = Math.hypot(gx, gy, gz) || 1e-9
  return { nx: gx / mag, ny: gy / mag, nz: gz / mag, grad: mag / (4 * GEPS) }
}

export interface Slice {
  /** xyz triples of accepted surface points */
  xyz: Float32Array
  /** raw orbit-trap scalar per point, equalised to colour later across the whole set */
  trap: Float32Array
  count: number
  attempts: number
}

/**
 * Sample `want` points on the bulb surface: scatter into the bounding ball, Newton-project on
 * to DE=0, reject anything that did not land on a real surface. Independent per point, which
 * is what makes it safe to split across workers.
 */
export function sampleSlice(
  want: number,
  seed: number,
  quality: Quality = 'fast',
  onProgress?: (done: number) => void,
): Slice {
  const K = KNOBS[quality]
  const rnd = makeRng(seed)
  const xyz = new Float32Array(want * 3)
  const trap = new Float32Array(want)
  let n = 0
  let attempts = 0
  const maxAttempts = want * 60
  let nextTick = Math.max(1, Math.floor(want / 40))

  while (n < want && attempts < maxAttempts) {
    attempts++
    // uniform point in a ball of radius BOUND (spherically symmetric — no boxy bias)
    const u = rnd() * 2 - 1
    const phi = rnd() * 6.2831853
    const rad = Math.cbrt(rnd()) * BOUND
    const st = Math.sqrt(Math.max(0, 1 - u * u))
    let px = rad * st * Math.cos(phi)
    let py = rad * st * Math.sin(phi)
    let pz = rad * u

    let nx = 0
    let ny = 0
    let nz = 1
    for (let s = 0; s < K.newton; s++) {
      const de = bulbDE(px, py, pz, K.projIters)
      if (s % K.gradEvery === 0) {
        const g = deGrad(px, py, pz, K.projIters)
        nx = g.nx
        ny = g.ny
        nz = g.nz
      }
      px -= nx * de.d
      py -= ny * de.d
      pz -= nz * de.d
    }
    // re-test at FULL depth, so an accepted point is exactly as accurate as the fine path
    const de = bulbDE(px, py, pz)
    const g = deGrad(px, py, pz)
    if (Math.abs(de.d) > SURF_EPS || g.grad < GRAD_MIN) continue // off-surface / flat interior
    if (px * px + py * py + pz * pz > BOUND * BOUND * 1.3) continue

    trap[n] = de.trapR * 0.7 + de.trapY * 0.5
    xyz[n * 3] = px
    xyz[n * 3 + 1] = py
    xyz[n * 3 + 2] = pz
    n++
    if (onProgress && n >= nextTick) {
      onProgress(n)
      nextTick = n + Math.max(1, Math.floor(want / 40))
    }
  }
  return { xyz, trap, count: n, attempts }
}

const SH_C0 = 0.28209479177387814
const KNN = 14
const CAP = 160
const A_SCALE = 0.9
const MIN_S = 0.0007
const MAX_S = 0.0075
const THIN = 0.16 // smaller splats keep the detail from being blurred away
const ALPHA = 0.22 // bulbs read crisper than flames, so a touch more opacity holds the surface

const paletteLinear = (c: number): number[] => {
  const segs = PALETTE.length - 1
  const f = Math.max(0, Math.min(1, c)) * segs
  const i0 = Math.min(segs, Math.floor(f))
  const i1 = Math.min(segs, i0 + 1)
  const lf = f - i0
  const a = PALETTE[i0]
  const b = PALETTE[i1]
  return [a[0] + (b[0] - a[0]) * lf, a[1] + (b[1] - a[1]) * lf, a[2] + (b[2] - a[2]) * lf]
}
const lin2srgb = (x: number): number => (x <= 0.0031308 ? 12.92 * x : 1.055 * Math.pow(x, 1 / 2.4) - 0.055)

/**
 * Merged points → a binary 3DGS `.ply`, which is what Spark parses.
 *
 * Two things here are not obvious and both came out of the original spike:
 *
 * - **Colour is rank-equalised, not scaled.** The raw orbit trap clusters in a narrow band, so
 *   a linear map uses a sliver of the palette. Sorting and taking each point's percentile
 *   spends the whole gradient and gives the iridescent look.
 * - **Never a global splat size.** Each Gaussian is sized and oriented from the covariance of
 *   its k nearest neighbours, so it becomes a flat oriented ellipsoid lying in the surface.
 *   A uniform sphere per point blurs the filigree and kills the GPU in dense regions.
 */
export function buildPly(
  xyz: Float32Array,
  trapRaw: Float32Array,
  n: number,
  onProgress?: (frac: number, label: string) => void,
): Uint8Array {
  onProgress?.(0, 'colouring')

  // rank-equalise the orbit-trap scalar so it uses the FULL palette
  const rgbLin = new Float32Array(n * 3)
  const sorted = Float32Array.from(trapRaw.subarray(0, n)).sort()
  for (let i = 0; i < n; i++) {
    const v = trapRaw[i]
    let lo = 0
    let hi = n
    while (lo < hi) {
      const mid = (lo + hi) >> 1
      if (sorted[mid] < v) lo = mid + 1
      else hi = mid
    }
    const rgb = paletteLinear(n > 1 ? lo / (n - 1) : 0.5)
    rgbLin[i * 3] = rgb[0]
    rgbLin[i * 3 + 1] = rgb[1]
    rgbLin[i * 3 + 2] = rgb[2]
  }

  // centre and normalise into a ~2-unit cube
  let cx = 0
  let cy = 0
  let cz = 0
  for (let i = 0; i < n; i++) {
    cx += xyz[i * 3]
    cy += xyz[i * 3 + 1]
    cz += xyz[i * 3 + 2]
  }
  cx /= n
  cy /= n
  cz /= n
  let ext = 0
  for (let i = 0; i < n; i++) {
    ext = Math.max(ext, Math.abs(xyz[i * 3] - cx), Math.abs(xyz[i * 3 + 1] - cy), Math.abs(xyz[i * 3 + 2] - cz))
  }
  const norm = 1 / (ext || 1)
  for (let i = 0; i < n; i++) {
    xyz[i * 3] = (xyz[i * 3] - cx) * norm
    xyz[i * 3 + 1] = (xyz[i * 3 + 1] - cy) * norm
    xyz[i * 3 + 2] = (xyz[i * 3 + 2] - cz) * norm
  }

  // ---- per-point anisotropic Gaussians from local-neighbourhood PCA --------
  onProgress?.(0.2, 'fitting gaussians')
  const G = 128
  const cellW = 2 / G
  const clampCell = (v: number): number => Math.min(G - 1, Math.max(0, Math.floor((v + 1) / cellW)))
  const cellId = (a: number, b: number, c: number): number => (a * G + b) * G + c
  const cellOfPt = (i: number): number =>
    cellId(clampCell(xyz[i * 3]), clampCell(xyz[i * 3 + 1]), clampCell(xyz[i * 3 + 2]))
  const nCell = G * G * G
  const cellStart = new Int32Array(nCell + 1)
  for (let i = 0; i < n; i++) cellStart[cellOfPt(i) + 1]++
  for (let c = 0; c < nCell; c++) cellStart[c + 1] += cellStart[c]
  const order = new Int32Array(n)
  {
    const cur = cellStart.slice(0, nCell)
    for (let i = 0; i < n; i++) {
      const c = cellOfPt(i)
      order[cur[c]++] = i
    }
  }

  const scaleArr = new Float32Array(n * 3)
  const quatArr = new Float32Array(n * 4)
  const cand = new Int32Array(CAP)
  const cd = new Float64Array(CAP)
  const tick = Math.max(1, Math.floor(n / 30))
  for (let i = 0; i < n; i++) {
    if (onProgress && i % tick === 0) onProgress(0.2 + 0.7 * (i / n), 'fitting gaussians')
    const px = xyz[i * 3]
    const py = xyz[i * 3 + 1]
    const pz = xyz[i * 3 + 2]
    const bx = clampCell(px)
    const by = clampCell(py)
    const bz = clampCell(pz)
    let m = 0
    gather: for (let ax = -1; ax <= 1; ax++) {
      for (let ay = -1; ay <= 1; ay++) {
        for (let az = -1; az <= 1; az++) {
          const gx = bx + ax
          const gy = by + ay
          const gz = bz + az
          if (gx < 0 || gy < 0 || gz < 0 || gx >= G || gy >= G || gz >= G) continue
          const c = cellId(gx, gy, gz)
          for (let s = cellStart[c]; s < cellStart[c + 1]; s++) {
            const j = order[s]
            const dx = xyz[j * 3] - px
            const dy = xyz[j * 3 + 1] - py
            const dz = xyz[j * 3 + 2] - pz
            cand[m] = j
            cd[m] = dx * dx + dy * dy + dz * dz
            m++
            if (m >= CAP) break gather
          }
        }
      }
    }
    const k = Math.min(KNN, m)
    for (let a = 0; a < k; a++) {
      let mi = a
      for (let b = a + 1; b < m; b++) if (cd[b] < cd[mi]) mi = b
      if (mi !== a) {
        const t = cd[a]
        cd[a] = cd[mi]
        cd[mi] = t
        const u = cand[a]
        cand[a] = cand[mi]
        cand[mi] = u
      }
    }
    quatArr[i * 4] = 1
    if (k < 6) {
      const s = MIN_S * 2
      scaleArr[i * 3] = s
      scaleArr[i * 3 + 1] = s
      scaleArr[i * 3 + 2] = s
      continue
    }
    let mx = 0
    let my = 0
    let mz = 0
    for (let a = 0; a < k; a++) {
      const j = cand[a]
      mx += xyz[j * 3]
      my += xyz[j * 3 + 1]
      mz += xyz[j * 3 + 2]
    }
    mx /= k
    my /= k
    mz /= k
    let Cxx = 0
    let Cyy = 0
    let Czz = 0
    let Cxy = 0
    let Cxz = 0
    let Cyz = 0
    for (let a = 0; a < k; a++) {
      const j = cand[a]
      const ex = xyz[j * 3] - mx
      const ey = xyz[j * 3 + 1] - my
      const ez = xyz[j * 3 + 2] - mz
      Cxx += ex * ex
      Cyy += ey * ey
      Czz += ez * ez
      Cxy += ex * ey
      Cxz += ex * ez
      Cyz += ey * ez
    }
    Cxx /= k
    Cyy /= k
    Czz /= k
    Cxy /= k
    Cxz /= k
    Cyz /= k
    const { val, vec } = eig3(Cxx, Cyy, Czz, Cxy, Cxz, Cyz)
    const s0 = Math.min(MAX_S, Math.max(MIN_S, A_SCALE * Math.sqrt(Math.max(0, val[0]))))
    let s1 = Math.min(MAX_S, Math.max(MIN_S, A_SCALE * Math.sqrt(Math.max(0, val[1]))))
    let s2 = Math.min(MAX_S, Math.max(MIN_S, A_SCALE * Math.sqrt(Math.max(0, val[2]))))
    s1 = Math.max(s1, THIN * s0)
    s2 = Math.max(s2, THIN * s0)
    scaleArr[i * 3] = s0
    scaleArr[i * 3 + 1] = s1
    scaleArr[i * 3 + 2] = s2
    const q = quatFromCols(vec)
    quatArr[i * 4] = q[0]
    quatArr[i * 4 + 1] = q[1]
    quatArr[i * 4 + 2] = q[2]
    quatArr[i * 4 + 3] = q[3]
  }

  // ---- binary 3DGS ply -----------------------------------------------------
  onProgress?.(0.92, 'packing')
  const logitOpacity = Math.log(ALPHA / (1 - ALPHA))
  const props = ['x', 'y', 'z', 'nx', 'ny', 'nz', 'f_dc_0', 'f_dc_1', 'f_dc_2', 'opacity',
    'scale_0', 'scale_1', 'scale_2', 'rot_0', 'rot_1', 'rot_2', 'rot_3']
  const header = `ply\nformat binary_little_endian 1.0\nelement vertex ${n}\n` +
    props.map((p) => `property float ${p}`).join('\n') + `\nend_header\n`
  const headerBytes = new TextEncoder().encode(header)
  const stride = props.length * 4
  const out = new Uint8Array(headerBytes.length + n * stride)
  out.set(headerBytes, 0)
  const view = new DataView(out.buffer, headerBytes.length)
  for (let i = 0; i < n; i++) {
    let o = i * stride
    const put = (v: number): void => {
      view.setFloat32(o, v, true)
      o += 4
    }
    put(xyz[i * 3]); put(xyz[i * 3 + 1]); put(xyz[i * 3 + 2])
    put(0); put(0); put(0) // normals unused by 3DGS viewers, but the format expects them
    put((lin2srgb(rgbLin[i * 3]) - 0.5) / SH_C0)
    put((lin2srgb(rgbLin[i * 3 + 1]) - 0.5) / SH_C0)
    put((lin2srgb(rgbLin[i * 3 + 2]) - 0.5) / SH_C0)
    put(logitOpacity)
    put(Math.log(scaleArr[i * 3])); put(Math.log(scaleArr[i * 3 + 1])); put(Math.log(scaleArr[i * 3 + 2]))
    put(quatArr[i * 4]); put(quatArr[i * 4 + 1]); put(quatArr[i * 4 + 2]); put(quatArr[i * 4 + 3])
  }
  onProgress?.(1, 'done')
  return out
}

/** Jacobi eigendecomposition of a symmetric 3x3, eigenvalues descending. */
function eig3(a: number, b: number, c: number, d: number, e: number, f: number): { val: number[]; vec: number[][] } {
  const M = [[a, d, e], [d, b, f], [e, f, c]]
  const V = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
  for (let iter = 0; iter < 50; iter++) {
    let p = 0
    let q = 1
    let mx = Math.abs(M[0][1])
    if (Math.abs(M[0][2]) > mx) { mx = Math.abs(M[0][2]); p = 0; q = 2 }
    if (Math.abs(M[1][2]) > mx) { mx = Math.abs(M[1][2]); p = 1; q = 2 }
    if (mx < 1e-12) break
    const phi = 0.5 * Math.atan2(2 * M[p][q], M[q][q] - M[p][p])
    const cs = Math.cos(phi)
    const sn = Math.sin(phi)
    for (let k = 0; k < 3; k++) { const mkp = M[k][p], mkq = M[k][q]; M[k][p] = cs * mkp - sn * mkq; M[k][q] = sn * mkp + cs * mkq }
    for (let k = 0; k < 3; k++) { const mpk = M[p][k], mqk = M[q][k]; M[p][k] = cs * mpk - sn * mqk; M[q][k] = sn * mpk + cs * mqk }
    for (let k = 0; k < 3; k++) { const vkp = V[k][p], vkq = V[k][q]; V[k][p] = cs * vkp - sn * vkq; V[k][q] = sn * vkp + cs * vkq }
  }
  const idx = [0, 1, 2].sort((x, y) => M[y][y] - M[x][x])
  return {
    val: [M[idx[0]][idx[0]], M[idx[1]][idx[1]], M[idx[2]][idx[2]]],
    vec: [
      [V[0][idx[0]], V[0][idx[1]], V[0][idx[2]]],
      [V[1][idx[0]], V[1][idx[1]], V[1][idx[2]]],
      [V[2][idx[0]], V[2][idx[1]], V[2][idx[2]]],
    ],
  }
}

/** Rotation matrix (as columns) → quaternion, in the INRIA (w, x, y, z) convention. */
function quatFromCols(vec: number[][]): number[] {
  const r00 = vec[0][0], r01 = vec[0][1]
  let r02 = vec[0][2]
  const r10 = vec[1][0], r11 = vec[1][1]
  let r12 = vec[1][2]
  const r20 = vec[2][0], r21 = vec[2][1]
  let r22 = vec[2][2]
  const det = r00 * (r11 * r22 - r12 * r21) - r01 * (r10 * r22 - r12 * r20) + r02 * (r10 * r21 - r11 * r20)
  if (det < 0) { r02 = -r02; r12 = -r12; r22 = -r22 }
  const tr = r00 + r11 + r22
  let w: number, x: number, y: number, z: number
  if (tr > 0) {
    const S = Math.sqrt(tr + 1) * 2
    w = 0.25 * S; x = (r21 - r12) / S; y = (r02 - r20) / S; z = (r10 - r01) / S
  } else if (r00 > r11 && r00 > r22) {
    const S = Math.sqrt(1 + r00 - r11 - r22) * 2
    w = (r21 - r12) / S; x = 0.25 * S; y = (r01 + r10) / S; z = (r02 + r20) / S
  } else if (r11 > r22) {
    const S = Math.sqrt(1 + r11 - r00 - r22) * 2
    w = (r02 - r20) / S; x = (r01 + r10) / S; y = 0.25 * S; z = (r12 + r21) / S
  } else {
    const S = Math.sqrt(1 + r22 - r00 - r11) * 2
    w = (r10 - r01) / S; x = (r02 + r20) / S; y = (r12 + r21) / S; z = 0.25 * S
  }
  const inv = 1 / (Math.hypot(w, x, y, z) || 1)
  return [w * inv, x * inv, y * inv, z * inv]
}
