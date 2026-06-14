import { BufferAttribute, BufferGeometry } from 'three'

/** A single clip-space triangle covering the viewport (for raw fullscreen passes). */
export function makeFullscreenTriangle(): BufferGeometry {
  const geo = new BufferGeometry()
  // (-1,-1), (3,-1), (-1,3) — covers [-1,1]² after rasterisation
  const pos = new Float32Array([-1, -1, 0, 3, -1, 0, -1, 3, 0])
  geo.setAttribute('position', new BufferAttribute(pos, 3))
  return geo
}
