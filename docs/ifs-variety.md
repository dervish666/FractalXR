# IFS variety and surface work, 2026-11-13

A preset chooses a polyhedron seed, a list of contracting maps, an opening recursion level
and a cheaper live level. `child_maps()` composes each map with its selected mirror-group
elements. `build()` walks the resulting tree breadth first and uploads one MultiMesh buffer.
Each instance is a whole seed frame. The shader reads level, radius and birth from custom
data, and the parent origin from the instance colour. Editing changes the two mirror planes
or the final depth stretch. DIVE uses the same child maps to re-root an exact subtree.

The screenshots supplied for this task show overhanging square beam ends and flat faces.
The endpoint centres were correct. `_frame_beams()` added a half-width to each end of every
beam, regardless of the angle between incident edges. Those independent box caps overlapped
as spikes rather than forming a joint. Scaling the whole frame at each recursion level
preserved that defect. Caps were present; missing caps and per-level endpoint rounding were
not the cause. Back-face culling compounded the surface problem: Godot does not reverse
winding for individual reflected instances inside a MultiMesh.

Tubes now end exactly at the seed vertices. Each unique vertex gets one octahedral node
with smooth radial normals. Its insphere is slightly larger than the tube radius, so the
node encloses every incident rim regardless of edge direction. Tubes have five sides with
smooth normals. All nodes and tubes remain in the same mesh and draw call. Two-sided drawing
keeps the near faces of reflected instances. Clearance capsules and published bounds include
the nodes. The endpoint regression measures the old extension as a 0.03-unit error and the
new endpoints within 0.000001 units.

The material computes directional key and fill shading from world-space normals, darkens
fine recursion levels by up to 20%, and adds 4.5% axial bands with derivative filtering.
There are no shadow maps, extra lights, texture assets or extra surface passes. The material
keeps Godot's `unshaded` render mode because its light is analytic, including in passthrough.
This is depth-based darkening, not screen-space ambient occlusion.

EVOLVE toggles contraction breathing by 9% over 48 seconds, a turn over 240 seconds, an
8-degree rocking tilt over 64 seconds and 6% radial drift over 80 seconds. The root transform
stays fixed. The existing every-other-frame rebuild and per-preset live rung remain. A held
edit or active DIVE freezes the maps. Switching EVOLVE off restores the stored map buffer.
The palette clock remains independent. Objects open 32 cm wide with the centre 60 cm forward
and 18 cm below eye height. These dimensions need an actual headset judgement.

These are finite frame sculptures of the named IFS rules, not opaque solid approximations.
All generations remain visible. With EVOLVE off and default handles the new rules use the
listed contractions and placements. Moving the handles or enabling EVOLVE intentionally
deforms those rules. The original five mirrored studies retain their original names and maps.

| Preset | Rule and source | Opening level | Instances | Triangles |
|---|---|---:|---:|---:|
| FRAMES | Existing eight corner-frame study, contraction 0.35 | 3 | 585 | 107,640 |
| TETRA | Existing eight-corner mirrored tetrahedron study, contraction 0.38 | 3 | 585 | 53,820 |
| STAR | Existing twelve-satellite octahedron study, contraction 0.30 | 3 | 1,885 | 316,680 |
| CROSS | Existing mirrored tetrahedron pinwheel, contraction 0.50 | 3 | 585 | 53,820 |
| TWIST | Existing eight cube maps with a 34-degree local turn | 3 | 585 | 107,640 |
| GASKET | Four half-size tetrahedra at the vertices. [Rico Trebeljahr's construction](https://fractal.garden/sierpinski-tetrahedron) | 4 | 341 | 31,372 |
| PYRAMID | Five half-size regular square pyramids at the vertices. [Trebeljahr's square-base variant](https://fractal.garden/sierpinski-tetrahedron) | 4 | 781 | 93,720 |
| OCTAFLAKE | Six half-size octahedra at the axial vertices. [Trebeljahr's polyhedron flake](https://fractal.garden/polyhedron-flake) | 3 | 259 | 43,512 |
| MENGER | Twenty third-size cubes, retaining corners and edge centres. [Trebeljahr's Menger construction](https://fractal.garden/menger-sponge) | 2 | 421 | 77,464 |
| JERUSALEM | Eight corner cubes at sqrt(2)-1 and twelve edge cubes at its square. [Eric Baird's original design](https://www.coroflot.com/erkdemon/Jerusalem-Cube), [Trebeljahr's scale derivation](https://fractal.garden/jerusalem-cube) | 2 | 421 | 77,464 |
| VICSEK | Seven third-size cubes at the centre and face centres. [Trebeljahr's 3D Vicsek construction](https://fractal.garden/vicsek-fractal-3d) | 3 | 400 | 73,600 |
| CANTOR | Eight third-size corner cubes. [Robert Dickau's 3D Cantor construction](https://www.robertdickau.com/cantor.html) | 3 | 585 | 107,640 |
| MOSELY | Lighter eighteen-copy version, keeping edge and face centres. [Trebeljahr's two Mosely rules](https://fractal.garden/mosely-snowflake) | 2 | 343 | 63,112 |

The linked construction pages were fetched. Cantor's map list follows directly from
independently choosing either retained third on x, y and z, which gives eight maps at
scale 1/3. The sources describe solid or infinite fractals; retaining all levels as frames
is this app's rendering decision.

Per-map masks select I, R1, R2 or R2*R1. This avoids duplicate copies on symmetry planes and
keeps the GASKET tetrahedra in the correct orientation. Both mirror handles still affect every
preset. Branch topology changes use the existing grow-in rather than interpolate incompatible
map slots. The original unmasked studies still morph as before. The gallery's existing paging
handles all 13 entries on two pages. The help card calls the new toggle EVOLVE too.

Before and after counts for the original shapes at their opening rung are below. Instance
counts do not change. Each hero is still one MultiMesh draw. Echo tiers share its mesh.

| Seed / presets | Instances | Before triangles | After triangles | Change |
|---|---:|---:|---:|---:|
| Cube / FRAMES, TWIST | 585 | 84,240 | 107,640 | +27.8% |
| Tetrahedron / TETRA, CROSS | 585 | 42,120 | 53,820 | +27.8% |
| Octahedron / STAR | 1,885 | 271,440 | 316,680 | +16.7% |

STAR runs at level 2 while evolving, as before: 157 instances and 22,608 -> 26,376 triangles.
PYRAMID evolves at level 3: 156 instances and 18,720 triangles. Other new presets evolve at
their opening level. The global ceilings remain 8,192 instances and 1,000,000 triangles.
The numeric gate exercises every preset at the editor's plane and depth extremes.

Baseline revision: `311374b`.

`ifs_variety_cost.sh` compares the current implementation against an optional baseline in
`.spike-out/ifs-baseline.gd`, with its shader at `.spike-out/ifs-baseline.gdshader`. Generate
those files with `git show <baseline>:godot/scripts/ifs/fractal_ifs.gd` and the equivalent
shader path, remove the baseline script's `class_name`, and point its shader load at the
baseline shader. The run uses 1280x800 Mobile rendering, disables vsync, samples 240 frames
per case and reverses order on a second pass. It measures FRAMES and STAR both still and
with motion, with echoes off. GPU time reports `unavailable` on this Mac.

The baseline FRAMES live tick averaged 304.5 microseconds per frame, compared with 300.5
after this change. The two-frame rebuild cadence is included. STAR live tick was 120.1 ->
128.2 microseconds. Desktop wall-frame times varied between 1.42 and 4.04 ms before and
3.54 and 3.99 ms after. That variance and missing GPU timing prevent a useful GPU-cost
claim. These numbers do not establish a Quest frame budget. The Quest needs a warm thermal
soak with the same preset, LEVELS, ECHOES, eye resolution and EVOLVE setting on both builds.



The thumbnail bake now uses a three-quarter IFS view and crops the central subject before
luminance framing. This keeps distant scene markers out of the crop and makes the hand-sized
sculpture fill its tile. The atlas contains 68 entries, including all 13 IFS shapes.
`thumbs.png.import` was imported and staged with the atlas. Its bytes are unchanged.

The menu harness had a timing defect in its float checks: 200 frames are shorter than the
0.4-second flight at over 500 fps. Both waits now use a three-second deadline and the actual
animation completion condition. The position, parent, drift and return-to-wrist assertions
are unchanged. This fixed the observed early-read failures without changing menu behaviour.

Fresh-worktree export needed the ignored Android Gradle template as well as the Meta vendors
plugin. The first-run template install in `build.sh` did not install it. The installed Godot
4.7.2 `android_source.zip`, canonical `.build_version` and empty `.gdignore` supplied the
local build directory. No template, plugin or APK is committed. No Quest operation ran.

The following gates were run against this worktree:

```text
SELFTEST PASS
PARSEALL PASS files=74 errors=0 control=FAIL
LOGICCHECK PASS failures=0 control=FAIL
MENUSHOT PASS shots=52 failures=0
CARDSHOT PASS modes=5
IFSCHECK PASS failures=0
IFSMODE PASS failures=0 dir=res://.spike-out/ifs-2026-09-16
THUMBBAKE PASS tiles=68 failures=0
MANIFEST APK PASS android.hardware.vr.headtracking required=true launch activity excludeFromRecents=true
BUILD PASS debug
```

Numeric coverage includes the old overextension as a failing control, smooth-normal winding,
all preset counts and caps, bounds, both mirror planes, tracked-handle edit/undo, and a DIVE
re-root on every entry. `ifs_mode_shot.sh` also drives the EVOLVE tile through the main scene.
Its measured default width was 0.320 m, centre distance 0.626 m and nearest bound 0.466 m.

Every preset has an outside PNG and a clipped interior PNG in
`godot/.spike-out/ifs-2026-09-16/preset-*.png`. I inspected all 26 through the labelled contact
sheet and inspected selected full-size frames and the baked atlas. The contact sheet is
`godot/.spike-out/ifs-variety-contact.png`. The debug APK is
`godot/build/fractalxr-debug.apk`. The timing log is
`godot/.spike-out/ifs_variety_cost.log`.

Only the headset can confirm the rounded joints and surface bands at actual stereo pixel
density, the hand-sized framing and reach, editing and grab feel, EVOLVE comfort, and the
warm GPU/thermal cost with ECHOES on. Room-size centred families deliberately use the head
clip sphere; their near-eye appearance also needs a headset check. No deployment ran.
