import { Matrix4, Quaternion, Vector3 } from 'three'
import { VARIATION_NAMES, zeroVariations } from './types'
import type { FlameGenome, FlameTransform, Vec3 } from './types'

const lerp = (a: number, b: number, t: number): number => a + (b - a) * t

/** Ease-in-out so morphs start and stop gently. */
export const smoothstep = (t: number): number => {
  const x = t < 0 ? 0 : t > 1 ? 1 : t
  return x * x * (3 - 2 * x)
}

// module scratch — avoid per-call allocation of the heavy math objects
const _m = new Matrix4()
const _pa = new Vector3()
const _qa = new Quaternion()
const _sa = new Vector3()
const _pb = new Vector3()
const _qb = new Quaternion()
const _sb = new Vector3()
const _pr = new Vector3()
const _qr = new Quaternion()
const _sr = new Vector3()

function decompose(tx: FlameTransform, p: Vector3, q: Quaternion, s: Vector3): void {
  // Matrix4.set is row-major; our transform applies new = M * [x,y,z,1]
  _m.set(
    tx.rowX[0], tx.rowX[1], tx.rowX[2], tx.translate[0],
    tx.rowY[0], tx.rowY[1], tx.rowY[2], tx.translate[1],
    tx.rowZ[0], tx.rowZ[1], tx.rowZ[2], tx.translate[2],
    0, 0, 0, 1,
  )
  _m.decompose(p, q, s) // M = T·R·S (shear ignored — our affines are rotation+scale dominant)
}

/**
 * Interpolate one transform: translation + scale lerp, rotation SLERP (so two
 * differently-oriented transforms rotate between rather than collapsing through
 * a degenerate scaled middle), variation weights / colour lerp.
 */
function cloneTransform(tx: FlameTransform): FlameTransform {
  return {
    rowX: [tx.rowX[0], tx.rowX[1], tx.rowX[2]],
    rowY: [tx.rowY[0], tx.rowY[1], tx.rowY[2]],
    rowZ: [tx.rowZ[0], tx.rowZ[1], tx.rowZ[2]],
    translate: [tx.translate[0], tx.translate[1], tx.translate[2]],
    weight: tx.weight,
    colorIndex: tx.colorIndex,
    variations: { ...tx.variations },
  }
}

function interpTransform(a: FlameTransform, b: FlameTransform, t: number): FlameTransform {
  if (t <= 0) return cloneTransform(a) // exact endpoints (no decompose round-trip / shear loss)
  if (t >= 1) return cloneTransform(b)
  decompose(a, _pa, _qa, _sa)
  decompose(b, _pb, _qb, _sb)
  _pr.copy(_pa).lerp(_pb, t)
  _qr.copy(_qa).slerp(_qb, t)
  _sr.copy(_sa).lerp(_sb, t)
  _m.compose(_pr, _qr, _sr)
  const e = _m.elements // column-major
  const variations = zeroVariations()
  for (const name of VARIATION_NAMES) variations[name] = lerp(a.variations[name], b.variations[name], t)
  return {
    rowX: [e[0], e[4], e[8]] as Vec3,
    rowY: [e[1], e[5], e[9]] as Vec3,
    rowZ: [e[2], e[6], e[10]] as Vec3,
    translate: [_pr.x, _pr.y, _pr.z] as Vec3,
    weight: lerp(a.weight, b.weight, t),
    colorIndex: lerp(a.colorIndex, b.colorIndex, t),
    variations,
  }
}

/** A zero-weight clone — used to pad a genome so a transform that only exists in
 * the other genome fades in/out by weight instead of popping. */
function zeroWeightCopy(tx: FlameTransform): FlameTransform {
  return {
    rowX: [tx.rowX[0], tx.rowX[1], tx.rowX[2]],
    rowY: [tx.rowY[0], tx.rowY[1], tx.rowY[2]],
    rowZ: [tx.rowZ[0], tx.rowZ[1], tx.rowZ[2]],
    translate: [tx.translate[0], tx.translate[1], tx.translate[2]],
    weight: 0,
    colorIndex: tx.colorIndex,
    variations: { ...tx.variations },
  }
}

function sampleColor(colors: Vec3[], s: number): Vec3 {
  const segs = Math.max(1, colors.length - 1)
  const f = Math.max(0, Math.min(1, s)) * segs
  const i0 = Math.min(segs, Math.floor(f))
  const i1 = Math.min(segs, i0 + 1)
  const lf = f - i0
  const a = colors[i0]
  const b = colors[i1]
  return [a[0] + (b[0] - a[0]) * lf, a[1] + (b[1] - a[1]) * lf, a[2] + (b[2] - a[2]) * lf]
}

/** Blend two palettes by resampling both at a common resolution then lerping. */
export function blendPalettes(a: Vec3[], b: Vec3[], t: number): Vec3[] {
  const n = Math.max(a.length, b.length)
  const out: Vec3[] = []
  for (let i = 0; i < n; i++) {
    const s = n === 1 ? 0 : i / (n - 1)
    const ca = sampleColor(a, s)
    const cb = sampleColor(b, s)
    out.push([lerp(ca[0], cb[0], t), lerp(ca[1], cb[1], t), lerp(ca[2], cb[2], t)])
  }
  return out
}

/** Interpolate a whole genome A→B at parameter t∈[0,1]. */
export function interpolateGenome(a: FlameGenome, b: FlameGenome, t: number): FlameGenome {
  const n = Math.max(a.transforms.length, b.transforms.length)
  const transforms: FlameTransform[] = []
  for (let i = 0; i < n; i++) {
    const ta = i < a.transforms.length ? a.transforms[i] : zeroWeightCopy(b.transforms[i])
    const tb = i < b.transforms.length ? b.transforms[i] : zeroWeightCopy(a.transforms[i])
    transforms.push(interpTransform(ta, tb, t))
  }
  return {
    name: `${a.name}→${b.name}`,
    transforms,
    palette: blendPalettes(a.palette, b.palette, t),
    brightness: lerp(a.brightness, b.brightness, t),
    gamma: lerp(a.gamma, b.gamma, t),
    k2: lerp(a.k2, b.k2, t),
    highlightDesat: lerp(a.highlightDesat, b.highlightDesat, t),
    pointBrightness: lerp(a.pointBrightness, b.pointBrightness, t),
  }
}
