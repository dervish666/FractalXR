import {
  Group,
  Mesh,
  MeshBasicMaterial,
  PlaneGeometry,
  Raycaster,
  Vector3,
  type Camera,
  type Texture,
} from 'three'

export interface DomeTile {
  mode: 'flame' | 'bulb'
  index: number // index into GALLERY (flame) or BULB_GALLERY (bulb)
  name: string
}

const COLS = 6 // atlas columns — MUST match src/bake/bake.ts

/**
 * A planetarium of pre-baked variation stills. The tiles ring the user on a sphere band
 * (full 360°, elevation clamped to a comfortable cone); each billboards to face the head.
 * Point the laser at one + trigger to pick it — main.ts then morphs the live fractal to that
 * preset, fades the dome out, and zooms in. Stills come from an offline atlas (bake.html), so
 * there is exactly ONE live cloud; the dome is just textures.
 *
 * Lives in `overlayScene` (drawn after the flame tone-map), depthTest off + high renderOrder, so
 * it reads over both the VR-opaque and MR-passthrough composites — same idiom as ControlsGuide.
 */
export class DomeGallery {
  readonly root = new Group()
  private tiles: { mesh: Mesh; mat: MeshBasicMaterial; data: DomeTile; opacity: number; scale: number }[] = []
  private meshes: Mesh[] = []
  private raycaster = new Raycaster()
  private _open = false
  private openAmount = 0
  private _hoverIdx = -1
  private _hitDist = 0
  private justOpened = false
  private center = new Vector3()

  constructor(
    tiles: DomeTile[],
    radius = 2.4,
    tileSize = 0.36,
    minElevDeg = -26,
    maxElevDeg = 46,
  ) {
    const n = tiles.length
    const rows = Math.ceil(n / COLS)
    const minEl = (minElevDeg * Math.PI) / 180
    const maxEl = (maxElevDeg * Math.PI) / 180
    const GOLDEN = Math.PI * (3 - Math.sqrt(5)) // golden-angle azimuth step → organic, even spread

    for (let i = 0; i < n; i++) {
      // fibonacci-sphere distribution with the elevation compressed into a comfortable band
      // (nothing directly overhead/underfoot) and full-360 azimuth (you turn to browse).
      const f = n === 1 ? 0.5 : i / (n - 1)
      const sinEl = Math.sin(minEl) + f * (Math.sin(maxEl) - Math.sin(minEl))
      const el = Math.asin(Math.max(-1, Math.min(1, sinEl)))
      const az = GOLDEN * i
      const cosEl = Math.cos(el)
      const dir = new Vector3(Math.sin(az) * cosEl, Math.sin(el), Math.cos(az) * cosEl)

      const geo = new PlaneGeometry(tileSize, tileSize)
      setCellUV(geo, i, rows)
      // starts as a dim placeholder panel until the atlas loads (setAtlas swaps in the texture)
      const mat = new MeshBasicMaterial({ color: 0x1b2740, transparent: true, depthTest: false, depthWrite: false, opacity: 0 })
      const mesh = new Mesh(geo, mat)
      mesh.position.copy(dir.multiplyScalar(radius))
      mesh.renderOrder = 998 // just under the wrist menu / guide (999) so the menu always wins
      mesh.visible = false
      this.root.add(mesh)
      this.tiles.push({ mesh, mat, data: tiles[i], opacity: 0, scale: 1 })
      this.meshes.push(mesh)
    }
  }

  /** Swap the dim placeholders for the baked thumbnail atlas (each tile samples its own cell). */
  setAtlas(tex: Texture): void {
    for (const t of this.tiles) {
      t.mat.map = tex
      t.mat.color.setHex(0xffffff) // stop tinting once a real image is on the quad
      t.mat.needsUpdate = true
    }
  }

  get open(): boolean {
    return this._open
  }
  /** True while on screen or fading (so main can skip the ray-test when fully hidden). */
  get visible(): boolean {
    return this._open || this.openAmount > 0.01
  }
  /** True when the laser is on a tile (and the dome is up) — gates the trigger-select. */
  get hovered(): boolean {
    return this._open && this._hoverIdx >= 0
  }
  get hitDistance(): number {
    return this._hitDist
  }

  show(): void {
    this._open = true
    this.justOpened = true
  }
  hide(): void {
    this._open = false
    this._hoverIdx = -1
  }
  toggle(): void {
    if (this._open) this.hide()
    else this.show()
  }

  /** The tile currently under the laser, or null — for the trigger-select handler. */
  pick(): DomeTile | null {
    return this._hoverIdx >= 0 ? this.tiles[this._hoverIdx].data : null
  }

  /** Raycast the controller ray against the tiles; caches the hovered tile + its distance.
   *  Returns true if a tile is under the ray (so main can light the laser to it). */
  pointerTest(origin: Vector3, dir: Vector3): boolean {
    if (!this._open || this.openAmount < 0.4) {
      this._hoverIdx = -1
      return false
    }
    this.raycaster.set(origin, dir)
    const hits = this.raycaster.intersectObjects(this.meshes, false)
    if (hits.length === 0) {
      this._hoverIdx = -1
      return false
    }
    this._hoverIdx = this.meshes.indexOf(hits[0].object as Mesh)
    this._hitDist = hits[0].distance
    return true
  }

  /** Ease the fade, anchor the dome (captured at open so you can lean/turn within it), and
   *  billboard every tile to face the user. `center` is the head (VR) or the flame (desktop). */
  update(dt: number, camera: Camera, center: Vector3): void {
    this.openAmount = approach(this.openAmount, this._open ? 1 : 0, dt * 5)
    const vis = this.openAmount > 0.01
    this.root.visible = vis
    if (!vis) {
      for (const t of this.tiles) t.mesh.visible = false
      return
    }

    if (this.justOpened) {
      this.center.copy(center) // anchor in the room where the user opened it
      this.justOpened = false
    }
    this.root.position.copy(this.center)

    _camPos.setFromMatrixPosition(camera.matrixWorld)
    const anyHover = this._hoverIdx >= 0
    for (let i = 0; i < this.tiles.length; i++) {
      const t = this.tiles[i]
      t.mesh.visible = true
      t.mesh.lookAt(_camPos) // face the user (plane front is +Z; lookAt points +Z at the head)
      // hovered tile reads bright; the rest dim so the focus pops
      const targetO = this.openAmount * (this._hoverIdx === i ? 1 : anyHover ? 0.5 : 0.92)
      t.opacity = approach(t.opacity, targetO, dt * 10)
      t.mat.opacity = t.opacity
      const targetS = this._hoverIdx === i ? 1.16 : 1 // and pops forward a touch
      t.scale = approach(t.scale, targetS, dt * 12)
      t.mesh.scale.setScalar(t.scale)
    }
  }
}

const _camPos = new Vector3()

function approach(v: number, target: number, rate: number): number {
  const k = Math.min(1, Math.max(0, rate))
  return v + (target - v) * k
}

/** Remap a unit plane's UVs onto its atlas cell. Cell k fills column `k%COLS`, row `k/COLS`,
 *  with row 0 at the TOP of the atlas image (so v is inverted: texture v=1 is the top). */
function setCellUV(geo: PlaneGeometry, k: number, rows: number): void {
  const col = k % COLS
  const row = (k / COLS) | 0
  const u0 = col / COLS
  const u1 = (col + 1) / COLS
  const v1 = 1 - row / rows
  const v0 = 1 - (row + 1) / rows
  const uv = geo.getAttribute('uv')
  // PlaneGeometry UV vertex order: 0=TL, 1=TR, 2=BL, 3=BR
  uv.setXY(0, u0, v1)
  uv.setXY(1, u1, v1)
  uv.setXY(2, u0, v0)
  uv.setXY(3, u1, v0)
  uv.needsUpdate = true
}
