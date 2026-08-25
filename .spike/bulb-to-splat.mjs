#!/usr/bin/env node
/**
 * Path-A spike, CRISP edition: FractalXR Mandelbulb → 3D Gaussian Splat (.ply).
 *
 * The soft Ember FLAME splats as a smooth watercolour cloud — by design. To chase
 * the fibrous, engraved detail of harry7557558's splats we need a crisp, hard-surface
 * BULB. This ports FractalXR's `mandelbulbDE` + Newton surface-projection from
 * src/engine/shaders.ts (BULB_UPDATE_FRAG) to CPU: seed particles in the bounding
 * ball, Newton-project them onto the DE=0 isosurface, colour by orbit trap, then run
 * the same anisotropic-PCA fit → INRIA .ply as flame-to-splat.mjs.
 *
 * NOTE on the ceiling: even a perfect surface-shell point dump won't match harry's
 * finest fibres — those come from high-res (7680²) render+train (Path B). This shows
 * how far Path A goes on the RIGHT KIND of fractal.
 *
 * Run:  node .spike/bulb-to-splat.mjs [nPoints]   (default 220000)
 */
import { writeFileSync } from 'node:fs'
import { deflateSync } from 'node:zlib'

const N_POINTS = Number(process.argv[2]) || 220_000
const OUT_DIR = new URL('.', import.meta.url).pathname

// ── Mandelbulb params (matches a classic power-8 bulb) ──────────────────────
const POWER = 8, BOUND = 1.25
const BULB_ITERS = 16 // DE iterations — the engine uses 8 for real-time; offline we go deeper → finer surface filigree
const NEWTON = 14 // one-shot surface-projection steps (engine does ~4/frame over many frames)
const GEPS = 0.0012 * BOUND // gradient epsilon (finer → more accurate normals for the fine detail)
const SURF_EPS = 0.0025 * BOUND // keep points this close to DE=0 (tighter → crisper surface)
const GRAD_MIN = 0.2 // reject flat interior (|∇d| units; a real surface has |∇d| ~ 1)
// Rainbow palette (linear RGB), full hue travel → iridescent orbit-trap colour, à la harry's bulbs
const PALETTE = [[0.5, 0.0, 0.7], [0.0, 0.35, 1.0], [0.0, 0.92, 0.35], [1.0, 0.88, 0.0], [1.0, 0.12, 0.15]]

// ── deterministic RNG (mulberry32) ──────────────────────────────────────────
let _s = 0x1a2b3c4d >>> 0
function rnd() { _s = (_s + 0x6d2b79f5) >>> 0; let t = _s; t = Math.imul(t ^ (t >>> 15), t | 1); t ^= t + Math.imul(t ^ (t >>> 7), t | 61); return ((t ^ (t >>> 14)) >>> 0) / 4294967296 }
function randBall(R) { const u = rnd() * 2 - 1, phi = rnd() * 6.2831853, r = Math.cbrt(rnd()) * R, st = Math.sqrt(Math.max(0, 1 - u * u)); return [r * st * Math.cos(phi), r * st * Math.sin(phi), r * u] }

// ── Mandelbulb distance estimate (verbatim port of mandelbulbDE) ────────────
function bulbDE(px, py, pz) {
  let zx = px, zy = py, zz = pz
  let dr = 1.0, r = Math.hypot(zx, zy, zz)
  let trapR = 1e10, trapY = 1e10
  for (let i = 0; i < BULB_ITERS; i++) {
    r = Math.hypot(zx, zy, zz)
    if (r > 2.0) break
    const rr = Math.max(r, 1e-9)
    let theta = Math.acos(Math.max(-1, Math.min(1, zz / rr)))
    let phi = Math.atan2(zy, zx)
    dr = Math.pow(rr, POWER - 1) * POWER * dr + 1
    const zr = Math.pow(rr, POWER)
    theta *= POWER; phi *= POWER
    const st = Math.sin(theta)
    zx = zr * st * Math.cos(phi) + px
    zy = zr * st * Math.sin(phi) + py
    zz = zr * Math.cos(theta) + pz
    const lz = Math.hypot(zx, zy, zz)
    if (lz < trapR) trapR = lz
    if (Math.abs(zy) < trapY) trapY = Math.abs(zy)
  }
  return { d: 0.5 * Math.log(Math.max(r, 1e-9)) * r / Math.max(dr, 1e-6), trapR, trapY }
}
// tetrahedral 4-tap gradient (as deGrad); returns unit normal + raw magnitude
function deGrad(px, py, pz) {
  const d1 = bulbDE(px + GEPS, py - GEPS, pz - GEPS).d
  const d2 = bulbDE(px - GEPS, py - GEPS, pz + GEPS).d
  const d3 = bulbDE(px - GEPS, py + GEPS, pz - GEPS).d
  const d4 = bulbDE(px + GEPS, py + GEPS, pz + GEPS).d
  let gx = d1 - d2 - d3 + d4, gy = -d1 - d2 + d3 + d4, gz = -d1 + d2 - d3 + d4
  const mag = Math.hypot(gx, gy, gz) || 1e-9
  // the 4-tap magnitude ≈ 4·eps·|∇d|; divide it back out so `grad` is in true |∇d| units (~1 on a surface)
  return { nx: gx / mag, ny: gy / mag, nz: gz / mag, grad: mag / (4 * GEPS) }
}

const smooth = (a, b, x) => { const t = Math.min(1, Math.max(0, (x - a) / (b - a))); return t * t * (3 - 2 * t) }
function paletteLinear(c) { const segs = PALETTE.length - 1, f = Math.max(0, Math.min(1, c)) * segs, i0 = Math.min(segs, Math.floor(f)), i1 = Math.min(segs, i0 + 1), lf = f - i0, a = PALETTE[i0], b = PALETTE[i1]; return [a[0] + (b[0] - a[0]) * lf, a[1] + (b[1] - a[1]) * lf, a[2] + (b[2] - a[2]) * lf] }
const lin2srgb = (x) => (x <= 0.0031308 ? 12.92 * x : 1.055 * Math.pow(x, 1 / 2.4) - 0.055)

// ── sample the surface shell ────────────────────────────────────────────────
console.log(`Sampling ${N_POINTS.toLocaleString()} Mandelbulb (power ${POWER}) surface points…`)
const xyzAll = new Float32Array(N_POINTS * 3)
const rgbAll = new Float32Array(N_POINTS * 3)
const colRawAll = new Float32Array(N_POINTS) // raw orbit-trap scalar; equalised to colour after sampling
let n = 0, attempts = 0
const MAXATT = N_POINTS * 60
while (n < N_POINTS && attempts < MAXATT) {
  attempts++
  let p = randBall(BOUND)
  for (let s = 0; s < NEWTON; s++) { const de = bulbDE(p[0], p[1], p[2]); const g = deGrad(p[0], p[1], p[2]); p[0] -= g.nx * de.d; p[1] -= g.ny * de.d; p[2] -= g.nz * de.d }
  const de = bulbDE(p[0], p[1], p[2]); const g = deGrad(p[0], p[1], p[2])
  if (Math.abs(de.d) > SURF_EPS || g.grad < GRAD_MIN) continue // not on the surface / flat interior
  if (p[0] * p[0] + p[1] * p[1] + p[2] * p[2] > BOUND * BOUND * 1.3) continue
  colRawAll[n] = de.trapR * 0.7 + de.trapY * 0.5
  xyzAll[n * 3] = p[0]; xyzAll[n * 3 + 1] = p[1]; xyzAll[n * 3 + 2] = p[2]
  n++
}
console.log(`  kept ${n.toLocaleString()} / ${attempts.toLocaleString()} attempts (${(100 * n / attempts).toFixed(1)}% on-surface)`)
const xyz = xyzAll.subarray(0, n * 3), rgbLin = rgbAll.subarray(0, n * 3)

// rank-equalise the orbit-trap colour so it uses the FULL palette (iridescent), not a narrow band
const sorted = Float32Array.from(colRawAll.subarray(0, n)).sort()
for (let i = 0; i < n; i++) {
  const v = colRawAll[i]
  let lo = 0, hi = n
  while (lo < hi) { const mid = (lo + hi) >> 1; if (sorted[mid] < v) lo = mid + 1; else hi = mid }
  const rgb = paletteLinear(n > 1 ? lo / (n - 1) : 0.5) // percentile → palette coordinate
  rgbLin[i * 3] = rgb[0]; rgbLin[i * 3 + 1] = rgb[1]; rgbLin[i * 3 + 2] = rgb[2]
}

// ── centre + normalise to a ~2-unit cube ────────────────────────────────────
let cx = 0, cy = 0, cz = 0
for (let i = 0; i < n; i++) { cx += xyz[i * 3]; cy += xyz[i * 3 + 1]; cz += xyz[i * 3 + 2] }
cx /= n; cy /= n; cz /= n
let ext = 0
for (let i = 0; i < n; i++) ext = Math.max(ext, Math.abs(xyz[i * 3] - cx), Math.abs(xyz[i * 3 + 1] - cy), Math.abs(xyz[i * 3 + 2] - cz))
const norm = 1 / (ext || 1)
for (let i = 0; i < n; i++) { xyz[i * 3] = (xyz[i * 3] - cx) * norm; xyz[i * 3 + 1] = (xyz[i * 3 + 1] - cy) * norm; xyz[i * 3 + 2] = (xyz[i * 3 + 2] - cz) * norm }

// ── anisotropic per-point Gaussians via local-neighbourhood PCA (shared) ────
const SH_C0 = 0.28209479177387814
const KNN = 14, CAP = 160
const A_SCALE = 0.9, MIN_S = 0.0007, MAX_S = 0.0075, THIN = 0.16 // smaller splats → detail isn't blurred
const G = 128, cellW = 2 / G
const clampCell = (v) => Math.min(G - 1, Math.max(0, Math.floor((v + 1) / cellW)))
const cellId = (a, b, c) => (a * G + b) * G + c
const cellOfPt = (i) => cellId(clampCell(xyz[i * 3]), clampCell(xyz[i * 3 + 1]), clampCell(xyz[i * 3 + 2]))
const nCell = G * G * G
const cellStart = new Int32Array(nCell + 1)
for (let i = 0; i < n; i++) cellStart[cellOfPt(i) + 1]++
for (let c = 0; c < nCell; c++) cellStart[c + 1] += cellStart[c]
const order = new Int32Array(n)
{ const cur = cellStart.slice(0, nCell); for (let i = 0; i < n; i++) { const c = cellOfPt(i); order[cur[c]++] = i } }
const scaleArr = new Float32Array(n * 3), quatArr = new Float32Array(n * 4)
const cand = new Int32Array(CAP), cd = new Float64Array(CAP)
for (let i = 0; i < n; i++) {
  const px = xyz[i * 3], py = xyz[i * 3 + 1], pz = xyz[i * 3 + 2]
  const bx = clampCell(px), by = clampCell(py), bz = clampCell(pz)
  let m = 0
  gather:
  for (let ax = -1; ax <= 1; ax++) for (let ay = -1; ay <= 1; ay++) for (let az = -1; az <= 1; az++) {
    const gx = bx + ax, gy = by + ay, gz = bz + az
    if (gx < 0 || gy < 0 || gz < 0 || gx >= G || gy >= G || gz >= G) continue
    const c = cellId(gx, gy, gz)
    for (let s = cellStart[c]; s < cellStart[c + 1]; s++) { const j = order[s]; const dx = xyz[j * 3] - px, dy = xyz[j * 3 + 1] - py, dz = xyz[j * 3 + 2] - pz; cand[m] = j; cd[m] = dx * dx + dy * dy + dz * dz; m++; if (m >= CAP) break gather }
  }
  const k = Math.min(KNN, m)
  for (let a = 0; a < k; a++) { let mi = a; for (let b = a + 1; b < m; b++) if (cd[b] < cd[mi]) mi = b; if (mi !== a) { const t = cd[a]; cd[a] = cd[mi]; cd[mi] = t; const u = cand[a]; cand[a] = cand[mi]; cand[mi] = u } }
  quatArr[i * 4] = 1
  if (k < 6) { const s = MIN_S * 2; scaleArr[i * 3] = s; scaleArr[i * 3 + 1] = s; scaleArr[i * 3 + 2] = s; continue }
  let mx = 0, my = 0, mz = 0
  for (let a = 0; a < k; a++) { const j = cand[a]; mx += xyz[j * 3]; my += xyz[j * 3 + 1]; mz += xyz[j * 3 + 2] }
  mx /= k; my /= k; mz /= k
  let Cxx = 0, Cyy = 0, Czz = 0, Cxy = 0, Cxz = 0, Cyz = 0
  for (let a = 0; a < k; a++) { const j = cand[a]; const ex = xyz[j * 3] - mx, ey = xyz[j * 3 + 1] - my, ez = xyz[j * 3 + 2] - mz; Cxx += ex * ex; Cyy += ey * ey; Czz += ez * ez; Cxy += ex * ey; Cxz += ex * ez; Cyz += ey * ez }
  Cxx /= k; Cyy /= k; Czz /= k; Cxy /= k; Cxz /= k; Cyz /= k
  const { val, vec } = eig3(Cxx, Cyy, Czz, Cxy, Cxz, Cyz)
  let s0 = Math.min(MAX_S, Math.max(MIN_S, A_SCALE * Math.sqrt(Math.max(0, val[0]))))
  let s1 = Math.min(MAX_S, Math.max(MIN_S, A_SCALE * Math.sqrt(Math.max(0, val[1]))))
  let s2 = Math.min(MAX_S, Math.max(MIN_S, A_SCALE * Math.sqrt(Math.max(0, val[2]))))
  s1 = Math.max(s1, THIN * s0); s2 = Math.max(s2, THIN * s0)
  scaleArr[i * 3] = s0; scaleArr[i * 3 + 1] = s1; scaleArr[i * 3 + 2] = s2
  const q = quatFromCols(vec)
  quatArr[i * 4] = q[0]; quatArr[i * 4 + 1] = q[1]; quatArr[i * 4 + 2] = q[2]; quatArr[i * 4 + 3] = q[3]
}
const ALPHA = 0.22 // bulbs read crisper than flames, so a touch more opacity holds the surface
const logitOpacity = Math.log(ALPHA / (1 - ALPHA))

// ── write binary 3DGS PLY ───────────────────────────────────────────────────
const props = ['x', 'y', 'z', 'nx', 'ny', 'nz', 'f_dc_0', 'f_dc_1', 'f_dc_2', 'opacity', 'scale_0', 'scale_1', 'scale_2', 'rot_0', 'rot_1', 'rot_2', 'rot_3']
const header = `ply\nformat binary_little_endian 1.0\nelement vertex ${n}\n` + props.map((p) => `property float ${p}`).join('\n') + `\nend_header\n`
const headerBuf = Buffer.from(header, 'ascii')
const stride = props.length * 4
const body = Buffer.allocUnsafe(n * stride)
for (let i = 0; i < n; i++) {
  let o = i * stride
  const put = (v) => { body.writeFloatLE(v, o); o += 4 }
  put(xyz[i * 3]); put(xyz[i * 3 + 1]); put(xyz[i * 3 + 2])
  put(0); put(0); put(0)
  put((lin2srgb(rgbLin[i * 3]) - 0.5) / SH_C0); put((lin2srgb(rgbLin[i * 3 + 1]) - 0.5) / SH_C0); put((lin2srgb(rgbLin[i * 3 + 2]) - 0.5) / SH_C0)
  put(logitOpacity)
  put(Math.log(scaleArr[i * 3])); put(Math.log(scaleArr[i * 3 + 1])); put(Math.log(scaleArr[i * 3 + 2]))
  put(quatArr[i * 4]); put(quatArr[i * 4 + 1]); put(quatArr[i * 4 + 2]); put(quatArr[i * 4 + 3])
}
const plyPath = OUT_DIR + 'mandelbulb.ply'
const plyBuf = Buffer.concat([headerBuf, body])
writeFileSync(plyPath, plyBuf)
console.log(`✓ ${plyPath}  (${n.toLocaleString()} Gaussians, ${(plyBuf.length / 1e6).toFixed(1)} MB, α=${ALPHA})`)

// ── preview: additive oriented-ellipse projection ───────────────────────────
const W = 900, H = 900
const acc = new Float32Array(W * H * 3)
const half = W / 2, pad = 0.9
for (let i = 0; i < n; i++) {
  const cxp = half + xyz[i * 3] * half * pad, cyp = half - xyz[i * 3 + 1] * half * pad, Sp = half * pad
  const w = quatArr[i * 4], qx = quatArr[i * 4 + 1], qy = quatArr[i * 4 + 2], qz = quatArr[i * 4 + 3]
  const R00 = 1 - 2 * (qy * qy + qz * qz), R10 = 2 * (qx * qy + w * qz)
  const R01 = 2 * (qx * qy - w * qz), R11 = 1 - 2 * (qx * qx + qz * qz)
  const R02 = 2 * (qx * qz + w * qy), R12 = 2 * (qy * qz - w * qx)
  const s0 = scaleArr[i * 3] * Sp, s1 = scaleArr[i * 3 + 1] * Sp, s2 = scaleArr[i * 3 + 2] * Sp
  const a0x = s0 * R00, a0y = -s0 * R10, a1x = s1 * R01, a1y = -s1 * R11, a2x = s2 * R02, a2y = -s2 * R12
  const Sxx = a0x * a0x + a1x * a1x + a2x * a2x + 0.5, Syy = a0y * a0y + a1y * a1y + a2y * a2y + 0.5, Sxy = a0x * a0y + a1x * a1y + a2x * a2y
  const det2 = Sxx * Syy - Sxy * Sxy
  if (det2 <= 1e-6) continue
  const ixx = Syy / det2, iyy = Sxx / det2, ixy = -Sxy / det2
  const radx = Math.min(30, Math.ceil(2.6 * Math.sqrt(Sxx))), rady = Math.min(30, Math.ceil(2.6 * Math.sqrt(Syy)))
  const r0 = rgbLin[i * 3] * ALPHA, g0 = rgbLin[i * 3 + 1] * ALPHA, b0 = rgbLin[i * 3 + 2] * ALPHA
  const x0 = Math.max(0, Math.floor(cxp - radx)), x1 = Math.min(W - 1, Math.ceil(cxp + radx))
  const y0 = Math.max(0, Math.floor(cyp - rady)), y1 = Math.min(H - 1, Math.ceil(cyp + rady))
  for (let py = y0; py <= y1; py++) for (let px2 = x0; px2 <= x1; px2++) {
    const dx = px2 - cxp, dy = py - cyp, q = ixx * dx * dx + 2 * ixy * dx * dy + iyy * dy * dy
    if (q > 9) continue
    const fall = Math.exp(-0.5 * q), pi = (py * W + px2) * 3
    acc[pi] += r0 * fall; acc[pi + 1] += g0 * fall; acc[pi + 2] += b0 * fall
  }
}
const K2 = 22, EXPOSURE = 0.32, GAMMA = 2.2
const pxb = Buffer.allocUnsafe(W * H * 3)
for (let i = 0; i < W * H; i++) {
  const r = acc[i * 3], g = acc[i * 3 + 1], b = acc[i * 3 + 2], lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
  const ls = lum > 1e-6 ? (EXPOSURE * Math.log(1 + lum * K2) / lum) : 0
  for (let c = 0; c < 3; c++) { const v = Math.min(1, Math.max(0, acc[i * 3 + c] * ls)); pxb[i * 3 + c] = Math.round(255 * Math.pow(v, 1 / GAMMA)) }
}
writeFileSync(OUT_DIR + 'mandelbulb-preview.png', encodePNG(W, H, pxb))
console.log(`✓ ${OUT_DIR}mandelbulb-preview.png`)

// ── shared helpers ──────────────────────────────────────────────────────────
function eig3(a, b, c, d, e, f) {
  const M = [[a, d, e], [d, b, f], [e, f, c]], V = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
  for (let iter = 0; iter < 50; iter++) {
    let p = 0, q = 1, mx = Math.abs(M[0][1])
    if (Math.abs(M[0][2]) > mx) { mx = Math.abs(M[0][2]); p = 0; q = 2 }
    if (Math.abs(M[1][2]) > mx) { mx = Math.abs(M[1][2]); p = 1; q = 2 }
    if (mx < 1e-12) break
    const phi = 0.5 * Math.atan2(2 * M[p][q], M[q][q] - M[p][p]), cs = Math.cos(phi), sn = Math.sin(phi)
    for (let k = 0; k < 3; k++) { const mkp = M[k][p], mkq = M[k][q]; M[k][p] = cs * mkp - sn * mkq; M[k][q] = sn * mkp + cs * mkq }
    for (let k = 0; k < 3; k++) { const mpk = M[p][k], mqk = M[q][k]; M[p][k] = cs * mpk - sn * mqk; M[q][k] = sn * mpk + cs * mqk }
    for (let k = 0; k < 3; k++) { const vkp = V[k][p], vkq = V[k][q]; V[k][p] = cs * vkp - sn * vkq; V[k][q] = sn * vkp + cs * vkq }
  }
  const idx = [0, 1, 2].sort((x, y) => M[y][y] - M[x][x])
  return { val: [M[idx[0]][idx[0]], M[idx[1]][idx[1]], M[idx[2]][idx[2]]], vec: [[V[0][idx[0]], V[0][idx[1]], V[0][idx[2]]], [V[1][idx[0]], V[1][idx[1]], V[1][idx[2]]], [V[2][idx[0]], V[2][idx[1]], V[2][idx[2]]]] }
}
function quatFromCols(vec) {
  let r00 = vec[0][0], r01 = vec[0][1], r02 = vec[0][2], r10 = vec[1][0], r11 = vec[1][1], r12 = vec[1][2], r20 = vec[2][0], r21 = vec[2][1], r22 = vec[2][2]
  const det = r00 * (r11 * r22 - r12 * r21) - r01 * (r10 * r22 - r12 * r20) + r02 * (r10 * r21 - r11 * r20)
  if (det < 0) { r02 = -r02; r12 = -r12; r22 = -r22 }
  const tr = r00 + r11 + r22
  let w, x, y, z
  if (tr > 0) { const S = Math.sqrt(tr + 1) * 2; w = 0.25 * S; x = (r21 - r12) / S; y = (r02 - r20) / S; z = (r10 - r01) / S }
  else if (r00 > r11 && r00 > r22) { const S = Math.sqrt(1 + r00 - r11 - r22) * 2; w = (r21 - r12) / S; x = 0.25 * S; y = (r01 + r10) / S; z = (r02 + r20) / S }
  else if (r11 > r22) { const S = Math.sqrt(1 + r11 - r00 - r22) * 2; w = (r02 - r20) / S; x = (r01 + r10) / S; y = 0.25 * S; z = (r12 + r21) / S }
  else { const S = Math.sqrt(1 + r22 - r00 - r11) * 2; w = (r10 - r01) / S; x = (r02 + r20) / S; y = (r12 + r21) / S; z = 0.25 * S }
  const inv = 1 / (Math.hypot(w, x, y, z) || 1)
  return [w * inv, x * inv, y * inv, z * inv]
}
function encodePNG(w, h, rgb) {
  const sig = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), ihdr = Buffer.alloc(13)
  ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 2
  const raw = Buffer.allocUnsafe(h * (w * 3 + 1))
  for (let y = 0; y < h; y++) { raw[y * (w * 3 + 1)] = 0; rgb.copy(raw, y * (w * 3 + 1) + 1, y * w * 3, (y + 1) * w * 3) }
  const idat = deflateSync(raw)
  return Buffer.concat([sig, chunk('IHDR', ihdr), chunk('IDAT', idat), chunk('IEND', Buffer.alloc(0))])
}
function chunk(type, data) {
  const t = Buffer.from(type, 'ascii'), len = Buffer.alloc(4); len.writeUInt32BE(data.length, 0)
  const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(Buffer.concat([t, data])) >>> 0, 0)
  return Buffer.concat([len, t, data, crc])
}
function crc32(buf) {
  const table = new Uint32Array(256)
  for (let nn = 0; nn < 256; nn++) { let c = nn; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; table[nn] = c }
  let c = 0xffffffff
  for (let i = 0; i < buf.length; i++) c = table[(c ^ buf[i]) & 0xff] ^ (c >>> 8)
  return c ^ 0xffffffff
}
