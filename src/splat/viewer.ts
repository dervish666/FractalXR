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

const PLACE = new THREE.Vector3(0, 1.4, -1.4) // a comfortable arm's length ahead, at eye height
let splat: SplatMesh | null = null
let busy = false

async function generate(): Promise<void> {
  if (busy) return
  busy = true
  const want = COUNTS[countIdx]
  setBar(0)
  barEl.style.opacity = '1'
  try {
    const t0 = performance.now()
    const { ply, splats, sampleMs, fitMs } = await buildBulbSplats(want, (frac, label) => {
      setBar(frac)
      setStatus(label)
    })

    if (splat) {
      scene.remove(splat)
      splat.dispose?.()
    }
    splat = new SplatMesh({ fileBytes: ply, fileType: SplatFileType.PLY })
    splat.position.copy(PLACE)
    splat.scale.setScalar(0.6) // the cloud spans ~2 units, so this is ~1.2m across
    splat.rotation.z = Math.PI // 3DGS data is Y-down; flip it upright
    scene.add(splat)

    const ready = (splat as unknown as { initialized?: Promise<unknown> }).initialized
    if (ready?.then) await ready
    // Spark sorts lazily on view change; prime the first sort so it appears without a nudge
    spark.update({ scene, camera })

    const total = Math.round(performance.now() - t0)
    setStatus(
      `${splats.toLocaleString()} splats · ${(total / 1000).toFixed(1)}s ` +
        `(${Math.round(sampleMs)}ms sample, ${Math.round(fitMs)}ms fit) · ` +
        `[ ] size · drag to orbit · Enter VR on Quest`,
    )
  } catch (e) {
    setStatus('generate failed: ' + ((e as Error)?.message ?? String(e)))
  } finally {
    barEl.style.opacity = '0'
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

renderer.setAnimationLoop(() => {
  controls.update()
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
