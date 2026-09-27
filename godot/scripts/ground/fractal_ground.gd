extends Node3D
class_name FractalGround

## The ground viewer: you stand on the fractal and it runs to the horizon.
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
## Deep levels iterate in two-float (df32) arithmetic, gated per dispatch on DF_RATIO so a
## shallow fill costs what it always did. docs/deep-zoom/README.md has why df32 and not
## perturbation.

## Level size. A level is only usable out to about (n/2 - SLACK) of its texels from the
## viewer, and on a ground plane seen at grazing angles that window radius, not the texel
## size, is what limits sharpness in the middle distance. 1024 at 8 bytes a texel is 72MB
## for the stack and a full rebuild of ~9M texels; RENDER doubles it to 2048 (288MB, 36M
## texels) for a still worth waiting for.
var n_tex := 1024
## Nine, because the finest texel is 1.5mm and the horizon still wants ~180m of window.
const LEVELS := 9
## Window is re-centred once the viewer drifts this many texels from its centre. The
## shader treats n_tex/2 - SLACK texels around the viewer as valid, so keep them in step.
const SLACK := 48
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
const TARGET_US := 3500.0
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
var julia_c := Vector2(-0.8, 0.156)
## Which escape-time family the tiles are filled with. ORDER IS LOAD-BEARING: it indexes
## the switch in ground.glsl's iterate(). Append only, and keep the shader in step.
const FORMULA_NAMES := ["mandelbrot", "burning ship", "tricorn", "celtic",
	"perpendicular", "buffalo", "cubic", "quartic"]
var formula := 0
var max_iter := 256
## Raise the iteration count with depth (iter_floor). tools/ground_check.gd turns it off to
## pin the count its CPU reference runs to.
var auto_iter := true
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
var _set: RID
var _tex: RID
var _texture := Texture2DArrayRD.new()
var _mesh_instance: MeshInstance3D
var _sky: MeshInstance3D
var _material: ShaderMaterial
var _stage := 0
var _rot := 0
var _win_lo: Array[Vector2i] = []
var _have: Array[bool] = []
var _full: Array[bool] = []
var _dirty: Array = []            # per level: Array[Rect2i], texels of that level from the anchor
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
	for i in LEVELS:
		_win_lo.append(Vector2i.ZERO)
		_have.append(false)
		_full.append(true)
		_dirty.append([] as Array[Rect2i])
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
	if spirv == null or spirv_df == null:
		_error = "ground.glsl: missing f32/df versions"
		return false
	if spirv.compile_error_compute != "" or spirv_df.compile_error_compute != "":
		_error = "ground.glsl: %s%s" % [spirv.compile_error_compute, spirv_df.compile_error_compute]
		return false
	_shader = _rd.shader_create_from_spirv(spirv)
	_pipeline = _rd.compute_pipeline_create(_shader)
	_shader_df = _rd.shader_create_from_spirv(spirv_df)
	_pipeline_df = _rd.compute_pipeline_create(_shader_df)

	_tex = _rd.texture_create(level_format(n_tex, LEVELS), RDTextureView.new(), [])
	_texture.texture_rd_rid = _tex
	_material.set_shader_parameter("levels", _texture)

	var img := RDUniform.new()
	img.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	img.binding = 0
	img.add_id(_tex)
	_set = _rd.uniform_set_create([img], _shader, 0)
	_ready_ok = true
	return true


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


## Put the fractal point (x, y) under the viewer's head. Takes two floats rather than a
## Vector2 so a caller holding 64-bit coordinates keeps them.
func set_viewer_fractal(x: float, y: float) -> void:
	var o := _m.basis_xform(_head_xz) / wpu
	_cx = x - o.x
	_cy = y - o.y


## Zoom factor relative to the home view, for the status line.
func zoom_factor() -> float:
	return wpu / WPU_BASE


func home() -> void:
	wpu = WPU_BASE
	_m = Transform2D.IDENTITY
	_glide = Vector2.ZERO
	_cx = -0.6 - _head_xz.x / wpu
	_cy = -_head_xz.y / wpu
	_level_set = false
	_sync_stage()


## Glide so that the world point `target_xz` ends up under the viewer. Eased over about
## a second; a new target replaces the old.
func glide_to(target_xz: Vector2) -> void:
	_glide = target_xz - _head_xz


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
	invalidate()


func set_julia(on: bool) -> void:
	if on == julia:
		return
	julia = on
	invalidate()


## Every tile in every level is wrong the moment this changes, so it is a full rebuild.
func set_formula(i: int) -> void:
	var n := wrapi(i, 0, FORMULA_NAMES.size())
	if n == formula:
		return
	formula = n
	invalidate()


func formula_name() -> String:
	return FORMULA_NAMES[formula]


## Julia set seeded from the point you are standing on: the classic pairing.
func julia_here() -> void:
	julia_c = viewer_fractal()
	julia = true
	invalidate()


func set_max_iter(n: int) -> void:
	if n == max_iter:
		return
	max_iter = n
	if effective_iter() != _iter_used:
		_iter_used = effective_iter()
		invalidate()


## The fewest iterations the fill runs at this depth, whatever ITER says. Deep spots need
## more: measured with a 64-bit escape count at 48x48 texels around four classic spots,
## the seahorse valley needs 2048 or more past stage 11 before 95% of what escapes by
## 16384 is shown escaping, and at 256 the whole floor there is "inside" and black from
## stage 16. Other spots need 256-512 at any depth, so this is a floor and not a rule:
## one doubling every three stages from stage 10, capped at ITER's top rung. Stepping
## across one rebuilds the stack, as changing ITER does; shallower than stage 10 nothing
## changes.
func iter_floor() -> int:
	if not auto_iter or _stage < 10:
		return 0
	return mini(4096, 512 << ((_stage - 10) / 3))


func effective_iter() -> int:
	return maxi(max_iter, iter_floor())


func set_texture_on(on: bool) -> void:
	if on == texture_on:
		return
	texture_on = on
	invalidate()


## Every level needs recomputing: a different set, iteration count or texture channel.
## The old picture stays up while the new one fills in, coarse levels first.
func invalidate() -> void:
	for i in LEVELS:
		_have[i] = false


func _sync_stage() -> void:
	var want := clampi(int(floor(log(wpu / WPU_BASE) / log(2.0))), STAGE_MIN, STAGE_MAX)
	while _stage < want:
		_shift_in()
	while _stage > want:
		_shift_out()


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
	_have[0] = false
	_full[0] = true
	_dirty[0] = [] as Array[Rect2i]


func _shift_out() -> void:
	_stage -= 1
	_rot = (_rot + 1) % LEVELS
	for i in range(0, LEVELS - 1):
		_win_lo[i] = _win_lo[i + 1]
		_have[i] = _have[i + 1]
		_full[i] = _full[i + 1]
		_dirty[i] = _dirty[i + 1]
	_have[LEVELS - 1] = false
	_full[LEVELS - 1] = true
	_dirty[LEVELS - 1] = [] as Array[Rect2i]
	# Halving keeps the anchor on the same point but only a multiple of ANCHOR_Q / 2, so
	# snap it back, after the levels have moved: _set_anchor shifts level i by the new
	# stage's texels. Done before the move, it shifted each window by half what it should,
	# and every zoom-out step rebuilt the whole stack (tools/orbit_check.sh DEEPCHECK).
	_ax /= 2
	_ay /= 2
	_set_anchor(_ax - posmod(_ax, ANCHOR_Q), _ay - posmod(_ay, ANCHOR_Q))


# --- per frame --------------------------------------------------------------------

## Called by the host every frame while the ground is showing. head_xz is the viewer's
## world position on the plane.
func update(head_xz: Vector2, delta: float = 0.0) -> void:
	if not _ready_ok:
		return
	_head_xz = head_xz
	# The mesh is finest at its centre; keep that under the viewer.
	_mesh_instance.position = Vector3(head_xz.x, 0.0, head_xz.y)
	_sky.position.x = head_xz.x
	_sky.position.z = head_xz.y
	if _glide.length() > 0.02 and delta > 0.0:
		var f := 1.0 - exp(-delta * 3.5)
		pan(_glide * f)
		_glide *= 1.0 - f
	else:
		_glide = Vector2.ZERO
	if effective_iter() != _iter_used:
		_iter_used = effective_iter()
		invalidate()
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
	var min_level := LEVELS - 1
	for i in LEVELS:
		if not _full[i]:
			min_level = i
			break
	var max_level := 0
	for i in range(LEVELS - 1, -1, -1):
		if not _full[i]:
			max_level = i
			break
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
	_material.set_shader_parameter("max_level", maxi(max_level, min_level))
	_material.set_shader_parameter("fog_end",
		float(n_tex / 2 - SLACK - 2) * _texel(LEVELS - 1) * wpu)
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
		var rects: Array[Rect2i] = _dirty[i]
		for k in rects.size():
			rects[k] = Rect2i(rects[k].position - sh, rects[k].size)
		_dirty[i] = rects
	_ax = nx
	_ay = ny


## Keep level i's window centred within SLACK texels of the viewer and queue whatever
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
		return
	var d := want - _win_lo[i]
	if absi(d.x) <= SLACK and absi(d.y) <= SLACK:
		return
	var old := _win_lo[i]
	if absi(d.x) >= n_tex or absi(d.y) >= n_tex:
		_win_lo[i] = want
		_full[i] = true
		_dirty[i] = [Rect2i(want, Vector2i(n_tex, n_tex))] as Array[Rect2i]
		return
	var rects: Array[Rect2i] = _dirty[i]
	if d.x != 0:
		var x0 := old.x + n_tex if d.x > 0 else want.x
		rects.append(Rect2i(Vector2i(x0, want.y), Vector2i(absi(d.x), n_tex)))
	if d.y != 0:
		var y0 := old.y + n_tex if d.y > 0 else want.y
		var xa := maxi(old.x, want.x)
		var xb := mini(old.x, want.x) + n_tex
		if xb > xa:
			rects.append(Rect2i(Vector2i(xa, y0), Vector2i(xb - xa, absi(d.y))))
	_dirty[i] = rects
	_win_lo[i] = want


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
		m = maxf(m, julia_c.length())
	return m / t > DF_RATIO


## Write x as a float32 pair hi + lo at two offsets: hi is x rounded to float32, lo the
## rest rounded again, which keeps about 48 of the double's 53 bits.
static func _encode_df(pc: PackedByteArray, off_hi: int, off_lo: int, x: float) -> void:
	pc.encode_float(off_hi, x)
	pc.encode_float(off_lo, x - pc.decode_float(off_hi))


func _push_constant(level: int, r: Rect2i) -> PackedByteArray:
	var o := _texel_centre(level, r.position)
	return push_constant_at(level, r, o[0], o[1])


## The dispatch push constant with the fractal origin given directly. tools/ground_check.gd
## uses this to fill a rect anywhere at any depth through the real encoding.
func push_constant_at(level: int, r: Rect2i, ox: float, oy: float) -> PackedByteArray:
	var pc := PackedByteArray()
	pc.resize(PC_SIZE)
	pc.encode_s32(0, r.position.x)
	pc.encode_s32(4, r.position.y)
	pc.encode_s32(8, r.size.x)
	pc.encode_s32(12, r.size.y)
	_encode_df(pc, 16, 80, julia_c.x)
	_encode_df(pc, 20, 84, julia_c.y)
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
	return pc


## Spend this frame's texel budget on the dirty rectangles, coarsest level first so a
## rebuild shows a blurry whole before a sharp corner. Render thread only.
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
	_worked = false
	var any_f32 := false
	var any_df := false
	# The budget is in texels at 256 iterations; deeper counts get proportionally fewer
	# texels a frame, so ITER 4096 sharpens over more frames rather than stalling one.
	var left := _budget * 256.0 / float(maxi(1, effective_iter()))
	var cl := -1
	var bound := -1   # 0 f32, 1 df: which pipeline the list has bound
	for i in range(LEVELS - 1, -1, -1):
		var rects: Array[Rect2i] = _dirty[i]
		while not rects.is_empty() and left > 0.0:
			var r: Rect2i = rects[0]
			var deep := _is_deep(i, r)
			var cost := _df_cost if deep else 1.0
			any_df = any_df or deep
			any_f32 = any_f32 or not deep
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
			if cl < 0:
				cl = _rd.compute_list_begin()
				_rd.capture_timestamp("ground_begin")
			var want := 1 if deep else 0
			if want != bound:
				_rd.compute_list_bind_compute_pipeline(cl, _pipeline_df if deep else _pipeline)
				_rd.compute_list_bind_uniform_set(cl, _set, 0)
				bound = want
			_rd.compute_list_set_push_constant(cl, _push_constant(i, sub), PC_SIZE)
			_rd.compute_list_dispatch(cl, int(ceil(float(sub.size.x) / 16.0)),
				int(ceil(float(sub.size.y) / 16.0)), 1)
			left -= cost * float(sub.size.x * sub.size.y)
			if split_x:
				rects[0] = Rect2i(r.position + Vector2i(sub.size.x, 0), Vector2i(r.size.x - sub.size.x, 16))
				if r.size.y > 16:
					rects.insert(1, Rect2i(r.position + Vector2i(0, 16), Vector2i(r.size.x, r.size.y - 16)))
			elif rows >= r.size.y:
				rects.pop_front()
			else:
				rects[0] = Rect2i(r.position + Vector2i(0, rows), Vector2i(r.size.x, r.size.y - rows))
		_dirty[i] = rects
		if rects.is_empty():
			_full[i] = false
	if cl >= 0:
		_rd.compute_list_end()
		_rd.capture_timestamp("ground_end")
		_worked = true
	_df_run = _df_run + 1 if (any_df and not any_f32) else 0


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


func set_palette_cycles(n: float) -> void:
	_material.set_shader_parameter("palette_cycles", n)


func set_look(name: StringName, v: Variant) -> void:
	_material.set_shader_parameter(name, v)


func pending_texels() -> int:
	var total := 0
	for i in LEVELS:
		for r: Rect2i in _dirty[i]:
			total += r.size.x * r.size.y
	return total


func cleanup() -> void:
	if _rd == null:
		return
	_texture.texture_rd_rid = RID()
	for rid: RID in [_tex, _shader, _shader_df]:
		if rid.is_valid():
			_rd.free_rid(rid)
	_ready_ok = false
