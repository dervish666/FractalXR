/**
 * WebXR Gaussian-splat viewer — reached via /splat.html.
 *
 * Freezes a Mandelbulb into a cloud of oriented Gaussians you can walk around, rendered with
 * Spark. Deliberately standalone: it does NOT touch the chaos-game app or the relief zoomer.
 *
 * The splats are generated IN THE PAGE rather than downloaded. That is the whole point of the
 * spike — FractalXR already computes its fractals as explicit 3D point clouds, so there is no
 * render-and-train step and no reason to bake a 26MB `.ply` into the repo and fetch it back.
 * Generation fans out across workers; see `build.ts` for why.
 */
import * as THREE from 'three'
import { VRButton } from 'three/addons/webxr/VRButton.js'
import { OrbitControls } from 'three/addons/controls/OrbitControls.js'
import { SparkRenderer, SplatMesh, SplatFileType } from '@sparkjsdev/spark'
import { buildBulbSplats } from './build'
import { HudPanel, type HudContent } from '../ui/HudPanel'
import { SPLAT_BUTTONS, SplatXR, type SplatXrHooks } from './splatXr'

const statusEl = document.getElementById('status') as HTMLDivElement
const barEl = document.getElementById('bar') as HTMLDivElement
const setStatus = (s: string): void => {
  statusEl.textContent = s
}
const setBar = (frac: number): void => {
  barEl.style.width = `${Math.round(frac * 100)}%`
}

const COUNTS = [25_000, 60_000, 120_000, 250_000, 500_000]
const params = new URLSearchParams(location.search)
// 60k is the default because it is the largest count that generates in a wait people will
// actually sit through. The ladder goes to 500k for when you are willing to.
let countIdx = COUNTS.indexOf(Number(params.get('n') ?? 60_000))
if (countIdx < 0) countIdx = 1

const scene = new THREE.Scene()
scene.background = new THREE.Color(0x05060a)

const camera = new THREE.PerspectiveCamera(60, window.innerWidth / window.innerHeight, 0.01, 100)
camera.position.set(0, 1.4, 2.2)

const renderer = new THREE.WebGLRenderer({ antialias: true })
renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2))
renderer.setSize(window.innerWidth, window.innerHeight)
renderer.xr.enabled = true
renderer.xr.setReferenceSpaceType('local-floor')
document.body.appendChild(renderer.domElement)
document.body.appendChild(VRButton.createButton(renderer))

// One SparkRenderer in the scene drives all splat rendering (autoUpdate + WebXR-aware).
const spark = new SparkRenderer({ renderer })
scene.add(spark)

// faint floor grid for spatial reference in VR
const grid = new THREE.GridHelper(6, 24, 0x2a4a72, 0x172233)
const gm = grid.material as THREE.Material
gm.transparent = true
gm.opacity = 0.35
scene.add(grid)

// The sculpture lives in its own group so it can be swapped on every rebuild while the rig,
// the HUD and every gesture baseline stay put.
const content = new THREE.Group()
const hudVR = new HudPanel(SPLAT_BUTTONS, 0.8)
let splat: SplatMesh | null = null
let busy = false
let lastReport = 'starting'
let progress: { frac: number; label: string } | undefined
let size = 0.6 // metres-ish; the cloud spans ~2 units

const ray = new THREE.Raycaster()
const hooks: SplatXrHooks = {
  press: (id) => pressButton(id),
  hudAtRay(origin, direction, out) {
    hudVR.mesh.updateMatrixWorld()
    ray.set(origin, direction)
    const hits = ray.intersectObject(hudVR.mesh, false)
    if (!hits.length) return false
    out.copy(hits[0].point)
    hudVR.mesh.worldToLocal(out)
    return true
  },
}
const xr = new SplatXR(renderer, content, hudVR, hooks)
scene.add(xr.rig)
for (const c of xr.controllers) scene.add(c) // controllers track the room, not the sculpture

// desktop framing: the rig sits where the old fixed placement put it
const PLACE = new THREE.Vector3(0, 1.4, -1.4)
xr.rig.position.copy(PLACE)
xr.layout()

renderer.xr.addEventListener('sessionstart', () => xr.place(1.5, 1.35))
renderer.xr.addEventListener('sessionend', () => {
  xr.reset()
  xr.rig.position.copy(PLACE)
})

function pressButton(id: string): void {
  hudVR.press(id)
  switch (id) {
    case 'count-':
    case 'count+':
      if (busy) return
      countIdx = Math.max(0, Math.min(COUNTS.length - 1, countIdx + (id === 'count+' ? 1 : -1)))
      void generate()
      return
    case 'regen':
      if (!busy) void generate()
      return
    case 'spin':
      xr.spin = xr.spin === 0 ? 0.25 : 0
      return
    case 'size-':
    case 'size+':
      size = Math.max(0.1, Math.min(4, size * (id === 'size+' ? 1.25 : 1 / 1.25)))
      if (splat) splat.scale.setScalar(size)
      return
    case 'reset':
      size = 0.6
      xr.scale = 1
      xr.spin = 0
      content.rotation.set(0, 0, 0)
      if (splat) splat.scale.setScalar(size)
      xr.layout()
      return
    case 'exit':
      renderer.xr.getSession()?.end()
      return
  }
}

async function generate(): Promise<void> {
  if (busy) return
  busy = true
  const want = COUNTS[countIdx]
  setBar(0)
  barEl.style.opacity = '1'
  progress = { frac: 0, label: 'starting' }
  try {
    const t0 = performance.now()
    const { ply, splats, sampleMs, fitMs } = await buildBulbSplats(want, (frac, label) => {
      setBar(frac)
      setStatus(label)
      progress = { frac, label } // the DOM status is invisible in-session; the VR HUD is not
    })

    if (splat) {
      content.remove(splat)
      splat.dispose?.()
    }
    splat = new SplatMesh({ fileBytes: ply, fileType: SplatFileType.PLY })
    splat.position.copy(PLACE)
    splat.scale.setScalar(size) // the cloud spans ~2 units
    splat.rotation.z = Math.PI // 3DGS data is Y-down; flip it upright
    content.add(splat)

    const ready = (splat as unknown as { initialized?: Promise<unknown> }).initialized
    if (ready?.then) await ready
    // Spark sorts lazily on view change; prime the first sort so it appears without a nudge
    spark.update({ scene, camera })

    const total = Math.round(performance.now() - t0)
    lastReport = `${splats.toLocaleString()} splats · ${(total / 1000).toFixed(1)}s`
    setStatus(
      `${splats.toLocaleString()} splats · ${(total / 1000).toFixed(1)}s ` +
        `(${Math.round(sampleMs)}ms sample, ${Math.round(fitMs)}ms fit) · ` +
        `[ ] size · drag to orbit · Enter VR on Quest`,
    )
  } catch (e) {
    lastReport = 'generate failed'
    setStatus('generate failed: ' + ((e as Error)?.message ?? String(e)))
  } finally {
    barEl.style.opacity = '0'
    progress = undefined
    busy = false
  }
}

addEventListener('keydown', (e) => {
  if (busy) return
  if (e.key === '[' || e.key === ']') {
    countIdx = Math.max(0, Math.min(COUNTS.length - 1, countIdx + (e.key === ']' ? 1 : -1)))
    void generate()
  } else if (e.key.toLowerCase() === 'r') {
    void generate()
  }
})

const controls = new OrbitControls(camera, renderer.domElement)
controls.target.copy(PLACE)
controls.enableDamping = true
controls.update()

window.addEventListener('resize', () => {
  camera.aspect = window.innerWidth / window.innerHeight
  camera.updateProjectionMatrix()
  renderer.setSize(window.innerWidth, window.innerHeight)
})

let prevT = performance.now() / 1000
let hudT = 0
renderer.setAnimationLoop(() => {
  const now = performance.now() / 1000
  const dt = Math.min(0.05, now - prevT)
  prevT = now

  if (renderer.xr.isPresenting) xr.update(dt)
  else controls.update()

  // redraw on change, plus a slow tick — a press flash inside a 250ms redraw is invisible
  if (now - hudT > 0.25 || hudVR.needsRedraw || progress) {
    hudT = now
    const stats: HudContent = {
      headline: `${COUNTS[countIdx].toLocaleString()} splats`,
      metric: busy ? 'building' : 'ready',
      metricOk: !busy,
      sub: lastReport,
      lines: [
        `size ${size.toFixed(2)} · rig ${xr.scale.toFixed(2)}x · ${xr.spin ? 'spinning' : 'still'}`,
        'grip to move · two grips to grow · stick to scale and spin',
        'grow it enough and you can walk inside it',
      ],
      footer: 'trigger a button · REBUILD after changing the count',
      progress,
      lit: (id) => id === 'spin' && xr.spin !== 0,
    }
    hudVR.draw(stats)
  }

  renderer.render(scene, camera)
})

;(window as unknown as Record<string, unknown>).__v = {
  scene, camera, renderer, spark, THREE,
  get splat() { return splat },
  generate,
  buildBulbSplats, // exposed so thread scaling can actually be measured, not assumed
  setCount(n: number) {
    const i = COUNTS.indexOf(n)
    if (i >= 0) countIdx = i
    return COUNTS[countIdx]
  },
  counts: COUNTS,
}

void generate()
