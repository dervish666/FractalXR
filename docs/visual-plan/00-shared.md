# Shared UI and visual evidence

Read [common contract](README.md). Target: a dark instrument panel whose active control is obvious at a glance. Keep the palette ribbon and selected-mode tint; quiet the rest.

## S0 · Make captures trustworthy

**Files:** `godot/tools/menu_shot.gd`, `card_shot.gd`, `splat_shot.gd`, `march_shot.gd`; new small flame capture helper if needed. Runtime edits only if a minimal debug hook is unavoidable.

1. Replace menu `_spec()` mock with the real `main.tscn` and `main.menu` after setup. Switch through `_set_mode("flame"|"bulb"|"ground"|"tree")`, refresh visibility, then capture the menu viewport with one visible tile hovered. Do not recreate the control list in a test fixture.
2. Capture each mode with three existing palettes, long title/value examples and EXIT armed. Ensure all four mode segments and APP controls lie within the 760×980 viewport. Report geometry outside the viewport as failure, even if save succeeded.
3. Capture help in all four modes. Add a baseline flame shot using fixed preset, settled state, stopped drift/spin, standing camera and whole-object framing.
4. Strengthen splat/march checks: require the intended mode/path, settled/baked state when relevant, non-empty rendered object, successful save, and absence of script/shader errors. March fallback must fail the march capture. Capture the exterior separately from the shelved interior experiment.
5. Keep existing output filenames for existing consumers; copy accepted captures plus a settings manifest into `godot/.spike-out/visual-2026-09-15/` (use actual implementation date).

**Done:** real four-mode menus captured; wrong-path negative control fails; no synthetic flame CLEAR tile; captured state and build/settings recorded. Do not claim pixel-perfect determinism for unseeded particle generation.

**Checks:** parser; changed capture helpers, serially; manually open images. Capture tools should exit nonzero on unmet state, not merely print a warning.

## S1 · Quiet the theme; preserve interaction

**Files/symbols:** `godot/scripts/xr/wrist_menu.gd`: `_derive_theme`, `_tile`, `_style_tile`, `_build_viewport`, `_section_head`.

1. Retain Space Grotesk and existing 26 px panel / 14 px tile radii. Use near-neutral panel `#10151F` and tile `#1B2330` as initial targets, with only 5–10% palette tint. Keep a solid-enough panel (start at alpha 0.97).
2. Use `#EDF1F8` primary labels and `#B8C3D4` inactive values. Palette accent belongs to selected mode, current hover and meaningful active state. Keep the 3 px palette ribbon. Replace strong coloured resting borders with subdued neutral borders.
3. Selected mode: tinted fill plus persistent stronger border. Hover: accent outline plus small fill change; remove broad luminous halo. Press: existing short pulse/haptic. Selection must stay visible when another tile is hovered.
4. Make section labels quieter through layout, not tiny low-contrast text. Start with title 32/weight 500, section 14/600, tile label 19/500, value 18/400, footer 15/400. Treat these as capture candidates; do not force them if they clip.
5. Keep 760×980 texture, physical size, hit rectangles, wrist thresholds, stick scrub, composition layer and mesh fallback unchanged in this task. Check all actual mode layouts before accepting larger type.

**Done:** only active states carry strong accents; every label/value fits; no loss of hover/press/armed state; readable in monochrome, bright palette and room-backed captures. Actual wrist-distance Quest reading remains a separate acceptance item.

**Checks:** parser; S0 menus in all modes/palettes; open/close, hover and stick scrub in headset; fallback desktop quad.

## S2 · Fit dense controls without shrinking text

**Dependency:** S0 geometry measurements, S1. **Files:** wrist menu and `_build_menu()` in `main.gd`.

Bulb and Ground can contain more controls than the flame fixture. Add progressive disclosure only if real layouts overflow or remain too dense to read.

1. Keep title, all four mode buttons and APP actions fixed. Keep the existing section order.
2. Collapse only the technical tuning group behind one labelled `MORE` toggle, retaining its state during a mode's session. Common creative actions stay visible. Flame: preserve preset, random/mutate/breed, drift/spin, theme. Bulb: preserve preset, SURFACE, coverage, theme. Ground: preserve set, height, relief, theme, INSIDE. Tree: preserve species, seed/regrow/clear, wind, leaves, theme.
3. Move count, foveation, rendering detail, bake diagnostics and numerical exposure controls into expanded tuning as needed. Keep their callbacks/settings unchanged. Do not duplicate controls or move them into a separate modal.
4. Expansion must fit. If it cannot, use two explicitly labelled tuning pages with fixed Previous/Next controls; no ray-operated free scrolling. Visible layout rectangles must remain the source of hit testing, and collapsed items cannot receive focus.

**Done:** all modes fit, APP is always reachable, opening tuning preserves values and focus never lands on hidden controls. Skip this task if S1 already fits comfortably; avoid adding navigation for its own sake.

## S3 · Make help visually and semantically consistent

**Files:** `godot/scripts/xr/help_card.gd`, `godot/tools/card_shot.gd`; reuse existing font asset.

1. Match wrist neutral background, text and accent roles; use Space Grotesk. Keep the controller diagram and existing dismissal/first-launch logic.
2. Add explicit bulb copy: previous/next bulb, grab/scale; remove the misleading flame-only mode note. Confirm actual input handlers before writing text.
3. Ground grip copy must describe moving/scaling the field rather than flying through an object. Tree copy must distinguish manipulating the hero from planting additional trees. Keep instructions short enough for existing callouts.
4. Put wrist-menu discovery and trigger-to-dismiss instructions above secondary explanation in visual emphasis. Do not add a tutorial flow.

**Done:** each mode's diagram agrees with handlers; no clipping at original card resolution; fonts match menu; both triggers still dismiss without activating the underlying scene.

**Checks:** parser, four card captures, Quest help open/dismiss in each mode.

## Intended hierarchy

```text
Current specimen / location                    State
━━━━━━━━━━━━━━━━ current palette ━━━━━━━━━━━━━━━━━━━
 FLAME       BULB       GROUND       TREE

 Make / Scene        main creative actions
 Look / Colour       mode-specific visual controls
 More                technical controls, if needed

 PASSTHRU            HELP                 EXIT
                                      compact timing
```

No persistent head-locked dashboard: `hud.visible = false` already retires it to the wrist. Preserve that decision.
