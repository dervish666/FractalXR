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
const _STATS_BYTES := (10 + HIST_BINS) * 4
const _C_SCALE := 65536.0
const _POS_SCALE := 4096.0
const _SQ_SCALE := 1024.0
const _MEASURE_BIAS := 8.0
var _measure_shader: RID
var _measure_pipeline: RID
var _measure_set: RID
var _stats_buf: RID
var _measure_pending := false
# Local density, for sizing splats the way bulbSplat.ts does from kNN covariance.
# 64 rather than 48: particles lie on a SURFACE, so they only occupy the cells the shell
# passes through — roughly grid^2 of them, not grid^3. A finer grid is what makes a cell
# a neighbourhood rather than a region, and the cost is a clear and a dispatch over cells
# that no readback ever touches.
const GRID := 64
const GRID_CELLS := GRID * GRID * GRID
const GRID_TEX_W := 512      # GRID^3 = 262144 = 512 x 512
var _density_shader: RID
var _density_pipeline: RID
var _density_set: RID
var _density_buf: RID
var _density_tex: RID
var _density_texture := Texture2DRD.new()
var _norm_shader: RID
var _norm_pipeline: RID
var _norm_set: RID
var _norm_buf: RID
var _norm_readback := false
## Mean particles per occupied cell. The splat shader divides by this, so a cell holding
## the average keeps the radius the user asked for and only the departures resize.
var density_nominal := 8.0

# --- Bake -------------------------------------------------------------------
#
# One kNN covariance per splat, computed once and then reused, which is what the WebXR
# viewer spends its few seconds doing before a cloud appears. A grid histogram can only
# make a round disc bigger or smaller; a covariance gives it a direction, so a splat on a
# filament lies ALONG the filament instead of straddling it. That is the whole remaining
# difference in look, and it is not reachable per frame at 72Hz.
const BAKE_BLOCK := 256                    # scan block, must match bake_scan.glsl
const BAKE_CHUNK := 32768                  # particles per frame, so nothing stalls
## How far the neighbourhood search reaches, in local spacings. 2.5 gathers roughly twenty
## neighbours on a surface, near enough bulbSplat.ts's k of 14 without a k-th-nearest search.
const BAKE_RADIUS_MUL := 2.5
var _scan_shader: RID
var _scan_pipeline: RID
var _scan_set: RID
var _scatter_shader: RID
var _scatter_pipeline: RID
var _scatter_set: RID
var _shape_shader: RID
var _shape_pipeline: RID
var _shape_set: RID
var _off_buf: RID
var _bsum_buf: RID
var _cursor_buf: RID
var _sorted_buf: RID
var _sorted_cap := 0
var _bake_norm_buf: RID
var _bake_tex: RID
var _bake_texture := Texture2DRD.new()
var _baking := false
var _bake_first := 0
var _bake_centre := Vector3.ZERO
var _bake_extent := 1.0
var _bake_mean := 0.0
var _splat_radius := 0.026
## Progress 0..1 while baking, for the status line. The pause is worth explaining.
var bake_progress := 0.0
var bake_ready := false
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
	_setup_density()
	_setup_bake()
	_ready_ok = true
	return true


func _setup_density() -> void:
	var file: RDShaderFile = load("res://shaders/density.glsl")
	if file == null:
		return
	var spirv := file.get_spirv()
	if spirv.compile_error_compute != "":
		push_error("[cloud] density: %s" % spirv.compile_error_compute)
		return
	_density_shader = _rd.shader_create_from_spirv(spirv)
	_density_pipeline = _rd.compute_pipeline_create(_density_shader)
	_density_buf = _rd.storage_buffer_create(GRID_CELLS * 4, PackedByteArray())

	# The counts have to reach a spatial shader, which cannot read a storage buffer, so
	# they land in a texture instead: the flattened grid laid out row by row.
	var fmt := RDTextureFormat.new()
	fmt.width = GRID_TEX_W
	fmt.height = int(ceil(float(GRID_CELLS) / float(GRID_TEX_W)))
	# FLOAT, not R32_UINT. An integer format needs `usampler2D` in the sampling shader;
	# through the `sampler2D` the splat shader declares, every fetch returned zero and
	# every splat silently took the same fallback size. The counts are written as floats
	# by the norm pass instead, which is both valid and one readback cheaper.
	fmt.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	fmt.usage_bits = (RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT)
	_density_tex = _rd.texture_create(fmt, RDTextureView.new(), [])
	_density_texture.texture_rd_rid = _density_tex
	_splat_material.set_shader_parameter("density_tex", _density_texture)
	_splat_material.set_shader_parameter("density_grid", GRID)

	var img := RDUniform.new()
	img.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	img.binding = 0
	img.add_id(_state_tex)
	var ssbo := RDUniform.new()
	ssbo.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	ssbo.binding = 1
	ssbo.add_id(_density_buf)
	_density_set = _rd.uniform_set_create([img, ssbo], _density_shader, 0)

	var nfile: RDShaderFile = load("res://shaders/density_norm.glsl")
	if nfile == null:
		return
	var nspirv := nfile.get_spirv()
	if nspirv.compile_error_compute != "":
		push_error("[cloud] density_norm: %s" % nspirv.compile_error_compute)
		return
	_norm_shader = _rd.shader_create_from_spirv(nspirv)
	_norm_pipeline = _rd.compute_pipeline_create(_norm_shader)
	_norm_buf = _rd.storage_buffer_create(8, PackedByteArray())
	var nsrc := RDUniform.new()
	nsrc.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	nsrc.binding = 0
	nsrc.add_id(_density_buf)
	var nimg := RDUniform.new()
	nimg.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	nimg.binding = 1
	nimg.add_id(_density_tex)
	var nst := RDUniform.new()
	nst.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	nst.binding = 2
	nst.add_id(_norm_buf)
	_norm_set = _rd.uniform_set_create([nsrc, nimg, nst], _norm_shader, 0)


func _run_density() -> void:
	if not _density_pipeline.is_valid() or not _norm_pipeline.is_valid():
		return
	var extent := maxf(0.2, 1.6 / maxf(0.05, fit))
	_rd.buffer_clear(_density_buf, 0, GRID_CELLS * 4)
	_rd.buffer_clear(_norm_buf, 0, 8)
	var pc := PackedByteArray()
	pc.resize(32)
	pc.encode_s32(0, _count)
	pc.encode_s32(4, tex_size)
	pc.encode_s32(8, GRID)
	pc.encode_float(12, 1.0 / extent)
	pc.encode_float(16, center.x)
	pc.encode_float(20, center.y)
	pc.encode_float(24, center.z)
	pc.encode_float(28, 0.0)
	var npc := PackedByteArray()
	npc.resize(16)
	npc.encode_s32(0, GRID_CELLS)
	npc.encode_s32(4, GRID_TEX_W)
	npc.encode_s32(8, GRID)
	npc.encode_s32(12, 0)
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _density_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _density_set, 0)
	_rd.compute_list_set_push_constant(cl, pc, 32)
	_rd.compute_list_dispatch(cl, int(ceil(float(_count) / 256.0)), 1, 1)
	# Every cell must be counted before any of them is published.
	_rd.compute_list_add_barrier(cl)
	_rd.compute_list_bind_compute_pipeline(cl, _norm_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _norm_set, 0)
	_rd.compute_list_set_push_constant(cl, npc, 16)
	_rd.compute_list_dispatch(cl, int(ceil(float(GRID_CELLS) / 256.0)), 1, 1)
	_rd.compute_list_end()
	_norm_readback = true
	_splat_material.set_shader_parameter("density_extent", extent)
	_splat_material.set_shader_parameter("density_centre", center)


## Read the previous frame's occupancy. A frame late on purpose: by now the GPU is done
## with it, so eight bytes come back without blocking.
func _read_density_norm() -> void:
	var raw := _rd.buffer_get_data(_norm_buf, 0, 8)
	var occupied := raw.decode_u32(0)
	var total := raw.decode_u32(4)
	if occupied == 0 or total == 0:
		return
	density_nominal = maxf(1.0, float(total) / float(occupied))
	_splat_material.set_shader_parameter("density_nominal", density_nominal)


func _compile(path: String, label: String) -> RID:
	var file: RDShaderFile = load(path)
	if file == null:
		push_error("[cloud] %s: missing %s" % [label, path])
		return RID()
	var spirv := file.get_spirv()
	if spirv.compile_error_compute != "":
		push_error("[cloud] %s: %s" % [label, spirv.compile_error_compute])
		return RID()
	return _rd.shader_create_from_spirv(spirv)


func _ssbo(binding: int, buf: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = binding
	u.add_id(buf)
	return u


func _image(binding: int, tex: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u.binding = binding
	u.add_id(tex)
	return u


func _setup_bake() -> void:
	_scan_shader = _compile("res://shaders/bake_scan.glsl", "bake_scan")
	_scatter_shader = _compile("res://shaders/bake_scatter.glsl", "bake_scatter")
	_shape_shader = _compile("res://shaders/bake_shape.glsl", "bake_shape")
	if not (_scan_shader.is_valid() and _scatter_shader.is_valid() and _shape_shader.is_valid()):
		return
	_scan_pipeline = _rd.compute_pipeline_create(_scan_shader)
	_scatter_pipeline = _rd.compute_pipeline_create(_scatter_shader)
	_shape_pipeline = _rd.compute_pipeline_create(_shape_shader)

	_off_buf = _rd.storage_buffer_create(GRID_CELLS * 4, PackedByteArray())
	_cursor_buf = _rd.storage_buffer_create(GRID_CELLS * 4, PackedByteArray())
	_bsum_buf = _rd.storage_buffer_create(int(ceil(float(GRID_CELLS) / float(BAKE_BLOCK))) * 4,
		PackedByteArray())
	_bake_norm_buf = _rd.storage_buffer_create(24, PackedByteArray())

	# RGBA16F, not 32: at 2048^2 the difference is 33MB against 67MB, on top of the two
	# RGBA32F images the cloud already carries. A cosine and two lengths of a few
	# thousandths lose nothing at half precision.
	var fmt := RDTextureFormat.new()
	fmt.width = tex_size
	fmt.height = tex_size
	fmt.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	fmt.usage_bits = (RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT)
	_bake_tex = _rd.texture_create(fmt, RDTextureView.new(), [])
	_bake_texture.texture_rd_rid = _bake_tex
	_splat_material.set_shader_parameter("bake_tex", _bake_texture)

	_scan_set = _rd.uniform_set_create(
		[_ssbo(0, _density_buf), _ssbo(1, _off_buf), _ssbo(2, _bsum_buf)], _scan_shader, 0)


## The sorted list is one slot per particle, so it has to follow the count.
func _ensure_sorted(n: int) -> bool:
	if not _scatter_pipeline.is_valid():
		return false
	if _sorted_cap >= n and _sorted_buf.is_valid():
		return true
	if _sorted_buf.is_valid():
		_rd.free_rid(_sorted_buf)
		_scatter_set = RID()
		_shape_set = RID()
	_sorted_cap = n
	_sorted_buf = _rd.storage_buffer_create(n * 4, PackedByteArray())
	_scatter_set = _rd.uniform_set_create([
		_image(0, _state_tex), _ssbo(1, _off_buf), _ssbo(2, _cursor_buf), _ssbo(3, _sorted_buf),
	], _scatter_shader, 0)
	_shape_set = _rd.uniform_set_create([
		_image(0, _state_tex), _image(1, _normal_tex), _ssbo(2, _density_buf),
		_ssbo(3, _off_buf), _ssbo(4, _sorted_buf), _image(5, _bake_tex),
		_ssbo(6, _bake_norm_buf),
	], _shape_shader, 0)
	return true


## Start a bake of the cloud as it stands. Render thread only.
func bake() -> void:
	if not _ready_ok or not _shape_pipeline.is_valid():
		return
	# A bake needs surface normals: the whole method is a covariance solved in the tangent
	# plane. A flame has no surface, so there is nothing to lie along.
	if source == null or not source.wants_normals():
		return
	if not _ensure_sorted(_count):
		return
	_baking = true
	_bake_first = 0
	bake_progress = 0.0
	bake_ready = false
	_splat_material.set_shader_parameter("use_bake", false)
	# Roomier than the density grid's box. A particle that falls outside gets a fallback
	# size rather than a real neighbourhood, so the box wants to contain the spikes too.
	_bake_extent = maxf(0.2, 2.6 / maxf(0.05, fit))
	_bake_centre = center
	_build_index()


## Count, scan, scatter. One list with barriers: every stage reads what the previous one
## wrote, so they cannot overlap.
func _build_index() -> void:
	var blocks := int(ceil(float(GRID_CELLS) / float(BAKE_BLOCK)))
	_rd.buffer_clear(_density_buf, 0, GRID_CELLS * 4)
	_rd.buffer_clear(_cursor_buf, 0, GRID_CELLS * 4)
	_rd.buffer_clear(_bake_norm_buf, 0, 24)

	var count_pc := PackedByteArray()
	count_pc.resize(32)
	count_pc.encode_s32(0, _count)
	count_pc.encode_s32(4, tex_size)
	count_pc.encode_s32(8, GRID)
	count_pc.encode_float(12, 1.0 / _bake_extent)
	count_pc.encode_float(16, _bake_centre.x)
	count_pc.encode_float(20, _bake_centre.y)
	count_pc.encode_float(24, _bake_centre.z)
	count_pc.encode_float(28, 0.0)

	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _density_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _density_set, 0)
	_rd.compute_list_set_push_constant(cl, count_pc, 32)
	_rd.compute_list_dispatch(cl, int(ceil(float(_count) / 256.0)), 1, 1)
	_rd.compute_list_add_barrier(cl)

	_rd.compute_list_bind_compute_pipeline(cl, _scan_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _scan_set, 0)
	for stage in 3:
		var spc := PackedByteArray()
		spc.resize(16)
		spc.encode_s32(0, GRID_CELLS)
		spc.encode_s32(4, blocks)
		spc.encode_s32(8, stage)
		spc.encode_s32(12, 0)
		_rd.compute_list_set_push_constant(cl, spc, 16)
		# Stage 1 scans the block totals with a single invocation.
		var groups := 1 if stage == 1 else blocks
		_rd.compute_list_dispatch(cl, groups, 1, 1)
		_rd.compute_list_add_barrier(cl)

	_rd.compute_list_bind_compute_pipeline(cl, _scatter_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _scatter_set, 0)
	_rd.compute_list_set_push_constant(cl, count_pc, 32)
	_rd.compute_list_dispatch(cl, int(ceil(float(_count) / 256.0)), 1, 1)
	_rd.compute_list_end()


## One chunk of the shape pass. Spread over frames so the bake never costs a dropped
## frame: a stall in a headset is worse than a wait.
func _bake_step() -> void:
	var pc := PackedByteArray()
	pc.resize(48)
	pc.encode_s32(0, _count)
	pc.encode_s32(4, tex_size)
	pc.encode_s32(8, GRID)
	pc.encode_float(12, _bake_extent)
	pc.encode_float(16, _bake_centre.x)
	pc.encode_float(20, _bake_centre.y)
	pc.encode_float(24, _bake_centre.z)
	pc.encode_float(28, 0.0)
	pc.encode_s32(32, _bake_first)
	pc.encode_s32(36, BAKE_CHUNK)
	pc.encode_float(40, BAKE_RADIUS_MUL)
	pc.encode_float(44, 2.0 * _bake_extent / float(GRID) * 0.3)

	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _shape_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _shape_set, 0)
	_rd.compute_list_set_push_constant(cl, pc, 48)
	_rd.compute_list_dispatch(cl, int(ceil(float(BAKE_CHUNK) / 256.0)), 1, 1)
	_rd.compute_list_end()

	_bake_first += BAKE_CHUNK
	bake_progress = clampf(float(_bake_first) / float(maxi(1, _count)), 0.0, 1.0)
	if _bake_first < _count:
		return

	_baking = false
	# One readback, once, when the whole cloud is done. The mean axis length is what
	# turns the baked sizes (in state units, whatever the fractal happens to span) back
	# into the radius the user asked for.
	var raw := _rd.buffer_get_data(_bake_norm_buf, 0, 24)
	var sum_s := raw.decode_u32(0)
	var n_s := raw.decode_u32(4)
	var n_cov := raw.decode_u32(8)
	var sum_m := raw.decode_u32(12)
	if n_s > 0:
		print("[cloud] bake neighbourhood: %.0f%% solved, %.1f found of %.1f examined, R %.5f" % [
			float(n_cov) / float(n_s) * 100.0, float(sum_m) / float(n_s),
			float(raw.decode_u32(16)) / float(n_s),
			float(raw.decode_u32(20)) / 1048576.0 / float(n_s)])
	if n_s == 0:
		print("[cloud] bake produced no samples; keeping grid sizing")
		return
	_bake_mean = (float(sum_s) / 65536.0) / float(n_s)
	if _bake_mean <= 0.0:
		return
	bake_ready = true
	_apply_bake_scale()
	_splat_material.set_shader_parameter("use_bake", true)
	print("[cloud] baked %d splats, mean axis %.5f" % [_count, _bake_mean])


func _apply_bake_scale() -> void:
	if _bake_mean <= 0.0:
		return
	# The baked lengths are in state units. Dividing by their mean makes them a ratio, so
	# SPLAT still sets the average size and the bake only decides the spread around it.
	_splat_material.set_shader_parameter("bake_scale", _splat_radius / _bake_mean)


func is_baking() -> bool:
	return _baking


## Drop back to the grid-histogram sizing. The bake stays in its texture; only the switch
## moves, so turning it back on is a re-bake and not a reload.
func clear_bake() -> void:
	bake_ready = false
	_splat_material.set_shader_parameter("use_bake", false)


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


func bake_texture_rid() -> RID:
	return _bake_tex


func state_texture_rid() -> RID:
	return _state_tex


func set_source(s: FractalSource) -> bool:
	if not _ready_ok:
		return false
	if source != null:
		source.cleanup()
	source = s
	_splat_material.set_shader_parameter("use_normals", s.wants_normals())
	# A source with normals is a surface; one without is a density field.
	_splat_material.set_shader_parameter("density_exponent", 0.5 if s.wants_normals() else 0.3333)
	clear_bake()
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


## Paint the cloud with a palette that is not the genome's own. Used by RECOLOR, and
## deliberately not written back to the genome: recolouring is a view, not an edit.
func override_palette(pal: Array) -> void:
	for i in mini(5, pal.size()):
		for m in [_material, _splat_material]:
			m.set_shader_parameter("pal%d" % i, pal[i])


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
	_splat_radius = radius
	_splat_material.set_shader_parameter("splat_radius", radius)
	_apply_bake_scale()
	if on == _splat:
		return
	_splat = on
	_mesh_instance.material_override = _splat_material if on else _material
	var n := _count
	_count = 0        # force the rebuild: the vertex count per particle changed
	set_count(n)


## The frame-rate governor's lever: a multiplier on every splat's real size. Fill cost
## falls with its square, which is what makes it strong enough to pull the app back from
## a fill-rate cliff no matter what sizes the user dialled in.
func set_perf_scale(v: float) -> void:
	_splat_material.set_shader_parameter("perf_scale", clampf(v, 0.05, 1.0))


## 0 disables density sizing and every splat takes the global radius.
func set_density_strength(v: float) -> void:
	_splat_material.set_shader_parameter("density_strength", clampf(v, 0.0, 1.0))


func set_opacity(a: float) -> void:
	_splat_material.set_shader_parameter("splat_opacity", clampf(a, 0.02, 1.0))


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
	if _norm_readback:
		_norm_readback = false
		_read_density_norm()
	if _measure_pending and _measure_pipeline.is_valid():
		_measure_pending = false
		_dispatch_measure()
		_measure_readback = true
		# Density rides along with the measure: same cadence, same reason. A finished
		# bake owns the sizing outright, so skip the grid entirely while one is live.
		if _splat and not bake_ready:
			_run_density()

	if _baking:
		_bake_step()

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
	var occupied := 0
	for i in HIST_BINS:
		var c := float(raw.decode_u32((8 + i) * 4))
		if c > 0.0:
			occupied += 1
		acc += c
		cdf[i] = acc / total
	# The CDF itself no longer reaches the shaders: equalisation was replaced by the
	# measured mean/spread mapping, which reads better. The histogram stays because this
	# diagnostic is how a "one colour whatever the palette says" report gets triaged.
	# If the palette coordinate lands in only a handful of bins, equalisation has almost
	# nothing to spread and the cloud comes out one colour whatever the palette says.
	# Worth knowing which of those two it is before blaming the palette.
	print("[cloud] colour: %d/%d bins used, cdf31=%.2f, raw bytes=%d" % [
		occupied, HIST_BINS, cdf[HIST_BINS - 1], raw.size()])


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
	if _rd != null:
		_state_texture.texture_rd_rid = RID()
		_normal_texture.texture_rd_rid = RID()
		_density_texture.texture_rd_rid = RID()
		# Pipelines and uniform sets are dependents of these and are freed with them.
		for rid: RID in [
			_state_tex, _normal_tex, _measure_shader, _stats_buf,
			_density_shader, _density_buf, _density_tex, _norm_shader, _norm_buf,
			_scan_shader, _scatter_shader, _shape_shader,
			_off_buf, _bsum_buf, _cursor_buf, _sorted_buf, _bake_norm_buf, _bake_tex,
		]:
			if rid.is_valid():
				_rd.free_rid(rid)
	_ready_ok = false
