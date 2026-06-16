// The variation set. bubble3D is a z-injector: at least one z-injecting
// variation must be present or a 3D flame collapses to a flat 2D sheet.
// ORDER IS LOAD-BEARING: encode.ts writes varW[i*NVAR + v] in this order, and the
// shader's applyVars() dispatches its branches in the SAME order. Append, never reorder.
export const VARIATION_NAMES = [
  'linear3D', 'spherical', 'swirl', 'sinusoidal', 'bubble3D',
  'horseshoe', 'handkerchief', 'disc', 'spiral', 'hyperbolic', 'cylinder', 'eyefish',
] as const
export type VariationName = (typeof VARIATION_NAMES)[number]
export const NVAR = VARIATION_NAMES.length // 12 — keep the shader's `#define NVAR` in sync
export const MAX_TRANSFORMS = 8

/** Variations that add genuine z-extent. A valid 3D genome needs ≥1 of these with weight > 0. */
export const Z_INJECTORS: VariationName[] = ['bubble3D', 'sinusoidal', 'spherical', 'eyefish']

export type Vec3 = [number, number, number]
export type VariationWeights = Record<VariationName, number>

export interface FlameTransform {
  /** 3×3 linear part, stored as rows so it uploads as plain vec3 uniform arrays. */
  rowX: Vec3
  rowY: Vec3
  rowZ: Vec3
  /** Translation. */
  translate: Vec3
  /** Unnormalised selection weight (probability ∝ weight). */
  weight: number
  /** Colour coordinate this transform pulls toward, 0..1 into the palette. */
  colorIndex: number
  variations: VariationWeights
}

export interface FlameGenome {
  name: string
  transforms: FlameTransform[]
  /** Control colours (linear RGB, 0..1) interpolated into a 256-entry LUT. */
  palette: Vec3[]
  /** Display tuning. */
  brightness: number // post-accumulation exposure
  gamma: number
  k2: number // log-density curve constant
  highlightDesat: number // 0 = keep colour in bright cores, 1 = clip highlights to white
  /** Per-point sprite brightness multiplier feeding the HDR accumulation. */
  pointBrightness: number
}

export function zeroVariations(): VariationWeights {
  return {
    linear3D: 0, spherical: 0, swirl: 0, sinusoidal: 0, bubble3D: 0,
    horseshoe: 0, handkerchief: 0, disc: 0, spiral: 0, hyperbolic: 0, cylinder: 0, eyefish: 0,
  }
}
