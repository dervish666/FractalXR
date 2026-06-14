import {
  ClampToEdgeWrapping,
  DataTexture,
  LinearFilter,
  RGBAFormat,
  UnsignedByteType,
} from 'three'
import type { Vec3 } from './types'

function fillLut(data: Uint8Array, colors: Vec3[]): void {
  const N = 256
  const segs = Math.max(1, colors.length - 1)
  for (let i = 0; i < N; i++) {
    const t = i / (N - 1)
    const f = t * segs
    const i0 = Math.min(segs, Math.floor(f))
    const i1 = Math.min(segs, i0 + 1)
    const lf = f - i0
    const a = colors[i0]
    const b = colors[i1]
    data[i * 4 + 0] = Math.round(255 * clamp01(a[0] + (b[0] - a[0]) * lf))
    data[i * 4 + 1] = Math.round(255 * clamp01(a[1] + (b[1] - a[1]) * lf))
    data[i * 4 + 2] = Math.round(255 * clamp01(a[2] + (b[2] - a[2]) * lf))
    data[i * 4 + 3] = 255
  }
}

function clamp01(x: number): number {
  return x < 0 ? 0 : x > 1 ? 1 : x
}

/**
 * A 256×1 RGBA palette LUT with an in-place updater — `setColors` refills the
 * existing texture buffer instead of allocating a new GPU texture, so morphing
 * can rebuild the palette every frame without churning GPU resources.
 */
export class Palette {
  readonly texture: DataTexture
  private data = new Uint8Array(256 * 4)

  constructor(colors: Vec3[]) {
    this.texture = new DataTexture(this.data, 256, 1, RGBAFormat, UnsignedByteType)
    this.texture.minFilter = LinearFilter
    this.texture.magFilter = LinearFilter
    this.texture.wrapS = ClampToEdgeWrapping
    this.texture.wrapT = ClampToEdgeWrapping
    this.setColors(colors)
  }

  setColors(colors: Vec3[]): void {
    fillLut(this.data, colors)
    this.texture.needsUpdate = true
  }
}
