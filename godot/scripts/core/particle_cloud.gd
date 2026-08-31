extends Node3D
class_name ParticleCloud

## The particle cloud: state image, point mesh, material. Type-agnostic.
##
## Owns the RGBA32F state image (xyz = position, w = palette coordinate) and the
## points that render it. Which fractal fills that image is entirely up to the
## FractalSource plugged in via set_source(), so adding a type touches nothing here.

# 2048^2 = 4,194,304 particles. The web build's 1536^2 was a WebGL-era ceiling; here the
# limit is vertex throughput, and the measurement says we have room to spend. More points
# is also the real fix for the per-pixel flicker: the chaos game is a stochastic sampler,
# so a pixel lit by one particle is a coin flip, and a pixel lit by ten is a value.
const DEFAULT_TEX_SIZE := 2048

var tex_size := DEFAULT_TEX_SIZE
var source: FractalSource = null

var _rd: RenderingDevice
var _state_tex: RID
var _state_texture := Texture2DRD.new()
var _normal_tex: RID
var _normal_texture := Texture2DRD.new()
var _mesh_instance: MeshInstance3D
var _material: ShaderMaterial          # point path
var _splat_material: ShaderMaterial    # quad path
var _splat := false
var _count := 0
var _frame := 0
var _needs_seed := true
var _ready_ok := false
var _error := ""

## Timestamped GPU cost of the iteration step, in microseconds. Godot's viewport
## timer never sees compute submitted from call_on_render_thread, so without this
## the simulation cost is simply invisible.
var iterate_us := 0.0

## Auto-framing. Measured from the particles themselves rather than hand-tuned per
## preset, because the gallery's attractors differ in both position and size by
## several times over.
var center := Vector3.ZERO
var fit := 1.0
const TARGET_RADIUS := 1.0
## Capped so the shader's uint accumulators cannot overflow; see measure.glsl.
const MEASURE_SAMPLES := 16384
const HIST_BINS := 32
const _STATS_BYTES := (8 + HIST_BINS) * 4
const _POS_SCALE := 4096.0
const _SQ_SCALE := 1024.0
const _MEASURE_BIAS := 8.0
var _measure_shader: RID
var _measure_pipeline: RID
var _measure_set: RID
var _stats_buf: RID
var _measure_pending := false
var _measure_readback := false
## Framing is eased toward these rather than snapped, so a re-measure never pops.
var target_center := Vector3.ZERO
var target_fit := 1.0
## Bumped whenever a measurement lands, so callers can tell a fresh result from a stale one.
var measure_generation := 0


func get_error() -> String:
	return _error


func is_ready() -> bool:
	return _ready_ok


func _init() -> void:
	_material = ShaderMaterial.new()
	_material.shader = load("res://shaders/points.gdshader")
	_splat_material = ShaderMaterial.new()
	_splat_material.shader = load("res://shaders/splat.gdshader")

	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.name = "Points"
	_mesh_instance.material_override = _material
	_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mesh_instance.custom_aabb = AABB(Vector3(-1e4, -1e4, -1e4), Vector3(2e4, 2e4, 2e4))
	add_child(_mesh_instance)


## Build the GPU state. Must run on the render thread.
func setup(p_tex_size: int = DEFAULT_TEX_SIZE) -> bool:
	tex_size = p_tex_size
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		_error = "No RenderingDevice. The Compatibility renderer has none; use Mobile or Forward+."
		return false

	var fmt := RDTextureFormat.new()
	fmt.width = tex_size
	fmt.height = tex_size
	fmt.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	fmt.usage_bits = (RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT)
	_state_tex = _rd.texture_create(fmt, RDTextureView.new(), [])
	_state_texture.texture_rd_rid = _state_tex
	_normal_tex = _rd.texture_create(fmt, RDTextureView.new(), [])
	_normal_texture.texture_rd_rid = _normal_tex

	for m in [_material, _splat_material]:
		m.set_shader_parameter("state_tex", _state_texture)
		m.set_shader_parameter("tex_size", tex_size)
	_splat_material.set_shader_parameter("normal_tex", _normal_texture)
	_setup_measure()
	_ready_ok = true
	return true


func _setup_measure() -> void:
	var file: RDShaderFile = load("res://shaders/measure.glsl")
	if file == null:
		return
	var spirv := file.get_spirv()
	if spirv.compile_error_compute != "":
		push_error("[cloud] measure: %s" % spirv.compile_error_compute)
		return
	_measure_shader = _rd.shader_create_from_spirv(spirv)
	_measure_pipeline = _rd.compute_pipeline_create(_measure_shader)
	# 8 scalars plus a 32-bin histogram.
	_stats_buf = _rd.storage_buffer_create(_STATS_BYTES, PackedByteArray())
	var img := RDUniform.new()
	img.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	img.binding = 0
	img.add_id(_state_tex)
	var ssbo := RDUniform.new()
	ssbo.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	ssbo.binding = 1
	ssbo.add_id(_stats_buf)
	_measure_set = _rd.uniform_set_create([img, ssbo], _measure_shader, 0)


## Ask for a fresh centroid and radius. Cheap, but it stalls on readback, so it runs
## on a settled cloud after a load or a morph rather than every frame.
func request_measure() -> void:
	_measure_pending = true


func state_texture_rid() -> RID:
	return _state_tex


func set_source(s: FractalSource) -> bool:
	if not _ready_ok:
		return false
	if source != null:
		source.cleanup()
	source = s
	_splat_material.set_shader_parameter("use_normals", s.wants_normals())
	if not s.setup(_rd, _state_tex, tex_size, _normal_tex):
		_error = s.get_error()
		return false
	apply_look()
	_needs_seed = true
	return true


## Pull palette and tone settings from the active source. Called on a preset change.
func apply_look() -> void:
	if source == null:
		return
	var pal := source.palette()
	for i in 5:
		for m in [_material, _splat_material]:
			m.set_shader_parameter("pal%d" % i, pal[i])
	# Deliberately NOT setting brightness here: the preset's pointBrightness is a
	# starting suggestion, and stomping the user's live choice every preset change
	# would undo the dial they just turned.


## Draw range. The mesh is a bare vertex buffer (the shader uses VERTEX_ID), so
## rebuilding it costs a resize and nothing else. The web build's equivalent is
## FlamePoints.setActiveCount / geometry.setDrawRange.
func set_count(n: int) -> void:
	n = clampi(n, 1024, tex_size * tex_size)
	if n == _count:
		return
	_count = n
	# Six dummy vertices per particle when splatting (two triangles), one when pointing.
	# VERTEX_ID carries the particle index and the corner, so there are no attributes to
	# fill and the build is a resize either way.
	var verts := PackedVector3Array()
	verts.resize(n * 6 if _splat else n)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(
		Mesh.PRIMITIVE_TRIANGLES if _splat else Mesh.PRIMITIVE_POINTS, arrays,
		[], {}, Mesh.ARRAY_FLAG_USE_DYNAMIC_UPDATE)
	mesh.custom_aabb = _mesh_instance.custom_aabb
	_mesh_instance.mesh = mesh


func get_count() -> int:
	return _count


func set_point_size(px: float) -> void:
	# 1.0 is a hardware floor, not a stylistic choice: a rasterised point covers at
	# least one fragment. Finer than that needs more pixels or less brightness.
	_material.set_shader_parameter("point_size", clampf(px, 1.0, 6.0))


## World-space quad splats instead of single-pixel points. Switching primitive means
## rebuilding the mesh, so only do it on an actual change.
func set_splat(on: bool, radius: float) -> void:
	_splat_material.set_shader_parameter("splat_radius", radius)
	if on == _splat:
		return
	_splat = on
	_mesh_instance.material_override = _splat_material if on else _material
	var n := _count
	_count = 0        # force the rebuild: the vertex count per particle changed
	set_count(n)


func set_sharpness(k: float) -> void:
	for m in [_material, _splat_material]:
		m.set_shader_parameter("sharpness", clampf(k, 1.0, 24.0))


## Palette repeats across the equalised range: 1 gives a single gradient, 2 or 3 give
## distinct colour bands from the same orbit-trap data.
func set_palette_cycles(n: float) -> void:
	for m in [_material, _splat_material]:
		m.set_shader_parameter("palette_cycles", n)


func set_brightness(b: float) -> void:
	for m in [_material, _splat_material]:
		m.set_shader_parameter("brightness", clampf(b, 0.05, 3.0))


func set_visible_cloud(v: bool) -> void:
	_mesh_instance.visible = v


func request_seed() -> void:
	_needs_seed = true


## One simulation step. Must run on the render thread.
func iterate() -> void:
	if not _ready_ok or source == null:
		return
	_frame += 1
	_read_timestamp()
	_rd.capture_timestamp("cloud_begin")

	# Read last frame's result before issuing a new one: by now the GPU is done with it,
	# so buffer_get_data returns without blocking.
	if _measure_readback:
		_measure_readback = false
		_read_measure()
	if _measure_pending and _measure_pipeline.is_valid():
		_measure_pending = false
		_dispatch_measure()
		_measure_readback = true

	var cl := _rd.compute_list_begin()
	if _needs_seed:
		source.encode(cl, _count, _frame, true)
		_rd.compute_list_add_barrier(cl)
		_needs_seed = false
	source.encode(cl, _count, _frame, false)
	_rd.compute_list_end()
	_rd.capture_timestamp("cloud_end")


func _dispatch_measure() -> void:
	_rd.buffer_clear(_stats_buf, 0, _STATS_BYTES)
	var pc := PackedByteArray()
	pc.resize(16)
	pc.encode_s32(0, _count)
	pc.encode_s32(4, tex_size)
	var stride := maxi(1, int(ceil(float(_count) / float(MEASURE_SAMPLES))))
	var groups := int(ceil(float(_count) / float(stride) / 256.0))
	pc.encode_s32(8, stride)
	pc.encode_s32(12, 0)
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _measure_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _measure_set, 0)
	_rd.compute_list_set_push_constant(cl, pc, 16)
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_end()


func _read_measure() -> void:
	var raw := _rd.buffer_get_data(_stats_buf, 0, _STATS_BYTES)
	if raw.size() < 20:
		return
	var n := raw.decode_u32(12)
	if n < 64:
		return   # too few survivors to trust; leave the previous framing alone

	var inv := 1.0 / (float(n) * _POS_SCALE)
	var c := Vector3(
		float(raw.decode_u32(0)) * inv - _MEASURE_BIAS,
		float(raw.decode_u32(4)) * inv - _MEASURE_BIAS,
		float(raw.decode_u32(8)) * inv - _MEASURE_BIAS)

	# RMS radius about the centroid: sqrt(mean|p|^2 - |centroid|^2). Exact from the sums
	# we already have, and far more robust than a max, which one stray particle owns.
	var mean_sq := float(raw.decode_u32(16)) / (float(n) * _SQ_SCALE)
	var radius := sqrt(maxf(0.0001, mean_sq - c.length_squared()))

	# Fail safe. A bad measurement must leave the cloud visible and roughly where it
	# was, never scale it to nothing: that is exactly how this vanished the first time.
	if not is_finite(c.x) or not is_finite(c.y) or not is_finite(c.z) or c.length() > 20.0:
		return
	if not is_finite(radius) or radius < 0.02 or radius > 20.0:
		return

	target_center = c
	# Shrink only, never magnify. Normalising every preset up to a unit radius spread a
	# fixed point budget over more screen area, and thinner points read as lower
	# resolution: that is the "degrades after any change" effect, not foveation and not
	# dynamic resolution, both of which the log shows never move. Large attractors still
	# get reined in; small dense ones keep the density that makes them look sharp.
	target_fit = clampf(TARGET_RADIUS / radius, 0.15, 1.0)
	measure_generation += 1
	if absf(target_fit - fit) > 0.25 or (c - center).length() > 0.25:
		print("[cloud] reframe: centre (%.2f, %.2f, %.2f) rms %.2f fit %.2f from %d samples" % [
			c.x, c.y, c.z, radius, target_fit, n])


## Turn the histogram into a CDF and hand it to the shaders. Mapping each point through
## its own percentile spends the WHOLE palette instead of the narrow band the raw orbit
## trap actually occupies, which is where the iridescence comes from.
func _update_colour_cdf(raw: PackedByteArray, n: int) -> void:
	var cdf := PackedFloat32Array()
	cdf.resize(HIST_BINS)
	var total := 0.0
	for i in HIST_BINS:
		total += float(raw.decode_u32((8 + i) * 4))
	if total < 1.0:
		return
	var acc := 0.0
	for i in HIST_BINS:
		acc += float(raw.decode_u32((8 + i) * 4))
		cdf[i] = acc / total
	for m in [_material, _splat_material]:
		m.set_shader_parameter("colour_cdf", cdf)


## Ease the framing toward the last measurement. Only used when the framing for a
## genome is not yet known; once both endpoints are cached, set_framing drives it
## directly along the morph curve instead, because easing chases a moving target and
## that chase is visible as the cloud drifting half a second behind the shape.
func ease_framing(delta: float) -> void:
	var k := clampf(delta * 1.8, 0.0, 1.0)
	center = center.lerp(target_center, k)
	fit = lerpf(fit, target_fit, k)
	_push_framing()


## Drive the framing directly, for interpolating between two known endpoints.
func set_framing(c: Vector3, f: float) -> void:
	center = c
	fit = f
	target_center = c
	target_fit = f
	_push_framing()


func _push_framing() -> void:
	for m in [_material, _splat_material]:
		m.set_shader_parameter("cloud_center", center)
		m.set_shader_parameter("cloud_fit", fit)


## The last measurement, for caching against a preset.
func measured() -> Dictionary:
	return {"center": target_center, "fit": target_fit}


func _read_timestamp() -> void:
	var n := _rd.get_captured_timestamps_count()
	if n < 2:
		return
	var begin := -1.0
	var end := -1.0
	for i in n:
		match _rd.get_captured_timestamp_name(i):
			"cloud_begin": begin = float(_rd.get_captured_timestamp_gpu_time(i)) / 1000.0
			"cloud_end": end = float(_rd.get_captured_timestamp_gpu_time(i)) / 1000.0
	if begin >= 0.0 and end >= begin:
		iterate_us = end - begin


func cleanup() -> void:
	if source != null:
		source.cleanup()
	if _rd != null and _state_tex.is_valid():
		_state_texture.texture_rd_rid = RID()
		_normal_texture.texture_rd_rid = RID()
		_rd.free_rid(_state_tex)
		_rd.free_rid(_normal_tex)
	_ready_ok = false
