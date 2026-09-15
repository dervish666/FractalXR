# BULB · Sculptural surfaces

Read [common contract](README.md). Target: readable folds, restrained highlights, coloured recesses, stable silhouette. Keep the small object users can grab and enlarge.

Splats and MARCH are two render paths within BULB, not two new navigation modes. Complete B1 before considering B3.

## B1 · Add restrained lighting to normal-oriented splats

**Dependency:** S0. **Files:** `godot/shaders/splat.gdshader`; `godot/scripts/core/particle_cloud.gd` only for a necessary uniform; `godot/tools/splat_shot.gd`.

**Evidence:** the warm-palette splat capture reads as a soft uniformly bright mass. Source uses normals to orient splats, but assigns colour with `v_col = palette(s.w) * brightness`; the existing normal fetch offers a cheap shape cue.

1. Inside `use_normals`, reuse `nl` from the existing `normal_tex` fetch. Transform it into world space correctly for the supported cloud transforms; normalize after transforming. Uniform cloud scaling is current behaviour; do not silently assume arbitrary nonuniform scaling has correct normals.
2. Derive one directional diffuse factor, starting with `0.45 + 0.55 * max(dot(n, key), 0)`, key direction approximately `(0.5, 0.8, 0.3)` normalized. Apply to RGB before the existing premultiplication. Preserve alpha, covariance, footprint compensation, sort order, coverage and culling exactly.
3. Make it bulb-only (`use_normals`); isotropic flame splats must remain unchanged. Keep the original result at lighting amount zero for an A/B capture. Use the same light in world space for both eyes. No added normal/DE samples, shadow pass or per-fragment noise.
4. Inspect normal orientation on Classic, Mandelbox/Citadel and a thin angular family. If inward/outward conventions differ, resolve from current source conventions; do not hide errors with an eye-dependent flip that changes between eyes.
5. Compare warm/cool palettes at coverage 0.9 and 1.1 with identical opacity. Select lighting amount from 0, 0.35 and 0.6. Do not increase coverage to disguise dark gaps.

**Done:** large folds gain depth, recesses retain colour, silhouette and opacity remain unchanged, flames do not change, lighting stays attached to the scene through head motion/grab/scale. Meet common GPU gate.

**Checks:** parser if host code changed; spatial shader check; splat capture with intended path/bake asserted; flame regression capture; Quest two eyes and MR edges.

## B2 · Expose render state clearly

**Dependency:** S1, B1. **Files:** `main.gd` `_build_menu()` and status callbacks, help copy via S3.

1. Keep existing SURFACE name and values. Present active path beside current bulb name/status; differentiate settling, baking and held using actual state.
2. After a performance fallback, show a brief factual status such as `Splats restored: surface too slow`, using the existing bailout state/time window. Do not silently show “march” while rendering splats.
3. Keep splat-only controls out of the active MARCH view (or visibly unavailable without receiving input). Keep SURFACE switch-back and performance footer reachable.
4. Retain toy-scale entry and CENTRE. No automatic approach/fly-in, no new pedestal, no loading rotation.

**Done:** controls describe the visible result; bake wait does not claim readiness; fallback is visible; switching splats → march → splats restores detail/scale settings correctly.

## B3 · Bounded MARCH surface cleanup experiment

**Dependency:** S0 path assertions. **Files:** `godot/shaders/march.gdshader`, exterior portion of `march_shot.gd`. Host changes only for temporary A/B uniforms.

**Risk:** saved image is speckled; neither cause nor active path is proven by that image. Current shader discards non-hits and uses derivative normals. Current guard forces 0.35 eye scale, 48/64/80 steps and fallback after sustained 60 ms. Do not loosen these limits.

1. First reproduce at fixed exterior pose with path assertion, spin/breath off, same preset/palette and effective resolution. If fallback occurs, report it; do not call a splat screenshot a march baseline.
2. Add temporary capture-only diagnostic outputs for hit mask and normal shading. Determine whether speckle is missing hits, unstable normals or palette frequency. No aesthetic fix before this distinction.
3. If silhouette/hit mask is continuous, compare fixed palette midpoint with existing colour. Test reducing trap weight 0.35 → 0.10 and a broader diffuse light. Change only final shading/colour expressions. Preserve hit testing, depth and per-eye rays.
4. If hit mask has holes at the allowed budget, stop B3. If derivative normals fail around divergent/discarded pixels, stop and record examples. Do not add six DE evaluations, raise steps/eye scale, paint the enclosing sphere, or activate the shelved interior.
5. Retain a shading candidate only if moving stereo is stable and the original guard stays effective. Remove temporary debug outputs from production code after recording evidence.

**Done:** either a measured, continuous exterior improvement at unchanged budget, or a clear experiment report rejecting default promotion. This task cannot promise to make MARCH production quality.

**Web difference:** `/splat` uses Spark plus worker-generated clouds (`src/splat/`); native normal-texture shader changes do not transfer directly. Reuse pose/palette acceptance scenes, preserve worker progress/error reporting, and independently validate Spark stereo.
