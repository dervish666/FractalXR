#!/usr/bin/env node
/**
 * Path-A spike: FractalXR flame  →  3D Gaussian Splat (.ply)  — no training, no browser.
 *
 * The Reddit approach renders a fractal to hundreds of 2D images and TRAINS 3DGS to
 * recover the 3D structure. FractalXR already computes the fractal AS a 3D point cloud
 * (every chaos-game particle is an (x,y,z,colour) sample of the attractor), so we can
 * skip the render+train step entirely and convert points → Gaussians directly.
 *
 * This is a faithful CPU port of the flame chaos game in src/engine/shaders.ts
 * (UPDATE_FRAG) + the palette LUT in src/flame/palette.ts, for the EMBER preset
 * (GALLERY[0]). It writes:
 *   - ember.ply           a standard INRIA/3DGS binary PLY (loads in superspl.at / Spark)
 *   - ember-preview.png   an additive-glow projection so we can see the shape now
 *
 * Deliberately the SIMPLE version: isotropic Gaussians, one per attractor sample. The
 * production polish is voxel-clustering + anisotropic covariance fitting to hit the
 * ~500-750k Quest budget with fewer, better splats — noted, not done here.
 *
 * Run:  node .spike/flame-to-splat.mjs
 */
import { writeFileSync } from 'node:fs'
import { deflateSync } from 'node:zlib'

// ── EMBER genome (verbatim from src/flame/presets.ts) ───────────────────────
const EMBER = {
  transforms: [
    { rowX: [0.62, -0.20, 0.10], rowY: [0.20, 0.62, -0.08], rowZ: [-0.10, 0.08, 0.62], b: [0.10, 0.06, 0.04], weight: 1.0, color: 0.05, vars: { linear3D: 0.35, spherical: 0.65 } },
    { rowX: [0.45, 0.30, -0.25], rowY: [-0.30, 0.45, 0.20], rowZ: [0.25, -0.20, 0.50], b: [0.28, 0.34, -0.22], weight: 0.85, color: 0.55, vars: { swirl: 0.55, bubble3D: 0.55, linear3D: 0.15 } },
    { rowX: [0.40, 0.00, 0.18], rowY: [0.00, 0.40, 0.00], rowZ: [-0.18, 0.00, 0.40], b: [-0.30, 0.20, 0.30], weight: 0.7, color: 0.95, vars: { sinusoidal: 0.7, bubble3D: 0.3 } },
  ],
  // Ember theme control colours (linear RGB, 0..1), dark → light — from src/flame/palettes.ts
  palette: [[0.02, 0.02, 0.12], [0.35, 0.04, 0.45], [0.95, 0.15, 0.4], [1.0, 0.6, 0.1], [1.0, 0.95, 0.65]],
}

const N_POINTS = Number(process.argv[2]) || 250_000 // attractor samples → Gaussians (CLI: node flame-to-splat.mjs 1000000)
const WARMUP = 28 // chaos-game iterations to settle onto the attractor before recording (more = finer fine-structure)
const OUT_DIR = new URL('.', import.meta.url).pathname

// ── deterministic RNG (mulberry32) so re-runs are reproducible ──────────────
let _s = 0x9e3779b9 >>> 0
function rnd() {
  _s = (_s + 0x6d2b79f5) >>> 0
  let t = _s
  t = Math.imul(t ^ (t >>> 15), t | 1)
  t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296
}
// uniform point in a ball of radius R (matches randBall() in the shader)
function randBall(R) {
  const u = rnd() * 2 - 1
  const phi = rnd() * 6.2831853
  const r = Math.cbrt(rnd()) * R
  const st = Math.sqrt(Math.max(0, 1 - u * u))
  return [r * st * Math.cos(phi), r * st * Math.sin(phi), r * u]
}

// ── the 12 flam3 variations (verbatim order + formulas from UPDATE_FRAG) ─────
const V = {
  linear3D: (p) => p,
  spherical: (p) => { const r2 = p[0] * p[0] + p[1] * p[1] + p[2] * p[2] + 1e-9; return [p[0] / r2, p[1] / r2, p[2] / r2] },
  swirl: (p) => { const r2 = p[0] * p[0] + p[1] * p[1], s = Math.sin(r2), c = Math.cos(r2); return [p[0] * s - p[1] * c, p[0] * c + p[1] * s, p[2]] },
  sinusoidal: (p) => [Math.sin(p[0]), Math.sin(p[1]), Math.sin(p[2])],
  bubble3D: (p) => { const r2 = p[0] * p[0] + p[1] * p[1] + p[2] * p[2], f = 4 / (r2 + 4); return [p[0] * f, p[1] * f, p[2] * f] },
  horseshoe: (p) => { const r = Math.hypot(p[0], p[1]) + 1e-9; return [(p[0] - p[1]) * (p[0] + p[1]) / r, 2 * p[0] * p[1] / r, p[2]] },
  handkerchief: (p) => { const r = Math.hypot(p[0], p[1]), th = Math.atan2(p[1], p[0]); return [r * Math.sin(th + r), r * Math.cos(th - r), p[2]] },
  disc: (p) => { const r = Math.hypot(p[0], p[1]), th = Math.atan2(p[1], p[0]), a = th * 0.31830989, pr = Math.PI * r; return [a * Math.sin(pr), a * Math.cos(pr), p[2]] },
  spiral: (p) => { const r = Math.hypot(p[0], p[1]) + 1e-9, th = Math.atan2(p[1], p[0]); return [(Math.cos(th) + Math.sin(r)) / r, (Math.sin(th) - Math.cos(r)) / r, p[2]] },
  hyperbolic: (p) => { const r = Math.hypot(p[0], p[1]) + 1e-9, th = Math.atan2(p[1], p[0]); return [Math.sin(th) / r, r * Math.cos(th), p[2]] },
  cylinder: (p) => [Math.sin(p[0]), p[1], p[2]],
  eyefish: (p) => { const r = Math.hypot(p[0], p[1], p[2]), f = 2 / (r + 1); return [p[0] * f, p[1] * f, p[2] * f] },
}

// ── build the selection CDF (matches encode.ts) ─────────────────────────────
const T = EMBER.transforms
let total = 0
for (const t of T) total += Math.max(0, t.weight)
const cdf = []
{ let acc = 0; for (const t of T) { acc += Math.max(0, t.weight) / total; cdf.push(acc) } cdf[cdf.length - 1] = 1 }

function applyVars(t, p) {
  const v = [0, 0, 0]
  for (const [name, w] of Object.entries(t.vars)) {
    if (!w) continue
    const r = V[name](p)
    v[0] += w * r[0]; v[1] += w * r[1]; v[2] += w * r[2]
  }
  return v
}
function step(t, pos) {
  const p = [
    t.rowX[0] * pos[0] + t.rowX[1] * pos[1] + t.rowX[2] * pos[2] + t.b[0],
    t.rowY[0] * pos[0] + t.rowY[1] * pos[1] + t.rowY[2] * pos[2] + t.b[1],
    t.rowZ[0] * pos[0] + t.rowZ[1] * pos[1] + t.rowZ[2] * pos[2] + t.b[2],
  ]
  return applyVars(t, p)
}

// ── palette LUT (fillLut from palette.ts), linear RGB ───────────────────────
function paletteLinear(c) {
  const cols = EMBER.palette, segs = cols.length - 1
  const f = Math.max(0, Math.min(1, c)) * segs
  const i0 = Math.min(segs, Math.floor(f)), i1 = Math.min(segs, i0 + 1), lf = f - i0
  const a = cols[i0], b = cols[i1]
  return [a[0] + (b[0] - a[0]) * lf, a[1] + (b[1] - a[1]) * lf, a[2] + (b[2] - a[2]) * lf]
}
const lin2srgb = (x) => (x <= 0.0031308 ? 12.92 * x : 1.055 * Math.pow(x, 1 / 2.4) - 0.055)

// ── run the chaos game → collect samples ────────────────────────────────────
console.log(`Sampling ${N_POINTS.toLocaleString()} attractor points (EMBER)…`)
const xyz = new Float32Array(N_POINTS * 3)
const rgbLin = new Float32Array(N_POINTS * 3)
let n = 0
while (n < N_POINTS) {
  let pos = randBall(0.5)
  let col = rnd()
  let alive = true
  for (let it = 0; it < WARMUP; it++) {
    const bad = !(pos[0] === pos[0]) || !(pos[1] === pos[1]) || !(pos[2] === pos[2]) || (pos[0] * pos[0] + pos[1] * pos[1] + pos[2] * pos[2]) > 36
    if (bad) { pos = randBall(0.5); col = rnd(); continue }
    const t = rnd()
    let j = T.length - 1
    for (let k = 0; k < T.length; k++) { if (t < cdf[k]) { j = k; break } }
    pos = step(T[j], pos)
    col = col * 0.4 + T[j].color * 0.6
  }
  const bad = !(pos[0] === pos[0]) || !(pos[1] === pos[1]) || !(pos[2] === pos[2]) || (pos[0] * pos[0] + pos[1] * pos[1] + pos[2] * pos[2]) > 36
  if (bad) continue
  const rgb = paletteLinear(col)
  xyz[n * 3] = pos[0]; xyz[n * 3 + 1] = pos[1]; xyz[n * 3 + 2] = pos[2]
  rgbLin[n * 3] = rgb[0]; rgbLin[n * 3 + 1] = rgb[1]; rgbLin[n * 3 + 2] = rgb[2]
  n++
}

// ── centre + normalise scale (attractor → ~2-unit cube around origin) ────────
let cx = 0, cy = 0, cz = 0
for (let i = 0; i < n; i++) { cx += xyz[i * 3]; cy += xyz[i * 3 + 1]; cz += xyz[i * 3 + 2] }
cx /= n; cy /= n; cz /= n
let ext = 0
for (let i = 0; i < n; i++) {
  ext = Math.max(ext, Math.abs(xyz[i * 3] - cx), Math.abs(xyz[i * 3 + 1] - cy), Math.abs(xyz[i * 3 + 2] - cz))
}
const norm = 1.0 / (ext || 1) // → fits in [-1,1]
for (let i = 0; i < n; i++) {
  xyz[i * 3] = (xyz[i * 3] - cx) * norm
  xyz[i * 3 + 1] = (xyz[i * 3 + 1] - cy) * norm
  xyz[i * 3 + 2] = (xyz[i * 3 + 2] - cz) * norm
}
// ── anisotropic per-point Gaussians via local-neighbourhood PCA ─────────────
// Fit each Gaussian as an ELLIPSOID aligned to the local surface (long in the
// two tangent directions, thin along the normal) instead of a sphere, so
// overlapping splats blend into smooth glow instead of cauliflower lumps.
// Orientation + axis lengths come from the eigendecomposition of the covariance
// of each point's k nearest neighbours.
const SH_C0 = 0.28209479177387814 // SH degree-0 basis constant
const KNN = 14, CAP = 160 // neighbours per fit; candidate-scan cap (dense core is huge)
const A_SCALE = 0.95, MIN_S = 0.0012, MAX_S = 0.011, THIN = 0.16 // normal-axis min flatness vs long axis

// neighbour lookup: CSR bucket grid over the normalised [-1,1] cloud
const G = 128, cellW = 2 / G
const clampCell = (v) => Math.min(G - 1, Math.max(0, Math.floor((v + 1) / cellW)))
const cellId = (cx, cy, cz) => (cx * G + cy) * G + cz
const cellOfPt = (i) => cellId(clampCell(xyz[i * 3]), clampCell(xyz[i * 3 + 1]), clampCell(xyz[i * 3 + 2]))
const nCell = G * G * G
const cellStart = new Int32Array(nCell + 1)
for (let i = 0; i < n; i++) cellStart[cellOfPt(i) + 1]++
for (let c = 0; c < nCell; c++) cellStart[c + 1] += cellStart[c]
const order = new Int32Array(n)
{ const cur = cellStart.slice(0, nCell); for (let i = 0; i < n; i++) { const c = cellOfPt(i); order[cur[c]++] = i } }

const scaleArr = new Float32Array(n * 3) // per-axis σ
const quatArr = new Float32Array(n * 4) // orientation (w,x,y,z)
const cand = new Int32Array(CAP)
const cd = new Float64Array(CAP)
let sMin = 1e9, sMax = 0
for (let i = 0; i < n; i++) {
  const px = xyz[i * 3], py = xyz[i * 3 + 1], pz = xyz[i * 3 + 2]
  const cx = clampCell(px), cy = clampCell(py), cz = clampCell(pz)
  let m = 0
  gather:
  for (let ax = -1; ax <= 1; ax++) for (let ay = -1; ay <= 1; ay++) for (let az = -1; az <= 1; az++) {
    const gx = cx + ax, gy = cy + ay, gz = cz + az
    if (gx < 0 || gy < 0 || gz < 0 || gx >= G || gy >= G || gz >= G) continue
    const c = cellId(gx, gy, gz)
    for (let s = cellStart[c]; s < cellStart[c + 1]; s++) {
      const j = order[s]
      const dx = xyz[j * 3] - px, dy = xyz[j * 3 + 1] - py, dz = xyz[j * 3 + 2] - pz
      cand[m] = j; cd[m] = dx * dx + dy * dy + dz * dz; m++
      if (m >= CAP) break gather
    }
  }
  const k = Math.min(KNN, m)
  // partial selection: pull the k nearest to the front
  for (let a = 0; a < k; a++) { let mi = a; for (let b = a + 1; b < m; b++) if (cd[b] < cd[mi]) mi = b; if (mi !== a) { const t = cd[a]; cd[a] = cd[mi]; cd[mi] = t; const u = cand[a]; cand[a] = cand[mi]; cand[mi] = u } }
  quatArr[i * 4] = 1
  if (k < 6) { const s = MIN_S * 2; scaleArr[i * 3] = s; scaleArr[i * 3 + 1] = s; scaleArr[i * 3 + 2] = s; continue }
  // covariance of the k nearest
  let mx = 0, my = 0, mz = 0
  for (let a = 0; a < k; a++) { const j = cand[a]; mx += xyz[j * 3]; my += xyz[j * 3 + 1]; mz += xyz[j * 3 + 2] }
  mx /= k; my /= k; mz /= k
  let Cxx = 0, Cyy = 0, Czz = 0, Cxy = 0, Cxz = 0, Cyz = 0
  for (let a = 0; a < k; a++) { const j = cand[a]; const ex = xyz[j * 3] - mx, ey = xyz[j * 3 + 1] - my, ez = xyz[j * 3 + 2] - mz; Cxx += ex * ex; Cyy += ey * ey; Czz += ez * ez; Cxy += ex * ey; Cxz += ex * ez; Cyz += ey * ez }
  Cxx /= k; Cyy /= k; Czz /= k; Cxy /= k; Cxz /= k; Cyz /= k
  const { val, vec } = eig3(Cxx, Cyy, Czz, Cxy, Cxz, Cyz) // val desc, vec columns = eigenvectors
  let s0 = Math.min(MAX_S, Math.max(MIN_S, A_SCALE * Math.sqrt(Math.max(0, val[0]))))
  let s1 = Math.min(MAX_S, Math.max(MIN_S, A_SCALE * Math.sqrt(Math.max(0, val[1]))))
  let s2 = Math.min(MAX_S, Math.max(MIN_S, A_SCALE * Math.sqrt(Math.max(0, val[2]))))
  s1 = Math.max(s1, THIN * s0); s2 = Math.max(s2, THIN * s0) // no needle-thin slivers → rendering artifacts
  scaleArr[i * 3] = s0; scaleArr[i * 3 + 1] = s1; scaleArr[i * 3 + 2] = s2
  const q = quatFromCols(vec)
  quatArr[i * 4] = q[0]; quatArr[i * 4 + 1] = q[1]; quatArr[i * 4 + 2] = q[2]; quatArr[i * 4 + 3] = q[3]
  if (s0 > sMax) sMax = s0; if (s2 < sMin) sMin = s2
}
const ALPHA = 0.18 // low per-splat opacity → translucent glow that builds up where dense (like the live flame)
const logitOpacity = Math.log(ALPHA / (1 - ALPHA))

// ── write binary 3DGS PLY (INRIA field layout, SH degree 0) ─────────────────
const props = ['x', 'y', 'z', 'nx', 'ny', 'nz', 'f_dc_0', 'f_dc_1', 'f_dc_2', 'opacity', 'scale_0', 'scale_1', 'scale_2', 'rot_0', 'rot_1', 'rot_2', 'rot_3']
const header =
  `ply\nformat binary_little_endian 1.0\nelement vertex ${n}\n` +
  props.map((p) => `property float ${p}`).join('\n') + `\nend_header\n`
const headerBuf = Buffer.from(header, 'ascii')
const stride = props.length * 4
const body = Buffer.allocUnsafe(n * stride)
for (let i = 0; i < n; i++) {
  let o = i * stride
  const put = (val) => { body.writeFloatLE(val, o); o += 4 }
  put(xyz[i * 3]); put(xyz[i * 3 + 1]); put(xyz[i * 3 + 2]) // position
  put(0); put(0); put(0) // normal (unused)
  put((lin2srgb(rgbLin[i * 3]) - 0.5) / SH_C0) // f_dc: colour → SH DC term
  put((lin2srgb(rgbLin[i * 3 + 1]) - 0.5) / SH_C0)
  put((lin2srgb(rgbLin[i * 3 + 2]) - 0.5) / SH_C0)
  put(logitOpacity) // opacity (logit; viewer applies sigmoid)
  put(Math.log(scaleArr[i * 3])); put(Math.log(scaleArr[i * 3 + 1])); put(Math.log(scaleArr[i * 3 + 2])) // per-axis σ (log)
  put(quatArr[i * 4]); put(quatArr[i * 4 + 1]); put(quatArr[i * 4 + 2]); put(quatArr[i * 4 + 3]) // orientation (w,x,y,z)
}
const plyPath = OUT_DIR + 'ember.ply'
writeFileSync(plyPath, Buffer.concat([headerBuf, body]))
console.log(`✓ ${plyPath}  (${n.toLocaleString()} Gaussians, ${(Buffer.concat([headerBuf, body]).length / 1e6).toFixed(1)} MB, adaptive scale ${sMin.toFixed(4)}–${sMax.toFixed(4)}, α=${ALPHA})`)

// ── preview PNG: additive-glow projection (XY, front view) ───────────────────
// Splat each Gaussian as an additive ORIENTED ELLIPSE (the 3D anisotropic
// covariance projected to screen), so the preview reflects the real ellipsoid
// footprints — this is what validates the PCA fit isn't eigen-garbage.
const W = 900, H = 900
const acc = new Float32Array(W * H * 3)
const half = W / 2, pad = 0.86
for (let i = 0; i < n; i++) {
  const cxp = half + xyz[i * 3] * half * pad
  const cyp = half - xyz[i * 3 + 1] * half * pad // flip y for image space
  const Sp = half * pad
  // rotation matrix columns from the stored quaternion (only rows x,y matter for XY projection)
  const w = quatArr[i * 4], qx = quatArr[i * 4 + 1], qy = quatArr[i * 4 + 2], qz = quatArr[i * 4 + 3]
  const R00 = 1 - 2 * (qy * qy + qz * qz), R10 = 2 * (qx * qy + w * qz)
  const R01 = 2 * (qx * qy - w * qz), R11 = 1 - 2 * (qx * qx + qz * qz)
  const R02 = 2 * (qx * qz + w * qy), R12 = 2 * (qy * qz - w * qx)
  const s0 = scaleArr[i * 3] * Sp, s1 = scaleArr[i * 3 + 1] * Sp, s2 = scaleArr[i * 3 + 2] * Sp
  // screen-space axis vectors (world → (x,-y)); 2D covariance = Σ aₖ aₖᵀ
  const a0x = s0 * R00, a0y = -s0 * R10, a1x = s1 * R01, a1y = -s1 * R11, a2x = s2 * R02, a2y = -s2 * R12
  const Sxx = a0x * a0x + a1x * a1x + a2x * a2x + 0.5 // +0.5px floor so sub-pixel splats still show
  const Syy = a0y * a0y + a1y * a1y + a2y * a2y + 0.5
  const Sxy = a0x * a0y + a1x * a1y + a2x * a2y
  const det2 = Sxx * Syy - Sxy * Sxy
  if (det2 <= 1e-6) continue
  const ixx = Syy / det2, iyy = Sxx / det2, ixy = -Sxy / det2
  const radx = Math.min(34, Math.ceil(2.6 * Math.sqrt(Sxx))), rady = Math.min(34, Math.ceil(2.6 * Math.sqrt(Syy)))
  const r0 = rgbLin[i * 3] * ALPHA, g0 = rgbLin[i * 3 + 1] * ALPHA, b0 = rgbLin[i * 3 + 2] * ALPHA
  const x0 = Math.max(0, Math.floor(cxp - radx)), x1 = Math.min(W - 1, Math.ceil(cxp + radx))
  const y0 = Math.max(0, Math.floor(cyp - rady)), y1 = Math.min(H - 1, Math.ceil(cyp + rady))
  for (let py = y0; py <= y1; py++) {
    for (let px2 = x0; px2 <= x1; px2++) {
      const dx = px2 - cxp, dy = py - cyp
      const q = ixx * dx * dx + 2 * ixy * dx * dy + iyy * dy * dy
      if (q > 9) continue
      const fall = Math.exp(-0.5 * q)
      const pi = (py * W + px2) * 3
      acc[pi] += r0 * fall; acc[pi + 1] += g0 * fall; acc[pi + 2] += b0 * fall
    }
  }
}
// flam3-ish log-density tonemap + gamma
const K2 = 16, EXPOSURE = 0.4, GAMMA = 2.2
const px = Buffer.allocUnsafe(W * H * 3)
for (let i = 0; i < W * H; i++) {
  const r = acc[i * 3], g = acc[i * 3 + 1], b = acc[i * 3 + 2]
  const lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
  const ls = lum > 1e-6 ? (EXPOSURE * Math.log(1 + lum * K2) / lum) : 0
  for (let c = 0; c < 3; c++) {
    const v = Math.min(1, Math.max(0, acc[i * 3 + c] * ls))
    px[i * 3 + c] = Math.round(255 * Math.pow(v, 1 / GAMMA))
  }
}
writeFileSync(OUT_DIR + 'ember-preview.png', encodePNG(W, H, px))
console.log(`✓ ${OUT_DIR}ember-preview.png  (${W}×${H} additive-glow projection)`)

// ── symmetric 3×3 eigendecomposition (cyclic Jacobi) ────────────────────────
// Input: matrix [[a,d,e],[d,b,f],[e,f,c]]. Returns eigenvalues DESC + eigenvectors
// as columns of `vec` (vec[row][col]). Reliable for the small SPD covariances here.
function eig3(a, b, c, d, e, f) {
  const M = [[a, d, e], [d, b, f], [e, f, c]]
  const V = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
  for (let iter = 0; iter < 50; iter++) {
    let p = 0, q = 1, mx = Math.abs(M[0][1])
    if (Math.abs(M[0][2]) > mx) { mx = Math.abs(M[0][2]); p = 0; q = 2 }
    if (Math.abs(M[1][2]) > mx) { mx = Math.abs(M[1][2]); p = 1; q = 2 }
    if (mx < 1e-12) break
    const phi = 0.5 * Math.atan2(2 * M[p][q], M[q][q] - M[p][p])
    const cs = Math.cos(phi), sn = Math.sin(phi)
    for (let k = 0; k < 3; k++) { const mkp = M[k][p], mkq = M[k][q]; M[k][p] = cs * mkp - sn * mkq; M[k][q] = sn * mkp + cs * mkq }
    for (let k = 0; k < 3; k++) { const mpk = M[p][k], mqk = M[q][k]; M[p][k] = cs * mpk - sn * mqk; M[q][k] = sn * mpk + cs * mqk }
    for (let k = 0; k < 3; k++) { const vkp = V[k][p], vkq = V[k][q]; V[k][p] = cs * vkp - sn * vkq; V[k][q] = sn * vkp + cs * vkq }
  }
  const idx = [0, 1, 2].sort((x, y) => M[y][y] - M[x][x]) // eigenvalues descending
  return {
    val: [M[idx[0]][idx[0]], M[idx[1]][idx[1]], M[idx[2]][idx[2]]],
    vec: [
      [V[0][idx[0]], V[0][idx[1]], V[0][idx[2]]],
      [V[1][idx[0]], V[1][idx[1]], V[1][idx[2]]],
      [V[2][idx[0]], V[2][idx[1]], V[2][idx[2]]],
    ],
  }
}

// quaternion (w,x,y,z) from a rotation whose columns are `vec` (forced proper, det +1)
function quatFromCols(vec) {
  let r00 = vec[0][0], r01 = vec[0][1], r02 = vec[0][2]
  let r10 = vec[1][0], r11 = vec[1][1], r12 = vec[1][2]
  let r20 = vec[2][0], r21 = vec[2][1], r22 = vec[2][2]
  const det = r00 * (r11 * r22 - r12 * r21) - r01 * (r10 * r22 - r12 * r20) + r02 * (r10 * r21 - r11 * r20)
  if (det < 0) { r02 = -r02; r12 = -r12; r22 = -r22 } // flip 3rd column → right-handed
  const tr = r00 + r11 + r22
  let w, x, y, z
  if (tr > 0) { const S = Math.sqrt(tr + 1) * 2; w = 0.25 * S; x = (r21 - r12) / S; y = (r02 - r20) / S; z = (r10 - r01) / S }
  else if (r00 > r11 && r00 > r22) { const S = Math.sqrt(1 + r00 - r11 - r22) * 2; w = (r21 - r12) / S; x = 0.25 * S; y = (r01 + r10) / S; z = (r02 + r20) / S }
  else if (r11 > r22) { const S = Math.sqrt(1 + r11 - r00 - r22) * 2; w = (r02 - r20) / S; x = (r01 + r10) / S; y = 0.25 * S; z = (r12 + r21) / S }
  else { const S = Math.sqrt(1 + r22 - r00 - r11) * 2; w = (r10 - r01) / S; x = (r02 + r20) / S; y = (r12 + r21) / S; z = 0.25 * S }
  const inv = 1 / (Math.hypot(w, x, y, z) || 1)
  return [w * inv, x * inv, y * inv, z * inv]
}

// ── minimal zero-dependency PNG encoder (truecolor RGB, filter 0) ───────────
function encodePNG(w, h, rgb) {
  const sig = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10])
  const ihdr = Buffer.alloc(13)
  ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4)
  ihdr[8] = 8; ihdr[9] = 2; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0
  const raw = Buffer.allocUnsafe(h * (w * 3 + 1))
  for (let y = 0; y < h; y++) {
    raw[y * (w * 3 + 1)] = 0 // filter: none
    rgb.copy(raw, y * (w * 3 + 1) + 1, y * w * 3, (y + 1) * w * 3)
  }
  const idat = deflateSync(raw)
  return Buffer.concat([sig, chunk('IHDR', ihdr), chunk('IDAT', idat), chunk('IEND', Buffer.alloc(0))])
}
function chunk(type, data) {
  const t = Buffer.from(type, 'ascii')
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length, 0)
  const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(Buffer.concat([t, data])) >>> 0, 0)
  return Buffer.concat([len, t, data, crc])
}
function crc32(buf) {
  const table = new Uint32Array(256)
  for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; table[n] = c }
  let c = 0xffffffff
  for (let i = 0; i < buf.length; i++) c = table[(c ^ buf[i]) & 0xff] ^ (c >>> 8)
  return c ^ 0xffffffff
}
