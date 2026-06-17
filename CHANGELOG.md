# Changelog

All notable changes to FractalXR are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/); this project follows semantic versioning.

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
