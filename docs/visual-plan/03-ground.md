# GROUND · Fractal landscape

Read [common contract](README.md). Target: crisp nearby structure, quieter distance, an intentional horizon, and a clear distinction between solid interior and room-through-interior.

Keep flat entry (`GROUND_HEIGHT[0] = 0`), floor-relative movement, pan/zoom, Julia selection and user-controlled relief. Do not add automatic terrain movement or turn flat entry into mountains.

## G1 · Calm distant colour without losing nearby detail

**Dependency:** S0 fresh ground capture. **Files:** `godot/shaders/ground.gdshader`; `godot/scripts/ground/fractal_ground.gd` / `main.gd::_apply_ground_look()` only for necessary mode-local uniform plumbing; ground capture helper.

1. Capture default Mandelbrot, Julia and a deeper boundary view after tiles settle. Include flat, terrain and terraces; record zoom and render quality. The inspected Sep 12 capture predates current MR work.
2. Reuse existing distance, selected levels and derivatives. Existing contours already fade with `fwidth`; do not add a second contour implementation. Inspect whether remaining noise is palette repetition, orbit texture or incomplete tiles.
3. For completed tiles, attenuate orbit-texture contrast as its footprint becomes subpixel; keep foreground texture strength unchanged. Blend only the high-frequency modulation toward its local neutral value. No extra compute pass, sample grid or global blur.
4. Align fog colour to the VR background, starting with neutral near-black, so the distant coloured band fades before the radial mesh ends. Keep near/middle contours colourful. Use existing `fog_end` and fog expression; do not add a sky dome or screen-space fog.
5. In MR, preserve the exterior opaque path and the explicit interior discard. Avoid broad dark fog covering the room. Any distance-colour change must be reviewed in passthrough as well as black void.

**Done:** distant boundary is calmer during head movement, no bright terminal stripe, near detail preserved, no tile seams or new texture reads. If apparent noise is unfinished tiles, fix/report the state first rather than hiding it with blur.

**Checks:** parser if host changed; ground spatial shader check; ground captures; Quest pan/zoom and settled views at constant quality.

## G2 · Clarify depth, interior and orbit

**Files:** `ground.gdshader`, `main.gd::_apply_ground_look()`, `godot/scripts/ground/orbit_trace.gd`, menu status only as needed.

1. In solid VR mode, lift `inside_colour` just enough to distinguish the filled set from the void (initial neutral candidate around `#10121B`). Preserve it as a mathematical interior, not an empty/loading state.
2. Keep HEIGHT off at entry. Tune relief lighting using existing `light_dir`, `relief_contrast` and specular term, with before/after at height 0.5 and 1.0. Start by reducing specular multiplier 0.25 → 0.12 if the new captures show broad glossy patches. Do not add shadow maps or displaced collision geometry.
3. Preserve `inside_passthrough = ground_inside_room && passthrough`. INSIDE room must reveal the real room only in MR; returning to VR must restore filled interior. Keep the setting visible and explain its effect through value/status text.
4. Inspect the fixed-scale orbit at actual head height. If it competes with the terrain, reduce its existing brightness/line weight before altering geometry. Keep it hidden while menu shows; do not remap it to world zoom, the earlier source of horizon streaks.

**Done:** interior reads as filled in VR and transparent only when requested in MR; terrain relief remains legible without sparkle; orbit is local and stable; no floor-height jump on a small physical step.

**Checks:** shader check, ground capture, `orbit_check.sh` if orbit changed, forest MR integration capture; headset VR solid → MR solid → MR room → VR sequence, plus SKY off/on/off. Restore user's DETAIL when leaving Ground.

## G3 · Finish the control hierarchy

**Dependency:** S1/S2. **Files:** Ground menu/title/status callbacks in `main.gd`, S3 help text.

- Keep primary choices SET, HEIGHT, relief style, THEME and INSIDE easily reachable. Group texture/bump/frequency separately from performance/detail.
- Use one compact `Mandelbrot · zoom …` title and truthful rendering progress. Do not add scientific coordinates to the normal view.
- Explain SKY as the existing mirrored ceiling using its value/helper text; no new environment selector.

**Done:** primary actions fit, progress finishes correctly, controls remain readable in front of bright terrain, help matches field gestures.

**Web difference:** native Ground is an infinite floor with clipmap levels. Web `/zoom` is a resizable relief panel with banded field updates. They share fractal concepts but not camera, depth or tile plumbing; never port native floor uniforms into the web panel wholesale.
