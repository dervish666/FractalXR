/**
 * OFFLINE icon/art renderer (dev-only — reached via /icon.html in `npm run art`).
 *
 * Same engine and the same straight-alpha trick as bake.ts, but it renders ONE preset per file at
 * icon resolution instead of a 256px atlas cell, so the result survives being blown up to a 432px
 * adaptive launcher icon or a store card. Files are POSTed to /save-art and land in
 * godot/art/candidates/ (gitignored — they are inputs to tools/make_icons.py, not artefacts).
 *
 * Pick candidates with ?names=Nautilus,Glacier,Starflower (flame or bulb names, case-insensitive).
 */
import {
  WebGLRenderer,
  PerspectiveCamera,
  Scene,
  Group,
  Vector3,
  WebGLRenderTarget,
  RGBAFormat,
  UnsignedByteType,
  NearestFilter,
} from 'three'
import { GALLERY } from '../flame/presets'
import { BULB_GALLERY } from '../flame/bulbs'
import { encodeFlame } from '../flame/encode'
import { Palette } from '../flame/palette'
import { Simulation } from '../engine/Simulation'
import { FlamePoints } from '../engine/FlamePoints'
import { Compositor } from '../engine/Compositor'
import type { FlameGenome } from '../flame/types'
import type { BulbGenome } from '../flame/bulbs'

// --- tunables ---------------------------------------------------------------
const OUT = 1024 // saved PNG edge (icons crop from this; 432 adaptive upscales from nothing)
const RENDER = 1536 // offscreen render edge — 2× supersample down into OUT, same as the atlas bake
const SIZE = 1024 // sim grid → 1,048,576 particles (an icon can afford the density)
const FLAME_FRAMES = 420 // settle longer than the atlas: no shimmer, and the faint arms fill in
const BULB_FRAMES = 220
const FLAME_SCALE = 0.26 // smaller than the atlas: nothing may touch the frame, the crop zooms back in
const BULB_FILL = 1.15
const CAM_DIST = 1.6
const VIEW_ROT_X = -0.33
const VIEW_ROT_Y = 0.52
const ALPHA_LO = 0.04
const ALPHA_HI = 0.45
const VIG_INNER = 0.9 // barely-there border feather: an icon wants its own margin, not a vignette
const BULB_TONE = { exposure: 0.34, gamma: 2.4, k2: 55, hiDesat: 0.3 }

type Item = { kind: 'flame'; g: FlameGenome } | { kind: 'bulb'; b: BulbGenome }
const ALL: Item[] = [
  ...GALLERY.map((g) => ({ kind: 'flame' as const, g })),
  ...BULB_GALLERY.map((b) => ({ kind: 'bulb' as const, b })),
]
const nameOf = (it: Item): string => (it.kind === 'flame' ? it.g.name : it.b.name)

const params = new URLSearchParams(location.search)
const wanted = (params.get('names') ?? '').split(',').map((s) => s.trim().toLowerCase()).filter(Boolean)
const items = wanted.length ? ALL.filter((it) => wanted.includes(nameOf(it).toLowerCase())) : ALL

const status = document.getElementById('status') as HTMLDivElement
const setStatus = (s: string): void => {
  status.textContent = s
}

// --- engine (mirrors bake.ts, one tile at a time) ---------------------------
const renderer = new WebGLRenderer({ antialias: false, powerPreference: 'high-performance' })
renderer.setSize(RENDER, RENDER)
renderer.setClearColor(0x000000, 1)

const palette = new Palette(GALLERY[0].palette)
const sim = new Simulation(SIZE)
sim.setParams({ iterations: 6, reseedProb: 0.0015 })

const flamePoints = new FlamePoints(SIZE, palette.texture, GALLERY[0].pointBrightness)
flamePoints.setActiveCount(SIZE * SIZE)
flamePoints.setPointSize(2.4 * (RENDER / 512)) // keep the atlas look at 4× the pixels

const group = new Group()
group.position.set(0, 0, -CAM_DIST)
group.rotation.set(VIEW_ROT_X, VIEW_ROT_Y, 0)
group.add(flamePoints.points)
const scene = new Scene()
scene.add(group)

const compositor = new Compositor({
  exposure: GALLERY[0].brightness,
  gamma: GALLERY[0].gamma,
  k2: GALLERY[0].k2,
  hiDesat: GALLERY[0].highlightDesat,
})
compositor.ensureSize(RENDER, RENDER, 1)

const cam = new PerspectiveCamera(60, 1, 0.05, 200)
cam.position.set(0, 0, 0)
cam.lookAt(0, 0, -1)

const ldr = new WebGLRenderTarget(RENDER, RENDER, {
  format: RGBAFormat,
  type: UnsignedByteType,
  depthBuffer: false,
  stencilBuffer: false,
  minFilter: NearestFilter,
  magFilter: NearestFilter,
})

const tile = document.createElement('canvas')
tile.width = OUT
tile.height = OUT
const octx = tile.getContext('2d')!

const tmp = document.createElement('canvas')
tmp.width = RENDER
tmp.height = RENDER
const tctx = tmp.getContext('2d', { willReadFrequently: true })!

let frame = 0

function setFlame(g: FlameGenome): void {
  sim.setMode('flame')
  sim.setGenome(encodeFlame(g))
  palette.setColors(g.palette)
  flamePoints.setBrightness(g.pointBrightness)
  compositor.setToneParams({ exposure: g.brightness, gamma: g.gamma, k2: g.k2, hiDesat: g.highlightDesat })
  group.scale.setScalar(FLAME_SCALE)
}

function setBulb(b: BulbGenome): void {
  sim.setMode('bulb')
  palette.setColors(b.palette)
  flamePoints.setBrightness(1.0)
  compositor.setToneParams(BULB_TONE)
  sim.setBulbParams({
    formula: b.formula,
    power: b.power,
    juliaC: new Vector3(b.juliaC[0], b.juliaC[1], b.juliaC[2]),
    mandelbulb: b.mandelbulb,
    scale: b.scale,
    minR: b.minR,
    fixedR: b.fixedR,
    bound: b.bound,
    kAngleA: b.kAngleA,
    kAngleB: b.kAngleB,
    projSteps: 4,
    jitter: 0.0022,
    reseedProb: 0.02,
  })
  group.scale.setScalar((0.65 / b.bound) * BULB_FILL)
}

function renderOneFrame(): void {
  sim.update(renderer, frame++)
  flamePoints.setStateTexture(sim.stateTexture)
  renderer.setRenderTarget(compositor.hdrRT)
  renderer.clear(true, true, true)
  renderer.autoClear = false
  renderer.render(scene, cam)
  renderer.autoClear = true
  compositor.tonemap(renderer, ldr)
}

function blit(): void {
  const buf = new Uint8Array(RENDER * RENDER * 4)
  renderer.readRenderTargetPixels(ldr, 0, 0, RENDER, RENDER, buf)
  for (let p = 0; p < buf.length; p += 4) {
    const idx = p >> 2
    const nx = ((idx % RENDER) / (RENDER - 1)) * 2 - 1
    const ny = (((idx / RENDER) | 0) / (RENDER - 1)) * 2 - 1
    const vt = Math.min(1, Math.max(0, (Math.max(Math.abs(nx), Math.abs(ny)) - VIG_INNER) / (1 - VIG_INNER)))
    const vig = 1 - vt * vt * (3 - 2 * vt)
    const m = Math.max(buf[p], buf[p + 1], buf[p + 2]) / 255
    const t = Math.min(1, Math.max(0, (m - ALPHA_LO) / (ALPHA_HI - ALPHA_LO)))
    buf[p + 3] = Math.round(t * t * (3 - 2 * t) * vig * 255)
  }
  tctx.clearRect(0, 0, RENDER, RENDER)
  tctx.putImageData(new ImageData(new Uint8ClampedArray(buf), RENDER, RENDER), 0, 0)
  octx.clearRect(0, 0, OUT, OUT)
  octx.save()
  octx.scale(OUT / RENDER, OUT / RENDER)
  octx.translate(0, RENDER)
  octx.scale(1, -1) // GL reads bottom-up
  octx.drawImage(tmp, 0, 0)
  octx.restore()
}

// setTimeout, not requestAnimationFrame: Chrome pauses rAF entirely in a hidden tab, and this
// page is usually rendering in the background while something else has focus.
const sleep = (): Promise<void> => new Promise((r) => setTimeout(r, 0))
const slug = (s: string): string => s.toLowerCase().replace(/[^a-z0-9]+/g, '-')

async function save(name: string): Promise<boolean> {
  const blob: Blob | null = await new Promise((r) => tile.toBlob(r, 'image/png'))
  if (!blob) return false
  const r = await fetch(`/save-art?name=${encodeURIComponent(slug(name))}`, { method: 'POST', body: blob })
  return r.ok
}

async function run(): Promise<void> {
  const btn = document.getElementById('go') as HTMLButtonElement
  btn.disabled = true
  const preview = document.getElementById('preview') as HTMLDivElement
  for (let k = 0; k < items.length; k++) {
    const it = items[k]
    const name = nameOf(it)
    setStatus(`Rendering ${k + 1}/${items.length} — ${name} (${it.kind})…`)
    await sleep()
    if (it.kind === 'flame') setFlame(it.g)
    else setBulb(it.b)
    sim.seed(renderer)
    const frames = it.kind === 'flame' ? FLAME_FRAMES : BULB_FRAMES
    for (let f = 0; f < frames; f++) renderOneFrame()
    blit()
    const ok = await save(name)
    const img = new Image()
    img.src = tile.toDataURL('image/png')
    img.width = 180
    img.title = name
    preview.appendChild(img)
    if (!ok) setStatus(`Save failed for ${name} — is this served by \`npm run art\`?`)
  }
  setStatus(`Done — ${items.length} file(s) in godot/art/candidates/.`)
  ;(window as unknown as { artDone: boolean }).artDone = true
  btn.disabled = false
}

document.getElementById('go')!.addEventListener('click', () => {
  run().catch((e) => setStatus(`Error: ${(e as Error).message}`))
})
setStatus(`Ready — ${items.length} item(s): ${items.map(nameOf).join(', ')}`)
