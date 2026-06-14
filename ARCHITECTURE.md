# FractalXR — Architecture

> Grounded in a 6-agent research pass (Quest 3 platform, Three.js renderer, 3D flame math,
> GPU chaos-game, VR UX) + verification against the installed Three.js r184 XR internals.
> See `SPEC.md` for the product decisions this serves.

## Stack (decided)

| Choice | Why |
|--------|-----|
| **Three.js r0.184 (classic `WebGLRenderer` + `renderer.xr`)** | WebGPURenderer **cannot drive WebXR** on Quest as of mid-2026 (three.js maintainers + open Quest binding issues). The classic WebGL2 XR path is mature: single-pass stereo, foveation, controllers, hands. Pinned — XR internals move fast. |
| **WebGL2 + `EXT_color_buffer_float`** | Full HDR-additive pipeline: float-renderable FBOs, additive blend, foveation. |
| **Custom float-texture ping-pong (not GPUComputationRenderer)** | Need explicit **GLSL ES 3.00** for `uint` PCG hashing + dynamic uniform-array indexing (transform CDF selection). GPUComputationRenderer defaults to GLSL1 and its internal `renderer.render` would be hijacked by the XR camera swap. |
| **State texture RGBA32F, accumulation RGBA16F** | Precision where it matters (iteration drift / NaN), bandwidth where it matters (additive overdraw is the real bottleneck). |
| **PCG hash, seeded from (particleId, frame)** | Stateless per-frame randomness in-shader, no CPU RNG, no readback. The sin/fract hash bands visibly. |
| **Log-density tone-map as one fullscreen pass per eye** | EffectComposer/bloom is **not stereo-aware in WebXR** (three.js #8146). The flame glow comes natively from additive HDR + flam3 log curve + soft sprites. |

## Render pipeline (per frame, inside `renderer.setAnimationLoop`)

Three.js calls our callback **after** it has set up the XR render target and updated the
per-eye cameras (verified: `WebXRManager.onAnimationFrame`, three.module.js ~L14758). So:

```
0. capture xrRT = renderer.getRenderTarget()      // the XR framebuffer (null on desktop)
1. SIMULATE (view-independent):
     renderer.xr.enabled = false                  // ← stop render() hijacking the compute camera
     sim.update()  ── ping-pong RGBA32F state texture, K chaos-game iterations/particle
     renderer.xr.enabled = true
2. ACCUMULATE (per-eye, HDR):
     setRenderTarget(hdrRT  sized to XR framebuffer); clear black
     renderer.render(pointsScene, rigCam)         // render() swaps to XR ArrayCamera →
                                                  // both eyes splat additively into hdrRT viewports
3. TONE-MAP (per-eye):
     setRenderTarget(xrRT); clear
     renderer.render(tonemapScene, rigCam)        // fullscreen tri; samples hdrRT at
                                                  // gl_FragCoord/fbSize → 1:1 per-eye log-density map
4. OVERLAY:
     autoClear = false
     renderer.render(overlayScene, rigCam)        // controllers / grid / UI, LDR, over the flame
```

Eye viewports from the XR `ArrayCamera` are in framebuffer pixels; `hdrRT` is sized to the
framebuffer so they align 1:1 and the tone-map samples the correct eye region automatically.

## The chaos game (GPU)

Each texel of the state texture is one **persistent particle** holding `(x,y,z, colorIndex)`.
Each frame, in `update.frag`, every particle runs **K iterations** of the 3D chaos game:

1. PCG-hash a random `t∈[0,1)`; pick transform `j` via a precomputed CDF (linear scan, N≤8).
2. 3D pre-affine: `p = A_j · pos + b_j` (A_j stored as three `vec3` rows — reliable uniform upload).
3. Weighted sum of **variations** (`p' = Σ wᵢ·Vᵢ(p)`). M0 set: `linear3D, spherical, swirl,
   sinusoidal, bubble3D`. **bubble3D is the z-injector** — at least one is mandatory or the
   flame collapses to a flat 2D sheet.
4. Colour blend: `c' = ½(c + c_j)`.
5. **Respawn:** if `pos` is NaN (self-compare `x!=x`, since mobile `isnan` is unreliable) or
   escapes a radius bound, or with small probability `pReseed`, scatter to a fresh point.

The **living animation** is emergent: K steps/particle/frame means the whole point set
reshuffles across the attractor every frame → it shimmers and flows, in world space (correct
under head tracking). No screen-space trails.

## Modules

```
src/
  flame/
    types.ts       FlameGenome / FlameTransform / variation weights
    presets.ts     hand-authored volumetric M0 genome (≥1 z-injector)
    palette.ts     control colours → 256×1 LUT texture
    encode.ts      genome → shader uniforms (affine rows, CDF, colour, variation weights)
  engine/
    shaders.ts     all GLSL (seed / update / points / tonemap), GLSL ES 3.00
    util.ts        fullscreen-triangle geometry
    Simulation.ts  RGBA32F ping-pong; seed + update passes; xr.enabled toggle
    FlamePoints.ts THREE.Points (ref-attr → samples state tex), additive HDR splats
    Compositor.ts  hdrRT (RGBA16F) + per-eye log-density tone-map pass
    AdaptiveQuality.ts  inter-frame timer → particle count + foveation (thermal guard)
  xr/
    WorldGrab.ts   1-grip = move/rotate, 2-grip = scale/rotate/translate ("grip-frame" math)
  main.ts          bootstrap + the 4-step loop above; desktop mono fallback for fast iteration
```

## Performance strategy (Quest 3, Adreno 740)

- Additive **overdraw is the bottleneck**, not iteration count. Levers, in order: **foveation**
  (`setFoveation`, runtime, primary), particle count, `setFramebufferScaleFactor(~0.9)` (before
  session), small 2–3px sprites, RGBA16F accumulation, depth off.
- **`AdaptiveQuality`** runs from day one: thermal throttling after 5–15 min is guaranteed and
  unobservable via any API, so the app self-regulates on measured frame time.
- No MSAA (does nothing for `GL_POINTS`, can't compose with float-accumulate).
- Target the highest *sustainable* rate from `session.supportedFrameRates` (expect 90, fall to 72).

## Desktop fallback

The same pipeline runs mono when not presenting (`xrRT = null = canvas`), so the flame, the
chaos game, and tone mapping can be iterated in a normal browser — only stereo/comfort needs
the headset. This is the fast dev loop.

## Roadmap beyond M0

M1 full variation set + genome model + perf hardening · M2 breeding gallery (uikit) ·
M3 morphing (quaternion-decomposed affine interpolation) · M4 gizmo editing · M5 save/load +
auto-sweeps · M6 hosted deploy + hand tracking. See the workflow synthesis in `.research/`.
