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
var reseed_prob := 0.0015
## 1 = every particle every frame (maximum flicker), 4 = a quarter per frame.
var update_mod := 4

var _preset: Dictionary = {}
var _num_t := 1


func _init(preset: Dictionary = {}) -> void:
	id = &"flame"
	display_name = "Flame"
	set_preset(preset)


func shader_path() -> String:
	return "res://shaders/chaos.glsl"


func set_preset(p: Dictionary) -> void:
	_preset = p
	display_name = str(p.get("name", "Flame"))
	_num_t = clampi(p.get("transforms", []).size(), 1, MAX_T)
	if _rd != null:
		rebuild_params()


const MAX_T := 8


func palette() -> Array:
	return PresetLibrary.palette_of(_preset)


func tone_settings() -> Dictionary:
	return PresetLibrary.tone_of(_preset)


## Mirrors encodeFlame() in src/flame/encode.ts, cdf drift guard included.
func param_buffer_floats() -> PackedFloat32Array:
	var f := PackedFloat32Array()
	f.resize(FLOATS)
	var tf: Array = _preset.get("transforms", [])
	var n := clampi(tf.size(), 1, MAX_T)

	var total := 0.0
	for i in n:
		total += maxf(0.0, float(tf[i].get("weight", 0.0)))
	if total <= 0.0:
		total = 1.0

	var acc := 0.0
	for i in MAX_T:
		if i < n:
			var t: Dictionary = tf[i]
			for k in 3:
				f[i * 3 + k] = float(t["rowX"][k])
				f[24 + i * 3 + k] = float(t["rowY"][k])
				f[48 + i * 3 + k] = float(t["rowZ"][k])
				f[72 + i * 3 + k] = float(t["translate"][k])
			acc += maxf(0.0, float(t.get("weight", 0.0))) / total
			f[96 + i] = acc
			f[104 + i] = float(t.get("colorIndex", 0.0))
			var vars: Array = t.get("variations", [])
			for v in mini(NVAR, vars.size()):
				f[112 + i * NVAR + v] = float(vars[v])
		else:
			# padding rows are never selected, but must still be valid uniforms
			f[i * 3 + 0] = 1.0
			f[24 + i * 3 + 1] = 1.0
			f[48 + i * 3 + 2] = 1.0
			f[96 + i] = 1.0
	f[96 + n - 1] = 1.0 # guard the last bucket against float drift

	var pal := palette()
	for i in 5:
		f[208 + i * 3 + 0] = pal[i].x
		f[208 + i * 3 + 1] = pal[i].y
		f[208 + i * 3 + 2] = pal[i].z
	return f


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
	b.encode_s32(32, 0 if seeding else (frame % maxi(1, update_mod)))
	b.encode_s32(36, 0)
	return b


func push_constant_size() -> int:
	return 40
