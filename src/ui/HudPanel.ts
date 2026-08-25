import {
  CanvasTexture,
  DoubleSide,
  LinearFilter,
  Mesh,
  MeshBasicMaterial,
  PlaneGeometry,
  SRGBColorSpace,
  Vector3,
} from 'three'

export interface HudButton {
  id: string
  label: string
  row: number
  col: number
}

/** Everything the panel draws. Callers own their own wording; this only lays it out. */
export interface HudContent {
  /** big, left */
  headline: string
  /** big, right — the number you are watching */
  metric?: string
  /** false paints the metric red */
  metricOk?: boolean
  /** small, under the metric */
  sub?: string
  /** the body block */
  lines: string[]
  /** the dim line above the buttons, replaced by a progress bar when one is running */
  footer: string
  progress?: { frac: number; label: string }
  /** buttons that should read as latched-on rather than momentary */
  lit?: (id: string) => boolean
}

const W = 1024 // canvas pixels. FIXED at construction — see the resize note below.
const PAD = 14
const BTN_TOP = 250

/**
 * An in-world readout and control strip, drawn to a canvas texture.
 *
 * It exists because a DOM HUD is invisible once you are presenting, and the Quest browser
 * blocks both the in-session devtools console and `EXT_disjoint_timer_query`. So the only way
 * to know what the headset is doing, or to change anything without taking it off, is to draw
 * it into the scene.
 *
 * Generic on purpose: the relief zoomer and the splat viewer want completely different
 * readouts and buttons but exactly the same slab of glass to put them on.
 */
export class HudPanel {
  readonly mesh: Mesh
  readonly half: Vector3
  readonly buttons: HudButton[]
  /** Set whenever something visible changed, so hover and press feedback are not stuck at the
   *  caller's stats refresh rate — a 180ms flash inside a 250ms redraw is invisible most of
   *  the time. */
  needsRedraw = true

  private canvas = document.createElement('canvas')
  private ctx: CanvasRenderingContext2D
  private texture: CanvasTexture
  private hot: string | null = null
  private flash = new Map<string, number>()
  private cols: number
  private rows: number
  private height: number
  private btnW: number
  private btnH: number

  constructor(buttons: HudButton[], widthMetres = 1.0) {
    this.buttons = buttons
    this.cols = Math.max(1, ...buttons.map((b) => b.col + 1))
    this.rows = Math.max(1, ...buttons.map((b) => b.row + 1))
    this.btnW = (W - PAD) / this.cols - PAD
    this.btnH = 84
    this.height = BTN_TOP + this.rows * (this.btnH + PAD) + PAD

    this.canvas.width = W
    this.canvas.height = this.height
    this.ctx = this.canvas.getContext('2d') as CanvasRenderingContext2D

    // NEVER resize this canvas at runtime: on three r0.184 a resized canvas does not reliably
    // reallocate its GPU texture, and the failure is invisible off-device.
    this.texture = new CanvasTexture(this.canvas)
    this.texture.minFilter = LinearFilter
    this.texture.magFilter = LinearFilter
    this.texture.generateMipmaps = false // nothing samples them, and they are rebuilt per redraw
    this.texture.colorSpace = SRGBColorSpace

    const h = (widthMetres * this.height) / W
    this.half = new Vector3(widthMetres / 2, h / 2, 0)
    this.mesh = new Mesh(
      new PlaneGeometry(widthMetres, h),
      // depthTest OFF on purpose. A ray-marched slab writes gl_FragDepth from the hit point,
      // so a HUD positioned anywhere near it gets swallowed by the terrain it is describing.
      // A readout you cannot read is worse than one that floats.
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

  private rect(b: HudButton): [number, number, number, number] {
    return [
      PAD + b.col * (this.btnW + PAD),
      BTN_TOP + b.row * (this.btnH + PAD),
      this.btnW,
      this.btnH,
    ]
  }

  /** Which button is under a panel-local point, or null. `local` is in mesh units. */
  buttonAt(local: Vector3): string | null {
    const u = local.x / (this.half.x * 2) + 0.5
    const v = 0.5 - local.y / (this.half.y * 2)
    if (u < 0 || u > 1 || v < 0 || v > 1) return null
    const px = u * W
    const py = v * this.height
    for (const b of this.buttons) {
      const [x, y, w, h] = this.rect(b)
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

  draw(content: HudContent): void {
    const c = this.ctx
    const H = this.height
    c.clearRect(0, 0, W, H)
    c.fillStyle = 'rgba(6, 8, 14, 0.88)'
    roundRect(c, 0, 0, W, H, 18)
    c.fill()
    c.strokeStyle = 'rgba(127, 211, 255, 0.30)'
    c.lineWidth = 2
    roundRect(c, 1, 1, W - 2, H - 2, 18)
    c.stroke()

    c.textBaseline = 'top'
    c.font = '600 34px ui-monospace, Menlo, monospace'
    c.fillStyle = '#e6ecf7'
    c.fillText(content.headline, PAD + 6, 18)
    if (content.metric) {
      c.fillStyle = content.metricOk === false ? '#e2606a' : '#7dd87d'
      c.fillText(content.metric, 400, 18)
    }
    if (content.sub) {
      c.fillStyle = '#9fb0c8'
      c.font = '500 26px ui-monospace, Menlo, monospace'
      c.fillText(content.sub, 400, 60)
    }

    c.font = '500 26px ui-monospace, Menlo, monospace'
    c.fillStyle = '#9fb0c8'
    content.lines.slice(0, 3).forEach((t, i) => c.fillText(t, PAD + 6, 106 + i * 38))

    if (content.progress) {
      // say so, or a busy few seconds just reads as the app hanging
      c.fillStyle = '#e2c766'
      c.font = '600 21px ui-monospace, Menlo, monospace'
      c.fillText(content.progress.label, PAD + 6, 222)
      c.fillStyle = 'rgba(226,199,102,0.85)'
      c.fillRect(PAD + 330, 226, (W - PAD * 2 - 340) * content.progress.frac, 8)
    } else {
      c.fillStyle = '#5d6a80'
      c.font = '500 21px ui-monospace, Menlo, monospace'
      c.fillText(content.footer, PAD + 6, 222)
    }

    const now = performance.now()
    for (const b of this.buttons) {
      const [x, y, w, h] = this.rect(b)
      const lit = now - (this.flash.get(b.id) ?? -1e9) < 180 || content.lit?.(b.id) === true
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
      c.font = '600 22px ui-monospace, Menlo, monospace'
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
