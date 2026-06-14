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
  formula: 'mandelbulb' | 'mandelbox'
  power: number // Mandelbulb polynomial power (8 = classic)
  powerBreath: number // Mandelbulb power-breath amplitude
  scale: number // Mandelbox scale (negative = architectural look)
  scaleBreath: number // Mandelbox scale-breath amplitude
  minR: number // Mandelbox sphere-fold min radius
  fixedR: number // Mandelbox sphere-fold fixed radius
  mandelbulb: boolean // c = p (true) vs Julia c (false)
  juliaC: Vec3
  juliaOrbit: number // Julia-C orbit amplitude (flowing Juliabulb)
  bound: number // seed / reseed ball radius (Mandelboxes are bigger)
  speed: number // breath / orbit speed
  palette: Vec3[]
}

const hex = (h: string): Vec3 => [parseInt(h.slice(0, 2), 16) / 255, parseInt(h.slice(2, 4), 16) / 255, parseInt(h.slice(4, 6), 16) / 255]
// homage palette lifted from a Mandelbulber surface gradient
const MANDELBULBER_PAL: Vec3[] = ['fd6029', 'f5bd22', '698403', '0b5e87', '3b9fee', 'a51c64', 'd4ffd4'].map(hex)

const mbulb = (name: string, power: number, powerBreath: number, speed: number, theme: string): BulbGenome => ({
  name, formula: 'mandelbulb', power, powerBreath, scale: 2, scaleBreath: 0, minR: 0.5, fixedR: 1, mandelbulb: true, juliaC: [0, 0, 0], juliaOrbit: 0, bound: 1.3, speed, palette: themeColors(theme),
})
const mbox = (name: string, scale: number, scaleBreath: number, speed: number, palette: Vec3[]): BulbGenome => ({
  name, formula: 'mandelbox', power: 8, powerBreath: 0, scale, scaleBreath, minR: 0.5, fixedR: 1, mandelbulb: true, juliaC: [0, 0, 0], juliaOrbit: 0, bound: 3.2 + Math.abs(scale), speed, palette,
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
]

let serial = 0
const rand = (a: number, b: number): number => a + Math.random() * (b - a)
const pick = <T>(arr: readonly T[]): T => arr[Math.floor(Math.random() * arr.length)]
const theme = (): Vec3[] => themeColors(pick(THEMES).name)

/** A fresh random bulb — Mandelbulb or Mandelbox. */
export function randomBulb(): BulbGenome {
  serial++
  if (Math.random() < 0.4) {
    const scale = rand(-2.2, 2.6)
    return { name: `Bulb ${serial}`, formula: 'mandelbox', power: 8, powerBreath: 0, scale, scaleBreath: rand(0.1, 0.3), minR: rand(0.3, 0.6), fixedR: 1.0, mandelbulb: true, juliaC: [0, 0, 0], juliaOrbit: 0, bound: 3.0 + Math.abs(scale), speed: rand(0.06, 0.12), palette: theme() }
  }
  const julia = Math.random() < 0.2
  return { name: `Bulb ${serial}`, formula: 'mandelbulb', power: Math.round(rand(3, 13)), powerBreath: julia ? 0 : rand(1, 3.5), scale: 2, scaleBreath: 0, minR: 0.5, fixedR: 1, mandelbulb: !julia, juliaC: [rand(-0.32, 0.32), rand(-0.32, 0.32), rand(-0.28, 0.28)], juliaOrbit: julia ? rand(0.08, 0.22) : 0, bound: 1.3, speed: rand(0.06, 0.14), palette: theme() }
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
