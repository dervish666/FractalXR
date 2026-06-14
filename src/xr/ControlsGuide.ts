import {
  CanvasTexture,
  Group,
  LinearFilter,
  Mesh,
  MeshBasicMaterial,
  PlaneGeometry,
  Quaternion,
  Vector3,
  type Camera,
} from 'three'

type Vec3 = [number, number, number]

const W = 1024
const H = 624

/**
 * A self-dismissing "what the buttons do" card. Head-locks ~1.1 m in front of the
 * user (a touch below eye-line, facing them) when a VR/MR session starts, fades out
 * after a few seconds — or the instant the user grabs / presses anything — and can be
 * re-opened from the wrist menu's HELP cell. Same Glass-Slate look as the WristMenu;
 * rides the existing overlay render pass, no new dependencies.
 */
export class ControlsGuide {
  readonly root = new Group()
  private panel: Mesh
  private canvas = document.createElement('canvas')
  private tex: CanvasTexture
  private opacity = 0
  private target = 0
  private life = 0

  constructor(private getAccent: () => Vec3) {
    this.canvas.width = W
    this.canvas.height = H
    this.tex = new CanvasTexture(this.canvas)
    this.tex.minFilter = LinearFilter
    const mat = new MeshBasicMaterial({
      map: this.tex,
      transparent: true,
      depthTest: false, // an onboarding card should always read, never be occluded by the flame
      depthWrite: false,
      opacity: 0,
    })
    this.panel = new Mesh(new PlaneGeometry(0.5, 0.5 * (H / W)), mat)
    this.panel.renderOrder = 999
    this.panel.visible = false
    this.root.add(this.panel)
    this.draw()
  }

  /** True while the card is on screen (or fading). */
  get visible(): boolean {
    return this.target > 0 || this.opacity > 0.01
  }

  /** Show the card (re-tinted to the current flame) and arm its auto-fade. */
  show(): void {
    this.draw()
    this.target = 1
    this.life = 12
    this.panel.visible = true
  }

  hide(): void {
    this.target = 0
  }

  /** Ease opacity, run the auto-fade, and head-lock the card to `camera` each frame. */
  update(dt: number, camera: Camera): void {
    this.opacity = approach(this.opacity, this.target, dt * 6)
    const mat = this.panel.material as MeshBasicMaterial
    mat.opacity = this.opacity
    const vis = this.opacity > 0.01
    this.panel.visible = vis
    if (!vis) return
    if (this.target > 0) {
      this.life -= dt
      if (this.life <= 0) this.target = 0
    }
    // 1.1 m ahead of the head, ~9 deg below eye-line, billboarded to face the user
    _q.setFromRotationMatrix(camera.matrixWorld)
    _p.setFromMatrixPosition(camera.matrixWorld)
    _fwd.set(0, 0, -1).applyQuaternion(_q)
    this.root.position.copy(_p).addScaledVector(_fwd, 1.1)
    this.root.position.y -= 0.16
    this.root.quaternion.copy(_q)
  }

  private draw(): void {
    const a = this.getAccent()
    const acc = `rgb(${(a[0] * 255) | 0},${(a[1] * 255) | 0},${(a[2] * 255) | 0})`
    const ctx = this.canvas.getContext('2d')!
    ctx.clearRect(0, 0, W, H)

    // backing slate
    roundRect(ctx, 8, 8, W - 16, H - 16, 36)
    ctx.fillStyle = 'rgba(10,14,22,0.92)'
    ctx.fill()
    ctx.lineWidth = 3
    ctx.strokeStyle = 'rgba(136,170,255,0.5)'
    ctx.stroke()

    // title strip
    ctx.textBaseline = 'middle'
    ctx.textAlign = 'left'
    ctx.fillStyle = '#eef2ff'
    ctx.font = '600 50px ui-sans-serif, system-ui, sans-serif'
    ctx.fillText('CONTROLS', 56, 74)
    ctx.textAlign = 'right'
    ctx.font = '500 28px ui-sans-serif, system-ui, sans-serif'
    ctx.fillStyle = 'rgba(150,165,200,0.7)'
    ctx.fillText('grab the flame to begin', W - 56, 78)
    ctx.strokeStyle = 'rgba(136,170,255,0.25)'
    ctx.lineWidth = 2
    ctx.beginPath()
    ctx.moveTo(56, 120)
    ctx.lineTo(W - 56, 120)
    ctx.stroke()

    // button → action rows; the three essentials are accent-tinted, the rest dim
    const rows: [string, string, boolean][] = [
      ['GRIP — squeeze either', 'Grab & move the flame', true],
      ['BOTH GRIPS — pull apart', 'Zoom / fly through it', true],
      ['☰  MENU button (left)', 'Open the menu', true],
      ['POINT + TRIGGER (right)', 'Pick a menu button', false],
      ['TRIGGER (right, in space)', 'Spawn a new flame', false],
      ['TRIGGER (left)', 'Mutate this flame', false],
    ]
    let y = 178
    for (const [btn, act, essential] of rows) {
      ctx.textAlign = 'left'
      ctx.font = `600 ${essential ? 34 : 30}px ui-sans-serif, system-ui, sans-serif`
      ctx.fillStyle = essential ? acc : 'rgba(180,195,230,0.85)'
      ctx.fillText(btn, 56, y)
      ctx.font = `500 ${essential ? 34 : 30}px ui-sans-serif, system-ui, sans-serif`
      ctx.fillStyle = essential ? '#eef2ff' : 'rgba(150,165,200,0.7)'
      ctx.fillText(act, 520, y)
      y += 64
    }

    // footer: secondary buttons + how to dismiss / reopen
    ctx.textAlign = 'center'
    ctx.font = '500 24px ui-sans-serif, system-ui, sans-serif'
    ctx.fillStyle = 'rgba(150,165,200,0.6)'
    ctx.fillText('A/X auto-generate   ·   B/Y cross-breed   ·   ☰ for menu   ·   this fades in a moment', W / 2, H - 40)

    this.tex.needsUpdate = true
  }
}

const _q = new Quaternion()
const _p = new Vector3()
const _fwd = new Vector3()

function approach(v: number, target: number, rate: number): number {
  const k = Math.min(1, Math.max(0, rate))
  return v + (target - v) * k
}
function roundRect(ctx: CanvasRenderingContext2D, x: number, y: number, w: number, h: number, r: number): void {
  ctx.beginPath()
  ctx.roundRect(x, y, w, h, r)
}
