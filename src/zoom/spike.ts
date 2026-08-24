import {
  Color,
  PerspectiveCamera,
  Raycaster,
  Scene,
  Vector2,
  Vector3,
  WebGLRenderer,
} from 'three'
import { VRButton } from 'three/examples/jsm/webxr/VRButton.js'
import { Palette } from '../flame/palette'
import { THEMES } from '../flame/palettes'
import { autoMaxIter, DEFAULT_VIEW, FieldPass, precisionUlps, type ZoomView } from './FieldPass'
import { HeightRange } from './HeightRange'
import { ReliefPanel } from './ReliefPanel'
import { ZoomXR, type XrHooks } from './xr'

// float32 runs out here. Past this the tile quantises into blocks — the cap is deliberately
// set one notch INTO the mush so the wall is visible rather than hidden behind a safe limit.
// Lifting it means perturbation (CPU reference orbit + fp32 deltas), not a bigger number.
const MIN_SCALE = 1e-5
const MAX_SCALE = 2.4

const res = Number(new URLSearchParams(location.search).get('res') ?? 1024)

const renderer = new WebGLRenderer({ antialias: false, powerPreference: 'high-performance' })
renderer.setPixelRatio(Math.min(devicePixelRatio, 2))
renderer.setSize(innerWidth, innerHeight)
renderer.xr.enabled = true
renderer.xr.setReferenceSpaceType('local-floor')
document.body.appendChild(renderer.domElement)
document.body.appendChild(VRButton.createButton(renderer))

const scene = new Scene()
scene.background = new Color(0x05060a)

const camera = new PerspectiveCamera(45, innerWidth / innerHeight, 0.01, 20)
const eyeL = camera.clone()
const eyeR = camera.clone()

let themeIndex = 4
const palette = new Palette(THEMES[themeIndex].colors)
const field = new FieldPass(res)
const panel = new ReliefPanel(field.rt.texture, palette.texture, res, {
  depth: 0.16,
  geometryDepth: 1.1, // headroom so the slab can grow with zoom without rebuilding geometry
  steps: 160,
})

// Depth ramps with zoom. At the widest view the structures are large and smooth, so a deep
// extrusion reads as a lumpy blob; once there is fine detail to carve, the same depth reads as
// texture. Sam's call after seeing 0.5m flat-out: "too much on the default view, a lot better
// once you zoom in".
const DEPTH_WIDE = 0.16
const DEPTH_DEEP = 0.5
const DEPTH_DECADES = 2 // zoom decades over which it eases from wide to deep
let depthScale = 1 // the - / = keys nudge this, so the ramp survives manual tuning
const targetDepth = (): number => {
  const decades = Math.log10(DEFAULT_VIEW.scale / view.scale)
  const t = Math.max(0, Math.min(1, decades / DEPTH_DECADES))
  return (DEPTH_WIDE + (DEPTH_DEEP - DEPTH_WIDE) * t) * depthScale
}

// height auto-exposure: measured on the refined tile only, so the readback stall never
// lands on a frame you are actively dragging
const heightRange = new HeightRange(res)
let rangeLo = 0
let rangeHi = 1

const xrHooks: XrHooks = {
  panBy(dx, dy) {
    view.cx += dx
    view.cy += dy
    pushView()
  },
  zoom(k, anchor) {
    applyZoom(k, anchor)
  },
  complexAtRay: (o, d) => complexAtRay(o, d),
}
const xr = new ZoomXR(renderer, panel, xrHooks)
scene.add(xr.rig)

renderer.xr.addEventListener('sessionstart', () => {
  xr.place()
  stereo = false // three drives both eyes in-session; the manual split would fight it
})
renderer.xr.addEventListener('sessionend', () => xr.reset())

const view: ZoomView = { ...DEFAULT_VIEW }
const REFINE_SAMPLES = 3
const REFINE_DELAY = 0.22 // seconds of stillness before the tile is re-rendered antialiased
let lastMove = 0
// side-by-side stereo check — proves each eye marches from its own ray origin
let stereo = false
// Free-viewing a side-by-side pair works two ways round, and they are opposites. Parallel
// (wall-eyed) wants left-eye-left; cross-eyed wants left-eye-RIGHT. Feed a cross-viewer a
// parallel pair and the depth comes out inside-out — near reads as far. Hence the swap.
let crossView = false
const SEP = 0.064
const pushView = (): void => {
  view.maxIter = autoMaxIter(view.scale)
  field.setSamples(1) // drop to preview quality while it is moving
  field.setView(view)
  lastMove = performance.now() / 1000
}

// --- camera framing ---------------------------------------------------------
let camDist = 1.35 // a 1m panel at 45° fov just overfills the frame at 1.15
let orbitYaw = 0
let orbitPitch = 0
let sway = true
const placeCamera = (t: number): void => {
  const sx = sway ? Math.sin(t * 0.25) * 0.14 : 0
  const sy = sway ? Math.sin(t * 0.19 + 1.1) * 0.08 : 0
  const yaw = orbitYaw + sx
  const pitch = orbitPitch + sy
  camera.position.set(
    Math.sin(yaw) * Math.cos(pitch) * camDist,
    Math.sin(pitch) * camDist,
    Math.cos(yaw) * Math.cos(pitch) * camDist,
  )
  camera.lookAt(0, 0, 0)
  camera.updateMatrixWorld()
}

// --- pointer → complex plane ------------------------------------------------
const ray = new Raycaster()
const hit = new Vector3()
const ndc = new Vector2()

/** Panel-local coords to complex coords, given the current window. */
const complexFromLocal = (local: Vector3): { x: number; y: number } => ({
  x: view.cx + (local.x / panel.half.x) * view.scale,
  y: view.cy + (local.y / panel.half.y) * view.scale,
})

/** Where a world-space ray meets the panel, in complex coords. Null if it misses. */
const complexAtRay = (origin: Vector3, direction: Vector3): { x: number; y: number } | null =>
  xr.localAtRay(origin, direction, hit) ? complexFromLocal(hit) : null

/** Where a screen point lands on the panel, in complex coords. Null if it misses. */
function complexAt(px: number, py: number): { x: number; y: number } | null {
  ndc.set((px / innerWidth) * 2 - 1, -(py / innerHeight) * 2 + 1)
  ray.setFromCamera(ndc, camera)
  return complexAtRay(ray.ray.origin, ray.ray.direction)
}

// --- drift (the whole point: momentum, so a flick keeps gliding) -------------
let velX = 0
let velY = 0
let zoomVel = 0 // log2 units per second
let autoZoom = 0 // -1 = in, +1 = out, 0 = off
let autoRate = 0.05 // octaves per second: a doubling every ~20s, which is the pace that reads as drifting rather than travelling
const DAMP = 2.2 // per-second exponential decay on flick momentum

let dragging = false
let orbiting = false
let last: { x: number; y: number } | null = null
let lastPx = new Vector2()

renderer.domElement.addEventListener('pointerdown', (e) => {
  renderer.domElement.setPointerCapture(e.pointerId)
  if (e.button === 2 || e.shiftKey) {
    orbiting = true
    lastPx.set(e.clientX, e.clientY)
  } else {
    dragging = true
    last = complexAt(e.clientX, e.clientY)
    velX = velY = 0
  }
})

renderer.domElement.addEventListener('pointermove', (e) => {
  if (orbiting) {
    orbitYaw -= (e.clientX - lastPx.x) * 0.005
    orbitPitch = Math.max(-1.2, Math.min(1.2, orbitPitch + (e.clientY - lastPx.y) * 0.005))
    lastPx.set(e.clientX, e.clientY)
    return
  }
  if (!dragging) return
  const now = complexAt(e.clientX, e.clientY)
  if (!now || !last) return
  // move the window so the grabbed point stays under the cursor
  const dx = last.x - now.x
  const dy = last.y - now.y
  view.cx += dx
  view.cy += dy
  velX = dx * 26 // rough per-second velocity; decays into the glide
  velY = dy * 26
  last = complexAt(e.clientX, e.clientY)
  pushView()
})

const endDrag = (e: PointerEvent): void => {
  dragging = false
  orbiting = false
  last = null
  renderer.domElement.releasePointerCapture?.(e.pointerId)
}
renderer.domElement.addEventListener('pointerup', endDrag)
renderer.domElement.addEventListener('pointercancel', endDrag)
renderer.domElement.addEventListener('contextmenu', (e) => e.preventDefault())

// wheel zooms about the cursor, into a velocity rather than a jump — that is the Frax glide
let zoomAnchor: { x: number; y: number } | null = null
renderer.domElement.addEventListener(
  'wheel',
  (e) => {
    e.preventDefault()
    zoomAnchor = complexAt(e.clientX, e.clientY)
    zoomVel += (e.deltaY > 0 ? 1 : -1) * 1.4
  },
  { passive: false },
)

/** Scale by 2^k, keeping `anchor` pinned where it is on screen. */
function applyZoom(k: number, anchor: { x: number; y: number } | null): void {
  const next = Math.min(MAX_SCALE, Math.max(MIN_SCALE, view.scale * Math.pow(2, k)))
  if (next === view.scale) return
  const f = next / view.scale
  if (anchor) {
    view.cx = anchor.x + (view.cx - anchor.x) * f
    view.cy = anchor.y + (view.cy - anchor.y) * f
  }
  view.scale = next
  pushView()
}

// --- keys -------------------------------------------------------------------
addEventListener('keydown', (e) => {
  const k = e.key.toLowerCase()
  if (k === ' ') {
    Object.assign(view, DEFAULT_VIEW)
    zoomVel = velX = velY = autoZoom = 0
    pushView()
  } else if (k === 'z') {
    const dir = e.shiftKey ? 1 : -1 // shift-Z drifts back out
    autoZoom = autoZoom === dir ? 0 : dir
  } else if (k === '9' || k === '0') {
    autoRate = Math.max(0.01, Math.min(1.2, autoRate * (k === '0' ? 1.3 : 1 / 1.3)))
  } else if (k === 'i') {
    view.invert = !view.invert
    pushView()
  } else if (k === 'j') {
    view.julia = !view.julia
    pushView()
  } else if (k === 'r') {
    view.ridge = view.ridge > 0.5 ? 0 : view.ridge > 0.05 ? 1 : 0.45
    pushView()
  } else if (k === 'p') {
    sway = !sway
  } else if (k === 'x') {
    if (e.shiftKey) crossView = !crossView
    else stereo = !stereo
  } else if (k === '[' || k === ']') {
    themeIndex = (themeIndex + (k === ']' ? 1 : THEMES.length - 1)) % THEMES.length
    palette.setColors(THEMES[themeIndex].colors)
  } else if (k === '-' || k === '=') {
    depthScale = Math.max(0.2, Math.min(2.2, depthScale * (k === '=' ? 1.15 : 1 / 1.15)))
  } else if (k === ',' || k === '.') {
    view.colorCycles = Math.max(0.2, view.colorCycles * (k === '.' ? 1.2 : 1 / 1.2))
    pushView()
  }
})

/** Ease the slab toward the zoom-dependent target, so a zoom reads as the relief growing. */
function easeDepth(dt: number): void {
  const hz = panel.material.uniforms.uHalf.value
  hz.z += (targetDepth() / 2 - hz.z) * (1 - Math.exp(-3 * dt))
}

/** One draw of the panel — mono, or side-by-side when the stereo check is on. */
function drawFrame(): void {
  if (!stereo) {
    renderer.render(scene, camera)
    return
  }
  const w = renderer.domElement.width / renderer.getPixelRatio()
  const h = renderer.domElement.height / renderer.getPixelRatio()
  const right = new Vector3().setFromMatrixColumn(camera.matrixWorld, 0)
  renderer.setScissorTest(true)
  for (let i = 0; i < 2; i++) {
    // i is the screen half; crossView decides which eye's view lands on it
    const isLeftEye = crossView ? i === 1 : i === 0
    const cam = isLeftEye ? eyeL : eyeR
    cam.copy(camera)
    cam.aspect = w / 2 / h
    cam.position.addScaledVector(right, (isLeftEye ? -0.5 : 0.5) * SEP)
    cam.updateProjectionMatrix()
    cam.updateMatrixWorld()
    renderer.setViewport((i * w) / 2, 0, w / 2, h)
    renderer.setScissor((i * w) / 2, 0, w / 2, h)
    renderer.render(scene, cam)
  }
  renderer.setScissorTest(false)
  renderer.setViewport(0, 0, w, h)
}

// --- HUD --------------------------------------------------------------------
const hud = document.createElement('div')
hud.className = 'hud'
document.body.appendChild(hud)

let frames = 0
let fps = 0
let fpsT = 0

// --- loop -------------------------------------------------------------------
let prev = performance.now() / 1000
renderer.setAnimationLoop((_time, frame) => {
  const now = performance.now() / 1000
  const dt = Math.min(0.05, now - prev)
  prev = now

  // glide: pan momentum + zoom momentum + optional hands-free zoom
  const decay = Math.exp(-DAMP * dt)
  if (!dragging && (Math.abs(velX) > 1e-12 || Math.abs(velY) > 1e-12)) {
    view.cx += velX * dt
    view.cy += velY * dt
    velX *= decay
    velY *= decay
    pushView()
  }
  const zk = zoomVel * dt + autoZoom * autoRate * dt
  if (Math.abs(zk) > 1e-6) applyZoom(zk, zoomAnchor)
  zoomVel *= decay

  const presenting = renderer.xr.isPresenting
  if (!presenting) placeCamera(now)
  else xr.update(dt, frame ?? null)

  easeDepth(dt)
  const hz = panel.material.uniforms.uHalf.value

  // settle → refine. The field only ever re-renders when it has to, which is what leaves
  // enough budget for a full-quality tile the moment you stop moving.
  if (now - lastMove > REFINE_DELAY) field.setSamples(REFINE_SAMPLES)
  const rendered = field.render(renderer) // no-op unless the window moved
  if (rendered && field.samples >= REFINE_SAMPLES) {
    const r = heightRange.compute(renderer, field.rt)
    rangeLo = r.lo
    rangeHi = r.hi
  }
  // ease toward the measured range so a re-scale reads as the relief breathing, not a pop
  const hu = panel.material.uniforms
  const ease = 1 - Math.exp(-6 * dt)
  hu.uHeightLo.value += (rangeLo - hu.uHeightLo.value) * ease
  hu.uHeightHi.value += (rangeHi - hu.uHeightHi.value) * ease

  drawFrame()

  frames++
  if (now - fpsT > 0.5) {
    fps = frames / (now - fpsT)
    frames = 0
    fpsT = now
    const zoom = DEFAULT_VIEW.scale / view.scale
    const ulps = precisionUlps(view, res)
    const grade = ulps > 8 ? 'clean' : ulps > 4 ? 'softening' : ulps > 1 ? 'blocky' : 'mush'
    hud.innerHTML = `
      <b>zoom</b> ${zoom < 1000 ? zoom.toFixed(1) : zoom.toExponential(2)}×
      &nbsp; <b>iter</b> ${view.maxIter}
      &nbsp; <b>fps</b> ${fps.toFixed(0)}
      &nbsp; <b>field</b> ${res}²·${field.samples ** 2}x<br>
      <b>fp32</b> ${ulps.toFixed(1)} ulps/texel <span class="${grade}">${grade}</span>
      &nbsp; <b>relief</b> ${view.ridge < 0.05 ? 'terrace' : view.ridge > 0.95 ? 'ridge' : 'mixed'}${view.invert ? '·inverted' : ''}
      &nbsp; <b>depth</b> ${(hz.z * 2).toFixed(2)}m
      &nbsp; <b>glide</b> ${autoRate.toFixed(3)}/s${autoZoom ? (autoZoom < 0 ? ' in' : ' out') : ' off'}${stereo ? (crossView ? ' · cross' : ' · parallel') : ''}
      &nbsp; <b>${view.julia ? 'julia' : 'mandelbrot'}</b>
      &nbsp; <b>${THEMES[themeIndex].name}</b><br>
      <span class="dim">drag pan · wheel zoom · shift-drag orbit · z/shift-z auto-zoom in/out ·
      9 0 glide speed · i invert relief · x stereo · shift-x cross/parallel · r relief · j julia ·
      p sway · [ ] palette · - = depth · , . colour · space reset</span>`
  }
})

// debug handle — drive the view from the console (and from automated checks) without
// depending on requestAnimationFrame, which Chrome freezes in a background tab
;(window as unknown as Record<string, unknown>).zoomSpike = {
  view,
  panel,
  field,
  renderer,
  set(patch: Partial<ZoomView>) {
    Object.assign(view, patch)
    pushView()
  },
  zoom(k: number, ax?: number, ay?: number) {
    applyZoom(k, ax !== undefined && ay !== undefined ? { x: ax, y: ay } : null)
  },
  step(t = 0, dt = 1 / 60) {
    easeDepth(dt)
    placeCamera(t)
    field.render(renderer)
    drawFrame()
  },
  stereo(on: boolean, cross = false) {
    stereo = on
    crossView = cross
  },
  hud: () => hud.innerText,
  orbit(yaw: number, pitch: number, dist = camDist) {
    orbitYaw = yaw
    orbitPitch = pitch
    camDist = dist
    sway = false
  },
  range: () => ({ lo: rangeLo, hi: rangeHi }),
  measureRange() {
    const r = heightRange.compute(renderer, field.rt)
    rangeLo = r.lo
    rangeHi = r.hi
    panel.material.uniforms.uHeightLo.value = r.lo
    panel.material.uniforms.uHeightHi.value = r.hi
    return r
  },
}

addEventListener('resize', () => {
  renderer.setSize(innerWidth, innerHeight)
  camera.aspect = innerWidth / innerHeight
  camera.updateProjectionMatrix()
})

pushView()
