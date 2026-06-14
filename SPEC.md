# FractalXR — Product Spec

A WebXR **3D fractal flame** generator for the **Meta Quest 3**, focused on *creating and exploring*, with first-class animation. Runs in the Quest Browser via WebXR `immersive-vr`.

## Confirmed decisions (2026-06-13)

### 1. Dimensionality — 3D volumetric flames
Generalize the IFS / fractal-flame chaos game to **3D** (3D affine transforms + 3D variations). The chaos game produces a **glowing point cloud** the user flies through, orbits, grabs, scales, and rotates with controllers (hand tracking if cheap). This is the VR-native hero experience.

### 2. Creation model — layered (easy by default, deep on demand)
- **Front door: "breed & explore."** Randomize / mutate / interpolate between flames (Electric-Sheep style). The user is handed beautiful results and steers by picking favorites and nudging a few sliders.
- **Advanced layer: direct parametric sculpting.** Each IFS transform shown as an in-VR gizmo; grab to translate/rotate/scale and watch the flame respond live.

### 3. Animation — all three
1. **Living, flowing structure** — particles perpetually run the chaos game so the form shimmers and breathes (inherent in the GPU-particle approach).
2. **Morph between flames** — smooth interpolation of transform/variation/palette parameters between saved flames.
3. **Parameter sweeps / auto-rotation** — hands-free ambient motion (rotate the structure, breathe a variation weight).
4. *(Deferred:* audio-reactive — not in initial scope.)

### 4. Platform & dev loop
- **Target:** Quest 3 (Adreno 740, Snapdragon XR2 Gen 2), stereo, ideally 72–90 Hz, foveated.
- **Dev:** LAN HTTPS Vite dev server (+ USB `adb reverse` for zero-cert friction). Hot reload in-headset.
- **Deploy:** static hosting (GitHub Pages / Vercel / Netlify) for a shareable URL — added later.
- **Stack (provisional, pending research):** TypeScript + Vite + Three.js + WebXR; WebGL2 GPU-particle chaos game (GPUComputationRenderer-style float-texture ping-pong) rendered additively into an HDR target with tone mapping. WebGPU/TSL evaluated as a future path.

## North-star feel
> You stand inside a galaxy-like glowing structure. Reach out, grab it, pull it closer, spin it. Fly through tendrils that recede infinitely. It never sits still — it flows. Pick two you love, breed them, and watch one melt into the next.
