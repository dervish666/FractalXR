/**
 * OFFLINE thumbnail baker (dev-only — not part of the production build; reached via /bake.html in
 * `npm run dev`). Renders every gallery preset to a still through the REAL engine (mono, desktop,
 * no XR, no thermal budget), reads the tonemapped pixels back, and composes one atlas PNG that the
 * DomeGallery loads. Re-run whenever the presets change.
 *
 * Why this works where a live-canvas screenshot can't: we render into an offscreen target and use
 * `readRenderTargetPixels`, which is immune to the main canvas's `preserveDrawingBuffer:false`.
 *
 * The combined order here (flames then bulbs) MUST match the dome tile order in main.ts and COLS
 * in DomeGallery.ts.
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

// --- tunables (re-bake to taste) -------------------------------------------
const COLS = 6 // atlas columns (DomeGallery COLS must match)
const TILE = 256 // atlas cell size (px)
const RENDER = 512 // offscreen render size — 2× supersample down into the tile for crisp glow
const SIZE_BAKE = 768 // sim grid → 589,824 particles (plenty dense for a thumbnail)
const FLAME_FRAMES = 240 // chaos-game frames from a cold seed (offline — settle generously)
const BULB_FRAMES = 150 // Newton-DE relaxation converges fast; a still needs no living shimmer
const FLAME_SCALE = 0.42 // flame model→view scale in the tile (live default is 0.16; bigger fills the cell)
const BULB_FILL = 1.9 // bulb framing multiplier on 0.65/bound (the live apparent-size normaliser)
const CAM_DIST = 1.6 // camera→fractal distance (mirrors the desktop view: cam −0.7, flame −2.3)
const VIEW_ROT_X = -0.33 // 3/4 view tilt so symmetric forms (mandelbulbs/boxes) read with 3D depth,
const VIEW_ROT_Y = 0.52 // not flat pole-on mandalas
const BULB_TONE = { exposure: 0.34, gamma: 2.4, k2: 55, hiDesat: 0.3 } // bulbs inherit a fixed tone (no per-genome tone)

const items: ({ kind: 'flame'; g: FlameGenome } | { kind: 'bulb'; b: BulbGenome })[] = [
  ...GALLERY.map((g) => ({ kind: 'flame' as const, g })),
  ...BULB_GALLERY.map((b) => ({ kind: 'bulb' as const, b })),
]

const status = document.getElementById('status') as HTMLDivElement
const setStatus = (s: string): void => {
  status.textContent = s
}

// --- engine (the live pipeline, shrunk + mono) ------------------------------
const renderer = new WebGLRenderer({ antialias: false, powerPreference: 'high-performance' })
renderer.setSize(RENDER, RENDER)
renderer.setClearColor(0x000000, 1)
// (the renderer canvas is never added to the DOM — we only read back its render targets)

const palette = new Palette(GALLERY[0].palette)
const sim = new Simulation(SIZE_BAKE)
sim.setParams({ iterations: 6, reseedProb: 0.0015 }) // a touch more iters than live for denser cold-start fill

const flamePoints = new FlamePoints(SIZE_BAKE, palette.texture, GALLERY[0].pointBrightness)
flamePoints.setActiveCount(SIZE_BAKE * SIZE_BAKE) // draw the whole grid for a complete still
flamePoints.setPointSize(2.4)

const group = new Group()
group.position.set(0, 0, -CAM_DIST)
group.rotation.set(VIEW_ROT_X, VIEW_ROT_Y, 0) // 3/4 view for 3D depth on the symmetric bulbs
group.add(flamePoints.points)
const scene = new Scene()
scene.add(group)

const compositor = new Compositor({ exposure: GALLERY[0].brightness, gamma: GALLERY[0].gamma, k2: GALLERY[0].k2, hiDesat: GALLERY[0].highlightDesat })
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

// --- atlas + scratch canvases ----------------------------------------------
const rows = Math.ceil(items.length / COLS)
const atlas = document.createElement('canvas')
atlas.width = COLS * TILE
atlas.height = rows * TILE
const actx = atlas.getContext('2d')!
actx.fillStyle = '#000'
actx.fillRect(0, 0, atlas.width, atlas.height)

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
  // settled DE params (no living breath — a still wants a clean canonical phase)
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
  // 1. accumulate additive point splats into the HDR target (cleared each frame — living, world-space)
  renderer.setRenderTarget(compositor.hdrRT)
  renderer.clear(true, true, true)
  renderer.autoClear = false
  renderer.render(scene, cam)
  renderer.autoClear = true
  // 2. log-density tone-map into the LDR readback target (opaque void — uPassthrough 0 by default)
  compositor.tonemap(renderer, ldr)
}

function blitToAtlas(k: number): void {
  const buf = new Uint8Array(RENDER * RENDER * 4)
  renderer.readRenderTargetPixels(ldr, 0, 0, RENDER, RENDER, buf)
  tctx.putImageData(new ImageData(new Uint8ClampedArray(buf), RENDER, RENDER), 0, 0)
  const col = k % COLS
  const row = (k / COLS) | 0
  actx.save()
  actx.translate(col * TILE, row * TILE)
  actx.scale(TILE / RENDER, TILE / RENDER) // supersample down into the cell
  actx.translate(0, RENDER)
  actx.scale(1, -1) // GL reads bottom-up; flip so the scene is upright
  actx.drawImage(tmp, 0, 0)
  actx.restore()
}

const sleep = (): Promise<void> => new Promise((r) => requestAnimationFrame(() => r()))

async function bake(): Promise<void> {
  const btn = document.getElementById('bake') as HTMLButtonElement
  btn.disabled = true
  for (let k = 0; k < items.length; k++) {
    const item = items[k]
    const name = item.kind === 'flame' ? item.g.name : item.b.name
    setStatus(`Baking ${k + 1}/${items.length} — ${name} (${item.kind})…`)
    await sleep() // let the status paint
    if (item.kind === 'flame') setFlame(item.g)
    else setBulb(item.b)
    sim.seed(renderer)
    const frames = item.kind === 'flame' ? FLAME_FRAMES : BULB_FRAMES
    for (let f = 0; f < frames; f++) renderOneFrame()
    blitToAtlas(k)
    atlas.style.display = 'block' // show progress filling in
  }

  setStatus(`Done — ${items.length} thumbnails. Saving thumbs.png…`)
  atlas.toBlob(async (blob) => {
    if (!blob) return
    // primary: POST straight to public/thumbs.png (the `npm run bake` server has the /save-thumbs
    // endpoint). Falls back to a normal download if that endpoint isn't present (e.g. plain dev server).
    try {
      const r = await fetch('/save-thumbs', { method: 'POST', body: blob })
      if (r.ok) {
        setStatus(`Saved → public/thumbs.png (${items.length} thumbnails). Done.`)
        ;(window as unknown as { bakeDone: boolean }).bakeDone = true
        return
      }
    } catch {
      /* fall through to download */
    }
    const a = document.createElement('a')
    a.href = URL.createObjectURL(blob)
    a.download = 'thumbs.png'
    a.click()
    setStatus(`Downloaded thumbs.png — move it into public/. Done.`)
    ;(window as unknown as { bakeDone: boolean }).bakeDone = true
  }, 'image/png')
  // also expose the data URL as a last-resort extraction path
  ;(window as unknown as { bakeAtlasURL: string }).bakeAtlasURL = atlas.toDataURL('image/png')
  btn.disabled = false
}

document.getElementById('bake')!.addEventListener('click', () => {
  bake().catch((e) => setStatus(`Error: ${(e as Error).message}`))
})
atlas.style.cssText = 'display:none;border:1px solid #234;margin-top:14px;max-width:92vw;image-rendering:pixelated'
document.body.appendChild(atlas)
setStatus(`Ready — ${items.length} presets (${GALLERY.length} flames + ${BULB_GALLERY.length} bulbs). Click Bake.`)
