extends CompositorEffect
class_name Flam3Tonemap

## flam3 log-density tone mapping, as a compute pass over the scene's HDR colour buffer.
##
## Runs at POST_TRANSPARENT, after the additive points have accumulated and before
## Godot's post chain. Because it works on the real per-view buffers inside the render
## pipeline, stereo is correct and there is none of the stale-pose swimming that sank
## the screen-space composite in experiments/atomic_splat.
##
## This requires an HDR colour buffer with the STORAGE bit, which is why the project
## uses Forward+ rather than Forward Mobile:
##
##   Forward Mobile  format 63 = A2B10G10R10_UNORM, storage=false  -> impossible
##   Forward+        format 96 = R16G16B16A16_SFLOAT, storage=true -> works
##
## On a fixed-point buffer the additive points clip at 1.0 before this pass ever sees
## them, and log-density has no dynamic range left to compress. That is a correctness
## requirement, not a quality preference.
##
## Set the Environment tonemapper to LINEAR alongside this, or two curves fight.

const SHADER := "res://shaders/flam3.glsl"
const TILE := 8   # must match local_size in flam3.glsl

## Godot's DATA_FORMAT enum is Vulkan's VkFormat minus one.
const HDR_FORMATS := [
	90,   # R16G16B16A16_UNORM is not float, but listed formats below are
	96,   # R16G16B16A16_SFLOAT   <- what Forward+ gives us
	108,  # R32G32B32A32_SFLOAT
	121,  # B10G11R11_UFLOAT_PACK32
	122,  # E5B9G9R9_UFLOAT_PACK32
]

var exposure := 0.32
var gamma := 2.4
var k2 := 55.0
var hi_desat := 0.3
## Cancels Godot's linear->sRGB encode so the pixel that reaches the panel is the one
## this shader chose. Exposed rather than baked so it can be dialled on-device.
var pre_gamma := 2.2

var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _sets := {}
var _reported := false
var _buffer_ok := false
## GPU microseconds for the pass itself. Inferring its cost from frame time was giving
## 40-115ms with huge variance, which is the signature of a stall rather than work.
var pass_us := 0.0


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	access_resolved_color = true
	RenderingServer.call_on_render_thread(_build)


func _build() -> void:
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		push_error("[flam3] no RenderingDevice")
		return
	var file: RDShaderFile = load(SHADER)
	if file == null:
		push_error("[flam3] cannot load %s" % SHADER)
		return
	var spirv := file.get_spirv()
	if spirv.compile_error_compute != "":
		push_error("[flam3] %s" % spirv.compile_error_compute)
		return
	_shader = _rd.shader_create_from_spirv(spirv)
	_pipeline = _rd.compute_pipeline_create(_shader)


func set_tone(t: Dictionary) -> void:
	exposure = float(t.get("exposure", exposure))
	gamma = float(t.get("gamma", gamma))
	k2 = float(t.get("k2", k2))
	hi_desat = float(t.get("hi_desat", hi_desat))


func _render_callback(callback_type: int, render_data: RenderData) -> void:
	if not enabled or _rd == null or not _pipeline.is_valid():
		return
	if callback_type != EFFECT_CALLBACK_TYPE_POST_TRANSPARENT:
		return
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	if buffers == null:
		return
	var size := buffers.get_internal_size()
	if size.x == 0 or size.y == 0:
		return

	# Check the buffer once and say plainly whether the look is even achievable, rather
	# than tone-mapping a clipped buffer and leaving someone to wonder why it is flat.
	if not _reported:
		_reported = true
		var fmt := buffers.get_texture_format(&"render_buffers", &"color")
		if fmt != null:
			var storage := (fmt.usage_bits & RenderingDevice.TEXTURE_USAGE_STORAGE_BIT) != 0
			var hdr: bool = fmt.format in HDR_FORMATS
			_buffer_ok = storage and hdr
			print("[flam3] colour buffer format=%d hdr=%s storage=%s size=%dx%d views=%d -> %s" % [
				fmt.format, str(hdr), str(storage), size.x, size.y, buffers.get_view_count(),
				"active" if _buffer_ok else "DISABLED"])
			if not hdr:
				push_warning("[flam3] fixed-point colour buffer: additive points clip at 1.0, so log-density has no range to compress. Use Forward+.")
			elif not storage:
				push_warning("[flam3] colour buffer has no STORAGE bit, compute cannot write to it. Use Forward+.")
	if not _buffer_ok:
		return

	var groups_x := int(ceil(float(size.x) / float(TILE)))
	var groups_y := int(ceil(float(size.y) / float(TILE)))
	var pc := _push_constant(size)

	_read_timestamp()
	_rd.capture_timestamp("flam3_begin")

	# Both views go in ONE compute list. A list per view meant a second barrier, and on
	# a tiler every break costs a tile store and reload of the whole colour buffer.
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline)
	for view in buffers.get_view_count():
		var color := buffers.get_color_layer(view, false)
		var uset := _uniform_set(color)
		if not uset.is_valid():
			continue
		_rd.compute_list_bind_uniform_set(cl, uset, 0)
		_rd.compute_list_set_push_constant(cl, pc, pc.size())
		_rd.compute_list_dispatch(cl, groups_x, groups_y, 1)
	_rd.compute_list_end()
	_rd.capture_timestamp("flam3_end")


func _read_timestamp() -> void:
	var n := _rd.get_captured_timestamps_count()
	if n < 2:
		return
	var b := -1.0
	var e := -1.0
	for i in n:
		match _rd.get_captured_timestamp_name(i):
			"flam3_begin": b = float(_rd.get_captured_timestamp_gpu_time(i)) / 1000.0
			"flam3_end": e = float(_rd.get_captured_timestamp_gpu_time(i)) / 1000.0
	if b >= 0.0 and e >= b:
		pass_us = e - b


## Cached per colour-layer RID. Godot recreates those layers on resize, so a stale
## entry is simply never looked up again.
func _uniform_set(color: RID) -> RID:
	if _sets.has(color) and _rd.uniform_set_is_valid(_sets[color]):
		return _sets[color]
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u.binding = 0
	u.add_id(color)
	var s := _rd.uniform_set_create([u], _shader, 0)
	_sets[color] = s
	return s


func _push_constant(size: Vector2i) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(32)
	b.encode_s32(0, size.x)
	b.encode_s32(4, size.y)
	b.encode_float(8, exposure)
	b.encode_float(12, gamma)
	b.encode_float(16, k2)
	b.encode_float(20, hi_desat)
	b.encode_float(24, pre_gamma)
	b.encode_float(28, 0.0)
	return b


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _rd != null:
		for r in [_pipeline, _shader]:
			if r.is_valid():
				_rd.free_rid(r)
