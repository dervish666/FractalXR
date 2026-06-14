import {
  AddEquation,
  BufferAttribute,
  BufferGeometry,
  CustomBlending,
  GLSL3,
  OneFactor,
  Points,
  RawShaderMaterial,
  Texture,
} from 'three'
import { POINTS_FRAG, POINTS_VERT } from './shaders'

/**
 * The flame point cloud. One THREE.Points vertex per particle; the vertex shader
 * reads its world position from the simulation's state texture (via a `ref` attribute
 * = the particle's texel UV) and splats a soft additive sprite into the HDR buffer.
 */
export class FlamePoints {
  readonly points: Points
  private material: RawShaderMaterial

  constructor(size: number, palette: Texture, pointBrightness: number) {
    const count = size * size
    const geo = new BufferGeometry()
    const position = new Float32Array(count * 3) // dummy; real pos comes from the texture
    const ref = new Float32Array(count * 2)
    for (let i = 0; i < count; i++) {
      const x = i % size
      const y = (i / size) | 0
      ref[i * 2 + 0] = (x + 0.5) / size
      ref[i * 2 + 1] = (y + 0.5) / size
    }
    geo.setAttribute('position', new BufferAttribute(position, 3))
    geo.setAttribute('ref', new BufferAttribute(ref, 2))
    geo.setDrawRange(0, count)

    this.material = new RawShaderMaterial({
      glslVersion: GLSL3,
      vertexShader: POINTS_VERT,
      fragmentShader: POINTS_FRAG,
      uniforms: {
        uState: { value: null as Texture | null },
        uPalette: { value: palette },
        uPointSize: { value: 2.0 },
        uBrightness: { value: pointBrightness },
      },
      transparent: true,
      depthTest: false,
      depthWrite: false,
      blending: CustomBlending,
      blendEquation: AddEquation,
      blendSrc: OneFactor,
      blendDst: OneFactor,
      blendSrcAlpha: OneFactor,
      blendDstAlpha: OneFactor,
    })

    this.points = new Points(geo, this.material)
    this.points.frustumCulled = false
  }

  setStateTexture(tex: Texture): void {
    this.material.uniforms.uState.value = tex
  }

  setPalette(tex: Texture): void {
    this.material.uniforms.uPalette.value = tex
  }

  setActiveCount(n: number): void {
    this.points.geometry.setDrawRange(0, Math.max(0, Math.floor(n)))
  }

  setPointSize(px: number): void {
    this.material.uniforms.uPointSize.value = px
  }

  setBrightness(b: number): void {
    this.material.uniforms.uBrightness.value = b
  }
}
