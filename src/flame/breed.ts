import { Matrix4, Quaternion, Vector3 } from 'three'
import { VARIATION_NAMES, Z_INJECTORS, zeroVariations } from './types'
import type { FlameGenome, FlameTransform, Vec3, VariationName } from './types'
import { THEMES } from './palettes'

// Browser-runtime randomness is fine here (not the workflow sandbox).
const rand = (a = 0, b = 1): number => a + Math.random() * (b - a)
const pick = <T>(arr: readonly T[]): T => arr[Math.floor(Math.random() * arr.length)]
const clamp01 = (x: number): number => (x < 0 ? 0 : x > 1 ? 1 : x)
const round2 = (x: number): number => Math.round(x * 100) / 100

const _m = new Matrix4()
const _q = new Quaternion()
const _t = new Vector3()
const _s = new Vector3()

/** A random affine built from rotation × (contractive) scale × translation — so the
 * linear part never blows up and the attractor stays bounded. */
function randomAffine(): Pick<FlameTransform, 'rowX' | 'rowY' | 'rowZ' | 'translate'> {
  _q.set(rand(-1, 1), rand(-1, 1), rand(-1, 1), rand(-1, 1)).normalize()
  // contractive scales + modest translation keep the attractor compact like the presets
  _s.set(rand(0.3, 0.62), rand(0.3, 0.62), rand(0.3, 0.62))
  _t.set(rand(-0.32, 0.32), rand(-0.32, 0.32), rand(-0.32, 0.32))
  _m.compose(_t, _q, _s)
  const e = _m.elements // column-major
  return {
    rowX: [e[0], e[4], e[8]],
    rowY: [e[1], e[5], e[9]],
    rowZ: [e[2], e[6], e[10]],
    translate: [_t.x, _t.y, _t.z],
  }
}

function randomVariations(): FlameTransform['variations'] {
  const v = zeroVariations()
  const k = 1 + Math.floor(rand(0, 2.999)) // 1–3 active variations
  for (let i = 0; i < k; i++) v[pick(VARIATION_NAMES)] = round2(rand(0.3, 1.0))
  return v
}

function hasZInjector(transforms: FlameTransform[]): boolean {
  return transforms.some((t) => Z_INJECTORS.some((z) => t.variations[z] > 0))
}

/** A flat 2D sheet is the failure mode — guarantee at least one z-injecting variation. */
function ensureZInjector(transforms: FlameTransform[]): void {
  if (hasZInjector(transforms)) return
  pick(transforms).variations[pick(Z_INJECTORS) as VariationName] = round2(rand(0.4, 0.8))
}

function hslToRgb(h: number, s: number, l: number): Vec3 {
  if (s === 0) return [l, l, l]
  const q = l < 0.5 ? l * (1 + s) : l + s - l * s
  const p = 2 * l - q
  const hue2 = (t: number): number => {
    let tt = t
    if (tt < 0) tt += 1
    if (tt > 1) tt -= 1
    if (tt < 1 / 6) return p + (q - p) * 6 * tt
    if (tt < 1 / 2) return q
    if (tt < 2 / 3) return p + (q - p) * (2 / 3 - tt) * 6
    return p
  }
  return [hue2(h + 1 / 3), hue2(h), hue2(h - 1 / 3)]
}

/** Random colours: usually a curated theme (cohesive), sometimes a generated ramp. */
function randomPalette(): Vec3[] {
  if (Math.random() < 0.6) {
    const t = pick(THEMES)
    return t.colors.map((c) => [c[0], c[1], c[2]] as Vec3)
  }
  const h0 = rand(0, 1)
  const drift = rand(-0.22, 0.22)
  const stops = [0.0, 0.2, 0.45, 0.72, 1.0]
  return stops.map((sPos) => {
    const h = (h0 + drift * sPos + 1) % 1
    const sat = clamp01(0.55 + 0.45 * Math.sin(sPos * Math.PI))
    const light = clamp01(0.02 + sPos * 0.95)
    return hslToRgb(h, sat, light)
  })
}

const DEFAULT_TONE = { brightness: 0.26, gamma: 2.4, k2: 55, highlightDesat: 0.3, pointBrightness: 0.9 }

function cloneTransform(t: FlameTransform): FlameTransform {
  return {
    rowX: [t.rowX[0], t.rowX[1], t.rowX[2]],
    rowY: [t.rowY[0], t.rowY[1], t.rowY[2]],
    rowZ: [t.rowZ[0], t.rowZ[1], t.rowZ[2]],
    translate: [t.translate[0], t.translate[1], t.translate[2]],
    weight: t.weight,
    colorIndex: t.colorIndex,
    variations: { ...t.variations },
  }
}

/** A brand-new random flame. */
export function randomGenome(serial: number): FlameGenome {
  const n = 2 + Math.floor(rand(0, 2.999)) // 2–4 transforms
  const transforms: FlameTransform[] = []
  for (let i = 0; i < n; i++) {
    transforms.push({
      ...randomAffine(),
      weight: round2(rand(0.4, 1.4)),
      colorIndex: clamp01(i / Math.max(1, n - 1) + rand(-0.12, 0.12)),
      variations: randomVariations(),
    })
  }
  ensureZInjector(transforms)
  return { name: `Wild ${serial}`, transforms, palette: randomPalette(), ...DEFAULT_TONE }
}

/** A nearby variation of `g` — explore around a flame you like. */
export function mutate(g: FlameGenome, serial: number, amt = 0.18): FlameGenome {
  const jitterRow = (r: Vec3): Vec3 => [r[0] + rand(-amt, amt), r[1] + rand(-amt, amt), r[2] + rand(-amt, amt)]
  const transforms = g.transforms.map((t) => {
    const variations = zeroVariations()
    for (const name of VARIATION_NAMES) {
      const base = t.variations[name]
      if (base > 0 || Math.random() < 0.15) variations[name] = Math.max(0, round2(base + rand(-amt, amt)))
    }
    return {
      rowX: jitterRow(t.rowX),
      rowY: jitterRow(t.rowY),
      rowZ: jitterRow(t.rowZ),
      translate: [t.translate[0] + rand(-amt, amt), t.translate[1] + rand(-amt, amt), t.translate[2] + rand(-amt, amt)] as Vec3,
      weight: Math.max(0.1, t.weight + rand(-amt, amt)),
      colorIndex: clamp01(t.colorIndex + rand(-amt, amt)),
      variations,
    }
  })
  ensureZInjector(transforms)
  const palette = g.palette.map((c) => [clamp01(c[0] + rand(-0.06, 0.06)), clamp01(c[1] + rand(-0.06, 0.06)), clamp01(c[2] + rand(-0.06, 0.06))] as Vec3)
  return { name: `Mutant ${serial}`, transforms, palette, brightness: g.brightness, gamma: g.gamma, k2: g.k2, highlightDesat: g.highlightDesat, pointBrightness: g.pointBrightness }
}

/** Cross-breed two flames — child takes each transform slot from one parent. */
export function crossover(a: FlameGenome, b: FlameGenome, serial: number): FlameGenome {
  const n = Math.max(a.transforms.length, b.transforms.length)
  const transforms: FlameTransform[] = []
  for (let i = 0; i < n; i++) {
    const inA = i < a.transforms.length
    const inB = i < b.transforms.length
    const src = inA && inB ? (Math.random() < 0.5 ? a : b) : inA ? a : b
    transforms.push(cloneTransform(src.transforms[i]))
  }
  ensureZInjector(transforms)
  const palette = (Math.random() < 0.5 ? a : b).palette.map((c) => [c[0], c[1], c[2]] as Vec3)
  return { name: `Hybrid ${serial}`, transforms, palette, brightness: a.brightness, gamma: a.gamma, k2: a.k2, highlightDesat: a.highlightDesat, pointBrightness: a.pointBrightness }
}
