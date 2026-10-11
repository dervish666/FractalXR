extends RefCounted
class_name FlameSky

## FLAME SKY: the current flame baked once into an HDR equirect and hung as the sky behind
## every mode: GROUND, TREE, IFS, the live flame itself (bake flame A, show flame B in front of
## it), and BULB on a switch of its own. Baked once and then static, so nothing in it moves or shimmers; a sky
## at infinity is a fixed reference, which is a comfort aid rather than a cost.
##
## THE BAKE. From the flame's centre, so the sky is the flame seen from inside it. 65,536
## walkers are copied from the live cloud's first rows and stepped by the unchanged chaos.glsl
## through a FlameSource snapshot of their own (the live cloud is never touched, frozen or
## not), and after each step sky_splat.glsl adds every walker's colour into an accumulator by
## direction. `samples` splats in all, a fixed slice per frame, then sky_resolve.glsl turns the
## sums into flam3 log-density in an RGBA16F texture and the accumulator is freed.
##
## WHY IT CANNOT RENDER THROUGH THE STEREO CAMERA. The web build switched renderer.xr off
## around its compute pass because three.js would otherwise draw the simulation through the XR
## ArrayCamera. Here there is nothing to switch: the bake is RenderingDevice dispatches
## recorded from call_on_render_thread, exactly as ParticleCloud.iterate() is, and no Viewport
## or Camera3D takes part. In Godot the hijack would come from rendering: the root viewport has
## use_xr and draws through XRCamera3D. A raster bake would have needed a SubViewport with
## use_xr false and its own Camera3D, and the XR camera's cull mask kept off the bake's layer.
## The compute bake needs neither, and it can also accumulate over many frames, which a
## one-frame raster could not (65k points spread over the whole sphere read as dust).
##
## COST. The atomics are the price: the README measured 707,788 atomic splats at 36.6 ms on
## Adreno. ROUNDS_PER_FRAME * 65,536 = 131,072 splats a frame is about a fifth of that, so a
## guess of 5-7 ms a frame on the headset, once per bake. The bake runs a fixed slice a frame,
## so on the headset it lasts frames / 72 seconds whatever the GPU: tools/sky_bake.sh measure
## counts the frames at each SKY RES. Steady state is one texture fetch per background pixel.
## Memory, the RGBA16F sky and the accumulator (3 x u32 a texel, while baking only):
## 25 + 38 MiB at 2560, 64 + 96 at 4096, 144 + 216 at 6144 (README, "The sky's resolution").
##
## PRESETS. art/skies/ holds skies baked offline on the Mac through this same bake (8192 wide,
## many times the samples) and resampled to compressed cubemaps by tools/sky_cube.py: sharper
## and cleaner than the live bake, no wait and no stutter, and there in BULB before any flame
## has been baked. Their colours are baked in. SKY PICK steps live / the presets.

## Equirect width of the live bake, by the SKY RES step; the height is half. 2560 across is 7.1
## texels a degree against the eye buffer's 17-21 pixels a degree, and Sam asked for it
## sharper; 4096 is 11.4; 6144 is 17.1, about a texel a pixel, as far as a sky without mipmaps
## should go (past it the sky is minified and sparkles).
const RES_STEPS := [2560, 4096, 6144]
const RES_NAMES := ["2.5k", "4k", "6k"]
const RES_DEFAULT := 1
## Walkers: this many rows of the cloud's state image (2048 wide): 65,536 of them.
const WALKER_ROWS := 32
## Chaos steps per frame, each followed by a splat of every walker.
const ROUNDS_PER_FRAME := 2
## Steps before the first splat, so walkers copied from a cloud that was still settling have
## reached this genome's attractor first.
const FUSE_ROUNDS := 12
## About 7.7 splats per texel on average (the first sky's 24M over 2560 x 1280); the flame
## covers the sphere unevenly, so the dense half gets many more. Held per texel rather than in
## total: resolution without samples is only finer grain.
const SAMPLES_PER_TEXEL := 24.0 * 1024.0 * 1024.0 / (2560.0 * 1280.0)
const FIXED := 1024.0
## A row near the pole averages at most this many texels. A row wants 1/cos(latitude) of them
## to cover the solid angle of a texel at the equator; past the cap the rows round the pole
## each hold a narrow sliver of samples, and within 0.9 degrees of the zenith there is a faint
## pinwheel (seen at 2560 with the sky brightened 5x, barely at 4096). 256 shrinks it to 0.22
## degrees and made the resolve frame at 6144 9.8 ms on the Mac against 8.0: not worth it.
## The SKY PICK presets are cubemaps and have no pole.
const MAX_TAPS := 64
## The curve. Relative density 1.0 is the flame spread evenly over the sphere. Picked from a
## desktop sweep in TREE (seven curves over one bake): the first try (0.35, 1.0, gamma 1.6) lit
## the whole sky at 0.35 mean and drowned the tree; a low K2 keeps dark gaps between luminous
## structure, mean about 0.1 of white, so the sky sits behind whatever stands in front of it.
const EXPOSURE := 0.28
const K2 := 0.25
const GAMMA := 1.0
const HI_DESAT := 0.3
## Walkers closer than this to the centre (state units) have no direction worth keeping.
const MIN_R := 0.002
## The sky comes up over this long once it is shown, rather than snapping in at the edges.
const FADE_S := 2.0

## The live bake's size and sample count, from set_width(). Read when a bake starts, so a
## change takes effect at the next bake.
var width := 4096
var height := 2048
var samples := 0
## Chaos steps a frame. The offline bake (tools/sky_bake.sh) raises it; the headset does not.
var rounds_per_frame := ROUNDS_PER_FRAME

## Pre-rendered skies, from art/skies/skies.json: [{name, path, gain}]. pick 0 is the live
## bake, pick i > 0 is presets[i - 1].
const PRESET_DIR := "res://art/skies/"
var presets: Array = []
var pick := 0
## An imported cube is a CompressedCubemap, which is a TextureLayered and not a Cubemap.
var _cube: TextureLayered = null

## Main-thread readable state.
var baking := false
var progress := 0.0
var ready := false
var baked_name := ""
## GPU microseconds of the last bake frame, from timestamps. 0 until one has been read.
var bake_us := 0.0
## The curve, from the constants above. Variables so the tuning harness can try others.
var exposure := EXPOSURE
var k2 := K2
var gamma := GAMMA
## Tuning only: the resolve leaves the sums allocated, so resolve_again() can try another
## curve on the same bake. Never set in the app: it holds the 39 MB accumulator.
var keep_accumulator := false

var _rd: RenderingDevice
var _gpu_tried := false
var _gpu_ok := false
var _splat_shader: RID
var _splat_pipeline: RID
var _resolve_shader: RID
var _resolve_pipeline: RID
var _walk_tex: RID
var _pal_buf: RID
var _acc_buf: RID
var _splat_set: RID
var _sky_tex: RID
var _sky_texture := Texture2DRD.new()
var _src: FlameSource = null
var _push := PackedByteArray()
var _walkers := 0
var _row_w := 0
## The size of the bake in flight, fixed at _begin so a SKY RES step mid-bake cannot tear it,
## and the size of the texture on show.
var _bw := 0
var _bh := 0
var _bs := 0
var _tex_w := 0
var _tex_h := 0
## Frames left to read timestamps after a bake ends.
var _tail := 0
var _round := 0
var _splatted := 0

var _env: Environment
var _sky := Sky.new()
var _mat := ShaderMaterial.new()
var _shown := false
var _fade := 1.0
var _saved_ambient := Environment.AMBIENT_SOURCE_BG
var _saved_reflect := Environment.REFLECTION_SOURCE_BG
var _saved_energy := 1.0


func _init() -> void:
	_mat.shader = load("res://shaders/flame_sky.gdshader")
	_mat.set_shader_parameter(&"flame_sky", _sky_texture)
	_sky.sky_material = _mat
	# Nothing here is lit (every material in the app is unshaded), so the radiance map is
	# never read. Smallest size and a one-shot process keep its one-time cost down.
	_sky.radiance_size = Sky.RADIANCE_SIZE_32
	_sky.process_mode = Sky.PROCESS_MODE_QUALITY
	set_width(RES_STEPS[RES_DEFAULT])
	_load_presets()


## The live bake's equirect width; the height is half and the samples scale with the texels.
func set_width(w: int) -> void:
	width = maxi(256, w)
	height = width / 2
	samples = int(SAMPLES_PER_TEXEL * float(width) * float(height))


func _load_presets() -> void:
	var f := FileAccess.open(PRESET_DIR + "skies.json", FileAccess.READ)
	if f == null:
		push_warning("[sky] no %sskies.json; SKY PICK has only the live bake" % PRESET_DIR)
		return
	var parsed = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_ARRAY:
		push_warning("[sky] %sskies.json is not a list; no presets" % PRESET_DIR)
		return
	for e in parsed:
		if typeof(e) == TYPE_DICTIONARY and ResourceLoader.exists(PRESET_DIR + str(e.get("file", ""))):
			presets.append({"name": str(e.get("name", "?")), "path": PRESET_DIR + str(e["file"]),
				"gain": float(e.get("gain", 1.0))})
		else:
			push_warning("[sky] preset %s is listed but not imported" % str(e))


## What SKY PICK shows: "live" or the preset's name.
func pick_name() -> String:
	return "live" if pick == 0 else str(presets[pick - 1]["name"])


## Choose the live bake (0) or a preset (1..). A preset loads on demand and the previous one is
## dropped, so only the sky on show holds memory. It fades in again when it changes on screen.
func set_pick(i: int) -> void:
	i = wrapi(i, 0, presets.size() + 1)
	if i == pick:
		return
	pick = i
	_cube = null
	if pick > 0:
		_cube = load(presets[pick - 1]["path"]) as TextureLayered
		# An image imported as a plain texture or an array would bind as garbage, silently.
		if _cube != null and _cube.get_layered_type() != TextureLayered.LAYERED_TYPE_CUBEMAP:
			_cube = null
		if _cube == null:
			push_error("[sky] could not load %s" % presets[pick - 1]["path"])
			pick = 0
	_mat.set_shader_parameter(&"sky_cube", _cube)
	_mat.set_shader_parameter(&"use_cube", _cube != null)
	_mat.set_shader_parameter(&"cube_gain", float(presets[pick - 1]["gain"]) if pick > 0 else 1.0)
	if _shown:
		_fade = 0.0


## True when there is something to hang: a preset, or a finished live bake.
func has_sky() -> bool:
	return _cube != null or ready


func setup(env: Environment) -> void:
	_env = env


func is_shown() -> bool:
	return _shown


## Start a bake of whatever flame the cloud holds, in the palette it is wearing. Main thread.
## False when the cloud holds no flame (a bulb), which leaves any earlier sky alone.
func request_bake(cloud: ParticleCloud, pal: Array, cycles: float) -> bool:
	var flame := cloud.source as FlameSource
	if flame == null or not cloud.is_ready():
		return false
	var src := flame.snapshot()
	src.iterations = 1
	src.update_mod = 1
	src.reseed_prob = 0.0
	baking = true
	progress = 0.0
	baked_name = src.display_name
	RenderingServer.call_on_render_thread(_begin.bind(src, cloud.state_texture_rid(),
		cloud.tex_size, cloud.target_center, cloud.global_transform.basis.orthonormalized(),
		pal.duplicate(), cycles))
	return true


## Once a frame from the host, in every mode. Steps a bake in flight and shows or hides the
## sky. `want` is the host's whole rule (sky on, a mode that hangs it, no passthrough).
func sync(want: bool, delta: float) -> void:
	if baking or _tail > 0:
		RenderingServer.call_on_render_thread(_step)
	var show := want and has_sky() and _env != null
	if show != _shown:
		_set_shown(show)
	if _shown and _fade < 1.0:
		_fade = minf(1.0, _fade + delta / FADE_S)
		_env.background_energy_multiplier = _saved_energy * smoothstep(0.0, 1.0, _fade)


func _set_shown(on: bool) -> void:
	_shown = on
	if on:
		_saved_ambient = _env.ambient_light_source
		_saved_reflect = _env.reflected_light_source
		_saved_energy = _env.background_energy_multiplier
		_env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
		_env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
		_env.sky = _sky
		_env.background_mode = Environment.BG_SKY
		_fade = 0.0
		_env.background_energy_multiplier = 0.0
	else:
		# Back to the plain colour, whatever passthrough has set it to meanwhile.
		_env.background_mode = Environment.BG_COLOR
		_env.sky = null
		_env.background_energy_multiplier = _saved_energy
		_env.ambient_light_source = _saved_ambient
		_env.reflected_light_source = _saved_reflect
		_fade = 1.0


# --- render thread -----------------------------------------------------------

func _ensure_gpu() -> bool:
	if _gpu_tried:
		return _gpu_ok
	_gpu_tried = true
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		push_error("[sky] no RenderingDevice")
		return false
	_splat_shader = _compile("res://shaders/sky_splat.glsl")
	_resolve_shader = _compile("res://shaders/sky_resolve.glsl")
	if not (_splat_shader.is_valid() and _resolve_shader.is_valid()):
		return false
	_splat_pipeline = _rd.compute_pipeline_create(_splat_shader)
	_resolve_pipeline = _rd.compute_pipeline_create(_resolve_shader)
	_pal_buf = _rd.storage_buffer_create(80)
	_gpu_ok = _pal_buf.is_valid()
	if not _gpu_ok:
		push_error("[sky] palette buffer creation failed")
	return _gpu_ok


## The sky texture at the bake's size: made at the first resolve, remade when SKY RES has
## changed. The old one is freed after the material points at the new one, and the device
## destroys it once this frame's work is done.
func _ensure_sky_tex() -> bool:
	if _sky_tex.is_valid() and _tex_w == _bw and _tex_h == _bh:
		return true
	var fmt := RDTextureFormat.new()
	fmt.width = _bw
	fmt.height = _bh
	fmt.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	# CAN_COPY_FROM so the shot harness and the offline bake can read the sky back whole.
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	var tex := _rd.texture_create(fmt, RDTextureView.new(), [])
	if not tex.is_valid():
		push_error("[sky] %dx%d texture creation failed" % [_bw, _bh])
		return false
	var old := _sky_tex
	_sky_tex = tex
	_tex_w = _bw
	_tex_h = _bh
	_sky_texture.texture_rd_rid = _sky_tex
	if old.is_valid():
		_rd.free_rid(old)
	return true


## Render thread: the live sky's RenderingDevice texture, for anything that reads it back.
func sky_texture_rid() -> RID:
	return _sky_tex


## The live sky texture's size as it stands; zero before the first bake.
func texture_size() -> Vector2i:
	return Vector2i(_tex_w, _tex_h)


func _compile(path: String) -> RID:
	var file: RDShaderFile = load(path)
	if file == null:
		push_error("[sky] missing %s" % path)
		return RID()
	var spirv := file.get_spirv()
	if spirv.compile_error_compute != "":
		push_error("[sky] %s: %s" % [path, spirv.compile_error_compute])
		return RID()
	return _rd.shader_create_from_spirv(spirv)


func _begin(src: FlameSource, state: RID, tex_size: int, centre: Vector3, rot: Basis,
		pal: Array, cycles: float) -> void:
	if not _ensure_gpu() or not state.is_valid():
		baking = false
		return
	if _src != null:
		_src.cleanup()
	_src = src
	if _walk_tex.is_valid() and _row_w != tex_size:
		_rd.free_rid(_walk_tex)
		_walk_tex = RID()
	_row_w = tex_size
	_walkers = _row_w * WALKER_ROWS
	if not _walk_tex.is_valid():
		var fmt := RDTextureFormat.new()
		fmt.width = _row_w
		fmt.height = WALKER_ROWS
		fmt.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
		fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
		_walk_tex = _rd.texture_create(fmt, RDTextureView.new(), [])
	_rd.texture_copy(state, _walk_tex, Vector3.ZERO, Vector3.ZERO,
		Vector3(_row_w, WALKER_ROWS, 1), 0, 0, 0, 0)
	if not _src.setup(_rd, _walk_tex, _row_w):
		push_error("[sky] %s" % _src.get_error())
		baking = false
		return

	var pf := PackedFloat32Array()
	pf.resize(20)
	for i in 5:
		var c: Vector3 = pal[i] if i < pal.size() else Vector3.ONE
		pf[i * 4] = c.x
		pf[i * 4 + 1] = c.y
		pf[i * 4 + 2] = c.z
	_rd.buffer_update(_pal_buf, 0, 80, pf.to_byte_array())

	# A bake restarted mid-flight drops the old sums with their buffer; the set goes with it.
	if _acc_buf.is_valid():
		_rd.free_rid(_acc_buf)
	_bw = width
	_bh = height
	_bs = samples
	_acc_buf = _rd.storage_buffer_create(_bw * _bh * 3 * 4)
	if not _acc_buf.is_valid():
		push_error("[sky] the %d MB accumulator was refused" % (_bw * _bh * 12 / 1048576))
		baking = false
		return
	_rd.buffer_clear(_acc_buf, 0, _bw * _bh * 3 * 4)
	var uw := RDUniform.new()
	uw.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uw.binding = 0
	uw.add_id(_walk_tex)
	_splat_set = _rd.uniform_set_create([uw, _ssbo(1, _acc_buf), _ssbo(2, _pal_buf)], _splat_shader, 0)

	_push.resize(96)
	for r in 3:
		# Rows of the rotation: Basis columns are its axes.
		_push.encode_float(r * 16, rot.x[r])
		_push.encode_float(r * 16 + 4, rot.y[r])
		_push.encode_float(r * 16 + 8, rot.z[r])
		_push.encode_float(r * 16 + 12, 0.0)
	_push.encode_float(48, centre.x)
	_push.encode_float(52, centre.y)
	_push.encode_float(56, centre.z)
	_push.encode_float(60, cycles)
	_push.encode_s32(64, _bw)
	_push.encode_s32(68, _bh)
	_push.encode_s32(72, _walkers)
	_push.encode_s32(76, _row_w)
	_push.encode_float(80, FIXED)
	_push.encode_float(84, MIN_R * MIN_R)
	_push.encode_float(88, 0.0)
	_push.encode_float(92, 0.0)
	_round = 0
	_splatted = 0


func _ssbo(binding: int, buf: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = binding
	u.add_id(buf)
	return u


func _step() -> void:
	if not baking:
		# A few frames on, so the resolve frame's own timestamps are read too.
		_tail -= 1
		_read_timestamp()
		return
	if _src == null or not _acc_buf.is_valid():
		return
	_read_timestamp()
	_rd.capture_timestamp("sky_begin")
	var groups := int(ceil(float(_walkers) / 256.0))
	var cl := _rd.compute_list_begin()
	for r in rounds_per_frame:
		_src.encode(cl, _walkers, _round + 1, false)
		_rd.compute_list_add_barrier(cl)
		if _round >= FUSE_ROUNDS:
			_rd.compute_list_bind_compute_pipeline(cl, _splat_pipeline)
			_rd.compute_list_bind_uniform_set(cl, _splat_set, 0)
			_rd.compute_list_set_push_constant(cl, _push, _push.size())
			_rd.compute_list_dispatch(cl, groups, 1, 1)
			_rd.compute_list_add_barrier(cl)
			_splatted += _walkers
		_round += 1
	_rd.compute_list_end()
	if _splatted >= _bs:
		_resolve()
	_rd.capture_timestamp("sky_end")
	progress = clampf(float(_splatted) / float(maxi(1, _bs)), 0.0, 1.0)


func _resolve() -> void:
	if not _ensure_sky_tex():
		_rd.free_rid(_acc_buf)
		_acc_buf = RID()
		_src.cleanup()
		_src = null
		baking = false
		return
	_resolve_pass()
	if not keep_accumulator:
		# Freed now, destroyed by the device once this frame's work is done; both sets go with it.
		_rd.free_rid(_acc_buf)
		_acc_buf = RID()
	_src.cleanup()
	_src = null
	baking = false
	ready = true
	_tail = 4
	print("[sky] baked %s: %d splats over %d rounds" % [baked_name, _splatted, _round])


## Tuning only, render thread: the same sums through the current curve.
func resolve_again() -> void:
	if _acc_buf.is_valid() and not baking:
		_resolve_pass()


func _resolve_pass() -> void:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u.binding = 1
	u.add_id(_sky_tex)
	var set := _rd.uniform_set_create([_ssbo(0, _acc_buf), u], _resolve_shader, 0)
	var pc := PackedByteArray()
	pc.resize(48)
	pc.encode_s32(0, _bw)
	pc.encode_s32(4, _bh)
	pc.encode_s32(8, MAX_TAPS)
	pc.encode_s32(12, 0)
	pc.encode_float(16, exposure)
	pc.encode_float(20, k2)
	pc.encode_float(24, gamma)
	pc.encode_float(28, HI_DESAT)
	pc.encode_float(32, 1.0 / FIXED)
	pc.encode_float(36, float(_splatted))
	pc.encode_float(40, 0.0)
	pc.encode_float(44, 0.0)
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _resolve_pipeline)
	_rd.compute_list_bind_uniform_set(cl, set, 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, int(ceil(_bw / 8.0)), int(ceil(_bh / 8.0)), 1)
	_rd.compute_list_end()
	# The set is a dependent of the accumulator and would go with it; a re-resolve makes its own.
	_rd.free_rid(set)


func _read_timestamp() -> void:
	var n := _rd.get_captured_timestamps_count()
	var b := -1.0
	var e := -1.0
	for i in n:
		match _rd.get_captured_timestamp_name(i):
			"sky_begin": b = float(_rd.get_captured_timestamp_gpu_time(i)) / 1000.0
			"sky_end": e = float(_rd.get_captured_timestamp_gpu_time(i)) / 1000.0
	if b >= 0.0 and e >= b:
		bake_us = e - b


## Render thread, once, at exit.
func cleanup() -> void:
	if _rd == null:
		return
	_sky_texture.texture_rd_rid = RID()
	if _src != null:
		_src.cleanup()
		_src = null
	for rid: RID in [_splat_shader, _resolve_shader, _walk_tex, _pal_buf, _acc_buf, _sky_tex]:
		if rid.is_valid():
			_rd.free_rid(rid)
	_gpu_ok = false
