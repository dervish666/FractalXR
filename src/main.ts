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
import { THEMES, themeColors } from './flame/palettes'
import { loadFavorites, persistFavorites } from './flame/favorites'
import { Simulation } from './engine/Simulation'
import { FlamePoints } from './engine/FlamePoints'
import { Compositor } from './engine/Compositor'
import { AdaptiveQuality } from './engine/AdaptiveQuality'
import { WorldGrab } from './xr/WorldGrab'
import { WristMenu } from './xr/WristMenu'
import { ControlsGuide } from './xr/ControlsGuide'
import { createMRButton } from './xr/MRButton'

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
// mode. `passthroughOn` is the in-session toggle and defaults OFF, so even an AR
// session opens in the familiar black void — the user opts into seeing the room.
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
  passthroughOn = false // every session starts in the void
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

// breeding actions — each result morphs in
const randomize = (): void => startMorphTo(randomGenome(serial++))
const mutateCurrent = (): void => startMorphTo(mutate(toGenome, serial++))
const breed = (): void => startMorphTo(crossover(toGenome, prevTarget, serial++))
const toggleAuto = (): void => {
  autoGenerate = !autoGenerate
  updateLabel()
}
// recolor: apply the next curated theme to the current flame (structure unchanged, colours morph)
let themeIndex = -1
const recolor = (): void => {
  themeIndex = (themeIndex + 1) % THEMES.length
  startMorphTo({ ...toGenome, palette: themeColors(THEMES[themeIndex].name) })
}

// favorites — persisted to localStorage, survive across sessions
const cloneGenome = (g: FlameGenome): FlameGenome => JSON.parse(JSON.stringify(g)) as FlameGenome
let favorites = loadFavorites()
let faveIndex = -1
const saveFavorite = (): void => {
  favorites.push(cloneGenome(toGenome))
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

// --- live settings (cycled from the menu) -----------------------------------
const PARTICLE_STEPS = [0.3, 0.5, 0.7, 0.85, 1.0]
const SIZE_STEPS = [1.0, 1.5, 2.0, 2.5, 3.0, 4.0]
const MORPH_STEPS = [0.8, 1.5, 2.5, 4.0, 7.0]
const SPIN_STEPS = [0, 0.03, 0.06, 0.12, 0.25]
const SPIN_LABELS = ['Off', 'Slow', 'Med', 'Fast', 'Spin']
let pIdx = 0 // default 0.3 ≈ 708K particles — the sweet spot for clarity at size 1
let sIdx = 0 // default size 1.0 (smallest points)
let mIdx = 2
let spinIdx = 2
let userCount = Math.floor(sim.count * PARTICLE_STEPS[pIdx]) // user-set ceiling
let activeCount = userCount // currently drawn (the thermal guard may dip below this)
let pointSize = SIZE_STEPS[sIdx]
let rotationSpeed = SPIN_STEPS[spinIdx]
let perfLine = '' // live fps / particle-load / foveation readout for the menu (updated each frame)
const next = (i: number, len: number): number => (i + 1) % len
const fmtCount = (n: number): string => (n >= 1e6 ? `${(n / 1e6).toFixed(1)}M` : `${Math.round(n / 1e3)}k`)
const cycleParticles = (): void => {
  pIdx = next(pIdx, PARTICLE_STEPS.length)
  userCount = Math.floor(sim.count * PARTICLE_STEPS[pIdx])
  activeCount = userCount
  flamePoints.setActiveCount(activeCount)
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
const cycleAnimation = (): void => {
  spinIdx = next(spinIdx, SPIN_STEPS.length)
  rotationSpeed = SPIN_STEPS[spinIdx]
}
const exitVR = (): void => {
  renderer.xr.getSession()?.end().catch(() => {})
}
flamePoints.setActiveCount(activeCount)
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
    name: toGenome.name,
    morphing: morphT < 1,
    auto: autoGenerate,
    passthrough: passthroughOn,
    arAvailable: sessionIsAR,
    accent: toGenome.palette[toGenome.palette.length - 1],
    currentPreset: GALLERY.indexOf(toGenome),
    particles: fmtCount(userCount),
    size: pointSize.toFixed(1),
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
    toggleAuto,
    recolor,
    morphToPreset: (i) => startMorphTo(GALLERY[i]),
    saveFavorite,
    loadFave,
    deleteFave,
    cycleParticles,
    cycleSize,
    cycleMorph,
    cycleAnimation,
    togglePassthrough,
    showGuide: () => guide.show(),
    exitVR,
  },
  () => worldGrab.gripCount >= 2,
  GALLERY.map((g) => g.name),
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

// desktop keys: r=randomize, e=mutate, b=breed, a=auto, 1-5=gallery presets
window.addEventListener('keydown', (e) => {
  if (e.key === 'r') randomize()
  else if (e.key === 'e') mutateCurrent()
  else if (e.key === 'b') breed()
  else if (e.key === 'a') toggleAuto()
  else if (e.key >= '1' && e.key <= '9') {
    const i = Number(e.key) - 1
    if (i < GALLERY.length) startMorphTo(GALLERY[i])
  }
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

  // left controller thumbstick + click drives the wrist menu
  const lpad = inputSources[0]?.gamepad
  if (lpad) {
    let ax = lpad.axes[2] ?? 0
    let ay = lpad.axes[3] ?? 0
    if (Math.abs(ax) < 0.15 && Math.abs(ay) < 0.15) {
      ax = lpad.axes[0] ?? 0
      ay = lpad.axes[1] ?? 0
    }
    if (stickArmed && (Math.abs(ax) > 0.5 || Math.abs(ay) > 0.5)) {
      if (Math.abs(ax) > Math.abs(ay)) menu.moveCursor(ax > 0 ? 1 : -1, 0)
      else menu.moveCursor(0, ay > 0 ? 1 : -1)
      stickArmed = false
      ;(lpad as unknown as { hapticActuators?: { pulse?: (a: number, b: number) => void }[] }).hapticActuators?.[0]?.pulse?.(0.3, 15)
    }
    if (Math.abs(ax) < 0.3 && Math.abs(ay) < 0.3) stickArmed = true

    const click = lpad.buttons[3]?.pressed === true
    if (click && !stickClickWas) menu.click()
    stickClickWas = click
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
    },
    setFoveation: (f) => renderer.xr.setFoveation(f),
  },
  72,
)

// pick the best sustainable refresh rate when a session starts
renderer.xr.addEventListener('sessionstart', () => {
  const session = renderer.xr.getSession()
  const rates = session?.supportedFrameRates
  if (session && rates && rates.length) {
    const target = Math.max(...rates.filter((r) => r <= 120))
    session.updateTargetFrameRate?.(target).catch(() => {})
    adaptive.setTargetHz(target >= 90 ? 90 : 72) // adapt against a sustainable floor
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

renderer.setAnimationLoop(() => {
  const now = performance.now()
  const dtMs = now - last
  last = now
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

  // 1. simulate — only while morphing (or briefly after), then FREEZE so the settled
  // cloud is stable: no per-frame chaos-game reshuffle = no distracting edge flicker.
  if (morphT < 1) settleFrames = 0
  else settleFrames++
  if (morphT < 1 || settleFrames <= SETTLE_TAIL) {
    sim.update(renderer, frame)
    flamePoints.setStateTexture(sim.stateTexture)
  }

  const xrRT = renderer.getRenderTarget() // XR framebuffer while presenting, else null (canvas)
  getRenderSize(fbSize)
  compositor.ensureSize(fbSize.x, fbSize.y)

  const presenting = renderer.xr.isPresenting
  const cam = presenting ? rigCamera : desktopCamera
  if (!presenting) controls.update()

  // 2. accumulate point splats into the HDR target (per eye while presenting)
  renderer.setRenderTarget(compositor.hdrRT)
  renderer.clear(true, true, true)
  renderer.autoClear = false
  renderer.render(pointsScene, cam)

  // 3. log-density tone-map into the XR framebuffer / canvas (per eye). In MR
  //    passthrough mode applyEnvMode has set clear-alpha to 0 and uPassthrough to 1,
  //    so untouched pixels stay transparent and reveal the room; in VR / AR-void it
  //    clears opaque black and writes alpha 1, identical to before.
  renderer.setRenderTarget(xrRT)
  renderer.clear(true, true, true)
  compositor.tonemap(renderer, xrRT)

  // 4. overlay (controllers / grid) in LDR over the flame
  renderer.render(overlayScene, cam)
  renderer.autoClear = true

  adaptive.update(dtMs)

  // headroom readout (bucketed so the menu only repaints a few times/sec): if fps is
  // pinned at the refresh rate with drawn==ceiling and fov 0, there's room for more
  // resolution; if particles are being shed (drawn < ceiling) or fov has climbed, we're
  // at the GPU limit. Only meaningful while presenting.
  const fps = adaptive.frameMs > 0 ? Math.round(1000 / adaptive.frameMs) : 0
  perfLine = `${fps} fps · ${fmtCount(activeCount)}/${fmtCount(userCount)} · fov ${adaptive.currentFoveation.toFixed(2)}`
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
}
