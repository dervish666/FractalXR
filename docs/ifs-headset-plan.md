# IFS sculpting and exploration — implementation handoff

2026-09-15 · Native Godot / Quest 3 · Proposed implementation, not implemented

## Outcome

Create a tabletop fractal using two movable mirror planes and a depth handle, then
enlarge it into an architectural space. The user should understand the relationship:
**move a mirror → change the repeated structure → explore the result from inside.**

Start with one attractive open frame sculpture. Success means readable repetition,
responsive manipulation, convincing stereo depth, and a stable headset frame rate.
Feature count is secondary.

This document supplies implementation defaults. They are proposals, not claims that
the user has tested or selected these exact mappings, shapes, or limits.

## 1. Scope and decisions

### First version

- Add native **IFS** mode alongside FLAME, BULB, GROUND and TREE.
- One deterministic recursive frame preset; two editable mirror planes.
- Separate **DEPTH** (front-to-back thickness) and **DETAIL** (recursion levels).
- Two states: **Sculpt**, at tabletop size, and **Inside**, with editing frozen.
- Reuse world grab, wrist menu, help card, palette conventions and passthrough.
- Provide Reset, one-step Undo of the last completed edit, Enter and Return.
- Keep geometry finite and capped; measure editing as well as static rendering.

### Deferred

Arbitrary plane count, freehand seeds, a gallery/breeding system, persistent saved
sculptures, web parity, infinite zoom, collision locomotion, navigation meshes,
continuous flight, animated interiors, reflected scene cameras and a new renderer.
Do not implement distance-based LOD until measurements show it is needed.

“Mirror” means reflecting construction coordinates. These are editing guides,
not reflective glass surfaces. “Inside” means an open geometric sculpture around
the viewer; it does not promise a watertight building or walkable virtual floors.

## 2. Existing code and constraints

Source inspected at `a6197c2` with ongoing uncommitted ground/main/help changes.
Re-read named symbols before editing; preserve all unrelated work. Source takes
precedence over older README/architecture descriptions.

| Existing location | Reuse / integration point |
|---|---|
| `godot/scripts/tree/fractal_tree.gd` | Native procedural geometry pattern: `Node3D`, `MultiMeshInstance3D`, bounded recursion, palette, bounds. Tree is a child of `cloud`. Reuse the pattern, not tree-specific growth/wind. |
| `godot/scripts/xr/world_grab.gd` | `WorldGrab.update`, `_recapture`, `reset`: one grip moves/rotates; two grips scale. Currently polls both controllers directly and targets `cloud`. |
| `godot/scripts/main.gd` | `_ready`, `_build_menu`, `_set_mode`, `_process`, `_handle_input`, `_recenter`, `_apply_palette`, `_update_hud`, `_sync_iteration`. Main integration owner. |
| `godot/scripts/xr/wrist_menu.gd` | Existing sections/tiles, hover activation and `wants_stick()`. Mode tiles are built in `main.gd`. |
| `godot/scripts/xr/help_card.gd` | `set_mode` and mode-specific controller copy. Add accurate Sculpt/Inside help. |
| `godot/shaders/bulb.glsl`, `godot/scripts/sources/bulb_source.gd` | Existing KIFS distance estimator; reference only for this prototype. |
| `src/flame/bulbs.ts` | Lattice/Cathedral/Snowflake parameters; aesthetic reference, not a mesh recipe. |
| `godot/tools/tree_check.*`, `tree_shot.*`, `menu_shot.*` | CPU checks and real-scene capture patterns. Inspect current helpers before reuse. |

The existing KIFS folds coordinates for distance estimation. The proposed mesh
prototype instead recursively places reflected, contracted copies of a seed frame.
Both use IFS ideas, but **this is not an exact mesh conversion of Cathedral**.
Do not present it as identical or map arbitrary plane motion to unrelated KIFS knobs.

The old bulb interior path remains off limits for this task. `main.gd` records
85–103 ms GPU at 48 steps / 0.6 eye scale plus renderer/GPU failures. Its ENTER
tile was removed. New IFS Enter must not call `_enter_inside()` or revive its
raymarcher. Native tree performance is encouraging precedent, not an IFS benchmark.

## 3. Geometry: bounded, understandable IFS

### Starter construction

Use one low-poly open cube frame: twelve solid rectangular beams combined into
one reusable mesh. This gives silhouettes, real depth and a large central opening.
Use opaque faces, no dynamic shadows, restrained palette lighting. Keep the seed
and selected coarser generations visible as a structural scaffold. Document that
the result is a finite recursive assembly, not only the limiting attractor.

A concrete starting rule, in construction coordinates:

1. Seed frame occupies approximately `[-1, 1]` on each axis; beam width about 0.06.
2. Base child maps: `B±(p) = 0.35 * p + (0.6, 0.6, ±0.6)`.
3. Default planes pass through the origin, with normals along X and Y.
4. Let `R1`, `R2` reflect across those planes. Child maps are each composition of
   `{identity, R1, R2, R2 ∘ R1}` with each `B±`: eight children.
5. Recursively compose the child maps, starting from identity. The 0.35 contraction
   keeps the repeated transforms bounded; plane movement changes their offsets.
6. Render seed plus generations 1 through the selected detail level. At detail 3,
   this is `1 + 8 + 64 + 512 = 585` frame instances, roughly 84k triangles for a
   144-triangle seed. Verify actual mesh counts rather than trusting this estimate.

These values are a visual starting point. Refine offsets, beam width and default
plane angles during the geometry milestone if it resembles disconnected clutter.
Maintain real empty space and visible repetition. Do not add a general-purpose
fractal editor to solve an unattractive first preset.

### Plane and depth semantics

Represent each plane by unit normal `n` and signed offset `d`; its reflection is
`R(p) = p - 2 * (dot(n, p) - d) * n`. Reflect position and basis consistently.
Zero-length normals, non-finite values and singular transforms must be rejected.

Plane translation moves it along its normal; in-plane dragging has no geometric
effect, so do not pretend otherwise. Rotation changes the normal. Begin with
offsets limited to ±0.3 construction units and rotation limited to 30° from each
default plane. These are tunable edit bounds, not proven clearance guarantees.
Non-perpendicular planes need not yield exact global symmetry: the visible guide
means “this reflection participates in the repeated rule.”

Depth applies a final Z stretch to both generated positions and mesh bases. Start
with a positive range 0.08–2.0, default 1.0. Never use zero scale. This provides a
nearly flat relief through to a deep volume while DETAIL remains unchanged.
It stretches existing openings; it does not manufacture new topology. Store depth
separately from the uniform transform used by world grab.

Handle reflections with negative determinants correctly: verify winding, normals
and backface visibility from both sides. Prefer a baked reversed-winding seed
variant grouped by transform parity if the renderer requires it; do not solve
missing faces by making the entire scene transparent or casually doubling fill.

### Bounded generation and publication

- Detail rungs 1/2/3 initially; hard instance cap 2,048 and triangle cap 300,000.
  Count the seed and all retained generations before allocation. Stop at the last
  complete level that fits; do not produce one detailed corner and truncate others.
- Generate only when parameters change. No rebuilds for head motion, world grab,
  palette changes or an idle frame.
- While dragging, preview at detail 2 at up to 15 updates/sec. Handles track every
  frame. On release, rebuild once at the selected detail.
- Start with time-sliced generation: at most approximately 1 ms CPU work/frame,
  retaining the last completed geometry. Coalesce requests and discard stale
  generations. Publish a complete buffer and matching bounds atomically.
- Measure GPU upload cost too. If bounded main-thread publication still stalls,
  reduce the preview workload before adding a worker. Any worker must produce
  immutable numeric data; scene/resource publication stays on the main thread.
- Bounds must include beam thickness, reflections and depth. Do not auto-fit the
  object after every edit: that would counteract the user's hand motion.
- One or a few MultiMeshes initially. Individual instances are not independently
  frustum-culled; proximity and looking away must be included in Quest measurements.

## 4. Headset interaction contract

### Sculpt state

Place an approximately 0.6 m wide sculpture within reach in front of the viewer,
using tracked pose and the app's existing placement conventions. Do not require
a real table. Scale its editor handles to remain easy targets at tabletop sizes.

| Input | Result |
|---|---|
| EDIT tile | Show/hide the two outlined plane guides and front/back depth handles. |
| Trigger over a plane handle, then hold | Capture that handle; translate along its normal and rotate from the controller pose. |
| Trigger over a depth handle, then hold | Change depth along the sculpture's local Z axis; keep its centre fixed. |
| Release trigger | Commit one edit and its Undo snapshot; request full-detail geometry. |
| Grip away from an active edit | Existing one-/two-hand world manipulation. |
| DETAIL tile | Step recursion rungs; no change in overall depth or root scale. |
| UNDO / RESET | Restore last completed parameter edit / the initial shape and tabletop pose. |
| ENTER | Enter the completed current shape if it has a verified open placement. |

Use the existing controller ray convention for picking; capture the closest eligible
handle on trigger-down and retain ownership until release/cancel. Guides should have
a highlighted border, a visible grab target and a concise label. Colour alone must
not distinguish the planes. Modest haptic ticks on acquisition/limits are optional.
No reflective textures or permanent giant translucent sheets.

Only one handle edit at a time in v1. An active edit suppresses all world manipulation
from either controller. Outside an edit, grips retain their familiar meaning.
Hide guides when EDIT is off, with a brief fade after release if desired.

### Input ownership — implement before gesture polish

Resolve input once per frame in this priority: **lost focus/tracking → help card →
wrist interaction → captured edit → new handle pick → world manipulation**.
Do not let an edit trigger also step a flame/bulb preset, plant a tree or activate a
tile. Read/update button edge states even when their actions are consumed.

`WorldGrab.update()` currently runs before `_handle_input()` and polls grips itself.
Reorder the IFS interaction pass and add the smallest explicit suspend/cancel API
needed in WorldGrab. Merely skipping update leaves stale grip frames. On release,
mode change or tracking recovery require release/re-press before reacquisition;
recapture from current poses to prevent jumps. Preserve existing modes' behavior.

On tracking loss/focus loss/menu takeover, cancel the unfinished parameter edit and
restore its starting snapshot. Invalidate pending builds from that edit. On a mode
change or exit, cancel pending work and clear all input ownership.

### Inside state

Entering is a discrete transition, not automatic as a scale threshold is crossed.
Wait for current geometry publication, save the tabletop transform and parameters,
and determine a clear viewpoint. Move/scale the sculpture around the tracked user;
do not rotate the tracked head or teleport the XR origin to an unverified pose.

For the default shape, target its central opening. Compute conservative clearance
against the actual rendered beam volumes, including retained coarse generations;
an overall object bounding box is insufficient. A bounding-sphere test against
each transformed beam can conservatively reject an unsafe candidate. Use a small,
bounded candidate set near the centre if needed. No expensive general room solver.

Choose uniform scale to provide approximately 1.2 m clear radius around the viewpoint,
within a separate bounded inside-scale range. Reject entry if this cannot be verified;
show “No clear opening — adjust folds or reset.” Clearance protects the virtual
viewpoint, not the user's physical room; do not represent it as a room safety scan.

Use a short fade during the transform change. Inside:

- Freeze folds, automatic spin and depth/detail editing. Keep natural head tracking.
- Disable grip-scale and stick-driven movement for the first version. The user can
  look and lean; no continuous locomotion or collision claims.
- Keep wrist HELP, PASSTHRU and **RETURN** available. Right B also returns, with
  mode-specific help. Ensure it cannot simultaneously change a preset.
- Return restores the exact tabletop snapshot. Mode switching also cleans up the
  inside state, any fade and altered settings before activating the destination.
- Passthrough remains available; do not add an opaque global sky or floor.

## 5. File responsibilities and integration

Proposed new files; collapse these if a smaller implementation remains clear:

| File | Responsibility |
|---|---|
| `godot/scripts/ifs/fractal_ifs.gd` | Parameters, deterministic transform generation, reusable seed mesh, bounded publication, bounds, palette and clearance query. |
| `godot/scripts/ifs/ifs_editor.gd` | Guides, handle picking/capture, parameter drag, Undo, Sculpt/Inside transitions. Keep this out of the growing main input handler. |
| `godot/shaders/ifs.gdshader` | Only if existing material facilities cannot supply the intended opaque palette shading. |
| `godot/tools/ifs_check.gd` / `.sh` | Numeric/geometry/state checks. |
| `godot/tools/ifs_shot.gd` / `.sh` | Deterministic real-main-scene captures and integration assertions. |

Attach the IFS geometry beneath `cloud`, following Tree, so the established world
grab can move it. Keep editor parameter space independent of `cloud`'s world transform.
Explicitly gate IFS mode in main; an IFS mesh is not a particle `FractalSource`.

Audit all existing `not bulb_mode`, `not ground_mode`, `not tree_mode` predicates.
In particular, FLAME's selected state must exclude IFS. Disable hidden particle
simulation/baking/morphing and ambient cloud spin during IFS, restore destination
state on exit, and return before particle dispatch. Visibility alone is not enough:
`_sync_iteration()` and bulb clock/march updates also run earlier in `_process()`.
Ensure IFS recenter uses its own fixed tabletop framing, not stale particle bounds.

Add only IFS-relevant menu tiles; existing mode-specific tiles must remain hidden.
Five modes must fit the real wrist panel without reducing text into illegibility.
Update Help and HUD to report IFS state, actual detail, instance count and build
status. Reuse palette integration without rebuilding geometry. Update CHANGELOG
when user-visible code lands. No broad main.gd state-machine rewrite.

## 6. Implementation sequence and completion gates

Each milestone is independently reviewable, but completing only geometry does not
complete this plan. Continue through all available checks; report unavailable
headset validation explicitly rather than claiming full acceptance.

### IFS-1 — Geometry and feasibility

Implement the generator and seed in a desktop harness first. Capture default,
minimum/maximum depth, plane offset, plane rotation, and each detail rung at fixed
camera/scale. Test determinism, reflection math, counts, bounds and parity.
Show both an outside and a centre view. Reject a visually closed or unreadable
default; tune within this construction before implementing interaction polish.
When Quest is available, get an early static/close-up performance measurement.

### IFS-2 — Native mode and controller ownership

Wire the real app, hide irrelevant controls/work, add appropriate palette/help/HUD,
and introduce the minimal world-grab suspend/reset behavior. Capture all five menu
modes through the real scene. Verify all mode pairs, including leaving BULB while
marching and returning to TREE/forest and GROUND with their previous settings.

### IFS-3 — Sculpting

Implement handle capture, transform-space conversion, bounded previews, full rebuild
on release, depth, detail, Undo and Reset. Validate near/far picking, rotated/scaled
sculptures, menu interception, two-controller conflicts, lost tracking, release and
reacquisition. Confirm handles track smoothly while generated geometry catches up.

### IFS-4 — Enter and Return

Implement actual beam-clearance testing, deterministic placement, fade, snapshot
restore and frozen Inside controls. Test blocked entry and rapid Enter/Return/mode
changes. Confirm no part of the old bulb interior renderer is activated.

### IFS-5 — Evidence and Quest acceptance

Build debug APK, collect desktop and available device evidence, tune only measured
bottlenecks, and document any incomplete acceptance. Installation/testing follows
the implementation session's user authorization and device availability. No Git
push, production release or new Codex task creation is implied by this document.

## 7. Verification

### Meaningful automated checks

- Reflection: points on the plane stay fixed; reflection twice restores a point;
  translated planes affect the expected axis. Verify composed child transforms.
- Same parameters produce identical instance transforms; depth changes Z geometry
  without changing instance count; detail changes count without changing parameters.
- All generated beam corners lie within published bounds. Counts and allocation
  stay capped at every allowed parameter extreme. Full levels remain complete.
- Latest requested generation wins after rapid edits; cancelled edits never publish
  late; teardown leaves no job using freed nodes/resources.
- Known occupied entry candidate fails; known central opening passes; disabled
  entry changes neither pose nor mode. Return restores the original snapshot.
- Capturing a handle suppresses world grab/preset actions, and tracking loss cannot
  turn a held trigger/grip into a new action on recovery.

Commands from repo root (new `ifs_*` helpers must be created):

```bash
GODOT=godot bash godot/tools/parse_all.sh
GODOT=godot bash godot/tools/ifs_check.sh
# Only if a new custom shader is used:
GODOT=godot bash godot/tools/shader_check.sh shaders/ifs.gdshader
GODOT=godot bash godot/tools/ifs_shot.sh
GODOT=godot bash godot/tools/menu_shot.sh
GODOT=godot bash godot/tools/card_shot.sh
git diff --check
GODOT=godot bash godot/tools/build.sh
```

Check installed Godot selection through `godot/tools/env.sh`. Run captures serially;
some existing helpers have broad watchdog process matching. New helpers should own
and terminate only their child PID. Existing wrappers can filter diagnostics or
ignore import failures: inspect full logs and expected assertions, not just exit
codes. A PNG saved successfully proves neither active mode nor correct geometry.
Make new helpers exit nonzero on failure, timeout, parse error or missing evidence.

Save captures/logs under ignored `godot/.spike-out/ifs-YYYY-MM-DD/`. Include build
revision, dirty state, parameters, pose, material, eye scale, refresh, foveation and
actual instance/triangle counts. No npm build is needed for native-only changes;
run `npm run build` if implementation unexpectedly changes web code.

### Quest acceptance checklist

- Both eyes show consistent shape, normals and depth; close views expose no one-sided
  missing beams, clipping surprises or geometry vanishing from incorrect bounds.
- Mirror manipulation is understandable; a novice can deliberately change the shape.
- Depth feels distinct from world scaling and recursion detail.
- Captures, releases, two-hand transitions, headset focus loss and controller tracking
  recovery produce no jumps, stuck handles or accidental actions in another mode.
- Inside begins in visible empty space; ambient motion is off; Return is reachable
  with the menu and B. VR → MR → VR preserves placement and expected transparency.
- All five menus fit and are readable at wrist distance over bright passthrough.
- Benchmark default and worst allowed shape, close-up, live edits and Inside. Record
  CPU generation/publication and app CPU/GPU frame times with their measurement source.
- Target the actual selected refresh budget: 13.89 ms at 72 Hz or 11.11 ms at 90 Hz.
  Aim for p95 app CPU and GPU times below budget after warm-up, and no repeated missed
  frames during editing. These are proposed acceptance targets, not current results.
- Run at least 15 minutes including edit/entry cycles. Record eye resolution and QGO
  profile; do not hide a regression by changing resolution or refresh mid-comparison.

If performance misses: lower preview detail/update work first; then reduce selected
geometry and remeasure. Add spatial MultiMesh grouping only for a measured visibility
problem. Do not switch to interior raymarching, add dependencies, or declare success
from a cold desktop screenshot. Preserve a usable prototype and record the failing
measurement if the bounded approach cannot meet the target.

## 8. Copyable implementation prompt

```text
Implement docs/ifs-headset-plan.md in this FractalXR repository, native Godot first.
Read AGENTS.md, current project notes, and the full plan. Inspect the current code
around the listed symbols. Preserve unrelated working-tree changes.

Deliver the complete bounded prototype: an IFS mode with opaque recursive frames,
two editable mirror planes, independent depth/detail, reliable controller ownership,
Undo/Reset, and verified-clearance Enter/Return. Follow milestones IFS-1 through IFS-5.
The mesh construction is a new finite IFS assembly, not an exact conversion of the
existing KIFS distance-estimator presets. Keep the old bulb interior marcher disabled.

Use the plan's defaults without routine clarification. Adjust geometry values based
on actual visual evidence and record deviations. Reuse existing Godot/UI/grab code;
avoid broad refactors, extra features, new dependencies, web changes and Git pushes.
Run meaningful numeric checks, real-scene captures, applicable native gates and a
debug build. Perform authorized available Quest checks; label anything unavailable
as pending. Desktop captures do not establish stereo, comfort, grab feel or thermals.

Return changed files, behavior delivered, validation results, image/APK paths, actual
performance measurements, deviations from the plan and remaining acceptance items.
Do not stop after writing another plan or implementing only the geometry milestone.
```

## References

- [Godot MultiMesh guidance](https://docs.godotengine.org/en/stable/tutorials/performance/using_multimesh.html):
  batched instancing and all-or-none visibility; verify against the project's installed
  engine version. This informs the prototype, not a guaranteed Quest performance claim.
- [Godot thread-safe APIs](https://docs.godotengine.org/en/stable/tutorials/performance/thread_safe_apis.html):
  active scene-tree access and shared resource mutation require care. The default
  design here uses bounded main-thread work before introducing threading.
- Existing project context: `docs/visual-plan/README.md`, `godot/scripts/main.gd`,
  `godot/scripts/tree/fractal_tree.gd`, and `~/vault/projects/FractalXR.md`.
