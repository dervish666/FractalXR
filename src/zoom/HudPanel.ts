import {
  CanvasTexture,
  SRGBColorSpace,
  DoubleSide,
  LinearFilter,
  Mesh,
  MeshBasicMaterial,
  PlaneGeometry,
  Vector3,
} from 'three'

export interface HudButton {
  id: string
  label: string
  row: number
  col: number
}

export interface HudStats {
  zoom: number
  iter: number
  res: number
  samples: number
  fps: number
  frameMs: number
  frameP95: number
  targetHz: number
  depth: number
  panel: number
  steps: number
  ulps: number
  julia: boolean
  invert: boolean
  ridge: number
  theme: string
  curve: number
  bands: number
  /** 0..1 while a refined tile is still being assembled band by band, 1 when idle. */
  refine: number
}

const W = 1024 // canvas pixels. FIXED — see the resize note on `draw` below.
const H = 560
const COLS = 6
const ROWS = 3
const PAD = 14
const BTN_TOP = 250
const BTN_H = (H - BTN_TOP - PAD) / ROWS - PAD
const BTN_W = (W - PAD) / COLS - PAD

/** The buttons, in the order they are laid out. */
export const HUD_BUTTONS: HudButton[] = [
  { id: 'res-', label: 'RES −', row: 0, col: 0 },
  { id: 'res+', label: 'RES +', row: 0, col: 1 },
  { id: 'iter-', label: 'ITER −', row: 0, col: 2 },
  { id: 'iter+', label: 'ITER +', row: 0, col: 3 },
  { id: 'steps-', label: 'STEP −', row: 0, col: 4 },
  { id: 'steps+', label: 'STEP +', row: 0, col: 5 },
  { id: 'depth-', label: 'HIGH −', row: 1, col: 0 },
  { id: 'depth+', label: 'HIGH +', row: 1, col: 1 },
  { id: 'curve-', label: 'SHAPE −', row: 1, col: 2 },
  { id: 'curve+', label: 'SHAPE +', row: 1, col: 3 },
  { id: 'bands-', label: 'BANDS −', row: 1, col: 4 },
  { id: 'bands+', label: 'BANDS +', row: 1, col: 5 },
  { id: 'invert', label: 'INVERT', row: 2, col: 0 },
  { id: 'relief', label: 'RELIEF', row: 2, col: 1 },
  { id: 'palette', label: 'COLOUR', row: 2, col: 2 },
  { id: 'julia', label: 'JULIA', row: 2, col: 3 },
  { id: 'reset', label: 'RESET', row: 2, col: 4 },
  { id: 'exit', label: 'EXIT VR', row: 2, col: 5 },
]

const btnRect = (b: HudButton): [number, number, number, number] => [
  PAD + b.col * (BTN_W + PAD),
  BTN_TOP + b.row * (BTN_H + PAD),
  BTN_W,
  BTN_H,
]

/**
 * The in-headset readout and control strip.
 *
 * Two things force this to exist rather than living in the DOM: the page HUD is invisible
 * once you are presenting, and the Quest browser blocks both the in-session devtools console
 * and `EXT_disjoint_timer_query`. So the only way to know what the headset is doing, or to
 * change anything without taking it off, is to draw it into the scene.
 *
 * Perf caveat worth stating plainly: frame time here is vsync-locked, so it tells you whether
 * the compositor is HOLDING its target rate, not how much headroom is left underneath. The
 * way to find the ceiling is to raise RES / ITER / STEP until p95 breaks away from the target
 * period — which is exactly why those are buttons.
 */
export class HudPanel {
  readonly mesh: Mesh
  private canvas = document.createElement('canvas')
  private ctx: CanvasRenderingContext2D
  private texture: CanvasTexture
  private hot: string | null = null
  private flash = new Map<string, number>()
  /** Set whenever something visible changed, so hover and press feedback are not stuck at the
   *  stats refresh rate — a 180ms flash inside a 250ms redraw is invisible most of the time. */
  needsRedraw = true
  readonly half: Vector3

  constructor(widthMetres = 0.9) {
    this.canvas.width = W
    this.canvas.height = H
    this.ctx = this.canvas.getContext('2d') as CanvasRenderingContext2D

    // NEVER resize this canvas at runtime: on three r0.184 a resized canvas does not reliably
    // reallocate its GPU texture, and the failure is invisible off-device.
    this.texture = new CanvasTexture(this.canvas)
    this.texture.minFilter = LinearFilter
    this.texture.magFilter = LinearFilter
    this.texture.generateMipmaps = false // nothing samples them, and they are rebuilt per redraw
    this.texture.colorSpace = SRGBColorSpace

    const h = (widthMetres * H) / W
    this.half = new Vector3(widthMetres / 2, h / 2, 0)
    this.mesh = new Mesh(
      new PlaneGeometry(widthMetres, h),
      // depthTest OFF on purpose. The relief is a ray-marched slab that writes gl_FragDepth
      // from the hit point, so a HUD positioned anywhere near the panel gets swallowed by the
      // terrain it is describing. A readout you cannot read is worse than one that floats.
      new MeshBasicMaterial({
        map: this.texture,
        transparent: true,
        depthTest: false,
        depthWrite: false,
        side: DoubleSide,
      }),
    )
    this.mesh.renderOrder = 999
  }

  /** Which button is under a panel-local point, or null. `local` is in mesh units. */
  buttonAt(local: Vector3): string | null {
    const u = local.x / (this.half.x * 2) + 0.5
    const v = 0.5 - local.y / (this.half.y * 2)
    if (u < 0 || u > 1 || v < 0 || v > 1) return null
    const px = u * W
    const py = v * H
    for (const b of HUD_BUTTONS) {
      const [x, y, w, h] = btnRect(b)
      if (px >= x && px <= x + w && py >= y && py <= y + h) return b.id
    }
    return null
  }

  /** Highlight the button the ray is over (null clears). */
  setHover(id: string | null): void {
    if (id === this.hot) return
    this.hot = id
    this.needsRedraw = true
  }

  /** Briefly light a button that was just pressed. */
  press(id: string): void {
    this.flash.set(id, performance.now())
    this.needsRedraw = true
  }

  draw(s: HudStats): void {
    const c = this.ctx
    c.clearRect(0, 0, W, H)
    c.fillStyle = 'rgba(6, 8, 14, 0.88)'
    roundRect(c, 0, 0, W, H, 18)
    c.fill()
    c.strokeStyle = 'rgba(127, 211, 255, 0.30)'
    c.lineWidth = 2
    roundRect(c, 1, 1, W - 2, H - 2, 18)
    c.stroke()

    const zoomTxt = s.zoom < 1000 ? `${s.zoom.toFixed(1)}×` : `${s.zoom.toExponential(2)}×`
    // frame time is the honest number here; fps saturates at the compositor's target
    const period = 1000 / Math.max(1, s.targetHz)
    const holding = s.frameP95 < period * 1.35
    const grade = s.ulps > 8 ? 'clean' : s.ulps > 4 ? 'softening' : s.ulps > 1 ? 'blocky' : 'mush'

    c.textBaseline = 'top'
    c.font = '600 34px ui-monospace, Menlo, monospace'
    c.fillStyle = '#e6ecf7'
    c.fillText(`zoom ${zoomTxt}`, PAD + 6, 18)
    c.fillStyle = holding ? '#7dd87d' : '#e2606a'
    c.fillText(`${s.frameMs.toFixed(1)}ms  p95 ${s.frameP95.toFixed(1)}ms`, 400, 18)
    c.fillStyle = '#9fb0c8'
    c.font = '500 26px ui-monospace, Menlo, monospace'
    c.fillText(`${s.fps.toFixed(0)} fps / ${s.targetHz}Hz target`, 400, 60)

    c.font = '500 26px ui-monospace, Menlo, monospace'
    const lines = [
      `field ${s.res}² · ${s.samples ** 2}x samples · ${s.iter} iter · ${s.steps} march`,
      `panel ${s.panel.toFixed(2)}m · high ${s.depth.toFixed(2)}m · shape ${s.curve.toFixed(2)} · bands ${s.bands.toFixed(1)}`,
      `fp32 ${s.ulps.toFixed(1)} ulps ${grade} · ${
        s.ridge < 0.05 ? 'terrace' : s.ridge > 0.95 ? 'ridge' : 'mixed'
      }${s.invert ? '·inverted' : ''} · ${s.julia ? 'julia' : 'mandelbrot'} · ${s.theme}`,
    ]
    lines.forEach((t, i) => {
      c.fillStyle = i === 2 && grade === 'mush' ? '#e2606a' : '#9fb0c8'
      c.fillText(t, PAD + 6, 106 + i * 38)
    })

    if (s.refine < 1) {
      // say so, or a busy few frames just reads as the app hanging
      c.fillStyle = '#e2c766'
      c.font = '600 21px ui-monospace, Menlo, monospace'
      c.fillText(`sharpening ${Math.round(s.refine * 100)}%`, PAD + 6, 222)
      c.fillStyle = 'rgba(226,199,102,0.85)'
      c.fillRect(PAD + 200, 226, (W - PAD * 2 - 210) * s.refine, 8)
    } else {
      c.fillStyle = '#5d6a80'
      c.font = '500 21px ui-monospace, Menlo, monospace'
      c.fillText('trigger drag · stick zoom · grip move · two grips scale', PAD + 6, 222)
    }

    const now = performance.now()
    for (const b of HUD_BUTTONS) {
      const [x, y, w, h] = btnRect(b)
      const lit = now - (this.flash.get(b.id) ?? -1e9) < 180
      const over = this.hot === b.id
      const danger = b.id === 'exit'
      c.fillStyle = lit
        ? '#7fd3ff'
        : over
          ? danger
            ? 'rgba(226,96,106,0.45)'
            : 'rgba(127,211,255,0.28)'
          : 'rgba(255,255,255,0.07)'
      roundRect(c, x, y, w, h, 10)
      c.fill()
      c.strokeStyle = danger ? 'rgba(226,96,106,0.65)' : 'rgba(127,211,255,0.35)'
      c.lineWidth = 2
      roundRect(c, x, y, w, h, 10)
      c.stroke()

      c.fillStyle = lit ? '#04070d' : danger ? '#ffb8bd' : '#dbe6f5'
      c.font = '600 25px ui-monospace, Menlo, monospace'
      c.textAlign = 'center'
      c.fillText(b.label, x + w / 2, y + h / 2 - 13)
      c.textAlign = 'left'
    }

    this.texture.needsUpdate = true
    // keep redrawing while a press flash is still fading
    this.needsRedraw = [...this.flash.values()].some((t) => now - t < 220)
  }

  dispose(): void {
    this.mesh.geometry.dispose()
    ;(this.mesh.material as MeshBasicMaterial).dispose()
    this.texture.dispose()
  }
}

function roundRect(c: CanvasRenderingContext2D, x: number, y: number, w: number, h: number, r: number): void {
  c.beginPath()
  c.moveTo(x + r, y)
  c.arcTo(x + w, y, x + w, y + h, r)
  c.arcTo(x + w, y + h, x, y + h, r)
  c.arcTo(x, y + h, x, y, r)
  c.arcTo(x, y, x + w, y, r)
  c.closePath()
}
