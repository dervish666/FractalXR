import {
  BackSide,
  BoxGeometry,
  GLSL3,
  Mesh,
  ShaderMaterial,
  Texture,
  Vector3,
} from 'three'
import { RELIEF_FRAG, RELIEF_VERT } from './shaders'

export interface ReliefOptions {
  width?: number // metres
  height?: number
  depth?: number // marched relief extrusion, base to peak. Deeper needs proportionally more steps
  geometryDepth?: number // box depth. Larger than `depth` leaves room to grow the slab at runtime
  steps?: number // march steps, or the march starts stepping over near-floor surfaces
}

/**
 * The escape field as a bas-relief slab you can lean into. Ray-marching happens in the
 * fragment shader from `cameraPosition`, which three sets per sub-camera, so each eye gets
 * its own ray and the parallax is real rather than a flat image pasted on a quad.
 *
 * Rendered with BackSide so the box still draws when your head is inside it; the ray entry
 * point comes from an analytic slab test, not from the rasterised face.
 */
export class ReliefPanel {
  readonly mesh: Mesh
  readonly material: ShaderMaterial
  readonly half: Vector3

  constructor(field: Texture, palette: Texture, res: number, opts: ReliefOptions = {}) {
    const w = opts.width ?? 1.0
    const h = opts.height ?? 1.0
    const d = opts.depth ?? 0.5
    // The box only has to CONTAIN the marched slab: entry comes from an analytic test against
    // uHalf, and anything outside it discards. So oversize the box once and vary uHalf.z freely.
    const geoD = Math.max(d, opts.geometryDepth ?? d)
    this.half = new Vector3(w / 2, h / 2, d / 2)

    this.material = new ShaderMaterial({
      glslVersion: GLSL3,
      vertexShader: RELIEF_VERT,
      fragmentShader: RELIEF_FRAG,
      side: BackSide,
      uniforms: {
        uField: { value: field },
        uPalette: { value: palette },
        uHalf: { value: this.half },
        uRes: { value: res },
        uSteps: { value: opts.steps ?? 160 },
        uLightDir: { value: new Vector3(-0.45, 0.6, 0.66).normalize() },
        uNormalWidth: { value: 1.6 },
        uShadow: { value: 0.55 },
        uSpecular: { value: 0.5 },
        uAmbient: { value: 0.18 },
        uExposure: { value: 1.35 },
        uInsideColor: { value: new Vector3(0.03, 0.02, 0.06) },
        uHeightLo: { value: 0 },
        uHeightHi: { value: 1 },
      },
    })

    this.mesh = new Mesh(new BoxGeometry(w, h, geoD), this.material)
  }

  set steps(n: number) {
    this.material.uniforms.uSteps.value = Math.max(16, Math.round(n))
  }
  get steps(): number {
    return this.material.uniforms.uSteps.value as number
  }

  dispose(): void {
    this.mesh.geometry.dispose()
    this.material.dispose()
  }
}
