# Web differences and later transfer

Native Quest is primary. These are bounded follow-up packets, not part of the initial native implementation queue. Inspect live/local web appearance before choosing CSS or renderer values: this planning pass reviewed web source structure, not fresh browser captures.

| Web surface | Native relationship | Transfer |
|---|---|---|
| `/`, Flames | Native FLAME | Visual hierarchy, specimen framing, palette comparisons; tune HDR independently |
| `/`, Bulbs | Native BULB | Specimen presentation; preserve web DE/point engine |
| `/`, Dome Gallery | Web-only presentation state | Less chrome, readable selection; keep curved gallery layout |
| `/zoom` | Related to GROUND, but a relief panel | Calmer textures, clearer rendering progress; preserve panel depth pipeline |
| `/splat` | Separate Spark viewer | Shared entry/control appearance and truthful generation state |
| VR/MR | Cross-cutting presentation | Contrast and correct transparency, tested per renderer |

## W1 · Shared entry and controls

**Files:** `index.html`, `zoom.html`, `splat.html`, `src/style.css`, `src/main.ts`, `src/ui/HudPanel.ts`, `src/xr/WristMenu.ts`, `src/xr/ControlsGuide.ts`.

Capture all three entry pages at 1440×900 and 390×844. Reuse existing CSS and control code. Give mode navigation and VR/MR entry consistent type, spacing and selected/focus states; keep fractal preview dominant. Use a neutral dark panel, restrained current accent, one control shape scale. Keep existing route names and unsupported-XR/error behaviour. Keep DOM/keyboard controls usable outside VR. Do not add React, Tailwind, a marketing hero or an icon package.

**Done:** routes load correctly, active mode obvious, keyboard focus visible, no narrow-screen overflow, VR/MR unavailable states readable. `npm run build`; browser screenshots; Quest entry/exit in each route. Web mode navigation ends its current XR session by design; do not promise seamless in-session page switching.

## W2 · Flames, bulbs and dome

**Files:** `src/main.ts`, `src/xr/DomeGallery.ts`, `src/xr/WristMenu.ts`; rendering only where a measured defect warrants it.

Carry over successful native control hierarchy. Capture flame/bulb presets before tuning; web HDR values are independent. For dome tiles, inspect selected outline/name legibility and centre framing; keep thumbnail vignette and transparent corners, avoid large coloured card backgrounds. Verify preset picking, favourites, gallery entry/exit and VR/MR against existing behaviours. Do not increase tile density or add a second carousel.

**Done:** selection readable without bright frames competing with images; no new thumbnail halos or loss of stereo depth; desktop build plus existing stereo test if compositor/eye handling changed; Quest gallery picking.

## W3 · Relief zoomer

**Files:** `src/zoom/spike.ts`, `ReliefPanel.ts`, `FieldPass.ts`, `HeightRange.ts`, `shaders.ts`, `src/ui/HudPanel.ts`, `zoom.html`.

Group existing controls into navigation, shape, appearance and quality through the existing HUD. Make settled versus updating state obvious. Keep marble/both/filaments styles; compare subpixel contrast at deep zoom before changing their defaults. Preserve percentile height normalization, last-step coverage, banded rendering and saved user quality settings. Do not “fix” blur by forcing the highest field size/iterations or by copying native ground geometry.

**Done:** same view before/after at shallow/deep zoom, depth remains readable, no holes at slab floor, controls do not disappear behind depth, style selection persists, reduced-motion behaviour retained. Build, browser capture and Quest two-eye panel resize/deep zoom.

## W4 · Splat viewer

**Files:** `src/splat/viewer.ts`, `splatXr.ts`, `splat.html`; worker/build code only for genuine status plumbing.

Apply W1 control styling. Clearly separate generating, ready and failed; retain actionable error/retry and worker cleanup. Compare existing count/scale options at fixed camera and palette. Native shader lighting is not automatically available in Spark; evaluate its existing supported material controls before adding rendering code.

**Done:** failed generation never looks like a blank successful scene, count/scale selection reflects visible cloud, VR entry remains usable, no regressions in worker termination. Build and desktop generation/failure check, then Quest stereo/MR review.
