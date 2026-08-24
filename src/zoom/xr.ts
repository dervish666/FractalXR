import {
  Group,
  Matrix4,
  Plane,
  Quaternion,
  Raycaster,
  Vector3,
  type WebGLRenderer,
} from 'three'
import type { ReliefPanel } from './ReliefPanel'

export interface XrHooks {
  /** Pan so that `from` (complex coords) ends up where `to` is now. */
  panBy(dx: number, dy: number): void
  /** Scale by 2^k about a complex-plane anchor. */
  zoom(k: number, anchor: { x: number; y: number } | null): void
  /** Complex coords under a world-space ray, or null if it misses the panel plane. */
  complexAtRay(origin: Vector3, direction: Vector3): { x: number; y: number } | null
}

const ZOOM_RATE = 1.6 // octaves/sec at full thumbstick deflection
const DEADZONE = 0.15

/**
 * Minimal in-headset controls for the relief panel. Deliberately small: this exists to
 * answer one question (does a ray-marched escape-time relief read as depth on a real
 * headset), not to be a VR UI.
 *
 *   trigger + move  drag the fractal under the ray, exactly like the mouse
 *   thumbstick Y    zoom, anchored where your ray meets the panel
 *   grip            grab the panel itself and reposition it in the room
 *
 * The DOM HUD is invisible in-session, so zoom depth and the fp32 headroom readout are
 * desktop-only for now.
 */
export class ZoomXR {
  readonly rig = new Group()
  private ray = new Raycaster()
  private plane = new Plane()
  private normal = new Vector3()
  private origin = new Vector3()
  private dir = new Vector3()
  private hit = new Vector3()
  private held: { x: number; y: number } | null = null
  private grabbed: XRInputSource | null = null
  private grabMatrix = new Matrix4()
  private q = new Quaternion()

  constructor(
    private renderer: WebGLRenderer,
    private panel: ReliefPanel,
    private hooks: XrHooks,
  ) {
    this.rig.add(panel.mesh)
  }

  /** Park the panel in front of the viewer at eye height. Called on session start. */
  place(): void {
    this.rig.position.set(0, 1.35, -1.15)
    this.rig.quaternion.identity()
  }

  /** Back to the desktop framing (panel at the origin, camera orbits it). */
  reset(): void {
    this.rig.position.set(0, 0, 0)
    this.rig.quaternion.identity()
  }

  /** Complex coords under an input source's target ray. */
  private complexAtSource(src: XRInputSource, frame: XRFrame, space: XRReferenceSpace): { x: number; y: number } | null {
    const pose = frame.getPose(src.targetRaySpace, space)
    if (!pose) return null
    const m = new Matrix4().fromArray(pose.transform.matrix)
    this.origin.setFromMatrixPosition(m)
    this.dir.set(0, 0, -1).applyQuaternion(this.q.setFromRotationMatrix(m)).normalize()
    return this.hooks.complexAtRay(this.origin, this.dir)
  }

  /** Drive one XR frame. No-op outside a session. */
  update(dt: number, frame: XRFrame | null): void {
    const session = this.renderer.xr.getSession()
    const space = this.renderer.xr.getReferenceSpace()
    if (!session || !space || !frame) return

    for (const src of session.inputSources) {
      const pad = src.gamepad
      if (!pad) continue

      // --- grip: carry the panel around the room ---------------------------
      const squeezing = pad.buttons[1]?.pressed === true
      if (squeezing && this.grabbed === null) {
        const pose = frame.getPose(src.gripSpace ?? src.targetRaySpace, space)
        if (pose) {
          const ctrl = new Matrix4().fromArray(pose.transform.matrix)
          // remember where the rig sits relative to the controller, then follow it
          this.grabMatrix.copy(ctrl).invert().multiply(this.rig.matrix)
          this.grabbed = src
        }
      } else if (!squeezing && this.grabbed === src) {
        this.grabbed = null
      }
      if (this.grabbed === src) {
        const pose = frame.getPose(src.gripSpace ?? src.targetRaySpace, space)
        if (pose) {
          const ctrl = new Matrix4().fromArray(pose.transform.matrix)
          ctrl.multiply(this.grabMatrix).decompose(this.rig.position, this.rig.quaternion, new Vector3())
        }
        continue // a hand that is carrying the panel does not also pan it
      }

      // --- trigger: drag the fractal under the ray --------------------------
      const pulling = pad.buttons[0]?.pressed === true
      const here = this.complexAtSource(src, frame, space)
      if (pulling && here) {
        if (this.held) this.hooks.panBy(this.held.x - here.x, this.held.y - here.y)
        // re-read after the pan so the grabbed point stays pinned to the ray
        this.held = this.complexAtSource(src, frame, space)
      } else if (!pulling) {
        this.held = null
      }

      // --- thumbstick Y: zoom about where the ray lands ---------------------
      const stick = pad.axes.length >= 4 ? pad.axes[3] : (pad.axes[1] ?? 0)
      if (Math.abs(stick) > DEADZONE) {
        const k = Math.sign(stick) * (Math.abs(stick) - DEADZONE) / (1 - DEADZONE)
        this.hooks.zoom(k * ZOOM_RATE * dt, here)
      }
    }
  }

  /** Where the panel plane sits in world space, for the ray tests above. */
  syncPlane(): void {
    this.panel.mesh.updateMatrixWorld()
    this.normal.set(0, 0, 1).applyQuaternion(this.panel.mesh.getWorldQuaternion(this.q))
    this.hit.setFromMatrixPosition(this.panel.mesh.matrixWorld)
    this.plane.setFromNormalAndCoplanarPoint(this.normal, this.hit)
  }

  /** Panel-local coords under a world ray, or null on a miss. Used by mouse and controller alike. */
  localAtRay(origin: Vector3, direction: Vector3, out: Vector3): boolean {
    this.syncPlane()
    this.ray.set(origin, direction)
    if (!this.ray.ray.intersectPlane(this.plane, out)) return false
    this.panel.mesh.worldToLocal(out)
    return true
  }
}
