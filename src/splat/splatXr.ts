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

export const SPLAT_BUTTONS: HudButton[] = [
  { id: 'count-', label: 'FEWER', row: 0, col: 0 },
  { id: 'count+', label: 'MORE', row: 0, col: 1 },
  { id: 'regen', label: 'REBUILD', row: 0, col: 2 },
  { id: 'spin', label: 'SPIN', row: 0, col: 3 },
  { id: 'size-', label: 'SIZE −', row: 1, col: 0 },
  { id: 'size+', label: 'SIZE +', row: 1, col: 1 },
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
const STICK_Y = 3
const DEADZONE = 0.18
const HUD_DROP = 0.55
const HUD_STANDOFF = 0.25

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
  readonly rig = new Group()
  scale = 1
  spin = 0 // radians/sec of idle yaw

  private hands: Hand[] = []
  private origin = new Vector3()
  private dir = new Vector3()
  private local = new Vector3()
  private a = new Vector3()
  private b = new Vector3()
  private mid0 = new Vector3()
  private rigPos0 = new Vector3()
  private grabDist0 = 0
  private grabScale0 = 1
  private grabOffset = new Vector3()
  private singleGrab: Hand | null = null
  private pendingPlace: { distance: number; height: number } | null = null

  constructor(
    private renderer: WebGLRenderer,
    private content: Object3D,
    private hud: HudPanel,
    private hooks: SplatXrHooks,
  ) {
    this.rig.add(content)
    this.rig.add(hud.mesh)
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
  }

  get controllers(): Object3D[] {
    return this.hands.map((h) => h.ctrl)
  }

  /** Park the rig in front of the viewer, on the first in-session frame. */
  place(distance = 1.5, height = 1.35): void {
    this.pendingPlace = { distance, height }
    this.layout()
  }

  reset(): void {
    this.rig.position.set(0, 0, 0)
    this.rig.quaternion.identity()
    this.scale = 1
    this.resetGestures()
    this.layout()
  }

  /** Clear every gesture baseline, or the first grip of the NEXT session snaps the rig. */
  resetGestures(): void {
    this.grabDist0 = 0
    this.singleGrab = null
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

  layout(): void {
    this.content.scale.setScalar(this.scale)
    // fixed standoff: keying it to the content's size sends the HUD at your face as it grows
    this.hud.mesh.position.set(0, -HUD_DROP, HUD_STANDOFF)
    // NEGATIVE: a plane's normal is +Z and rotating +X tips it DOWN, so a HUD below eye level
    // has to tip up to face you
    this.hud.mesh.rotation.x = -0.34
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
    this.rig.position.set(
      this.origin.x + this.dir.x * distance,
      height,
      this.origin.z + this.dir.z * distance,
    )
    this.rig.rotation.set(0, Math.atan2(this.dir.x, this.dir.z) + Math.PI, 0)
    this.layout()
  }

  update(dt: number): void {
    if (!this.renderer.xr.isPresenting) return
    if (this.pendingPlace) {
      const { distance, height } = this.pendingPlace
      this.pendingPlace = null
      this.placeNow(distance, height)
    }
    if (this.spin !== 0) this.content.rotation.y += this.spin * dt
    this.layout()

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
    const gripping = this.hands.filter((h) => h.squeezing)

    if (gripping.length === 2) {
      this.ray(gripping[0])
      this.a.copy(this.origin)
      this.ray(gripping[1])
      this.b.copy(this.origin)
      const dist = this.a.distanceTo(this.b)
      const mid = this.a.clone().lerp(this.b, 0.5)
      if (this.grabDist0 === 0) {
        this.grabDist0 = Math.max(0.05, dist)
        this.grabScale0 = this.scale
        this.mid0.copy(mid)
        this.rigPos0.copy(this.rig.position)
      }
      this.scale = Math.max(0.1, Math.min(20, this.grabScale0 * (dist / this.grabDist0)))
      this.rig.position.copy(this.rigPos0).add(mid).sub(this.mid0)
      this.layout()
      this.singleGrab = null
      for (const h of this.hands) h.laser.visible = false
      this.hud.setHover(null)
      return
    }
    this.grabDist0 = 0

    if (gripping.length === 1) {
      const h = gripping[0]
      this.ray(h)
      if (this.singleGrab !== h) {
        this.singleGrab = h
        this.grabOffset.copy(this.rig.position).sub(this.origin)
      }
      this.rig.position.copy(this.origin).add(this.grabOffset)
    } else {
      this.singleGrab = null
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

      const sy = pad.axes.length > STICK_Y ? pad.axes[STICK_Y] : 0
      if (Math.abs(sy) > DEADZONE && h.mode !== 'hud') {
        const k = (Math.sign(sy) * (Math.abs(sy) - DEADZONE)) / (1 - DEADZONE)
        this.scale = Math.max(0.1, Math.min(20, this.scale * Math.exp(-k * 1.1 * dt)))
        this.layout()
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
