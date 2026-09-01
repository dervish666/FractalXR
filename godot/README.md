# FractalXR: Godot spike

A native Quest build of the chaos game, existing to answer one question:

> **How much GPU time does the same fractal-flame workload cost natively versus the WebXR build?**

Everything else is scaffolding. There is no wrist menu, no dome gallery, no
presets browser and no adaptive quality, and that is deliberate.

## The premise being tested

WebGL2 has no compute shaders. The web build's chaos game is therefore a fragment
shader ping-ponging two RGBA32F render targets, with the resulting points splatted
through the rasteriser as `GL_POINTS` with additive blending.

Natively, all three of those constraints lift:

| | WebXR build | this spike |
|---|---|---|
| Iterator | fragment shader, 2 ping-ponged targets | compute, **one image updated in place** |
| Splat | `GL_POINTS` + additive blend | **`imageAtomicAdd` into a uint accumulator** |
| Accumulator clear | separate clear of the HDR target | **fused into the tone-map read** |
| Clocks | whatever the browser picks | `XR_EXT_performance_settings` (not wired yet) |

If the gap is ~20% this is a hard sell against three rewrites. If compute and
atomics land it at 2x, the decision makes itself.

## Layout

```
scripts/core/fractal_source.gd    base class: anything that fills the state image
scripts/core/particle_cloud.gd    state image + point mesh + material (type-agnostic)
scripts/core/preset_library.gd    loads data/presets.json
scripts/sources/flame_source.gd   the chaos game (reference implementation)
scripts/xr/world_grab.gd          two-handed grab, ported from src/xr/WorldGrab.ts
scripts/main.gd                   XR setup, controls, HUD
shaders/chaos.glsl                compute: the flame iterator
shaders/points.gdshader           the renderer, shared by every type
data/presets.json                 generated; see below
experiments/atomic_splat/         the abandoned design, kept for reproducibility
```

### Adding a fractal type

The renderer, grab, controls, HUD and preset machinery know nothing about which
fractal is running. The state image is always RGBA32F, one texel per particle,
`xyz` = position and `w` = palette coordinate. That layout is the whole contract.

To add Mandelbulb, Mandelbox, KIFS, quaternion Julia or anything else:

1. Write `shaders/<type>.glsl`, a compute shader with the same bindings as
   `chaos.glsl` (binding 0 the state image, binding 1 your parameter buffer).
2. Subclass `FractalSource` in `scripts/sources/`, overriding `shader_path()`,
   `params_bytes()` and `param_buffer_floats()`. Copy `flame_source.gd`.
3. Hand it to `cloud.set_source()`.

Nothing else changes. `src/engine/shaders.ts` already has `BULB_UPDATE_FRAG` covering
all five distance-estimate formulas, and it ports the same way `chaos.glsl` did.

### Presets

`data/presets.json` is **generated** by `../tools/export-presets.mjs` from
`src/flame/presets.ts`. The TypeScript stays the single source of truth, so a preset
added on the web side reaches the headset with no transcription and no chance of the
two drifting:

```bash
node tools/export-presets.mjs   # from the repo root
```

`tools/selftest.sh` steps every preset and fails on NaN, an escaping cloud, a collapse
to a point, or a genome that has gone flat in z (the missing-z-injector bug).

## Controls

| Input | Does |
|---|---|
| Grip, one hand | Move and rotate the cloud with your hand |
| Grip, both hands | Move, rotate and scale: pull your hands apart and fly through |
| Right stick up/down | Push the cloud away, pull it back |
| Right stick left/right | Rotate it |
| Right trigger | Next flame, or activate the menu row you are pointing at |
| Left trigger | Previous flame |
| Turn left wrist toward your face | Wrist menu appears |

The first launch shows a card with both controllers drawn on it and what each button does,
dismissed by either trigger and never shown again (`user://state.cfg`); `HELP` in the wrist
menu brings it back. Nobody was ever going to guess the wrist-turn on their own.

Everything else lives in the wrist menu: Flame, Drift, Spin, Points, Size, Bright,
Exposure, Motion, Detail, Recentre, with fps and the draw/sim split underneath.

Desktop preview: arrows, left/right flames, D drift, 1 2 3 4 5 6, R reset, S reseed.

### Wrist menu

Label3D rows rather than a SubViewport UI. A viewport would mean mapping a controller
ray into synthetic mouse events; Label3D renders crisp MSDF text at any distance and
picking is a plane intersection against row rectangles, which is cheaper and more
predictable when there is nothing else in the scene to hit.

Each entry is a label plus two closures, `read` and `advance`. The menu knows nothing
about particle counts or exposures, so **adding a setting is one line** in the item
list in `main.gd`. The trigger is taken over only while the pointer is actually on a
row, so changing flames still works everywhere else.

## Transitions

Genome interpolation follows **flam3's "log" interpolation**, its default since 2.7.15,
not the quaternion decomposition in `src/flame/morph.ts`.

flam3 converts each COLUMN of the affine to polar form and interpolates the angle and
magnitude separately (`interpolation.c`: `convert_linear_to_polar`,
`interp_and_convert_back`), taking the short way round the circle. Two properties follow,
and the quaternion approach had neither:

1. **It is exact at t=0 and t=1.** Decomposing a matrix into a rotation and a scale
   loses shear, which forced an endpoint special case, and that special case was a
   visible jump at both ends of every transition. Per-column polar reproduces its
   inputs exactly, so the interpolated genome joins the real ones without a seam.
2. **The translation is treated as another column**, so it arcs between positions
   rather than sliding straight through the origin. That is a large part of why flam3
   transitions read as organic rather than mechanical.

Extended to 3D by slerping the column direction instead of carrying a single angle.
Degenerate and antipodal columns are handled explicitly, or a near-zero cross product
picks a different rotation plane every frame.

flam3 also offers Catmull-Rom interpolation across four control points for continuous
velocity through a chain of keyframes. Not needed for a single A-to-B transition with
smoothstep easing, but it is the thing to reach for if transitions are ever chained
without a pause.

## Look and feel notes

Three things were wrong on-device and each had a different cause.

**Blown-out white cores.** Forward Mobile's colour buffer is `A2B10G10R10_UNORM`, 10-bit
fixed point. Per-point brightness of 0.7 meant 1.4 overlapping particles saturated a
channel, so every dense region clipped to flat white and lost its hue. Dropping the
default to 0.02 lets roughly 50 particles overlap before clipping, which turns the
buffer into a real density accumulator with the tonemapper doing the compression.

**Flickering pixels.** The chaos game re-randomises every particle it touches, so at
1px each screen pixel was lit by zero or one particle and re-rolled 72 times a second.
The fix is to stagger the updates: only `1/n` of the cloud iterates per frame, so the
sample set persists. It converges to the same attractor, looks far more solid, and
costs proportionally less GPU. Default is a quarter per frame.

**Low resolution.** Two separate causes, neither of them a resolution setting.

Above about 1.2M particles the frame rate falls below refresh, the compositor reprojects
the previous frame, and reprojection ghosts anything in motion. **Frame budget is a
sharpness setting here**: 1.68M looked better in a still screenshot and worse in motion,
and both were true at once.

The rest was the auto-framing. Normalising every preset up to a unit radius magnified
the naturally small ones, spreading a fixed point budget over more screen area, and
thinner points read as lower resolution. It now only ever shrinks. Large attractors get
reined in; small dense ones keep the density that makes them look sharp.

**Bulb motion has two independent clocks**, and the menu now exposes both because
telling them apart on-device is the only way to judge what the shimmer costs.

`MOTION` is the particle clock: how much of the cloud re-projects onto the surface each
frame, frozen to every-frame. Until now it read `BULB_UPDATE_MOD` and cycled
`stability_idx`, which only ever reaches the flame source, so in bulb mode it was a live
button wired to nothing. Frozen needs a settle pass first (`BULB_SETTLE_FRAMES`): a
particle only reaches the surface on an update, so stopping the clock cold would strand
whatever had not stepped yet in the seed ball.

`BREATHE` is the surface clock: the per-genome parameter drift that keeps the shell
reshaping. Off holds the form still while particles keep filling it in.

### Density-adaptive splat sizing, and the bug that hid it

`bulbSplat.ts` sizes every Gaussian from the covariance of its 14 nearest neighbours,
across a full 10x span (MIN_S 0.0007 to MAX_S 0.0075). That spread is why 60k of its
splats read sharper than 294k of uniformly sized ones: a dense region gets small splats
that hold the detail, a sparse one gets large ones that close the gaps, and a single
global size can only ever do one of those. kNN per frame is out of the question on a
live cloud, so this approximates it with a grid histogram: one `atomicAdd` per particle
into a 64^3 grid, and each splat scales by the cube root of the volume it has to itself.

**It did nothing at all for its first outing.** The counts reach the vertex shader as a
texture, because a Godot spatial shader cannot read a storage buffer, and that texture
was `R32_UINT` sampled through a `sampler2D`. Vulkan needs `usampler2D` for an integer
format. Every fetch came back zero, every splat took the same clamped fallback, and 147k
identically sized discs merged into a foam ball. Nothing errored: an invalid sampler
binding is silent, and the fallback path was a legal number.

The fix is a second compute pass that writes floats with `imageStore`, which is both
valid and one 400KB readback cheaper than uploading the buffer each measure. It also
does two things the first version could not:

- **Sums the 3x3x3 block around each cell** rather than reading one. A single cell
  quantises hard, so two particles either side of a boundary get different sizes and the
  grid itself becomes visible.
- **Measures the mean occupancy** of the cells that actually hold particles, and the
  splat shader divides by it. Without that reference the sizing depends on the particle
  count and the grid resolution, so changing either quietly rescales the whole cloud.

### The bake

`shaders/bake_scan.glsl`, `bake_scatter.glsl`, `bake_shape.glsl`, driven from
`ParticleCloud.bake()`. Once per bulb, after the shell has filled: bin every particle
into the 64^3 grid, prefix-sum the counts so each cell knows where its slice of a sorted
particle list starts, scatter the ids into it, then give every splat its own size and
shape from the neighbours that list makes reachable. Chunked at 32k particles a frame, so
the pause is a wait rather than a stall — a dropped frame in a headset is worse than a
loading bar.

Two shortcuts make it cheap enough to run on-device at all. The surface normal is already
known, so the covariance only has to be solved in the tangent plane: a 2x2 eigenproblem
with a closed form, not a 3x3 needing Jacobi sweeps. And the neighbourhood is "everything
within 2.5 local spacings" rather than a true k-th nearest, which lands on ~23 neighbours
against bulbSplat.ts's k of 14 and needs no sorted search. Output is four numbers per
splat: the major axis as a cosine and sine in the tangent frame, and the two axis lengths.
The vertex shader rebuilds the frame from the same normal with the same formula, so only
the angle has to cross.

Measured on the first bulb: sizes spread at 67% of the mean, and a mean minor/major of
**0.66**. Splats now lie along the filament they belong to instead of straddling it,
which is the difference no amount of resizing a circle can reach.

### The renderer was the missing piece, not the data

After the bake shipped and still read as "a point cloud with splats", the WebXR viewer's
actual renderer (Spark) got read properly instead of guessed about. Its splat material is
`depthTest: true, depthWrite: FALSE`, it depth-sorts every frame, and its vertex shader
projects each splat's 3D covariance through the Jacobian of the perspective transform to
get a screen-space ellipse, with a blur floor and matching alpha compensation.

Ours wrote depth on every splat (`depth_draw_always` + `depth_prepass_alpha`). That
single flag is most of the difference: with depth writes, a nearer splat OCCLUDES the
ones behind it, so every splat stays a legible disc and no amount of sizing makes discs
merge into a surface. Gaussian splatting is an accumulation of translucency; occlusion
was structurally the wrong compositing model, chosen early on the reasonable-sounding
"a surface wants nearer to cover farther" and never revisited while everything else got
tuned around it.

`splat.gdshader` is now the real algorithm: no depth write, premultiplied alpha,
screen-space covariance projection (a direct port of Spark's maths), `exp(-0.5 sigma^2)`
falloff over a sqrt(8)-sigma quad, blur floor with energy-conserving alpha adjustment.
Bulb defaults moved to Spark's numbers: alpha 0.22, smaller splats, palette at full
strength (an "over" composite converges to the source colour, it does not sum).

The one Spark feature not ported is the per-frame back-to-front sort. Unsorted "over" is
order-dependent; a thin shell of similarly coloured splats is the mildest case, so the
sort is deferred until the headset says otherwise.

### The fill-rate guard

The projected-covariance renderer moved the cost model: it is now almost pure fill rate,
and fill scales with the SQUARE of splat size, so the settings ladder has a cliff in it.
On-device: 42mm splats with the bake's spread hit 2fps and needed a hard quit to escape.

Two guards. A hard per-splat cap (`MAX_PIXEL_RADIUS`, 192px) bounds any one ellipse. And
a governor in `main.gd` watches the real frame time and scales every splat (`perf_scale`)
the moment fps dives under 24 — cuts are immediate and proportional, recovery waits three
seconds and then creeps, so it cannot oscillate against the cliff it fell off. The wrist
menu shows "guard N%" while it is intervening, because a silently shrunk 42mm splat would
otherwise read as a broken setting.

### Two bugs the self-test caught, and one it could not

The neighbour search first came back finding **zero** neighbours for every particle. The
cause was scanning a blanket 3x3x3 of cells under a candidate budget: the budget went on a
far corner cell whose particles all failed the radius test, and the home cell was never
reached, so every splat took the isotropic fallback. It reads on-device as "the bake did
nothing", which is indistinguishable from twenty other causes. The self-test named it in
one line: `minor/major 0.99`. Both a size-variance and an anisotropy assertion are now
gates, because "the bake ran and produced uniform circles" is the failure this whole pass
exists to prevent.

The one it could not catch was itself. **`tools/selftest.sh` runs Godot with `--script`,
which does not rescan the filesystem**, so it executed the last-imported SPIR-V and
reported a confident pass on shader source that had never been compiled. Three consecutive
edits to `bake_shape.glsl` were each "verified" against the binary from before the first
one, and the fix that did work looked like it had failed. `--import` now runs first,
always. Exports were never affected: `--export-debug` scans.

### What the web build is really buying with those few seconds

The WebXR viewer pauses for several seconds before a splat cloud appears. That pause is
the difference, and it is not something a live simulation can approximate away: it is a
real kNN covariance per splat, computed once, giving each Gaussian a true size AND three
eigenvalue-derived axes (`THIN = 0.16`). Then it renders a cloud that never changes.

We get orientation for free from the distance-estimate normal, and now approximate size
from a grid. The two things still missing are genuine anisotropy and staying still, and
both point the same way: **bake the cloud once per bulb** rather than simulate it live.
Freeze already wins on-device, which is the same finding from the other end.

Both exist because of what the WebXR splat viewer does differently. It generates its
cloud **once** and never touches it again, and a static cloud is why each splat sits
exactly where it belongs. Ours re-jitters tangentially on every update, which is life,
but it is also a permanent shimmer that no amount of splat sizing can sharpen. Frozen
plus breath-off is the closest this gets to that, and the toggles make it a comparison
rather than an argument.

For the record, three things were blamed before the log settled it: dynamic foveation
twice and dynamic resolution once. `fov=0 dyn=false rt=(1680,1760) scale3d=1.00` never
moved across an entire run, and at a constant particle count the frame rate held 71-72fps
from start to finish. It was our own feature both times.

## Setup

Already installed on this machine, listed so it can be rebuilt elsewhere:

- Godot 4.7.2 (`brew install --cask godot`)
- JDK 17 (`brew install openjdk@17`)
- Android SDK cmdline-tools, `platform-tools`, `build-tools;34.0.0`, `platforms;android-34`
- Godot export templates 4.7.2, in `~/Library/Application Support/Godot/export_templates/`
- A debug keystore at `~/.android/debug.keystore`
- **`addons/godotopenxrvendors`**, gitignored (82MB). Fetch from the
  [godot_openxr_vendors 5.1.0 release](https://github.com/GodotVR/godot_openxr_vendors/releases/tag/5.1.0-stable),
  asset `godotopenxrvendorsaddon.zip`, and drop `asset/addons/` in at the project root.
  This is not optional: without it the export produces a 2D panel app, and the
  Meta extensions (refresh rate, CPU/GPU levels, frame synthesis) are unreachable.

## Commands

```bash
tools/selftest.sh          # verify the compute chain on this machine, writes .spike-out/selftest.png
tools/card_shot.sh         # render the first-launch controls card to .spike-out/help_card.png
tools/build.sh             # export build/fractalxr-debug.apk (debug-signed, the dev loop)
tools/build.sh release     # export build/fractalxr.apk, signed for the store
tools/keystore.sh          # make the release keystore, once, ever
tools/deploy.sh [release]  # build, install, launch, stream the [perf] log
tools/soak.sh 900 > soak-compute.csv   # scrape 15 minutes of [perf] lines into CSV
tools/make_icons.py art/candidates/glacier.png       # launcher icons from a real render
tools/make_store_art.py art/candidates/vortex.png …  # SideQuest card and background
```

Candidate renders come from the web build: `npm run art` in the repo root, then
`/icon.html?names=Vortex,Glacier`. Publishing is written up in [`../SIDEQUEST.md`](../SIDEQUEST.md).

`--xr-mode off` is load-bearing on the Mac and is baked into `tools/env.sh`. Without
it the OpenXR loader hunts for a runtime that isn't there and hangs the process for
minutes. That cost an hour; don't remove it.

## Controls

| Input | Does |
|---|---|
| Right stick | Orbit the cloud (x = yaw, y = pitch) |
| Left stick Y | Scale |
| Right trigger | Cycle particle count through `[0.3, 0.5, 0.7, 0.85, 1.0]` |
| Left trigger | Swap render path: compute/atomic to raster/points |
| A / B | Iterations per frame down / up |
| X | Toggle splat stamp 1x1 or 2x2 |
| Grip | Reseed |

Keys 1 to 5 and R do the same on the desktop preview.

The HUD shows fps, GPU ms, CPU ms, the active path, particle count, iterations,
eye resolution, and a soak timer. Every HUD update also prints a `[perf]` line to
logcat, so a soak can be scraped without anyone wearing the headset.

## The measurement protocol

The number is worthless unless both sides run identically. Defaults here already
match `src/main.ts`:

- state grid 1536², **707,788 particles drawn** (`floor(0.3 × 1536²)`)
- 4 chaos-game iterations per frame, reseed 0.0015
- foveation 0, 72Hz, the Ember genome, exposure 0.32 / gamma 2.4 / k2 55
- **no adaptive quality on either side**. The web build's `AdaptiveQuality` sheds
  particles under load, so leaving it on measures the governor, not the engine

Then:

1. Cold headset. Both runs start from the same device temperature.
2. Run each build for **15 minutes**. Quest 3 throttling is guaranteed after 5 to 15
   minutes and invisible to every API.
3. Compare **GPU ms per frame at a fixed particle count**, not fps. FPS pins to the
   refresh rate and tells you nothing until you are already dropping frames.
4. Cross-check against OVR Metrics Tool. Godot's own GPU timer and Meta's app GPU
   time measure slightly different things; if they disagree, believe Meta's.

## Caveats, read before trusting a number

- **The raster path is not tone-map-identical.** It renders points straight into
  the eye buffer through Godot's pipeline, so there is no flam3 log-density pass.
  Its number answers "how fast is Godot's rasteriser at N points", nothing more.
  The compute path is the apples-to-apples one.
- **The compute splat may lag the head pose by one frame.** `call_on_render_thread`
  does not guarantee it records before the viewport render. Irrelevant to GPU ms,
  visible as the cloud swimming against head motion. A production port controls its
  own frame loop and has no such ambiguity.
- **CPU/GPU performance levels are not wired up yet.** That lever needs the vendors
  plugin's Meta extensions and is the obvious next step once a baseline exists.
- **The self-test proves the shaders, not the headset.** It runs on this Mac's
  Metal driver. Adreno will disagree about something; it always does. Stereo,
  comfort, thermals and whether it actually looks right are on-device questions
  and nobody has answered them yet.

## Results, Quest 3, 2026-08-31

707,788 particles, 4 iterations/frame, Ember, 72Hz, foveation 0, eye 2800x2800
unless stated. GPU ms from `RenderingDevice` timestamps, medianed over a 6s window
after a 3s settle, with a **fixed camera** so the splat always has the cloud in view.

| stage | chaos | splat | resolve | compute | viewport | **total** | frame |
|---|---|---|---|---|---|---|---|
| idle (composite only) | 0 | 0 | 0 | 0 | 9.44 | 9.45 | 13.89 |
| chaos only | 4.02 | 0 | 0 | 4.03 | 7.55 | 11.58 | 13.89 |
| chaos + splat 1x1 | 2.24 | 36.63 | 0 | 39.24 | 3.39 | 42.63 | 42.60 |
| chaos + splat 2x2 | 2.21 | 131.32 | 0 | 133.88 | 3.26 | 137.14 | 136.67 |
| resolve only | 0 | 0 | 8.26 | 8.26 | 4.86 | 13.12 | 13.89 |
| full (compute path) | 2.21 | 89.70 | 7.57 | 99.60 | 4.12 | 103.72 | 103.33 |
| full, stamp 1x1 | 2.19 | 24.94 | 7.54 | 34.76 | 3.89 | 38.65 | 38.89 |
| full @ 1960x1960 | 2.21 | 73.26 | 3.71 | 79.62 | 1.69 | 81.31 | 80.56 |
| full @ 1400x1400 | 2.20 | 56.20 | 1.75 | 60.28 | 1.03 | 61.32 | 61.90 |
| **raster points** | 2.36 | 0 | 0 | 2.37 | 11.98 | **14.35** | 14.58 |

### What this says

**The atomic splat is a disaster on Adreno: 90 to 131ms.** That was the whole
premise of going native and it is wrong. A tile-based mobile GPU makes the
rasteriser's additive blend cheap because it happens in tile memory; `imageAtomicAdd`
goes to global memory and serialises on contention, and a fractal flame's dense core
is nothing but contention. The 2x2 stamp costs 3.6x the 1x1 stamp, tracking the atomic
count almost exactly, which is the signature of throughput-bound atomics rather than
bandwidth. Splat cost also barely falls when the resolution drops 4x (89.7 -> 56.2),
because fewer pixels means *more* contention per pixel.

**The compute chaos game is a genuine win: 2.2 to 4.0ms** for 707,788 particles at 4
iterations. That is the part worth keeping, and it is the part WebGL2 cannot do.

**The rasterised points path holds 72Hz at 14.35ms**, roughly 7x faster than the
compute-atomic path, and it renders through Godot's own pipeline so it gets correct
per-eye projection and tracks the head. The compute path's screen-space composite
does neither: it blits an image built from a possibly-stale pose, which on-device
reads as the cloud sitting still while the world moves. Unfixable inside Godot's
scene renderer, because closing that gap means owning the frame loop.

**So the native design is: chaos game in compute, splat through the rasteriser.**
Not the atomics-replace-everything idea this spike set out to test.

### Phase 2: which levers actually work

Same conditions, raster path, fixed camera at 1.2m.

| stage | viewport ms | total ms |
|---|---|---|
| XR baseline, nothing drawn | 4.86 | 4.86 |
| base @ 2800x2800 | 11.60 | 13.67 |
| render multiplier 0.75 @ 2100x2100 | 10.56 | 12.63 |
| render multiplier 0.6 @ 1680x1680 | 10.66 | 12.72 |
| foveation 2 / 3 | 10.64 | 12.70 |
| point size 1.5 / 1.0 | 9.97 / 9.90 | 12.04 / 11.97 |
| 2 iterations | 11.10 | 12.33 |

Cutting pixels 2.8x saved 1ms. Foveation did nothing measurable. Point size did almost
nothing. **The point rendering is vertex-bound, not fill-bound**: 707,788 points across
two eyes is 1.4M vertices each doing a texture fetch, and that is the cost. So the lever
that works is particle count, and everything else is noise.

That pointed straight at a bug: the mesh had no draw range and always rendered all
2,359,296 vertices regardless of the particle setting, 3.3x the necessary work. The
shader now indexes the state image by `VERTEX_ID`, so the mesh carries no UV attribute
and is a bare resized vertex buffer. Changing the draw range costs a resize. That alone
took the draw cost from 10.56ms to 6.2-8.1ms.

### Phase 3: Forward+ is not an option on Quest 3

Forward+ would give the RGBA16F colour buffer with a STORAGE bit that flam3 needs, and
the tone map did run correctly on it. It is still the wrong choice:

| | Forward Mobile | Forward+ |
|---|---|---|
| Colour buffer | A2B10G10R10_UNORM, no storage | R16G16B16A16_SFLOAT, storage |
| Draw time | 4.4-9.9 ms | 28-100 ms |
| Vulkan pipeline failures | none | many (black screen, no HUD) |

So the flam3 curve is achievable or the app is playable, not both.

### Phase 4: what Meta's own instrument says

Two OVR Metrics Tool captures, one with a maxed QGO profile and one with none:

| | QGO maxed | No profile |
|---|---|---|
| CPU / GPU level | 7 / 5 | 2 / 5 |
| CPU / GPU clock | 2361 / 640 MHz | 1382 / 599 MHz |
| Refresh rate | 120 Hz | 72 Hz |
| Frame rate | 90 (64-108) | 72 (71-73) |
| Stale frames | 31 | 1 |
| App GPU time | 9.56 ms | 9.88 ms |
| GPU utilisation | 99% | 81% |
| CPU utilisation | 12% | 11% |

**The maxed profile made it worse.** It pushed the display to 120Hz, cutting the budget
to 8.33ms against a 9.56ms frame, so roughly a third of frames go stale. At 72Hz it is
solid with about 4ms of headroom.

**App GPU time barely moved** across a 70% CPU clock increase, and CPU utilisation is
11-12% with three cores idle. This is a GPU-bound workload with the CPU asleep, which
settles the "would native C++ be faster" question: there is no CPU time to reclaim. The
same shaders would do the same work on the same GPU for the same 9.9ms.

It also cross-checks the in-app instrumentation: 4.4ms draw plus 4.1ms sim against
Meta's 9.88ms app GPU time, the gap being compositor overhead.

**The case for a native OpenXR port is now the render target format and nothing else.**

### Still open

- **No flam3 log-density tone map.** The web build's look comes from a log-density
  curve over an HDR accumulation buffer. This renders additive points straight into the
  eye buffer with Godot's Reinhard tonemapper, so bright cores and faint filaments will
  not match. Doing it properly means a `CompositorEffect`, which is the supported way to
  post-process with correct stereo. This is the biggest remaining visual gap.
- **No web-build comparison at matched settings.** The native figure is ~11ms.
- **No thermal soak.** Every number here is a short window, not the 15 minutes that
  would tell the truth.
- **CPU/GPU performance levels still not wired up.** Needs the vendors plugin's Meta
  extensions, and is the battery-for-fidelity lever.
- **Only the flame type is ported.** Bulbs and the relief zoomer are next, and the
  architecture above exists so they are additive rather than invasive.
- **True flam3 log-density is not reachable on Forward Mobile.** It needs an HDR colour
  buffer; Mobile gives 10-bit fixed point with no storage bit. `Flam3Tonemap` is written,
  correct, and costs only 2.1-2.9ms, but it self-disables because the buffer cannot feed
  it. The only renderer that can is Forward+, which is unusable here (below).
- **Per-point cost.** A frozen cloud spends essentially its whole budget drawing points
  twice, so this is the one optimisation that would end the density-versus-sharpness
  trade rather than just moving along it.

## Status

**Holding 72Hz on a Quest 3** at 707,788 particles, eye 2100x2100: draw 6.2-8.1ms plus
sim 3.5-3.7ms against a 13.89ms budget. All 13 presets load and pass the self-test.
Grab, preset cycling and the HUD work on-device.

Adreno 740, Vulkan 1.3.295, OpenXR runtime 206.134.0.
