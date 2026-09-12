# Changelog

All notable changes to FractalXR are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/); this project follows semantic versioning.

## [Unreleased]

## [0.9.0] - 2026-09-12

The first release that is mostly the native Quest build. Web entries are unchanged in
substance; the version fields in `package.json` and `godot/export_presets.cfg` now move
together (the APK had sat at 0.1.0, build code 1, since the first export).

### Added
- **CI parses every GDScript and compiles every spatial shader** on push and PR, with a
  broken control in each step so a silent pass is impossible. The GPU self-test still needs a
  real RenderingDevice and stays a laptop step (`godot/tools/selftest.sh`).
- **Bulb mode opens as a toy.** Entry now puts the bulb hand-sized (0.55 m radius) just over a
  metre ahead and a little below the eyes instead of 2.1x around you. Sam: "a lot better when
  it's smaller and in front of the user, like something to be played with." Grab still scales it.
- **Marcher interior groundwork (desktop only).** `_enter_inside()` puts your head in the shape's
  roomiest hollow at walking scale, turned so the nearest wall is ahead, and switches to the
  raymarched surface. It is not on the headset menu: measured at 85-103 ms GPU per frame at 48
  steps on a 0.6x eye buffer (every pixel of both eyes marching), and full-res 96 steps faulted
  the GPU. It needs a quarter-res pass with reprojection before it is a feature. The hollows
  come from a CPU port of the five distance estimates
  (`BulbSource.de`, cross-checked against the shader's own code by `tools/de_check.sh`) and a
  dev tool, `tools/rooms.sh`, that precomputes each bulb's true extent and best enclosed room
  into `data/rooms.json`. The marcher now starts its rays at the measured extent (the seed
  bound of the scale-2 Mandelbox sat well inside it, which painted a ball of noise), walks out
  of solid when the head is in a wall, stops iterating below the pixel footprint, keeps its
  cover mesh inside the far plane at any scale, and has a 160-step SURFACE tier.
- **TREE mode: a fractal tree as real geometry.** A fourth segment on the mode strip. Oak,
  pine, willow and coral shapes from recursive branching into a MultiMesh of tapered
  cylinders, with glowing leaf discs at the tips; it grows from the base over six seconds and
  bends in one wind field by height, all in the shaders. SHAPE, DEPTH, WIND, LEAVES, SEED and
  REGROW tiles; the right trigger reseeds, the left regrows; grab, scale and SPIN apply as
  they do to the cloud. Takes the theme palette.
- **ORBIT (ground mode): the orbit of the point under your hand.** Point at the floor and
  the iteration z -> z^2 + c from that spot hangs in the air as a chain of beads, climbing a
  little per step: inside the set it circles and settles, outside it flies off to the bailout.
  Julia mode iterates from the point with the ground's constant. 64-bit on the CPU, so it
  stays honest past the texture's zoom limit. ORBIT tile to switch it off.

### Changed
- **Optimisation pass (native build), from the 2026-09-12 audit.** The splat mesh is four
  indexed corners per particle instead of six loose vertices, so the covariance build and eigen
  solve run a third fewer times (pixel-identical: diffed against a before render, inside
  run-to-run noise). The ground relief fetches one 4x4 texel block for the centre and the four
  gradient samples instead of five separate bilinears, 24 fetches down to 16 per pixel with
  relief on (pixel-identical, diffed with the trace off). The wrist menu re-reads its tile values
  at 8 Hz and on hover change instead of every frame, restyles mode tiles only when their state
  flips, and stops animating once folded. The orbit trace links are a MultiMesh of thin
  cylinders instead of an ImmediateMesh rebuilt every frame. The invisible HUD label no longer
  has its text built. A FOVEA tile (off, fixed 1, 2, 3) joins GLOW as a measurement instrument;
  the default stays off until the headset says otherwise.

### Fixed
- **Bulb mode refuses to start on an empty bulb list** instead of indexing it every frame.
- **DETAIL changed on the ground now survives leaving ground mode**; before, the flame's saved
  value was restored blindly.
- **A tracking dropout no longer fires a phantom press** when the hand comes back.
- **Tree depth +2 no longer degrades to a single strand**: the branch cap now truncates the
  deepest level evenly (breadth-first build).
- **The first-run card says which mode it describes** and names the four modes.
- **The perf log line only prints in debug builds.**
- **Cloud setup failures are loud.** Every compute pass (measure, density, bake, sort) records
  a message and stops setup, so a broken shader is a line on screen and in the self-test
  (`SELFTEST detail: measure.glsl failed to compile`) instead of a cascade of invalid-RID errors.
- **Dev tools**: every shot harness now clears its watchdog on any exit (a failed run used to
  leave a pkill that killed the next run four minutes later); `tools/soak.sh` parses the current
  perf line format (it had been producing a CSV of raw log lines under nine empty columns).
- **Web: ENTER MR failures show on the button** ("MR UNAVAILABLE") instead of a silent catch.
- **Web: missing assets return 404** instead of the flames page with a 200; the four pages are
  independent static entries, so the SPA fallback bought nothing and hid broken asset paths.
- **Web: the wrist menu and controls guide take the bulb's palette in bulb mode**; they wore an
  unseen flame's accent. A lost WebGL context now says so instead of freezing on the last frame.
  A failed splat sampler terminates its siblings. The dev server refuses to move off 5173 (the
  headset loop is `adb reverse` on that port). The zoom app's sway honours reduced motion and
  its controls legend passes AA contrast. `npm audit fix` cleared the six dev-only advisories.
- Removed dead code: `_cycle_mode`, `tone_on`.
- **Mandelbox distance estimate bailed out too early.** At |z| > 6 the estimate was not a
  lower bound (97% of sampled points had solid within the promised radius); it bails at
  |z| > 100 now in the compute shader, the marcher and the CPU port alike.
- **Ground mode in the native build: stand on the fractal.** MODE now cycles flame, bulb,
  ground. A Mandelbrot or Julia set is the floor and runs to the horizon: crisp at your feet,
  smooth in the distance, and the frame cost does not depend on zoom or iteration count. It is
  a GPU clipmap (eight 512-texel levels, each twice the scale of the last, all centred under
  you) filled by a compute port of the web zoomer's escape-time core, coloured Frax-style at
  sample time: palette (THEME and BANDS apply), FREQ, HUE, orbit TEXTURE, RELIEF (terraces from
  iteration count or ridges from distance, lit), SET (Mandelbrot or Julia), JULIA from here,
  ITER, HOME. Left stick walks, right stick zooms about your feet. Float32, so useful zoom ends
  around 1e5; perturbation is the follow-up. The self-test fills a stack and checks two points.

- **Ground mode: turning, grabbing, gliding, RENDER, and an honest status line.** Right stick X
  turns the world about you (Y still zooms), left stick walks. Grip drags the world with the hand
  and twists it with the wrist; two hands also zoom by their spread. Point a controller at the
  ground and pull the trigger to glide there. RENDER doubles the level size to 2048 and sets 4096
  iterations for a still that is sharp into the middle distance, and the menu status counts the
  fill in ("rendering 34%" until "sharp"). The menu title shows the set and zoom factor, and the
  flame's morph and drift pause while you are on the ground instead of ticking underneath.
- **Ground mode: sharper, deeper, bumpier, with a sky.** The finest texel is 1.5mm (was 3) with a
  ninth level to keep the horizon; ground mode runs the full eye buffer (DETAIL 1.0x on entry,
  restored on exit) since it draws in ~6ms; ITER goes to 4096 with the fill budget scaled by the
  count so deep settings sharpen over more frames instead of stalling one; relief normals come from
  neighbouring texels of the sampled level rather than screen derivatives, so slopes have
  per-texel detail that coarsens with distance like terrain, and a BUMP dial adds grain from the
  orbit texture; SKY mirrors the ground overhead at 3, 8 or 30m for the cost of one more plane.

### Changed
- **Native build: the self-inflicted stalls are gone.** A flame morph rebuilt the genome
  storage buffer and its uniform set every frame (`FlameSource.set_preset`); it now rewrites
  the buffer in place. Every bulb switch recompiled the compute pipeline; compiled shaders are
  now shared per path for the life of the process and a switch swaps the genome into the
  existing source. Every measurement, density and bake readback was a synchronous
  `buffer_get_data`, a full GPU drain each time; all three are `buffer_get_data_async` now.
  The wrist menu and controls card SubViewports rendered every frame whether shown or not;
  they sleep when hidden. A frozen cloud no longer dispatches an empty compute pass, and a
  converged framing no longer re-sends its uniforms every frame.
- **The fps guard no longer flinches at hitches.** It cut splat size on any single frame under
  24fps, so the stalls above (all CPU-side) made it shrink the cloud for three seconds after
  every bulb switch. It now needs six slow frames in a row, cuts by the smoothed rate, and
  ignores frames over 100ms.
- **OpenXR housekeeping.** The 72Hz request is retried on `session_begun` (the rate list is
  usually empty before it); a system recenter recenters the cloud; drift, spin and the guard
  pause while the Quest dash covers the app.
- **Honest colour comment.** The shaders' "measured live" colour centring was never wired up;
  the fixed 4/3 stretch that actually shipped is now a named constant, and the dead histogram
  reader is gone. The look is unchanged.
- The bulb iterator evaluated one distance estimate per particle per frame that the first
  projection step immediately recomputed; it no longer does.
- **Bulb splats are sized by coverage.** The headset's own bake measured a mean neighbour axis of
  0.014 cloud units against a default splat sigma of 0.006: each splat was 43% of the size it
  needed to merge with its neighbours, which is why the surface read as discs whatever the
  opacity or order. In bulb mode SPLAT is now a coverage dial (0.9x of each splat's own baked
  axis by default, the WebXR builder's A_SCALE) instead of millimetres. The quad is trimmed
  from 2.83 to 2.24 sigma to pay for it in fill.
- **Bulb splats are depth-sorted.** A GPU counting sort by view depth runs every frame in
  splat mode and the vertex shader draws back-to-front through the resulting permutation.
  This was the largest remaining difference from the WebXR build's renderer, and the reason
  no opacity setting could make a bulb read as solid: "over" compositing is order-dependent.
  The self-test verifies the permutation is complete.
- **Staggered iteration now actually saves GPU time.** MOTION 1/n and the morph's 1/6 picked
  particles by `idx % n`, which leaves most of every SIMD wave idle while the rest run the full
  loop: the headset measured 1/6 of the cloud at 3ms against 4.4ms for all of it. Particles are
  now iterated in contiguous slabs and only a slab's worth of workgroups is dispatched.
- **Palette lookup is branchless** in both point shaders (a mix chain instead of a dynamically
  indexed local array, which Adreno spills to scratch).
- **Bulb switches morph.** A new bulb now starts from the old bulb's particles instead of a fresh
  ball of seeds, so the shell projects onto the new surface over the settle: a real shape-to-shape
  transition, and the previous bake's splat sizes stay live until the new bake lands. The old
  seed-ball collapse was also the most expensive thing the renderer drew (30fps for a second).
- **The wrist menu shows only the current mode's controls.** Every tile is tagged flame, cloud
  (flame and bulb), bulb, ground or all, and a section whose tiles are all hidden drops out with
  its header. Thirty-five tiles across three modes had become a wall.
- **GLOW toggle in LOOK**, so the cost of the post chain can be measured on the wrist menu
  instead of guessed at. The menu panel is taller to make room for it and EXIT.
- **Switching bulbs keeps your grab.** Every bulb switch reset the cloud's scale (and with it
  where it sat), throwing away however you had placed it. Only entering bulb mode now sets the
  inside-the-surface scale.

### Added
- **EXIT in the wrist menu** (its own section at the bottom). Two presses within four seconds:
  the first arms it and the tile says so, because the menu is a ray and a trigger and one
  stray pull should not end the session.
- **The Quest build is ready to be a real app.** Package `uk.fractalxr.app`, label FractalXR,
  Quest 3/3S only, `INTERNET` permission dropped, and launcher icons baked from a real engine
  render instead of the placeholder circle. `godot/tools/build.sh release` produces a
  release-signed APK from a keystore made by `godot/tools/keystore.sh`; the build prints the
  signing certificate afterwards, because a debug-signed APK on a store listing is a bug and
  not a detail. The whole path is written down in `SIDEQUEST.md`.
- **A first-launch controls card in the native build.** A drawn schematic of both controllers
  with what each button does, floating where you are looking, dismissed by either trigger and
  shown once ever (`user://state.cfg`). `HELP` in the wrist menu brings it back. Nobody was
  going to discover the wrist-turn gesture on their own.
- **An icon and store-art pipeline from the real engine.** `npm run art` renders any preset at
  1024px with the glow's own alpha (`/icon.html?names=…`); `godot/tools/make_icons.py` frames it
  on the bright core and writes every Android icon size, and `make_store_art.py` composes the
  SideQuest listing card and background. Screenshots and the trailer stay a headset job.
- **The three modes are now one site with mode switching.** The landing page explains what
  FractalXR is and links all three modes (flames / relief zoom / splat); the zoom and splat
  pages carry a corner nav back to the others. In-headset, the zoomer and splat viewer get a
  MODE ▸ HUD button *and* thumbstick-click to cycle flames → zoom → splat (leaving the page,
  session ends and the next mode opens flat), and the main app's wrist menu gains a VISIT
  section (ZOOM / SPLAT) since every face button there is already spoken for.

### Fixed
- **Splat viewer: two-grip grab now grows the sculpture toward you** instead of swinging it
  around a ~2m lever arm (the splat was double-placed, once inside its rig and once by the
  rig itself). Grabs are also one frame of controller lag tighter.
- **Splat viewer: stick Y resizes about the sculpture's centre**, and a new INSIDE button
  centres it on your head at 5× so you can jump straight in.
- **Splat viewer: the HUD no longer reads as flipped** when you zoom in past its plane — it
  yaws to track your head instead of showing its mirrored back.

## [0.8.1] - 2026-06-21

### Changed
- **Dome thumbnails are now transparent-backed and larger.** They were opaque black squares that
  read as floating cards; now each thumbnail carries an alpha channel derived from the fractal's own
  glow (plus a soft border vignette so even edge-filling forms like the Mandelboxes don't clip to a
  square), so the fractals dissolve into the void — and into your real room in passthrough. Tiles are
  also much bigger and on a slightly wider dome. (Re-bake with `npm run bake` after preset changes.)

### Added
- **Dome gallery — a planetarium of variation stills.** Open it from the wrist menu (EXPLORE →
  DOME) and all 34 built-in variations (13 flames + 21 bulbs) ring you on a 360° dome as still
  thumbnails. Point the laser at one and pull the trigger: it blooms into the live animated fractal,
  zooms toward you, and the rest fade away. Reuses the existing morph paths, so activating a tile is
  the same smooth melt as the preset chips — picking a bulb tile from flame mode switches engines
  automatically. Each tile billboards to face you; the dome and the wrist menu are mutually exclusive.
- **Offline thumbnail baker** (`npm run bake`, dev-only). Renders every preset to a still through the
  real engine and composes a single atlas (`public/thumbs.png`) the dome loads as one texture — so the
  gallery costs nothing to show in-headset. Re-run it whenever the presets change.

## [0.7.0] - 2026-06-19

### Added
- **Sierpinski tetrahedron (Pyramid)** — a fifth bulb formula: the classic 3D Sierpinski gasket
  pyramid with its recursive triangular holes. It's the KIFS machinery with a *tetrahedral* fold
  (where the existing Lattice uses a cubic one), so it reuses all the same params (no new uniforms)
  and the two rotation angles bend it into organic tetra forms. Three presets — **Pyramid** (the
  pure tetrahedron), **Tetra**, **Stellated** — plus random/morph support.

## [0.6.4] - 2026-06-19

### Changed
- **Bulbs now show much more of the colour palette.** The orbit-trap colour coordinate concentrated
  ~50% of particles in the mid-palette (green/yellow), starving the violet and red ends — so any
  palette looked low-variety on a bulb. Measured the distribution across Mandelbulb/KIFS/Quaternion
  and added a histogram-equalising `smoothstep` remap that spreads the dense middle across the whole
  palette, so a Rainbow bulb actually reads as a rainbow. (Flames were already full-range; unchanged.)

## [0.6.3] - 2026-06-17

### Added
- **5 wild full-spectrum colour themes** — **Rainbow** (violet→blue→green→yellow→red), **Prism**
  (bright pastel spectrum), **Vaporwave** (indigo/hot-pink/cyan), **Acid** (clashing neon), and
  **Iridescent** (oil-slick sheen). Bigger hue travel than the existing mostly-tonal themes; reach
  them via Recolor (or the right-stick palette step) and they turn up on random flames/bulbs. They
  show fullest on flames (whose colour coordinate spans the whole palette).

## [0.6.2] - 2026-06-17

### Fixed
- **Resizing a bulb then mutating/randomising no longer snaps it back to a huge default size.**
  The per-bulb framing (apparent size) is now applied as a *ratio* on top of your grab-scale rather
  than overwriting it — so mutate keeps your size exactly, and a formula/size change eases smoothly
  to the new size instead of jumping.

### Changed
- **Bulbs jump between formula types far less.** Auto-cycle and the randomise button now usually stay
  in the current family (Mandelbulb/Mandelbox/KIFS/Quaternion), which melts smoothly, instead of
  constantly reseed-jumping to a different formula. Mutate already stays in-family; cross-formula
  changes still happen, just occasionally rather than every other pick.

## [0.6.1] - 2026-06-17

### Changed
- **"Enter MR" now goes straight to mixed reality** — an immersive-ar session opens with
  passthrough already on (the room visible), instead of starting in the black void and waiting
  for a manual PASSTHRU toggle. VR is unchanged (still opens in the void); the PASSTHRU cell still
  flips room/void mid-session.

## [0.6.0] - 2026-06-16

Faster preset browsing.

### Changed
- **Presets are now a floating side panel** to the right of the menu instead of a full-panel
  takeover, and it **stays open when you pick a variant** — so you can audition several in a row
  without reopening it. Ray-point + trigger to pick; ✕ Close (or reopening PRESETS) dismisses it.

### Added
- **Left-thumbstick shortcut with the menu closed**: left/right cycles through the active gallery's
  presets, up = flame / down = bulb mode. Quick browsing without opening the menu at all.



### Fixed
- **Wrist menu glitching on flame↔bulb switch** — the previous (ghosted) menu showed through and
  taps landed on the wrong buttons. The new sectioned menu has different heights per mode, so the
  panel canvas now resizes on a mode switch — but resizing a canvas doesn't reliably reallocate its
  GPU `CanvasTexture`, leaving a stale/misscaled panel whose drawn buttons no longer matched their
  (correctly-resized) hit-targets. The texture is now recreated whenever the panel height changes.



A fourth bulb family — smooth where the others are spiky.

### Added
- **Quaternion Julia** — a fourth DE formula (`z → z² + c`, sliced to 3D at w=0) alongside
  Mandelbulb / Mandelbox / KIFS. Smooth, organic, swirling forms — soft and shell-like where the
  Mandelbulb is spiky and the KIFS is faceted. Analytic Green's-function distance estimate, no new
  uniforms (the constant `c` reuses the Julia-C slot; it rides the existing bulb projection path).
  Four presets (**Quaternion, Mercury, Cobalt, Halcyon**) + full random / mutate / morph; the
  living breath orbits `c`, and ~20% of randomly generated bulbs are now quaternion Julias.



Wrist-menu clarity pass.

### Changed
- **Wrist menu regrouped into labelled sections** — `CREATE` (randomize / mutate / cross-breed /
  auto), `EXPLORE` (presets / mode / recolor), `TUNE` (the value cyclers), and `KEEP` (favourites),
  instead of one dense grab-bag. **Exit VR** moved to its own system row so it's no longer a
  stray-tap neighbour of the cyclers, and the cells got more room.
- **Variant chips moved into a `PRESETS ▸` popup** — picking the EXPLORE → Presets cell opens a
  grid of every flame/bulb variant (+ Back); choosing one applies it and returns. Reclaims the two
  rows the chips used to occupy.
- **PASSTHRU now only appears in an MR (immersive-ar) session**, on the system row — it's
  meaningless in VR/desktop, so it no longer takes a permanent slot (which also widens the rows).

### Added
- **`SPLAT` cycler in the TUNE row** (Full / ¾ / ½) — the v0.3.1 splat-resolution overdraw lever is
  now adjustable in-headset with the controller, no console needed.
- **Thumbstick controls in the help card** — `LEFT STICK` (move the menu cursor · click to open)
  and `RIGHT STICK` (step colour · morph speed), which were previously undocumented.



A splat-overdraw lever for on-device tuning.

### Added
- **Sub-resolution splat target** (`window.fractal.setSplatScale(s)`, default 1 = unchanged).
  The additive point cloud can render into a fraction-res HDR target (¼ the fill/bandwidth at
  0.5 — and the additive glow is the real overdraw cost on the mobile tiler) that the tone-map
  upscales through a Linear filter. The glow is low-frequency so it softens rather than aliases.
  Set it in the browser console *before* Enter VR (in-session console isn't reachable), like
  `setScale`. Desktop-verified on the canvas path; the per-eye XR viewport scaling is the bit to
  A/B on-device. The HDR target's filter is now Linear (identical at 1:1).



Seven new flame variations — the create-space just got a lot bigger.

### Added
- **7 new flame variations** (`horseshoe`, `handkerchief`, `disc`, `spiral`, `hyperbolic`,
  `cylinder`, `eyefish`) joining the original five. Each is a classic flam3 form adapted to
  3D; `eyefish` scales the full vector so it counts as a z-injector. They multiply
  combinatorially through the existing randomize / mutate / cross-breed / morph pipeline —
  no new UI, just dramatically more variety in **Create**. The variation set went from 5 to 12.

### Fixed
- **Older saved favourites survive a growing variation set.** Loading a favourite saved before
  a variation existed now backfills the missing weights to 0 (and the encoder defaults absent
  keys), instead of feeding `NaN` into the GPU and corrupting the flame.



A third fractal family joins the bulb engine.

### Added
- **Kaleidoscopic IFS (KIFS)** — a new distance-estimated formula alongside Mandelbulb and
  Mandelbox: conditional tetrahedral plane folds wrapped in two rotations, then a scale toward
  an offset. The two fold-angles + offset + scale span a huge space of cathedral / tree /
  lattice / snowflake forms. Four curated presets (**Lattice, Cathedral, Snowflake, Thornwood**),
  plus full random / mutate / morph support — ~30% of randomly generated bulbs are now KIFS.
- **Living kaleidoscope** — the two fold-angles breathe in quadrature on settled KIFS, so the
  whole structure slowly turns. KIFS angles also lerp within the family, so morphing between two
  KIFS genomes melts the kaleidoscope continuously (cross-formula morphs reseed onto the new
  surface as before).



A performance pass — measure first, then optimise.

### Changed
- **Bulb mode is smoother**: the Mandelbulb/Mandelbox iterator was computing a distance-estimator
  gradient twice near the end of each particle's update; it now reuses the projection gradient for
  the tangent shimmer, cutting ~20% of the bulb DE cost with an identical look. (Flames untouched.)
- The simulation pass restores the renderer's scissor-test state instead of forcing it off every
  frame.

### Added
- Developer GPU-timing instrumentation (`EXT_disjoint_timer_query`) surfacing per-pass cost
  (sim / splat / tone) in the menu HUD and `window.fractal.gpu()`, plus live tuning levers
  (`setScale` / `setFoveation` / `setProjSteps` / `setIterations`). Desktop-only — Quest WebXR
  blocks timer queries — but it redirected this pass from the wrong bottleneck to the right one.

## [0.1.1] - 2026-06-15

Quick-win pass from the first codebase audit — bug fixes, the desktop/landing experience, and a CI gate.

### Fixed
- **Open wrist menu no longer re-uploads its full canvas to the GPU every frame.** The live fps readout was baked into the menu's redraw dirty-check, so an open menu repainted ~3.7 MB/frame and could itself trip particle-shedding. The perf line now refreshes on a throttle, out of the structural check.
- **Corrupted/old-schema saved favourites no longer crash the session.** `loadFavorites` now validates each entry's shape and drops malformed ones instead of detonating in the morph pipeline on the next "Faves" press.
- **Deleting a favourite after saving now targets the right one** (the save no longer leaves a stale "current favourite" index).

### Added
- **WebGL2 fallback message** — visitors on browsers/devices without WebGL2 get a readable explanation instead of a silent black screen.
- **`prefers-reduced-motion` support** — ambient auto-rotation is off by default for users who request reduced motion (re-enableable from the menu).
- **Open Graph / Twitter-card meta + a branded preview image** so shared links unfurl with a title, description and image. Added a favicon and a `_headers` file (nosniff / referrer-policy / frame-ancestors).
- **CI build workflow** (`.github/workflows/build.yml`) running `tsc --noEmit && vite build` on every push/PR, plus a `typecheck` script and a Node `engines` field.

### Changed
- Dropped `maximum-scale=1, user-scalable=no` from the viewport so the landing page allows pinch-zoom.

## [0.1.0] - 2026-06-14

### Added
- **Bulb mode** — a second attractor family alongside the flames: Mandelbulb and
  Mandelbox point clouds, reachable via the wrist-menu **MODE** toggle (or `m` on desktop),
  with a 10-bulb gallery and the breeding controls repurposed (randomize / mutate / flip-kind).
- **Bulb-to-bulb morphing** — the parametric analog of the flame melt. Same-formula
  transitions interpolate the distance-estimator parameters so the cloud chases a continuously
  deforming isosurface; cross-formula (bulb↔box) transitions reform with an eased size and
  palette crossfade. Auto-cycle melts through the gallery.
- **Mode-aware wrist menu** — in bulb mode the preset chips become the bulb gallery, the
  flame-only favourites (Save / Faves / Delete) are hidden, and Cross-breed relabels to Flip.
- **Pointer-hand thumbstick controls** — flick left/right to step the palette, up/down to
  change morph speed, without opening the menu.

### Fixed
- **Particle count decaying to the floor** — the adaptive-quality guard's recovery threshold
  was unreachable under vsync, so any transient frame hitch shed particles permanently and
  ratcheted the count down to the 20% minimum over a session. It now recovers while holding
  refresh, and the session runs at 72 Hz for the largest frame budget (fullest cloud).
- Recoloring mid-morph now heads toward the morph destination instead of freezing at the
  half-morphed midpoint.
- Menu cursor navigation follows the menu hand regardless of controller enumeration order.

### Changed
- The XR session now targets 72 Hz (favouring particle density) instead of the maximum
  supported refresh rate.
