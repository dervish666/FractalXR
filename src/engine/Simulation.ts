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
import { SEED_FRAG, UPDATE_FRAG, BULB_UPDATE_FRAG, RAW_VERT } from './shaders'

export interface BulbParams {
  formula: 'mandelbulb' | 'mandelbox'
  power: number
  juliaC: Vector3
  mandelbulb: boolean // true = c = p, false = Julia (c = juliaC)
  scale: number // Mandelbox scale
  minR: number // Mandelbox sphere-fold min radius
  fixedR: number // Mandelbox sphere-fold fixed radius
  bound: number // seed / reseed ball radius
  projSteps: number
  jitter: number
  reseedProb: number
}

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
  private bulbMat: RawShaderMaterial
  private mesh: Mesh
  private seeded = false
  private _mode: 'flame' | 'bulb' = 'flame'
  private activeTexels: number // only simulate the texels actually drawn (huge win for the heavy bulb DE)

  constructor(size = 256) {
    this.size = size
    this.count = size * size
    this.activeTexels = this.count

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

    this.bulbMat = new RawShaderMaterial({
      glslVersion: GLSL3,
      vertexShader: RAW_VERT,
      fragmentShader: BULB_UPDATE_FRAG,
      depthTest: false,
      depthWrite: false,
      uniforms: {
        uState: { value: null as Texture | null },
        uTexSize: { value: size },
        uFrame: { value: 0 },
        uReseedProb: { value: 0.02 },
        uPower: { value: 8 },
        uJuliaC: { value: new Vector3(0.35, 0.0, 0.0) },
        uMandelbulb: { value: 1 },
        uFormula: { value: 0 },
        uScale: { value: 2.0 },
        uMinR: { value: 0.5 },
        uFixedR: { value: 1.0 },
        uBound: { value: 1.3 },
        uProjSteps: { value: 3 },
        uJitter: { value: 0.0022 },
      },
    })

    this.mesh = new Mesh(makeFullscreenTriangle(), this.seedMat)
    this.mesh.frustumCulled = false
    this.scene.add(this.mesh)
  }

  get mode(): 'flame' | 'bulb' {
    return this._mode
  }

  setMode(m: 'flame' | 'bulb'): void {
    this._mode = m
  }

  setBulbParams(p: Partial<BulbParams>): void {
    const u = this.bulbMat.uniforms
    if (p.formula !== undefined) u.uFormula.value = p.formula === 'mandelbox' ? 1 : 0
    if (p.power !== undefined) u.uPower.value = p.power
    if (p.juliaC !== undefined) (u.uJuliaC.value as Vector3).copy(p.juliaC)
    if (p.mandelbulb !== undefined) u.uMandelbulb.value = p.mandelbulb ? 1 : 0
    if (p.scale !== undefined) u.uScale.value = p.scale
    if (p.minR !== undefined) u.uMinR.value = p.minR
    if (p.fixedR !== undefined) u.uFixedR.value = p.fixedR
    if (p.bound !== undefined) u.uBound.value = p.bound
    if (p.projSteps !== undefined) u.uProjSteps.value = p.projSteps
    if (p.jitter !== undefined) u.uJitter.value = p.jitter
    if (p.reseedProb !== undefined) u.uReseedProb.value = p.reseedProb
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

  /** Only simulate the `n` texels that are actually drawn — the rest are wasted work,
   *  which the heavy Mandelbulb DE can't afford. Scissors the update pass to ⌈n/size⌉ rows. */
  setActiveTexels(n: number): void {
    this.activeTexels = Math.max(this.size, Math.min(this.count, Math.floor(n)))
  }

  private renderPass(renderer: WebGLRenderer, mat: RawShaderMaterial, target: WebGLRenderTarget, rows: number): void {
    this.mesh.material = mat
    const prevTarget = renderer.getRenderTarget()
    const xrWas = renderer.xr.enabled
    renderer.xr.enabled = false // ← stop render() swapping in the XR camera
    renderer.setRenderTarget(target)
    if (rows < this.size) {
      const scissorWas = renderer.getScissorTest()
      renderer.setScissorTest(true)
      renderer.setScissor(0, 0, this.size, rows) // run the shader on the drawn texels only
      renderer.render(this.scene, this.cam)
      renderer.setScissorTest(scissorWas) // restore prior state rather than forcing it off every flame frame
    } else {
      renderer.render(this.scene, this.cam)
    }
    renderer.xr.enabled = xrWas
    renderer.setRenderTarget(prevTarget)
  }

  /** Scatter all particles to fresh start points (full texture, so raising the count later has valid seeds). */
  seed(renderer: WebGLRenderer): void {
    this.renderPass(renderer, this.seedMat, this.rtA, this.size)
    this.renderPass(renderer, this.seedMat, this.rtB, this.size)
    this.seeded = true
  }

  /** Advance one frame of the chaos game, writing into the live state texture. */
  update(renderer: WebGLRenderer, frame: number): void {
    if (!this.seeded) this.seed(renderer)
    const mat = this._mode === 'bulb' ? this.bulbMat : this.updateMat
    mat.uniforms.uState.value = this.rtA.texture
    mat.uniforms.uFrame.value = frame % 16777216 // keep exact as float
    // scissor the sim to the drawn texels in bulb mode (the heavy DE can't afford the full
    // grid). Flames keep the full grid — their math is cheap and they freeze when settled.
    const rows = this._mode === 'bulb' ? Math.min(this.size, Math.ceil(this.activeTexels / this.size)) : this.size
    this.renderPass(renderer, mat, this.rtB, rows)
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
    this.bulbMat.dispose()
    this.mesh.geometry.dispose()
  }
}
