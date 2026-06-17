import type { Vec3 } from './types'
import { themeColors, THEMES } from './palettes'
import { blendPalettes } from './morph'

/**
 * A bulb "genome" — the parametric analog of a FlameGenome. Two formulas so far
 * (Mandelbulb + Mandelbox), each a distance estimate the point cloud relaxes onto.
 * Drop new finds (e.g. from Mandelbulber) straight into BULB_GALLERY. The live morph
 * driver (main.ts) animates power (Mandelbulb) or scale (Mandelbox) from `*Breath`.
 */
export interface BulbGenome {
  name: string
  formula: 'mandelbulb' | 'mandelbox' | 'kifs' | 'quat'
  power: number // Mandelbulb polynomial power (8 = classic)
  powerBreath: number // Mandelbulb power-breath amplitude
  scale: number // Mandelbox / KIFS per-iteration scale (negative box = architectural look)
  scaleBreath: number // Mandelbox scale-breath amplitude
  minR: number // Mandelbox sphere-fold min radius
  fixedR: number // Mandelbox sphere-fold fixed radius / KIFS bounding-sphere radius
  mandelbulb: boolean // c = p (true) vs Julia c (false)
  juliaC: Vec3 // Julia constant — also the KIFS fold offset
  juliaOrbit: number // Julia-C orbit amplitude (flowing Juliabulb)
  kAngleA: number // KIFS fold rotation A (radians)
  kAngleB: number // KIFS fold rotation B (radians)
  kAngleBreath: number // KIFS angle-breath amplitude — slowly turns the kaleidoscope
  bound: number // seed / reseed ball radius (Mandelboxes are bigger)
  speed: number // breath / orbit speed
  palette: Vec3[]
}

const hex = (h: string): Vec3 => [parseInt(h.slice(0, 2), 16) / 255, parseInt(h.slice(2, 4), 16) / 255, parseInt(h.slice(4, 6), 16) / 255]
// homage palette lifted from a Mandelbulber surface gradient
const MANDELBULBER_PAL: Vec3[] = ['fd6029', 'f5bd22', '698403', '0b5e87', '3b9fee', 'a51c64', 'd4ffd4'].map(hex)

const mbulb = (name: string, power: number, powerBreath: number, speed: number, theme: string): BulbGenome => ({
  name, formula: 'mandelbulb', power, powerBreath, scale: 2, scaleBreath: 0, minR: 0.5, fixedR: 1, mandelbulb: true, juliaC: [0, 0, 0], juliaOrbit: 0, kAngleA: 0, kAngleB: 0, kAngleBreath: 0, bound: 1.3, speed, palette: themeColors(theme),
})
const mbox = (name: string, scale: number, scaleBreath: number, speed: number, palette: Vec3[]): BulbGenome => ({
  name, formula: 'mandelbox', power: 8, powerBreath: 0, scale, scaleBreath, minR: 0.5, fixedR: 1, mandelbulb: true, juliaC: [0, 0, 0], juliaOrbit: 0, kAngleA: 0, kAngleB: 0, kAngleBreath: 0, bound: 3.2 + Math.abs(scale), speed, palette,
})
// Kaleidoscopic IFS: scale + fold offset + two rotation angles span a huge form-space.
const kifs = (name: string, scale: number, offset: Vec3, aA: number, aB: number, breath: number, fixedR: number, speed: number, palette: Vec3[]): BulbGenome => ({
  name, formula: 'kifs', power: 8, powerBreath: 0, scale, scaleBreath: 0, minR: 0.5, fixedR, mandelbulb: true, juliaC: offset, juliaOrbit: 0, kAngleA: aA, kAngleB: aB, kAngleBreath: breath, bound: 2.0, speed, palette,
})
// Quaternion Julia: z → z² + c. `c` (the Julia-C slot) picks the form; juliaOrbit gives it life.
const quat = (name: string, c: Vec3, orbit: number, speed: number, palette: Vec3[]): BulbGenome => ({
  name, formula: 'quat', power: 8, powerBreath: 0, scale: 2, scaleBreath: 0, minR: 0.5, fixedR: 1, mandelbulb: false, juliaC: c, juliaOrbit: orbit, kAngleA: 0, kAngleB: 0, kAngleBreath: 0, bound: 1.4, speed, palette,
})

/** Curated bulbs — a spread of Mandelbulb powers + a couple of Mandelboxes. Easy to extend. */
export const BULB_GALLERY: BulbGenome[] = [
  mbulb('Classic', 8, 2.5, 0.09, 'Ember'),
  mbulb('Pollen', 3, 1.0, 0.12, 'Sunset'),
  mbulb('Quartz', 4, 1.5, 0.1, 'Violet'),
  mbulb('Starflower', 5, 1.5, 0.11, 'Spectrum'),
  mbulb('Nebula', 9, 2.5, 0.08, 'Nebula'),
  mbulb('Coral', 12, 2.5, 0.07, 'Inferno'),
  mbulb('Spire', 16, 2.0, 0.06, 'Neon'),
  mbulb('Frostbulb', 8, 3.0, 0.08, 'Ice'),
  mbox('Mandelbox', 2.0, 0.25, 0.08, themeColors('Toxic')),
  mbox('Citadel', -1.6, 0.15, 0.07, MANDELBULBER_PAL),
  kifs('Lattice', 2.0, [1, 1, 1], 0, 0, 0.06, 1.0, 0.05, themeColors('Ice')),
  kifs('Cathedral', 1.9, [0.9, 1.3, 0.6], 0.32, -0.2, 0.1, 0.9, 0.06, MANDELBULBER_PAL),
  kifs('Snowflake', 2.1, [1.0, 0.7, 1.1], -0.42, 0.5, 0.14, 0.8, 0.07, themeColors('Spectrum')),
  kifs('Thornwood', 1.75, [0.6, 1.15, 0.8], 0.6, 0.25, 0.1, 0.85, 0.06, themeColors('Ember')),
  quat('Quaternion', [-0.45, 0.3, 0.5], 0.05, 0.08, themeColors('Violet')),
  quat('Mercury', [-0.2, 0.6, 0.2], 0.06, 0.09, themeColors('Ice')),
  quat('Cobalt', [-0.291, -0.4, 0.339], 0.04, 0.07, themeColors('Neon')),
  quat('Halcyon', [-0.5, 0.5, 0.0], 0.05, 0.08, themeColors('Spectrum')),
]

let serial = 0
const rand = (a: number, b: number): number => a + Math.random() * (b - a)
const pick = <T>(arr: readonly T[]): T => arr[Math.floor(Math.random() * arr.length)]
const theme = (): Vec3[] => themeColors(pick(THEMES).name)

/** A fresh random bulb. Pass `formula` to stay within a family (callers bias toward the current
 *  one so morphs lerp smoothly instead of reseed-jumping between formulas); omit for any formula. */
export function randomBulb(formula?: BulbGenome['formula']): BulbGenome {
  serial++
  const f =
    formula ??
    (() => {
      const roll = Math.random()
      return roll < 0.25 ? 'kifs' : roll < 0.45 ? 'quat' : roll < 0.65 ? 'mandelbox' : 'mandelbulb'
    })()
  if (f === 'kifs') {
    // Kaleidoscopic IFS: random scale + fold offset + rotation angles
    const sign = (): number => (Math.random() < 0.5 ? -1 : 1)
    return { name: `Bulb ${serial}`, formula: 'kifs', power: 8, powerBreath: 0, scale: rand(1.6, 2.4), scaleBreath: 0, minR: 0.5, fixedR: rand(0.7, 1.15), mandelbulb: true, juliaC: [rand(0.45, 1.3) * sign(), rand(0.5, 1.4), rand(0.45, 1.2) * sign()], juliaOrbit: 0, kAngleA: rand(-0.7, 0.7), kAngleB: rand(-0.7, 0.7), kAngleBreath: rand(0.05, 0.18), bound: 2.0, speed: rand(0.05, 0.11), palette: theme() }
  }
  if (f === 'quat') {
    // Quaternion Julia: random c constant (the form selector), gentle orbit for life
    return { name: `Bulb ${serial}`, formula: 'quat', power: 8, powerBreath: 0, scale: 2, scaleBreath: 0, minR: 0.5, fixedR: 1, mandelbulb: false, juliaC: [rand(-0.55, 0.55), rand(-0.55, 0.55), rand(-0.55, 0.55)], juliaOrbit: rand(0.03, 0.1), kAngleA: 0, kAngleB: 0, kAngleBreath: 0, bound: 1.4, speed: rand(0.06, 0.1), palette: theme() }
  }
  if (f === 'mandelbox') {
    const scale = rand(-2.2, 2.6)
    return { name: `Bulb ${serial}`, formula: 'mandelbox', power: 8, powerBreath: 0, scale, scaleBreath: rand(0.1, 0.3), minR: rand(0.3, 0.6), fixedR: 1.0, mandelbulb: true, juliaC: [0, 0, 0], juliaOrbit: 0, kAngleA: 0, kAngleB: 0, kAngleBreath: 0, bound: 3.0 + Math.abs(scale), speed: rand(0.06, 0.12), palette: theme() }
  }
  const julia = Math.random() < 0.2
  return { name: `Bulb ${serial}`, formula: 'mandelbulb', power: Math.round(rand(3, 13)), powerBreath: julia ? 0 : rand(1, 3.5), scale: 2, scaleBreath: 0, minR: 0.5, fixedR: 1, mandelbulb: !julia, juliaC: [rand(-0.32, 0.32), rand(-0.32, 0.32), rand(-0.28, 0.28)], juliaOrbit: julia ? rand(0.08, 0.22) : 0, kAngleA: 0, kAngleB: 0, kAngleBreath: 0, bound: 1.3, speed: rand(0.06, 0.14), palette: theme() }
}

/** A nearby variation — nudge the family's key params. */
export function mutateBulb(b: BulbGenome): BulbGenome {
  serial++
  return {
    ...b,
    name: `Bulb ${serial}`,
    power: Math.max(2, Math.round(b.power + rand(-2, 2))),
    powerBreath: Math.max(0, b.powerBreath + rand(-1, 1)),
    scale: b.scale + rand(-0.3, 0.3),
    juliaC: [b.juliaC[0] + rand(-0.1, 0.1), b.juliaC[1] + rand(-0.1, 0.1), b.juliaC[2] + rand(-0.1, 0.1)],
    kAngleA: b.kAngleA + rand(-0.15, 0.15), // harmless for non-KIFS (those ignore the angles)
    kAngleB: b.kAngleB + rand(-0.15, 0.15),
  }
}

/**
 * Interpolate one bulb genome into another at t∈[0,1] — the bulb analog of
 * interpolateGenome. SAME formula: every continuous DE param melts smoothly, so the
 * point cloud (which re-relaxes every frame) chases a continuously deforming isosurface
 * — the gorgeous flame-style morph. DIFFERENT formula: the DE can't be lerped (it's a
 * discrete shader switch), so structural params snap to the target and only the palette
 * crossfades; the caller reseeds so the cloud reforms onto the new surface.
 */
export function interpolateBulb(a: BulbGenome, b: BulbGenome, t: number): BulbGenome {
  const same = a.formula === b.formula
  const L = (x: number, y: number): number => x + (y - x) * t
  // when same formula, lerp; otherwise snap to the target (b)
  const S = (x: number, y: number): number => (same ? L(x, y) : y)
  return {
    name: b.name,
    formula: b.formula,
    // a discrete c=p ⇄ Julia flip can't lerp; switch at the midpoint when the cloud is most dispersed
    mandelbulb: t < 0.5 ? a.mandelbulb : b.mandelbulb,
    power: S(a.power, b.power),
    powerBreath: L(a.powerBreath, b.powerBreath),
    scale: S(a.scale, b.scale),
    scaleBreath: L(a.scaleBreath, b.scaleBreath),
    minR: S(a.minR, b.minR),
    fixedR: S(a.fixedR, b.fixedR),
    juliaC: [S(a.juliaC[0], b.juliaC[0]), S(a.juliaC[1], b.juliaC[1]), S(a.juliaC[2], b.juliaC[2])],
    juliaOrbit: L(a.juliaOrbit, b.juliaOrbit),
    // KIFS angles lerp within the family — the kaleidoscope melts; snap across formulas
    kAngleA: S(a.kAngleA, b.kAngleA),
    kAngleB: S(a.kAngleB, b.kAngleB),
    kAngleBreath: L(a.kAngleBreath, b.kAngleBreath),
    bound: S(a.bound, b.bound), // snap across formulas so framing matches the (reseeded) surface
    speed: L(a.speed, b.speed),
    palette: blendPalettes(a.palette, b.palette, t),
  }
}

/** Flip between c=p and Julia (the "cross-breed" analog) — works for both formulas. */
export function flipBulbKind(b: BulbGenome): BulbGenome {
  serial++
  const toJulia = b.mandelbulb
  return {
    ...b,
    name: `Bulb ${serial}`,
    mandelbulb: !toJulia,
    powerBreath: toJulia ? 0 : b.formula === 'mandelbulb' ? 2.5 : 0,
    juliaOrbit: toJulia && b.formula === 'mandelbulb' ? 0.16 : 0,
  }
}
