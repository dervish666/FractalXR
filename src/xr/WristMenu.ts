import {
  CanvasTexture,
  Group,
  LinearFilter,
  Mesh,
  MeshBasicMaterial,
  PlaneGeometry,
  MathUtils,
  Raycaster,
  type Object3D,
  type Vector3,
} from 'three'

type Vec3 = [number, number, number]

export interface MenuState {
  name: string
  mode: string // 'FLAME' | 'BULB' — shown on the MODE cell
  morphing: boolean
  auto: boolean
  passthrough: boolean // MR/passthrough toggle state (room visible behind the flame)
  arAvailable: boolean // true only inside an immersive-ar session; gates the passthrough cell
  accent: Vec3 // current flame accent (0..1 rgb)
  currentPreset: number // index in gallery, or -1 if a bred flame
  particles: string // formatted current values for the settings cells
  size: string
  morph: string
  animation: string
  saved: string
  faves: string
  perf: string // live fps / particle-load / foveation readout
}

export interface MenuActions {
  randomize: () => void
  mutateCurrent: () => void
  breed: () => void
  toggleMode: () => void
  toggleAuto: () => void
  recolor: () => void
  morphToPreset: (i: number) => void
  morphToBulbPreset: (i: number) => void // bulb-gallery chip (shown only in bulb mode)
  saveFavorite: () => void
  loadFave: () => void
  deleteFave: () => void
  cycleParticles: () => void
  cycleSize: () => void
  cycleMorph: () => void
  cycleAnimation: () => void
  togglePassthrough: () => void
  showGuide: () => void
  exitVR: () => void
}

interface Cell {
  label: string
  sub?: string
  kind: 'action' | 'toggle' | 'stub' | 'preset' | 'setting' | 'exit'
  run: () => void
  presetIdx?: number
  valueKey?: 'particles' | 'size' | 'morph' | 'animation' | 'saved' | 'faves' | 'mode' // dynamic value
  toggleKey?: 'auto' | 'passthrough' // which MenuState bool drives the ON/OFF capsule
  rect: [number, number, number, number] // x,y,w,h in canvas px
}

const W = 1024
const H = 760

/** Left-wrist "Glass Slate" menu. Thumbstick moves a cursor over a fixed grid;
 * stick-click expands / commits. Renders as one CanvasTexture quad, child of the
 * off-hand controller, so it tracks the hand and composites in the overlay pass. */
export class WristMenu {
  readonly root = new Group()
  private panel: Mesh
  private sliver: Mesh
  private panelCanvas = document.createElement('canvas')
  private sliverCanvas = document.createElement('canvas')
  private panelTex: CanvasTexture
  private sliverTex: CanvasTexture
  private rows: Cell[][] = []
  private h = H // panel canvas height — recomputed by buildGrid to fit the preset rows
  private cursor = { r: 0, c: 0 }
  private open = false
  private openAmount = 0
  private lastSnapshot = ''
  private lastSliverSnapshot = ''
  private raycaster = new Raycaster()
  private _hovered = false
  private _hitDist = 0
  // retained so the grid can be rebuilt when the mode changes (flame ⇄ bulb)
  private actions: MenuActions
  private flamePresets: string[]
  private bulbPresets: string[]
  private mode: string

  constructor(
    offHand: Object3D,
    private getState: () => MenuState,
    actions: MenuActions,
    private isFlyThrough: () => boolean,
    presetNames: string[],
    bulbPresetNames: string[],
  ) {
    this.actions = actions
    this.flamePresets = presetNames
    this.bulbPresets = bulbPresetNames
    this.mode = getState().mode
    this.buildGrid(actions, this.mode)

    this.panelCanvas.width = W
    this.panelCanvas.height = this.h
    this.panelTex = new CanvasTexture(this.panelCanvas)
    this.panelTex.minFilter = LinearFilter
    const panelMat = new MeshBasicMaterial({
      map: this.panelTex,
      transparent: true,
      depthWrite: false,
      polygonOffset: true,
      polygonOffsetFactor: -1,
    })
    this.panel = new Mesh(new PlaneGeometry(0.17, 0.17 * (this.h / W)), panelMat)

    this.sliverCanvas.width = 512
    this.sliverCanvas.height = 128
    this.sliverTex = new CanvasTexture(this.sliverCanvas)
    this.sliverTex.minFilter = LinearFilter
    const sliverMat = new MeshBasicMaterial({ map: this.sliverTex, transparent: true, depthWrite: false })
    this.sliver = new Mesh(new PlaneGeometry(0.1, 0.1 * (128 / 512)), sliverMat)

    this.root.add(this.panel, this.sliver)
    this.root.position.set(0, 0.045, 0.06)
    this.root.rotation.set(MathUtils.degToRad(-50), MathUtils.degToRad(10), 0)
    offHand.add(this.root)

    this.redrawSliver(this.getState())
    this.redrawPanel(this.getState())
  }

  private buildGrid(a: MenuActions, mode: string): void {
    const bulb = mode === 'BULB'
    const presetNames = bulb ? this.bulbPresets : this.flamePresets
    const m = 36
    const gap = 20
    const stripBottom = 150
    // mode toggle + breeding row (4 cells)
    const r0y = stripBottom + 24
    const r0h = 130
    const cwb = (W - 2 * m - 3 * gap) / 4
    const bx = (i: number): number => m + i * (cwb + gap)
    const breeding: Cell[] = [
      { label: 'MODE', kind: 'action', valueKey: 'mode', run: a.toggleMode, rect: [bx(0), r0y, cwb, r0h] },
      { label: 'RANDOMIZE', sub: 'R-trig', kind: 'action', run: a.randomize, rect: [bx(1), r0y, cwb, r0h] },
      { label: 'MUTATE', sub: 'L-trig', kind: 'action', run: a.mutateCurrent, rect: [bx(2), r0y, cwb, r0h] },
      // in bulb mode "breed" flips Mandelbulb ⇄ Juliabulb, so relabel it
      bulb
        ? { label: 'FLIP', sub: 'kind', kind: 'action', run: a.breed, rect: [bx(3), r0y, cwb, r0h] }
        : { label: 'CROSS-BREED', sub: 'B btn', kind: 'action', run: a.breed, rect: [bx(3), r0y, cwb, r0h] },
    ]
    // auto / recolor / [save / faves / delete — flame only] / passthrough row
    const r1y = r0y + r0h + gap
    const r1h = 120
    const cw4 = (W - 2 * m - 5 * gap) / 6
    const mx = (i: number): number => m + i * (cw4 + gap)
    const middle: Cell[] = [
      { label: 'AUTO', kind: 'toggle', toggleKey: 'auto', run: a.toggleAuto, rect: [mx(0), r1y, cw4, r1h] },
      { label: 'RECOLOR', sub: 'theme', kind: 'action', run: a.recolor, rect: [mx(1), r1y, cw4, r1h] },
      // favourites store flame genomes — hide them in bulb mode (keep PASSTHRU in its slot)
      ...(bulb
        ? []
        : [
            { label: 'SAVE', kind: 'action' as const, valueKey: 'saved' as const, run: a.saveFavorite, rect: [mx(2), r1y, cw4, r1h] as [number, number, number, number] },
            { label: 'FAVES', kind: 'action' as const, valueKey: 'faves' as const, run: a.loadFave, rect: [mx(3), r1y, cw4, r1h] as [number, number, number, number] },
            { label: 'DELETE', sub: 'fave', kind: 'action' as const, run: a.deleteFave, rect: [mx(4), r1y, cw4, r1h] as [number, number, number, number] },
          ]),
      { label: 'PASSTHRU', kind: 'toggle', toggleKey: 'passthrough', run: a.togglePassthrough, rect: [mx(5), r1y, cw4, r1h] },
    ]
    // preset chips — bulb gallery in bulb mode, flame gallery otherwise; wrap into up to two rows
    const presetAction = bulb ? a.morphToBulbPreset : a.morphToPreset
    const r2y = r1y + r1h + gap
    const r2h = 92
    const cgap = 12
    const n = Math.max(1, presetNames.length)
    const presetRowCount = n > 8 ? 2 : 1
    const perRow = Math.ceil(n / presetRowCount)
    const cwN = (W - 2 * m - (perRow - 1) * cgap) / perRow
    const presetRows: Cell[][] = Array.from({ length: presetRowCount }, () => [] as Cell[])
    presetNames.forEach((name, i) => {
      const row = Math.floor(i / perRow)
      const col = i % perRow
      const inThisRow = Math.min(perRow, n - row * perRow) // last row may be short → centre it
      const rowW = inThisRow * cwN + (inThisRow - 1) * cgap
      const x0 = (W - rowW) / 2
      presetRows[row].push({
        label: name,
        kind: 'preset',
        presetIdx: i,
        run: () => presetAction(i),
        rect: [x0 + col * (cwN + cgap), r2y + row * (r2h + cgap), cwN, r2h] as [number, number, number, number],
      })
    })
    // settings row — value cyclers (click to step) + Exit VR — below the preset rows
    const r3y = r2y + presetRowCount * r2h + (presetRowCount - 1) * cgap + gap
    const r3h = 104
    const sgap = 12
    const sw = (W - 2 * m - 5 * sgap) / 6
    const sx = (i: number): number => m + i * (sw + sgap)
    const settings: Cell[] = [
      { label: 'PARTICLES', kind: 'setting', valueKey: 'particles', run: a.cycleParticles, rect: [sx(0), r3y, sw, r3h] },
      { label: 'SIZE', kind: 'setting', valueKey: 'size', run: a.cycleSize, rect: [sx(1), r3y, sw, r3h] },
      { label: 'MORPH', kind: 'setting', valueKey: 'morph', run: a.cycleMorph, rect: [sx(2), r3y, sw, r3h] },
      { label: 'SPIN', kind: 'setting', valueKey: 'animation', run: a.cycleAnimation, rect: [sx(3), r3y, sw, r3h] },
      { label: 'HELP', sub: 'controls', kind: 'action', run: a.showGuide, rect: [sx(4), r3y, sw, r3h] },
      { label: 'EXIT VR', kind: 'exit', run: a.exitVR, rect: [sx(5), r3y, sw, r3h] },
    ]
    this.h = r3y + r3h + 28 // panel height fits the actual content (1 or 2 preset rows)
    this.rows = [breeding, middle, ...presetRows, settings]
  }

  // ---- input (called from main's button poll) -----------------------------

  get isOpen(): boolean {
    return this.open
  }

  /** Move the slate onto a different controller (used to pin it to the left hand). */
  attachTo(parent: Object3D): void {
    parent.add(this.root)
  }

  expand(): void {
    this.open = true
  }

  collapse(): void {
    this.open = false
  }

  moveCursor(dx: number, dy: number): void {
    if (!this.open) return
    this.cursor.r = clampInt(this.cursor.r + dy, 0, this.rows.length - 1)
    this.cursor.c = clampInt(this.cursor.c + dx, 0, this.rows[this.cursor.r].length - 1)
  }

  /** Stick-click / trigger-while-hovering: open if collapsed, else run highlighted cell. */
  click(): void {
    if (!this.open) {
      this.open = true
      return
    }
    this.rows[this.cursor.r][this.cursor.c].run()
  }

  get hovered(): boolean {
    return this._hovered
  }

  get hitDistance(): number {
    return this._hitDist
  }

  /** Raycast a controller ray against the menu. If it hits a button, move the cursor
   * there (so trigger/click commits it) and report a hover. Tests the sliver when
   * collapsed (so pointing at the wrist + trigger opens the menu). */
  pointerTest(origin: Vector3, dir: Vector3): boolean {
    const target = this.open ? this.panel : this.sliver
    if (!target.visible) {
      this._hovered = false
      return false
    }
    this.raycaster.set(origin, dir)
    const hits = this.raycaster.intersectObject(target, false)
    if (hits.length === 0) {
      this._hovered = false
      return false
    }
    this._hitDist = hits[0].distance
    if (!this.open) {
      this._hovered = true // sliver: anywhere on it = "expand"
      return true
    }
    const uv = hits[0].uv
    if (uv) {
      const px = uv.x * W
      const py = (1 - uv.y) * this.h
      for (let r = 0; r < this.rows.length; r++) {
        for (let c = 0; c < this.rows[r].length; c++) {
          const [x, y, w, h] = this.rows[r][c].rect
          if (px >= x && px <= x + w && py >= y && py <= y + h) {
            this.cursor.r = r
            this.cursor.c = c
            this._hovered = true
            return true
          }
        }
      }
    }
    this._hovered = false // on the panel but not on a button
    return false
  }

  // ---- per-frame ----------------------------------------------------------

  /** Rebuild the grid for the current mode (flame ⇄ bulb) — different preset gallery,
   * and favourites are hidden in bulb mode. Cheap; only runs on an actual mode change. */
  private rebuildForMode(): void {
    const prevH = this.h
    this.buildGrid(this.actions, this.mode)
    if (this.h !== prevH) {
      this.panelCanvas.height = this.h
      this.panel.geometry.dispose()
      this.panel.geometry = new PlaneGeometry(0.17, 0.17 * (this.h / W))
    }
    // the new grid may have fewer rows/cells — keep the cursor in bounds
    this.cursor.r = clampInt(this.cursor.r, 0, this.rows.length - 1)
    this.cursor.c = clampInt(this.cursor.c, 0, this.rows[this.cursor.r].length - 1)
    this.lastSnapshot = '' // force a panel redraw
  }

  update(dt: number): void {
    this.root.visible = true
    const st = this.getState()
    if (st.mode !== this.mode) {
      this.mode = st.mode
      this.rebuildForMode()
    }
    // force-collapse while two-hand fly-through scaling
    const target = this.isFlyThrough() ? false : this.open
    if (!target) this.open = false

    this.openAmount = approach(this.openAmount, this.open ? 1 : 0, dt * 8)
    const showPanel = this.openAmount > 0.02
    this.panel.visible = showPanel
    this.sliver.visible = this.openAmount < 0.98
    const s = 0.85 + 0.15 * this.openAmount
    this.panel.scale.setScalar(s)
    ;(this.panel.material as MeshBasicMaterial).opacity = this.openAmount
    ;(this.sliver.material as MeshBasicMaterial).opacity = 1 - this.openAmount

    const sliverSnap = `${st.name}|${st.auto}`
    if (sliverSnap !== this.lastSliverSnapshot) {
      this.lastSliverSnapshot = sliverSnap
      this.redrawSliver(st)
    }
    if (showPanel) {
      const snap = `${st.name}|${st.mode}|${st.morphing}|${st.auto}|${st.passthrough}|${st.arAvailable}|${st.currentPreset}|${this.cursor.r},${this.cursor.c}|${st.accent.join(',')}|${st.particles}|${st.size}|${st.morph}|${st.animation}|${st.saved}|${st.faves}|${st.perf}`
      if (snap !== this.lastSnapshot) {
        this.lastSnapshot = snap
        this.redrawPanel(st)
      }
    }
  }

  // ---- drawing ------------------------------------------------------------

  private redrawSliver(st: MenuState): void {
    const ctx = this.sliverCanvas.getContext('2d')!
    ctx.clearRect(0, 0, 512, 128)
    roundRect(ctx, 6, 6, 500, 116, 58)
    ctx.fillStyle = 'rgba(10,14,22,0.8)'
    ctx.fill()
    ctx.lineWidth = 2
    ctx.strokeStyle = 'rgba(136,170,255,0.4)'
    ctx.stroke()
    ctx.fillStyle = '#cfd8ff'
    ctx.font = '500 52px ui-sans-serif, system-ui, sans-serif'
    ctx.textAlign = 'center'
    ctx.textBaseline = 'middle'
    ctx.fillText(`${st.name}${st.auto ? '  ▶' : ''}`, 256, 66)
    this.sliverTex.needsUpdate = true
  }

  private redrawPanel(st: MenuState): void {
    const ctx = this.panelCanvas.getContext('2d')!
    const accent = accentCss(st.accent)
    ctx.clearRect(0, 0, W, this.h)

    // backing
    roundRect(ctx, 8, 8, W - 16, this.h - 16, 40)
    ctx.fillStyle = 'rgba(10,14,22,0.9)'
    ctx.fill()
    ctx.lineWidth = 3
    ctx.strokeStyle = 'rgba(136,170,255,0.5)'
    ctx.stroke()

    // name + status strip
    ctx.textBaseline = 'middle'
    ctx.textAlign = 'left'
    ctx.fillStyle = '#eef2ff'
    ctx.font = '600 60px ui-sans-serif, system-ui, sans-serif'
    ctx.fillText(st.name, 44, 86)
    ctx.textAlign = 'right'
    ctx.font = '500 38px ui-sans-serif, system-ui, sans-serif'
    ctx.fillStyle = st.auto ? accent : st.morphing ? 'rgba(180,200,255,0.85)' : 'rgba(150,165,200,0.6)'
    ctx.fillText(st.auto ? '▶ auto' : st.morphing ? '… morphing' : 'idle', W - 44, 86)
    // live headroom readout: fps · drawn/ceiling particles · foveation
    ctx.font = '500 26px ui-sans-serif, system-ui, sans-serif'
    ctx.fillStyle = 'rgba(150,165,200,0.7)'
    ctx.fillText(st.perf, W - 44, 124)
    ctx.strokeStyle = 'rgba(136,170,255,0.25)'
    ctx.lineWidth = 2
    ctx.beginPath()
    ctx.moveTo(44, 150)
    ctx.lineTo(W - 44, 150)
    ctx.stroke()

    // cells
    for (let r = 0; r < this.rows.length; r++) {
      for (let c = 0; c < this.rows[r].length; c++) {
        const cell = this.rows[r][c]
        const hot = this.cursor.r === r && this.cursor.c === c
        this.drawCell(ctx, cell, hot, accent, st)
      }
    }

    this.panelTex.needsUpdate = true
  }

  private drawCell(ctx: CanvasRenderingContext2D, cell: Cell, hot: boolean, accent: string, st: MenuState): void {
    const [x, y, w, h] = cell.rect
    const isCurrentPreset = cell.kind === 'preset' && st.currentPreset === cell.presetIdx
    const dim = cell.kind === 'stub'
    const isExit = cell.kind === 'exit'

    roundRect(ctx, x, y, w, h, 16)
    ctx.fillStyle = hot
      ? isExit
        ? 'rgba(255,90,90,0.3)'
        : accentFill(st.accent, 0.32)
      : isCurrentPreset
        ? accentFill(st.accent, 0.16)
        : 'rgba(255,255,255,0.05)'
    ctx.fill()
    ctx.lineWidth = hot ? 5 : 2
    ctx.strokeStyle = hot ? (isExit ? '#ff6a6a' : accent) : isExit ? 'rgba(255,120,120,0.5)' : isCurrentPreset ? accent : 'rgba(136,170,255,0.3)'
    ctx.stroke()

    ctx.textAlign = 'center'
    ctx.textBaseline = 'middle'
    const cx = x + w / 2
    const cy = y + h / 2

    if (cell.kind === 'setting') {
      ctx.fillStyle = 'rgba(170,185,220,0.8)'
      ctx.font = '600 26px ui-sans-serif, system-ui, sans-serif'
      ctx.fillText(cell.label, cx, cy - 22)
      ctx.fillStyle = accent
      ctx.font = '700 38px ui-sans-serif, system-ui, sans-serif'
      const val = cell.valueKey ? st[cell.valueKey] : ''
      ctx.fillText(val, cx, cy + 22)
      return
    }

    if (isExit) {
      ctx.fillStyle = '#ffb3b3'
      ctx.font = '600 30px ui-sans-serif, system-ui, sans-serif'
      ctx.fillText('⎋ EXIT VR', cx, cy)
      return
    }

    if (cell.kind === 'toggle') {
      const on = cell.toggleKey === 'passthrough' ? st.passthrough : st.auto
      // the passthrough toggle is inert outside an immersive-ar session — dim it there
      const inert = cell.toggleKey === 'passthrough' && !st.arAvailable
      ctx.fillStyle = dim || inert ? 'rgba(200,210,240,0.4)' : '#eef2ff'
      ctx.font = `600 ${cell.label.length > 5 ? 30 : 40}px ui-sans-serif, system-ui, sans-serif`
      ctx.fillText(cell.label, cx, cy - 24)
      // ON/OFF capsule
      const cwid = 120
      const chx = cx - cwid / 2
      roundRect(ctx, chx, cy + 8, cwid, 44, 22)
      ctx.fillStyle = on ? accent : 'rgba(255,255,255,0.08)'
      ctx.fill()
      ctx.fillStyle = on ? '#0a0e16' : 'rgba(200,210,240,0.7)'
      ctx.font = '700 28px ui-sans-serif, system-ui, sans-serif'
      ctx.fillText(on ? 'ON' : 'OFF', cx, cy + 31)
      return
    }

    const subText = cell.valueKey ? st[cell.valueKey] : cell.sub
    ctx.fillStyle = dim ? 'rgba(200,210,240,0.4)' : '#eef2ff'
    ctx.font = `600 ${cell.kind === 'preset' ? 24 : 36}px ui-sans-serif, system-ui, sans-serif`
    ctx.fillText(cell.label, cx, subText ? cy - 16 : cy)
    if (subText) {
      ctx.font = '400 26px ui-sans-serif, system-ui, sans-serif'
      ctx.fillStyle = cell.valueKey ? accent : 'rgba(150,165,200,0.65)'
      ctx.fillText(subText, cx, cy + 30)
    }
  }
}

function clampInt(v: number, lo: number, hi: number): number {
  return v < lo ? lo : v > hi ? hi : v
}
function approach(v: number, target: number, rate: number): number {
  const a = Math.min(1, Math.max(0, rate))
  return v + (target - v) * a
}
function roundRect(ctx: CanvasRenderingContext2D, x: number, y: number, w: number, h: number, r: number): void {
  ctx.beginPath()
  ctx.roundRect(x, y, w, h, r)
}
function accentCss(a: Vec3): string {
  return `rgb(${(a[0] * 255) | 0},${(a[1] * 255) | 0},${(a[2] * 255) | 0})`
}
function accentFill(a: Vec3, alpha: number): string {
  return `rgba(${(a[0] * 255) | 0},${(a[1] * 255) | 0},${(a[2] * 255) | 0},${alpha})`
}
