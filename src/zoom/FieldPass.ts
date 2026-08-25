import {
  Camera,
  ClampToEdgeWrapping,
  GLSL3,
  HalfFloatType,
  LinearFilter,
  Mesh,
  NoBlending,
  RawShaderMaterial,
  RGBAFormat,
  Scene,
  Vector2,
  WebGLRenderer,
  WebGLRenderTarget,
} from 'three'
import { makeFullscreenTriangle } from '../engine/util'
import { RAW_VERT } from '../engine/shaders'
import { FIELD_FRAG } from './shaders'

/** Everything that decides what the field tile contains. */
export interface ZoomView {
  cx: number // complex-plane centre (kept in JS doubles)
  cy: number
  scale: number // half-width of the window, in complex units
  maxIter: number
  julia: boolean
  juliaCx: number
  juliaCy: number
  ridge: number // 0 = iteration terraces, 1 = distance-estimate ridges
  invert: boolean // set as the lowest point rather than the highest
  terraceGamma: number
  ridgeWidth: number
  colorCycles: number
  colorShift: number
}

export const DEFAULT_VIEW: ZoomView = {
  cx: -0.6,
  cy: 0,
  scale: 1.5,
  maxIter: 128,
  julia: false,
  juliaCx: -0.79,
  juliaCy: 0.15,
  ridge: 0.45,
  invert: true,
  terraceGamma: 0.32,
  ridgeWidth: 9,
  colorCycles: 5,
  colorShift: 0.1,
}

/**
 * The escape-time tile. One evaluation per texel, re-rendered only when the view actually
 * changes — a still relief costs a texture fetch per march step and nothing else, which is
 * what makes per-eye stereo affordable.
 *
 * Storage is RGBA16F (linear filtering is core in WebGL2, unlike float32):
 *   R = height 0..1 · G = palette index, negative = inside · B = inside flag · A = iter fraction
 */
export class FieldPass {
  private full: WebGLRenderTarget
  private preview: WebGLRenderTarget
  private active: WebGLRenderTarget
  private bandRow = 0 // next scanline of the refined pass still to be drawn
  private banding = false
  private maxIter = 128
  /** Explicit, NOT inferred from the sample count: at high resolution the settled tile uses
   *  1 sample too, so `samples === 1` cannot mean "this is only the preview". */
  private wantFull = true
  private _res: number
  private _previewRes: number
  private scene = new Scene()
  private cam = new Camera()
  private mat: RawShaderMaterial
  private dirty = true

  constructor(res = 1024, previewRes = 768) {
    this._res = res
    this._previewRes = Math.min(previewRes, res)
    this.full = FieldPass.makeTarget(res)
    this.preview = FieldPass.makeTarget(this._previewRes)
    this.active = this.full

    this.mat = new RawShaderMaterial({
      glslVersion: GLSL3,
      vertexShader: RAW_VERT,
      fragmentShader: FIELD_FRAG,
      depthTest: false,
      depthWrite: false,
      blending: NoBlending,
      uniforms: {
        uCenterHi: { value: new Vector2() },
        uCenterLo: { value: new Vector2() },
        uScale: { value: 1.5 },
        uRes: { value: res },
        uMaxIter: { value: 128 },
        uJuliaC: { value: new Vector2() },
        uJulia: { value: 0 },
        uRidge: { value: 0.45 },
        uTerraceGamma: { value: 0.32 },
        uRidgeWidth: { value: 9 },
        uColorCycles: { value: 1.6 },
        uColorShift: { value: 0.1 },
        uSamples: { value: 1 },
        uTexOn: { value: 1 },
        uStalk: { value: 0 },
        uStalkWidth: { value: 0.12 },
        uInvert: { value: 0 },
      },
    })
    this.scene.add(new Mesh(makeFullscreenTriangle(), this.mat))
  }

  /** The full (settled) tile resolution. */
  get res(): number {
    return this._res
  }

  /** The target the last `render` actually wrote, and the one to sample from. */
  get rt(): WebGLRenderTarget {
    return this.active
  }

  /** The full-resolution target — the only one the height reduction ever runs on. */
  get fullRt(): WebGLRenderTarget {
    return this.full
  }

  /** Resolution of the tile currently bound, which is the preview one while you are moving. */
  get activeRes(): number {
    return this.active === this.full ? this._res : this._previewRes
  }

  private static makeTarget(res: number): WebGLRenderTarget {
    return new WebGLRenderTarget(res, res, {
      type: HalfFloatType, // linear filtering of half-float is core in WebGL2, unlike float32
      format: RGBAFormat,
      minFilter: LinearFilter,
      magFilter: LinearFilter,
      wrapS: ClampToEdgeWrapping,
      wrapT: ClampToEdgeWrapping,
      depthBuffer: false,
      stencilBuffer: false,
    })
  }

  /**
   * Re-allocate the tile at a new resolution. The old target is disposed, so the caller MUST
   * re-point anything holding `rt.texture` (the relief material's uField) at the new one.
   * Returns the texture to rebind.
   */
  setResolution(res: number): void {
    if (res === this._res) return
    this.full.dispose()
    this._res = res
    this.full = FieldPass.makeTarget(res)
    if (this._previewRes > res) {
      this.preview.dispose()
      this._previewRes = res
      this.preview = FieldPass.makeTarget(res)
    }
    this.active = this.full
    this.dirty = true
    this.banding = false
  }

  /** Push a view; the tile re-renders on the next `render` call. */
  setView(v: ZoomView): void {
    const u = this.mat.uniforms
    // split the centre into a float32 head and the tail it dropped
    const hix = Math.fround(v.cx)
    const hiy = Math.fround(v.cy)
    u.uCenterHi.value.set(hix, hiy)
    u.uCenterLo.value.set(v.cx - hix, v.cy - hiy)
    u.uScale.value = v.scale
    u.uMaxIter.value = Math.round(v.maxIter)
    this.maxIter = Math.round(v.maxIter)
    u.uJulia.value = v.julia ? 1 : 0
    u.uJuliaC.value.set(v.juliaCx, v.juliaCy)
    u.uRidge.value = v.ridge
    u.uInvert.value = v.invert ? 1 : 0
    u.uTerraceGamma.value = v.terraceGamma
    u.uRidgeWidth.value = v.ridgeWidth
    u.uColorCycles.value = v.colorCycles
    u.uColorShift.value = v.colorShift
    this.dirty = true
    this.banding = false // a new view abandons whatever refined tile was half-drawn
  }

  /**
   * Sub-texel sampling grid, 1..3 (1, 4 or 9 evaluations per texel). Held at 1 while the
   * view is moving and raised once it settles — a preview-then-refine loop, which is the
   * only affordable way to pay for antialiasing at deep zooms.
   */
  setSamples(n: number): void {
    const v = Math.max(1, Math.min(3, Math.round(n)))
    if (v === this.mat.uniforms.uSamples.value) return
    this.mat.uniforms.uSamples.value = v
    this.dirty = true
    this.banding = false
  }

  /** Preview (small tile, drawn in one go) versus settled (full tile, drawn band by band). */
  setFullQuality(on: boolean): void {
    if (on === this.wantFull) return
    this.wantFull = on
    this.dirty = true
    this.banding = false
  }

  /** Exterior texture character: 0 = marbled TIA, 1 = Pickover filaments. Interior is unaffected. */
  setStalk(v: number): void {
    const x = Math.max(0, Math.min(1, v))
    if (x === this.mat.uniforms.uStalk.value) return
    this.mat.uniforms.uStalk.value = x
    this.dirty = true
    this.banding = false
  }

  get stalk(): number {
    return this.mat.uniforms.uStalk.value as number
  }

  /** Skip the orbit-texture accumulation when nothing is going to read it. */
  setTextureOn(on: boolean): void {
    const v = on ? 1 : 0
    if (v === this.mat.uniforms.uTexOn.value) return
    this.mat.uniforms.uTexOn.value = v
    this.dirty = true
    this.banding = false
  }

  get fullQuality(): boolean {
    return this.wantFull
  }

  get samples(): number {
    return this.mat.uniforms.uSamples.value as number
  }

  /**
   * Re-render the tile if the view moved. Returns true if it actually did any work.
   *
   * While you are moving this writes a SMALLER preview tile, and only the settled pass pays
   * for the full resolution. That split is what lets the full tile be 3072² at all: a moving
   * frame pays for the field AND the march, and at full res the field alone is several times
   * a headset's whole frame budget.
   */
  render(renderer: WebGLRenderer): boolean {
    if (this.banding) return this.renderBand(renderer)
    if (!this.dirty) return false

    if (!this.wantFull) {
      this.mat.uniforms.uRes.value = this._previewRes
      this.drawInto(renderer, this.preview, this._previewRes)
      this.active = this.preview
      this.dirty = false
      return true
    }

    // Refined pass: start banding rather than submitting it all at once.
    this.mat.uniforms.uRes.value = this._res
    this.bandRow = 0
    this.banding = true
    this.dirty = false
    return this.renderBand(renderer)
  }

  /**
   * Rows of the refined tile to draw per frame.
   *
   * The refined pass at 3072² and 9 samples is hundreds of milliseconds of GPU work in ONE
   * submission. On a headset that is not a slow frame, it is a hang: the compositor freezes,
   * and long enough submissions get the context killed outright. Splitting it into scissored
   * bands trades a freeze for a few busy frames.
   */
  private bandRows(): number {
    // Size a band by the WORK it does, not by the tile height: rows x width x samples² x
    // iterations. A fixed row count is meaningless when iterations swing by 100x with zoom.
    const perRow = this._res * this.samples * this.samples * Math.max(1, this.maxIter)
    return Math.max(1, Math.min(this._res, Math.floor(this.bandBudget / perRow)))
  }

  /** Work units per band. Tuned so a band is a few ms on a desktop GPU. */
  bandBudget = 1.5e8

  /** Draw the next band of the refined tile. Returns true while there is still work pending. */
  private renderBand(renderer: WebGLRenderer): boolean {
    const rows = Math.min(this.bandRows(), this._res - this.bandRow)
    this.drawInto(renderer, this.full, this._res, this.bandRow, rows)
    this.bandRow += rows
    if (this.bandRow >= this._res) {
      this.banding = false
      this.active = this.full // only swap once the whole tile is actually there
    }
    return true
  }

  /** True while a refined tile is still being assembled band by band. */
  get refining(): boolean {
    return this.banding
  }

  /** How far through the refined tile we are, 0..1. */
  get refineProgress(): number {
    return this.banding ? this.bandRow / this._res : 1
  }

  /**
   * Draw the fullscreen triangle into `target`, optionally restricted to a band of rows.
   *
   * The band is bounded by the VIEWPORT, not by the scissor. Scissor is specified as a
   * per-fragment operation after fragment shading, and on this hardware it behaves that way:
   * a scissored band of a 3072² tile still ran the whole tile's shader work, 6.3 seconds of
   * it. A viewport actually limits rasterisation. `gl_FragCoord` stays in absolute framebuffer
   * space either way, so the shader's `gl_FragCoord.xy / uRes` needs no adjustment.
   */
  private drawInto(
    renderer: WebGLRenderer,
    target: WebGLRenderTarget,
    res: number,
    y = 0,
    rows = res,
  ): void {
    this.mat.uniforms.uRes.value = res
    const prevRT = renderer.getRenderTarget()
    const xrWas = renderer.xr.enabled
    const autoWas = renderer.autoClear
    renderer.xr.enabled = false // otherwise render() swaps in the XR camera and viewports
    renderer.autoClear = false // the triangle writes every pixel it covers
    renderer.setRenderTarget(target) // resets the viewport, so set ours AFTER it
    renderer.setViewport(0, y, res, rows)
    renderer.setScissorTest(true)
    renderer.setScissor(0, y, res, rows)
    renderer.render(this.scene, this.cam)
    renderer.setScissorTest(false)
    renderer.setViewport(0, 0, res, res)
    renderer.setRenderTarget(prevRT)
    renderer.autoClear = autoWas
    renderer.xr.enabled = xrWas
  }

  dispose(): void {
    this.full.dispose()
    this.preview.dispose()
    this.mat.dispose()
  }
}

/**
 * Where float32 gives up. `c` is built as centre + offset in the shader, so the smallest
 * distinguishable step near |c| ~ 1 is one float32 ulp (~1.2e-7). Once a texel spans less
 * than a few ulps the tile quantises into blocks. Returns texel spacing measured in ulps —
 * below ~4 it visibly degrades, below 1 it is mush.
 */
export function precisionUlps(view: ZoomView, res: number): number {
  const mag = Math.max(1, Math.hypot(view.cx, view.cy))
  const ulp = mag * 1.1920929e-7
  return (2 * view.scale) / res / ulp
}

/**
 * Iteration budget grows with depth, so shallow views waste nothing and deep ones stay
 * detailed. `mult` is the runtime ITER lever: the field only re-renders when the view moves,
 * so a big multiplier costs pan/zoom responsiveness rather than steady-state frame rate,
 * which is why the ceiling is set high enough to actually hurt if you ask for it.
 */
export function autoMaxIter(scale: number, base = 1.5, mult = 1): number {
  const zoom = Math.max(1, base / scale)
  return Math.min(24000, Math.round((192 + 120 * Math.log2(zoom)) * mult))
}
