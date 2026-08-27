import {
  AdditiveBlending,
  BufferGeometry,
  Group,
  Line,
  LineBasicMaterial,
  Vector3,
  type WebGLRenderer,
} from 'three'
import type { HudPanel } from '../ui/HudPanel'
import type { ReliefPanel } from './ReliefPanel'

export interface XrHooks {
  /** Shift the complex window by a delta. */
  panBy(dx: number, dy: number): void
  /** Scale by 2^k about a complex-plane anchor. */
  zoom(k: number, anchor: { x: number; y: number } | null): void
  /** Complex coords under a world ray, or null on a miss. */
  complexAtRay(origin: Vector3, direction: Vector3): { x: number; y: number } | null
  /** Panel-local coords under a world ray, or null on a miss. */
  localAtRay(origin: Vector3, direction: Vector3, out: Vector3, mesh: 'panel' | 'hud'): boolean
  /** A HUD button was pressed. */
  press(id: string): void
}

const ZOOM_RATE = 1.9 // octaves/sec at full thumbstick deflection
const DEADZONE = 0.18
const TRIGGER = 0
const SQUEEZE = 1
const STICK_CLICK = 3
const STICK_Y = 3
const HUD_STANDOFF = 0.2 // metres in front of the slab's front face

interface Hand {
  ctrl: Group
  src: XRInputSource | null
  laser: Line
  /** what the trigger grabbed when it went down: the fractal, a HUD button, or nothing */
  mode: 'none' | 'pan' | 'hud'
  heldButton: string | null
  held: { x: number; y: number } | null
  prevTrigger: boolean
  trigger: boolean
  pressedEdge: boolean
  releasedEdge: boolean
  squeezing: boolean
  stickWas: boolean
}

/**
 * In-headset controls.
 *
 *   point + trigger   on the fractal: drag it under your ray. on the HUD: press the button.
 *   thumbstick Y      zoom, anchored where your ray meets the fractal
 *   one grip          carry the whole rig around the room
 *   two grips         pull apart to grow the panel, together to shrink it
 *
 * Ray priority is HUD first. Without that, aiming at a button would also pan the fractal
 * underneath it, and every button press would drag the view out from under you.
 */
export class ZoomXR {
  readonly rig = new Group()
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
  private panHand: Hand | null = null
  private pendingPlace: { distance: number; height: number } | null = null

  /** Panel size in metres. The mesh is a unit cube, so this is just its uniform scale. */
  panelScale = 1

  constructor(
    private renderer: WebGLRenderer,
    private panel: ReliefPanel,
    private hud: HudPanel,
    private hooks: XrHooks,
  ) {
    this.rig.add(panel.mesh)
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
        held: null,
        prevTrigger: false,
        trigger: false,
        pressedEdge: false,
        releasedEdge: false,
        squeezing: false,
        stickWas: false,
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

  /** The controller groups, so the caller can parent them into the scene. */
  get controllers(): Group[] {
    return this.hands.map((h) => h.ctrl)
  }

  /**
   * Park the rig in front of the viewer.
   *
   * Deferred to the first in-session frame on purpose. `local-floor` on Quest is the
   * guardian/stage space: its origin and yaw come from room setup, NOT from where you are
   * standing or facing when the session opens. Writing a fixed (0, h, -d) there drops the
   * panel at a fixed spot in the room, which is behind you as often as not. The XR camera has
   * no valid pose until the animation loop runs, hence the deferral rather than doing it in
   * the sessionstart handler.
   */
  place(distance: number, height: number): void {
    this.pendingPlace = { distance, height }
    this.layout()
  }

  private placeNow(distance: number, height: number): void {
    const cam = this.renderer.xr.getCamera()
    this.origin.setFromMatrixPosition(cam.matrixWorld)
    this.dir.set(0, 0, -1).transformDirection(cam.matrixWorld)
    this.dir.y = 0 // yaw only: nobody wants the panel pitched to match how they held their head
    if (this.dir.lengthSq() < 1e-6) this.dir.set(0, 0, -1)
    this.dir.normalize()
    this.rig.position.set(
      this.origin.x + this.dir.x * distance,
      height,
      this.origin.z + this.dir.z * distance,
    )
    this.rig.rotation.set(0, Math.atan2(this.dir.x, this.dir.z) + Math.PI, 0) // face the viewer
    this.layout()
  }

  /** Clear every gesture baseline. Without this the first grip of the NEXT session snaps the
   *  rig to an offset captured in the last one. */
  resetGestures(): void {
    this.grabDist0 = 0
    this.singleGrab = null
    this.panHand = null
    this.pendingPlace = null
    for (const h of this.hands) {
      h.mode = 'none'
      h.heldButton = null
      h.held = null
      h.prevTrigger = false
      h.trigger = false
      h.pressedEdge = h.releasedEdge = false
      h.squeezing = false
      h.stickWas = false
    }
    this.hud.setHover(null)
  }

  /** Back to the desktop framing: rig at the origin, camera orbits it. */
  reset(): void {
    this.rig.position.set(0, 0, 0)
    this.rig.quaternion.identity()
    this.resetGestures()
  }

  /**
   * Size the panel and park the HUD under it.
   *
   * The drop is CAPPED rather than tracking the panel's bottom edge: at 2.4m that edge is
   * near the floor, and a readout you have to look at your feet to read is no readout at all.
   * Past the cap the HUD overlaps the lower strip of the fractal, which is the right trade.
   */
  layout(): void {
    this.panel.mesh.scale.setScalar(this.panelScale)
    // Anchor the slab's FRONT FACE, not its centre. Relief depth ramps with zoom, and a slab
    // that grows symmetrically sends half that growth straight at your face — over a metre of
    // it on a 2.4m panel, which is why the panel appeared to move and then swallow you as you
    // zoomed. Growing backward instead carves the fractal INTO a wall that stays put.
    this.panel.mesh.position.z = -this.panel.half.z * this.panelScale
    const drop = Math.min(this.panel.half.y * this.panelScale + this.hud.half.y + 0.06, 0.62)
    // Constant standoff from that fixed front face. Keying it to the live slab depth was the
    // same bug in miniature: the HUD flew toward you as the relief deepened.
    this.hud.mesh.position.set(0, -drop, HUD_STANDOFF)
    // NEGATIVE: a plane's normal is +Z, and rotating +X tips it DOWN. The HUD sits below eye
    // level, so it has to tip up to face you.
    this.hud.mesh.rotation.x = -0.34
  }

  private ray(h: Hand): void {
    h.ctrl.updateMatrixWorld()
    this.origin.setFromMatrixPosition(h.ctrl.matrixWorld)
    this.dir.set(0, 0, -1).transformDirection(h.ctrl.matrixWorld).normalize()
  }

  /** Drive one XR frame. No-op outside a session. */
  update(dt: number): void {
    if (!this.renderer.xr.isPresenting) return
    if (this.pendingPlace) {
      const { distance, height } = this.pendingPlace
      this.pendingPlace = null
      this.placeNow(distance, height)
    }

    // Sample every hand ONCE, up front. Edge detection has to happen for every hand on every
    // frame or an early return leaves prevTrigger stale — which is how a trigger released
    // during a grip fires a HUD button (EXIT VR among them) frames later.
    for (const h of this.hands) {
      const pad = h.src?.gamepad
      h.squeezing = pad?.buttons[SQUEEZE]?.pressed === true
      const trigger = pad?.buttons[TRIGGER]?.pressed === true
      h.pressedEdge = trigger && !h.prevTrigger
      h.releasedEdge = !trigger && h.prevTrigger
      h.trigger = trigger
      h.prevTrigger = trigger
      // thumbstick click is the one spare face button here: cycles to the next mode (also
      // on the HUD as MODE ▸). Sampled in this unconditional loop so the edge never goes stale.
      const stick = pad?.buttons[STICK_CLICK]?.pressed === true
      if (stick && !h.stickWas) this.hooks.press('mode')
      h.stickWas = stick
      if (h.squeezing) {
        // a gripping hand is not pointing: drop whatever it was holding, and drop it silently
        if (this.panHand === h) this.panHand = null
        h.mode = 'none'
        h.heldButton = null
        h.held = null
      }
    }

    const gripping = this.hands.filter((h) => h.squeezing)

    // --- two grips: scale and carry -------------------------------------------
    if (gripping.length === 2) {
      this.ray(gripping[0])
      this.a.copy(this.origin)
      this.ray(gripping[1])
      this.b.copy(this.origin)
      const dist = this.a.distanceTo(this.b)
      const mid = this.a.clone().lerp(this.b, 0.5)
      if (this.grabDist0 === 0) {
        this.grabDist0 = Math.max(0.05, dist)
        this.grabScale0 = this.panelScale
        this.mid0.copy(mid)
        this.rigPos0.copy(this.rig.position)
      }
      this.panelScale = Math.max(0.35, Math.min(8, this.grabScale0 * (dist / this.grabDist0)))
      this.rig.position.copy(this.rigPos0).add(mid).sub(this.mid0)
      this.layout()
      this.singleGrab = null
      for (const h of this.hands) h.laser.visible = false
      this.hud.setHover(null)
      return
    }
    this.grabDist0 = 0

    // --- one grip: carry -------------------------------------------------------
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

    // --- pointing --------------------------------------------------------------
    let hovered: string | null = null
    for (const h of this.hands) {
      if (!h.src?.gamepad || h.squeezing) {
        h.laser.visible = false
        continue
      }
      h.laser.visible = true
      this.ray(h)

      // HUD wins the ray, or a button press would also drag the fractal behind it
      const onHud = this.hooks.localAtRay(this.origin, this.dir, this.local, 'hud')
      const button = onHud ? this.hud.buttonAt(this.local) : null
      if (button) hovered = button

      if (h.pressedEdge) {
        if (button) {
          h.mode = 'hud'
          h.heldButton = button
        } else if (!onHud && this.panHand === null) {
          // one hand pans at a time; two hands both re-anchoring cancel each other out
          h.mode = 'pan'
          this.panHand = h
          h.held = this.hooks.complexAtRay(this.origin, this.dir)
        }
      }

      if (h.releasedEdge) {
        // fire on release, and only if the ray is still on the button it went down on
        if (h.mode === 'hud' && h.heldButton && h.heldButton === button) this.hooks.press(h.heldButton)
        if (this.panHand === h) this.panHand = null
        h.mode = 'none'
        h.heldButton = null
        h.held = null
      }

      if (h.trigger && h.mode === 'pan') {
        const here = this.hooks.complexAtRay(this.origin, this.dir)
        if (here && h.held) {
          this.hooks.panBy(h.held.x - here.x, h.held.y - here.y)
          // re-read after the pan so the grabbed point stays pinned under the ray
          h.held = this.hooks.complexAtRay(this.origin, this.dir)
        } else if (here && !h.held) {
          h.held = here
        }
      }

      // thumbstick Y zooms about wherever the ray lands
      const pad = h.src.gamepad
      const stick = pad.axes.length > STICK_Y ? pad.axes[STICK_Y] : (pad.axes[1] ?? 0)
      if (Math.abs(stick) > DEADZONE && h.mode !== 'hud') {
        const k = (Math.sign(stick) * (Math.abs(stick) - DEADZONE)) / (1 - DEADZONE)
        this.hooks.zoom(k * ZOOM_RATE * dt, this.hooks.complexAtRay(this.origin, this.dir))
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
