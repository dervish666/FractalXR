import { Group, Matrix4, Object3D, Quaternion, Vector3 } from 'three'

/**
 * Two-handed "grab the world" manipulation of the flame.
 *  - one grip: translate + rotate the flame rigidly with the hand
 *  - two grips: translate + rotate + uniform-scale (pull hands apart to grow the
 *    flame around you and fly through it)
 *
 * Unified via a "grip frame" G built from the grabbing controllers. On each frame
 * the flame transform = G · G0⁻¹ · M0, where G0 / M0 are the grip frame and flame
 * matrix captured when the grab set last changed.
 */
export class WorldGrab {
  private grabbing: Object3D[] = []
  private g0inv = new Matrix4()
  private m0 = new Matrix4()
  private active = false

  // scratch
  private G = new Matrix4()
  private out = new Matrix4()
  private p0 = new Vector3()
  private p1 = new Vector3()
  private mid = new Vector3()
  private xAxis = new Vector3()
  private yAxis = new Vector3()
  private zAxis = new Vector3()
  private up = new Vector3(0, 1, 0)
  private quat = new Quaternion()
  private scaleV = new Vector3()
  private basis = new Matrix4()

  constructor(
    private controllers: Object3D[],
    private target: Group,
  ) {
    for (const c of controllers) {
      // XR controller events aren't in the default Object3D event map
      ;(c as Object3D & { addEventListener: (t: string, f: () => void) => void }).addEventListener(
        'squeezestart',
        () => this.onGrab(c, true),
      )
      ;(c as Object3D & { addEventListener: (t: string, f: () => void) => void }).addEventListener(
        'squeezeend',
        () => this.onGrab(c, false),
      )
    }
  }

  private onGrab(c: Object3D, on: boolean): void {
    this.grabbing = this.controllers.filter((ctrl) => (ctrl === c ? on : this.grabbing.includes(ctrl)))
    this.recapture()
  }

  /** Build the grip frame from currently grabbing controllers into `this.G`. */
  private gripFrame(out: Matrix4): boolean {
    const n = this.grabbing.length
    if (n === 0) return false

    if (n === 1) {
      // rigid: position + orientation of the hand, unit scale
      this.grabbing[0].matrixWorld.decompose(this.mid, this.quat, this.scaleV)
      out.compose(this.mid, this.quat, this.scaleV.set(1, 1, 1))
      return true
    }

    // two (or more → use first two) hands
    this.p0.setFromMatrixPosition(this.grabbing[0].matrixWorld)
    this.p1.setFromMatrixPosition(this.grabbing[1].matrixWorld)
    this.mid.copy(this.p0).add(this.p1).multiplyScalar(0.5)
    const dist = Math.max(1e-4, this.p0.distanceTo(this.p1))

    this.xAxis.copy(this.p1).sub(this.p0).normalize()
    // pick an up hint not parallel to xAxis
    this.up.set(0, 1, 0)
    if (Math.abs(this.xAxis.dot(this.up)) > 0.95) this.up.set(0, 0, 1)
    this.zAxis.copy(this.xAxis).cross(this.up).normalize()
    this.yAxis.copy(this.zAxis).cross(this.xAxis).normalize()
    this.basis.makeBasis(this.xAxis, this.yAxis, this.zAxis)
    this.quat.setFromRotationMatrix(this.basis)
    out.compose(this.mid, this.quat, this.scaleV.set(dist, dist, dist))
    return true
  }

  private recapture(): void {
    if (!this.gripFrame(this.G)) {
      this.active = false
      return
    }
    this.g0inv.copy(this.G).invert()
    this.m0.copy(this.target.matrix)
    this.active = true
  }

  /** Call each frame, after controller world matrices are up to date. */
  update(): void {
    if (!this.active || this.grabbing.length === 0) return
    if (!this.gripFrame(this.G)) return
    this.out.copy(this.G).multiply(this.g0inv).multiply(this.m0)
    this.out.decompose(this.target.position, this.target.quaternion, this.target.scale)
  }

  get isGrabbing(): boolean {
    return this.grabbing.length > 0
  }

  get gripCount(): number {
    return this.grabbing.length
  }
}
