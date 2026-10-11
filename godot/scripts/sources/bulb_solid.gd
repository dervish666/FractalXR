extends MeshInstance3D
class_name BulbSolid

## SOLID: the bulb as an opaque mesh, extracted on the device from the same distance
## estimate the particles project onto, with ambient occlusion and a soft key-light
## shadow baked into every vertex. The classic raymarched look paid for once per bulb
## instead of per pixel per frame (vault: topics/fractalxr-bulb-display-options, S4).
##
## The build is four compute passes, all variants of shaders/bulb.glsl so the DE exists
## once: FIELD samples (DE - iso) on an (N+1)^3 grid, VERTS places one surface-nets vertex
## per crossed cell and snaps it onto the DE, QUADS joins the four cells round every
## crossed grid edge, LIGHT marches six AO cones and one shadow cone per vertex. Each runs
## in slabs sized to about 2 ms of Quest GPU a frame (a guess; see *_PER_FRAME), so the
## build is a short
## "growing" moment and never one long stall.
##
## The passes write Godot's own vertex layout, so the readback goes into an ArrayMesh
## untouched: no per-vertex GDScript. There is no public way to hand a compute buffer to a
## mesh, which is why the data makes the round trip through the CPU at all.
##
## Sits under the ParticleCloud like BulbMarch: positions are in state units and the node
## transform is the cloud's state-to-local mapping, so grab, scale and spin apply as is.

enum State { IDLE, FIELD, VERTS, QUADS, LIGHT, READBACK, READY }

## The palette SOLID wears on THEME "preset": an echo of the Mandelbulber still Sam liked
## (.spike-out/mb2-2026-10-11/classic_toy_mono). Its lit pixels are 46% bronze to gold,
## 15% cream highlight and the rest magenta, violet and a little green in the folds (hue
## histogram, 2026-10-11). Mandelbulber's own default gradient is Citadel's preset palette
## (fd6029, f5bd22, 698403 ...); this keeps its warm end and one magenta band, so the
## trap's equalised spread lands most of the surface on bronze, gold and cream. An olive
## stop was tried and turned the whole bulb khaki; magenta on two of the four segments
## turned it pink.
const CLASSIC_PALETTE := [
	Vector3(0.58, 0.24, 0.08), Vector3(0.92, 0.64, 0.18), Vector3(0.62, 0.18, 0.42),
	Vector3(0.94, 0.7, 0.26), Vector3(0.96, 0.9, 0.66)]

## Work per frame, per pass. Sized from the M1 Pro (MoltenVK timestamps, Classic, 2026-10-11)
## to about 0.4 ms a slab there, which is 1.2-2 ms on the Quest if the Quest is the 3-5x
## slower guessed in the spike report (a guess until a headset log has [solid] lines).
## Measured on the Mac, Classic at 192:
##   FIELD  ~1.1 ms per 1M corners (one DE each)
##   VERTS  ~2 ms per 1M cells (eight byte reads each; the crossed 3% snap and take a normal)
##   QUADS  ~0.3 ms per 1M corners
##   LIGHT  ~0.6 ms per 10k vertices (six AO rays, one shadow march)
const FIELD_PER_FRAME := 3 << 17
const VERTS_PER_FRAME := 1 << 18
const QUADS_PER_FRAME := 1 << 20
const LIGHT_PER_FRAME := 6144
## Extracted level set, in voxels: DE = ISO_VOXELS * h. A little outside the set, so a
## filament thinner than a voxel still reads as a tube instead of breaking into dust.
const ISO_VOXELS := 0.35
## 1 = a point that never escaped counts as solid (the note's escape test), 0 = the DE's
## level set alone. Per-family results are in the spike report.
var inside_mode := 1.0
## AO reach as a fraction of the grid's half-width, shadow reach as a multiple of it.
const AO_RADIUS := 0.15
const SHADOW_REACH := 2.2
const SHADOW_K := 10.0
## Vertex capacity per N^2 cells; triangles get 2.2 per vertex. Fractal surfaces outgrow
## the N^2 of a smooth one, so this is generous, and an overflow is reported, not hidden.
const CAP_PER_N2 := 24
## Godot picks 16-bit indices at or under this many vertices; the passes write 32-bit.
const MIN_VERTS_32BIT := 65537

var state := State.IDLE
var grid := 0
var vert_count := 0
var tri_count := 0
var overflow := false
## Build cost, for the [perf] line and the spike harness. gpu_ms is the sum of the
## timestamped passes; wall_ms runs from the request to the mesh on screen; upload_ms is
## the main-thread cost of turning the readback into a mesh (the one stall left).
var gpu_ms := 0.0
var wall_ms := 0.0
var upload_ms := 0.0
var build_frames := 0
## Slabs dispatched, and how many had their timestamps read back. Timestamps come from the
## last finished frame only, so a slab can be missed, and gpu_ms is then an undercount.
var slabs := 0
var timed_slabs := 0
## The dearest single slab, which is what decides whether a build frame drops.
var max_slab_ms := 0.0
var pass_ms := {"field": 0.0, "verts": 0.0, "quads": 0.0, "light": 0.0}
## Set when the mesh lands, cleared by whoever reads it.
var just_ready := false

var _mat: ShaderMaterial
var _rd: RenderingDevice
var _shaders := {}
var _pipes := {}
var _sets := {}
var _field: RID
var _cellmap: RID
var _verts: RID
var _attrs: RID
var _indices: RID
var _counters: RID
var _cap_v := 0
var _cap_t := 0
var _alloc_grid := 0
var _gen := 0
var _layer := 0
var _vfirst := 0
var _pc := PackedByteArray()
var _half := 1.0
var _light := Vector3(0.5, 0.8, 0.35).normalized()
var _t_start := 0
var _grow := 1.0
var _pending := {}
var _want_data := false
var _hist := PackedInt32Array()
var _last_ts_frame := -1
var _ts_pass := ""
var _err := ""


func _init() -> void:
	name = "Solid"
	_mat = ShaderMaterial.new()
	_mat.shader = load("res://shaders/bulb_solid.gdshader")
	material_override = _mat
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	visible = false


func is_building() -> bool:
	return state != State.IDLE and state != State.READY


func is_ready() -> bool:
	return state == State.READY


func get_error() -> String:
	return _err


## The shape's radius in state units: the measured extent from rooms.json when there is
## one (march_bound() would take the seed ball, which is 1.3 against Classic's 1.10 and
## 1.8x the cells), else the marcher's sphere.
static func extent_of(src: BulbSource) -> float:
	var r := src.room()
	if r.has("extent"):
		return float(r["extent"])
	return src.march_bound()


## Grid half-width: the extent plus room for the breath, which moves the surface out (power
## 5.5 is a fatter bulb than 8) and was not what rooms.sh measured.
static func half_of(src: BulbSource) -> float:
	return extent_of(src) * 1.12


## 0..1 through the build, for the SURFACE tile.
func progress() -> float:
	match state:
		State.FIELD: return 0.3 * float(_layer) / float(grid + 1)
		State.VERTS: return 0.3 + 0.15 * float(_layer) / float(grid)
		State.QUADS: return 0.45 + 0.05 * float(_layer) / float(grid + 1)
		State.LIGHT: return 0.5 + 0.45 * float(_vfirst) / float(maxi(1, vert_count))
		State.READBACK: return 0.97
		State.READY: return 1.0
	return 0.0


## Main thread. Snapshot the genome as it stands (the breath moves on, the mesh does not)
## and the key light in state space, then let step() run the passes.
func request(src: BulbSource, n: int, light_state: Vector3) -> void:
	_gen += 1
	grid = n
	state = State.FIELD
	_layer = 0
	_vfirst = 0
	vert_count = 0
	tri_count = 0
	overflow = false
	gpu_ms = 0.0
	build_frames = 0
	slabs = 0
	timed_slabs = 0
	max_slab_ms = 0.0
	for k in pass_ms:
		pass_ms[k] = 0.0
	_pending = {}
	_want_data = false
	_err = ""
	_light = light_state.normalized() if light_state.length_squared() > 1e-8 else _light
	_half = half_of(src)
	_t_start = Time.get_ticks_usec()
	var mp := src.march_params()
	var h := 2.0 * _half / float(n)
	_pc.resize(112)
	_pc.encode_s32(0, n)
	_pc.encode_float(16, -_half)
	_pc.encode_float(20, -_half)
	_pc.encode_float(24, -_half)
	_pc.encode_float(28, h)
	_pc.encode_float(32, ISO_VOXELS * h)
	_pc.encode_float(36, mp["power"])
	_pc.encode_float(40, mp["mandelbulb"])
	_pc.encode_float(44, mp["formula"])
	var c: Vector3 = mp["julia_c"]
	_pc.encode_float(48, c.x)
	_pc.encode_float(52, c.y)
	_pc.encode_float(56, c.z)
	_pc.encode_float(60, 0.0)
	_pc.encode_float(64, mp["scale"])
	_pc.encode_float(68, mp["min_r"])
	_pc.encode_float(72, mp["fixed_r"])
	_pc.encode_float(76, mp["k_angle_a"])
	_pc.encode_float(80, mp["k_angle_b"])
	_pc.encode_float(84, inside_mode)
	_pc.encode_float(88, AO_RADIUS * _half)
	_pc.encode_float(92, SHADOW_K)
	_pc.encode_float(96, _light.x)
	_pc.encode_float(100, _light.y)
	_pc.encode_float(104, _light.z)
	_pc.encode_float(108, SHADOW_REACH * _half)
	_mat.set_shader_parameter("light_dir", _light)


## Drop the mesh and abandon any build in flight. Its readbacks are tagged with the old
## generation and are dropped when they land.
func clear() -> void:
	if is_building():
		# 30-160 MB of scratch that nothing will read now. The RD defers the free past any
		# frame still using it, so a readback in flight is safe.
		RenderingServer.call_on_render_thread(_free_buffers)
	_gen += 1
	state = State.IDLE
	mesh = null
	visible = false
	just_ready = false


## Render thread, once a frame while building: the next slab of whichever pass is running.
func step() -> void:
	if state == State.READBACK and _want_data:
		# Asked for here, not from inside _on_counters: a readback requested from within
		# another readback's callback came back as zeros (Metal, Godot 4.7).
		_want_data = false
		var v := vert_count
		_rd.buffer_get_data_async(_verts, _on_data.bind(_gen, "verts"), 0, v * 12)
		_rd.buffer_get_data_async(_attrs, _on_data.bind(_gen, "attrs"), 0, v * 12)
		_rd.buffer_get_data_async(_indices, _on_data.bind(_gen, "indices"), 0, tri_count * 12)
	if not is_building() or state == State.READBACK:
		_read_timestamps()
		return
	if _rd == null and not _setup():
		state = State.IDLE
		return
	_read_timestamps()
	if not _ensure_buffers():
		state = State.IDLE
		return
	build_frames += 1
	var n := grid
	var pc := _pc.duplicate()
	var cl: int
	_ts_pass = ""
	match state:
		State.FIELD:
			if _layer == 0:
				_rd.buffer_clear(_counters, 0, 66 * 4)
			var c := n + 1
			var layers := clampi(FIELD_PER_FRAME / (c * c), 1, c - _layer)
			var row := (n + 4) / 4
			pc.encode_s32(4, _layer)
			pc.encode_s32(8, layers)
			_ts_pass = "field"
			_rd.capture_timestamp("solid_b%d" % _gen)
			cl = _rd.compute_list_begin()
			_dispatch(cl, &"mesh_field", pc, layers * row * c)
			_rd.compute_list_end()
			_layer += layers
			if _layer >= c:
				state = State.VERTS
				_layer = 0
		State.VERTS:
			var layers := clampi(VERTS_PER_FRAME / (n * n), 1, n - _layer)
			pc.encode_s32(4, _layer)
			pc.encode_s32(8, layers)
			pc.encode_s32(12, _cap_v)
			_ts_pass = "verts"
			_rd.capture_timestamp("solid_b%d" % _gen)
			cl = _rd.compute_list_begin()
			_dispatch(cl, &"mesh_verts", pc, layers * n * n)
			_rd.compute_list_end()
			_layer += layers
			if _layer >= n:
				state = State.QUADS
				_layer = 0
				_rd.buffer_get_data_async(_counters, _on_vert_count.bind(_gen), 0, 8)
		State.QUADS:
			var c := n + 1
			# A few byte reads a corner. Kept under 65535 workgroups of 64.
			var layers := clampi(QUADS_PER_FRAME / (c * c), 1, c - _layer)
			pc.encode_s32(4, _layer)
			pc.encode_s32(8, layers)
			pc.encode_s32(12, _cap_t)
			_ts_pass = "quads"
			_rd.capture_timestamp("solid_b%d" % _gen)
			cl = _rd.compute_list_begin()
			_dispatch(cl, &"mesh_quads", pc, layers * c * c)
			_rd.compute_list_end()
			_layer += layers
			if _layer >= c:
				state = State.LIGHT
		State.LIGHT:
			if vert_count == 0:
				return   # the vertex count readback has not landed yet
			var chunk := mini(LIGHT_PER_FRAME, vert_count - _vfirst)
			pc.encode_s32(4, _vfirst)
			pc.encode_s32(8, chunk)
			pc.encode_s32(12, _cap_v)
			_ts_pass = "light"
			_rd.capture_timestamp("solid_b%d" % _gen)
			cl = _rd.compute_list_begin()
			_dispatch(cl, &"mesh_light", pc, chunk)
			_rd.compute_list_end()
			_vfirst += chunk
			if _vfirst >= vert_count:
				state = State.READBACK
				_rd.buffer_get_data_async(_counters, _on_counters.bind(_gen), 0, 66 * 4)
	if _ts_pass != "":
		slabs += 1
		_rd.capture_timestamp("solid_e%d_%s" % [_gen, _ts_pass])


func _dispatch(cl: int, version: StringName, pc: PackedByteArray, invocations: int) -> void:
	_rd.compute_list_bind_compute_pipeline(cl, _pipes[version])
	_rd.compute_list_bind_uniform_set(cl, _sets[version], 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, int(ceil(float(invocations) / 64.0)), 1, 1)


## GPU time of the previous frame's slab, summed per pass. Timestamps come back a frame or
## two late, and each captured frame is counted once. The names carry the build generation,
## so a slab of an abandoned build landing after a restart is not billed to the new one.
func _read_timestamps() -> void:
	if _rd == null:
		return
	var n := _rd.get_captured_timestamps_count()
	if n < 2:
		return
	var frame := _rd.get_captured_timestamps_frame()
	if frame == _last_ts_frame:
		return
	_last_ts_frame = frame
	var b := -1.0
	var tag_b := "solid_b%d" % _gen
	var tag_e := "solid_e%d_" % _gen
	for i in n:
		var nm := _rd.get_captured_timestamp_name(i)
		if nm == tag_b:
			b = float(_rd.get_captured_timestamp_gpu_time(i)) / 1e6
		elif nm.begins_with(tag_e) and b >= 0.0:
			var ms := float(_rd.get_captured_timestamp_gpu_time(i)) / 1e6 - b
			var key := nm.substr(tag_e.length())
			if pass_ms.has(key):
				pass_ms[key] += ms
			gpu_ms += ms
			timed_slabs += 1
			max_slab_ms = maxf(max_slab_ms, ms)
			b = -1.0


func _on_vert_count(raw: PackedByteArray, gen: int) -> void:
	if gen != _gen or raw.size() < 4:
		return
	var v := raw.decode_u32(0)
	overflow = v > _cap_v
	vert_count = mini(v, _cap_v)
	if vert_count == 0:
		_err = "no surface crossed the grid"
		push_warning("[solid] %s" % _err)
		state = State.IDLE


func _on_counters(raw: PackedByteArray, gen: int) -> void:
	if gen != _gen or raw.size() < 66 * 4:
		return
	var t := raw.decode_u32(4)
	overflow = overflow or t > _cap_t
	tri_count = mini(t, _cap_t - 1)
	if tri_count == 0:
		_err = "the surface made no triangles"
		push_warning("[solid] %s" % _err)
		state = State.IDLE
		return
	_hist.resize(64)
	for i in 64:
		_hist[i] = raw.decode_u32(8 + i * 4)
	_pending = {}
	_want_data = true


func _on_data(raw: PackedByteArray, gen: int, what: String) -> void:
	if gen != _gen:
		return
	_pending[what] = raw
	if _pending.size() == 3:
		# Mesh creation belongs to the main thread; the readback callback is the RD's.
		_finish.call_deferred(gen)


func _finish(gen: int) -> void:
	if gen != _gen or state != State.READBACK:
		return
	var t0 := Time.get_ticks_usec()
	var v := vert_count
	var vdata: PackedByteArray = _pending["verts"]
	var adata: PackedByteArray = _pending["attrs"]
	var idata: PackedByteArray = _pending["indices"]
	_pending = {}
	# Godot switches to 16-bit indices for small meshes; pad past that rather than repack.
	var vc := maxi(v, MIN_VERTS_32BIT)
	if vc > v:
		vdata.resize(vc * 12)
		adata.resize(vc * 12)
	var surf := _surface_template()
	if surf.is_empty():
		state = State.IDLE
		return
	surf["vertex_data"] = vdata
	surf["attribute_data"] = adata
	surf["vertex_count"] = vc
	surf["index_data"] = idata
	surf["index_count"] = tri_count * 3
	surf["aabb"] = AABB(Vector3.ONE * -_half, Vector3.ONE * (2.0 * _half))
	var m := ArrayMesh.new()
	m.set("_surfaces", [surf])
	if m.get_surface_count() != 1:
		_err = "mesh rejected the surface"
		push_error("[solid] %s" % _err)
		state = State.IDLE
		return
	mesh = m
	_set_cdf()
	if OS.has_feature("editor"):   # desktop harness runs only, never the headset
		_debug_sample(vdata, adata, idata)
	upload_ms = float(Time.get_ticks_usec() - t0) / 1000.0
	wall_ms = float(Time.get_ticks_usec() - _t_start) / 1000.0
	state = State.READY
	just_ready = true
	_grow = 0.0
	print("[solid] grid %d: %d verts, %d tris%s, gpu %.1f ms over %d of %d slabs (field %.1f verts %.1f quads %.1f light %.1f), %d frames, wall %.0f ms, upload %.1f ms" % [
		grid, v, tri_count, " OVERFLOW" if overflow else "", gpu_ms, timed_slabs, slabs,
		pass_ms["field"], pass_ms["verts"], pass_ms["quads"], pass_ms["light"], build_frames,
		wall_ms, upload_ms])
	RenderingServer.call_on_render_thread(_free_scratch.bind(gen))


## Means over a sample of vertices, so a harness log says whether the light pass ran.
func _debug_sample(vdata: PackedByteArray, adata: PackedByteArray, idata: PackedByteArray) -> void:
	var n := mini(vert_count, 4096)
	var stride := maxi(1, vert_count / n)
	var ao := 0.0
	var sh := 0.0
	var trap := 0.0
	var lo := Vector3.ONE * 1e9
	var hi := -lo
	for s in n:
		var v := s * stride
		ao += float(adata[v * 12 + 8]) / 255.0
		sh += float(adata[v * 12 + 9]) / 255.0
		trap += adata.decode_half(v * 12 + 6)
		var p := Vector3(vdata.decode_float(v * 12), vdata.decode_float(v * 12 + 4), vdata.decode_float(v * 12 + 8))
		lo = lo.min(p)
		hi = hi.max(p)
	var total := 0
	for x in _hist:
		total += x
	print("[solid] sample of %d: mean ao %.2f shadow %.2f trap %.2f, bounds %s..%s, hist total %d, first tri %d %d %d" % [
		n, ao / n, sh / n, trap / n, str(lo), str(hi), total,
		idata.decode_u32(0), idata.decode_u32(4), idata.decode_u32(8)])


## A one-triangle mesh built the documented way, then read back as the storage dictionary
## the readback is dropped into. Godot's format bits are taken from it, not written by hand.
static var _template: Dictionary = {}


func _surface_template() -> Dictionary:
	if _template.is_empty():
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.UP])
		var c0 := PackedByteArray()
		c0.resize(24)
		var c1 := PackedByteArray()
		c1.resize(12)
		arrays[Mesh.ARRAY_CUSTOM0] = c0
		arrays[Mesh.ARRAY_CUSTOM1] = c1
		arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2])
		var fmt := (Mesh.ARRAY_CUSTOM_RGBA_HALF << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT) \
			| (Mesh.ARRAY_CUSTOM_RGBA8_UNORM << Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT)
		var ref := ArrayMesh.new()
		ref.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, fmt)
		var surfs: Array = ref.get("_surfaces")
		if surfs.size() != 1:
			_err = "no _surfaces on a reference mesh"
			push_error("[solid] %s" % _err)
			return {}
		var d: Dictionary = surfs[0]
		# The passes write 12 bytes of position and 12 of attributes a vertex. If Godot's
		# layout ever differs, refuse rather than draw garbage.
		var vb: PackedByteArray = d.get("vertex_data", PackedByteArray())
		var ab: PackedByteArray = d.get("attribute_data", PackedByteArray())
		if vb.size() != 36 or ab.size() != 36:
			_err = "unexpected vertex layout: %d / %d bytes for 3 vertices" % [vb.size(), ab.size()]
			push_error("[solid] %s" % _err)
			return {}
		d.erase("lods")
		_template = d
	return _template.duplicate()


## Histogram equalisation of the trap, as the splat renderer does for its particles: the
## raw trap bunches up, and a palette across a bunched range is one colour.
func _set_cdf() -> void:
	var cdf := PackedFloat32Array()
	cdf.resize(65)
	var total := 0
	for i in _hist.size():
		total += _hist[i]
	var acc := 0
	cdf[0] = 0.0
	for i in 64:
		acc += _hist[i] if i < _hist.size() else 0
		cdf[i + 1] = float(acc) / float(maxi(1, total))
	_mat.set_shader_parameter("cdf", cdf)


## Main thread, every frame: the cloud's state-to-local mapping, and the grow-in.
func tick(center: Vector3, fit: float, delta: float) -> void:
	transform = Transform3D(Basis().scaled(Vector3.ONE * fit), -center * fit)
	if _grow < 1.0:
		_grow = minf(1.0, _grow + delta / 0.35)
		_mat.set_shader_parameter("grow", Morph.smoothstep_t(_grow))


const _PAL_NAMES: Array[StringName] = [&"pal0", &"pal1", &"pal2", &"pal3", &"pal4"]


func set_palette(pal: Array) -> void:
	for i in mini(5, pal.size()):
		_mat.set_shader_parameter(_PAL_NAMES[i], pal[i])


func set_gain(g: float) -> void:
	_mat.set_shader_parameter("gain", g)


func set_palette_cycles(c: float) -> void:
	_mat.set_shader_parameter("palette_cycles", c)


# --- render thread ---------------------------------------------------------------------

func _setup() -> bool:
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		_err = "no RenderingDevice"
		return false
	var file: RDShaderFile = load("res://shaders/bulb.glsl")
	if file == null:
		_err = "missing bulb.glsl"
		return false
	for v: StringName in [&"mesh_field", &"mesh_verts", &"mesh_quads", &"mesh_light"]:
		var spirv := file.get_spirv(v)
		if spirv == null or spirv.compile_error_compute != "":
			_err = "bulb.glsl %s: %s" % [v, spirv.compile_error_compute if spirv else "no variant"]
			push_error("[solid] %s" % _err)
			_rd = null
			return false
		var sh := _rd.shader_create_from_spirv(spirv)
		if not sh.is_valid():
			_err = "shader_create_from_spirv failed for %s" % v
			_rd = null
			return false
		_shaders[v] = sh
		_pipes[v] = _rd.compute_pipeline_create(sh)
	return true


func _ensure_buffers() -> bool:
	if _alloc_grid == grid and _field.is_valid():
		return true
	_free_buffers()
	var n := grid
	var c := n + 1
	var row := (n + 4) / 4
	_cap_v = n * n * CAP_PER_N2
	_cap_t = int(_cap_v * 2.2)
	_field = _rd.storage_buffer_create(row * c * c * 4)
	_cellmap = _rd.storage_buffer_create(n * n * n * 4)
	_verts = _rd.storage_buffer_create(_cap_v * 12)
	_attrs = _rd.storage_buffer_create(_cap_v * 12)
	_indices = _rd.storage_buffer_create(_cap_t * 12)
	_counters = _rd.storage_buffer_create(66 * 4)
	for rid: RID in [_field, _cellmap, _verts, _attrs, _indices, _counters]:
		if not rid.is_valid():
			_err = "could not allocate the grid %d buffers" % n
			push_error("[solid] %s" % _err)
			_free_buffers()
			return false
	_alloc_grid = n
	var u := func(binding: int, buf: RID) -> RDUniform:
		var x := RDUniform.new()
		x.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		x.binding = binding
		x.add_id(buf)
		return x
	_sets[&"mesh_field"] = _rd.uniform_set_create([u.call(0, _field)], _shaders[&"mesh_field"], 0)
	_sets[&"mesh_verts"] = _rd.uniform_set_create([u.call(0, _field), u.call(1, _cellmap),
		u.call(2, _verts), u.call(3, _attrs), u.call(5, _counters)], _shaders[&"mesh_verts"], 0)
	_sets[&"mesh_quads"] = _rd.uniform_set_create([u.call(0, _field), u.call(1, _cellmap),
		u.call(2, _verts), u.call(4, _indices), u.call(5, _counters)], _shaders[&"mesh_quads"], 0)
	_sets[&"mesh_light"] = _rd.uniform_set_create([u.call(2, _verts), u.call(3, _attrs),
		u.call(5, _counters)], _shaders[&"mesh_light"], 0)
	print("[solid] grid %d buffers: %.1f MB (caps %d verts, %d tris)" % [n,
		float(row * c * c * 4 + n * n * n * 4 + _cap_v * 24 + _cap_t * 12) / 1048576.0, _cap_v, _cap_t])
	return true


## The scratch is 30-160 MB depending on the grid. Once the mesh is up nothing reads it.
func _free_scratch(gen: int) -> void:
	if gen == _gen:
		_free_buffers()


func _free_buffers() -> void:
	if _rd == null:
		return
	for rid: RID in [_field, _cellmap, _verts, _attrs, _indices, _counters]:
		if rid.is_valid():
			_rd.free_rid(rid)   # uniform sets depending on them go with them
	_field = RID()
	_cellmap = RID()
	_verts = RID()
	_attrs = RID()
	_indices = RID()
	_counters = RID()
	_sets = {}
	_alloc_grid = 0


func cleanup() -> void:
	_free_buffers()
	if _rd != null:
		for v in _shaders:
			if (_shaders[v] as RID).is_valid():
				_rd.free_rid(_shaders[v])
	_shaders = {}
	_pipes = {}
