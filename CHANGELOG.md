# Changelog

All notable changes to FractalXR are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/); this project follows semantic versioning.

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
