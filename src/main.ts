import {
  Group,
  HemisphereLight,
  GridHelper,
  Line,
  LineBasicMaterial,
  BufferGeometry,
  Material,
  PerspectiveCamera,
  Scene,
  Vector2,
  Vector3,
  Vector4,
  WebGLRenderer,
} from 'three'
import { VRButton } from 'three/examples/jsm/webxr/VRButton.js'
import { XRControllerModelFactory } from 'three/examples/jsm/webxr/XRControllerModelFactory.js'
import { OrbitControls } from 'three/examples/jsm/controls/OrbitControls.js'
import './style.css'

import { GALLERY } from './flame/presets'
import type { FlameGenome } from './flame/types'
import { encodeFlame } from './flame/encode'
import { Palette } from './flame/palette'
import { interpolateGenome, smoothstep } from './flame/morph'
import { randomGenome, mutate, crossover } from './flame/breed'
import { BULB_GALLERY, randomBulb, mutateBulb, flipBulbKind, interpolateBulb } from './flame/bulbs'
import type { BulbGenome } from './flame/bulbs'
import { THEMES, themeColors } from './flame/palettes'
import { loadFavorites, persistFavorites } from './flame/favorites'
import { Simulation } from './engine/Simulation'
import { FlamePoints } from './engine/FlamePoints'
import { Compositor } from './engine/Compositor'
import { AdaptiveQuality } from './engine/AdaptiveQuality'
import { GpuTimer } from './engine/GpuTimer'
import { WorldGrab } from './xr/WorldGrab'
import { WristMenu } from './xr/WristMenu'
import { ControlsGuide } from './xr/ControlsGuide'
import { createMRButton } from './xr/MRButton'

// Replace the landing overlay with a readable message (no innerHTML — keep the codebase XSS-free).
function showFatal(msg: string, hint: string): void {
  const o = document.getElementById('overlay')
  if (!o) return
  o.replaceChildren()
  const h = document.createElement('h1')
  h.textContent = 'FractalXR'
  const p = document.createElement('p')
  p.textContent = msg
  const s = document.createElement('p')
  s.textContent = hint
  s.style.opacity = '0.7'
  o.append(h, p, s)
}

// The engine is WebGL2 / GLSL ES 3.00. Fail with a readable message rather than a silent black
// screen for visitors on older/locked-down browsers or a GPU blocklist.
if (!document.createElement('canvas').getContext('webgl2')) {
  showFatal(
    "This needs WebGL2, which this browser or device doesn't support here.",
    'Try a recent desktop Chrome, Edge or Firefox — or open it in the Meta Quest browser.',
  )
  throw new Error('WebGL2 unavailable')
}

// --- renderer ---------------------------------------------------------------
// alpha: true gives the drawing buffer an alpha channel so immersive-ar passthrough
// can show through where we clear/write transparent. Harmless for VR (opaque blend)
// and desktop (we clear opaque black there).
const renderer = new WebGLRenderer({ antialias: false, powerPreference: 'high-performance', alpha: true })
renderer.setPixelRatio(window.devicePixelRatio)
renderer.setSize(window.innerWidth, window.innerHeight)
renderer.setClearColor(0x000000, 1)
renderer.xr.enabled = true
renderer.xr.setReferenceSpaceType('local-floor')
renderer.xr.setFramebufferScaleFactor(1.5) // supersample above native panel res for sharpness (applies at session entry); AdaptiveQuality sheds particle count if the GPU can't keep up
renderer.xr.setFoveation(0) // zero foveation → full resolution edge-to-edge; AdaptiveQuality raises it only under real load
document.body.appendChild(renderer.domElement)
document.body.appendChild(VRButton.createButton(renderer))
// "Enter MR" — immersive-ar passthrough; the flame floats in the real room. The
// button hides itself on devices without immersive-ar, so the VR path is untouched.
document.body.appendChild(createMRButton(renderer))

// --- scenes -----------------------------------------------------------------
const pointsScene = new Scene()
const overlayScene = new Scene()
overlayScene.add(new HemisphereLight(0xbbbbff, 0x080820, 1.2))

const grid = new GridHelper(10, 20, 0x224466, 0x0e1a2a)
const gridMat = grid.material as Material
gridMat.transparent = true
gridMat.opacity = 0.18
overlayScene.add(grid)

// --- flame engine -----------------------------------------------------------
const SIZE = 1536 // 2,359,296 particles (AdaptiveQuality backstops the draw count)
const initial = GALLERY[0]
const palette = new Palette(initial.palette)

const sim = new Simulation(SIZE)
sim.setParams({ iterations: 4, reseedProb: 0.0015 })

const flamePoints = new FlamePoints(SIZE, palette.texture, initial.pointBrightness)

const flameGroup = new Group()
flameGroup.position.set(0, 1.5, -2.3)
flameGroup.scale.setScalar(0.16) // far zoomed-out default (denser per pixel = smoother); grab-scale to fly in
flameGroup.add(flamePoints.points)
pointsScene.add(flameGroup)

const compositor = new Compositor({
  exposure: initial.brightness,
  gamma: initial.gamma,
  k2: initial.k2,
  hiDesat: initial.highlightDesat,
})

// --- mixed-reality (immersive-ar passthrough) -------------------------------
// `sessionIsAR` is true only while the live session reports a passthrough blend
// mode. `passthroughOn` is the in-session toggle; an AR session now opens straight
// into passthrough (room visible) so "Enter MR" goes directly to mixed reality, while
// VR stays in the black void. The PASSTHRU cell still flips room/void mid-session.
// `applyEnvMode` is the single source of truth: it drives the GL clear-alpha, the
// tonemap shader branch, and the fake-floor grid's visibility together.
let sessionIsAR = false
let passthroughOn = false

function applyEnvMode(): void {
  const reveal = sessionIsAR && passthroughOn
  // reveal → clear transparent so untouched pixels show the real room;
  // otherwise → opaque black, exactly as the VR path has always cleared.
  renderer.setClearColor(0x000000, reveal ? 0 : 1)
  compositor.setPassthrough(reveal ? 1 : 0)
  grid.visible = !reveal // the fake floor grid would float in your real room — hide it
}

const togglePassthrough = (): void => {
  if (!sessionIsAR) return // inert in VR — passthrough only exists in an immersive-ar session
  passthroughOn = !passthroughOn
  applyEnvMode()
}

renderer.xr.addEventListener('sessionstart', () => {
  sessionIsAR = renderer.xr.getEnvironmentBlendMode() === 'alpha-blend'
  passthroughOn = sessionIsAR // AR → straight to passthrough (mixed); VR → void
  applyEnvMode()
})
renderer.xr.addEventListener('sessionend', () => {
  sessionIsAR = false
  passthroughOn = false
  applyEnvMode()
})

// --- cameras ----------------------------------------------------------------
const rigCamera = new PerspectiveCamera(70, window.innerWidth / window.innerHeight, 0.05, 200)
const desktopCamera = new PerspectiveCamera(60, window.innerWidth / window.innerHeight, 0.05, 200)
desktopCamera.position.set(0, 1.5, -0.7)
const controls = new OrbitControls(desktopCamera, renderer.domElement)
controls.target.copy(flameGroup.position)
controls.enableDamping = true
controls.update()

// --- controllers ------------------------------------------------------------
const controllerModelFactory = new XRControllerModelFactory()
const controllers: Group[] = []
const rays: Line[] = []
for (const i of [0, 1]) {
  const controller = renderer.xr.getController(i)
  overlayScene.add(controller)
  controllers.push(controller)

  const grip = renderer.xr.getControllerGrip(i)
  grip.add(controllerModelFactory.createControllerModel(grip))
  overlayScene.add(grip)

  const rayGeo = new BufferGeometry().setFromPoints([new Vector3(0, 0, 0), new Vector3(0, 0, -1)])
  const ray = new Line(rayGeo, new LineBasicMaterial({ color: 0x88aaff, transparent: true, opacity: 0.5 }))
  ray.scale.z = 5
  controller.add(ray)
  rays.push(ray)
}

const worldGrab = new WorldGrab(controllers, flameGroup)

// --- create loop: breed + morph --------------------------------------------
const label = document.createElement('div')
label.id = 'flame-label'
document.body.appendChild(label)

let morphDuration = 2.5 // seconds for one flame to melt into the next (user-adjustable)
let fromGenome: FlameGenome = initial
let toGenome: FlameGenome = initial
let prevTarget: FlameGenome = initial
let morphT = 1 // 1 = settled on toGenome
let autoGenerate = false // infinite-generation ambient mode
let serial = 1

function applyGenome(g: FlameGenome): void {
  sim.setGenome(encodeFlame(g))
  palette.setColors(g.palette)
  flamePoints.setBrightness(g.pointBrightness)
  compositor.setToneParams({ exposure: g.brightness, gamma: g.gamma, k2: g.k2, hiDesat: g.highlightDesat })
}

function updateLabel(): void {
  if (sim.mode === 'bulb') {
    label.textContent = `${currentBulb.name}   ◆ bulb${bulbMorphT < 1 ? '  …morphing' : ''}${autoGenerate ? '   ▶ auto' : ''}`
    return
  }
  label.textContent = `${toGenome.name}${morphT < 1 ? '  …morphing' : ''}${autoGenerate ? '   ▶ auto' : ''}`
}

/** Begin morphing toward an arbitrary genome (gallery, random, mutant, hybrid). */
function startMorphTo(g: FlameGenome): void {
  // snapshot the currently-displayed (possibly mid-morph) genome as the source
  fromGenome = morphT < 1 ? interpolateGenome(fromGenome, toGenome, smoothstep(morphT)) : toGenome
  prevTarget = toGenome
  toGenome = g
  morphT = 0
  updateLabel()
}

function stepMorph(dtSec: number): void {
  if (sim.mode === 'bulb') return // bulb mode runs its own morph driver (stepBulbMorph)
  if (morphT >= 1) {
    if (!autoGenerate) return
    startMorphTo(randomGenome(serial++)) // auto: keep birthing new flames
  }
  morphT = Math.min(1, morphT + dtSec / morphDuration)
  applyGenome(interpolateGenome(fromGenome, toGenome, smoothstep(morphT)))
  if (morphT >= 1) {
    fromGenome = toGenome
    updateLabel()
  }
}

// breeding actions — in bulb mode they morph the cloud toward a new / varied bulb
const randomize = (): void => {
  // bulb: keep the current formula half the time so randomise melts (same family) more often
  // than it reseed-jumps to a different type; the other half gives a genuinely new formula
  if (sim.mode === 'bulb') startBulbMorphTo(randomBulb(Math.random() < 0.5 ? currentBulb.formula : undefined))
  else startMorphTo(randomGenome(serial++))
}
const mutateCurrent = (): void => {
  if (sim.mode === 'bulb') startBulbMorphTo(mutateBulb(currentBulb))
  else startMorphTo(mutate(toGenome, serial++))
}
const breed = (): void => {
  if (sim.mode === 'bulb') startBulbMorphTo(flipBulbKind(currentBulb)) // Mandelbulb ⇄ Juliabulb
  else startMorphTo(crossover(toGenome, prevTarget, serial++))
}
const toggleAuto = (): void => {
  autoGenerate = !autoGenerate
  updateLabel()
}
// recolor: apply the next curated theme to the current flame (structure unchanged, colours morph)
let themeIndex = -1
const recolor = (dir = 1): void => {
  themeIndex = (themeIndex + dir + THEMES.length) % THEMES.length
  const pal = themeColors(THEMES[themeIndex].name)
  // recolor toward the morph DESTINATION (bulbTo / toGenome), not the frozen mid-morph
  // value — so changing colour mid-morph keeps heading to the shape you were going to.
  if (sim.mode === 'bulb') startBulbMorphTo({ ...bulbTo, palette: pal })
  else startMorphTo({ ...toGenome, palette: pal })
}

// favorites — persisted to localStorage, survive across sessions
const cloneGenome = (g: FlameGenome): FlameGenome => JSON.parse(JSON.stringify(g)) as FlameGenome
let favorites = loadFavorites()
let faveIndex = -1
const saveFavorite = (): void => {
  favorites.push(cloneGenome(toGenome))
  faveIndex = favorites.length - 1 // the just-saved flame is now "current" so Delete targets it, not a stale prior load
  persistFavorites(favorites)
}
const loadFave = (): void => {
  if (favorites.length === 0) return
  faveIndex = (faveIndex + 1) % favorites.length
  startMorphTo(cloneGenome(favorites[faveIndex]))
}
// delete the favourite you most recently loaded with Faves (recoverable — just re-Save)
const deleteFave = (): void => {
  if (faveIndex < 0 || faveIndex >= favorites.length) return
  favorites.splice(faveIndex, 1)
  persistFavorites(favorites)
  faveIndex-- // so the next Faves press lands on the item that shifted into this slot
}

// --- bulb mode (Mandelbulb point cloud) -------------------------------------
let bulbTime = 0 // drives the living-bulb breath (power breath / Julia-C orbit), runs continuously
const bulbC = new Vector3()
let currentBulb: BulbGenome = BULB_GALLERY[0] // the bulb currently displayed (mid-morph: an interpolated one)
// bulb-to-bulb morph state — the parametric analog of fromGenome/toGenome/morphT
let bulbFrom: BulbGenome = BULB_GALLERY[0]
let bulbTo: BulbGenome = BULB_GALLERY[0]
let bulbMorphT = 1 // 1 = settled on bulbTo
let bulbFraming = 1 // the per-bulb apparent-size factor currently baked into flameGroup.scale,
// kept separate so re-framing on mutate/randomise adjusts by RATIO and preserves the user's grab-scale

/** Snap instantly to a bulb (used on mode-switch / init — no transition). */
const applyBulb = (b: BulbGenome): void => {
  currentBulb = b
  bulbFrom = b
  bulbTo = b
  bulbMorphT = 1
  palette.setColors(b.palette) // bulbs share the flame palettes
  bulbTime = 0
  // mode-entry / init: snap to the framing default (a clean view; resets any prior grab)
  bulbFraming = 0.65 / b.bound // normalise apparent size across bulb / box
  flameGroup.scale.setScalar(bulbFraming)
  updateLabel()
}

/** Begin morphing the cloud toward a new bulb — the bulb analog of startMorphTo. */
function startBulbMorphTo(b: BulbGenome): void {
  // snapshot the currently-displayed (possibly mid-morph) bulb as the source
  bulbFrom = bulbMorphT < 1 ? interpolateBulb(bulbFrom, bulbTo, smoothstep(bulbMorphT)) : currentBulb
  bulbTo = b
  bulbMorphT = 0
  // a discrete formula switch (bulb⇄box) can't be melted — reform the cloud onto the new surface;
  // interpolateBulb then crossfades only the palette while the points re-relax
  if (bulbFrom.formula !== b.formula) sim.seed(renderer)
  // NB: bulbTime is NOT reset — the breath phase stays continuous across the morph
  updateLabel()
}

// auto-cycle: mostly mutate within the family (smooth melt); when it does pull a fresh random
// bulb, usually keep the formula — so the continuous flow rarely reseed-jumps between types
const nextAutoBulb = (): BulbGenome =>
  Math.random() < 0.75 ? mutateBulb(currentBulb) : randomBulb(Math.random() < 0.6 ? currentBulb.formula : undefined)

/** Advance the bulb morph + drive the living breath, writing the live DE uniforms. */
function stepBulbMorph(dtSec: number): void {
  const wasMorphing = bulbMorphT < 1
  // auto-cycle: when settled, start the next bulb NOW so this same frame advances it — mirrors the
  // flame stepMorph (no one-frame stall at the cycle boundary)
  if (!wasMorphing && autoGenerate) startBulbMorphTo(nextAutoBulb()) // sets bulbMorphT=0
  if (bulbMorphT < 1) bulbMorphT = Math.min(1, bulbMorphT + dtSec / morphDuration)

  const disp = bulbMorphT < 1 ? interpolateBulb(bulbFrom, bulbTo, smoothstep(bulbMorphT)) : bulbTo
  currentBulb = disp
  // re-apply framing + palette only while in motion (or on the frame we just landed) —
  // a settled bulb leaves them untouched, so no per-frame texture upload while idle
  if (bulbMorphT < 1 || wasMorphing) {
    // same-formula morphs already lerp bound inside interpolateBulb; a cross-formula morph snaps the
    // DE bound to the target (the cloud reseeds onto the new surface), so ease the FRAMING (apparent
    // size) independently — otherwise the group scale pops 3-4× on the morph-start frame.
    const framingBound =
      bulbFrom.formula === bulbTo.formula
        ? disp.bound
        : bulbFrom.bound + (bulbTo.bound - bulbFrom.bound) * smoothstep(bulbMorphT)
    // apply the framing as a RATIO against what's already there, so the user's grab-scale survives
    // a mutate/randomise (same bound → ratio 1 → no jump; new bound → proportional, not a reset).
    const framing = 0.65 / framingBound
    flameGroup.scale.multiplyScalar(framing / bulbFraming)
    bulbFraming = framing
    palette.setColors(disp.palette)
    if (wasMorphing && bulbMorphT >= 1) updateLabel() // drop the "…morphing" tag
  }

  // living breath on top of the (possibly morphing) base params
  const t = bulbTime * disp.speed
  if (disp.formula === 'kifs') {
    // breathe the two fold angles in quadrature — the kaleidoscope slowly turns
    sim.setBulbParams({
      formula: 'kifs',
      scale: disp.scale,
      fixedR: disp.fixedR,
      bound: disp.bound,
      juliaC: bulbC.set(disp.juliaC[0], disp.juliaC[1], disp.juliaC[2]),
      kAngleA: disp.kAngleA + disp.kAngleBreath * Math.sin(t),
      kAngleB: disp.kAngleB + disp.kAngleBreath * Math.cos(t * 0.7),
    })
  } else if (disp.formula === 'mandelbox') {
    sim.setBulbParams({
      formula: 'mandelbox',
      scale: disp.scale + disp.scaleBreath * Math.sin(t),
      minR: disp.minR,
      fixedR: disp.fixedR,
      bound: disp.bound,
      mandelbulb: disp.mandelbulb,
      juliaC: bulbC.set(disp.juliaC[0], disp.juliaC[1], disp.juliaC[2]),
    })
  } else if (disp.formula === 'quat') {
    // quaternion Julia breathes by orbiting its c constant (the form selector)
    bulbC.set(
      disp.juliaC[0] + disp.juliaOrbit * Math.sin(t),
      disp.juliaC[1] + disp.juliaOrbit * Math.cos(t * 0.8),
      disp.juliaC[2] + disp.juliaOrbit * Math.sin(t * 0.6),
    )
    sim.setBulbParams({ formula: 'quat', juliaC: bulbC, mandelbulb: disp.mandelbulb, bound: disp.bound })
  } else {
    const p = disp.power + disp.powerBreath * Math.sin(t)
    bulbC.set(
      disp.juliaC[0] + disp.juliaOrbit * Math.sin(t),
      disp.juliaC[1] + disp.juliaOrbit * Math.cos(t * 0.8),
      disp.juliaC[2] + disp.juliaOrbit * Math.sin(t * 0.6),
    )
    sim.setBulbParams({ formula: 'mandelbulb', power: p, juliaC: bulbC, mandelbulb: disp.mandelbulb, bound: disp.bound })
  }
}

const setMode = (m: 'flame' | 'bulb'): void => {
  sim.setMode(m)
  sim.setActiveTexels(activeCount) // scissor the (heavy) bulb sim to the drawn count
  sim.seed(renderer) // re-scatter particles into the new attractor
  // re-arm the freeze window: the re-seeded random scatter needs its SETTLE_TAIL frames of chaos
  // game to converge onto the attractor. Without this, returning to a flame that had already
  // settled (settleFrames ≫ tail, morphT == 1) leaves the fresh scatter frozen as a raw blob.
  settleFrames = 0
  if (m === 'bulb') {
    applyBulb(bulbMorphT < 1 ? bulbTo : currentBulb) // settle on the morph target, not a frozen midpoint
  } else {
    applyGenome(toGenome)
    flameGroup.scale.setScalar(0.16)
  }
  updateLabel()
}
const toggleMode = (): void => setMode(sim.mode === 'bulb' ? 'flame' : 'bulb')

// --- live settings (cycled from the menu) -----------------------------------
const PARTICLE_STEPS = [0.3, 0.5, 0.7, 0.85, 1.0]
const SIZE_STEPS = [1.0, 1.5, 2.0, 2.5, 3.0, 4.0]
const MORPH_STEPS = [0.8, 1.5, 2.5, 4.0, 7.0]
const SPIN_STEPS = [0, 0.03, 0.06, 0.12, 0.25]
const SPIN_LABELS = ['Off', 'Slow', 'Med', 'Fast', 'Spin']
const SPLAT_STEPS = [1, 0.75, 0.5] // splat-target resolution fractions (overdraw lever)
const SPLAT_LABELS = ['Full', '¾', '½']
// honour prefers-reduced-motion: start with no ambient auto-rotation (the user can re-enable
// spin from the menu). The flame already freezes when settled, so this leaves it still at rest.
const reduceMotion = window.matchMedia?.('(prefers-reduced-motion: reduce)').matches ?? false
let pIdx = 0 // default 0.3 ≈ 708K particles — the sweet spot for clarity at size 1
let sIdx = 0 // default size 1.0 (smallest points)
let mIdx = 2
let spinIdx = reduceMotion ? 0 : 2
let userCount = Math.floor(sim.count * PARTICLE_STEPS[pIdx]) // user-set ceiling
let activeCount = userCount // currently drawn (the thermal guard may dip below this)
let pointSize = SIZE_STEPS[sIdx]
let rotationSpeed = SPIN_STEPS[spinIdx]
let splatIdx = 0 // index into SPLAT_STEPS (Full by default)
let splatScale = SPLAT_STEPS[splatIdx] // splat-target resolution fraction (1 = full; <1 = cheaper additive fill, upscaled by the tone-map). Menu cycler + console lever.
let perfLine = '' // live fps / particle-load / foveation readout for the menu (updated each frame)
const next = (i: number, len: number): number => (i + 1) % len
const fmtCount = (n: number): string => (n >= 1e6 ? `${(n / 1e6).toFixed(1)}M` : `${Math.round(n / 1e3)}k`)
const cycleParticles = (): void => {
  pIdx = next(pIdx, PARTICLE_STEPS.length)
  userCount = Math.floor(sim.count * PARTICLE_STEPS[pIdx])
  activeCount = userCount
  flamePoints.setActiveCount(activeCount)
  sim.setActiveTexels(activeCount)
}
const cycleSize = (): void => {
  sIdx = next(sIdx, SIZE_STEPS.length)
  pointSize = SIZE_STEPS[sIdx]
  flamePoints.setPointSize(pointSize)
}
const cycleMorph = (): void => {
  mIdx = next(mIdx, MORPH_STEPS.length)
  morphDuration = MORPH_STEPS[mIdx]
}
// thumbstick morph-speed nudge — clamped (no wrap), faster = shorter duration = lower index
const setMorphSpeed = (faster: boolean): void => {
  mIdx = Math.max(0, Math.min(MORPH_STEPS.length - 1, mIdx + (faster ? -1 : 1)))
  morphDuration = MORPH_STEPS[mIdx]
}
const cycleAnimation = (): void => {
  spinIdx = next(spinIdx, SPIN_STEPS.length)
  rotationSpeed = SPIN_STEPS[spinIdx]
}
const cycleSplat = (): void => {
  splatIdx = next(splatIdx, SPLAT_STEPS.length)
  splatScale = SPLAT_STEPS[splatIdx]
}
// preset cycling for the closed-menu left-stick shortcut — steps through the active gallery
let presetIdx = 0
const cyclePreset = (dir: number): void => {
  if (sim.mode === 'bulb') {
    presetIdx = (presetIdx + dir + BULB_GALLERY.length) % BULB_GALLERY.length
    startBulbMorphTo(BULB_GALLERY[presetIdx])
  } else {
    presetIdx = (presetIdx + dir + GALLERY.length) % GALLERY.length
    startMorphTo(GALLERY[presetIdx])
  }
}
const exitVR = (): void => {
  renderer.xr.getSession()?.end().catch(() => {})
}
flamePoints.setActiveCount(activeCount)
sim.setActiveTexels(activeCount)
flamePoints.setPointSize(pointSize)

// in-VR controls guide — a "what the buttons do" card that pops in front of you on
// session start (and reopens from the menu's HELP cell); dismisses on first grab/press.
const guide = new ControlsGuide(() => toGenome.palette[toGenome.palette.length - 1])
overlayScene.add(guide.root)
// show it every time someone enters (not first-run-only) — the same headset is handed
// to a stream of newcomers; a quick grab/press makes it vanish for the experienced user.
renderer.xr.addEventListener('sessionstart', () => window.setTimeout(() => guide.show(), 600))

// in-VR wrist menu (left controller), driven by ray-point + trigger (and thumbstick)
const menu = new WristMenu(
  controllers[0],
  () => ({
    name: sim.mode === 'bulb' ? currentBulb.name : toGenome.name,
    mode: sim.mode === 'bulb' ? 'BULB' : 'FLAME',
    morphing: sim.mode === 'bulb' ? bulbMorphT < 1 : morphT < 1,
    auto: autoGenerate,
    passthrough: passthroughOn,
    arAvailable: sessionIsAR,
    accent: toGenome.palette[toGenome.palette.length - 1],
    currentPreset: sim.mode === 'bulb' ? BULB_GALLERY.indexOf(currentBulb) : GALLERY.indexOf(toGenome),
    particles: fmtCount(userCount),
    size: pointSize.toFixed(1),
    splat: SPLAT_LABELS[splatIdx],
    morph: `${morphDuration.toFixed(1)}s`,
    animation: SPIN_LABELS[spinIdx],
    saved: `${favorites.length} saved`,
    faves: favorites.length ? `load (${favorites.length})` : 'none yet',
    perf: perfLine,
  }),
  {
    randomize,
    mutateCurrent,
    breed,
    toggleMode,
    toggleAuto,
    recolor,
    morphToPreset: (i) => {
      if (sim.mode === 'bulb') setMode('flame') // picking a flame preset leaves bulb mode
      presetIdx = i // keep the stick shortcut in sync
      startMorphTo(GALLERY[i])
    },
    morphToBulbPreset: (i) => {
      presetIdx = i
      startBulbMorphTo(BULB_GALLERY[i])
    }, // bulb-gallery chip (bulb mode only)
    saveFavorite,
    loadFave,
    deleteFave,
    cycleParticles,
    cycleSize,
    cycleSplat,
    cycleMorph,
    cycleAnimation,
    togglePassthrough,
    showGuide: () => guide.show(),
    exitVR,
  },
  () => worldGrab.gripCount >= 2,
  GALLERY.map((g) => g.name),
  BULB_GALLERY.map((b) => b.name),
)

applyGenome(initial)
updateLabel()

// hand roles: menu on the off-hand (left), pointer on the dominant (right).
// Pinned by handedness on 'connected'; sensible defaults until then.
type Evented = { addEventListener: (t: string, f: (e: { data?: XRInputSource }) => void) => void }
let menuHand = 0
let pointerHand = 1

// trigger: on the pointer hand → commit the menu if aimed at it, else randomize;
// on the menu hand → mutate.
controllers.forEach((c, i) => {
  ;(c as unknown as Evented).addEventListener('selectstart', () => {
    guide.hide() // any trigger pull dismisses the controls card
    if (i === pointerHand) {
      if (menu.hovered) menu.click()
      else randomize()
    } else {
      mutateCurrent()
    }
  })
})

// desktop keys: r=randomize, e=mutate, b=breed, a=auto, 1-9=gallery presets
window.addEventListener('keydown', (e) => {
  const k = e.key
  let hit = true
  if (k === 'r') randomize()
  else if (k === 'e') mutateCurrent()
  else if (k === 'b') breed()
  else if (k === 'a') toggleAuto()
  else if (k === 'm') toggleMode()
  else if (k >= '1' && k <= '9') {
    const i = Number(k) - 1
    if (i < GALLERY.length) startMorphTo(GALLERY[i])
  } else hit = false
  // once they've used a control, fade the on-screen hint back so it's not in the way
  if (hit) document.getElementById('desk-controls')?.classList.add('used')
})

// headset face buttons: A/X (4) = toggle auto-generate, B/Y (5) = cross-breed
const inputSources: (XRInputSource | null)[] = [null, null]
controllers.forEach((c, i) => {
  ;(c as unknown as Evented).addEventListener('connected', (e) => {
    inputSources[i] = e.data ?? null
    const hand = e.data?.handedness
    if (hand === 'left' || hand === 'right') {
      menuHand = hand === 'left' ? i : i === 0 ? 1 : 0
      pointerHand = menuHand === 0 ? 1 : 0
      menu.attachTo(controllers[menuHand]) // pin the slate to the left hand
    }
  })
  ;(c as unknown as Evented).addEventListener('disconnected', () => (inputSources[i] = null))
})
let aWasDown = false
let bWasDown = false
let stickArmed = true
let stickClickWas = false
let adjArmed = true // pointer-hand stick debounce (palette / morph-speed nudges)
const menuBtnPrev: boolean[] = [] // previous pressed-state per unmapped button index (menu-button detection)
let menuBtnInit = false // skip firing on the very first poll so a stuck/phantom button can't auto-open
function pollButtons(): void {
  const a = inputSources.some((s) => s?.gamepad?.buttons[4]?.pressed === true)
  const b = inputSources.some((s) => s?.gamepad?.buttons[5]?.pressed === true)
  if (a && !aWasDown) toggleAuto()
  if (b && !bWasDown) breed()
  aWasDown = a
  bWasDown = b

  // left controller's dedicated Menu (☰) button toggles the slate open/closed. Its
  // gamepad index isn't standardised across runtimes, so we watch every button beyond
  // the ones we already use — 0 trigger, 1 grip, 3 thumbstick, 4 X, 5 Y, 6 thumbrest —
  // and fire on a genuine released→pressed transition of any other index. Per-index edge
  // detection means a phantom always-pressed button never transitions, so it's ignored.
  const menuPad = inputSources[menuHand]?.gamepad
  if (menuPad) {
    for (let i = 2; i < menuPad.buttons.length; i++) {
      if (i === 3 || i === 4 || i === 5 || i === 6) continue
      const pressed = menuPad.buttons[i]?.pressed === true
      if (pressed && !menuBtnPrev[i] && menuBtnInit) {
        guide.hide() // ☰ also dismisses the controls card
        if (menu.isOpen) menu.collapse()
        else menu.expand()
      }
      menuBtnPrev[i] = pressed
    }
    menuBtnInit = true
  }

  // menu-hand thumbstick + click drives the wrist menu cursor (follow handedness, like the
  // menu-button and pointer-tweak blocks — don't assume the left controller is index 0)
  const lpad = inputSources[menuHand]?.gamepad
  if (lpad) {
    let ax = lpad.axes[2] ?? 0
    let ay = lpad.axes[3] ?? 0
    if (Math.abs(ax) < 0.15 && Math.abs(ay) < 0.15) {
      ax = lpad.axes[0] ?? 0
      ay = lpad.axes[1] ?? 0
    }
    if (stickArmed && (Math.abs(ax) > 0.5 || Math.abs(ay) > 0.5)) {
      if (menu.isOpen) {
        // open menu: navigate the cursor grid
        if (Math.abs(ax) > Math.abs(ay)) menu.moveCursor(ax > 0 ? 1 : -1, 0)
        else menu.moveCursor(0, ay > 0 ? 1 : -1)
      } else {
        // closed menu: quick shortcut — L/R cycles presets, up = flame / down = bulb
        if (Math.abs(ax) > Math.abs(ay)) cyclePreset(ax > 0 ? 1 : -1)
        else if (ay < 0 && sim.mode === 'bulb') toggleMode()
        else if (ay > 0 && sim.mode === 'flame') toggleMode()
      }
      stickArmed = false
      ;(lpad as unknown as { hapticActuators?: { pulse?: (a: number, b: number) => void }[] }).hapticActuators?.[0]?.pulse?.(0.3, 15)
    }
    if (Math.abs(ax) < 0.3 && Math.abs(ay) < 0.3) stickArmed = true

    const click = lpad.buttons[3]?.pressed === true
    if (click && !stickClickWas) menu.click()
    stickClickWas = click
  }

  // pointer-hand thumbstick — quick tweaks any time: left/right = previous/next palette,
  // up/down = faster/slower morph. It's the OTHER stick from the menu cursor nav (which is
  // on the menu hand), so the two never fight even with the menu open.
  const ppad = inputSources[pointerHand]?.gamepad
  if (ppad) {
    let ax = ppad.axes[2] ?? 0
    let ay = ppad.axes[3] ?? 0
    if (Math.abs(ax) < 0.15 && Math.abs(ay) < 0.15) {
      ax = ppad.axes[0] ?? 0
      ay = ppad.axes[1] ?? 0
    }
    if (adjArmed && (Math.abs(ax) > 0.6 || Math.abs(ay) > 0.6)) {
      if (Math.abs(ax) > Math.abs(ay)) recolor(ax > 0 ? 1 : -1) // L/R: step palette (colour)
      else setMorphSpeed(ay < 0) // up = faster morph, down = slower
      adjArmed = false
      ;(ppad as unknown as { hapticActuators?: { pulse?: (a: number, b: number) => void }[] }).hapticActuators?.[0]?.pulse?.(0.3, 15)
    }
    if (Math.abs(ax) < 0.35 && Math.abs(ay) < 0.35) adjArmed = true
  }
}

// --- adaptive quality -------------------------------------------------------
const adaptive = new AdaptiveQuality(
  {
    minCount: Math.floor(sim.count * 0.2),
    getMaxCount: () => userCount, // never exceed the user's particle setting
    getCount: () => activeCount,
    setCount: (n) => {
      activeCount = n
      flamePoints.setActiveCount(n)
      sim.setActiveTexels(n) // shedding particles now also sheds the bulb's heavy sim cost
    },
    setFoveation: (f) => renderer.xr.setFoveation(f),
  },
  72,
)

// refresh rate when a session starts. This app trades refresh for particle DENSITY — a higher
// refresh shrinks the frame budget and forces the adaptive guard to shed particles to keep up.
// 72Hz is the comfortable VR floor and gives the largest budget, so the cloud stays fullest.
renderer.xr.addEventListener('sessionstart', () => {
  const session = renderer.xr.getSession()
  const rates = session?.supportedFrameRates
  if (session && rates && rates.length) {
    const target = rates.includes(72) ? 72 : Math.min(...rates)
    session.updateTargetFrameRate?.(target).catch(() => {})
    adaptive.setTargetHz(target) // adapt against the rate we actually run at
  }
})

// --- render loop ------------------------------------------------------------
const fbSize = new Vector2()
const menuRayOrigin = new Vector3()
const menuRayDir = new Vector3()
let frame = 0
let settleFrames = 0
const SETTLE_TAIL = 45 // keep simulating briefly after a morph settles, then freeze
let last = performance.now()

function getRenderSize(out: Vector2): Vector2 {
  const session = renderer.xr.getSession()
  if (renderer.xr.isPresenting && session?.renderState.baseLayer) {
    const bl = session.renderState.baseLayer
    return out.set(bl.framebufferWidth, bl.framebufferHeight)
  }
  return renderer.getDrawingBufferSize(out)
}

// per-pass GPU timing (sim / splat / tone) so quality tuning is measured, not guessed. No-ops if
// the EXT_disjoint_timer_query extension is unavailable (common in a WebXR session).
const gpuTimer = new GpuTimer(renderer.getContext() as WebGL2RenderingContext)

// half-res splat support: scale the XR ArrayCamera's per-eye viewports so the stereo eyes land
// in their (scaled) halves of the sub-res HDR target, then restore them for the full-res tone-map.
function scaleXrViewports(s: number): Vector4[] {
  const cams = renderer.xr.getCamera().cameras
  const saved = cams.map((c) => c.viewport.clone())
  for (const c of cams) c.viewport.multiplyScalar(s)
  return saved
}
function restoreXrViewports(saved: Vector4[]): void {
  const cams = renderer.xr.getCamera().cameras
  cams.forEach((c, i) => c.viewport.copy(saved[i]))
}

renderer.setAnimationLoop(() => {
  const now = performance.now()
  const dtMs = now - last
  last = now
  gpuTimer.poll() // harvest GPU times from earlier frames (results come back a few frames late)
  frame++

  // fresh controller world matrices for the grab math
  overlayScene.updateMatrixWorld(true)
  worldGrab.update()
  menu.update(dtMs / 1000)
  guide.update(dtMs / 1000, renderer.xr.isPresenting ? renderer.xr.getCamera() : desktopCamera)
  if (guide.visible && worldGrab.gripCount > 0) guide.hide() // grabbing the flame means "I've got it"

  // gentle auto-rotation gives life without per-frame particle flicker (paused while grabbing)
  if (!worldGrab.isGrabbing && rotationSpeed > 0) flameGroup.rotateY((dtMs / 1000) * rotationSpeed)

  // laser-pointer hover for the menu (point the dominant hand at it; trigger commits)
  menuRayOrigin.setFromMatrixPosition(controllers[pointerHand].matrixWorld)
  menuRayDir.set(0, 0, -1).transformDirection(controllers[pointerHand].matrixWorld)
  const onMenu = menu.pointerTest(menuRayOrigin, menuRayDir)
  rays[pointerHand].scale.z = onMenu ? menu.hitDistance : 5
  rays[menuHand].scale.z = 5

  // breeding buttons + morph the genome toward the target (auto-generate if enabled)
  pollButtons()
  stepMorph(dtMs / 1000)

  // living bulb: morph the cloud toward the target bulb (param melt — the bulb's analog of
  // the flame morph) and breathe on top. The cloud re-relaxes every frame so it chases the
  // continuously deforming isosurface; auto-cycle keeps birthing new bulbs.
  if (sim.mode === 'bulb') {
    bulbTime += dtMs / 1000
    stepBulbMorph(dtMs / 1000)
  }

  // 1. simulate — only while morphing (or briefly after), then FREEZE so the settled
  // cloud is stable: no per-frame chaos-game reshuffle = no distracting edge flicker.
  if (morphT < 1) settleFrames = 0
  else settleFrames++
  // bulb mode re-relaxes every frame (the cloud chases the live isosurface); flames freeze once settled
  if (sim.mode === 'bulb' || morphT < 1 || settleFrames <= SETTLE_TAIL) {
    gpuTimer.begin('sim')
    sim.update(renderer, frame)
    gpuTimer.end()
    flamePoints.setStateTexture(sim.stateTexture)
  }

  const xrRT = renderer.getRenderTarget() // XR framebuffer while presenting, else null (canvas)
  getRenderSize(fbSize)
  compositor.ensureSize(fbSize.x, fbSize.y, splatScale)

  const presenting = renderer.xr.isPresenting
  const cam = presenting ? rigCamera : desktopCamera
  if (!presenting) controls.update()

  // 2. accumulate point splats into the HDR target (per eye while presenting).
  //    At splatScale < 1 the HDR target is sub-res; shrink the XR per-eye viewports to match
  //    so each eye still lands in its half (desktop's single camera needs none of this — three
  //    uses the smaller target's full extent). Restored straight after so the tone-map is full-res.
  renderer.setRenderTarget(compositor.hdrRT)
  renderer.clear(true, true, true)
  renderer.autoClear = false
  const savedViewports = presenting && splatScale !== 1 ? scaleXrViewports(splatScale) : null
  gpuTimer.begin('splat')
  renderer.render(pointsScene, cam)
  gpuTimer.end()
  if (savedViewports) restoreXrViewports(savedViewports)

  // 3. log-density tone-map into the XR framebuffer / canvas (per eye). In MR
  //    passthrough mode applyEnvMode has set clear-alpha to 0 and uPassthrough to 1,
  //    so untouched pixels stay transparent and reveal the room; in VR / AR-void it
  //    clears opaque black and writes alpha 1, identical to before.
  renderer.setRenderTarget(xrRT)
  renderer.clear(true, true, true)
  gpuTimer.begin('tone')
  compositor.tonemap(renderer, xrRT)
  gpuTimer.end()

  // 4. overlay (controllers / grid) in LDR over the flame
  renderer.render(overlayScene, cam)
  renderer.autoClear = true

  adaptive.update(dtMs)

  // headroom readout (bucketed so the menu only repaints a few times/sec): if fps is
  // pinned at the refresh rate with drawn==ceiling and fov 0, there's room for more
  // resolution; if particles are being shed (drawn < ceiling) or fov has climbed, we're
  // at the GPU limit. Only meaningful while presenting.
  const fps = adaptive.frameMs > 0 ? Math.round(1000 / adaptive.frameMs) : 0
  perfLine = `${fps} fps · ${fmtCount(activeCount)}/${fmtCount(userCount)} · fov ${adaptive.currentFoveation.toFixed(2)}${gpuTimer.hud()}`
})

// --- resize -----------------------------------------------------------------
window.addEventListener('resize', () => {
  desktopCamera.aspect = window.innerWidth / window.innerHeight
  desktopCamera.updateProjectionMatrix()
  renderer.setSize(window.innerWidth, window.innerHeight)
})

// expose for live tinkering in the console
;(window as unknown as { fractal: unknown }).fractal = {
  renderer,
  sim,
  flamePoints,
  compositor,
  desktopCamera,
  controls,
  flameGroup,
  randomize,
  mutateCurrent,
  breed,
  toggleAuto,
  morphToPreset: (i: number) => startMorphTo(GALLERY[i]),
  gallery: GALLERY,
  menu,
  guide,
  overlayScene,
  controllers,
  // tuning/dev helpers: read the live genome, and set morph speed (for fast candidate harvesting)
  getGenome: () => JSON.parse(JSON.stringify(toGenome)) as FlameGenome,
  setMorph: (s: number) => {
    morphDuration = s
  },
  // EXPERIMENTAL: Mandelbulb point-cloud mode (swaps the chaos game for a bulb iterator)
  bulb: (on = true) => setMode(on ? 'bulb' : 'flame'),
  bulbPreset: (i: number) => {
    if (sim.mode !== 'bulb') setMode('bulb') // enter bulb mode (instant), then melt to the pick
    startBulbMorphTo(BULB_GALLERY[i])
  },
  // --- perf-pass instrumentation + live levers (for on-device A/B tuning) ---
  // measured per-pass GPU cost in ms (sim / splat / tone), or available:false in WebXR if the
  // timer-query extension is blocked there.
  gpu: () => ({
    available: gpuTimer.available,
    sim: +gpuTimer.ms('sim').toFixed(2),
    splat: +gpuTimer.ms('splat').toFixed(2),
    tone: +gpuTimer.ms('tone').toFixed(2),
    fps: adaptive.frameMs > 0 ? Math.round(1000 / adaptive.frameMs) : 0,
    drawn: activeCount,
  }),
  // supersample factor (default 1.5 = 2.25× pixels — the per-eye tone/composite pay it). Re-enter
  // VR to apply (framebufferScaleFactor is read only at session init).
  setScale: (x: number) => {
    renderer.xr.setFramebufferScaleFactor(x)
    return `framebufferScaleFactor=${x} — re-enter VR to apply`
  },
  setFoveation: (x: number) => renderer.xr.setFoveation(x), // 0..1, live
  setProjSteps: (n: number) => sim.setBulbParams({ projSteps: n }), // bulb DE Newton steps (cost), live
  setIterations: (n: number) => sim.setParams({ iterations: n, reseedProb: 0.0015 }), // flame chaos-game iters/frame
  // splat-target resolution fraction, live. <1 renders the additive glow into a sub-res HDR
  // target (¼ the fill at 0.5) that the tone-map upscales — the overdraw lever. The glow is
  // low-frequency so it softens rather than aliases; 0.5–0.8 is the range to A/B on-device.
  setSplatScale: (x: number) => {
    splatScale = Math.max(0.25, Math.min(1, x))
    // snap the menu cycler to the nearest labelled step so the SPLAT readout stays coherent
    splatIdx = SPLAT_STEPS.reduce((best, s, i) => (Math.abs(s - splatScale) < Math.abs(SPLAT_STEPS[best] - splatScale) ? i : best), 0)
    return `splatScale=${splatScale}`
  },
}
