extends RefCounted
class_name FractalSource

## Base class for anything that fills the particle state image.
##
## The whole point of this class is that the renderer, the controls, the grab, the
## HUD and the preset machinery know nothing about which fractal is running. To add
## a type (Mandelbulb, Mandelbox, KIFS, quaternion Julia, the relief zoomer), write
## one compute shader and one subclass. Nothing else changes.
##
## Contract for a subclass:
##   shader_path()   where the compute shader lives
##   params_bytes()  the push constant, sized to push_constant_size()
##   param_buffer()  optional per-type storage buffer (genome, DE params); may be empty
##
## The state image is always RGBA32F, one texel per particle, xyz = position and
## w = palette coordinate 0..1. That layout is the contract with points.gdshader,
## so every type renders through the same path for free.

var id: StringName = &"base"
var display_name: String = "Base"

var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _uniform_set: RID
var _param_buf: RID
var _state_tex: RID
var _normal_tex: RID
var _tex_size: int
var _error := ""


func shader_path() -> String:
	push_error("FractalSource.shader_path() not overridden")
	return ""


## Bytes for the compute push constant. Must be a multiple of 16 and at most 128,
## which is the limit every Vulkan implementation is guaranteed to offer.
func params_bytes(_count: int, _frame: int, _seeding: bool) -> PackedByteArray:
	return PackedByteArray()


func push_constant_size() -> int:
	return 32


## True for sources that write a surface normal alongside the position. A flame is a
## density field with no surface, so it has no normal to give.
func wants_normals() -> bool:
	return false


## Per-type storage buffer contents. Return an empty array for a type that needs none.
func param_buffer_floats() -> PackedFloat32Array:
	return PackedFloat32Array()


## Tone-map and render settings this source wants. Keys match ToneSettings.
func tone_settings() -> Dictionary:
	return {"exposure": 0.32, "gamma": 2.4, "k2": 55.0, "hi_desat": 0.3, "point_brightness": 0.9}


## Five palette control colours, dark to light.
func palette() -> Array:
	return [Vector3(0, 0, 0), Vector3(0.25, 0, 0.3), Vector3(0.9, 0.2, 0.4),
		Vector3(1, 0.6, 0.1), Vector3(1, 0.95, 0.65)]


func get_error() -> String:
	return _error


func setup(rd: RenderingDevice, state_tex: RID, tex_size: int, normal_tex: RID = RID()) -> bool:
	_rd = rd
	_state_tex = state_tex
	_normal_tex = normal_tex
	_tex_size = tex_size

	var file: RDShaderFile = load(shader_path())
	if file == null:
		_error = "failed to load %s" % shader_path()
		return false
	var spirv := file.get_spirv()
	if spirv.compile_error_compute != "":
		_error = "%s: %s" % [shader_path(), spirv.compile_error_compute]
		return false
	_shader = rd.shader_create_from_spirv(spirv)
	if not _shader.is_valid():
		_error = "shader_create_from_spirv failed for %s" % shader_path()
		return false
	_pipeline = rd.compute_pipeline_create(_shader)

	rebuild_params()
	return true


## Re-upload the per-type buffer. Call after switching preset or editing parameters;
## it reallocates rather than mapping, which is fine at human interaction rates.
func rebuild_params() -> void:
	var floats := param_buffer_floats()
	if floats.is_empty():
		# A source with no parameters still needs a valid binding, so allocate a stub.
		floats = PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
	if _param_buf.is_valid():
		_rd.free_rid(_param_buf)
	_param_buf = _rd.storage_buffer_create(floats.size() * 4, floats.to_byte_array())

	var img := RDUniform.new()
	img.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	img.binding = 0
	img.add_id(_state_tex)
	var ssbo := RDUniform.new()
	ssbo.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	ssbo.binding = 1
	ssbo.add_id(_param_buf)
	var binds: Array = [img, ssbo]
	if wants_normals() and _normal_tex.is_valid():
		var nrm := RDUniform.new()
		nrm.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		nrm.binding = 2
		nrm.add_id(_normal_tex)
		binds.append(nrm)
	_uniform_set = _rd.uniform_set_create(binds, _shader, 0)


## Rewrite the parameter buffer in place. Used by morphing, which changes the genome
## every frame: recreating the buffer at 72Hz would churn RIDs for no reason.
func update_params() -> void:
	if _rd == null or not _param_buf.is_valid():
		return
	var floats := param_buffer_floats()
	if floats.is_empty():
		return
	_rd.buffer_update(_param_buf, 0, floats.size() * 4, floats.to_byte_array())


## Record one iteration step into an open compute list.
func encode(cl: int, count: int, frame: int, seeding: bool) -> void:
	if not _pipeline.is_valid():
		return
	var n := _tex_size * _tex_size if seeding else count
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline)
	_rd.compute_list_bind_uniform_set(cl, _uniform_set, 0)
	_rd.compute_list_set_push_constant(cl, params_bytes(n, frame, seeding), push_constant_size())
	_rd.compute_list_dispatch(cl, int(ceil(float(n) / 256.0)), 1, 1)


func cleanup() -> void:
	if _rd == null:
		return
	for r in [_param_buf, _pipeline, _shader]:
		if r != null and r.is_valid():
			_rd.free_rid(r)
