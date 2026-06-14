# Changelog

All notable changes to FractalXR are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/); this project follows semantic versioning.

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
