extends Node3D
class_name FractalGround

## The ground viewer: you stand on the fractal and it runs to the horizon. With SPHERE on it
## curves round you instead, mapped onto a 2 m sphere by inverse stereographic projection from
## the zenith in ground.gdshader, with a translucent glass disc at y = 0 to stand on: bowl
## bends the plane's inner 45 m onto the lower hemisphere under the sky, and globe carries the
## same map over the top, the whole plane on the sphere with infinity at the zenith.
##
## A clipmap. LEVELS square textures of n_tex texels, level i with texels twice the size of
## level i-1, every window centred under the viewer. ground.glsl fills them (escape-time
## Mandelbrot or Julia, four data channels), ground.gdshader samples the level whose texel
## matches the pixel footprint and does all the colouring at sample time. So the frame cost
## is flat whatever the zoom or iteration count, and only movement costs compute: a pan
## computes the strip that came into view, a zoom step re-labels the levels (the texel grid
## is anchored at the fractal origin, so level i at the new zoom IS level i-1 at the old)
## and rebuilds just the new finest one. All of it against a per-frame texel budget that
## adapts to the measured GPU time, so a big jump sharpens over a few frames rather than
## dropping any.
##
## Deep levels are gated per dispatch on DF_RATIO so a shallow fill costs what it always did.
## Past it the Mandelbrot, cubic and quartic iterate by perturbation against one reference
## orbit (ground.glsl's PERT), and the folded families and Julia in two-float (df32)
## arithmetic. docs/deep-zoom/README.md has the df32 reasoning; perturbation came back once
## GroundGuide's tours started asking for 16384 iterations, where df32 on the M1 filled 7%
## of a view in six minutes.

## Level size. A level is only usable out to about (n/2 - SLACK) of its texels from the
## viewer, and on a ground plane seen at grazing angles that window radius, not the texel
## size, is what limits sharpness in the middle distance. 1024 at 8 bytes a texel is 72MB
## for the stack and a full rebuild of ~9M texels; RENDER doubles it to 2048 (288MB, 36M
## texels) for a still worth waiting for.
var n_tex := 1024
## Nine, because the finest texel is 1.5mm and the horizon still wants ~180m of window.
const LEVELS := 9
## The shader treats n_tex/2 - SLACK texels around the viewer as a level's reach.
const SLACK := 48
## The window re-centres once the viewer drifts this many texels from its centre. Half of
## SLACK, so the strip a re-centre queues lies RECENTRE texels beyond the shader's reach and
## the fill has that much walking to land it before anything can sample it. Re-centring at
## SLACK put the new strip right at the reach, exposed from the next step on.
const RECENTRE := SLACK / 2
## Finest texel at the viewer's feet, in metres, at a zoom stage boundary (it grows to
## twice this just before the next stage). About two pixels at standing height.
const TEXEL_M := 0.0015
## World metres per fractal unit at stage 0: the whole Mandelbrot is ~90m across.
const WPU_BASE := 30.0
const STAGE_MIN := -4
## 2^23, about 8e6x. Past this df32 itself runs out: tools/ground_check.sh measures its
## error as a fraction of a texel, and at stage 22 every escape-time family is within 0.11
## of a texel on four spots each, while at stage 23 Buffalo and Celtic are 0.6-0.9 out, as
## wrong as sampling the neighbour. Julia is the weak one, 0.23-0.38 at stage 22: those
## texels change count when the point moves by df32's own rounding, so they read as grain
## rather than blocks. Going further needs perturbation or more than two floats.
const STAGE_MAX := 22
## Anchor granularity: n_tex (2048 at most) times 2^(LEVELS-1), doubled for headroom.
const ANCHOR_Q := 1048576
## Re-anchor on the viewer once its level-0 index from the anchor passes this. Well inside
## int32, with room for a window of n_tex either side and the shader's arithmetic.
const ANCHOR_REBASE := 268435456
const BUDGET_MIN := 20000.0
const BUDGET_MAX := 2000000.0
## GPU time the fill aims for each frame. It was 3500, more than the headset has spare: a
## 2026-09-15 headset log reads draw_ms 12.4-12.8 in ground mode with the fill idle, of a
## 13.9 ms frame at 72 Hz. Not yet measured on the headset at 2000. A smaller fill takes
## longer to land, which the shader covers with the next coarser level, not stale texels.
const TARGET_US := 2000.0
## Past this many texels per fractal unit of coordinate, float32 stops telling neighbouring
## texels apart and a dispatch switches to the df32 variant of ground.glsl. A float32 near
## a coordinate of magnitude m is spaced m * 2^-24 to m * 2^-23 apart, so at 2^22 the
## spacing is a quarter to a half of a texel. Measured (tools/ground_check.sh, SWEEP):
## float32 starts pairing identical neighbours at a ratio of about 1.4e7 (stage 9 at a
## coordinate near 1), none at 5e6, so this switches one stage before the blocks. The
## orbit's own rounding is the same size at |z| ~ 1, which is why m is never below 1.
const DF_RATIO := 4194304.0
## What a df32 texel is charged against the per-frame budget, in float32 texels, so a deep
## fill sharpens over more frames instead of spiking one. 3 is the plan's estimate for a
## GPU that runs the Dekker arithmetic natively (docs/deep-zoom/README.md); Apple M1 with
## fast math off measured 1.5-1.7x, and with `precise` about 37x (see ground.glsl). The
## Quest's figure is unmeasured, so this is only the starting point: _flush() raises the
## charge when a deep fill still runs over TARGET_US with the budget already at its floor,
## which is the one case the budget loop alone cannot fix.
const DF_COST := 3.0
const DF_COST_MAX := 64.0
## Families ground.glsl's PERT variant carries, indexing FORMULA_NAMES: the Mandelbrot. The
## cubic and quartic perturb on paper but not in float32; see the shader.
const PERT_FORMULAS: Array[int] = [0]
## A perturbation texel against the budget, in float32 texels: the same float32 maths plus a
## reference read and the rebase test.
const PERT_COST := 1.5
## Longest stored reference orbit. Rebasing lets a shorter one serve any iteration count.
const REF_MAX := 32768
## A reference serves texels within about this many level-0 texels of it, and the viewer is
## given a new one before the window can reach past it. d is float32 and |d| starts at |dc|,
## so its rounding is in proportion to the texel's distance from the reference, not to the
## gap between texels: a C replay of the loop held a boundary patch at 98.8% with 64-bit d
## at any distance, and float32 d fell to 94% at 1000 texels and 91% at 4000 (its own
## reference: 98.5%). tools/ground_check.sh, mean count error in texels of position against
## df32's 0.01-0.05: 0.003-0.04 on the reference's own patch, 0.12-0.16 at 4880 texels. 2000
## is 3 m of walking at level 0, more at every coarser one, and a rebuild is a worker job.
const REF_RANGE_T0 := 2000.0
## The floor reference holds still while the eye stays within this many metres of it, and
## once it has to move it follows until it is back within REF_SETTLE_M. Turning your head
## swings the eye 8-10 cm round the neck, and a reference that followed every centimetre
## re-levelled the whole displaced field on every glance: in a capture, a 90 degree turn in
## place changed the frame as much as walking does. Walking still carries it along.
const REF_HOLD_M := 0.3
const REF_SETTLE_M := 0.01

## Fractal coordinate under world (0, 0), held as two 64-bit floats. It used to be a
## Vector2, which in a standard Godot build is float32: at 0.7 its step is 6e-8, a metre
## and a half of floor at stage 18 and seven at stage 22, so walking would have moved in
## jumps and then not at all. The Vector2 property is for callers that only need a rough
## position (tools, the orbit trace); everything here reads _cx and _cy.
var _cx := -0.6
var _cy := 0.0
var centre: Vector2:
	get:
		return Vector2(_cx, _cy)
	set(v):
		_cx = v.x
		_cy = v.y
var wpu := WPU_BASE
var julia := false
## The Julia seed, 64-bit like the centre: julia_here() takes it from the viewer's position,
## and a float32 Vector2 rounded that to the same c for every point within 6e-8, a seed
## a metre and a half wide at stage 18. julia_c is the rough view for the orbit trace.
var _jx := -0.8
var _jy := 0.156
var julia_c: Vector2:
	get:
		return Vector2(_jx, _jy)
	set(v):
		_jx = v.x
		_jy = v.y
## Which escape-time family the tiles are filled with. ORDER IS LOAD-BEARING: it indexes
## the switch in ground.glsl's iterate(). Append only, and keep the shader in step.
const FORMULA_NAMES := ["mandelbrot", "burning ship", "tricorn", "celtic",
	"perpendicular", "buffalo", "cubic", "quartic"]
## Where each family opens, indexed like FORMULA_NAMES: (cx, cy) is the fractal point under
## your feet and z the world metres per fractal unit. One home for all of them, -0.6 on the
## real axis, stood every family but the Mandelbrot on a blank plain: inside the set, near
## black, or on a smooth exterior with the boundary at the horizon. Each was picked by
## rendering candidates from the ground_shot pose (standing eye, 22 degrees down, facing -y
## in fractal space) and keeping one with boundary detail under the feet and ahead. The
## Mandelbrot moved too: at -0.6 you stood inside the cardioid on the near-black interior.
## Julia views open from these too. Their picture follows the seed JULIA takes from where you
## stand, not the home, so they were not given a table of their own and were not rendered.
const HOMES := [
	Vector3(-0.55, 0.62, 30.0),   # mandelbrot: above the cardioid, its bulbs ahead
	Vector3(-1.6, 0.0, 120.0),    # burning ship: the mast and its flames, near the ship
	Vector3(-1.2, 0.08, 30.0),    # tricorn: astride the left spike
	Vector3(-1.35, 0.5, 30.0),    # celtic: the speckled field left of the body
	Vector3(-0.4, 0.9, 30.0),     # perpendicular: the upper-left fringe
	Vector3(-1.25, -0.05, 30.0),  # buffalo: the left lobe's edge
	Vector3(-0.55, 0.3, 30.0),    # cubic: the left flank of the body
	Vector3(-0.75, 0.3, 60.0),    # quartic: between the body and its left bulb
]
var formula := 0
var max_iter := 256
## Raise the iteration count with depth (iter_floor). tools/ground_check.gd turns it off to
## pin the count its CPU reference runs to.
var auto_iter := true
## The count a GroundGuide trip asks for: about ITER_PER_PERIOD times its minibrot's period.
## Measured round eight tour stops (period 23 to 779): 90% of the outside points in view
## escape within 7 to 38 periods and 95% within 11 to 72, where 256-4096 left them black.
## 0 when no trip has asked. The shader's periodicity check keeps the interior cheap.
var iter_hint := 0
var _iter_used := 256       # the effective count the stored levels were filled with
var texture_on := true
var stalk := 0.0
var stalk_width := 0.05
## GPU microseconds of the last frame's fill, from timestamps.
var ground_us := 0.0

var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _shader_df: RID
var _pipeline_df: RID
var _shader_pert: RID
var _pipeline_pert: RID
## Two references, each with its own buffer and uniform set. Slot 0 is the orbit of a point
## by the viewer, slot 1 a minibrot's nucleus GroundGuide pinned. A rect takes the nucleus
## when it is in range, measured in that level's own texels, else the viewer's: the fine
## levels round your feet stay on the viewer's, and the coarse ones that draw the minibrot
## ahead on its nucleus, whose orbit never escapes.
var _ref_buf: Array[RID] = [RID(), RID()]
var _set_pert: Array[RID] = [RID(), RID()]
## Perturbation on for the families that allow it. tools/ground_check.gd and the bench turn
## it off to time df32.
var perturb := true
## Slot 0 as the main thread last built it, [x, y, len, capped_at]: its own copy for deciding
## when to build another. The render thread reads only the _ref_next pair and _ref_cur.
var _ref_main: Array = []
var _ref_next0: Array = []  # [x, y, len, PackedFloat32Array] for slot 0, for the render thread
var _ref_next1: Array = []  # the same for slot 1; [] nothing new
var _ref_drop1 := false     # slot 1 is to be forgotten (home, a new family)
var _ref_cur: Array = [[], []]   # per slot [x, y, len] the GPU buffer holds; render thread only
## A reference orbit is 64-bit GDScript work, up to REF_MAX steps (milliseconds), so it is
## built on the WorkerThreadPool and the fill uses df32 for the few frames until it lands.
var _ref_task := -1
var _ref_built: Array = []  # [x, y, n, cap, PackedFloat32Array], written by the task
## A minibrot's nucleus GroundGuide offered as the reference: x, y in 64-bit, period p.
var _pin_x := 0.0
var _pin_y := 0.0
var _pin_p := 0
var _set: RID
var _tex: RID
var _texture := Texture2DArrayRD.new()
var _mesh_instance: MeshInstance3D
var _sky: MeshInstance3D
var _stand: MeshInstance3D
var _stand_mat: ShaderMaterial
var _material: ShaderMaterial
## Sphere mode (SPHERE tile). sphere_radius is in metres (0 = flat floor),
## sphere_horizon_r is the plane radius mapped to the equator, and _sphere_fog_start is the
## fraction of that radius where the bowl's rim fog begins. sphere_globe carries the map past
## the equator to the zenith and has no rim.
var sphere_radius := 0.0
var sphere_horizon_r := 60.0
var _sphere_fog_start := 0.85
var sphere_globe := false
## GLOBE runs the clipmap this many stages coarser than the zoom asks for. Seen from the
## centre, the nadir's pixel covers H / 2 plane metres a radian (17 mm on the Quest at
## H = 45), so the finest two levels (1.5 to 6 mm) were never sampled there; two stages
## coarser, level 0 is 6 to 12 mm and still finer than that pixel, and the coarsest level
## reaches four times as far, 700 to 1400 m, 3.6 to 7.3 degrees from the zenith at H = 45.
## Changing it is a zoom of four as far as the fill goes: the two new coarse levels fill
## while the cap closes over them (_tick_globe_cap).
const GLOBE_STAGE_BIAS := 2
var _stage_bias := 0
## The stage the zoom alone asks for, before that bias. iter_floor() and the shader's
## relief_unit go by it, so the land keeps its height in metres and the fill its iterations.
var _zoom_stage := 0
## GLOBE's cap: past the data the fragment works the escape count itself, crossfading in
## between plane radii GLOBE_CAP_FADE * _globe_cap_m and _globe_cap_m. That radius eases out to
## GLOBE_CAP_M behind the coarsest level's reach and snaps in at once if the reach falls short. 600 m is 8.6 degrees from the
## zenith at H = 45 and inside the coarsest level's 650 m minimum. From 420 to 590 m out (by
## the stage) that level's texels fall below a Quest pixel, so the fade also hides the shimmer.
const GLOBE_CAP_M := 600.0
const GLOBE_CAP_FADE := 0.6
const GLOBE_CAP_MIN_M := 1.0
var _globe_cap_m := GLOBE_CAP_MIN_M
var _eye_y := 1.6
## The sphere's centre and the standing glass disc under it are anchored in the world. A head
## turn swings the eyes 8 to 10 cm round the neck and looking down drops them about 10 cm; a
## centre on the eye carried the 2 m bowl with every glance, against the stand and the
## controllers. The centre holds still while the head stays within STAND_HOLD_M across and
## STAND_HOLD_Y_M up or down, and eases after it (time constant 0.25 s) once you walk or crouch
## further, until it sits within the settle distance again. The disc lies at y = 0 and hides
## on the flat floor and in passthrough.
const STAND_RADIUS := 0.75
const STAND_HOLD_M := 0.55
const STAND_SETTLE_M := 0.05
const STAND_HOLD_Y_M := 0.3
const STAND_SETTLE_Y_M := 0.03
var _stand_xz := Vector2.ZERO
var _sphere_cy := 1.6
var _stand_set := false
var _stand_chasing := false
var _cy_chasing := false
var _stand_passthrough := false
var _stand_fits := true
var _stage := 0
var _rot := 0
var _win_lo: Array[Vector2i] = []
var _have: Array[bool] = []
var _full: Array[bool] = []
## Per level, Array[Rect2i] of texels (counted from the anchor) whose slots do not hold that
## level's data yet: a pan strip, a new level, a rebuild. The shader routes round them.
var _dirty: Array = []
## Per level, Array[Rect2i] of texels that hold the right place but an older fill (another
## iteration count). Shown as they are until refilled, after all of _dirty.
var _refresh: Array = []
## Per level, the part of the window the shader may read, as texels from the viewer's.
var _clean := PackedVector4Array()
var _budget := 150000.0
var _head_xz := Vector2.ZERO
var _ready_ok := false
var _error := ""
var _worked := false
var _df_cost := DF_COST
var _df_run := 0            # consecutive fills that ran nothing but df32 dispatches
var _timed := false         # a GPU timestamp pair has been read at least once
## World -> fractal rotation about the viewer (the basis only; translation is `centre`).
## fractal = centre + M * world_xz / wpu.
var _m := Transform2D.IDENTITY
var _glide := Vector2.ZERO        # world metres still to travel toward a trigger target
## The glide's own speed last frame, m/s, for the comfort vignette.
var glide_mps := 0.0
## A pick near the horizon lands tens of metres out (23.5 m was measured), and the ease's first
## frame then ran at ~80 m/s. The pick is clamped to GLIDE_MAX_M along its own direction and the
## travel to GLIDE_MAX_MPS, so a far pick is a steady glide that way, not a lurch.
const GLIDE_MAX_M := 6.0
const GLIDE_MAX_MPS := 1.5
var _lfx := 0.0                   # fractal point the floor is levelled to; lags the viewer
var _lfy := 0.0
## Level-0 texel index of the anchor, in 64-bit ints. Every texel index this node stores or
## hands a shader counts from it (level i from _ax >> i), because absolute indices pass
## int32 around stage 16 and Vector2i, Rect2i and GLSL ivec2 are all int32. It is kept a
## multiple of ANCHOR_Q, so _ax >> i is a multiple of the level size at every level and a
## texel's torus slot, index mod n_tex, is the same counted either way: re-anchoring
## re-labels the stored windows and never moves or recomputes a texel.
var _ax := 0
var _ay := 0
var _level_set := false
var _level_chasing := false
var _pending_peak := 0
## Test hook: called with (level, rect) whenever a rect is queued because its slots no
## longer hold that level's texels. tools/ground_fill.gd poisons them through it.
var on_queue := Callable()


func get_error() -> String:
	return _error


func _init() -> void:
	_material = ShaderMaterial.new()
	_material.shader = load("res://shaders/ground.gdshader")
	# A radial grid centred on the head, ring spacing growing with distance, so the
	# vertex shader can displace real height: fine where you stand, coarse where the
	# fog takes over. update() keeps it under the viewer.
	var plane := _radial_mesh()
	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.name = "Ground"
	_mesh_instance.mesh = plane
	_mesh_instance.material_override = _material
	_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mesh_instance)
	# The sky: the same ground mirrored overhead. Same textures, same shader, one more
	# plane, so it costs fill and nothing else.
	_sky = MeshInstance3D.new()
	_sky.name = "Sky"
	_sky.mesh = plane
	_sky.material_override = _material
	_sky.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_sky.rotation.x = PI      # face down
	_sky.visible = false
	add_child(_sky)
	# Real-floor standing glass disc for VR comfort in sphere mode (bowl and globe).
	_stand_mat = ShaderMaterial.new()
	_stand_mat.shader = load("res://shaders/ground_stand.gdshader")
	var stand_plane := PlaneMesh.new()
	stand_plane.size = Vector2(STAND_RADIUS * 2.0, STAND_RADIUS * 2.0)
	_stand = MeshInstance3D.new()
	_stand.name = "Stand"
	_stand.mesh = stand_plane
	_stand.material_override = _stand_mat
	_stand.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_stand.visible = false
	add_child(_stand)
	for i in LEVELS:
		_win_lo.append(Vector2i.ZERO)
		_have.append(false)
		_full.append(true)
		_dirty.append([] as Array[Rect2i])
		_refresh.append([] as Array[Rect2i])
		_clean.append(Vector4.ZERO)
	_material.set_shader_parameter("tex_size", n_tex)
	_material.set_shader_parameter("num_levels", LEVELS)
	_material.set_shader_parameter("slack", float(SLACK))
	visible = false


const MESH_RINGS := 160
const MESH_SECTORS := 192
const MESH_R0 := 0.04        # first ring, metres
const MESH_R_MAX := 320.0    # past fog_end


## Rings of vertices with geometric radius growth: about 6% of the distance between
## rings, so the sample level the vertex shader picks tracks the fragment's. No
## T-junctions to stitch, one draw, ~30k vertices.
static func _radial_mesh() -> ArrayMesh:
	var verts := PackedVector3Array()
	var idx := PackedInt32Array()
	var g := pow(MESH_R_MAX / MESH_R0, 1.0 / float(MESH_RINGS - 1))
	verts.append(Vector3.ZERO)
	for k in MESH_RINGS:
		var r := MESH_R0 * pow(g, k)
		for j in MESH_SECTORS:
			var a := TAU * float(j) / float(MESH_SECTORS)
			verts.append(Vector3(r * cos(a), 0.0, r * sin(a)))
	# Centre fan.
	for j in MESH_SECTORS:
		var j1 := (j + 1) % MESH_SECTORS
		idx.append_array([0, 1 + j, 1 + j1])
	for k in MESH_RINGS - 1:
		var b0 := 1 + k * MESH_SECTORS
		var b1 := b0 + MESH_SECTORS
		for j in MESH_SECTORS:
			var j1 := (j + 1) % MESH_SECTORS
			idx.append_array([b0 + j, b1 + j, b1 + j1, b0 + j, b1 + j1, b0 + j1])
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	# Displaced in the vertex shader, so the true bounds are not the flat ones.
	m.custom_aabb = AABB(Vector3(-MESH_R_MAX, -60.0, -MESH_R_MAX), Vector3(2.0 * MESH_R_MAX, 120.0, 2.0 * MESH_R_MAX))
	return m


## Build the GPU side. Render thread only.
func setup() -> bool:
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		_error = "No RenderingDevice"
		return false
	var file: RDShaderFile = load("res://shaders/ground.glsl")
	if file == null:
		_error = "ground.glsl missing"
		return false
	# Two variants of one file: f32 is the original fill, df the two-float one. Separate
	# pipelines rather than a branch, so the shallow variant carries none of the df code's
	# registers and costs exactly what it did.
	var spirv := file.get_spirv(&"f32")
	var spirv_df := file.get_spirv(&"df")
	var spirv_pert := file.get_spirv(&"pert")
	if spirv == null or spirv_df == null or spirv_pert == null:
		_error = "ground.glsl: missing f32/df/pert versions"
		return false
	if spirv.compile_error_compute != "" or spirv_df.compile_error_compute != "" \
			or spirv_pert.compile_error_compute != "":
		_error = "ground.glsl: %s%s%s" % [spirv.compile_error_compute,
			spirv_df.compile_error_compute, spirv_pert.compile_error_compute]
		return false
	_shader = _rd.shader_create_from_spirv(spirv)
	_pipeline = _rd.compute_pipeline_create(_shader)
	_shader_df = _rd.shader_create_from_spirv(spirv_df)
	_pipeline_df = _rd.compute_pipeline_create(_shader_df)
	_shader_pert = _rd.shader_create_from_spirv(spirv_pert)
	_pipeline_pert = _rd.compute_pipeline_create(_shader_pert)
	for s in 2:
		_ref_buf[s] = _rd.storage_buffer_create(REF_MAX * 16)

	_tex = _rd.texture_create(level_format(n_tex, LEVELS), RDTextureView.new(), [])
	_texture.texture_rd_rid = _tex
	_material.set_shader_parameter("levels", _texture)

	var img := RDUniform.new()
	img.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	img.binding = 0
	img.add_id(_tex)
	_set = _rd.uniform_set_create([img], _shader, 0)
	_set_pert = [_pert_set(img, 0), _pert_set(img, 1)]
	_ready_ok = true
	return true


## The PERT variant's uniform set: the levels image and the reference orbit. Built in
## setup() and again in set_quality(), which frees the texture this depends on.
func _pert_set(img: RDUniform, slot: int) -> RID:
	var buf := RDUniform.new()
	buf.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	buf.binding = 1
	buf.add_id(_ref_buf[slot])
	return _rd.uniform_set_create([img, buf], _shader_pert, 0)


## The clipmap stack's format, in one place because setup(), set_quality() and
## tools/ground_check.gd must agree with ground.glsl's image declaration.
static func level_format(n: int, layers: int) -> RDTextureFormat:
	var fmt := RDTextureFormat.new()
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY
	fmt.width = n
	fmt.height = n
	fmt.array_layers = layers
	# Four 16-bit uints, packed by ground.glsl's encode(): the count as a full float32 so
	# its fraction survives past 2048 (RGBA16F lost it there, and ITER goes to 4096), the
	# distance as a half of its log2, texture and inside flag in the last. Still 8 bytes a
	# texel: RGBA32F would have doubled the stack, to 604MB on RENDER. Integer formats
	# cannot be filtered, which costs nothing because ground.gdshader only texelFetches.
	fmt.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_UINT
	fmt.usage_bits = (RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT)
	return fmt


func is_ready() -> bool:
	return _ready_ok


# --- geometry ---------------------------------------------------------------------

func _texel0() -> float:
	return TEXEL_M / WPU_BASE / pow(2.0, float(_stage))


func _texel(level: int) -> float:
	return _texel0() * pow(2.0, float(level))


## Fractal coordinate under the viewer's head, rounded to a Vector2. viewer_fx/fy are the
## full 64-bit coordinate.
func viewer_fractal() -> Vector2:
	return Vector2(viewer_fx(), viewer_fy())


## The head's offset is a few metres over wpu, small enough that its float32 rounding is
## far under a texel; it is the sum with the centre that needs the 64 bits.
func viewer_fx() -> float:
	return _cx + _m.basis_xform(_head_xz).x / wpu


func viewer_fy() -> float:
	return _cy + _m.basis_xform(_head_xz).y / wpu


## World xz (metres) to the fractal point under it, and back. The mapping is
## fractal = centre + M w / wpu with M a rotation, so the inverse is its transpose. Both
## pass through a float32 Vector2, so they are for the orbit trace and tools, not texels.
func world_to_fractal(w: Vector2) -> Vector2:
	var o := _m.basis_xform(w) / wpu
	return Vector2(_cx + o.x, _cy + o.y)


## world_to_fractal() without the float32 round trip: [x, y] in 64-bit floats, for the
## orbit trace, which iterates the point under the hand and at depth needs it to the texel.
func world_to_fractal64(w: Vector2) -> PackedFloat64Array:
	var o := _m.basis_xform(w) / wpu
	return PackedFloat64Array([_cx + o.x, _cy + o.y])


## fractal_to_world() for a 64-bit point: the difference from the centre is taken in
## doubles, so a beacon deep in the set lands on its texel and not on float32's grid.
func fractal64_to_world(x: float, y: float) -> Vector2:
	return _m.basis_xform_inv(Vector2((x - _cx) * wpu, (y - _cy) * wpu))


func fractal_to_world(f: Vector2) -> Vector2:
	return _m.basis_xform_inv(Vector2((f.x - _cx) * wpu, (f.y - _cy) * wpu))


## A fractal-space direction turned into a world direction, without the zoom: the orbit
## trace draws at its own fixed scale but keeps the map's orientation.
func fractal_dir_to_world(v: Vector2) -> Vector2:
	return _m.basis_xform_inv(v)


## Walk: move the viewer over the fractal by a world-space distance (metres, xz).
func pan(delta_m: Vector2) -> void:
	var d := _m.basis_xform(delta_m) / wpu
	_cx += d.x
	_cy += d.y


## Turn the world by `a` radians about the viewer. The mapping is fractal = centre +
## M w / wpu; for the world point that lands where p was to keep p's value, M' = M R(-a)
## and centre moves so the head stays on the same fractal point.
func rotate_about_head(a: float) -> void:
	var m2 := _m * Transform2D(-a, Vector2.ZERO)
	var d := (_m.basis_xform(_head_xz) - m2.basis_xform(_head_xz)) / wpu
	_cx += d.x
	_cy += d.y
	_m = m2


## Scale about the point under the viewer, so the ground at your feet stays put.
func zoom(factor: float) -> void:
	var vx := viewer_fx()
	var vy := viewer_fy()
	var lo := WPU_BASE * pow(2.0, float(STAGE_MIN))
	var hi := WPU_BASE * pow(2.0, float(STAGE_MAX + 1)) * 0.999
	wpu = clampf(wpu * factor, lo, hi)
	set_viewer_fractal(vx, vy)
	_sync_stage()


## Scale about the world point p (xz, metres), so the ground there stays put: a trip
## grows its minibrot in place in front of you rather than about your feet.
func zoom_about(p: Vector2, factor: float) -> void:
	var f := world_to_fractal64(p)
	var lo := WPU_BASE * pow(2.0, float(STAGE_MIN))
	var hi := WPU_BASE * pow(2.0, float(STAGE_MAX + 1)) * 0.999
	wpu = clampf(wpu * factor, lo, hi)
	var o := _m.basis_xform(p) / wpu
	_cx = f[0] - o.x
	_cy = f[1] - o.y
	_sync_stage()


## Put the fractal point (x, y) under the viewer's head. Takes two floats rather than a
## Vector2 so a caller holding 64-bit coordinates keeps them.
func set_viewer_fractal(x: float, y: float) -> void:
	var o := _m.basis_xform(_head_xz) / wpu
	_cx = x - o.x
	_cy = y - o.y


## Zoom factor relative to WPU_BASE, for the status line. A family whose home sits deeper
## (HOMES z) opens at more than 1x.
func zoom_factor() -> float:
	return wpu / WPU_BASE


## Back to the current family's HOMES entry, the head over its point, facing as it opens.
func home() -> void:
	iter_hint = 0
	clear_reference_nucleus()
	var h: Vector3 = HOMES[formula]
	wpu = h.z
	_m = Transform2D.IDENTITY
	_glide = Vector2.ZERO
	_cx = h.x - _head_xz.x / wpu
	_cy = h.y - _head_xz.y / wpu
	_level_set = false
	_stand_set = false
	_stand_chasing = false
	_sync_stage()


## Drop what is left of a glide. The host calls it while something above the world owns input:
## a trip that carried on under the dash or the card moved the viewer with no hand in it.
func stop_glide() -> void:
	_glide = Vector2.ZERO


## Glide so that the world point `target_xz` ends up under the viewer (at the sphere's nadir
## in sphere mode, scaled by sphere_pan_scale() so bowl glides cover real surface metres).
## Eased over about a second; a new target replaces the old.
func glide_to(target_xz: Vector2) -> void:
	var sc := sphere_pan_scale()
	var from := _stand_xz if sphere_radius > 0.0 else _head_xz
	_glide = (target_xz - from).limit_length(GLIDE_MAX_M * sc)


## 0..1 fill progress of the work queued since the queue was last empty.
func progress() -> float:
	var p := pending_texels()
	if p == 0:
		_pending_peak = 0
		return 1.0
	_pending_peak = maxi(_pending_peak, p)
	return 1.0 - float(p) / float(maxi(1, _pending_peak))


## Level size, live. Frees and rebuilds the stack; everything recomputes. Render thread.
func set_quality(n: int) -> void:
	if n == n_tex or not _ready_ok:
		return
	# ground.gdshader wraps texel indices with a mask, which is only a modulo for a power of two.
	if n <= 0 or n & (n - 1) != 0:
		push_error("FractalGround.set_quality: %d is not a power of two" % n)
		return
	n_tex = n
	_texture.texture_rd_rid = RID()
	if _tex.is_valid():
		_rd.free_rid(_tex)   # the uniform set is its dependent
	_tex = _rd.texture_create(level_format(n_tex, LEVELS), RDTextureView.new(), [])
	_texture.texture_rd_rid = _tex
	_material.set_shader_parameter("levels", _texture)
	_material.set_shader_parameter("tex_size", n_tex)
	var img := RDUniform.new()
	img.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	img.binding = 0
	img.add_id(_tex)
	_set = _rd.uniform_set_create([img], _shader, 0)
	_set_pert = [_pert_set(img, 0), _pert_set(img, 1)]
	# A new texture holds nothing yet, not even an old picture to refill in place.
	for i in LEVELS:
		_have[i] = false


func set_julia(on: bool) -> void:
	if on == julia:
		return
	julia = on
	invalidate()


## Every tile in every level is wrong the moment this changes, so it is a full rebuild. A new
## family opens at its own home: the old spot is a blank plain for most of them.
func set_formula(i: int) -> void:
	var n := wrapi(i, 0, FORMULA_NAMES.size())
	if n == formula:
		return
	formula = n
	invalidate()
	home()


func formula_name() -> String:
	return FORMULA_NAMES[formula]


## Julia set seeded from the point you are standing on: the classic pairing.
func julia_here() -> void:
	_jx = viewer_fx()
	_jy = viewer_fy()
	julia = true
	invalidate()


func set_max_iter(n: int) -> void:
	if n == max_iter:
		return
	max_iter = n
	if effective_iter() != _iter_used:
		_iter_used = effective_iter()
		refresh()


## The fewest iterations the fill runs at this depth, whatever ITER says. Deep spots need
## more: measured with a 64-bit escape count at 48x48 texels around four classic spots,
## the seahorse valley needs 2048 or more past stage 11 before 95% of what escapes by
## 16384 is shown escaping, and at 256 the whole floor there is "inside" and black from
## stage 16. Other spots need 256-512 at any depth, so this is a floor and not a rule:
## one doubling every three stages from stage 10, capped at ITER's top rung. Stepping
## across one rebuilds the stack, as changing ITER does; shallower than stage 10 nothing
## changes.
func iter_floor() -> int:
	# Depth, not the clipmap's stage: GLOBE runs the clipmap coarser at the same zoom.
	if not auto_iter or _zoom_stage < 10:
		return 0
	return mini(4096, 512 << ((_zoom_stage - 10) / 3))


## NEAR: the per-pixel escape budget for the shader's near field (ground.gdshader), 0 off.
## Where a texel spans several pixels near the set, the fragment iterates its own point.
const NEAR_STEPS := [0, 128, 256, 512]
## Off by default: at 256 GROUND ran 9-12 fps on the Quest (2026-11-17, before the edge
## budget fix and the two-pixel gate). Measure before turning it on by default.
var near_iter := 0


func _set_near(vx: float, vy: float) -> void:
	# Stereographic stretching on the sphere makes texels coarser than pixels over most of the
	# wall, which would trigger per-pixel escape almost everywhere; force NEAR off there.
	var eff_near := 0 if sphere_radius > 0.0 else near_iter
	_material.set_shader_parameter("near_iter", eff_near)
	# The globe works the escape past its data with the same uniforms (ground.gdshader).
	if eff_near <= 0 and not sphere_globe:
		return
	var f := PackedFloat32Array([vx, vy])
	_material.set_shader_parameter("near_c", Vector4(f[0], vx - f[0], f[1], vy - f[1]))
	_material.set_shader_parameter("near_formula", formula)
	_material.set_shader_parameter("near_julia", 1 if julia else 0)
	_material.set_shader_parameter("near_julia_c", Vector2(_jx, _jy))
	_material.set_shader_parameter("near_max_iter", effective_iter())
	_material.set_shader_parameter("near_tex_on", 1.0 if texture_on else 0.0)
	_material.set_shader_parameter("near_stalk", stalk)
	_material.set_shader_parameter("near_stalk_width", stalk_width)


func effective_iter() -> int:
	return maxi(maxi(max_iter, iter_floor()), iter_hint)


func set_texture_on(on: bool) -> void:
	if on == texture_on:
		return
	texture_on = on
	invalidate()


## Every level needs recomputing: a different set or texture channel, or a new texture.
## The fine levels drop out at once and come back coarse to fine as they fill; the coarsest
## keeps its old picture and is refilled in place, so the floor always shows something
## that belongs where it is drawn. With nothing to keep (a new texture, or a level still
## being built) the coarsest is rebuilt too and the floor fogs over until it lands, rather
## than drawing whatever the slots held before.
func invalidate() -> void:
	for i in LEVELS - 1:
		_have[i] = false
	var top := LEVELS - 1
	if _have[top] and not _full[top]:
		_refresh[top] = [_window(top)] as Array[Rect2i]
	else:
		_have[top] = false


## Same place, more iterations: every texel is still the right point, only its count is
## short. Refill in place, coarsest first, with the old picture up until each texel lands.
## A rebuild here (what this used to be) dropped the floor to the coarsest level, half a
## metre a texel, every time a zoom crossed one of iter_floor()'s steps.
func refresh() -> void:
	for i in LEVELS:
		if _have[i] and not _full[i]:
			_refresh[i] = [_window(i)] as Array[Rect2i]


func _window(i: int) -> Rect2i:
	return Rect2i(_win_lo[i], Vector2i(n_tex, n_tex))


func _sync_stage() -> void:
	_zoom_stage = clampi(int(floor(log(wpu / WPU_BASE) / log(2.0))), STAGE_MIN, STAGE_MAX)
	var want := clampi(_zoom_stage - _stage_bias, STAGE_MIN, STAGE_MAX)
	while _stage < want:
		_shift_in()
	while _stage > want:
		_shift_out()
	if _material != null:
		# The clipmap's level-0 texel against the zoom's own: 1 off the globe, 1/4 on it, and
		# less than that bias at the widest zoom, where STAGE_MIN stops the clipmap going coarser.
		_material.set_shader_parameter(&"relief_unit", pow(2.0, float(_stage - _zoom_stage)))


## Zoomed in past 2x: level i becomes level i+1 (same texel size, same absolute grid, so
## its data is still right), the old coarsest layer is reused for a new finest level.
func _shift_in() -> void:
	_stage += 1
	# The anchor is the same fractal point, and a level-0 texel just halved.
	_ax *= 2
	_ay *= 2
	_rot = (_rot - 1 + LEVELS) % LEVELS
	for i in range(LEVELS - 1, 0, -1):
		_win_lo[i] = _win_lo[i - 1]
		_have[i] = _have[i - 1]
		_full[i] = _full[i - 1]
		_dirty[i] = _dirty[i - 1]
		_refresh[i] = _refresh[i - 1]
	_have[0] = false
	_full[0] = true
	_dirty[0] = [] as Array[Rect2i]
	_refresh[0] = [] as Array[Rect2i]


func _shift_out() -> void:
	_stage -= 1
	_rot = (_rot + 1) % LEVELS
	for i in range(0, LEVELS - 1):
		_win_lo[i] = _win_lo[i + 1]
		_have[i] = _have[i + 1]
		_full[i] = _full[i + 1]
		_dirty[i] = _dirty[i + 1]
		_refresh[i] = _refresh[i + 1]
	_have[LEVELS - 1] = false
	_full[LEVELS - 1] = true
	_dirty[LEVELS - 1] = [] as Array[Rect2i]
	_refresh[LEVELS - 1] = [] as Array[Rect2i]
	# Halving keeps the anchor on the same point but only a multiple of ANCHOR_Q / 2, so
	# snap it back, after the levels have moved: _set_anchor shifts level i by the new
	# stage's texels. Done before the move, it shifted each window by half what it should,
	# and every zoom-out step rebuilt the whole stack (tools/orbit_check.sh DEEPCHECK).
	_ax /= 2
	_ay /= 2
	_set_anchor(_ax - posmod(_ax, ANCHOR_Q), _ay - posmod(_ay, ANCHOR_Q))


# --- per frame --------------------------------------------------------------------

## Called by the host every frame while the ground is showing. head_xz is the viewer's
## world position on the plane; eye_y is the eyes' height in metres (sphere mode anchors the
## lower hemisphere's centre near it, so the equator sits on the horizon).
func update(head_xz: Vector2, delta: float = 0.0, eye_y: float = 1.6) -> void:
	if not _ready_ok:
		return
	if sun_orbit and sun_applies and delta > 0.0 and _material != null:
		_sun_angle = fposmod(_sun_angle + delta * SUN_ORBIT_RAD_S, TAU)
		var r := Vector2(DEFAULT_LIGHT_DIR.x, DEFAULT_LIGHT_DIR.z).length()
		_material.set_shader_parameter(&"light_dir",
			Vector3(cos(_sun_angle) * r, DEFAULT_LIGHT_DIR.y, sin(_sun_angle) * r))
	_head_xz = head_xz
	_eye_y = eye_y
	if sphere_radius > 0.0:
		if not _stand_set or delta <= 0.0:
			_stand_xz = head_xz
			_sphere_cy = eye_y
			_stand_set = true
			_stand_chasing = false
			_cy_chasing = false
		else:
			var ease := 1.0 - exp(-delta * 4.0)
			if (head_xz - _stand_xz).length() > STAND_HOLD_M:
				_stand_chasing = true
			if _stand_chasing:
				_stand_xz = _stand_xz.lerp(head_xz, ease)
				if (head_xz - _stand_xz).length() < STAND_SETTLE_M:
					_stand_chasing = false
			if absf(eye_y - _sphere_cy) > STAND_HOLD_Y_M:
				_cy_chasing = true
			if _cy_chasing:
				_sphere_cy = lerpf(_sphere_cy, eye_y, ease)
				if absf(eye_y - _sphere_cy) < STAND_SETTLE_Y_M:
					_cy_chasing = false
		# The mesh is centred under the sphere's centre, not the eye (see STAND_HOLD_M).
		_mesh_instance.position = Vector3(_stand_xz.x, 0.0, _stand_xz.y)
		_stand.position = Vector3(_stand_xz.x, 0.002, _stand_xz.y)
		# The bowl's wall crosses the real floor sqrt(R^2 - cy^2) out (1.2 m at a 1.6 m eye
		# height); a taller eye pulls that in, so the disc shrinks to stay inside the wall
		# rather than slip behind it.
		var cross := sqrt(maxf(0.0, sphere_radius * sphere_radius - _sphere_cy * _sphere_cy))
		var fit := clampf(cross * 0.9 / STAND_RADIUS, 0.0, 1.0)
		_stand.scale = Vector3(fit, 1.0, fit) if fit > 0.05 else Vector3.ONE
		_stand_fits = fit > 0.05
	else:
		# The mesh is finest at its centre; keep that under the viewer.
		_mesh_instance.position = Vector3(head_xz.x, 0.0, head_xz.y)
	_sky.position.x = head_xz.x
	_sky.position.z = head_xz.y
	_stand.visible = sphere_radius > 0.0 and not _stand_passthrough and _stand_fits
	glide_mps = 0.0
	var pan_sc := sphere_pan_scale()
	if _glide.length() > 0.02 * pan_sc and delta > 0.0:
		var f := 1.0 - exp(-delta * 3.5)
		var step := (_glide * f).limit_length(GLIDE_MAX_MPS * pan_sc * delta)
		pan(step)
		_glide -= step
		glide_mps = (step.length() / pan_sc) / delta
	else:
		_glide = Vector2.ZERO
	if effective_iter() != _iter_used:
		_iter_used = effective_iter()
		refresh()
	var vx := viewer_fx()
	var vy := viewer_fy()
	var t0 := _texel0()
	var vt0 := track_windows()

	# The floor reference drifts after the viewer with a two-second time constant, so
	# stepping over a terrace eases the ground down instead of dropping it, and it ignores
	# the small circles a turning head draws; see REF_HOLD_M. Fractal units times wpu is
	# metres, because _m is a pure rotation.
	if not _level_set or delta <= 0.0:
		_lfx = vx
		_lfy = vy
		_level_set = true
		_level_chasing = false
	else:
		var gap_m := Vector2(vx - _lfx, vy - _lfy).length() * wpu
		if gap_m > REF_HOLD_M:
			_level_chasing = true
		if _level_chasing:
			var k := 1.0 - exp(-delta / 2.0)
			_lfx += (vx - _lfx) * k
			_lfy += (vy - _lfy) * k
			if Vector2(vx - _lfx, vy - _lfy).length() * wpu < REF_SETTLE_M:
				_level_chasing = false

	var frac := Vector2(vx / t0 - float(vt0.x + _ax), vy / t0 - float(vt0.y + _ay))
	# What the shader may read: per level, the part of the window with nothing queued, as
	# texels from the viewer's. Taken before this frame's fill, so a rect that lands now is
	# used from the next frame: a frame late, never a frame early.
	var min_level := -1
	var max_level := -1
	for i in LEVELS:
		var vt := Vector2i(vt0.x >> i, vt0.y >> i)
		var c := _clean_rect(i, vt)
		if c.has_area():
			_clean[i] = Vector4(c.position.x - vt.x, c.position.y - vt.y, c.end.x - vt.x, c.end.y - vt.y)
			if min_level < 0:
				min_level = i
			max_level = i
		else:
			_clean[i] = Vector4.ZERO
	if min_level < 0:
		# Nothing usable anywhere: the shader finds the coarsest level empty too, and fogs.
		min_level = LEVELS - 1
		max_level = LEVELS - 1
	_material.set_shader_parameter("clean_rect", _clean)
	if sphere_globe:
		_tick_globe_cap(max_level, delta)
	_material.set_shader_parameter("texel0", t0)
	_material.set_shader_parameter("wpu", wpu)
	_material.set_shader_parameter("head_xz", head_xz)
	_material.set_shader_parameter("rot", Vector4(_m.x.x, _m.x.y, _m.y.x, _m.y.y))
	_material.set_shader_parameter("view_texel0", vt0)
	_material.set_shader_parameter("view_frac0", frac)
	_material.set_shader_parameter("level_e0", Vector2((_lfx - vx) / t0, (_lfy - vy) / t0))
	_material.set_shader_parameter("ref_hold", REF_HOLD_M)
	_material.set_shader_parameter("level_rot", _rot)
	_material.set_shader_parameter("min_level", min_level)
	_material.set_shader_parameter("max_level", max_level)
	_material.set_shader_parameter("fog_end",
		float(n_tex / 2 - SLACK - 2) * _texel(LEVELS - 1) * wpu)
	_material.set_shader_parameter(&"sphere_centre_y", _sphere_cy)
	_material.set_shader_parameter(&"sphere_off",
		_stand_xz - head_xz if sphere_radius > 0.0 else Vector2.ZERO)
	_set_near(vx, vy)
	_keep_reference(vx, vy)
	RenderingServer.call_on_render_thread(_flush)


## Re-anchor if the viewer has wandered far enough, then keep every level's window on the
## viewer. Returns the viewer's level-0 texel from the anchor. The viewer's absolute
## index is worked out once, in 64-bit ints, and every level's follows from it by a
## shift, so the levels agree about where the viewer is to the texel.
func track_windows() -> Vector2i:
	var t0 := _texel0()
	var ix := int(floor(viewer_fx() / t0))
	var iy := int(floor(viewer_fy() / t0))
	if absi(ix - _ax) > ANCHOR_REBASE or absi(iy - _ay) > ANCHOR_REBASE:
		_set_anchor(ix - posmod(ix, ANCHOR_Q), iy - posmod(iy, ANCHOR_Q))
	var vt0 := Vector2i(ix - _ax, iy - _ay)
	for i in LEVELS:
		_track_window(i, vt0)
	return vt0


## Move the anchor to level-0 index (nx, ny), both multiples of ANCHOR_Q (or of half of
## it, in _shift_out's case), and re-label every stored window and queued rect to count
## from it. The move is a multiple of n_tex at every level, so no texel changes slot.
func _set_anchor(nx: int, ny: int) -> void:
	var dx := nx - _ax
	var dy := ny - _ay
	if dx == 0 and dy == 0:
		return
	for i in LEVELS:
		var sh := Vector2i(dx / (1 << i), dy / (1 << i))
		_win_lo[i] -= sh
		for q: Array in [_dirty, _refresh]:
			var rects: Array[Rect2i] = q[i]
			for k in rects.size():
				rects[k] = Rect2i(rects[k].position - sh, rects[k].size)
	_ax = nx
	_ay = ny


## Keep level i's window centred within RECENTRE texels of the viewer and queue whatever
## strip the move uncovered. A window that does not exist yet is queued whole. vt0 is
## the viewer's level-0 texel from the anchor.
func _track_window(i: int, vt0: Vector2i) -> void:
	var vt := Vector2i(vt0.x >> i, vt0.y >> i)
	var want := vt - Vector2i(n_tex / 2, n_tex / 2)
	if not _have[i]:
		_win_lo[i] = want
		_have[i] = true
		_full[i] = true
		_dirty[i] = [Rect2i(want, Vector2i(n_tex, n_tex))] as Array[Rect2i]
		_refresh[i] = [] as Array[Rect2i]
		if on_queue.is_valid(): on_queue.call(i, _dirty[i][0])
		return
	var d := want - _win_lo[i]
	if absi(d.x) <= RECENTRE and absi(d.y) <= RECENTRE:
		return
	var old := _win_lo[i]
	if absi(d.x) >= n_tex or absi(d.y) >= n_tex:
		_win_lo[i] = want
		_full[i] = true
		_dirty[i] = [Rect2i(want, Vector2i(n_tex, n_tex))] as Array[Rect2i]
		_refresh[i] = [] as Array[Rect2i]
		if on_queue.is_valid(): on_queue.call(i, _dirty[i][0])
		return
	# Whatever is still queued from earlier moves only matters inside the new window. Past
	# its edge a rect's slots now belong to the new strip, and since the fill no longer
	# runs strictly in queue order, filling it after that strip would write the far side's
	# texels over the near side's.
	var win := Rect2i(want, Vector2i(n_tex, n_tex))
	_clip(_dirty, i, win)
	_clip(_refresh, i, win)
	var rects: Array[Rect2i] = _dirty[i]
	if d.x != 0:
		var x0 := old.x + n_tex if d.x > 0 else want.x
		rects.append(Rect2i(Vector2i(x0, want.y), Vector2i(absi(d.x), n_tex)))
		if on_queue.is_valid(): on_queue.call(i, rects[-1])
	if d.y != 0:
		var y0 := old.y + n_tex if d.y > 0 else want.y
		var xa := maxi(old.x, want.x)
		var xb := mini(old.x, want.x) + n_tex
		if xb > xa:
			rects.append(Rect2i(Vector2i(xa, y0), Vector2i(xb - xa, absi(d.y))))
			if on_queue.is_valid(): on_queue.call(i, rects[-1])
	_dirty[i] = rects
	_win_lo[i] = want


func _clip(q: Array, i: int, win: Rect2i) -> void:
	var out: Array[Rect2i] = []
	for r: Rect2i in q[i]:
		var c := r.intersection(win)
		if c.has_area():
			out.append(c)
	q[i] = out


## The largest rectangle of level i's window with nothing in _dirty, around the viewer's
## texel vt. Each queued rect it overlaps is cut off along whichever side leaves the viewer
## the most reach (the least of the four distances to the edge, which is what the shader's
## square reach test spends). Empty when a queued rect covers the viewer.
func _clean_rect(i: int, vt: Vector2i) -> Rect2i:
	if not _have[i] or _full[i]:
		return Rect2i()
	var c := _window(i)
	for r: Rect2i in _dirty[i]:
		if not r.intersects(c):
			continue
		var best := Rect2i()
		var reach := -1
		for cand: Rect2i in [
				Rect2i(c.position, Vector2i(r.position.x - c.position.x, c.size.y)),
				Rect2i(Vector2i(r.end.x, c.position.y), Vector2i(c.end.x - r.end.x, c.size.y)),
				Rect2i(c.position, Vector2i(c.size.x, r.position.y - c.position.y)),
				Rect2i(Vector2i(c.position.x, r.end.y), Vector2i(c.size.x, c.end.y - r.end.y))]:
			if not cand.has_area() or not cand.has_point(vt):
				continue
			var m := mini(mini(vt.x - cand.position.x, cand.end.x - 1 - vt.x),
				mini(vt.y - cand.position.y, cand.end.y - 1 - vt.y))
			if m > reach:
				reach = m
				best = cand
		if reach < 0:
			return Rect2i()
		c = best
	return c


const PC_SIZE := 96


## Fractal coordinate of a level's texel centre, in 64-bit floats. The texel grid is
## anchored at the fractal origin; `a` counts from the anchor, which sits on that grid at
## every level.
func _texel_centre(level: int, a: Vector2i) -> Array[float]:
	var t := _texel(level)
	var t0 := _texel0()
	return [float(_ax) * t0 + (float(a.x) + 0.5) * t, float(_ay) * t0 + (float(a.y) + 0.5) * t]


## Whether a rect's coordinates need df32: the largest coordinate magnitude it touches
## (never below 1, see DF_RATIO) over its texel size.
func _is_deep(level: int, r: Rect2i) -> bool:
	var t := _texel(level)
	var o := _texel_centre(level, r.position)
	var m := maxf(1.0, maxf(maxf(absf(o[0]), absf(o[0] + float(r.size.x) * t)),
		maxf(absf(o[1]), absf(o[1] + float(r.size.y) * t))))
	if julia:
		m = maxf(m, sqrt(_jx * _jx + _jy * _jy))
	return m / t > DF_RATIO


## Write x as a float32 pair hi + lo at two offsets: hi is x rounded to float32, lo the
## rest rounded again, which keeps about 48 of the double's 53 bits.
static func _encode_df(pc: PackedByteArray, off_hi: int, off_lo: int, x: float) -> void:
	pc.encode_float(off_hi, x)
	pc.encode_float(off_lo, x - pc.decode_float(off_hi))


func _push_constant(level: int, r: Rect2i, slot := -1) -> PackedByteArray:
	var o := _texel_centre(level, r.position)
	if slot >= 0:
		var c: Array = _ref_cur[slot]
		return push_constant_at(level, r, o[0] - c[0], o[1] - c[1], c[2])
	return push_constant_at(level, r, o[0], o[1])


## The dispatch push constant with the fractal origin given directly. tools/ground_check.gd
## uses this to fill a rect anywhere at any depth through the real encoding.
## For the PERT variant (ox, oy) is the offset from the reference point and ref_len the
## reference orbit's last index.
func push_constant_at(level: int, r: Rect2i, ox: float, oy: float, ref_len := 0) -> PackedByteArray:
	var pc := PackedByteArray()
	pc.resize(PC_SIZE)
	pc.encode_s32(0, r.position.x)
	pc.encode_s32(4, r.position.y)
	pc.encode_s32(8, r.size.x)
	pc.encode_s32(12, r.size.y)
	_encode_df(pc, 16, 80, _jx)
	_encode_df(pc, 20, 84, _jy)
	_encode_df(pc, 24, 60, _texel(level))
	pc.encode_s32(28, (level + _rot) % LEVELS)
	pc.encode_s32(32, n_tex)
	pc.encode_s32(36, effective_iter())
	pc.encode_s32(40, 1 if julia else 0)
	pc.encode_float(44, 1.0 if texture_on else 0.0)
	pc.encode_float(48, stalk)
	pc.encode_float(52, stalk_width)
	pc.encode_s32(56, formula)
	_encode_df(pc, 64, 68, ox)
	_encode_df(pc, 72, 76, oy)
	pc.encode_s32(88, ref_len)
	return pc


## Spend this frame's texel budget: every hole in _dirty before any refresh, each coarsest
## level first so a rebuild shows a blurry whole before a sharp corner and a fine level's
## strip always has a filled coarser level for the shader to fall back on. Render thread.
func _flush() -> void:
	_read_timestamp()
	# Adapt the budget to what the last fill actually cost. Only once a timestamp has ever
	# come back: Metal returns none, ground_us sat at 0, and "cost nothing" grew the budget
	# to BUDGET_MAX, 2M texels a frame. With df32 at 37x that stalled the desktop GPU long
	# enough to drop fences and fill tiles with garbage. No reading holds the budget where
	# it started instead.
	if _worked and _timed:
		# Timestamps lag the dispatch by a frame or two, so the df charge only moves once
		# several fills in a row were pure df and the measurement must be one of them.
		var df_only := _df_run >= 3
		if ground_us > TARGET_US * 1.3:
			if df_only and _budget <= BUDGET_MIN:
				_df_cost = minf(DF_COST_MAX, _df_cost * 1.33)
			_budget = maxf(BUDGET_MIN, _budget * 0.75)
		elif ground_us < TARGET_US * 0.6:
			if df_only and _df_cost > DF_COST:
				_df_cost = maxf(DF_COST, _df_cost * 0.87)
			else:
				_budget = minf(BUDGET_MAX, _budget * 1.15)
	if _ref_drop1:
		_ref_cur[1] = []
		_ref_drop1 = false
	for s in 2:
		var nx: Array = _ref_next1 if s == 1 else _ref_next0
		if nx.is_empty():
			continue
		var data: PackedFloat32Array = nx[3]
		_rd.buffer_update(_ref_buf[s], 0, data.size() * 4, data.to_byte_array())
		_ref_cur[s] = [nx[0], nx[1], nx[2]]
		if s == 1:
			_ref_next1 = []
		else:
			_ref_next0 = []
	_worked = false
	_any_f32 = false
	_any_df = false
	_cl = -1
	_bound = -1
	# The budget is in texels at 256 iterations; deeper counts get proportionally fewer
	# texels a frame, so ITER 4096 sharpens over more frames rather than stalling one.
	var left := _budget * 256.0 / float(maxi(1, effective_iter()))
	for i in range(LEVELS - 1, -1, -1):
		left = _spend(_dirty[i], i, left)
		if (_dirty[i] as Array).is_empty():
			_full[i] = false
	for i in range(LEVELS - 1, -1, -1):
		left = _spend(_refresh[i], i, left)
	if _cl >= 0:
		_rd.compute_list_end()
		_rd.capture_timestamp("ground_end")
		_worked = true
	_df_run = _df_run + 1 if (_any_df and not _any_f32) else 0


var _cl := -1
var _bound := -1   # 0 f32, 1 df, 2 + slot pert: which pipeline and set the list has bound
var _n_pert := 0   # texels dispatched on each deep path, ever
var _n_df := 0


## Texels filled by perturbation and by df32 so far: the log and the harnesses take deltas.
func deep_counts() -> Vector2i:
	return Vector2i(_n_pert, _n_df)
var _any_f32 := false
var _any_df := false


## Dispatch from the front of one level's queue until it is empty or `left` runs out, and
## return what is left. Edits `rects` in place.
func _spend(rects: Array[Rect2i], i: int, left: float) -> float:
	while not rects.is_empty() and left > 0.0:
		var r: Rect2i = rects[0]
		var deep := _is_deep(i, r)
		var slot := _pert_slot(i, r) if deep else -1
		var pert := slot >= 0
		var cost := PERT_COST if pert else (_df_cost if deep else 1.0)
		if pert:
			deep = false   # float32 work: the df32 charge and the thin-strip rule are not for it
		_any_df = _any_df or deep
		_any_f32 = _any_f32 or not deep
		var rows := mini(r.size.y, maxi(1, int(left / (cost * float(maxi(1, r.size.x))))))
		var sub := Rect2i(r.position, Vector2i(r.size.x, rows))
		var split_x := false
		if deep and rows < 16 and r.size.y >= 16:
			# A thin strip wastes most of every 16x16 workgroup, and a df32 budget is
			# often only a few rows of a 1024-wide rect: one row ran a sixteenth of the
			# lanes and measured 5 ms for 1024 texels. Take a 16-row block of the width
			# the budget allows instead, and leave the rest of that strip queued.
			var w := int(left / (cost * 16.0)) / 16 * 16
			sub = Rect2i(r.position, Vector2i(clampi(w, 16, r.size.x), 16))
			split_x = sub.size.x < r.size.x
			rows = 16
		if _cl < 0:
			_cl = _rd.compute_list_begin()
			_rd.capture_timestamp("ground_begin")
		var want := 2 + slot if pert else (1 if deep else 0)
		if want != _bound:
			_rd.compute_list_bind_compute_pipeline(_cl,
				_pipeline_pert if pert else (_pipeline_df if deep else _pipeline))
			_rd.compute_list_bind_uniform_set(_cl, _set_pert[slot] if pert else _set, 0)
			_bound = want
		_rd.compute_list_set_push_constant(_cl, _push_constant(i, sub, slot), PC_SIZE)
		_rd.compute_list_dispatch(_cl, int(ceil(float(sub.size.x) / 16.0)),
			int(ceil(float(sub.size.y) / 16.0)), 1)
		left -= cost * float(sub.size.x * sub.size.y)
		if pert:
			_n_pert += sub.size.x * sub.size.y
		elif deep:
			_n_df += sub.size.x * sub.size.y
		if split_x:
			rects[0] = Rect2i(r.position + Vector2i(sub.size.x, 0), Vector2i(r.size.x - sub.size.x, 16))
			if r.size.y > 16:
				rects.insert(1, Rect2i(r.position + Vector2i(0, 16), Vector2i(r.size.x, r.size.y - 16)))
		elif rows >= r.size.y:
			rects.pop_front()
		else:
			rects[0] = Rect2i(r.position + Vector2i(0, rows), Vector2i(r.size.x, r.size.y - rows))
	return left


## Which reference this rect fills against, or -1 for none (df32 then): a family that
## perturbs, and a reference within REF_RANGE_T0 of the whole rect in this level's texels.
## The nucleus first. Render thread.
func _pert_slot(level: int, r: Rect2i) -> int:
	if not perturb or julia or not formula in PERT_FORMULAS:
		return -1
	var t := _texel(level)
	var o := _texel_centre(level, r.position)
	var x1 := o[0] + float(r.size.x) * t
	var y1 := o[1] + float(r.size.y) * t
	for s: int in [1, 0]:
		var c: Array = _ref_cur[s]
		if c.is_empty():
			continue
		var far := maxf(maxf(absf(o[0] - c[0]), absf(x1 - c[0])), maxf(absf(o[1] - c[1]), absf(y1 - c[1])))
		if far < REF_RANGE_T0 * 1.25 * t:
			return s
	return -1


## Pin a minibrot's nucleus (x, y in 64-bit, period p) as reference slot 1. Its orbit comes
## back to 0 every p steps and never escapes, so every texel round that minibrot follows it
## closely. One period is a few hundred 64-bit steps, cheap enough to build here.
func set_reference_nucleus(x: float, y: float, p: int) -> void:
	if p <= 0 or p >= REF_MAX or (p == _pin_p and x == _pin_x and y == _pin_y):
		return
	_pin_x = x
	_pin_y = y
	_pin_p = p
	var z := reference_orbit(x, y, p)
	_ref_next1 = [x, y, z.size() / 4 - 1, z]


## Forget the pinned nucleus: a new family, home, or a harness comparing without it.
func clear_reference_nucleus() -> void:
	_pin_p = 0
	_ref_next1 = []
	_ref_drop1 = true


## How far from slot 0's reference the viewer may stand, in fractal units: the range less half
## a level-0 window, so everything level 0 holds is still within it.
func _ref_reach() -> float:
	return (REF_RANGE_T0 - float(n_tex / 2)) * _texel0()


## Keep slot 0 serving the viewer, building a new orbit when the viewer walked out of reach
## or a capped orbit is shorter than the count now asked for. Nothing at all while the finest
## level is shallow: no level would use it. Main thread.
func _keep_reference(vx: float, vy: float) -> void:
	if _ref_task >= 0:
		if not WorkerThreadPool.is_task_completed(_ref_task):
			return
		WorkerThreadPool.wait_for_task_completion(_ref_task)
		_ref_task = -1
		var b := _ref_built
		var z: PackedFloat32Array = b[4]
		var m := z.size() / 4 - 1
		# An orbit stopped by the count rather than by escaping is short for a higher count.
		_ref_main = [b[0], b[1], m, b[3] if (b[3] >= 0 and m >= b[2]) else -1]
		_ref_next0 = [b[0], b[1], m, z]
	if not perturb or julia or not formula in PERT_FORMULAS:
		return
	if maxf(1.0, Vector2(vx, vy).length()) / _texel0() <= DF_RATIO:
		return
	var r := _ref_reach()
	var it := mini(effective_iter(), REF_MAX - 1)
	if not _ref_main.is_empty() and absf(float(_ref_main[0]) - vx) < r \
			and absf(float(_ref_main[1]) - vy) < r and (int(_ref_main[3]) < 0 or int(_ref_main[3]) >= it):
		return
	_build_reference(vx, vy, it, it)


## Start iterating slot 0's reference in 64-bit on the WorkerThreadPool; _keep_reference()
## collects it. `cap` is the count an orbit that never escapes was stopped at.
func _build_reference(x: float, y: float, n: int, cap: int) -> void:
	_ref_task = WorkerThreadPool.add_task(func() -> void:
		_ref_built = [x, y, n, cap, FractalGround.reference_orbit(x, y, n)])


## Z_0 .. Z_M of the Mandelbrot z -> z^2 + C from Z_0 = 0, stopping at n steps or one past
## escape. Each Z is four float32s, x hi, y hi, x lo, y lo, the layout ground.glsl's Ref buffer
## reads. Static so tools/ground_check.gd can build the same orbit.
static func reference_orbit(cx: float, cy: float, n: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(4 * (n + 1))
	var zx := 0.0
	var zy := 0.0
	var m := n
	for i in n:
		var nx := zx * zx - zy * zy + cx
		zy = 2.0 * zx * zy + cy
		zx = nx
		var o := 4 * i + 4
		out[o] = zx
		out[o + 1] = zy
		out[o + 2] = zx - out[o]
		out[o + 3] = zy - out[o + 1]
		if zx * zx + zy * zy > 65536.0:
			m = i + 1
			break
	out.resize(4 * (m + 1))
	return out


func _read_timestamp() -> void:
	var n := _rd.get_captured_timestamps_count()
	if n < 2:
		return
	var b := -1.0
	var e := -1.0
	for i in n:
		match _rd.get_captured_timestamp_name(i):
			"ground_begin": b = float(_rd.get_captured_timestamp_gpu_time(i)) / 1000.0
			"ground_end": e = float(_rd.get_captured_timestamp_gpu_time(i)) / 1000.0
	# e == b is what Metal hands back: the names arrive but every GPU time is zero. A fill
	# that ran cannot take no time, so that is no reading, not a free frame.
	if b >= 0.0 and e > b:
		ground_us = e - b
		_timed = true


# --- look ---------------------------------------------------------------------------

const _PAL_NAMES: Array[StringName] = [&"pal0", &"pal1", &"pal2", &"pal3", &"pal4"]


## Height of the mirrored ceiling in metres; 0 turns it off.
func set_sky(height: float) -> void:
	_sky.visible = height > 0.0
	_sky.position.y = height


## Configures sphere mode. A radius of 0 returns to the flat plane, and a positive radius
## bends the radial mesh onto a sphere of `radius` metres round the anchored centre
## (_stand_xz, _sphere_cy), mapping plane radius `horizon_r` to the equator. The bowl stops
## there, with rim fog from `fog_start` of that radius; `globe` carries on over the top and
## runs the clipmap GLOBE_STAGE_BIAS stages coarser. Turning it on centres it on the head.
func set_sphere(radius: float, horizon_r: float, fog_start: float, passthrough_on := false,
		globe := false) -> void:
	var was_on := sphere_radius > 0.0
	sphere_radius = maxf(0.0, radius)
	sphere_horizon_r = maxf(1.0, horizon_r)
	_sphere_fog_start = clampf(fog_start, 0.0, 0.99)
	_stand_passthrough = passthrough_on
	var was_globe := sphere_globe
	sphere_globe = globe and sphere_radius > 0.0
	_stage_bias = GLOBE_STAGE_BIAS if sphere_globe else 0
	_sync_stage()
	if sphere_globe and not was_globe:
		_globe_cap_m = GLOBE_CAP_MIN_M
	if not was_on and sphere_radius > 0.0:
		_stand_xz = _head_xz
		_sphere_cy = _eye_y
		_stand_set = false
		_stand_chasing = false
		_cy_chasing = false
	_stand.visible = sphere_radius > 0.0 and not _stand_passthrough
	if _material != null:
		_material.set_shader_parameter(&"sphere_radius", sphere_radius)
		_material.set_shader_parameter(&"sphere_horizon_r", sphere_horizon_r)
		_material.set_shader_parameter(&"sphere_fog_start", _sphere_fog_start)
		_material.set_shader_parameter(&"sphere_globe", 1.0 if sphere_globe else 0.0)
		_material.set_shader_parameter(&"sphere_mesh_r", MESH_R_MAX)
		_material.set_shader_parameter(&"globe_cap",
			Vector2(GLOBE_CAP_FADE * _globe_cap_m, _globe_cap_m))
		if sphere_radius > 0.0:
			_material.set_shader_parameter(&"near_iter", 0)
		else:
			_material.set_shader_parameter(&"sphere_off", Vector2.ZERO)
			_material.set_shader_parameter(&"sky_rim_mix", 0.0)


## GLOBE's cap follows the data. The reach is the coarsest clean level's margin round the
## viewer, as ground.gdshader's in_window() measures it (the window less the slack, and 1.5
## texels inside the clean rect), in metres, less the stand's offset from the head. The cap's
## outer edge stays 8% inside it: out to GLOBE_CAP_M, eased over about a third of a second as
## new levels land, and in at once when the reach drops (a new family, a refill).
func _tick_globe_cap(top: int, delta: float) -> void:
	var c: Vector4 = _clean[top]
	var margin := minf(minf(-c.x, -c.y), minf(c.z, c.w)) - 1.5
	margin = minf(margin, float(n_tex / 2 - SLACK - 1) - 1.5)
	var reach := margin * _texel(top) * wpu - (_stand_xz - _head_xz).length()
	var want := clampf(reach * 0.92, GLOBE_CAP_MIN_M, GLOBE_CAP_M)
	if want < _globe_cap_m or delta <= 0.0:
		_globe_cap_m = want
	else:
		_globe_cap_m += (want - _globe_cap_m) * (1.0 - exp(-delta / 0.35))
	_material.set_shader_parameter(&"globe_cap", Vector2(GLOBE_CAP_FADE * _globe_cap_m, _globe_cap_m))


## How far the sphere's rim fades into MANDEL SKY's horizon colour rather than fog_colour, 0..1.
## main.gd passes the sky's fade-in while MANDEL is on show, else 0. The sky's view and data
## reach the material from MandelSky.tick().
func set_sphere_sky_rim(mix_k: float) -> void:
	if _material == null:
		return
	_material.set_shader_parameter(&"sky_rim_mix",
		clampf(mix_k, 0.0, 1.0) if sphere_radius > 0.0 else 0.0)


## Plane metres per sphere surface metre at the nadir (1.0 on the flat floor). Inverse of the
## nadir conformal scale 2 * R / R_H so hand grabs stay 1:1 underfoot and stick walks move at
## surface speed on the bowl instead of 1/11 speed.
func sphere_pan_scale() -> float:
	if sphere_radius <= 0.0:
		return 1.0
	return sphere_horizon_r / (2.0 * sphere_radius)


## Ratio of nadir angular optic flow on the sphere to the flat floor (1.0 on flat), clamped to
## 1.0 so the WALK comfort vignette scales with visual flow rate.
func sphere_flow_scale() -> float:
	if sphere_radius <= 0.0:
		return 1.0
	return clampf(_eye_y / sphere_radius, 0.0, 1.0)


## Where a world ray (origin `o`, direction `dir`) hits the ground as world XZ on the fractal
## plane for trigger glides. The flat floor intersects y = 0. Sphere mode intersects the sphere
## centred at (_stand_xz.x, _sphere_cy, _stand_xz.y) and maps the hit back to the plane by
## stereographic projection from the zenith. In the bowl a hit on the upper half is no hit; on
## the globe every ray from inside hits the floor, up to plane radii in the thousands of
## metres near the zenith (glide_to() caps the trip).
func ray_to_plane(o: Vector3, dir: Vector3) -> Variant:
	if dir.length_squared() < 1e-8:
		return null
	var d := dir.normalized()
	if sphere_radius <= 0.0:
		if d.y > -0.05:
			return null
		var t := -o.y / d.y
		var hit := o + d * t
		return Vector2(hit.x, hit.z)
	var c := Vector3(_stand_xz.x, _sphere_cy, _stand_xz.y)
	var oc := o - c
	var b := oc.dot(d)
	var disc := b * b - (oc.dot(oc) - sphere_radius * sphere_radius)
	if disc < 0.0:
		return null
	var t := -b + sqrt(disc)
	if t <= 0.0:
		return null
	var p := o + d * t
	var s := (p - c) / sphere_radius
	if sphere_globe:
		return _stand_xz + Vector2(s.x, s.z) / maxf(1.0 - s.y, 1e-6) * sphere_horizon_r
	if s.y > 0.0:
		return null
	var u := Vector2(s.x, s.z) / maxf(1.0 - s.y, 1e-3)
	if u.length_squared() > 1.0:
		u = u.normalized()
	return _stand_xz + u * sphere_horizon_r


## Fog's colour: the shader's default, or a STYLE's sky (main.gd _art_sky).
const FOG_COLOUR := Color(0.02, 0.02, 0.04)
## V10: slowly orbiting low sun sweeping relief shadows across the fractal terrain.
## Six minutes a turn: ambient motion runs about four times slower than first instinct (90 s).
const SUN_ORBIT_RAD_S := TAU / 360.0
const DEFAULT_LIGHT_DIR := Vector3(0.5, 0.5, 0.35)
var sun_orbit := false
## Whether ground.gdshader lights by light_dir at all (main.gd _ground_sun_lights()). The orbit
## writes it only then, and holds its angle otherwise.
var sun_applies := true
var _sun_angle := atan2(DEFAULT_LIGHT_DIR.z, DEFAULT_LIGHT_DIR.x)


func set_sun_orbit(on: bool) -> void:
	sun_orbit = on
	if not on and _material != null:
		_sun_angle = atan2(DEFAULT_LIGHT_DIR.z, DEFAULT_LIGHT_DIR.x)
		_material.set_shader_parameter(&"light_dir", DEFAULT_LIGHT_DIR)


func set_fog_colour(c: Color) -> void:
	if _material != null:
		_material.set_shader_parameter(&"fog_colour", Vector3(c.r, c.g, c.b))


func set_palette(pal: Array) -> void:
	for i in mini(5, pal.size()):
		_material.set_shader_parameter(_PAL_NAMES[i], pal[i])
	# The filled interior takes its colour from the theme's darkest stop, lifted toward
	# the next one and floored. The old fixed (0.03, 0.02, 0.05) was so close to black
	# that in passthrough the set read as a hole punched in the room rather than as the
	# solid it is, and in the void it merged with the background entirely. It still has
	# to be the darkest thing on the ground, so this only lifts it clear of nothing.
	if pal.size() >= 2:
		var a: Vector3 = pal[0]
		var b: Vector3 = pal[1]
		var c: Vector3 = a.lerp(b, 0.35)
		c = Vector3(maxf(c.x, 0.055), maxf(c.y, 0.06), maxf(c.z, 0.085))
		_material.set_shader_parameter("inside_colour", Color(c.x, c.y, c.z))
		if _stand_mat != null:
			_stand_mat.set_shader_parameter(&"tint", Color(c.x * 0.7, c.y * 0.7, c.z * 0.7))
			if pal.size() >= 4:
				var hi: Vector3 = (pal[3] as Vector3).lerp(Vector3(0.85, 0.90, 0.98), 0.72)
				_stand_mat.set_shader_parameter(&"ring_col", Color(hi.x, hi.y, hi.z))


func set_palette_cycles(n: float) -> void:
	_material.set_shader_parameter("palette_cycles", n)


var _ground_shader: Shader
var _ground_shader_pt: Shader
var _passthrough_discard := false

func set_look(name: StringName, v: Variant) -> void:
	if name == &"inside_passthrough":
		var want := float(v) > 0.5
		if want != _passthrough_discard:
			_passthrough_discard = want
			if _ground_shader == null:
				_ground_shader = _material.shader
			if want:
				if _ground_shader_pt == null:
					var s := Shader.new()
					s.code = _ground_shader.code.replace(
						"\t// PASSTHROUGH_DISCARD",
						"\tif (inside_passthrough > 0.5 && inside > 0.5) discard;\n\t// PASSTHROUGH_DISCARD")
					_ground_shader_pt = s
				_material.shader = _ground_shader_pt
			else:
				_material.shader = _ground_shader
	_material.set_shader_parameter(name, v)


func pending_texels() -> int:
	var total := 0
	for i in LEVELS:
		for r: Rect2i in _dirty[i] + _refresh[i]:
			total += r.size.x * r.size.y
	return total


## The reference task writes into this node, so it must land before the node goes. Here on
## the main thread: from cleanup(), on the render thread at quit, the pool's lock was already
## gone ("recursive_mutex lock failed", an abort on every harness exit).
func _exit_tree() -> void:
	if _ref_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_ref_task)
		_ref_task = -1


func cleanup() -> void:
	if _rd == null:
		return
	_texture.texture_rd_rid = RID()
	for rid: RID in [_tex, _shader, _shader_df, _shader_pert, _ref_buf[0], _ref_buf[1]]:
		if rid.is_valid():
			_rd.free_rid(rid)
	_ready_ok = false
