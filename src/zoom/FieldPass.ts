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
    u.uJulia.value = v.julia ? 1 : 0
    u.uJuliaC.value.set(v.juliaCx, v.juliaCy)
    u.uRidge.value = v.ridge
    u.uInvert.value = v.invert ? 1 : 0
    u.uTerraceGamma.value = v.terraceGamma
    u.uRidgeWidth.value = v.ridgeWidth
    u.uColorCycles.value = v.colorCycles
    u.uColorShift.value = v.colorShift
    this.dirty = true
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
    if (!this.dirty) return false
    const previewing = this.samples === 1
    const target = previewing ? this.preview : this.full
    const res = previewing ? this._previewRes : this._res
    this.mat.uniforms.uRes.value = res

    const prevRT = renderer.getRenderTarget()
    const xrWas = renderer.xr.enabled
    renderer.xr.enabled = false // otherwise render() swaps in the XR camera and viewports
    renderer.setRenderTarget(target)
    renderer.render(this.scene, this.cam)
    renderer.setRenderTarget(prevRT)
    renderer.xr.enabled = xrWas

    this.active = target
    this.dirty = false
    return true
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
