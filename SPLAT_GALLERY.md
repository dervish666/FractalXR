# FractalXR × Gaussian Splatting — feasibility & collaboration note

*A walkable "splat gallery" of frozen fractal sculptures inside FractalXR, and why FractalXR
is unusually well-placed to build one. Written as a shared starting point for a possible
collaboration with **harry7557558**, whose fractal-splat work
([superspl.at gallery](https://superspl.at/scene/e7088609)) sparked this.*

---

## TL;DR

- **Yes, this is feasible**, and FractalXR is a better-than-average host for it because **it already
  computes each fractal as an explicit 3D point cloud** — so we can convert points → Gaussians
  **directly, with no image-rendering and no training run**.
- A first proof-of-concept export already works: one preset (Ember) → **250k Gaussians → a
  standard 3DGS `.ply`**, generated in seconds from the engine's own chaos-game math
  (`.spike/flame-to-splat.mjs`, preview `.spike/ember-preview.png`).
- It ships as a **complementary "specimen mode"**, not a replacement: you breed & morph the
  *living* fractal as now, then **freeze a favourite into a walkable, shareable splat sculpture**.
- In-headset rendering is a solved-ish problem via **Spark** (Three.js-native WebXR splats),
  within a realistic **~500–750k-splat budget** on a standalone Quest 3.

## What FractalXR is (context for harry)

A dependency-light **WebXR fractal renderer for Meta Quest** — Three.js r184, WebGL2, one prod
dependency. It is **not** a per-pixel raymarcher. It runs a **GPU chaos game**: ~2.3M persistent
particles, each holding `(x, y, z, colourIndex)` in a float texture, iterated every frame and
splatted as additive HDR points with a flam3 log-density tone-map. Two families:

- **Flames** — 3D fractal flames (affine + flam3 variations); glowy, volumetric, cheap to run live.
- **Bulbs** — Mandelbulb / Mandelbox / KIFS / quaternion-Julia / Sierpinski, where particles
  Newton-project onto the DE=0 isosurface. Expensive live; coloured by orbit traps.

There's already a **dome gallery**: a planetarium of pre-baked stills you point-and-trigger to
activate. Live at **[fractalxr.uk](https://fractalxr.uk)**.

## The key insight — we can skip the training step

Your pipeline (as we understand it): render the fractal to ~200 images from known camera poses
with a Taichi raymarcher, then **train 3DGS** to *recover* the 3D Gaussians from those images.
The training is the expensive part precisely because an implicit fractal is only a formula — you
have to reconstruct its 3D structure from 2D pictures.

**FractalXR already has the 3D structure.** Every particle is an `(x,y,z,colour)` sample of the
attractor, sitting in a GPU texture we already read back offline (the dome-thumbnail baker does
exactly this). So there are two authoring paths:

| | **Path A — direct convert** | **Path B — render + train (your method)** |
|---|---|---|
| Input | The particle cloud itself | ~N rendered views + known poses |
| Work | Read points → emit Gaussians | Render views → gradient-descent training |
| Time | **Seconds** | Hours per configuration |
| Fidelity | Great for glowy flames; needs clustering polish | Highest — captures exact tone/glow |
| Best for | Flames, fast iteration, "freeze this now" | Hero pieces, bulbs, exact look |

**Path A proof-of-concept (done + validated in superspl.at):** Ember → Gaussians → valid
INRIA-format `.ply`, straight from the chaos-game math, no training. Each Gaussian is an
**anisotropic ellipsoid fitted to the local surface** (PCA of its ~14 nearest neighbours →
covariance → eigendecomposition → oriented quaternion), so it renders as a smooth, translucent,
flowing flame rather than lumpy spheres. Two gotchas learned the hard way: **never a global splat
scale** (it balloons the dense core and kills the GPU — size to local density), and use the
**INRIA `(w,x,y,z)` quaternion convention**. Detail scales with **point count** (250k is a soft
preview; 1M+ resolves fine filaments — the exporter takes it as a CLI arg). For fidelity matching a
trained scene (crisp bulb filigree, exact log-density glow), Path B (your training) is the route.

*(The one thing Path A can't do that your training does: recover a faithful **volumetric** density
field with view-dependent colour. For hard cases, or to nail the exact FractalXR tone, Path B —
your pipeline — is the gold standard. That's exactly where a collaboration is valuable.)*

## Rendering it in-headset

- **Renderer: [Spark](https://sparkjs.dev/)** (MIT, by World Labs). `SplatMesh extends
  THREE.Object3D`, drops into our existing Three.js scene, proven on Quest 3 WebXR. (Alternative:
  mkkellogg/GaussianSplats3D — the OG Three.js one; needs COOP/COEP headers for its worker sort.)
- **Budget: ~500–750k splats at 72–90 fps** in stereo on a standalone Quest 3 (Spark's own default
  WebXR LoD cap; the per-frame depth sort runs on a web worker, since Quest-browser WebGPU compute
  is still experimental as of mid-2026). That's why we decimate/cluster rather than dump all 2.3M.
- **Low integration risk:** in specimen mode you view the frozen splat *instead of* the live flame,
  not on top of it — so there's no fill-rate fight between the two, and adding a sorted alpha pass
  is the same shape of change as our existing overlay pass.

## Product fit — the dome gallery already is this UX

The dome rings you with frozen stills; point at one and it becomes the live fractal. The splat
feature swaps the payload: **point at a tile → drop inside a walkable splat sculpture of that
fractal.** The billboarding, laser-pick and select→become flow are all reusable. There's exactly
one live cloud today; a splat specimen is just a second thing a tile can instantiate.

## Honest trade-offs

- **You lose the living shimmer.** FractalXR's soul is the chaos game reshuffling every frame; a
  splat is frozen. Hence *complementary* — living exploration **and** frozen, shareable sculptures.
- **Net-new infrastructure:** there's no runtime binary loader today (the only runtime asset load
  is one PNG atlas). A `.ply`/`.splat` loader is the one genuinely new piece.
- **Per-configuration:** each frozen fractal is its own asset, like yours.
- **Flames splat gorgeously; bulbs less so.** Gaussians *are* soft semi-transparent blobs, so the
  glowy flames reconstruct beautifully; razor-thin Mandelbulb filigree blurs. Nicely, bulbs (the
  expensive-to-run ones) are where a bake buys the most performance.

## A collaboration shape

- **FractalXR brings:** a live breeding/morphing engine, 34 curated fractal genomes, a Quest VR
  gallery to walk through specimens in, and the direct-convert (Path A) exporter.
- **We'd love from you:** your camera-rig / `transforms.json` conventions and
  [`spirulae-splat`](https://github.com/harry7557558/spirulae-splat) settings for Path B fidelity —
  and, if you're up for it, your fractal splats as a **guest collection** in the gallery.

## Phased plan

1. **Path-A spike** — export a preset to `.ply`, view in a splat viewer. *(done + validated —
   `ember.ply` renders as a smooth anisotropic Ember in superspl.at. Spark-on-Quest is the real test.)*
2. **Spark POC** — load that `.ply` into the live Three.js scene, desktop then on-device Quest at
   ~500k splats with foveation on. The real go/no-go.
3. **Gallery integration** — wire splat specimens into the dome select flow.
4. **Path B / share pipeline** — train hero pieces; export FractalXR specimens to superspl.at.

---

*Status: Path-A exporter working and **validated in superspl.at** — `ember.ply` uses **anisotropic**
Gaussians (each ellipsoid fitted to the local surface via PCA of its nearest neighbours), rendering
as a smooth, translucent, flowing flame. Spark-on-Quest POC is the next step. Lessons retained:
never a global splat scale (it ballooned the core and killed the GPU — size to local density);
INRIA `(w,x,y,z)` quaternion convention.*
