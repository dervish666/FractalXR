import {
  Camera,
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
import { makeFullscreenTriangle } from './util'
import { RAW_VERT, TONEMAP_FRAG } from './shaders'

export interface ToneParams {
  exposure: number
  gamma: number
  k2: number
  hiDesat: number // highlight desaturation / vibrancy, 0..1
}

/**
 * Owns the HDR accumulation target (RGBA16F) and the per-eye log-density tone-map
 * pass. The tone-map samples each eye's region by gl_FragCoord/fbSize (full output res).
 * The splat target can be rendered at a fraction of that (`splatScale`) — the additive
 * glow is low-frequency, so a half-res splat (¼ the fill/bandwidth, the real overdraw cost)
 * upscales near-invisibly through the Linear filter. Caller scales the XR eye viewports to
 * match (see main.ts); at splatScale 1 this is byte-identical to a full-res 1:1 target.
 */
export class Compositor {
  readonly hdrRT: WebGLRenderTarget
  private scene = new Scene()
  private cam = new Camera()
  private material: RawShaderMaterial
  private size = new Vector2(2, 2) // tone-map output (full) resolution
  private splatSize = new Vector2(2, 2) // HDR splat target resolution (= size × splatScale)

  constructor(params: ToneParams) {
    this.hdrRT = new WebGLRenderTarget(2, 2, {
      type: HalfFloatType,
      format: RGBAFormat,
      minFilter: LinearFilter, // bilinear upscale when the splat target is sub-res (identical at 1:1)
      magFilter: LinearFilter,
      depthBuffer: false,
      stencilBuffer: false,
    })

    this.material = new RawShaderMaterial({
      glslVersion: GLSL3,
      vertexShader: RAW_VERT,
      fragmentShader: TONEMAP_FRAG,
      depthTest: false,
      depthWrite: false,
      transparent: true, // honour the alpha we emit in passthrough mode
      blending: NoBlending, // we write the final premultiplied pixel; three must not re-blend it
      uniforms: {
        uHdr: { value: this.hdrRT.texture },
        uFbSize: { value: new Vector2(2, 2) },
        uExposure: { value: params.exposure },
        uGamma: { value: params.gamma },
        uK2: { value: params.k2 },
        uHiDesat: { value: params.hiDesat },
        uPassthrough: { value: 0 }, // 0 = opaque void (default, matches legacy VR path)
      },
    })

    const mesh = new Mesh(makeFullscreenTriangle(), this.material)
    mesh.frustumCulled = false
    this.scene.add(mesh)
  }

  /** Size the tone-map to the full (XR or canvas) framebuffer, and the splat target to
   *  `splatScale` of it (1 = 1:1). uFbSize stays full so the tone-map outputs at full res. */
  ensureSize(w: number, h: number, splatScale = 1): void {
    const sw = Math.max(1, Math.round(w * splatScale))
    const sh = Math.max(1, Math.round(h * splatScale))
    if (w === this.size.x && h === this.size.y && sw === this.splatSize.x && sh === this.splatSize.y) return
    this.size.set(w, h)
    this.splatSize.set(sw, sh)
    this.hdrRT.setSize(sw, sh)
    this.material.uniforms.uHdr.value = this.hdrRT.texture
    ;(this.material.uniforms.uFbSize.value as Vector2).set(w, h)
  }

  setToneParams(p: ToneParams): void {
    this.material.uniforms.uExposure.value = p.exposure
    this.material.uniforms.uGamma.value = p.gamma
    this.material.uniforms.uK2.value = p.k2
    this.material.uniforms.uHiDesat.value = p.hiDesat
  }

  /** 0 = opaque void (VR / AR-void), 1 = premultiplied glow over passthrough (AR-room). */
  setPassthrough(v: number): void {
    this.material.uniforms.uPassthrough.value = v
  }

  /** Composite the HDR buffer into `target` (the XR framebuffer, or null = canvas). */
  tonemap(renderer: WebGLRenderer, target: WebGLRenderTarget | null): void {
    renderer.setRenderTarget(target)
    renderer.render(this.scene, this.cam)
  }
}
