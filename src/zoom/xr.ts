import {
  AdditiveBlending,
  BufferGeometry,
  Group,
  Line,
  LineBasicMaterial,
  Vector3,
  type WebGLRenderer,
} from 'three'
import type { HudPanel } from './HudPanel'
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
const STICK_Y = 3

interface Hand {
  ctrl: Group
  src: XRInputSource | null
  laser: Line
  /** what the trigger grabbed when it went down: the fractal, a HUD button, or nothing */
  mode: 'none' | 'pan' | 'hud'
  heldButton: string | null
  held: { x: number; y: number } | null
  prevTrigger: boolean
  squeezing: boolean
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

  /** The controller groups, so the caller can parent them into the scene. */
  get controllers(): Group[] {
    return this.hands.map((h) => h.ctrl)
  }

  /** Park the rig in front of the viewer. Called on session start. */
  place(distance: number, height: number): void {
    this.rig.position.set(0, height, -distance)
    this.rig.quaternion.identity()
    this.layout()
  }

  /** Back to the desktop framing: rig at the origin, camera orbits it. */
  reset(): void {
    this.rig.position.set(0, 0, 0)
    this.rig.quaternion.identity()
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
    const drop = Math.min(this.panel.half.y * this.panelScale + this.hud.half.y + 0.06, 0.62)
    // well clear of the slab's front face, so it reads as a control surface in front of the
    // fractal rather than something embedded in it
    this.hud.mesh.position.set(0, -drop, this.panel.half.z * this.panelScale + 0.45)
    this.hud.mesh.rotation.x = 0.34 // tilt it up toward the face
  }

  private ray(h: Hand): void {
    h.ctrl.updateMatrixWorld()
    this.origin.setFromMatrixPosition(h.ctrl.matrixWorld)
    this.dir.set(0, 0, -1).transformDirection(h.ctrl.matrixWorld).normalize()
  }

  /** Drive one XR frame. No-op outside a session. */
  update(dt: number): void {
    if (!this.renderer.xr.isPresenting) return

    // --- grips first: they take a hand out of pointing duty --------------------
    for (const h of this.hands) h.squeezing = h.src?.gamepad?.buttons[SQUEEZE]?.pressed === true
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
        this.grabScale0 = this.panelScale
        this.mid0.copy(mid)
        this.rigPos0.copy(this.rig.position)
      }
      this.panelScale = Math.max(0.35, Math.min(8, this.grabScale0 * (dist / this.grabDist0)))
      this.rig.position.copy(this.rigPos0).add(mid).sub(this.mid0)
      this.layout()
      this.singleGrab = null
      return // both hands are busy; nothing else this frame
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

    // --- pointing -------------------------------------------------------------
    let hovered: string | null = null
    for (const h of this.hands) {
      const pad = h.src?.gamepad
      if (!pad || h.squeezing) {
        h.laser.visible = !h.squeezing
        continue
      }
      h.laser.visible = true
      this.ray(h)

      // HUD wins the ray, or a button press would also drag the fractal behind it
      const onHud = this.hooks.localAtRay(this.origin, this.dir, this.local, 'hud')
      const button = onHud ? this.hud.buttonAt(this.local) : null
      if (button) hovered = button

      const trigger = pad.buttons[TRIGGER]?.pressed === true
      const pressed = trigger && !h.prevTrigger
      const released = !trigger && h.prevTrigger
      h.prevTrigger = trigger

      if (pressed) {
        if (button) {
          h.mode = 'hud'
          h.heldButton = button
        } else if (!onHud) {
          h.mode = 'pan'
          h.held = this.hooks.complexAtRay(this.origin, this.dir)
        }
      }

      if (released) {
        // fire on release, and only if the ray is still on the button it went down on
        if (h.mode === 'hud' && h.heldButton && h.heldButton === button) this.hooks.press(h.heldButton)
        h.mode = 'none'
        h.heldButton = null
        h.held = null
      }

      if (trigger && h.mode === 'pan') {
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
