# FractalXR visual improvement plan

2026-09-15 · Planning only · Native Quest first, web differences noted

## Status, 2026-09-15 (implementation pass)

Verified against the working tree before implementing: 258 factual claims across the six
packets, 67 flagged, 2 confirmed wrong after an adversarial pass. The plan is accurate
about the code. Three corrections that changed what got built:

- **S2's premise is backwards and S2 is not needed.** The packet says bulb and ground
  carry more controls than flame. Measured through the real scene: flame 29 tiles across
  six sections, ground 27 across four, bulb 26, tree 22. Flame is the tallest layout by a
  wide margin. All four modes fit the 760x980 panel with room to spare, so no progressive
  disclosure was added. (A related claim, that flame already overflowed before any change,
  was wrong: the first real capture passed the geometry check. It overflowed only after
  the S1 type increase, and that was paid for out of row gaps.)
- **S3.2's bulb copy described behaviour that did not exist.** Both triggers fell through
  to the flame morph in bulb mode. The handler was fixed to step the bulb gallery, then
  the copy was written against it. See the Fixed entry in `CHANGELOG.md`.
- **F1 and G1 are measurement tasks, not implementation tasks.** Both ask for a default to
  be chosen from a headset comparison. Neither was promoted. They stay open.

Landed: S0, S1, S3, B1, T1, T2, T3, and the bulb trigger fix.
Not landed: S2 (unnecessary, see above), F1, F2, B2, B3, G1, G2, G3, W1-W4.

Every desktop capture and the leaf-gain measurement are in
`godot/.spike-out/visual-2026-09-15/` with a manifest. Stereo, wrist-distance legibility,
grab feel, MR and thermals are unmeasured and remain headset acceptance items.

## Direction

An immersive fractal gallery: luminous flames, sculptural bulbs, readable terrain, and living trees. Keep the black void, expressive palettes, Space Grotesk, wrist reveal, controller gestures, and toy-scale bulb entry. Give the controls less visual weight and give each mode a distinct material character.

The strongest opportunities are **tree foliage/materials, wrist-menu hierarchy, and bulb surface shading**. Ground needs calmer distance detail and better separation of the set from the horizon. Flames need measured tuning of core brightness versus fine filaments, with fresh captures before choosing defaults.

This is an evolution of the current app. No new renderer, framework, dependency, mode, environment scene, or asset pipeline is needed for the first pass.

## Implementation packets

Pass the common contract below plus **one task ID from one packet** to a smaller model. Each task is one reviewable change. Complete local verification before taking another task; obtain the headset verdict before promoting experimental settings to defaults.

| Order | Packet | Result | Risk |
|---|---|---|---|
| 0 | [Shared UI and evidence](00-shared.md), S0 | Captures represent actual modes and render paths | Low |
| 1 | [Tree / Forest](04-tree.md), T1 | Coloured foliage with less bloom; coherent branch colour | Low–medium |
| 2 | [Shared UI](00-shared.md), S1–S3 | Quieter, readable wrist panel and accurate help | Low–medium |
| 3 | [Bulbs](02-bulbs.md), B1 | Shape reads through restrained normal-based lighting | Medium |
| 4 | [Ground](03-ground.md), G1–G2 | Legible foreground, calmer horizon, correct MR interior | Medium |
| 5 | [Flames](01-flames.md), F1–F2 | Better colour and filament balance across presets | Medium |
| 6 | [Tree / Forest](04-tree.md), T2–T3 | More organic branches and clear planting feedback | Medium |
| 7 | [Bulbs](02-bulbs.md), B2–B3 | Surface-state clarity, then bounded marcher experiment | High for B3 |
| Later | [Web differences](05-web.md) | Transfer successful visual decisions to web surfaces | Separate pass |

## Common handoff contract

```text
Implement task <ID> from docs/visual-plan/<PACKET>.md.
Read docs/visual-plan/README.md and the packet before editing.
Read the current implementation around the named symbols; this plan is based on
2026-09-15 working tree, not a promise that line numbers or defaults remain fixed.
Implement only this task. Reuse existing Godot nodes, shaders and control plumbing.
Keep unrelated working-tree edits. Do not reset files or commit another person's changes.
Keep the native Mobile renderer, stereo transforms, premultiplied-alpha paths,
performance guards, controller mappings and existing menu mode names.
No new packages, broad main.gd refactor, renderer migration, build deployment or
Git push as part of this task. Save before/after images at identical settings.
Run the packet's applicable checks. Separate verified desktop results from pending
Quest results. If the bounded experiment fails, restore only your own changes and
record why; do not expand into a renderer rewrite.
Return: changed files, visual result, checks with outcomes, image paths, measured
performance if available, and remaining headset acceptance items.
```

This plan authorizes no automatic task creation. It is ready to hand off when implementation is requested.

## Shared acceptance contract

- Save baseline before editing: mode, preset/species, seed if available, palette, pose, scale, count, eye scale, render path, glow, foveation, motion, viewport and build revision. Freeze animation for comparisons; separately capture a short moving sequence for temporal defects.
- Desktop captures establish appearance and integration only. Verify both eyes, head movement, wrist reading, grab/scale and VR → MR → VR on Quest before calling a visual change accepted.
- Proposed performance gate: at unchanged settings, median app GPU time must not rise by more than 0.5 ms and p95 by more than 1 ms, with no new stale-frame pattern. Also remain within the **actual active refresh budget** (13.89 ms at 72 Hz, 11.11 ms at 90 Hz). These are acceptance targets, not current measurements. If baseline already misses budget, do not describe it as smooth or conceal the miss by reducing resolution.
- Compare matched 60-second runs after warm-up. For a default-changing renderer/material change, follow with a 15-minute on-device run. Use the same timing source throughout; record QGO profile and refresh rate. Historical figures from different settings are not interchangeable.
- UI text must remain readable over a bright room and dense bright fractals. Aim for at least 4.5:1 text contrast in the composited panel, plus visible non-colour selection cues. Texture pixels alone do not establish angular legibility.
- Keep MR backgrounds transparent where intended. No new full-screen fog, sky, vignette or ground plane across all modes.
- Run `git diff --check`. Run native parser/spatial-shader checks for native changes; `npm run build` only for web changes. Existing shader check is not proof that runtime compute shaders work.

Commands below are run from repository root. Tool scripts source `godot/tools/env.sh`; use installed `GODOT` override if required. Keep `--xr-mode off` for desktop captures. Inspect helper scripts before running them: their watchdogs can terminate another Godot run, so run captures serially. Never treat an output PNG or the word PASS alone as proof of correct rendered state.

## Evidence and limits

Inspected source at HEAD `7f19901` plus existing uncommitted changes in `main.gd`, help, ground and march shaders, menu capture, and forest capture tools. Those edits belong to ongoing work and must be preserved.

| Evidence inspected | Date / limitation | Finding |
|---|---|---|
| `godot/.spike-out/menu_flame.png` | Sep 14; synthetic fixture | Saturated panel and tile borders compete with values; fixture has only three modes and a tree-only CLEAR tile in flame layout |
| `godot/.spike-out/help_card.png` | Sep 14; flame card | Clear controller diagram, different font/theme from wrist panel; source lacks a bulb-specific text branch |
| `godot/.spike-out/forest.png` | Sep 14; real main scene | Bright foliage merges into white clusters; lower trunk very dark; abrupt level-based branch hues |
| `godot/.spike-out/tree.png` | Sep 12; close crop | Faceted branches and dark trunk; crop is not proof that headset entry framing is wrong |
| `godot/.spike-out/ground.png` | Sep 12; older than MR changes | Bright distant band, busy fine boundary, black interior merging with void |
| `godot/.spike-out/splat_after1.png` | Sep 12; single warm palette | Soft, uniformly bright bulb with weak large-scale relief |
| `godot/.spike-out/shots/bulb_latest.jpg` | Historical headset capture; settings unverified | Different palette reveals more structure; reinforces need for matched palette comparisons |
| `godot/.spike-out/march.png` | Sep 14; path unverified | Speckled silhouette; harness only gates file save, not active marcher/hit coverage |
| `godot/.spike-out/shots/uk.fractalxr.app-20260901-205129.jpg` | Sep 1; historical high-brightness settings | White flame core and visible points; not evidence of current default quality |

These files are local ignored artifacts, not portable plan assets. S0 regenerates evidence into a dated local directory. No new headset test or app build was performed for this planning task. README and architecture documentation contain obsolete descriptions; the current source takes precedence.

## Reference basis

Keep the existing composition-layer UI: Godot describes why a compositor layer avoids the extra resampling that can blur scene-rendered text, and documents the runtime fallback. [Godot composition layers](https://docs.godotengine.org/en/stable/tutorials/xr/openxr_composition_layers.html).

Use a consistent, legible type hierarchy, then verify at the actual wrist distance. [Meta typography guidance](https://developers.meta.com/horizon/design/styles_typography/). This plan's precise colours, sizes and performance gates are project proposals, not claimed platform requirements.
