extends RefCounted
class_name MandelSky

## MANDEL SKY: GROUND's escape-time family over the whole sky, a SKY PICK entry next to the
## flame bake and the presets. The plane sits on the Riemann sphere: stereographic projection
## from the nadir puts the view's centre at the zenith, the escape bands ringing out to the
## horizon and the point at infinity under your feet. Each family opens with the whole set
## overhead (HOMES); point above the horizon and hold a trigger to zoom the sky about the spot
## you aim at, right in, left out. X (HOME) puts it back with the ground.
##
## WHY A FILL AND NOT A SKY SHADER THAT ITERATES. Per-pixel escape over the ground's near
## field (NEAR) took the Quest to 9-12 fps; a whole sky of it would be worse, and the sky
## would shimmer with every head turn. So mandel_sky.glsl fills a flat square of the plane
## (q in [-HALF_W, HALF_W]^2, c = centre + r q) a slice of rows a frame, and the sky shader
## does one fetch a pixel. Steady state costs what the flame sky costs.
##
## ZOOMING. The view on show (_cx, _cy, _r) moves every frame a trigger is held; the data
## stays what it was filled for, and the shader stretches it to the view (off, k) until a fill
## for the new view lands. Two slots: one on show, one filling. A full 3k fill takes seconds
## on the Quest, and a held zoom at 3.3x a second stretched the last one 10-30x before the
## next landed: mud. So while the view moves the fill runs at move_res into the corner of the
## slot (fill_frac), short enough to land every few frames, and a full-res fill starts once it
## is still. A moving fill is never restarted (a held zoom would never land one); a full-res
## fill in flight is dropped as soon as the view moves again.
##
## LIMITS (a spike). Float32 only, so the zoom stops at R_MIN, about 1000x, where a texel
## nears float32's grid. Past the filled square (below the horizon, or the rim during a zoom
## out) the shader draws a flat far-exterior colour. JULIA on the ground hides the marker:
## the floor's points are z0 there, not c.
##
## SPHERE (GROUND's lower-sphere floor). The floor's rim fades into this sky's colour on the
## horizon at the same azimuth, so the two hemispheres meet with no band. tick() copies the
## data on show and the view into the ground's material for that (_feed_rim) and changes
## nothing on the sky itself, so no SPHERE state reaches the sky in another mode.

const RES_STEPS := [2048, 3072, 4096]
const RES_NAMES := ["2k", "3k", "4k"]
const RES_DEFAULT := 1
## The filled square's half width in stereographic units: 1.0 reaches the horizon at the
## edges' midpoints and 19.5 degrees below it in the corners.
const HALF_W := 1.0
## Each family's opening view, indexed like FractalGround.FORMULA_NAMES: (cx, cy, r). r is
## fractal units per stereographic unit; the set's far edge lands about |w| = 0.64, 25 to 30
## degrees above the horizon, so it reads looking ahead and up rather than straight up.
const HOMES := [
	Vector3(-0.75, 0.0, 2.0),     # mandelbrot
	Vector3(-0.45, -0.5, 2.9),    # burning ship
	Vector3(-0.3, 0.0, 2.9),      # tricorn
	Vector3(-0.3, 0.0, 3.0),      # celtic
	Vector3(-0.4, 0.0, 3.0),      # perpendicular
	Vector3(-0.3, 0.0, 3.0),      # buffalo
	Vector3(0.0, 0.0, 2.4),       # cubic
	Vector3(-0.1, 0.0, 2.2),      # quartic
]
## float32's floor: a texel at 3k is r * 6.5e-4 fractal units, and past about 1e-6 neighbours
## round to the same c. 2e-3 keeps a few float32 steps a texel near |c| = 2.
const R_MIN := 2.0e-3
const R_MAX := 8.0
## e-folds a second with the trigger fully in: 1.2 is 3.3x a second. Slow on purpose: the
## whole sky streaming past is optic flow on every side.
const ZOOM_RATE := 1.2
## GPU time a frame for the fill where timestamps exist (the Quest); Metal has none, so the
## Mac fills ROWS_NO_TIMER full-res rows' worth of texels a frame.
const BUDGET_US := 2500.0
const ROWS_START := 64
const ROWS_NO_TIMER := 128
## Fill resolution while the view moves, stepped by how long the last one took to land.
const MOVE_RES := [512, 768, 1024, 1536]
const MOVE_RES_DEFAULT := 2
const MOVE_FRAMES_SLOW := 18
const MOVE_FRAMES_FAST := 6
## How long after the last zoom step the view still counts as moving.
const MOVE_HOLD_MS := 200
## MANDEL SKY tile: how bright the sky stands against the floor.
const GAINS := [0.25, 0.4, 0.6, 0.85, 1.2]
const GAIN_DEFAULT := 2
## mandel_sky.gdshader's dusk and floor_keep (never set from here), and what the floor dimming
## leaves at d.y = 0: mix(floor_keep, 1, smoothstep(-0.35, 0.05, 0)). _feed_rim passes them on.
const DUSK := 0.2
const FLOOR_KEEP := 0.12
var _horizon_keep := lerpf(FLOOR_KEEP, 1.0, smoothstep(-0.35, 0.05, 0.0))
var _rim_front := -1
var _rim_mat: ShaderMaterial

var sky := Sky.new()
var res: int = RES_STEPS[RES_DEFAULT]
var gain_idx := GAIN_DEFAULT
## 0..1 progress of the fill in flight; 1 when none is.
var progress := 1.0
## GPU microseconds of the last slice, from timestamps; 0 where there are none.
var fill_us := 0.0
## How far the view is from home, for the status line.
var zoom := 1.0
## The ground's ITER: the sky's iteration count never drops below it.
var iter_floor := 256

var _mat := ShaderMaterial.new()
var _tex: Array[Texture2DRD] = [Texture2DRD.new(), Texture2DRD.new()]
## Render thread owns these two; the main thread only reads _front and the params.
var _rid: Array[RID] = [RID(), RID()]
var _rid_n := [0, 0]
var _set: Array[RID] = [RID(), RID()]
## The slot on show (-1 before the first fill lands) and the view it was filled for.
var _front := -1
var _front_p := {}
var _fill_p := {}
var _fill_slot := 0
var _filling := false
var _fill_row := 0
var _rows := ROWS_START
var _texels := float(ROWS_START * 3072)
var _formula := -1
var _move_idx := MOVE_RES_DEFAULT
var _moved_ms := -100000
## Frames and GPU time of the fill in flight, for the [msky] line when it lands.
var _fill_frames := 0
var _fill_gpu_us := 0.0

## The view on show, in GDScript's 64-bit floats.
var _cx := -0.75
var _cy := 0.0
var _r := 2.0

var _rd: RenderingDevice
var _gpu_tried := false
var _gpu_ok := false
var _shader: RID
var _pipeline: RID


func _init() -> void:
	_mat.shader = load("res://shaders/mandel_sky.gdshader")
	_mat.set_shader_parameter(&"half_w", HALF_W)
	_mat.set_shader_parameter(&"gain", GAINS[gain_idx])
	sky.sky_material = _mat
	# The shader returns black in the cubemap pass, so the radiance map costs next to nothing.
	sky.radiance_size = Sky.RADIANCE_SIZE_32
	sky.process_mode = Sky.PROCESS_MODE_QUALITY
	home()


func has_data() -> bool:
	return _front >= 0


## Back to the current family's whole set overhead.
func home() -> void:
	var h: Vector3 = HOMES[clampi(maxi(_formula, 0), 0, HOMES.size() - 1)]
	_cx = h.x
	_cy = h.y
	_r = h.z


func step_gain(d: int) -> void:
	gain_idx = wrapi(gain_idx + d, 0, GAINS.size())
	_mat.set_shader_parameter(&"gain", GAINS[gain_idx])


func gain_name() -> String:
	return "%.2fx" % GAINS[gain_idx]


## The theme, as the ground wears it; the filled interior is lifted as FractalGround lifts it.
func set_palette(pal: Array) -> void:
	for i in mini(5, pal.size()):
		_mat.set_shader_parameter(StringName("pal%d" % i), pal[i])
	if pal.size() >= 2:
		var c: Vector3 = (pal[0] as Vector3).lerp(pal[1] as Vector3, 0.35)
		_mat.set_shader_parameter(&"inside_colour",
			Color(maxf(c.x, 0.055), maxf(c.y, 0.06), maxf(c.z, 0.085)))


## Zoom about the sky point in world direction `dir`: it stays where it is and the rest
## streams toward it (rate > 0) or away (rate < 0). `rate` is e-folds a second.
func zoom_toward(dir: Vector3, rate: float, delta: float, m: Transform2D) -> void:
	var w := Vector2(dir.x, dir.z) / maxf(1.0 + dir.y, 1e-3)
	var u := m.x * w.x + m.y * w.y
	var ax := _cx + _r * u.x
	var ay := _cy + _r * u.y
	var nr := clampf(_r * exp(-rate * delta), R_MIN, R_MAX)
	_cx = ax - nr * u.x
	_cy = ay - nr * u.y
	_r = nr
	_moved_ms = Time.get_ticks_msec()


func is_moving() -> bool:
	return Time.get_ticks_msec() - _moved_ms < MOVE_HOLD_MS


## Once a frame from the host. `active`: the sky is picked and wanted (fills only run then).
## `here`: draw the marker at the fractal point under your feet.
func tick(ground: FractalGround, active: bool, here: bool) -> void:
	if not active:
		return
	if ground.formula != _formula:
		_formula = ground.formula
		home()
	var gm: ShaderMaterial = ground._material
	if gm != null:
		for p: StringName in [&"colour_freq", &"colour_offset", &"palette_cycles", &"texture_strength"]:
			_mat.set_shader_parameter(p, gm.get_shader_parameter(p))
	var h: Vector3 = HOMES[_formula]
	zoom = h.z / _r
	iter_floor = ground.max_iter

	# A fill whose last slice was queued last frame has landed: put it on show.
	if _filling and _fill_row >= int(_fill_p["n"]):
		_filling = false
		_front = _fill_slot
		_front_p = _fill_p
		_mat.set_shader_parameter(&"sky_data", _tex[_front])
		_mat.set_shader_parameter(&"has_data", true)
		_mat.set_shader_parameter(&"fill_frac", float(_front_p["n"]) / float(res))
		_landed()
	var want := _want()
	# A full-res fill for a view the trigger has since left: drop it, the moving fill is due.
	if _filling and int(_fill_p["n"]) == res and int(want["n"]) < res:
		_filling = false
	if not _filling and want != _front_p:
		_fill_p = want
		_fill_slot = 1 - _front if _front >= 0 else 0
		_fill_row = 0
		_fill_frames = 0
		_fill_gpu_us = 0.0
		_filling = true
	if _filling:
		var n: int = _fill_p["n"]
		_fill_frames += 1
		_fill_gpu_us += fill_us
		# The budget is in texels, so it carries across a change of fill resolution.
		if fill_us > 0.0:
			if fill_us > BUDGET_US * 1.2:
				_texels = maxf(16.0 * 512.0, _texels * 0.7)
			elif fill_us < BUDGET_US * 0.6:
				_texels = minf(float(res * res), _texels * 1.3)
		else:
			_texels = float(ROWS_NO_TIMER * res)
		_rows = clampi(int(_texels / n) / 16 * 16, 16, n)
		var rows := mini(_rows, n - _fill_row)
		RenderingServer.call_on_render_thread(_dispatch.bind(_fill_slot, res, n, _push(_fill_p, _fill_row), rows))
		_fill_row += rows
		progress = float(_fill_row) / float(n)
	else:
		progress = 1.0

	if _front >= 0:
		var fr: float = _front_p["r"]
		_mat.set_shader_parameter(&"off", Vector2((_cx - float(_front_p["x"])) / fr,
			(_cy - float(_front_p["y"])) / fr))
		_mat.set_shader_parameter(&"k", _r / fr)
		_mat.set_shader_parameter(&"data_r", fr)
	var m: Transform2D = ground._m
	_mat.set_shader_parameter(&"rot", Vector4(m.x.x, m.x.y, m.y.x, m.y.y))
	if here and ground.sphere_radius > 0.0:
		_feed_rim(ground)
	var on := here and not ground.julia
	_mat.set_shader_parameter(&"here_on", 1.0 if on else 0.0)
	if on:
		var u := Vector2((ground.viewer_fx() - _cx) / _r, (ground.viewer_fy() - _cy) / _r)
		var w := Vector2(m.x.dot(u), m.y.dot(u))
		var r2 := w.length_squared()
		_mat.set_shader_parameter(&"here_dir",
			Vector3(2.0 * w.x, 1.0 - r2, 2.0 * w.y) / (1.0 + r2))


## For SPHERE, the sky on show goes to ground.gdshader's sky_rim_colour(). The texture goes
## only when the slot on show changes; the view and tone go every frame, as the sky's own do.
func _feed_rim(ground: FractalGround) -> void:
	var gm: ShaderMaterial = ground._material
	if gm == null:
		return
	if gm != _rim_mat:
		_rim_mat = gm
		_rim_front = -1
	if _front < 0:
		gm.set_shader_parameter(&"sky_rim_tone", Vector4(1.0, DUSK, 0.0, 0.0))
		return
	if _front != _rim_front:
		_rim_front = _front
		gm.set_shader_parameter(&"sky_rim_data", _tex[_front])
	var fr: float = _front_p["r"]
	gm.set_shader_parameter(&"sky_rim_view", Vector4((_cx - float(_front_p["x"])) / fr,
		(_cy - float(_front_p["y"])) / fr, _r / fr, HALF_W))
	gm.set_shader_parameter(&"sky_rim_tone", Vector4(float(_mat.get_shader_parameter(&"fill_frac")),
		DUSK, GAINS[gain_idx] * _horizon_keep, 1.0))


## What a fill for the view on show would be. Iterations grow with depth, as the ground's do,
## and never drop below the ground's ITER. Measured at seahorse valley by a readback of the
## fill (2026-11-18): 16384 against this rule's 1531 at 100x moved 7% of the inside texels
## outside, and at 1000x changed nothing. Depth is not short of iterations at float32's
## reach; the ITER floor covers the spots that are.
func _want() -> Dictionary:
	var it := clampi(int(256.0 + 192.0 * log(maxf(1.0, zoom)) / log(2.0)), 256, 3072)
	var n: int = MOVE_RES[_move_idx] if is_moving() else res
	return {"x": _cx, "y": _cy, "r": _r, "f": _formula, "it": maxi(it, iter_floor), "n": mini(n, res)}


## A fill has landed: log it, and step the moving resolution by how long a moving one took.
func _landed() -> void:
	var n: int = _front_p["n"]
	print("[msky] fill n=%d it=%d frames=%d gpu_ms=%.1f rows=%d zoom=%.1fx" % [n, int(_front_p["it"]),
		_fill_frames, _fill_gpu_us / 1000.0, _rows, zoom])
	if n >= res:
		return
	if _fill_frames > MOVE_FRAMES_SLOW:
		_move_idx = maxi(0, _move_idx - 1)
	elif _fill_frames < MOVE_FRAMES_FAST:
		_move_idx = mini(MOVE_RES.size() - 1, _move_idx + 1)


func _push(p: Dictionary, row0: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(48)
	b.encode_float(0, float(p["x"]))
	b.encode_float(4, float(p["y"]))
	b.encode_float(8, 0.0)
	b.encode_float(12, 0.0)
	b.encode_float(16, float(p["r"]))
	b.encode_float(20, HALF_W)
	b.encode_s32(24, int(p["n"]))
	b.encode_s32(28, row0)
	b.encode_s32(32, int(p["it"]))
	b.encode_s32(36, int(p["f"]))
	b.encode_s32(40, 0)
	b.encode_float(44, 1.0)
	return b


# --- render thread -----------------------------------------------------------

func _ensure_gpu() -> bool:
	if _gpu_tried:
		return _gpu_ok
	_gpu_tried = true
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		push_error("[msky] no RenderingDevice")
		return false
	var file: RDShaderFile = load("res://shaders/mandel_sky.glsl")
	if file == null:
		push_error("[msky] missing mandel_sky.glsl")
		return false
	var spirv := file.get_spirv()
	if spirv.compile_error_compute != "":
		push_error("[msky] %s" % spirv.compile_error_compute)
		return false
	_shader = _rd.shader_create_from_spirv(spirv)
	_pipeline = _rd.compute_pipeline_create(_shader)
	_gpu_ok = _pipeline.is_valid()
	return _gpu_ok


func _ensure_slot(slot: int, n: int) -> bool:
	if _rid[slot].is_valid() and _rid_n[slot] == n:
		return true
	var fmt := RDTextureFormat.new()
	fmt.width = n
	fmt.height = n
	fmt.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	var tex := _rd.texture_create(fmt, RDTextureView.new(), [])
	if not tex.is_valid():
		push_error("[msky] %dx%d texture creation failed" % [n, n])
		return false
	var old := _rid[slot]
	_rid[slot] = tex
	_rid_n[slot] = n
	_tex[slot].texture_rd_rid = tex
	if old.is_valid():
		# Its uniform set is a dependent and goes with it.
		_rd.free_rid(old)
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u.binding = 0
	u.add_id(tex)
	_set[slot] = _rd.uniform_set_create([u], _shader, 0)
	return _set[slot].is_valid()


## `size`: the slot's texture; `n`: the texels across this fill writes, from its corner.
func _dispatch(slot: int, size: int, n: int, push: PackedByteArray, rows: int) -> void:
	if not _ensure_gpu() or not _ensure_slot(slot, size):
		return
	_read_timestamp()
	_rd.capture_timestamp("msky_begin")
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline)
	_rd.compute_list_bind_uniform_set(cl, _set[slot], 0)
	_rd.compute_list_set_push_constant(cl, push, push.size())
	_rd.compute_list_dispatch(cl, int(ceil(n / 16.0)), int(ceil(rows / 16.0)), 1)
	_rd.compute_list_end()
	_rd.capture_timestamp("msky_end")


func _read_timestamp() -> void:
	var b := -1.0
	var e := -1.0
	for i in _rd.get_captured_timestamps_count():
		match _rd.get_captured_timestamp_name(i):
			"msky_begin": b = float(_rd.get_captured_timestamp_gpu_time(i)) / 1000.0
			"msky_end": e = float(_rd.get_captured_timestamp_gpu_time(i)) / 1000.0
	if b >= 0.0 and e >= b:
		fill_us = e - b


## Render thread, once, at exit.
func cleanup() -> void:
	if _rd == null:
		return
	for t in _tex:
		t.texture_rd_rid = RID()
	for rid: RID in [_rid[0], _rid[1], _shader]:
		if rid.is_valid():
			_rd.free_rid(rid)
	_gpu_ok = false
