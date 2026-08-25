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
import { HudPanel } from './HudPanel'
import { ReliefPanel } from './ReliefPanel'
import { ZoomXR, type XrHooks } from './xr'

// float32 runs out here. Past this the tile quantises into blocks — the cap is deliberately
// set one notch INTO the mush so the wall is visible rather than hidden behind a safe limit.
// Lifting it means perturbation (CPU reference orbit + fp32 deltas), not a bigger number.
const MIN_SCALE = 1e-5
const MAX_SCALE = 2.4

// Field resolutions, low to high. 2048² of RGBA16F is 33MB; 3072² is 75MB, which a Quest 3
// can hold but is worth knowing about. The field only re-renders when the view moves, so the
// cost of the big ones lands on pan/zoom responsiveness, not on the steady-state frame rate.
const RES_STEPS = [768, 1024, 1536, 2048, 3072]
const STEP_STEPS = [96, 128, 160, 224, 320, 448]
const ITER_SCALES = [0.5, 1, 1.5, 2, 3, 4, 6, 8]

const params = new URLSearchParams(location.search)
let resIdx = RES_STEPS.indexOf(Number(params.get('res') ?? 1536))
if (resIdx < 0) resIdx = 2
let stepIdx = 2
let iterIdx = 1

const PANEL_METRES = 2.4 // "the panel size is quite small, we can make it a lot larger"
const PANEL_DISTANCE = 1.9
const PANEL_HEIGHT = 1.45

const renderer = new WebGLRenderer({ antialias: false, powerPreference: 'high-performance' })
renderer.setPixelRatio(Math.min(devicePixelRatio, 2))
renderer.setSize(innerWidth, innerHeight)
renderer.xr.enabled = true
renderer.xr.setReferenceSpaceType('local-floor')
document.body.appendChild(renderer.domElement)
document.body.appendChild(VRButton.createButton(renderer))

const scene = new Scene()
scene.background = new Color(0x05060a)

const camera = new PerspectiveCamera(45, innerWidth / innerHeight, 0.01, 50)
const eyeL = camera.clone()
const eyeR = camera.clone()

let themeIndex = 4
const palette = new Palette(THEMES[themeIndex].colors)
const field = new FieldPass(RES_STEPS[resIdx])
// The panel mesh is a UNIT cube, so its physical size is just a uniform scale — which means
// two-grip resizing in VR costs nothing and the relief depth (a local-space quantity) grows
// with it automatically instead of staying a fixed number of centimetres.
const panel = new ReliefPanel(field.rt.texture, palette.texture, field.res, {
  depth: 0.16,
  geometryDepth: 1.1, // headroom for the deepest slab the ramp can ask for (0.5 x 2.2)
  steps: STEP_STEPS[stepIdx],
})
const hudVR = new HudPanel(1.0)
const heightRange = new HeightRange(field.res)
let rangeLo = 0
let rangeHi = 1
let rangePending = false

// Depth ramps with zoom, in panel-local units. At the widest view the structures are large
// and smooth, so a deep extrusion reads as a lumpy blob; once there is fine detail to carve,
// the same depth reads as texture.
const DEPTH_WIDE = 0.16
const DEPTH_DEEP = 0.5
const DEPTH_DECADES = 2
let depthScale = 1
const targetDepth = (): number => {
  const decades = Math.log10(DEFAULT_VIEW.scale / view.scale)
  const t = Math.max(0, Math.min(1, decades / DEPTH_DECADES))
  return (DEPTH_WIDE + (DEPTH_DEEP - DEPTH_WIDE) * t) * depthScale
}

const view: ZoomView = { ...DEFAULT_VIEW }
/**
 * Supersampling for the settled tile, by resolution.
 *
 * Supersampling and resolution fix the SAME problem — an escape count that changes faster
 * than one texel. Once the tile is 3072² the texels are small enough to resolve it on their
 * own, so 9x on top is nearly all waste, and it is 9x of the most expensive pass in the app.
 */
const refineSamples = (res: number): number => (res >= 3072 ? 1 : res >= 1536 ? 2 : 3)
const REFINE_DELAY = 0.22 // seconds of stillness before the tile is re-rendered antialiased
let lastMove = 0
let stereo = false
// Free-viewing a side-by-side pair works two ways round, and they are opposites. Parallel
// (wall-eyed) wants left-eye-left; cross-eyed wants left-eye-RIGHT. Feed a cross-viewer a
// parallel pair and the depth comes out inside-out — near reads as far. Hence the swap.
let crossView = false
const SEP = 0.064

const pushView = (): void => {
  view.maxIter = autoMaxIter(view.scale, DEFAULT_VIEW.scale, ITER_SCALES[iterIdx])
  field.setSamples(1) // preview quality while it is moving
  field.setFullQuality(false)
  field.setView(view)
  lastMove = performance.now() / 1000
}

// --- ray helpers (shared by mouse and controller) ---------------------------
const ray = new Raycaster()
const hit = new Vector3()
const ndc = new Vector2()

/** Panel-local coords under a world ray, or null on a miss. */
function localAtRay(origin: Vector3, direction: Vector3, out: Vector3, which: 'panel' | 'hud'): boolean {
  const mesh = which === 'panel' ? panel.mesh : hudVR.mesh
  if (which === 'hud' && !renderer.xr.isPresenting) return false // the VR HUD is not in the desktop path
  mesh.updateMatrixWorld()
  ray.set(origin, direction)
  const hits = ray.intersectObject(mesh, false)
  if (!hits.length) return false
  out.copy(hits[0].point)
  mesh.worldToLocal(out)
  return true
}

/**
 * The relief panel is a BackSide box, so a plain raycast reports the FAR wall. For picking we
 * want the plane the fractal lives on, so intersect that directly rather than the geometry.
 */
function panelLocalAtRay(origin: Vector3, direction: Vector3, out: Vector3): boolean {
  panel.mesh.updateMatrixWorld()
  const inv = panel.mesh.matrixWorld.clone().invert()
  const o = origin.clone().applyMatrix4(inv)
  const d = direction.clone().transformDirection(inv).normalize()
  if (Math.abs(d.z) < 1e-6) return false
  const t = -o.z / d.z // the z = 0 plane in panel-local space
  if (t <= 0) return false
  out.copy(o).addScaledVector(d, t)
  return Math.abs(out.x) <= panel.half.x && Math.abs(out.y) <= panel.half.y
}

const complexFromLocal = (local: Vector3): { x: number; y: number } => ({
  x: view.cx + (local.x / panel.half.x) * view.scale,
  y: view.cy + (local.y / panel.half.y) * view.scale,
})

const complexAtRay = (origin: Vector3, direction: Vector3): { x: number; y: number } | null =>
  panelLocalAtRay(origin, direction, hit) ? complexFromLocal(hit) : null

/** Where a screen point lands on the panel, in complex coords. Null if it misses. */
function complexAt(px: number, py: number): { x: number; y: number } | null {
  ndc.set((px / innerWidth) * 2 - 1, -(py / innerHeight) * 2 + 1)
  ray.setFromCamera(ndc, camera)
  return complexAtRay(ray.ray.origin, ray.ray.direction)
}

// --- runtime quality levers (the same code path from a key or a HUD button) --
function setRes(delta: number): void {
  const next = Math.max(0, Math.min(RES_STEPS.length - 1, resIdx + delta))
  if (next === resIdx) return
  resIdx = next
  field.setResolution(RES_STEPS[resIdx])
  heightRange.setResolution(RES_STEPS[resIdx])
  // setResolution disposes the old target, so anything holding its texture must be re-pointed
  panel.material.uniforms.uField.value = field.rt.texture
  panel.material.uniforms.uRes.value = field.activeRes
  // A long enough GPU submission can get the context killed outright. That used to be reachable
// here by pressing a button at the top of the resolution ladder; the field pass is banded now,
// but a dead context must still say so rather than leaving a frozen picture.
renderer.domElement.addEventListener('webglcontextlost', (e) => {
  e.preventDefault()
  hud.innerHTML = '<b class="mush">WebGL context lost.</b> Reload the page. If it keeps happening, drop RES or ITER.'
})

pushView()
}

function setSteps(delta: number): void {
  stepIdx = Math.max(0, Math.min(STEP_STEPS.length - 1, stepIdx + delta))
  panel.steps = STEP_STEPS[stepIdx]
}

function setIter(delta: number): void {
  iterIdx = Math.max(0, Math.min(ITER_SCALES.length - 1, iterIdx + delta))
  pushView()
}

let flatMode = false
let depthBeforeFlat = 1

/** Flat mode: the classic 2D fractal, no relief. Also the cheapest thing the app can draw. */
function setFlat(on: boolean): void {
  if (on === flatMode) return
  if (on) {
    depthBeforeFlat = depthScale
    depthScale = 0.02 // not exactly zero: the normal is derived from the height gradient
  } else {
    depthScale = depthBeforeFlat
  }
  flatMode = on
}

function setDepth(delta: number): void {
  if (flatMode) setFlat(false) // reaching for height means you want the relief back
  depthScale = Math.max(0.15, Math.min(2.2, depthScale * (delta > 0 ? 1.18 : 1 / 1.18)))
}

function setCurve(delta: number): void {
  const u = panel.material.uniforms.uHeightCurve
  u.value = Math.max(0, Math.min(2, u.value + delta * 0.25))
}

/**
 * Orbit-trap texture strength. Drives colour modulation and surface bump together, since
 * separating them just gives two sliders that only look right in the same place.
 */
function setTexture(delta: number): void {
  const u = panel.material.uniforms
  const next = Math.max(0, Math.min(1.6, (u.uTexAmt.value as number) + delta * 0.15))
  u.uTexAmt.value = next
  u.uTexBump.value = next * 0.05
  field.setTextureOn(next > 0.001) // stop paying for the orbit statistic nobody is reading
  if (next > 0.001) pushView()
}

const STALK_STEPS = [0, 0.5, 1] // marble → both → filaments

/** Cycle the exterior texture's character. The interior keeps its own trap either way. */
function cycleStyle(): void {
  const i = STALK_STEPS.indexOf(field.stalk)
  field.setStalk(STALK_STEPS[(i + 1) % STALK_STEPS.length] ?? 0)
  pushView()
}

function setBands(delta: number): void {
  view.colorCycles = Math.max(0.3, Math.min(30, view.colorCycles * (delta > 0 ? 1.25 : 1 / 1.25)))
  pushView()
}

function cyclePalette(delta = 1): void {
  themeIndex = (themeIndex + delta + THEMES.length) % THEMES.length
  palette.setColors(THEMES[themeIndex].colors)
}

function resetView(): void {
  Object.assign(view, DEFAULT_VIEW)
  zoomVel = velX = velY = autoZoom = 0
  pushView()
}

/** One place for every HUD button, so a key and a controller do exactly the same thing. */
function pressButton(id: string): void {
  hudVR.press(id)
  switch (id) {
    case 'res-': return setRes(-1)
    case 'res+': return setRes(1)
    case 'iter-': return setIter(-1)
    case 'iter+': return setIter(1)
    case 'steps-': return setSteps(-1)
    case 'steps+': return setSteps(1)
    case 'depth-': return setDepth(-1)
    case 'depth+': return setDepth(1)
    case 'curve-': return setCurve(-1)
    case 'curve+': return setCurve(1)
    case 'bands-': return setBands(-1)
    case 'bands+': return setBands(1)
    case 'tex-': return setTexture(-1)
    case 'tex+': return setTexture(1)
    case 'style': return cycleStyle()
    case 'invert':
      view.invert = !view.invert
      return pushView()
    case 'relief':
      view.ridge = view.ridge > 0.5 ? 0 : view.ridge > 0.05 ? 1 : 0.45
      return pushView()
    case 'palette': return cyclePalette()
    case 'julia':
      view.julia = !view.julia
      return pushView()
    case 'flat': return setFlat(!flatMode)
    case 'reset':
      setFlat(false)
      return resetView()
    case 'exit':
      renderer.xr.getSession()?.end()
      return
  }
}

// --- XR ---------------------------------------------------------------------
const xrHooks: XrHooks = {
  panBy(dx, dy) {
    view.cx += dx
    view.cy += dy
    pushView()
  },
  zoom: (k, anchor) => applyZoom(k, anchor),
  complexAtRay: (o, d) => complexAtRay(o, d),
  localAtRay,
  press: pressButton,
}
const xr = new ZoomXR(renderer, panel, hudVR, xrHooks)
scene.add(xr.rig)
// controllers live at the scene root, not in the rig: they track the room, not the panel
for (const c of xr.controllers) scene.add(c)

let targetHz = 72
renderer.xr.addEventListener('sessionstart', () => {
  stereo = false // three drives both eyes in-session; the manual split would fight it
  xr.panelScale = PANEL_METRES
  xr.place(PANEL_DISTANCE, PANEL_HEIGHT)
  const session = renderer.xr.getSession()
  targetHz = Math.round(session?.frameRate ?? 72)
})
renderer.xr.addEventListener('sessionend', () => {
  xr.panelScale = 1
  xr.reset()
  xr.layout()
})

// --- drift (the whole point: momentum, so a flick keeps gliding) -------------
let velX = 0
let velY = 0
let zoomVel = 0
let autoZoom = 0 // -1 = in, +1 = out, 0 = off
let autoRate = 0.05 // octaves/sec: a doubling every ~20s, which reads as drifting not travelling
const DAMP = 2.2

// --- camera framing (desktop only) ------------------------------------------
let camDist = 1.35
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

// --- mouse ------------------------------------------------------------------
let dragging = false
let orbiting = false
let last: { x: number; y: number } | null = null
const lastPx = new Vector2()

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
  if (k === ' ') resetView()
  else if (k === 'z') {
    const dir = e.shiftKey ? 1 : -1
    autoZoom = autoZoom === dir ? 0 : dir
  } else if (k === '9' || k === '0') {
    autoRate = Math.max(0.01, Math.min(1.2, autoRate * (k === '0' ? 1.3 : 1 / 1.3)))
  } else if (k === 'i') pressButton('invert')
  else if (k === 'j') pressButton('julia')
  else if (k === 'r') pressButton('relief')
  else if (k === 'p') sway = !sway
  else if (k === 'f') pressButton('flat')
  else if (k === 'k' || k === 'l') pressButton(k === 'l' ? 'tex+' : 'tex-')
  else if (k === 'y') pressButton('style')
  else if (k === 'x') {
    if (e.shiftKey) crossView = !crossView
    else stereo = !stereo
  } else if (k === '[' || k === ']') cyclePalette(k === ']' ? 1 : -1)
  else if (k === '-' || k === '=') {
    depthScale = Math.max(0.2, Math.min(2.2, depthScale * (k === '=' ? 1.15 : 1 / 1.15)))
  } else if (k === ',' || k === '.') {
    view.colorCycles = Math.max(0.2, view.colorCycles * (k === '.' ? 1.2 : 1 / 1.2))
    pushView()
  } else if (k === 'q' || k === 'w') setRes(k === 'w' ? 1 : -1)
  else if (k === 'a' || k === 's') setIter(k === 's' ? 1 : -1)
  else if (k === 'e' || k === 'd') setSteps(k === 'd' ? 1 : -1)
})

/** Ease the slab toward the zoom-dependent target, so a zoom reads as the relief growing. */
function easeDepth(dt: number): void {
  const hz = panel.material.uniforms.uHalf.value
  hz.z += (targetDepth() / 2 - hz.z) * (1 - Math.exp(-3 * dt))
}

/** One draw — mono, or side-by-side when the desktop stereo check is on. */
function drawFrame(): void {
  if (!stereo || renderer.xr.isPresenting) {
    renderer.render(scene, camera)
    return
  }
  const w = renderer.domElement.width / renderer.getPixelRatio()
  const h = renderer.domElement.height / renderer.getPixelRatio()
  const right = new Vector3().setFromMatrixColumn(camera.matrixWorld, 0)
  renderer.setScissorTest(true)
  for (let i = 0; i < 2; i++) {
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

// --- stats ------------------------------------------------------------------
const hud = document.createElement('div')
hud.className = 'hud'
document.body.appendChild(hud)

const frameLog: number[] = []
let fps = 0
let statT = 0
let frameMs = 0
let frameP95 = 0

let lastStats: Parameters<HudPanel['draw']>[0] | null = null

function updateStats(now: number, dt: number): void {
  frameLog.push(dt * 1000)
  if (frameLog.length > 180) frameLog.shift()
  if (now - statT < 0.25) {
    // hover and press feedback must not wait for the next stats tick
    if (hudVR.needsRedraw && lastStats) hudVR.draw(lastStats)
    return
  }
  statT = now
  const sorted = [...frameLog].sort((a, b) => a - b)
  frameMs = sorted[Math.floor(sorted.length * 0.5)] ?? 0
  frameP95 = sorted[Math.floor(sorted.length * 0.95)] ?? 0
  fps = frameMs > 0 ? 1000 / frameMs : 0

  const zoom = DEFAULT_VIEW.scale / view.scale
  const ulps = precisionUlps(view, field.res)
  // xr.panelScale IS the mesh scale, in or out of a session — report what is actually drawn
  const depth = panel.material.uniforms.uHalf.value.z * 2 * xr.panelScale
  const stats = {
    zoom,
    iter: view.maxIter,
    res: field.res,
    samples: field.samples,
    fps,
    frameMs,
    frameP95,
    targetHz: renderer.xr.isPresenting ? targetHz : Math.round(fps || 60),
    depth,
    panel: xr.panelScale,
    steps: panel.material.uniforms.uSteps.value as number,
    ulps,
    julia: view.julia,
    invert: view.invert,
    ridge: view.ridge,
    theme: THEMES[themeIndex].name,
    curve: panel.material.uniforms.uHeightCurve.value as number,
    flat: flatMode,
    texture: panel.material.uniforms.uTexAmt.value as number,
    stalk: field.stalk,
    bands: view.colorCycles,
    refine: field.refineProgress,
  }
  lastStats = stats
  hudVR.draw(stats)

  const grade = ulps > 8 ? 'clean' : ulps > 4 ? 'softening' : ulps > 1 ? 'blocky' : 'mush'
  hud.innerHTML = `
    <b>zoom</b> ${zoom < 1000 ? zoom.toFixed(1) : zoom.toExponential(2)}×
    &nbsp; <b>iter</b> ${view.maxIter} (×${ITER_SCALES[iterIdx]})
    &nbsp; <b>frame</b> ${frameMs.toFixed(1)}ms p95 ${frameP95.toFixed(1)}ms
    &nbsp; <b>field</b> ${field.res}²·${field.samples ** 2}x (${field.activeRes}² live)
    &nbsp; <b>march</b> ${panel.material.uniforms.uSteps.value}${flatMode ? ' flat' : ''}${field.refining ? ` · <b>sharpening ${Math.round(field.refineProgress * 100)}%</b>` : ''}<br>
    <b>fp32</b> ${ulps.toFixed(1)} ulps/texel <span class="${grade}">${grade}</span>
    &nbsp; <b>relief</b> ${view.ridge < 0.05 ? 'terrace' : view.ridge > 0.95 ? 'ridge' : 'mixed'}${view.invert ? '·inverted' : ''}
    &nbsp; <b>high</b> ${depth.toFixed(2)}m
    &nbsp; <b>shape</b> ${(panel.material.uniforms.uHeightCurve.value as number).toFixed(2)}
    &nbsp; <b>bands</b> ${view.colorCycles.toFixed(1)}
    &nbsp; <b>texture</b> ${(panel.material.uniforms.uTexAmt.value as number).toFixed(2)} ${field.stalk < 0.05 ? 'marble' : field.stalk > 0.95 ? 'filament' : 'mixed'}
    &nbsp; <b>glide</b> ${autoRate.toFixed(3)}/s${autoZoom ? (autoZoom < 0 ? ' in' : ' out') : ' off'}${stereo ? (crossView ? ' · cross' : ' · parallel') : ''}
    &nbsp; <b>${view.julia ? 'julia' : 'mandelbrot'}</b>
    &nbsp; <b>${THEMES[themeIndex].name}</b><br>
    <span class="dim">drag pan · wheel zoom · shift-drag orbit · z/shift-z auto-zoom · 9 0 glide ·
    q w field res · a s iterations · e d march steps · - = height · ; ' shape · , . bands · k l texture · y style ·
    i invert · r relief · j julia · x stereo ·
    shift-x cross/parallel · p sway · [ ] palette · - = depth · , . colour · space reset</span>`
}

// --- loop -------------------------------------------------------------------
let prev = performance.now() / 1000
renderer.setAnimationLoop(() => {
  const now = performance.now() / 1000
  const dt = Math.min(0.05, now - prev)
  prev = now

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

  if (renderer.xr.isPresenting) xr.update(dt)
  else placeCamera(now)

  easeDepth(dt)
  // A nearly planar surface is hit on the first or second sample, so the full march is waste.
  // Read the SETTING (stepIdx), never panel.steps — that is the uniform this line just wrote,
  // so restoring from it latches whatever flat mode last clamped it to.
  panel.material.uniforms.uSteps.value = flatMode
    ? Math.min(STEP_STEPS[stepIdx], 48)
    : STEP_STEPS[stepIdx]
  xr.layout() // slab depth eases every frame, and the front-face anchor has to follow it

  // settle → refine. The field only ever re-renders when it has to, which is what leaves
  // enough budget for a full-quality tile the moment you stop moving.
  if (now - lastMove > REFINE_DELAY) {
    field.setSamples(refineSamples(field.res))
    field.setFullQuality(true)
  }
  const rendered = field.render(renderer)
  if (rendered) {
    // the active target alternates between the preview and full tiles, so rebind every time
    panel.material.uniforms.uField.value = field.rt.texture
    panel.material.uniforms.uRes.value = field.activeRes
    // the reduction ends in a synchronous readback, which stalls the pipeline — so never run
    // it in the same frame as the band that finished the tile
    if (field.fullQuality && !field.refining) rangePending = true
  } else if (rangePending) {
    rangePending = false
    const r = heightRange.compute(renderer, field.fullRt, 0)
    rangeLo = r.lo
    rangeHi = r.hi
    // the orbit texture needs its own range: raw TIA sits in a narrow band and reads as a
    // faint tint until it is stretched over what the tile actually contains
    const t = heightRange.compute(renderer, field.fullRt, 3)
    panel.material.uniforms.uTexLo.value = t.lo
    panel.material.uniforms.uTexHi.value = t.hi
  }
  const hu = panel.material.uniforms
  const ease = 1 - Math.exp(-6 * dt)
  hu.uHeightLo.value += (rangeLo - hu.uHeightLo.value) * ease
  hu.uHeightHi.value += (rangeHi - hu.uHeightHi.value) * ease

  updateStats(now, dt)
  drawFrame()
})

// debug handle — drive the view without depending on requestAnimationFrame, which Chrome
// freezes in a background tab
;(window as unknown as Record<string, unknown>).zoomSpike = {
  view,
  panel,
  field,
  renderer,
  hudVR,
  xr,
  press: pressButton,
  set(patch: Partial<ZoomView>) {
    Object.assign(view, patch)
    pushView()
  },
  zoom(k: number, ax?: number, ay?: number) {
    applyZoom(k, ax !== undefined && ay !== undefined ? { x: ax, y: ay } : null)
  },
  step(t = 0, dt = 1 / 60) {
    easeDepth(dt)
  // A nearly planar surface is hit on the first or second sample, so the full march is waste.
  // Read the SETTING (stepIdx), never panel.steps — that is the uniform this line just wrote,
  // so restoring from it latches whatever flat mode last clamped it to.
  panel.material.uniforms.uSteps.value = flatMode
    ? Math.min(STEP_STEPS[stepIdx], 48)
    : STEP_STEPS[stepIdx]
  xr.layout() // slab depth eases every frame, and the front-face anchor has to follow it
    placeCamera(t)
    field.render(renderer)
    drawFrame()
  },
  stereo(on: boolean, cross = false) {
    stereo = on
    crossView = cross
  },
  quality: () => ({ res: field.res, steps: panel.steps, iterScale: ITER_SCALES[iterIdx], maxIter: view.maxIter }),
  hud: () => hud.innerText,
  orbit(yaw: number, pitch: number, dist = camDist) {
    orbitYaw = yaw
    orbitPitch = pitch
    camDist = dist
    sway = false
  },
  range: () => ({ lo: rangeLo, hi: rangeHi }),
  refineSamples: () => refineSamples(field.res),
  measureRange() {
    const r = heightRange.compute(renderer, field.fullRt, 0)
    rangeLo = r.lo
    rangeHi = r.hi
    panel.material.uniforms.uHeightLo.value = r.lo
    panel.material.uniforms.uHeightHi.value = r.hi
    const t = heightRange.compute(renderer, field.fullRt, 3)
    panel.material.uniforms.uTexLo.value = t.lo
    panel.material.uniforms.uTexHi.value = t.hi
    return { ...r, tex: t }
  },
}

addEventListener('resize', () => {
  renderer.setSize(innerWidth, innerHeight)
  camera.aspect = innerWidth / innerHeight
  camera.updateProjectionMatrix()
})

pushView()
