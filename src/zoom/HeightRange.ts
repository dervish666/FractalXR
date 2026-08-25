import {
  Camera,
  FloatType,
  GLSL3,
  Mesh,
  NearestFilter,
  NoBlending,
  RawShaderMaterial,
  RGBAFormat,
  Scene,
  WebGLRenderer,
  WebGLRenderTarget,
} from 'three'
import { makeFullscreenTriangle } from '../engine/util'
import { RAW_VERT } from '../engine/shaders'
import { REDUCE_FRAG } from './shaders'

/**
 * Auto-exposure, but for height.
 *
 * The escape field's absolute height range is near-useless as a relief: deep in a valley
 * almost every texel sits close to the set, so the whole tile squashes into a few percent of
 * the slab and the relief goes flat (and, inverted, so close to the floor that a fixed-step
 * ray march walks straight past it). Measuring the range actually present in the tile and
 * stretching it across the full depth is what keeps the relief dramatic at any zoom.
 *
 * A pyramid of 4x4 reductions gets 1024² down to 16² on the GPU, so the readback that
 * finishes the job is a couple of KB rather than eight megabytes.
 */
export class HeightRange {
  private levels: WebGLRenderTarget[] = []
  private scene = new Scene()
  private cam = new Camera()
  private mat!: RawShaderMaterial
  private buf!: Float32Array

  constructor(res: number) {
    this.build(res)

    this.mat = new RawShaderMaterial({
      glslVersion: GLSL3,
      vertexShader: RAW_VERT,
      fragmentShader: REDUCE_FRAG,
      depthTest: false,
      depthWrite: false,
      blending: NoBlending,
      uniforms: { uSrc: { value: null }, uFirst: { value: 1 }, uChannel: { value: 0 } },
    })
    this.scene.add(new Mesh(makeFullscreenTriangle(), this.mat))
  }

  /** Rebuild the reduction pyramid for a new field resolution. */
  setResolution(res: number): void {
    for (const l of this.levels) l.dispose()
    this.levels = []
    this.build(res)
  }

  private sourceRes = 1024

  private build(res: number): void {
    this.sourceRes = res
    let size = res
    while (size > 32) {
      size = Math.max(1, Math.floor(size / 4))
      this.levels.push(
        new WebGLRenderTarget(size, size, {
          type: FloatType, // read back as Float32Array — no half-float decode on the CPU
          format: RGBAFormat,
          minFilter: NearestFilter,
          magFilter: NearestFilter,
          depthBuffer: false,
          stencilBuffer: false,
        }),
      )
    }
    const last = this.levels[this.levels.length - 1]
    this.buf = new Float32Array(last.width * last.height * 4)
  }

  /** Min/max height in the tile, ignoring the extreme tails so one stray texel can't set the scale. */
  compute(renderer: WebGLRenderer, field: WebGLRenderTarget, channel = 0): { lo: number; hi: number } {
    const prevRT = renderer.getRenderTarget()
    const xrWas = renderer.xr.enabled
    renderer.xr.enabled = false

    let src: WebGLRenderTarget = field
    for (let i = 0; i < this.levels.length; i++) {
      this.mat.uniforms.uSrc.value = src.texture
      this.mat.uniforms.uFirst.value = i === 0 ? 1 : 0
      this.mat.uniforms.uChannel.value = channel
      renderer.setRenderTarget(this.levels[i])
      renderer.render(this.scene, this.cam)
      src = this.levels[i]
    }

    const last = this.levels[this.levels.length - 1]
    renderer.readRenderTargetPixels(last, 0, 0, last.width, last.height, this.buf)
    renderer.setRenderTarget(prevRT)
    renderer.xr.enabled = xrWas

    // Absolute min/max is the wrong statistic: a handful of texels deep in the filigree reach
    // heights nothing else comes near, and how extreme they get depends on how many texels
    // there are — so the scale moved every time the resolution changed. Mean and standard
    // deviation are averages, so they hold still across the ladder. Clamp to the real extremes
    // so the window can never claim range the tile does not have.
    let lo = Infinity
    let hi = -Infinity
    let sum = 0
    let sq = 0
    const n = last.width * last.height
    for (let i = 0; i < n; i++) {
      const a = this.buf[i * 4]
      const b = this.buf[i * 4 + 1]
      if (a < lo) lo = a
      if (b > hi) hi = b
      sum += this.buf[i * 4 + 2]
      sq += this.buf[i * 4 + 3]
    }
    if (!isFinite(lo) || !isFinite(hi) || hi - lo < 1e-4) return { lo: 0, hi: 1 }

    const texels = this.sourceRes * this.sourceRes
    const mean = sum / texels
    const variance = Math.max(0, sq / texels - mean * mean)
    const sigma = Math.sqrt(variance)
    if (!(sigma > 1e-4)) return { lo, hi } // a nearly uniform tile: nothing to normalise against

    const k = 2.4
    const outLo = Math.max(lo, mean - k * sigma)
    const outHi = Math.min(hi, mean + k * sigma)
    if (outHi - outLo < 1e-4) return { lo, hi }
    return { lo: outLo, hi: outHi }
  }

  dispose(): void {
    for (const l of this.levels) l.dispose()
    this.mat.dispose()
  }
}
