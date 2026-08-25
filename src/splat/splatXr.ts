import {
  AdditiveBlending,
  BufferGeometry,
  Group,
  Line,
  LineBasicMaterial,
  Object3D,
  Vector3,
  type WebGLRenderer,
} from 'three'
import type { HudButton, HudPanel } from '../ui/HudPanel'
import { WorldGrab } from '../xr/WorldGrab'

export const SPLAT_BUTTONS: HudButton[] = [
  { id: 'count-', label: 'FEWER', row: 0, col: 0 },
  { id: 'count+', label: 'MORE', row: 0, col: 1 },
  { id: 'regen', label: 'REBUILD', row: 0, col: 2 },
  { id: 'spin', label: 'SPIN', row: 0, col: 3 },
  { id: 'flip', label: 'FLIP', row: 1, col: 0 },
  { id: 'recentre', label: 'RECENTRE', row: 1, col: 1 },
  { id: 'reset', label: 'RESET', row: 1, col: 2 },
  { id: 'exit', label: 'EXIT VR', row: 1, col: 3 },
]

export interface SplatXrHooks {
  press(id: string): void
  /** Panel-local coords under a world ray against the HUD, or null on a miss. */
  hudAtRay(origin: Vector3, direction: Vector3, out: Vector3): boolean
}

const TRIGGER = 0
const SQUEEZE = 1
const STICK_X = 2
const DEADZONE = 0.18
const HUD_DROP = 0.55

interface Hand {
  ctrl: Object3D
  src: XRInputSource | null
  laser: Line
  mode: 'none' | 'hud'
  heldButton: string | null
  prevTrigger: boolean
  trigger: boolean
  pressedEdge: boolean
  releasedEdge: boolean
  squeezing: boolean
}

/**
 * In-headset controls for the splat viewer.
 *
 *   one grip     carry the sculpture around the room
 *   two grips    pull apart to grow it — grow it enough and you can walk inside
 *   stick Y      scale, stick X spins it
 *   trigger      press a HUD button
 *
 * A near-copy of the relief zoomer's control scheme on purpose: the two pages should not want
 * different muscle memory. The zoomer's hard-won details are carried over rather than
 * rediscovered — every hand is sampled once up front so no early return can strand the trigger
 * edge state (a trigger released during a grip used to fire a HUD button, EXIT VR included),
 * and placement is head-relative on the first in-session frame because `local-floor` on Quest
 * is the guardian space, not where you happen to be standing.
 */
export class SplatXR {
  /** Grabbable: holds the sculpture, and WorldGrab owns its transform entirely. */
  readonly grabRig = new Group()
  /** NOT grabbable: the control panel stays put and stays a readable size. */
  readonly hudRig = new Group()
  spin = 0 // radians/sec of idle yaw

  private hands: Hand[] = []
  private grab: WorldGrab
  private origin = new Vector3()
  private dir = new Vector3()
  private local = new Vector3()
  private pendingPlace: { distance: number; height: number } | null = null

  constructor(
    private renderer: WebGLRenderer,
    private content: Object3D,
    private hud: HudPanel,
    private hooks: SplatXrHooks,
  ) {
    this.grabRig.add(content)
    this.hudRig.add(hud.mesh)

    for (let i = 0; i < 2; i++) {
      const ctrl = renderer.xr.getController(i)
      const laser = makeLaser()
      ctrl.add(laser)
      const hand: Hand = {
        ctrl,
        src: null,
        laser,
        mode: 'none',
        heldButton: null,
        prevTrigger: false,
        trigger: false,
        pressedEdge: false,
        releasedEdge: false,
        squeezing: false,
      }
      ctrl.addEventListener('connected', (e) => {
        hand.src = (e as unknown as { data: XRInputSource }).data
      })
      ctrl.addEventListener('disconnected', () => {
        hand.src = null
        hand.mode = 'none'
        hand.squeezing = false
      })
      this.hands.push(hand)
    }

    // The same grab the main app uses for the point cloud, so the two do not want different
    // muscle memory: one grip translates AND rotates rigidly with the hand, two grips add
    // uniform scale. It listens to squeezestart/squeezeend on the controllers itself.
    this.grab = new WorldGrab(this.hands.map((h) => h.ctrl), this.grabRig)
  }

  get controllers(): Object3D[] {
    return this.hands.map((h) => h.ctrl)
  }

  get scale(): number {
    return this.grabRig.scale.x
  }

  get isGrabbing(): boolean {
    return this.grab.isGrabbing
  }

  /** Park both rigs in front of the viewer, on the first in-session frame. */
  place(distance = 1.5, height = 1.35): void {
    this.pendingPlace = { distance, height }
  }

  /** Put the sculpture back in front of you without disturbing its scale or spin. */
  recentre(): void {
    this.place()
  }

  reset(): void {
    this.grabRig.position.set(0, 0, 0)
    this.grabRig.quaternion.identity()
    this.grabRig.scale.setScalar(1)
    this.content.rotation.set(0, 0, 0)
    this.spin = 0
    this.resetGestures()
  }

  /** Clear the pointing state. WorldGrab recaptures on its own squeeze events. */
  resetGestures(): void {
    this.pendingPlace = null
    for (const h of this.hands) {
      h.mode = 'none'
      h.heldButton = null
      h.prevTrigger = false
      h.trigger = false
      h.pressedEdge = h.releasedEdge = false
      h.squeezing = false
    }
    this.hud.setHover(null)
  }

  private ray(h: Hand): void {
    h.ctrl.updateMatrixWorld()
    this.origin.setFromMatrixPosition(h.ctrl.matrixWorld)
    this.dir.set(0, 0, -1).transformDirection(h.ctrl.matrixWorld).normalize()
  }

  private placeNow(distance: number, height: number): void {
    const cam = this.renderer.xr.getCamera()
    this.origin.setFromMatrixPosition(cam.matrixWorld)
    this.dir.set(0, 0, -1).transformDirection(cam.matrixWorld)
    this.dir.y = 0 // yaw only
    if (this.dir.lengthSq() < 1e-6) this.dir.set(0, 0, -1)
    this.dir.normalize()
    const yaw = Math.atan2(this.dir.x, this.dir.z) + Math.PI

    this.grabRig.position.set(
      this.origin.x + this.dir.x * distance,
      height,
      this.origin.z + this.dir.z * distance,
    )
    this.grabRig.rotation.set(0, yaw, 0)

    // the panel sits nearer and lower, and never scales with the sculpture
    this.hudRig.position.set(
      this.origin.x + this.dir.x * (distance * 0.55),
      height - HUD_DROP,
      this.origin.z + this.dir.z * (distance * 0.55),
    )
    this.hudRig.rotation.set(0, yaw, 0)
    this.hud.mesh.position.set(0, 0, 0)
    // NEGATIVE: a plane's normal is +Z and rotating +X tips it DOWN, so a panel below eye
    // level has to tip up to face you
    this.hud.mesh.rotation.set(-0.42, 0, 0)
  }

  update(dt: number): void {
    if (!this.renderer.xr.isPresenting) return
    if (this.pendingPlace) {
      const { distance, height } = this.pendingPlace
      this.pendingPlace = null
      this.placeNow(distance, height)
    }
    if (this.spin !== 0) this.content.rotation.y += this.spin * dt
    this.grab.update()

    // sample every hand ONCE, before any branch, so edge state can never go stale
    for (const h of this.hands) {
      const pad = h.src?.gamepad
      h.squeezing = pad?.buttons[SQUEEZE]?.pressed === true
      const trigger = pad?.buttons[TRIGGER]?.pressed === true
      h.pressedEdge = trigger && !h.prevTrigger
      h.releasedEdge = !trigger && h.prevTrigger
      h.trigger = trigger
      h.prevTrigger = trigger
      if (h.squeezing) {
        h.mode = 'none'
        h.heldButton = null
      }
    }

    let hovered: string | null = null
    for (const h of this.hands) {
      const pad = h.src?.gamepad
      if (!pad || h.squeezing) {
        h.laser.visible = false
        continue
      }
      h.laser.visible = true
      this.ray(h)

      const onHud = this.hooks.hudAtRay(this.origin, this.dir, this.local)
      const button = onHud ? this.hud.buttonAt(this.local) : null
      if (button) hovered = button

      if (h.pressedEdge && button) {
        h.mode = 'hud'
        h.heldButton = button
      }
      if (h.releasedEdge) {
        // fire on release, and only if the ray is still on the button it went down on
        if (h.mode === 'hud' && h.heldButton && h.heldButton === button) this.hooks.press(h.heldButton)
        h.mode = 'none'
        h.heldButton = null
      }

      const sx = pad.axes.length > STICK_X ? pad.axes[STICK_X] : 0
      if (Math.abs(sx) > DEADZONE && h.mode !== 'hud') {
        const k = (Math.sign(sx) * (Math.abs(sx) - DEADZONE)) / (1 - DEADZONE)
        this.content.rotation.y += k * 1.4 * dt
      }
    }
    this.hud.setHover(hovered)
  }
}

function makeLaser(): Line {
  const geo = new BufferGeometry().setFromPoints([new Vector3(0, 0, 0), new Vector3(0, 0, -1.6)])
  const mat = new LineBasicMaterial({
    color: 0x7fd3ff,
    transparent: true,
    opacity: 0.45,
    blending: AdditiveBlending,
    depthWrite: false,
  })
  return new Line(geo, mat)
}
