extends RefCounted
class_name FractalCompute

## GPU chaos game on the RenderingDevice compute path.
##
## Three dispatches per frame:
##   1. chaos    N invocations, K iterations each, updates the state image IN PLACE
##                 (the web build needs two ping-ponged RGBA32F targets; compute doesn't)
##   2. splat    N invocations per eye, imageAtomicAdd into a uint accumulator
##   3. resolve  flam3 log-density tone map, fused with the clear for the next frame
##
## Everything runs on the render thread via RenderingServer.call_on_render_thread.

const FIXED_SCALE := 1024.0
const LOCAL_SIZE := 256      # must match layout(local_size_x) in chaos.glsl / splat.glsl
const RESOLVE_TILE := 8      # must match layout(local_size_x/y) in resolve.glsl

var rd: RenderingDevice
## True when driving a standalone RenderingDevice (RenderingServer.create_local_rendering_device).
## Local devices need explicit submit/sync and cannot back a Texture2DRD, but they work headless,
## which is the only way to verify the compute chain without a window.
var is_local := false

var tex_size: int = 1536     # 1536^2 = 2,359,296 particles, matching SIZE in src/main.ts
var eye_res := Vector2i.ZERO
var views: int = 2

# GPU resources
var _state_tex: RID
var _accum_tex: RID
var _out_tex: RID
var _genome_buf: RID

var _chaos_shader: RID
var _chaos_pipeline: RID
var _chaos_set: RID
var _splat_shader: RID
var _splat_pipeline: RID
var _splat_set: RID
var _resolve_shader: RID
var _resolve_pipeline: RID
var _resolve_set: RID

# Texture wrappers handed to the scene materials
var out_texture := Texture2DArrayRD.new()
var state_texture := Texture2DRD.new()

var _ready := false
var _needs_seed := true
var _frame := 0
var _last_error := ""

## Per-stage GPU cost in MICROSECONDS, refreshed each frame from RenderingDevice
## timestamps. Godot reports raw GPU time in nanoseconds.
## Godot's viewport timer does not see compute submitted via call_on_render_thread,
## so without these the compute cost is simply invisible.
var stage_ms := {"chaos": 0.0, "splat": 0.0, "resolve": 0.0, "total": 0.0}
var _timestamps_enabled := true

func get_error() -> String:
	return _last_error

func is_ready() -> bool:
	return _ready

## Build every GPU resource. Must be called on the render thread.
func setup(p_tex_size: int, p_eye_res: Vector2i, p_views: int, p_rd: RenderingDevice = null) -> bool:
	tex_size = p_tex_size
	eye_res = p_eye_res
	views = p_views

	is_local = p_rd != null
	rd = p_rd if is_local else RenderingServer.get_rendering_device()
	if rd == null:
		_last_error = "No RenderingDevice. The Compatibility renderer has none; switch to Mobile or Forward+."
		push_error(_last_error)
		return false

	if not _load_shaders():
		return false

	_genome_buf = rd.storage_buffer_create(Genome.FLOATS * 4, Genome.pack().to_byte_array())
	_create_state()
	_create_targets()
	_build_uniform_sets()

	_ready = true
	print("[fractal] compute ready: %d particles, eye %dx%d, %d views" % [
		tex_size * tex_size, eye_res.x, eye_res.y, views])
	return true

func _load_shaders() -> bool:
	var specs := [
		["res://shaders/chaos.glsl", "_chaos_shader", "_chaos_pipeline"],
		["res://shaders/splat.glsl", "_splat_shader", "_splat_pipeline"],
		["res://shaders/resolve.glsl", "_resolve_shader", "_resolve_pipeline"],
	]
	for s in specs:
		var file: RDShaderFile = load(s[0])
		if file == null:
			_last_error = "Failed to load %s" % s[0]
			push_error(_last_error)
			return false
		var spirv := file.get_spirv()
		var err := spirv.compile_error_compute
		if err != "":
			_last_error = "%s: %s" % [s[0], err]
			push_error(_last_error)
			return false
		var shader := rd.shader_create_from_spirv(spirv)
		if not shader.is_valid():
			_last_error = "shader_create_from_spirv failed for %s" % s[0]
			push_error(_last_error)
			return false
		set(s[1], shader)
		set(s[2], rd.compute_pipeline_create(shader))
	return true

func _create_state() -> void:
	var fmt := RDTextureFormat.new()
	fmt.width = tex_size
	fmt.height = tex_size
	fmt.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	fmt.usage_bits = (RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT)
	_state_tex = rd.texture_create(fmt, RDTextureView.new(), [])
	if not is_local:
		state_texture.texture_rd_rid = _state_tex

## Accumulation + display targets. Separate from _create_state so a headset
## resolution change (foveation, render scale) can rebuild just these.
func _create_targets() -> void:
	# Texture2DArrayRD refuses a 1-layer texture, so always allocate two views' worth
	# even when running flat on the desktop; only `views` of them are ever written.
	var layers := maxi(views, 2)

	var acc := RDTextureFormat.new()
	acc.width = eye_res.x
	acc.height = eye_res.y
	acc.array_layers = layers * 3         # one r32ui layer per colour channel per eye
	acc.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY
	acc.format = RenderingDevice.DATA_FORMAT_R32_UINT
	acc.usage_bits = (RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT)
	_accum_tex = rd.texture_create(acc, RDTextureView.new(), [])
	for layer in layers * 3:
		rd.texture_clear(_accum_tex, Color(0, 0, 0, 0), 0, 1, layer, 1)

	var out := RDTextureFormat.new()
	out.width = eye_res.x
	out.height = eye_res.y
	out.array_layers = layers
	out.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY
	out.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	out.usage_bits = (RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT)
	_out_tex = rd.texture_create(out, RDTextureView.new(), [])
	if not is_local:
		out_texture.texture_rd_rid = _out_tex

func _img(binding: int, tex: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u.binding = binding
	u.add_id(tex)
	return u

func _ssbo(binding: int, buf: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = binding
	u.add_id(buf)
	return u

func _build_uniform_sets() -> void:
	_chaos_set = rd.uniform_set_create(
		[_img(0, _state_tex), _ssbo(1, _genome_buf)], _chaos_shader, 0)
	_splat_set = rd.uniform_set_create(
		[_img(0, _state_tex), _img(1, _accum_tex), _ssbo(2, _genome_buf)], _splat_shader, 0)
	_resolve_set = rd.uniform_set_create(
		[_img(0, _accum_tex), _img(1, _out_tex)], _resolve_shader, 0)

## Eye resolution changed: rebuild the targets and the sets that reference them.
func resize(p_eye_res: Vector2i) -> void:
	if p_eye_res == eye_res or p_eye_res.x <= 0 or p_eye_res.y <= 0:
		return
	eye_res = p_eye_res
	if _accum_tex.is_valid():
		rd.free_rid(_accum_tex)
	if _out_tex.is_valid():
		rd.free_rid(_out_tex)
	_create_targets()
	_build_uniform_sets()
	print("[fractal] targets resized to %dx%d" % [eye_res.x, eye_res.y])

## Force a full reseed on the next dispatch (all particles scattered fresh).
func request_seed() -> void:
	_needs_seed = true

func _pc_chaos(num_t: int, iters: int, count: int, reseed: float, do_seed: bool) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(32)
	b.encode_s32(0, num_t)
	b.encode_s32(4, iters)
	b.encode_s32(8, tex_size)
	b.encode_s32(12, _frame % 16777216)
	b.encode_float(16, reseed)
	b.encode_s32(20, count)
	b.encode_s32(24, 1 if do_seed else 0)
	b.encode_s32(28, 0)
	return b

func _pc_splat(viewproj: Projection, view: int, count: int, stamp: int, brightness: float) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(96)
	var cols := [viewproj.x, viewproj.y, viewproj.z, viewproj.w]
	for c in 4:
		var v: Vector4 = cols[c]
		b.encode_float(c * 16 + 0, v.x)
		b.encode_float(c * 16 + 4, v.y)
		b.encode_float(c * 16 + 8, v.z)
		b.encode_float(c * 16 + 12, v.w)
	b.encode_s32(64, eye_res.x)
	b.encode_s32(68, eye_res.y)
	b.encode_s32(72, view)
	b.encode_s32(76, count)
	b.encode_s32(80, tex_size)
	b.encode_s32(84, stamp)
	b.encode_float(88, brightness)
	b.encode_float(92, 0.0)
	return b

func _pc_resolve() -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(32)
	b.encode_s32(0, eye_res.x)
	b.encode_s32(4, eye_res.y)
	b.encode_s32(8, views)
	b.encode_float(12, Genome.BRIGHTNESS)
	b.encode_float(16, Genome.GAMMA)
	b.encode_float(20, Genome.K2)
	b.encode_float(24, Genome.HIGHLIGHT_DESAT)
	b.encode_float(28, 0.0)
	return b

## One frame. `viewprojs` holds one Projection per eye (already including the cloud's
## model transform). Must be called on the render thread.
func dispatch(viewprojs: Array, count: int, iters: int, reseed: float, stamp: int,
		do_chaos: bool = true, do_splat: bool = true, do_resolve: bool = true) -> void:
	if not _ready:
		return
	_frame += 1
	var groups := int(ceil(float(tex_size * tex_size) / float(LOCAL_SIZE)))
	var active_groups := int(ceil(float(count) / float(LOCAL_SIZE)))

	if _timestamps_enabled:
		_read_timestamps()
		rd.capture_timestamp("fx_begin")

	var cl := rd.compute_list_begin()

	# 1. chaos game: the whole grid on a seed pass, the drawn subset otherwise
	if do_chaos or _needs_seed:
		rd.compute_list_bind_compute_pipeline(cl, _chaos_pipeline)
		rd.compute_list_bind_uniform_set(cl, _chaos_set, 0)
		if _needs_seed:
			rd.compute_list_set_push_constant(cl,
				_pc_chaos(Genome.num_transforms(), iters, tex_size * tex_size, reseed, true), 32)
			rd.compute_list_dispatch(cl, groups, 1, 1)
			rd.compute_list_add_barrier(cl)
			_needs_seed = false
		if do_chaos:
			rd.compute_list_set_push_constant(cl,
				_pc_chaos(Genome.num_transforms(), iters, count, reseed, false), 32)
			rd.compute_list_dispatch(cl, active_groups, 1, 1)
		rd.compute_list_add_barrier(cl)
	if _timestamps_enabled:
		rd.compute_list_end()
		rd.capture_timestamp("fx_chaos")
		cl = rd.compute_list_begin()

	# 2. atomic splat, once per eye
	if do_splat:
		rd.compute_list_bind_compute_pipeline(cl, _splat_pipeline)
		rd.compute_list_bind_uniform_set(cl, _splat_set, 0)
		for v in mini(views, viewprojs.size()):
			rd.compute_list_set_push_constant(cl,
				_pc_splat(viewprojs[v], v, count, stamp, Genome.POINT_BRIGHTNESS), 96)
			rd.compute_list_dispatch(cl, active_groups, 1, 1)
		rd.compute_list_add_barrier(cl)
	if _timestamps_enabled:
		rd.compute_list_end()
		rd.capture_timestamp("fx_splat")
		cl = rd.compute_list_begin()

	# 3. tone map + fused clear
	if do_resolve:
		rd.compute_list_bind_compute_pipeline(cl, _resolve_pipeline)
		rd.compute_list_bind_uniform_set(cl, _resolve_set, 0)
		rd.compute_list_set_push_constant(cl, _pc_resolve(), 32)
		rd.compute_list_dispatch(cl,
			int(ceil(float(eye_res.x) / float(RESOLVE_TILE))),
			int(ceil(float(eye_res.y) / float(RESOLVE_TILE))), 1)

	rd.compute_list_end()
	if _timestamps_enabled:
		rd.capture_timestamp("fx_resolve")

	# A local device runs nothing until it is told to; the main RD flows with the frame.
	if is_local:
		rd.submit()
		rd.sync()

## Timestamps land one frame late, which is fine: the bench holds each stage for
## seconds. Godot's raw value is nanoseconds; these are microseconds.
func _read_timestamps() -> void:
	var n := rd.get_captured_timestamps_count()
	if n < 2:
		return
	var t := {}
	for i in n:
		t[rd.get_captured_timestamp_name(i)] = float(rd.get_captured_timestamp_gpu_time(i)) / 1000.0  # ns -> us
	if not t.has("fx_begin"):
		return
	var b: float = t["fx_begin"]
	stage_ms["chaos"] = maxf(0.0, t.get("fx_chaos", b) - b)
	stage_ms["splat"] = maxf(0.0, t.get("fx_splat", t.get("fx_chaos", b)) - t.get("fx_chaos", b))
	stage_ms["resolve"] = maxf(0.0, t.get("fx_resolve", t.get("fx_splat", b)) - t.get("fx_splat", b))
	stage_ms["total"] = maxf(0.0, t.get("fx_resolve", b) - b)


## Raw RID of the tone-mapped output, for readback in the headless self-test.
func get_out_texture_rid() -> RID:
	return _out_tex


func cleanup() -> void:
	if rd == null:
		return
	if not is_local:
		out_texture.texture_rd_rid = RID()
		state_texture.texture_rd_rid = RID()
	for r in [_state_tex, _accum_tex, _out_tex, _genome_buf,
			_chaos_pipeline, _splat_pipeline, _resolve_pipeline,
			_chaos_shader, _splat_shader, _resolve_shader]:
		if r != null and r.is_valid():
			rd.free_rid(r)
	_ready = false
