import { Vector3 } from 'three'
import { MAX_TRANSFORMS, NVAR, VARIATION_NAMES, type FlameGenome } from './types'

/** Shader-ready form of a genome: padded uniform arrays + a selection CDF. */
export interface EncodedFlame {
  numT: number
  rowX: Vector3[]
  rowY: Vector3[]
  rowZ: Vector3[]
  b: Vector3[]
  cdf: Float32Array // length MAX_TRANSFORMS, cumulative normalised weights (cdf[numT-1..] = 1)
  color: Float32Array // length MAX_TRANSFORMS
  varW: Float32Array // length MAX_TRANSFORMS * NVAR
}

const IDENTITY_ROWS: [Vector3, Vector3, Vector3] = [
  new Vector3(1, 0, 0),
  new Vector3(0, 1, 0),
  new Vector3(0, 0, 1),
]

export function encodeFlame(g: FlameGenome): EncodedFlame {
  const n = Math.max(1, Math.min(g.transforms.length, MAX_TRANSFORMS))

  const rowX: Vector3[] = []
  const rowY: Vector3[] = []
  const rowZ: Vector3[] = []
  const b: Vector3[] = []
  const cdf = new Float32Array(MAX_TRANSFORMS)
  const color = new Float32Array(MAX_TRANSFORMS)
  const varW = new Float32Array(MAX_TRANSFORMS * NVAR)

  let total = 0
  for (let i = 0; i < n; i++) total += Math.max(0, g.transforms[i].weight)
  if (total <= 0) total = 1

  let acc = 0
  for (let i = 0; i < MAX_TRANSFORMS; i++) {
    if (i < n) {
      const t = g.transforms[i]
      rowX.push(new Vector3().fromArray(t.rowX))
      rowY.push(new Vector3().fromArray(t.rowY))
      rowZ.push(new Vector3().fromArray(t.rowZ))
      b.push(new Vector3().fromArray(t.translate))
      acc += Math.max(0, t.weight) / total
      cdf[i] = acc
      color[i] = t.colorIndex
      // `?? 0`: an older-schema genome (e.g. a favourite saved before a variation was added)
      // lacks the newer keys — undefined would coerce to NaN here and corrupt the transform.
      for (let v = 0; v < NVAR; v++) varW[i * NVAR + v] = t.variations[VARIATION_NAMES[v]] ?? 0
    } else {
      // padding rows are never selected (cdf already saturated), but must be valid uniforms
      rowX.push(IDENTITY_ROWS[0].clone())
      rowY.push(IDENTITY_ROWS[1].clone())
      rowZ.push(IDENTITY_ROWS[2].clone())
      b.push(new Vector3())
      cdf[i] = 1
      color[i] = 0
    }
  }
  cdf[n - 1] = 1 // guard against float drift in the last bucket

  return { numT: n, rowX, rowY, rowZ, b, cdf, color, varW }
}
