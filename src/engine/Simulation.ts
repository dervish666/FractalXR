import {
  Camera,
  GLSL3,
  Mesh,
  NearestFilter,
  RawShaderMaterial,
  RGBAFormat,
  Scene,
  FloatType,
  Texture,
  Vector3,
  WebGLRenderer,
  WebGLRenderTarget,
} from 'three'
import type { EncodedFlame } from '../flame/encode'
import { makeFullscreenTriangle } from './util'
import { SEED_FRAG, UPDATE_FRAG, RAW_VERT } from './shaders'

export interface SimParams {
  iterations: number // chaos-game steps per particle per frame
  reseedProb: number // per-iteration respawn probability
}

/**
 * GPU chaos-game simulator. Holds particle state (pos.xyz + colorIndex) in an
 * RGBA32F texture, ping-ponged between two render targets. View-independent —
 * runs with `renderer.xr.enabled` temporarily off so `renderer.render` does not
 * hijack the compute pass with the XR stereo camera.
 */
export class Simulation {
  readonly size: number
  readonly count: number
  private rtA: WebGLRenderTarget
  private rtB: WebGLRenderTarget
  private scene = new Scene()
  private cam = new Camera()
  private seedMat: RawShaderMaterial
  private updateMat: RawShaderMaterial
  private mesh: Mesh
  private seeded = false

  constructor(size = 256) {
    this.size = size
    this.count = size * size

    const opts = {
      type: FloatType,
      format: RGBAFormat,
      minFilter: NearestFilter,
      magFilter: NearestFilter,
      depthBuffer: false,
      stencilBuffer: false,
    }
    this.rtA = new WebGLRenderTarget(size, size, opts)
    this.rtB = new WebGLRenderTarget(size, size, opts)

    this.seedMat = new RawShaderMaterial({
      glslVersion: GLSL3,
      vertexShader: RAW_VERT,
      fragmentShader: SEED_FRAG,
      uniforms: { uTexSize: { value: size } },
      depthTest: false,
      depthWrite: false,
    })

    this.updateMat = new RawShaderMaterial({
      glslVersion: GLSL3,
      vertexShader: RAW_VERT,
      fragmentShader: UPDATE_FRAG,
      depthTest: false,
      depthWrite: false,
      uniforms: {
        uState: { value: null as Texture | null },
        uTexSize: { value: size },
        uFrame: { value: 0 },
        uNumT: { value: 1 },
        uIters: { value: 4 },
        uReseedProb: { value: 0.008 },
        uArow0: { value: [] as Vector3[] },
        uArow1: { value: [] as Vector3[] },
        uArow2: { value: [] as Vector3[] },
        uB: { value: [] as Vector3[] },
        uCdf: { value: new Float32Array(8) },
        uColor: { value: new Float32Array(8) },
        uVar: { value: new Float32Array(40) },
      },
    })

    this.mesh = new Mesh(makeFullscreenTriangle(), this.seedMat)
    this.mesh.frustumCulled = false
    this.scene.add(this.mesh)
  }

  /** The most recently written particle-state texture (for the renderer). */
  get stateTexture(): Texture {
    return this.rtA.texture
  }

  setGenome(e: EncodedFlame): void {
    const u = this.updateMat.uniforms
    u.uNumT.value = e.numT
    u.uArow0.value = e.rowX
    u.uArow1.value = e.rowY
    u.uArow2.value = e.rowZ
    u.uB.value = e.b
    u.uCdf.value = e.cdf
    u.uColor.value = e.color
    u.uVar.value = e.varW
  }

  setParams(p: SimParams): void {
    this.updateMat.uniforms.uIters.value = p.iterations
    this.updateMat.uniforms.uReseedProb.value = p.reseedProb
  }

  private renderPass(renderer: WebGLRenderer, mat: RawShaderMaterial, target: WebGLRenderTarget): void {
    this.mesh.material = mat
    const prevTarget = renderer.getRenderTarget()
    const xrWas = renderer.xr.enabled
    renderer.xr.enabled = false // ← stop render() swapping in the XR camera
    renderer.setRenderTarget(target)
    renderer.render(this.scene, this.cam)
    renderer.xr.enabled = xrWas
    renderer.setRenderTarget(prevTarget)
  }

  /** Scatter all particles to fresh start points. */
  seed(renderer: WebGLRenderer): void {
    this.renderPass(renderer, this.seedMat, this.rtA)
    this.renderPass(renderer, this.seedMat, this.rtB)
    this.seeded = true
  }

  /** Advance one frame of the chaos game, writing into the live state texture. */
  update(renderer: WebGLRenderer, frame: number): void {
    if (!this.seeded) this.seed(renderer)
    this.updateMat.uniforms.uState.value = this.rtA.texture
    this.updateMat.uniforms.uFrame.value = frame % 16777216 // keep exact as float
    this.renderPass(renderer, this.updateMat, this.rtB)
    // swap
    const t = this.rtA
    this.rtA = this.rtB
    this.rtB = t
  }

  dispose(): void {
    this.rtA.dispose()
    this.rtB.dispose()
    this.seedMat.dispose()
    this.updateMat.dispose()
    this.mesh.geometry.dispose()
  }
}
