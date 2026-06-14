import {
  Camera,
  GLSL3,
  HalfFloatType,
  Mesh,
  NearestFilter,
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
 * pass. The HDR target is sized to the XR framebuffer so the stereo eye viewports
 * line up 1:1 and the tone-map samples each eye's region by gl_FragCoord/fbSize.
 */
export class Compositor {
  readonly hdrRT: WebGLRenderTarget
  private scene = new Scene()
  private cam = new Camera()
  private material: RawShaderMaterial
  private size = new Vector2(2, 2)

  constructor(params: ToneParams) {
    this.hdrRT = new WebGLRenderTarget(2, 2, {
      type: HalfFloatType,
      format: RGBAFormat,
      minFilter: NearestFilter,
      magFilter: NearestFilter,
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

  /** Resize the HDR target to match the current (XR or canvas) framebuffer. */
  ensureSize(w: number, h: number): void {
    if (w === this.size.x && h === this.size.y) return
    this.size.set(w, h)
    this.hdrRT.setSize(w, h)
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
