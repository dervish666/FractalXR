import { zeroVariations, type FlameGenome, type FlameTransform, type VariationWeights } from './types'
import { themeColors } from './palettes'

function tx(
  rows: [number[], number[], number[]],
  translate: number[],
  weight: number,
  colorIndex: number,
  variations: Partial<VariationWeights>,
): FlameTransform {
  return {
    rowX: rows[0] as [number, number, number],
    rowY: rows[1] as [number, number, number],
    rowZ: rows[2] as [number, number, number],
    translate: translate as [number, number, number],
    weight,
    colorIndex,
    variations: { ...zeroVariations(), ...variations },
  }
}

/**
 * "Ember" — the hand-authored M0 genome. Three transforms; bubble3D + sinusoidal
 * guarantee genuine z-extent so it reads as a volumetric cloud, not a flat sheet.
 * Tunable live; aesthetics get refined on-device.
 */
export const EMBER: FlameGenome = {
  name: 'Ember',
  transforms: [
    // gentle contraction with a spherical fold — builds the dense core
    tx(
      [
        [0.62, -0.20, 0.10],
        [0.20, 0.62, -0.08],
        [-0.10, 0.08, 0.62],
      ],
      [0.10, 0.06, 0.04],
      1.0,
      0.05,
      { linear3D: 0.35, spherical: 0.65 },
    ),
    // swirl + bubble — throws filaments out and up into 3D
    tx(
      [
        [0.45, 0.30, -0.25],
        [-0.30, 0.45, 0.20],
        [0.25, -0.20, 0.50],
      ],
      [0.28, 0.34, -0.22],
      0.85,
      0.55,
      { swirl: 0.55, bubble3D: 0.55, linear3D: 0.15 },
    ),
    // sinusoidal lattice — fine structure and a second colour pole
    tx(
      [
        [0.40, 0.00, 0.18],
        [0.00, 0.40, 0.00],
        [-0.18, 0.00, 0.40],
      ],
      [-0.30, 0.20, 0.30],
      0.7,
      0.95,
      { sinusoidal: 0.7, bubble3D: 0.3 },
    ),
  ],
  palette: themeColors('Ember'),
  brightness: 0.32,
  gamma: 2.4,
  k2: 55,
  highlightDesat: 0.3,
  pointBrightness: 0.9,
}

/** "Aurora" — wispy sinusoidal lattice, cool greens. */
export const AURORA: FlameGenome = {
  name: 'Aurora',
  transforms: [
    tx(
      [
        [0.5, 0.0, 0.1],
        [0.0, 0.5, 0.0],
        [-0.1, 0.0, 0.5],
      ],
      [0.0, 0.1, 0.0],
      1.0,
      0.08,
      { linear3D: 0.4, sinusoidal: 0.5 },
    ),
    tx(
      [
        [0.45, 0.2, 0.0],
        [-0.2, 0.45, 0.1],
        [0.0, -0.1, 0.45],
      ],
      [0.22, -0.15, 0.25],
      0.8,
      0.5,
      { sinusoidal: 0.5, bubble3D: 0.5 },
    ),
    tx(
      [
        [0.4, 0.0, 0.2],
        [0.0, 0.45, 0.0],
        [-0.2, 0.0, 0.4],
      ],
      [-0.25, 0.2, -0.2],
      0.7,
      0.92,
      { linear3D: 0.3, spherical: 0.5, sinusoidal: 0.3 },
    ),
  ],
  palette: themeColors('Aurora'),
  brightness: 0.32,
  gamma: 2.4,
  k2: 55,
  highlightDesat: 0.25,
  pointBrightness: 0.9,
}

/** "Nautilus" — swirl spiral with a dense core, deep blues. */
export const NAUTILUS: FlameGenome = {
  name: 'Nautilus',
  transforms: [
    tx(
      [
        [0.6, -0.1, 0.0],
        [0.1, 0.6, 0.0],
        [0.0, 0.0, 0.6],
      ],
      [0.05, 0.0, 0.0],
      1.0,
      0.0,
      { spherical: 0.7, linear3D: 0.2 },
    ),
    tx(
      [
        [0.5, 0.35, -0.1],
        [-0.35, 0.5, 0.1],
        [0.1, -0.1, 0.5],
      ],
      [0.3, 0.2, -0.1],
      0.9,
      0.5,
      { swirl: 0.7, bubble3D: 0.4 },
    ),
    tx(
      [
        [0.45, 0.25, 0.1],
        [-0.25, 0.45, 0.0],
        [-0.1, 0.0, 0.5],
      ],
      [-0.2, 0.25, 0.2],
      0.7,
      0.95,
      { swirl: 0.4, linear3D: 0.3, bubble3D: 0.3 },
    ),
  ],
  palette: themeColors('Ocean'),
  brightness: 0.32,
  gamma: 2.4,
  k2: 60,
  highlightDesat: 0.3,
  pointBrightness: 0.9,
}

/** "Vortex" — swirling fire tendrils, red→gold. */
export const VORTEX: FlameGenome = {
  name: 'Vortex',
  transforms: [
    tx(
      [
        [0.55, 0.0, 0.05],
        [0.0, 0.55, 0.0],
        [-0.05, 0.0, 0.55],
      ],
      [0.0, 0.0, 0.0],
      1.0,
      0.05,
      { linear3D: 0.3, spherical: 0.55 },
    ),
    tx(
      [
        [0.5, 0.4, -0.15],
        [-0.4, 0.5, 0.15],
        [0.15, -0.15, 0.45],
      ],
      [0.35, 0.1, -0.2],
      0.9,
      0.5,
      { swirl: 0.65, bubble3D: 0.45, linear3D: 0.1 },
    ),
    tx(
      [
        [0.42, 0.1, 0.15],
        [-0.1, 0.42, 0.0],
        [-0.15, 0.0, 0.45],
      ],
      [-0.25, 0.3, 0.25],
      0.7,
      0.92,
      { swirl: 0.5, sinusoidal: 0.3, bubble3D: 0.3 },
    ),
  ],
  palette: themeColors('Inferno'),
  brightness: 0.3,
  gamma: 2.4,
  k2: 55,
  highlightDesat: 0.35,
  pointBrightness: 0.9,
}

/** "Thistle" — spherical shells and tendrils, violet→gold. */
export const THISTLE: FlameGenome = {
  name: 'Thistle',
  transforms: [
    tx(
      [
        [0.5, 0.0, 0.0],
        [0.0, 0.5, 0.0],
        [0.0, 0.0, 0.5],
      ],
      [0.0, 0.0, 0.0],
      1.0,
      0.1,
      { spherical: 0.6, bubble3D: 0.5 },
    ),
    tx(
      [
        [0.46, 0.18, -0.1],
        [-0.18, 0.46, 0.12],
        [0.1, -0.12, 0.46],
      ],
      [0.25, 0.28, 0.18],
      0.85,
      0.55,
      { bubble3D: 0.6, swirl: 0.3 },
    ),
    tx(
      [
        [0.4, 0.0, 0.2],
        [0.0, 0.44, 0.0],
        [-0.2, 0.0, 0.4],
      ],
      [-0.28, 0.18, -0.25],
      0.7,
      0.95,
      { spherical: 0.4, sinusoidal: 0.4, bubble3D: 0.3 },
    ),
  ],
  palette: themeColors('Rose'),
  brightness: 0.32,
  gamma: 2.4,
  k2: 55,
  highlightDesat: 0.3,
  pointBrightness: 0.9,
}

/** "Glacier" — tight swirl spiral, cool blues. */
export const GLACIER: FlameGenome = {
  name: 'Glacier',
  transforms: [
    tx([[0.55, -0.18, 0.05], [0.18, 0.55, 0.0], [0.0, 0.0, 0.55]], [0.04, 0.0, 0.0], 1.0, 0.0, { spherical: 0.65, linear3D: 0.25 }),
    tx([[0.48, 0.4, -0.12], [-0.4, 0.48, 0.12], [0.12, -0.12, 0.46]], [0.32, 0.18, -0.12], 0.9, 0.5, { swirl: 0.75, bubble3D: 0.35 }),
    tx([[0.42, 0.22, 0.12], [-0.22, 0.42, 0.0], [-0.12, 0.0, 0.48]], [-0.18, 0.28, 0.22], 0.65, 0.95, { swirl: 0.45, linear3D: 0.3, bubble3D: 0.3 }),
  ],
  palette: themeColors('Ice'),
  brightness: 0.3,
  gamma: 2.4,
  k2: 60,
  highlightDesat: 0.3,
  pointBrightness: 0.9,
}

/** "Orchid" — spherical shells and tendrils, violets. */
export const ORCHID: FlameGenome = {
  name: 'Orchid',
  transforms: [
    tx([[0.52, 0.0, 0.0], [0.0, 0.52, 0.0], [0.0, 0.0, 0.52]], [0.0, 0.0, 0.0], 1.0, 0.1, { spherical: 0.55, bubble3D: 0.55 }),
    tx([[0.44, 0.2, -0.12], [-0.2, 0.44, 0.14], [0.12, -0.14, 0.44]], [0.26, 0.3, 0.2], 0.85, 0.55, { bubble3D: 0.65, swirl: 0.25, sinusoidal: 0.2 }),
    tx([[0.4, 0.0, 0.22], [0.0, 0.42, 0.0], [-0.22, 0.0, 0.4]], [-0.3, 0.16, -0.26], 0.7, 0.95, { spherical: 0.4, sinusoidal: 0.45, bubble3D: 0.3 }),
  ],
  palette: themeColors('Violet'),
  brightness: 0.32,
  gamma: 2.4,
  k2: 55,
  highlightDesat: 0.3,
  pointBrightness: 0.9,
}

/** "Helix" — broad twisted swirl, electric neon. */
export const HELIX: FlameGenome = {
  name: 'Helix',
  transforms: [
    tx([[0.62, 0.0, 0.14], [0.0, 0.6, 0.0], [-0.14, 0.0, 0.6]], [0.05, 0.18, 0.0], 1.0, 0.05, { linear3D: 0.3, spherical: 0.5, sinusoidal: 0.3 }),
    tx([[0.52, 0.46, -0.2], [-0.46, 0.52, 0.2], [0.2, -0.2, 0.48]], [0.42, 0.05, -0.24], 0.95, 0.5, { swirl: 0.75, bubble3D: 0.45 }),
    tx([[0.46, 0.14, 0.24], [-0.14, 0.48, 0.0], [-0.24, 0.0, 0.48]], [-0.3, 0.34, 0.34], 0.72, 0.92, { swirl: 0.5, sinusoidal: 0.3, bubble3D: 0.4 }),
  ],
  palette: themeColors('Neon'),
  brightness: 0.42,
  gamma: 2.4,
  k2: 55,
  highlightDesat: 0.35,
  pointBrightness: 0.9,
}

/** The explore-loop gallery. */
export const GALLERY: FlameGenome[] = [EMBER, AURORA, NAUTILUS, VORTEX, THISTLE, GLACIER, ORCHID, HELIX]
