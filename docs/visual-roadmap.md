# FractalXR — Visual Polish & Wow-Factor Roadmap

> **Baseline:** `edce99e` (2026-11-21) · **Target:** Native Quest 3 (`godot/`, Godot 4.7 Forward Mobile, Adreno 740, 72 Hz / 13.89 ms budget)
> **Purpose:** Durable reference & progress tracker for working through visual upgrades one bounded step at a time without losing architectural context or Quest performance discipline.

---

## Executive Summary & Tracker

| ID | Phase | Mode(s) | Upgrade | GPU cost (estimate, unmeasured) | Risk | Status |
|---|---|---|---|---|---|---|
| **V1** | 1 · Materiality | `IFS` | Metallic/crystal shading + traveling generation glow pulses | ~0.1–0.2 ms | Low | `[d]` Mac renders only, Quest unverified |
| **V2** | 1 · Materiality | `BULB`, `FLY`, `IFS`, `GROUND`, `TREE` | Physical finishes (`Iridescent`, `Magma`, `Jade`, `Chrome`) | ~0.1–0.3 ms | Low–Med | `[d]` Mac renders only, Quest unverified |
| **V3** | 1 · Materiality | `GROUND` (`COAST`) | Animated ocean ripples, Fresnel sky reflection & shoreline foam | ~0.15 ms | Low | `[d]` Mac renders only, Quest unverified |
| **V4** | 1 · Materiality | `BULB` (`MARCH`) | Specular highlights, two-tone sky/ground ambient & `art_style` | ~0.05 ms | Low | `[d]` Mac renders only, Quest unverified |
| **V5** | 2 · Atmosphere | `FLY` (`SPIRES`, `VAULT`) | Gradient sky (zenith to horizon), sun halo and disc, fog that follows the gradient and scatters toward the sun | ~0.15 ms | Low | `[d]` Mac renders only, Quest unverified |
| **V6** | 2 · Atmosphere | `TREE` (`AVENUE`) | Exponential distance fog + canopy bounce tint on trunks | ~0.05 ms | Low | `[d]` Mac renders only, Quest unverified |
| **V7** | 2 · Atmosphere | `TREE` (every layout) | GPU-driven drifting petals, spores & fireflies in the wind field | ~0.2–0.4 ms | Low–Med | `[d]` Mac renders only, Quest unverified |
| **V8** | 2 · Atmosphere | `SKY`, `GROUND` | SKY hue follows CYCLE (the drift and the ground horizon blend were removed, see below) | ~0.05 ms | Low | `[d]` Mac renders only, Quest unverified |
| **V9** | 3 · VR Presence | `BULB`, `FLY`, `IFS`, `GROUND`, `TREE` | Hand-held proximity lantern light (`hand_light_pos` global uniform) | ~0.1 ms | Low | `[d]` Mac renders only, Quest unverified |
| **V10** | 3 · VR Presence | `GROUND` | Slowly orbiting low sun sweeping relief shadows across terrain | ~0.0 ms | Low | `[ ]` built; `logic_check.sh` checks where it applies, no harness renders it, Quest unverified |
| **V11** | 3 · VR Presence | `FLAME` (`GALAXY`) | Subtle aerial depth color-grading for foreground/background separation | ~0.05 ms | Low | `[ ]` built; `flame_scale_shot.sh` checks it on points and splats, Quest unverified |
| **V12** | 4 · Polish | All modes | Fade in from dark on a mode switch (exposure ramp, XR only; not a cross-fade) | ~0.0 ms | Low | `[ ]` XR only: no Mac render covers it, Quest unverified |
| **V13** | 4 · Polish | All modes | Optional audio-reactive motion/glow pulse (deferred from `SPEC.md`) | ~0.1 ms | Medium | `[ ]` Todo |

### Recommended Starting Order (Quick-Win Starter Pack)
1. **V1 (IFS Shading & Pulses)** — highest immediate visual delta; IFS natural mode is currently flat-shaded.
2. **V5 (FLY Sky & In-Scattering Fog)** — transforms `SPIRES` and `VAULT` from flat-color haze into golden-hour vistas.
3. **V2 (Physical Finishes)** — multiplies the visual variety of every solid mode (`BULB`, `FLY`, `IFS`).
4. **V6 + V7 (Forest Fog + Drifting Petals/Spores)** — makes `TREE` `AVENUE` / `WALK` feel genuinely enchanted.
5. **V9 (Hand-Held Proximity Light)** — biggest single VR presence multiplier across all solid modes.

---

## Non-Negotiable Quest 3 Guardrails

Every task in this roadmap must preserve these invariants:

1. **Forward Mobile & Early-Z / LRZ discipline:**
   * Do **not** add `discard` to default opaque shaders ([bulb_solid.gdshader](../godot/shaders/bulb_solid.gdshader), [ground.gdshader](../godot/shaders/ground.gdshader), [ifs.gdshader](../godot/shaders/ifs.gdshader), [tree.gdshader](../godot/shaders/tree.gdshader)). Follow the existing lazy shader-variant pattern (`inside_passthrough` in `fractal_ground.gd`, `HEAD_CLIP` in `fractal_ifs.gd`) whenever discard is strictly needed.
2. **Stereo coherence & zero shimmer (MSAA is off):**
   * Every pattern, reflection, ripple, and light term must live in **world or model/state space**—never screen-space effects that diverge between eyes.
   * Gate high-frequency procedural detail with `fwidth()` (as in [styles.gdshaderinc](../godot/shaders/styles.gdshaderinc) and [tree.gdshader](../godot/shaders/tree.gdshader)) so distant surfaces fade smoothly to their mean instead of crawling.
3. **Auto-Glow & HDR discipline:**
   * [`_sync_glow()`](../godot/scripts/main.gd) turns `Environment.glow_enabled` off in non-HDR modes to save full-screen bloom passes. Any new finish or effect that intentionally emits `ALBEDO > 1.0` (e.g., `V1` pulses, `V2` Obsidian/Lava crevices) must update `_sync_glow()` so bloom turns on **only** when that feature is active.
4. **Passthrough (MR) safety:**
   * Keep `env.background_color.a == 0` in passthrough. Never enable an opaque procedural sky or full-screen fog tint over passthrough; distance fog must either stay off or fade cleanly in MR.
5. **Verification before promoting defaults:**
   * Run `godot/tools/parse_all.sh` and `godot/tools/shader_check.sh` on every change, capture before/after shots using the mode's existing `*_shot.sh` harness, and keep desktop appearance verified separately from final Quest 3 stereo/frame-time sign-off.

---

## Phase 1 — High-Payoff Materiality & Shading

### V1 · IFS Metallic/Crystal Shading & Generation Light Pulses
* **Status:** `[d]` Mac renders only, Quest unverified (see the council notes below)
* **Current limitation:** In natural mode, [ifs.gdshader](../godot/shaders/ifs.gdshader#L140-L142) outputs `texture(ramp, vec2(fract(v_u), 0.5)).rgb * v_shade * brightness`, where `v_shade` is only the 3-value baked `AXIS_SHADE` (`0.66, 1.0, 0.82` in [fractal_ifs.gd](../godot/scripts/ifs/fractal_ifs.gd#L42)). There is no specular highlight, no Fresnel sheen, no depth shading, and no emissive life.
* **Visual goal:** Make IFS sculptures (`CATHEDRAL`, `MONOLITH`, `PAGODA`, `CRYSTAL`, etc.) read like precision anodized metal or glowing crystal architecture, with gleaming highlights as they rotate/breathe and a subtle traveling pulse of light rippling from the root frame out through each recursive generation.
* **Target files:**
  * [ifs.gdshader](../godot/shaders/ifs.gdshader)
  * [fractal_ifs.gd](../godot/scripts/ifs/fractal_ifs.gd)
  * [main.gd](../godot/scripts/main.gd) (`_sync_glow` if pulse exceeds `1.0`)
* **Implementation plan:**
  1. Pass `v_level = INSTANCE_CUSTOM.x` and `v_rad = INSTANCE_CUSTOM.y` to `fragment()` (or pack into one `varying vec2 v_meta`).
  2. In `fragment()` (natural branch):
     * Compute `n = normalize(NORMAL)`, `v = VIEW`, `ndv = clamp(dot(n, v), 0.0, 1.0)`.
     * Add a fixed view-coherent world key light (`v_light` transformed in `vertex()`, same pattern as [bulb_solid.gdshader](../godot/shaders/bulb_solid.gdshader#L171)): diffuse + metallic tinted Blinn-Phong sheen (`pow(ndh, 24.0)`) + tight glint (`pow(ndh, 90.0)`).
     * Add a subtle Fresnel edge rim (`pow(1.0 - ndv, 3.0)`) tinted by the bright end of `ramp`.
     * Blend a gentle depth/cavity gradient using `v_rad` (inner core slightly deeper, outer tips crisper) to amplify monumental scale in room-size mode.
     * Add an optional traveling **energy pulse**: `float pulse = pow(max(0.0, sin(v_level * 6.28318 - anim_t * 1.4)), 12.0)` (gated off when `MOTION` is off or `pulse_gain == 0.0`). Pushing the pulse peak slightly past `1.0` triggers soft bloom along recursive rings.
  3. Keep `echo_gain` and `echo_glow` multiplying cleanly so room-scale echoes stay recessed behind the hero.
* **Est. GPU cost:** ~0.1–0.2 ms (ALU plus one extra ramp fetch for the highlight colour, no `discard`).
* **Verification:** `godot/tools/ifs_shot.sh`, `godot/tools/ifs_echo_shot.sh`, `godot/tools/ifs_check.sh`, `godot/tools/shader_check.sh`.

---

### V2 · Physical Surface Finishes (`Iridescent`, `Obsidian/Lava`, `Jade/SSS`, `Sky-Chrome`)
* **Status:** `[d]` Mac renders only, Quest unverified (see the council notes below)
* **Current limitation:** [styles.gdshaderinc](../godot/shaders/styles.gdshaderinc) provides 4 great NPR styles (`neon`, `toon`, `pencil`, `circuit`), but natural mode in [bulb_solid.gdshader](../godot/shaders/bulb_solid.gdshader#L290-L305) has only one fixed metallic finish with a hardcoded blue Mandelbulber rim.
* **Visual goal:** Offer rich physical material finishes (either as additional entries in `STYLE` or a dedicated `FINISH` control when `STYLE == natural`) that make solid bulbs, `FLY` worlds, and `IFS` sculptures look dramatically different without rebuilding meshes:
  * **Iridescent (Bismuth / Thin-Film):** View-angle interference (`0.5 + 0.5 * cos(6.28318 * (ndv * 1.6 + trap + vec3(0.0, 0.33, 0.67)))`) blended into the metallic specular & Fresnel rim. Enhances stereo depth because left and right eyes sample slightly different interference phases.
  * **Obsidian & Magma (Bioluminescent Crevices):** Dark glossy volcanic stone on exposed ridges (`v_ao` high) with glowing emissive theme color (`pal3`/`pal4` pushed `> 1.0` to bloom) deep inside crevices (`pow(1.0 - v_ao, 3.0)`). Looks extraordinary in `VAULT` and Mandelbulbs.
  * **Jade / Alabaster (Fake Subsurface Scattering):** Soft wrapped diffuse (`max((dot(n, l) + 0.5) / 1.5, 0.0)`) + backlit transmission (`pow(clamp(dot(-l, VIEW), 0.0, 1.0), 4.0) * v_ao * albedo`) so thin fractal ridges glow warmly from behind.
  * **Liquid Chrome / Sky Reflection:** Reflect `-VIEW` across `n` into world space and sample either the active `flame_sky` cubemap/equirect or a fast procedural 3-band studio reflection gradient.
* **Target files:**
  * [bulb_solid.gdshader](../godot/shaders/bulb_solid.gdshader)
  * [ifs.gdshader](../godot/shaders/ifs.gdshader)
  * [project.godot](../godot/project.godot) (optional `material_finish` shader global, or extend `art_style`)
  * [main.gd](../godot/scripts/main.gd) (`ART_NAMES` / `_sync_glow`)
  * [shared_items.gd](../godot/scripts/menu/shared_items.gd)
* **Design decision to make before implementing:** Extend `STYLE` (`natural, neon, toon, pencil, circuit, iridescent, magma, jade, chrome`) vs. add a separate `FINISH` tile. Extending `STYLE` avoids adding menu clutter and works automatically across `BULB`, `FLY`, `IFS`, and `GROUND`.
* **Est. GPU cost:** ~0.1–0.3 ms (pure ALU except `Sky-Chrome` which adds 1 filtered cubemap/2D fetch).
* **Verification:** `godot/tools/solid_shot.sh`, `godot/tools/fly_shot.sh`, `godot/tools/style_shot.sh`.

---

### V3 · Living Ocean & Shoreline in `GROUND` `COAST`
* **Status:** `[d]` Mac renders only, Quest unverified (see the council notes below)
* **Current limitation:** In [ground.gdshader](../godot/shaders/ground.gdshader#L199-L202), `COAST` mode (`relief_mode == 4`) explicitly treats the set interior (`inside`) as a flat sea at height `0`, shaded with static `inside_colour * (0.4 + 1.2 * s.a)`.
* **Visual goal:** Give the `COAST` sea gentle animated wave normals, Fresnel reflection of the sky/horizon, sun glint across the ripples, and a crisp luminous shoreline foam/caustic band along the fractal beach.
* **Target files:**
  * [ground.gdshader](../godot/shaders/ground.gdshader)
* **Implementation plan:**
  1. Guard strictly behind `relief_mode == 4 && inside > 0.01 && art_style == 0` (and skip when `inside_passthrough > 0.5`).
  2. Compute 2–3 world-space Gerstner/sine wave derivatives on `v_world.xz` using `TIME`, faded smoothly by `fwidth(v_world.xz)` so distant waves never shimmer.
  3. Perturb water normal `nw`, compute Schlick Fresnel `pow(1.0 - max(dot(nw, V), 0.0), 4.0)` blending deep sea `inside_colour` toward sky/fog tint, plus a sharp sun specular sparkle from `light_dir`.
  4. Near the beach (`smoothstep(0.0, 0.35, coast_height(s))` fading back out), add a subtle animated shoreline foam/glow edge modulated by `s.a`.
* **Est. GPU cost:** ~0.15 ms (only runs on `inside` fragments in `COAST` mode).
* **Verification:** `godot/tools/coast_shot.sh`, `godot/tools/ground_check.sh`.

---

### V4 · Upgraded Raymarched Bulb Shading
* **Status:** `[d]` Mac renders only, Quest unverified (see the council notes below)
* **Current limitation:** [march.gdshader](../godot/shaders/march.gdshader#L158-L183) only computes simple `ndv` + `ndk` diffuse and a fixed `pal4` rim—no specular highlights, no sky/ground bounce contrast, and no `art_style` support.
* **Visual goal:** Bring raymarched bulbs up to parity with `SOLID` so switching `SURFACE` to raymarched feels like an instant sharpness upgrade rather than a lighting downgrade.
* **Target files:**
  * [march.gdshader](../godot/shaders/march.gdshader)
* **Implementation plan:**
  1. Add metallic tinted Blinn-Phong sheen + tight gloss highlight (matching [bulb_solid.gdshader](../godot/shaders/bulb_solid.gdshader#L293-L298)) using `KEY` and `v`.
  2. Replace flat `0.16` ambient with a two-tone hemisphere ambient (`mix(ground_tint, sky_tint, n.y * 0.5 + 0.5) * ao`).
  3. Optionally include `styles.gdshaderinc` (with `ART_GLOBAL`) so `neon` / `toon` / `pencil` / `circuit` work on raymarched surfaces too.
* **Est. GPU cost:** ~0.05 ms (negligible compared to the DE march loop).
* **Verification:** `godot/tools/march_shot.sh`, `godot/tools/shader_check.sh`.

---

## Phase 2 — Atmosphere, Depth & Living Environments

### V5 · Procedural Sky, Sun Disc & Directional In-Scattering Fog in `FLY`
* **Status:** `[d]` Mac renders only, Quest unverified (see the council notes below)
* **Current limitation:** In [bulb_fly.gd](../godot/scripts/sources/bulb_fly.gd#L79-L106), `SPIRES` and `VAULT` clear the background to a flat uniform color (`Color(0.58, 0.7, 0.86)`) and [bulb_solid.gdshader](../godot/shaders/bulb_solid.gdshader#L308-L311) fades distance fog to a single uniform `fog_colour`.
* **Visual goal:** Give `SPIRES` and `VAULT` a rich atmospheric dome (deep zenith fading to luminous horizon haze + crisp glowing sun disc aligned with `light_dir`) and match it with sun-tinted directional fog scattering on the fractal geometry—creating dramatic golden-hour / god-ray depth through towers and canyons.
* **Target files:**
  * New shader: `godot/shaders/fly_sky.gdshader` (lightweight procedural `shader_type sky;`, `AT_CUBEMAP_PASS` returns `vec3(0.0)` like [mandel_sky.gdshader](../godot/shaders/mandel_sky.gdshader#L121))
  * [bulb_solid.gdshader](../godot/shaders/bulb_solid.gdshader#L308-L311)
  * [bulb_fly.gd](../godot/scripts/sources/bulb_fly.gd)
  * [main.gd](../godot/scripts/main.gd) (attach `fly_sky` when in `FLY` + `!passthrough` + `art_style == 0` and no custom `flame_sky` active)
* **Implementation plan:**
  1. Write `fly_sky.gdshader`: zenith-to-horizon vertical gradient (`pow(1.0 - max(d.y, 0.0), 3.0)`), Mie halo (`pow(max(dot(d, sun_dir), 0.0), 8.0)`), and soft HDR sun disc (`smoothstep(0.9985, 0.9995, dot(d, sun_dir))`). Respect `floor_keep` below horizon.
  2. In `bulb_solid.gdshader`, upgrade the 3-line fog block so `fog_col = mix(fog_colour, key_colour * 1.15, pow(max(dot(-normalize(VERTEX), v_light), 0.0), 6.0) * sun_scatter)`.
  3. Keep `STYLE` skies (`neon` dark night, `toon` blue, `pencil` paper, `circuit` dark green) intact when `art_style > 0`, and keep transparent background in passthrough.
* **Est. GPU cost:** ~0.15 ms (runs only on uncovered sky pixels + 3 extra ALU ops in `bulb_solid` fog).
* **Verification:** `godot/tools/fly_shot.sh`, `godot/tools/style_shot.sh`.

---

### V6 · Forest Distance Fog & Canopy Bounce Light in `TREE`
* **Status:** `[d]` Mac renders only, Quest unverified (see the council notes below)
* **Current limitation:** [tree.gdshader](../godot/shaders/tree.gdshader#L2) and [tree_leaf.gdshader](../godot/shaders/tree_leaf.gdshader#L2) both set `fog_disabled` with no manual distance attenuation, so a 500-tree `AVENUE` stops sharply against black void and trunks look slightly detached from their glowing canopies.
* **Visual goal:** Far avenue trees dissolve smoothly into twilight atmospheric haze, and upper branches/trunks catch a warm downward bounce glow from their own luminous canopy.
* **Target files:**
  * [tree.gdshader](../godot/shaders/tree.gdshader)
  * [tree_leaf.gdshader](../godot/shaders/tree_leaf.gdshader)
  * [forest.gd](../godot/scripts/tree/forest.gd) (feed avenue fog radius & color, disabled in passthrough)
* **Implementation plan:**
  1. In `tree.gdshader`: add a subtle canopy bounce term `pal3 * 0.12 * smoothstep(0.3, 1.0, u) * max(n.y * 0.5 + 0.5, 0.0)` so upper wood glows softly under the leaves.
  2. Add 3-line exponential distance fog in `tree.gdshader` (`ALBEDO = mix(fog_colour, ALBEDO, exp(-fd * fd))` when `fog_density > 0.0`, set to `0.0` in passthrough) and fade additive leaf gain with distance in `tree_leaf.gdshader` so distant canopies soften into mist instead of hard bright dots.
* **Est. GPU cost:** ~0.05 ms.
* **Verification:** `godot/tools/forest_shot.sh`, `godot/tools/avenue_shot.sh`, `godot/tools/tree_look_shot.sh`.

---

### V7 · Drifting Wind-Carried Petals, Spores & Fireflies in `TREE`
* **Status:** `[d]` Mac renders only, Quest unverified (see the council notes below)
* **Current limitation:** The forest has swaying canopies and static fallen `tree_litter`, but the air between the trees is completely empty.
* **Visual goal:** Send 500–1,000 gentle, luminous petals (sakura), needles/spores (oak/willow/pine), or crystal motes (crystal) drifting through the avenue in the exact same `wind_dir`, giving huge VR parallax and magic during `AVENUE` and `WALK`.
* **Target files:**
  * New shader: `godot/shaders/tree_motes.gdshader`
  * [forest.gd](../godot/scripts/tree/forest.gd) (one `MultiMeshInstance3D`; no buffer writes, three uniforms a frame: walk, drift and clock)
  * [tree_items.gd](../godot/scripts/menu/tree_items.gd) (tied to `FLOOR` or `WIND` / optional toggle)
* **Implementation plan:**
  1. Create a single `MultiMesh` of ~600–800 tiny camera-facing quads (2 triangles each) with random per-instance seed `(x, y, z, phase)` in `INSTANCE_CUSTOM`.
  2. In `tree_motes.gdshader` `vertex()`:
     * Advance position analytically using `TIME`, `wind_dir`, gentle downward drift + sinusoidal swirl, and `walk_offset` (so motes flow past naturally during `WALK`).
     * Wrap modulo a 14 m × 6 m × 14 m box centered on `CAMERA_POSITION_WORLD` using `mod()`, and fade smoothly at box boundaries and within `0.5 m` of the eyes (`near_fade`, preventing stereo fusion strain).
     * Match active species `leaf_shape` (petal / sparkle / soft orb) and palette + `colour_cycle`.
* **Est. GPU cost:** ~0.2–0.4 ms, unmeasured (tiny additive quads, no buffer writes, `depth_draw_never`).
* **Verification:** `godot/tools/avenue_shot.sh`, `godot/tools/forest_shot.sh`.

---

### V8 · Living Skies & Seamless `GROUND` Horizon Blending
* **Status:** `[d]` Mac renders only, Quest unverified (see the council notes below)
* **Current limitation:** [flame_sky.gdshader](../godot/shaders/flame_sky.gdshader) is completely static, and [ground.gdshader](../godot/shaders/ground.gdshader#L791-L793) always fades the outer ground edge into a fixed dark `fog_colour`, creating a dark band between the terrain and bright skies (`mandel_sky` / `flame_sky`).
* **Visual goal:** Make skies gently breathe in sync with `colour_cycle` and subtle celestial drift, and blend the `GROUND` horizon seamlessly into whatever sky hangs behind it.
* **Target files:**
  * [flame_sky.gdshader](../godot/shaders/flame_sky.gdshader)
  * [ground.gdshader](../godot/shaders/ground.gdshader)
  * [main.gd](../godot/scripts/main.gd)
* **Implementation plan:**
  1. In `flame_sky.gdshader`: add optional very slow yaw rotation (`sky_drift * TIME`, e.g. 0.004 rad/s—slow enough for zero vestibular discomfort) and optional `colour_cycle` Rodrigues hue rotation (same `hue_turn()` used in `tree.gdshader`) so the sky harmonizes when `COLOUR CYCLE` is active.
  2. In `ground.gdshader` / `main.gd`: when `mandel_sky` or `flame_sky` is active (and not in passthrough), tint `fog_colour` toward the active palette's horizon tone (or sample the sky's lower-horizon average color) so the fractal floor dissolves into the sky instead of a dark ring.
* **Est. GPU cost:** ~0.05 ms.
* **Verification:** `godot/tools/mandel_sky_shot.sh`, `godot/tools/ground_shot.sh`.

---

## Phase 3 — Interactive VR Presence

### V9 · Hand-Held Lantern / Proximity Light
* **Status:** `[d]` Mac renders only, Quest unverified (see the council notes below)
* **Current limitation:** `VAULT` has a `head_light` glued to the camera ([bulb_solid.gdshader](../godot/shaders/bulb_solid.gdshader#L301-L304)), which moves with your gaze instead of letting you explore surfaces with your hands.
* **Visual goal:** Moving your controller close to a Mandelbulb crevice, `VAULT` canyon wall, `IFS` interior, `TREE` bark, or `GROUND` cliff casts a soft, physically grounded warm/theme-tinted point light + specular reflection from your hand—an unmistakable "it's really in the room with me" VR moment.
* **Target files:**
  * [project.godot](../godot/project.godot) (add global uniforms `hand_light_pos` (`vec3`) and `hand_light_col` (`vec3`, `vec3(0.0)` when off))
  * [main.gd](../godot/scripts/main.gd) (update `RenderingServer.global_shader_parameter_set` once per frame from `right_hand.global_position`, plus a toggle in menu or automatic gentle glow when not pointing at the wrist menu)
  * [bulb_solid.gdshader](../godot/shaders/bulb_solid.gdshader), [ifs.gdshader](../godot/shaders/ifs.gdshader), [ground.gdshader](../godot/shaders/ground.gdshader), [tree.gdshader](../godot/shaders/tree.gdshader), [march.gdshader](../godot/shaders/march.gdshader)
* **Implementation plan:**
  1. Set `hand_light_pos` in world space once per frame from `right_hand` (or midpoint/stronger of active controller), and set `hand_light_col` to a soft warm/palette-accent tint scaled by intensity (zero when `hand_light` is disabled or on desktop harnesses unless requested).
  2. In each solid fragment shader, add 5 lines:
     ```glsl
     if (dot(hand_light_col, hand_light_col) > 1e-4) {
         vec3 hl = hand_light_pos - world_pos;
         float d2 = dot(hl, hl);
         float att = 1.0 / (1.0 + d2 * 1.8);
         vec3 hdir = hl * inversesqrt(max(d2, 1e-6));
         c += albedo * hand_light_col * max(dot(world_n, hdir), 0.0) * att;
     }
     ```
  3. Optionally draw a tiny soft orb at the controller tip when the lantern is on so the light source feels anchored.
* **Est. GPU cost:** ~0.1 ms (5–8 ALU ops per fragment, early-skipped when off).
* **Verification:** as planned, `solid_shot.sh`, `ifs_shot.sh` and `ground_shot.sh` with a synthetic `hand_light_pos`. As built, see the council section below.

---

### V10 · Slowly Orbiting Sun in `GROUND`
* **Status:** `[ ]` built; `logic_check.sh` checks where SUN applies (RELIEF, BUMP or a finish), no harness renders it, Quest unverified (see the council notes below)
* **Current limitation:** `light_dir` in [ground.gdshader](../godot/shaders/ground.gdshader#L76) is static (`vec3(0.5, 0.5, 0.35)`).
* **Visual goal:** Because `GROUND` computes hillshade normals and speculars live per pixel, slowly rotating `light_dir` around the horizon (e.g., 1 full turn per 90–120 s when `MOTION` / `SUN` is enabled) makes relief shadows and highlights glide cinematically over fractal canyons and terraces.
* **Target files:**
  * [fractal_ground.gd](../godot/scripts/ground/fractal_ground.gd)
  * [ground_items.gd](../godot/scripts/menu/ground_items.gd)
* **Est. GPU cost:** 0.0 ms (1 uniform update per frame on CPU).
* **Verification:** `godot/tools/ground_shot.sh` at two sun azimuths.

---

### V11 · Depth Color-Grading in `FLAME` (`GALAXY`)
* **Status:** `[ ]` built. `flame_scale_shot.sh` checks `depth_grade` is 1 on the point and the splat material as GALAXY sets it (read before the harness writes it), still 1 on both when SPLAT goes on inside (zeroed first, so it is main.gd's own write), and 0 after leaving, and renders the grade off, on and off: points at GALAXY's settings lose 7.7% linear luma and their blue gains 9% on their red; SPLAT, with the near splats faded out (`near_fade` 8 m, for the check only), loses 2.8% and gains 3%. At the default settings the grade moves the SPLAT frame about 0.2% (the points' 7.7%): the splats inside 3.5 m cover the far ones it tints. Whether that is worth keeping on SPLAT is a headset call. Quest unverified (see the council notes below)
* **Current limitation:** In [points.gdshader](../godot/shaders/points.gdshader#L145-L148), all particles at distances beyond `near_fade` have identical color saturation regardless of depth, so inside a 24 m `GALAXY` foreground tendrils and distant clouds can visually flatten together.
* **Visual goal:** Gently cool and slightly dim far-field particles in `GALAXY` (in `vertex()`, zero fragment cost) so nearby filaments pop vividly in front of deep cosmic clouds in stereo.
* **Target files:**
  * [points.gdshader](../godot/shaders/points.gdshader)
  * [flame_galaxy.gd](../godot/scripts/core/flame_galaxy.gd)
* **Est. GPU cost:** ~0.05 ms (vertex-stage only, only active when `depth_grade > 0.0`).
* **Verification:** `godot/tools/flame_scale_shot.sh`.

---

## Phase 4 — Polish & Sensory Multipliers

### V12 · Smooth Mode Transitions
* **Status:** `[ ]` XR only, so no Mac render covers it; Quest unverified (see the council notes below)
* **Current limitation:** Switching between `FLAME`, `BULB`, `GROUND`, `TREE`, and `IFS` swaps node visibility instantaneously, which can feel abrupt in VR.
* **Visual goal:** Add a crisp ~0.35 s ease-out brightness/exposure dip-and-bloom (or scale settle) on mode switches so transitioning between worlds feels intentional and museum-grade.
* **Target files:** [main.gd](../godot/scripts/main.gd)
* **Est. GPU cost:** 0.0 ms.

---

### V13 · Subtle Audio Reactivity / Ambient Pulse (Optional)
* **Status:** `[ ]` Todo (not started)
* **Context:** Noted as deferred in [SPEC.md](../SPEC.md#L18).
* **Visual goal:** Expose a lightweight smoothed `audio_energy` float (from either an optional subtle procedural ambient synth bus or Quest microphone input, strictly opt-in) that gently modulates `IFS` pulse brightness, `TREE` wind gusts, `FLAME` echo glow, or `V2` magma crevice intensity.
* **Note:** Quest microphone requires `RECORD_AUDIO` permission (note [README.md](../README.md#L96) highlights "asks for no permissions"); an internal optional generative ambient soundscape avoids any Android permission prompts while delivering the same audiovisual synergy.

---

## Council review, 2026-11-21

Four reviewers (GPT Sol, Claude Opus, Gemini Neon, Claude Fable) went through `fbebcf4..HEAD`.
The costs in the table above were never measured; treat them as guesses until a Quest
`[perf]` line says otherwise. What the council changed, rounds 1 to 4:

- **Broke FLY and SOLID:** `physical_finish()` named a parameter `key` and locals `tint` and
  `rim`, all uniforms in `bulb_solid.gdshader`, so it did not compile and every FLY world drew
  black. Renamed. CI had been red on both commits.
- **V2:** a preset change in FLY BULB dropped STYLE to natural (fixed). The finishes' look
  (magma, jade, iridescent, chrome) is Sam's to judge on the headset; unchanged.
- **V1:** the pulse runs only with MOTION (on by default), at half its first gain, one swell about every
  20 s, easing in and out over half a second. It keeps running while a handle is held or a dive
  steps (it is light, not shape; dropping it there stepped the beams dark and back at another
  phase). At 0.25 it stays under 1.0, so the plan's "soft bloom" is not built: natural IFS keeps
  Glow off. IFS neon is back to its old brightness (the normal flip had dimmed it to a quarter).
- **V3:** three swells at unrelated angles (the crossed pairs tiled into a quilt), under 1 rad/s,
  and the sea reflects the horizon fog, so it stays dark.
- **V5:** the sky's sun direction is written only when it changes (every write re-rendered the
  sky radiance), the fog follows the sky's zenith gradient, the sky below the horizon is the
  fog's colour, the sun disc is about 2.5 degrees, and the light sources it turns off are put back.
- **V7:** motes drew in every mode until TREE was left once (fixed). Their drift follows the
  trees' wind, integrated per frame so a WIND change no longer jumps them; spin and twinkle slowed.
- **V8:** the slow drift is gone (TIME in a sky shader re-renders its radiance every frame and
  jumps at the hourly rollover), and so is the theme-tinted ground horizon (it matched neither a
  baked sky nor MANDEL). The CYCLE hue turn keeps each texel's luma, as the points' CYCLE does:
  turning about the grey axis alone pumped the skies' brightness (Ember +49%, Nautilus -39% a
  third of the way round). `flame_scale_shot.sh` checks it on screen, in the band of the frame that is sky only: Ember reads -11.8% (the unkept turn +247%), which the tonemapper does not explain (under 2% modelled) and is most likely 8-bit quantisation near black, so the bound is 20%.
- **V9:** LANTERN is off by default, hidden under the NPR styles (which never drew it), skipped
  where no shader reads it, and dims to a quarter while the menu is open (eased over 0.2 s). On
  SOLID it adds at a quarter, shaded by AO: at full strength it washed the hand-sized bulb to
  cream. Checked by `style_shot.sh` (GROUND, TREE, IFS), `march_shot.sh`, `solid_shot.sh` (which
  also fails a burn of more than 1% of lit pixels) and `logic_check.sh` (the gate in `main.gd`).
  FLY's worlds are room scale and take it at full strength (`lantern_k`); a BULB flight eases it
  by the bulb's width, from the quarter at SOLID's 0.35 m across to full by 1.4 m, one value on
  every level so no seam shows between them (`fly_shot.sh` checks both ends, and the reset on
  leaving). On MIRROR's ceiling it lights from below as a real light would
  (`coast_shot.sh` compares the ceiling's gain with the floor's).
- **MIRROR (V2, V3):** the ceiling is the floor drawn again face down with the floor's normals, so
  its view is mirrored before any view-dependent term: its sea and finishes now show the floor's
  reflection (`coast_shot.sh`, with the clock stopped between the two shots).
- **V3:** the swells and the shore ripple skip their sines where their weight is zero.
- **V5:** with the backdrop taken down (passthrough, a flame or preset SKY), every FLY level fogs
  flat and keeps its density; `fly_shot.sh` takes it down through the SKY PICK tile.
- **MARCH:** a missed ray is discarded straight after the normal's derivatives except under the
  four line styles, which take derivatives after it.
- **V10:** one turn in six minutes, not ninety seconds. The shader reads `light_dir` only under
  relief or bump or in a finish, so on flat, unbumped ground in natural or a line STYLE the SUN
  tile hides and the orbit stops writing (`logic_check.sh`).
- **V11:** applies to SPLAT on too.
- **Splat cull:** the early frustum cull's margin is the largest splat in this viewport's NDC
  (`1 + 2 * MAX_PIXEL_RADIUS / VIEWPORT_SIZE`), not a fixed 1.4.
- **Splats (`5c155e5`):** the skirt trim is gone; every splat that survives the 0.002 cull
  draws its whole footprint again. The trim only ever cut faint splats, and under "over"
  blending a faint halo also dims what lies behind it, so cutting halos made LINES' grazing
  views brighter, not darker: Classic side-on read 0.0168 mean linear luma trimmed against
  0.0085 at `fbebcf4`. `fbebcf4`'s scene with today's splat shader reads 0.0085, the same.
- **Glow (`edce99e`, open):** `_sync_glow()` turns Glow off for a natural BULB, and that alone
  leaves LINES side-on 40-50% brighter than `fbebcf4` (0.0120 to 0.0130; 0.0085 with Glow forced
  on). Left for Sam to judge in the headset: Glow costs a blur pass, and the off look may be the
  one he prefers.

## Working Protocol (Per Task)

When we pick up any item `Vx`:
1. Re-read its section above and inspect the current target shaders/scripts.
2. Implement cleanly within the Quest 3 guardrails (no `discard` regressions, stereo-coherent math, `_sync_glow()` updated if HDR, MR-safe).
3. Run `godot/tools/parse_all.sh`, `godot/tools/shader_check.sh`, and the relevant `*_shot.sh` capture if Godot is available in the environment.
4. Update the **Status** column in this file (`[ ]` Todo → `[~]` In Progress → `[d]` Desktop Verified → `[x]` Quest Verified) and record any measured notes.
