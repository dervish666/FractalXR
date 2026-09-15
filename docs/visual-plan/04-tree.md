# TREE / Forest · Living branching forms

Read [common contract](README.md). Target: readable branches, coloured canopies, believable growth and clear placement. Keep the fantastical palette. Realistic bark textures are unnecessary.

## T1 · Separate branch and leaf brightness

**Dependency:** S0 baseline capture. **Files:** `godot/shaders/tree.gdshader`, `tree_leaf.gdshader`, `godot/scripts/tree/fractal_tree.gd::set_palette()` if needed; tree/forest capture helpers.

**Evidence:** saved forest has nearly black lower trunks, abrupt purple branch bands and clusters of white leaves. Branches use palette position based on recursion level; leaves use additive soft discs from the two brightest palette stops.

1. Keep geometry, growth and synchronized sway unchanged. First isolate foliage: compare leaf gain 0.6 with 0.25 and 0.4 in the existing fragment expression. Preserve alpha/edge falloff in this pass; do not accidentally multiply opacity twice or change blending without evidence.
2. Map leaf colour across middle-to-bright stops rather than only `pal3`/`pal4`. Use the existing per-leaf hue (`COLOR.r`) for stable variation; no time-based noise. Warm and cool themes must retain their character.
3. Lift the trunk's effective palette floor modestly so it remains visible against black, while keeping the canopy brighter. Blend the darkest stop toward the next stop by about 0.2 as an initial candidate; avoid global exposure changes.
4. Compare branch-only, leaves-only and combined captures for oak, pine, willow and coral. Include a mixed three-tree forest and the maximum allowed planted count. Keep caps (`FOREST_EXTRA_MAX = 12`, secondary depth ≤6, branch cap 80,000 per tree) unchanged.

**Done:** individual leaf clusters retain colour, lower trunks are visible, white bloom does not merge whole canopy regions; branch/leaf counts and draw topology unchanged. No fireflies, falling particles, transparency stacks or extra lights.

**Checks:** spatial shaders, parser if host touched, `tree_check.sh`, `tree_shot.sh`, `forest_shot.sh`; Quest wind on/off, growth, mixed forest VR/MR; common performance gate.

## T2 · Soften branch colour transitions

**Dependency:** T1. **Files:** `tree.gdshader`; `fractal_tree.gd` only if stable per-instance data is genuinely missing.

1. Replace abrupt recursion-level colour boundaries with a continuous colour coordinate. Start with normalized height relative to `tree_origin` / `tree_up` / `tree_height * tree_scale`, already supplied for sway, blended with level (initial 70% height, 30% level).
2. Compute from undeformed position so colour does not slide when wind bends the tree. Preserve stable colouring during regrowth and grab/scale. Reuse existing phase only for small static variation if needed.
3. Keep six-sided cylinders initially. Correct material/readability first; increasing radial segments across tens of thousands of branches is not an inexpensive cosmetic change.
4. Check joints in close-up. If disconnected-looking geometry remains, record it for a separate junction task. Do not hide joins with emissive spheres or rewrite the generator.

**Done:** trunk-to-tip colour progresses smoothly, species silhouettes remain distinct, wind doesn't move colour bands, no extra instances or mesh rebuilds per frame.

**Checks:** tree shader compile; tree/forest captures at fixed species/seed; grow/grab/scale sequence; tree structural check if generator data changed.

## T3 · Preview planting and give bases a visual anchor

**Dependency:** T1, S1. **Files:** `main.gd::_plant_tree_from_hand()`, `_plant_tree_at()`, existing floor-ray intersection code; small Node3D/mesh helper only if required.

1. Reuse exactly the floor hit and validity rules used by planting for a small ground-aligned outline at the prospective root. A simple ring mesh is sufficient. Show only in Tree mode while aiming at a valid floor point and not interacting with menu/help.
2. Size in world metres (start at radius 0.12 m), offset slightly to avoid z-fighting. Hide when tracking is lost, ray misses, forest cap is reached or mode changes. Do not render a second full tree as a ghost preview.
3. At capacity, show a concise status explaining that CLEAR removes planted trees. Keep hero tree semantics and existing CLEAR action unchanged.
4. Only if VR roots still look detached after material changes, evaluate one small palette-dark root disc per tree on the virtual floor. Default off in MR; it must not cover the physical room. Reject if it reads as a floating pedestal or adds noticeable overdraw.

**Done:** preview root matches planted root, no planting while menu/help consumes trigger, no lingering marker across mode switches, max count unchanged, MR floor stays visible. World y=0 remains the current reference; this task adds no room-mesh anchoring.

**Checks:** parser, forest integration capture including marker hit/miss, Quest planting and controller tracking loss, VR/MR mode cycle. Headset placement acceptance is required; a desktop screenshot cannot prove it.

**Web difference:** no equivalent Tree/Forest mode exists in `src/modes.ts`. Do not introduce one as part of visual parity.
