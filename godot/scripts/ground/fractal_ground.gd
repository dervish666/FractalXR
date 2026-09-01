extends Node3D
class_name FractalGround

## The ground viewer: you stand on the fractal and it runs to the horizon.
##
## A clipmap. LEVELS square textures of N texels, level i with texels twice the size of
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
## Float32 throughout, so useful zoom ends around 1e5. Perturbation is the next step and
## replaces escape() in ground.glsl and nothing else.

## 1024 rather than 512: a level is only usable out to about (N/2 - SLACK) of its texels
## from the viewer, and on a ground plane seen at grazing angles that window is what
## limits sharpness in the middle distance, not the texel size. Half floats keep the
## stack at 64MB.
const N := 1024
const LEVELS := 8
## Window is re-centred once the viewer drifts this many texels from its centre. The
## shader treats N/2 - SLACK texels around the viewer as valid, so keep them in step.
const SLACK := 48
## Finest texel at the viewer's feet, in metres, at a zoom stage boundary (it grows to
## twice this just before the next stage). About two pixels at standing height.
const TEXEL_M := 0.003
## World metres per fractal unit at stage 0: the whole Mandelbrot is ~90m across.
const WPU_BASE := 30.0
const STAGE_MIN := -4
const STAGE_MAX := 13
const BUDGET_MIN := 20000.0
const BUDGET_MAX := 2000000.0
const TARGET_US := 3500.0

## Fractal coordinate under world (0, 0). GDScript floats are 64-bit, so this and the
## texel arithmetic below keep precision the shaders cannot; only small offsets cross.
var centre := Vector2(-0.6, 0.0)
var wpu := WPU_BASE
var julia := false
var julia_c := Vector2(-0.8, 0.156)
var max_iter := 256
var texture_on := true
var stalk := 0.0
var stalk_width := 0.05
## GPU microseconds of the last frame's fill, from timestamps.
var ground_us := 0.0

var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _set: RID
var _tex: RID
var _texture := Texture2DArrayRD.new()
var _mesh_instance: MeshInstance3D
var _material: ShaderMaterial
var _stage := 0
var _rot := 0
var _win_lo: Array[Vector2i] = []
var _have: Array[bool] = []
var _full: Array[bool] = []
var _dirty: Array = []            # per level: Array[Rect2i], absolute texels of that level
var _budget := 150000.0
var _head_xz := Vector2.ZERO
var _ready_ok := false
var _error := ""
var _worked := false


func get_error() -> String:
	return _error


func _init() -> void:
	_material = ShaderMaterial.new()
	_material.shader = load("res://shaders/ground.gdshader")
	var plane := PlaneMesh.new()
	plane.size = Vector2(600.0, 600.0)
	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.name = "Ground"
	_mesh_instance.mesh = plane
	_mesh_instance.material_override = _material
	_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mesh_instance)
	for i in LEVELS:
		_win_lo.append(Vector2i.ZERO)
		_have.append(false)
		_full.append(true)
		_dirty.append([] as Array[Rect2i])
	_material.set_shader_parameter("tex_size", N)
	_material.set_shader_parameter("num_levels", LEVELS)
	_material.set_shader_parameter("slack", float(SLACK))
	visible = false


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
	var spirv := file.get_spirv()
	if spirv.compile_error_compute != "":
		_error = "ground.glsl: %s" % spirv.compile_error_compute
		return false
	_shader = _rd.shader_create_from_spirv(spirv)
	_pipeline = _rd.compute_pipeline_create(_shader)

	var fmt := RDTextureFormat.new()
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY
	fmt.width = N
	fmt.height = N
	fmt.array_layers = LEVELS
	# RGBA16F: smooth count to 1024 with 0.5 resolution (invisible through the log
	# palette), distance stored as its log2 so it never underflows, flag and texture 0..1.
	fmt.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	fmt.usage_bits = (RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT)
	_tex = _rd.texture_create(fmt, RDTextureView.new(), [])
	_texture.texture_rd_rid = _tex
	_material.set_shader_parameter("levels", _texture)

	var img := RDUniform.new()
	img.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	img.binding = 0
	img.add_id(_tex)
	_set = _rd.uniform_set_create([img], _shader, 0)
	_ready_ok = true
	return true


func is_ready() -> bool:
	return _ready_ok


# --- geometry ---------------------------------------------------------------------

func _texel0() -> float:
	return TEXEL_M / WPU_BASE / pow(2.0, float(_stage))


func _texel(level: int) -> float:
	return _texel0() * pow(2.0, float(level))


## Fractal coordinate under the viewer's head.
func viewer_fractal() -> Vector2:
	return centre + _head_xz / wpu


## Move the fractal under the viewer by a world-space distance (metres, xz).
func pan(delta_m: Vector2) -> void:
	centre += delta_m / wpu


## Scale about the point under the viewer, so the ground at your feet stays put.
func zoom(factor: float) -> void:
	var vf := viewer_fractal()
	var lo := WPU_BASE * pow(2.0, float(STAGE_MIN))
	var hi := WPU_BASE * pow(2.0, float(STAGE_MAX + 1)) * 0.999
	wpu = clampf(wpu * factor, lo, hi)
	centre = vf - _head_xz / wpu
	_sync_stage()


func home() -> void:
	wpu = WPU_BASE
	centre = Vector2(-0.6, 0.0) - _head_xz / wpu
	_sync_stage()


func set_julia(on: bool) -> void:
	if on == julia:
		return
	julia = on
	invalidate()


## Julia set seeded from the point you are standing on: the classic pairing.
func julia_here() -> void:
	julia_c = viewer_fractal()
	julia = true
	invalidate()


func set_max_iter(n: int) -> void:
	if n == max_iter:
		return
	max_iter = n
	invalidate()


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


# --- per frame --------------------------------------------------------------------

## Called by the host every frame while the ground is showing. head_xz is the viewer's
## world position on the plane.
func update(head_xz: Vector2) -> void:
	if not _ready_ok:
		return
	_head_xz = head_xz
	var vf := viewer_fractal()
	for i in LEVELS:
		_track_window(i, vf)

	var t0 := _texel0()
	var vt0 := Vector2i(int(floor(vf.x / t0)), int(floor(vf.y / t0)))
	var frac := Vector2(vf.x / t0 - float(vt0.x), vf.y / t0 - float(vt0.y))
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
	_material.set_shader_parameter("view_texel0", vt0)
	_material.set_shader_parameter("view_frac0", frac)
	_material.set_shader_parameter("level_rot", _rot)
	_material.set_shader_parameter("min_level", min_level)
	_material.set_shader_parameter("max_level", maxi(max_level, min_level))
	_material.set_shader_parameter("fog_end",
		float(N / 2 - SLACK - 2) * _texel(LEVELS - 1) * wpu)
	RenderingServer.call_on_render_thread(_flush)


## Keep level i's window centred within SLACK texels of the viewer and queue whatever
## strip the move uncovered. A window that does not exist yet is queued whole.
func _track_window(i: int, vf: Vector2) -> void:
	var t := _texel(i)
	var vt := Vector2i(int(floor(vf.x / t)), int(floor(vf.y / t)))
	var want := vt - Vector2i(N / 2, N / 2)
	if not _have[i]:
		_win_lo[i] = want
		_have[i] = true
		_full[i] = true
		_dirty[i] = [Rect2i(want, Vector2i(N, N))] as Array[Rect2i]
		return
	var d := want - _win_lo[i]
	if absi(d.x) <= SLACK and absi(d.y) <= SLACK:
		return
	var old := _win_lo[i]
	if absi(d.x) >= N or absi(d.y) >= N:
		_win_lo[i] = want
		_full[i] = true
		_dirty[i] = [Rect2i(want, Vector2i(N, N))] as Array[Rect2i]
		return
	var rects: Array[Rect2i] = _dirty[i]
	if d.x != 0:
		var x0 := old.x + N if d.x > 0 else want.x
		rects.append(Rect2i(Vector2i(x0, want.y), Vector2i(absi(d.x), N)))
	if d.y != 0:
		var y0 := old.y + N if d.y > 0 else want.y
		var xa := maxi(old.x, want.x)
		var xb := mini(old.x, want.x) + N
		if xb > xa:
			rects.append(Rect2i(Vector2i(xa, y0), Vector2i(xb - xa, absi(d.y))))
	_dirty[i] = rects
	_win_lo[i] = want


func _push_constant(level: int, r: Rect2i) -> PackedByteArray:
	var pc := PackedByteArray()
	pc.resize(64)
	pc.encode_s32(0, r.position.x)
	pc.encode_s32(4, r.position.y)
	pc.encode_s32(8, r.size.x)
	pc.encode_s32(12, r.size.y)
	pc.encode_float(16, julia_c.x)
	pc.encode_float(20, julia_c.y)
	pc.encode_float(24, _texel(level))
	pc.encode_s32(28, (level + _rot) % LEVELS)
	pc.encode_s32(32, N)
	pc.encode_s32(36, max_iter)
	pc.encode_s32(40, 1 if julia else 0)
	pc.encode_float(44, 1.0 if texture_on else 0.0)
	pc.encode_float(48, stalk)
	pc.encode_float(52, stalk_width)
	pc.encode_float(56, 0.0)
	pc.encode_float(60, 0.0)
	return pc


## Spend this frame's texel budget on the dirty rectangles, coarsest level first so a
## rebuild shows a blurry whole before a sharp corner. Render thread only.
func _flush() -> void:
	_read_timestamp()
	# Adapt the budget to what the last fill actually cost.
	if _worked:
		if ground_us > TARGET_US * 1.3:
			_budget = maxf(BUDGET_MIN, _budget * 0.75)
		elif ground_us < TARGET_US * 0.6:
			_budget = minf(BUDGET_MAX, _budget * 1.15)
	_worked = false
	var left := _budget
	var cl := -1
	for i in range(LEVELS - 1, -1, -1):
		var rects: Array[Rect2i] = _dirty[i]
		while not rects.is_empty() and left > 0.0:
			var r: Rect2i = rects[0]
			var rows := mini(r.size.y, maxi(1, int(left / float(maxi(1, r.size.x)))))
			var sub := Rect2i(r.position, Vector2i(r.size.x, rows))
			if cl < 0:
				cl = _rd.compute_list_begin()
				_rd.compute_list_bind_compute_pipeline(cl, _pipeline)
				_rd.compute_list_bind_uniform_set(cl, _set, 0)
				_rd.capture_timestamp("ground_begin")
			_rd.compute_list_set_push_constant(cl, _push_constant(i, sub), 64)
			_rd.compute_list_dispatch(cl, int(ceil(float(sub.size.x) / 16.0)),
				int(ceil(float(sub.size.y) / 16.0)), 1)
			left -= float(sub.size.x * sub.size.y)
			if rows >= r.size.y:
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
	if b >= 0.0 and e >= b:
		ground_us = e - b


# --- look ---------------------------------------------------------------------------

const _PAL_NAMES: Array[StringName] = [&"pal0", &"pal1", &"pal2", &"pal3", &"pal4"]


func set_palette(pal: Array) -> void:
	for i in mini(5, pal.size()):
		_material.set_shader_parameter(_PAL_NAMES[i], pal[i])


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
	for rid: RID in [_tex, _shader]:
		if rid.is_valid():
			_rd.free_rid(rid)
	_ready_ok = false
