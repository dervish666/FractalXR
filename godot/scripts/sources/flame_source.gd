extends FractalSource
class_name FlameSource

## The 3D fractal-flame chaos game. Reference implementation of a FractalSource, and
## the one to copy when adding Mandelbulb, Mandelbox, KIFS or quaternion Julia: those
## share this exact shape and differ only in shader and parameter layout.
##
## Genome buffer layout, matching shaders/chaos.glsl:
##   0..23   row0[8][3]   24..47  row1[8][3]   48..71  row2[8][3]   72..95  b[8][3]
##   96..103 cdf[8]       104..111 color[8]    112..207 varW[8][12] 208..222 palette[5][3]

const FLOATS := 224
const NVAR := 12

var iterations := 4
const RESEED_PROB := 0.0015
var reseed_prob := RESEED_PROB
## 1 = every particle every frame (maximum flicker), 4 = a quarter per frame.
var update_mod := 4
## Of those update_mod slabs, how many move per frame. They are taken in turn from a pointer
## that runs round all of them, so a transition can vary its rate here without the slabs
## re-partitioning under a particle and leaving it waiting (main.gd, _morph_slabs).
var slabs_per_frame := 1
var _slab := 0

var _preset: Dictionary = {}
var _num_t := 1


func _init(preset: Dictionary = {}) -> void:
	id = &"flame"
	display_name = "Flame"
	set_preset(preset)


func shader_path() -> String:
	return "res://shaders/chaos.glsl"


func is_frozen() -> bool:
	return update_mod <= 0


func update_stride() -> int:
	return maxi(1, update_mod)


func update_slabs() -> int:
	return clampi(slabs_per_frame, 1, update_stride())


func set_preset(p: Dictionary) -> void:
	_preset = p
	_live.clear()
	_live_pal = []
	display_name = str(p.get("name", "Flame"))
	_num_t = clampi(p.get("transforms", []).size(), 1, MAX_T)
	# No GPU work here. The genome buffer is a fixed 224 floats, created once in setup()
	# and rewritten in place by update_params().


## One frame of a morph: the genome already in flat form (STRIDE floats per transform, from
## Morph.Plan.sample) and its palette. Encoded here once, into a buffer that is reused, so
## update_params() uploads it without walking a Dictionary. set_preset() ends it.
func set_frame(flat: PackedFloat32Array, n: int, pal: Array, label: String) -> void:
	_num_t = clampi(n, 1, MAX_T)
	_live_pal = pal
	display_name = label
	encode_into(_live, flat, n, pal)


## A second source on the same genome, frozen at this moment: the authored preset, or the
## morph frame in flight. The sky bake iterates its own walkers with it, so a morph that
## carries on afterwards cannot change what is being baked. No GPU state is shared.
func snapshot() -> FlameSource:
	var s := FlameSource.new(_preset)
	if not _live.is_empty():
		s._live = _live.duplicate()
		s._live_pal = _live_pal.duplicate()
		s._num_t = _num_t
		s.display_name = display_name
	return s


const MAX_T := 8
## Floats per transform in the flat form: rowX, rowY, rowZ, translate (3 each), weight,
## colorIndex, then NVAR variation weights.
const STRIDE := 14 + NVAR

var _live := PackedFloat32Array()   # the encoded genome while a morph is driving it
var _live_pal: Array = []


func palette() -> Array:
	if not _live.is_empty():
		return _live_pal
	return PresetLibrary.palette_of(_preset)


func tone_settings() -> Dictionary:
	return PresetLibrary.tone_of(_preset)


## A genome's transforms in the flat form Morph.Plan writes, so both paths share one encoder.
static func flatten(tf: Array, n: int) -> PackedFloat32Array:
	var flat := PackedFloat32Array()
	flat.resize(n * STRIDE)
	for i in mini(n, tf.size()):
		var t: Dictionary = tf[i]
		var o := i * STRIDE
		for k in 3:
			flat[o + k] = float(t["rowX"][k])
			flat[o + 3 + k] = float(t["rowY"][k])
			flat[o + 6 + k] = float(t["rowZ"][k])
			flat[o + 9 + k] = float(t["translate"][k])
		flat[o + 12] = float(t.get("weight", 0.0))
		flat[o + 13] = float(t.get("colorIndex", 0.0))
		var vars: Array = t.get("variations", [])
		for v in mini(NVAR, vars.size()):
			flat[o + 14 + v] = float(vars[v])
	return flat


func param_buffer_floats() -> PackedFloat32Array:
	if not _live.is_empty():
		return _live
	var tf: Array = _preset.get("transforms", [])
	var n := clampi(tf.size(), 1, MAX_T)
	var f := PackedFloat32Array()
	encode_into(f, flatten(tf, n), n, palette())
	return f


## Mirrors encodeFlame() in src/flame/encode.ts, cdf drift guard included.
static func encode_into(f: PackedFloat32Array, flat: PackedFloat32Array, n: int, pal: Array) -> void:
	f.resize(FLOATS)
	f.fill(0.0)
	n = clampi(mini(n, flat.size() / STRIDE), 1, MAX_T) if flat.size() >= STRIDE else 1
	var have := flat.size() >= STRIDE

	var total := 0.0
	if have:
		for i in n:
			total += maxf(0.0, flat[i * STRIDE + 12])
	if total <= 0.0:
		total = 1.0

	var acc := 0.0
	for i in MAX_T:
		if have and i < n:
			var o := i * STRIDE
			for k in 3:
				f[i * 3 + k] = flat[o + k]
				f[24 + i * 3 + k] = flat[o + 3 + k]
				f[48 + i * 3 + k] = flat[o + 6 + k]
				f[72 + i * 3 + k] = flat[o + 9 + k]
			acc += maxf(0.0, flat[o + 12]) / total
			f[96 + i] = acc
			f[104 + i] = flat[o + 13]
			for v in NVAR:
				f[112 + i * NVAR + v] = flat[o + 14 + v]
		else:
			# padding rows are never selected, but must still be valid uniforms
			f[i * 3 + 0] = 1.0
			f[24 + i * 3 + 1] = 1.0
			f[48 + i * 3 + 2] = 1.0
			f[96 + i] = 1.0
	f[96 + n - 1] = 1.0 # guard the last bucket against float drift

	for i in 5:
		var c: Vector3 = pal[i] if i < pal.size() else Vector3.ONE
		f[208 + i * 3 + 0] = c.x
		f[208 + i * 3 + 1] = c.y
		f[208 + i * 3 + 2] = c.z


func params_bytes(count: int, frame: int, seeding: bool) -> PackedByteArray:
	# 40 bytes, matching the Params block in chaos.glsl exactly. Godot rejects a
	# mismatch outright, which is how the self-test caught this.
	var b := PackedByteArray()
	b.resize(40)
	b.encode_s32(0, _num_t)
	b.encode_s32(4, iterations)
	b.encode_s32(8, _tex_size)
	b.encode_s32(12, frame % 16777216)
	b.encode_float(16, reseed_prob)
	b.encode_s32(20, count)
	b.encode_s32(24, 1 if seeding else 0)
	# The seed pass must touch every particle, so staggering is disabled for it.
	b.encode_s32(28, 1 if seeding else update_mod)
	if seeding:
		b.encode_s32(32, 0)
		b.encode_s32(36, 1)
	else:
		var mod := update_stride()
		var k := update_slabs()
		_slab %= mod
		b.encode_s32(32, _slab)
		b.encode_s32(36, k)
		_slab = (_slab + k) % mod
	return b


func push_constant_size() -> int:
	return 40
