import type { Vec3 } from './types'

export interface Theme {
  name: string
  colors: Vec3[] // 5 control colours, dark → light
}

/**
 * Curated colour themes — used by presets, the Recolor action, and (sometimes) breeding.
 * Each travels across SEVERAL hues (not just light→dark of one colour) so the flame's
 * colour-coding shows real detail rather than collapsing to a single tone.
 */
export const THEMES: Theme[] = [
  { name: 'Ember', colors: [[0.02, 0.02, 0.12], [0.35, 0.04, 0.45], [0.95, 0.15, 0.4], [1.0, 0.6, 0.1], [1.0, 0.95, 0.65]] },
  { name: 'Ice', colors: [[0.02, 0.0, 0.2], [0.0, 0.4, 0.75], [0.3, 0.85, 0.95], [0.85, 1.0, 0.95], [1.0, 0.92, 0.6]] },
  { name: 'Inferno', colors: [[0.06, 0.0, 0.12], [0.45, 0.0, 0.3], [0.95, 0.1, 0.05], [1.0, 0.55, 0.0], [1.0, 0.95, 0.5]] },
  { name: 'Neon', colors: [[0.12, 0.0, 0.25], [0.75, 0.0, 0.75], [1.0, 0.1, 0.5], [0.0, 0.85, 1.0], [0.55, 1.0, 0.8]] },
  { name: 'Spectrum', colors: [[0.15, 0.0, 0.45], [0.0, 0.45, 0.95], [0.1, 0.85, 0.3], [1.0, 0.85, 0.0], [1.0, 0.25, 0.2]] },
  { name: 'Nebula', colors: [[0.05, 0.0, 0.18], [0.45, 0.0, 0.55], [0.85, 0.1, 0.6], [0.3, 0.35, 0.95], [0.75, 0.9, 1.0]] },
  { name: 'Sunset', colors: [[0.1, 0.0, 0.25], [0.5, 0.05, 0.45], [0.97, 0.25, 0.35], [1.0, 0.6, 0.2], [1.0, 0.95, 0.55]] },
  { name: 'Aurora', colors: [[0.0, 0.05, 0.12], [0.0, 0.5, 0.45], [0.25, 0.95, 0.5], [0.5, 0.7, 1.0], [1.0, 0.7, 0.85]] },
  { name: 'Toxic', colors: [[0.02, 0.06, 0.05], [0.0, 0.45, 0.18], [0.45, 0.9, 0.0], [0.9, 1.0, 0.1], [1.0, 1.0, 0.65]] },
  { name: 'Ocean', colors: [[0.0, 0.0, 0.2], [0.0, 0.35, 0.6], [0.0, 0.72, 0.6], [0.45, 0.95, 0.7], [1.0, 0.9, 0.45]] },
  { name: 'Rose', colors: [[0.1, 0.0, 0.12], [0.5, 0.0, 0.3], [0.92, 0.12, 0.45], [1.0, 0.55, 0.45], [0.95, 0.95, 0.6]] },
  { name: 'Violet', colors: [[0.06, 0.0, 0.2], [0.4, 0.0, 0.6], [0.85, 0.1, 0.7], [1.0, 0.5, 0.55], [0.95, 0.95, 0.55]] },
  { name: 'FireIce', colors: [[0.0, 0.12, 0.45], [0.25, 0.65, 0.95], [0.95, 0.92, 0.92], [1.0, 0.5, 0.1], [1.0, 0.18, 0.0]] },
  { name: 'Candy', colors: [[0.15, 0.0, 0.22], [0.92, 0.1, 0.6], [1.0, 0.5, 0.3], [1.0, 0.9, 0.35], [0.4, 0.92, 0.92]] },
  // --- wild / full-spectrum themes (added on request — bigger hue travel) ---
  { name: 'Rainbow', colors: [[0.5, 0.0, 0.7], [0.0, 0.35, 1.0], [0.0, 0.92, 0.35], [1.0, 0.88, 0.0], [1.0, 0.12, 0.15]] }, // violet→blue→green→yellow→red
  { name: 'Prism', colors: [[0.45, 0.0, 0.8], [0.0, 0.6, 1.0], [0.25, 1.0, 0.6], [1.0, 1.0, 0.35], [1.0, 0.45, 0.8]] }, // bright pastel spectrum
  { name: 'Vaporwave', colors: [[0.12, 0.0, 0.35], [0.55, 0.0, 0.95], [1.0, 0.1, 0.7], [0.0, 0.85, 1.0], [0.7, 1.0, 1.0]] }, // indigo→purple→hot-pink→cyan
  { name: 'Acid', colors: [[0.1, 0.0, 0.12], [0.7, 0.0, 1.0], [0.25, 1.0, 0.0], [1.0, 0.92, 0.0], [1.0, 0.0, 0.6]] }, // clashing neon: purple/lime/yellow/magenta
  { name: 'Iridescent', colors: [[0.02, 0.06, 0.18], [0.18, 0.0, 0.55], [0.0, 0.65, 0.7], [0.45, 0.98, 0.5], [1.0, 0.45, 0.88]] }, // oilslick sheen
]

/** Look up a theme's colours by name (cloned so callers can't mutate the source). */
export function themeColors(name: string): Vec3[] {
  const t = THEMES.find((x) => x.name === name) ?? THEMES[0]
  return t.colors.map((c) => [c[0], c[1], c[2]] as Vec3)
}
