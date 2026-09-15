# FLAME · Luminous filaments

Read [common contract](README.md). Target: coloured cores, fine luminous strands and depth between lobes. Preserve volumetric transparency, free exploration and existing morph behaviour.

## Current diagnosis

- The historical high-brightness headset image has a broad white core. It is not a current-default baseline: current `bright_idx = 1` selects 0.02, whereas that image shows 0.300.
- `points.gdshader` adds palette-coloured points into the native framebuffer. Source/notes document the native Mobile accumulation limitation. A per-point tone curve cannot recover colour already clipped during accumulation.
- Frozen settled particles and measured framing already exist. `main.gd` already hides the old HUD. Reuse both instead of implementing replacements.

## F1 · Tune the existing look at fixed cost

**Dependency:** S0. **Files:** `godot/scripts/main.gd` brightness/exposure/glow application; `godot/tools/` flame capture. Read `points.gdshader`, `_apply_point_look()`, `_apply_palette()`, exposure setter and `main.tscn` before editing defaults.

1. Capture Ember, Plasma and a sparse filament preset selected from the current library. Record exact names. Use native preset colours plus one cool and one warm theme, same particle count and camera.
2. Compare baseline brightness 0.02 with 0.01 and 0.015, keeping exposure fixed. Then compare glow intensity 0.45 with 0.20 and 0.30 at the best brightness. Do not vary count, point size or eye scale in this sweep.
3. Select the lowest-change candidate that retains faint outer filaments while reducing flat white areas. Check close-up, default distance and during morph. A darker image alone is not success.
4. Only bake a new default if it wins across the three specimens in VR and MR. If no candidate does, keep baseline and record the limitation. Do not change every preset's generated data or the simulation to force a result.
5. Scope any glow change to the active mode through one existing look-application path, restoring the other mode's expected state on switch. Avoid several setters fighting over the shared Environment.

**Done:** before/after pairs show equal framing and visible outer strands, more hue inside dense cores, no new flicker or morph brightness jump; no higher particle count or GPU cost used to hide defects.

**Checks:** parser; shader check only if shader changed; flame captures; selftest if simulation/source logic changed (not required for constants only); Quest moving/settled VR and MR.

## F2 · Presentation and control polish

**Dependency:** S1. **Files:** `main.gd` menu title/status callbacks and framing/recentre code only if a measured defect is found.

1. Use specimen name as title and the existing truthful status (`morphing`, settling, held) as secondary text. Keep random/mutate/breed grouped and preserve their semantics.
2. Verify default and CENTRE frame whole attractors with breathing room across wide/tall presets. Keep measurement-based fitting; do not add a generic bounding-sphere camera rewrite. Change framing constants only if S0 shows clipping at the actual headset pose.
3. Preserve slow ambient spin, drift controls and stable hold. Suppress decorative UI motion while the controller is pointing; no new particles, trails, stars or room geometry.

**Done:** names/status fit, no UI appears across the specimen during normal viewing, recenter works after a large two-hand scale, and morph endpoints do not jump.

## Deferred

HDR accumulation/compositor redesign is a separate research project. Do not switch to Forward+ or restore the abandoned atomic splat path for this polish pass. If F1 reaches the buffer's quality ceiling, return evidence rather than promising a one-line tone-map fix.

**Web difference:** web already has per-eye HDR/log-density composition (`src/engine/Compositor.ts`). Do not copy native brightness numbers into it. Carry across hierarchy and evaluation scenes, then tune independently.
