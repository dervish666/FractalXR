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

// ── curated from the breeder (harvested, screened on-device, retuned) ──────────

/** "Geode" — swirl shell wrapped around a bubble core, crystalline spectrum. */
export const GEODE: FlameGenome = {
  name: 'Geode',
  transforms: [
    tx([[-0.1643, -0.4804, 0.0952], [-0.0461, -0.1176, -0.3758], [0.304, -0.2775, -0.0055]], [-0.008, 0.2839, -0.2185], 1.02, 0.0, { swirl: 0.99 }),
    tx([[0.1263, -0.5058, -0.0064], [-0.1363, -0.0519, 0.4553], [-0.4182, -0.1358, -0.1503]], [0.0618, -0.151, 0.0294], 1.18, 0.58, { spherical: 0.59, bubble3D: 0.92 }),
    tx([[-0.3009, 0.0394, 0.4556], [0.34, -0.1621, 0.3402], [0.1966, 0.3407, 0.1091]], [0.0756, -0.1141, -0.0408], 0.7, 1.0, { linear3D: 0.84 }),
  ],
  palette: themeColors('Spectrum'),
  brightness: 0.36,
  gamma: 2.4,
  k2: 55,
  highlightDesat: 0.3,
  pointBrightness: 0.95,
}

/** "Pinwheel" — spherical spiral galaxy, warm sunset gold. */
export const PINWHEEL: FlameGenome = {
  name: 'Pinwheel',
  transforms: [
    tx([[0.0399, 0.3854, -0.4128], [-0.5553, 0.0987, 0.0325], [0.0934, 0.4217, 0.3697]], [0.0628, 0.1492, -0.2491], 0.63, 0.0, { linear3D: 0.8, spherical: 0.66 }),
    tx([[-0.019, -0.3909, 0.1008], [0.2455, -0.1009, -0.2342], [0.2556, 0.0679, 0.2325]], [-0.311, -0.1832, 0.0489], 0.55, 0.56, { linear3D: 0.54, swirl: 0.51 }),
    tx([[-0.4962, -0.1838, -0.0795], [-0.0066, -0.1767, 0.3917], [-0.2498, 0.3699, 0.1476]], [0.3087, -0.2589, -0.1094], 0.78, 0.96, { linear3D: 0.96, spherical: 0.83, sinusoidal: 0.82 }),
  ],
  palette: themeColors('Sunset'),
  brightness: 0.36,
  gamma: 2.4,
  k2: 55,
  highlightDesat: 0.3,
  pointBrightness: 0.95,
}

/** "Luna" — minimal two-transform moth-wing, nebula teals. */
export const LUNA: FlameGenome = {
  name: 'Luna',
  transforms: [
    tx([[-0.0305, 0.1771, 0.454], [-0.1548, -0.2855, 0.2306], [0.3637, -0.1067, 0.1363]], [-0.2867, -0.1352, 0.032], 1.23, 0.03, { spherical: 0.71, sinusoidal: 0.51 }),
    tx([[-0.1607, 0.3915, 0.1378], [0.2746, 0.2061, -0.314], [-0.2516, -0.025, -0.4307]], [0.3148, -0.1754, -0.1432], 0.49, 1.0, { linear3D: 0.5, swirl: 0.6 }),
  ],
  palette: themeColors('Nebula'),
  brightness: 0.36,
  gamma: 2.4,
  k2: 55,
  highlightDesat: 0.3,
  pointBrightness: 0.95,
}

/** "Plasma" — swirl + spherical two-lobe, candy cyan meeting magenta. */
export const PLASMA: FlameGenome = {
  name: 'Plasma',
  transforms: [
    tx([[0.4513, 0.2203, 0.0722], [-0.0907, -0.0325, 0.3985], [0.3514, -0.2914, 0.0101]], [0.1922, 0.2086, 0.0534], 1.07, 0.11, { linear3D: 0.42, swirl: 0.89 }),
    tx([[0.0521, -0.2187, 0.3211], [0.5108, -0.0708, -0.1256], [0.1918, 0.2481, 0.2472]], [-0.1458, 0.107, -0.1612], 1.06, 0.23, { swirl: 0.99, bubble3D: 0.49 }),
    tx([[0.2377, 0.0844, -0.3441], [0.2035, 0.0633, 0.405], [0.0773, -0.426, -0.008]], [0.2673, -0.2294, 0.2413], 1.33, 0.64, { spherical: 0.88, swirl: 0.38 }),
    tx([[-0.0977, 0.4448, -0.0769], [-0.3706, -0.0852, 0.2183], [0.1286, 0.0925, 0.5708]], [-0.0426, -0.0083, 0.0624], 1.15, 1.0, { linear3D: 0.31 }),
  ],
  palette: themeColors('Candy'),
  brightness: 0.34,
  gamma: 2.4,
  k2: 55,
  highlightDesat: 0.3,
  pointBrightness: 0.95,
}

/** "Verdant" — busy four-transform tangle, toxic greens. */
export const VERDANT: FlameGenome = {
  name: 'Verdant',
  transforms: [
    tx([[0.4191, 0.1904, -0.0863], [-0.1724, 0.2594, 0.2179], [0.2539, -0.1381, 0.2903]], [-0.2564, -0.3099, -0.1896], 1.01, 0.0, { swirl: 0.58 }),
    tx([[0.0877, 0.2756, -0.1822], [0.4951, 0.0496, 0.1521], [0.2604, -0.1872, -0.2278]], [-0.2661, -0.0886, -0.1303], 0.99, 0.41, { linear3D: 0.56 }),
    tx([[-0.126, 0.2547, -0.2959], [0.1592, -0.3652, -0.2134], [-0.3399, -0.2654, 0.0098]], [0.1587, 0.0095, -0.1112], 0.43, 0.67, { swirl: 0.53, bubble3D: 0.77 }),
    tx([[-0.0868, -0.024, -0.4274], [-0.1852, -0.3583, 0.0573], [-0.4207, 0.1627, 0.063]], [0.1364, -0.0529, -0.2729], 1.11, 0.95, { linear3D: 0.86, spherical: 0.61, bubble3D: 0.79 }),
  ],
  palette: themeColors('Toxic'),
  brightness: 0.36,
  gamma: 2.4,
  k2: 55,
  highlightDesat: 0.3,
  pointBrightness: 0.95,
}

/** The explore-loop gallery — 13 hand-tuned + breeder-curated flames. */
export const GALLERY: FlameGenome[] = [
  EMBER, AURORA, NAUTILUS, VORTEX, THISTLE, GLACIER, ORCHID, HELIX,
  GEODE, PINWHEEL, LUNA, PLASMA, VERDANT,
]
