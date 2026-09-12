extends FractalSource
class_name BulbSource

## Distance-estimate fractals as a particle cloud: Mandelbulb, Mandelbox, KIFS,
## quaternion Julia, Sierpinski. The second FractalSource, and the proof the split was
## worth it: this is one shader and one subclass, and the renderer, grab, framing,
## morphing, menu and self-test all work on it unchanged.
##
## The "breath" fields are the animation. Each genome slowly modulates whichever
## parameter defines its form (Mandelbulb power, Mandelbox scale, KIFS fold angles,
## Julia constant), so the surface is continuously reshaping rather than sitting there
## as a static model. That is what makes a bulb feel of a piece with the flames.

const FORMULA_IDS := {
	"mandelbulb": 0.0, "mandelbox": 1.0, "kifs": 2.0, "quat": 3.0, "sierpinski": 4.0,
}

var reseed_prob := 0.02
var proj_steps := 3.0
var jitter := 0.0022
var update_mod := 1
## Seconds of breathing, advanced by the host each frame.
var clock := 0.0

var _b: Dictionary = {}


func _init(genome: Dictionary = {}) -> void:
	id = &"bulb"
	set_genome(genome)


func shader_path() -> String:
	return "res://shaders/bulb.glsl"


func is_frozen() -> bool:
	return update_mod <= 0


func update_stride() -> int:
	return maxi(1, update_mod)


func push_constant_size() -> int:
	return 96


func wants_normals() -> bool:
	return true


func set_genome(b: Dictionary) -> void:
	_b = b
	display_name = str(b.get("name", "Bulb"))
	# The palette buffer is rewritten by update_params(); see FlameSource.set_preset.


func palette() -> Array:
	var out: Array = []
	for c in _b.get("palette", []):
		out.append(Vector3(float(c[0]), float(c[1]), float(c[2])))
	while out.size() < 5:
		out.append(Vector3.ONE)
	# The bulb palettes run to seven stops; the renderer takes five control colours, so
	# resample rather than truncate, or the top of every ramp is lost.
	if out.size() > 5:
		var res: Array = []
		for i in 5:
			var f := float(i) / 4.0 * float(out.size() - 1)
			var i0 := mini(out.size() - 1, int(f))
			var i1 := mini(out.size() - 1, i0 + 1)
			res.append((out[i0] as Vector3).lerp(out[i1] as Vector3, f - float(i0)))
		out = res
	return out


func tone_settings() -> Dictionary:
	return {"exposure": 0.3, "gamma": 2.4, "k2": 55.0, "hi_desat": 0.3, "point_brightness": 0.9}


func param_buffer_floats() -> PackedFloat32Array:
	var f := PackedFloat32Array()
	f.resize(16)
	var pal := palette()
	for i in 5:
		f[i * 3 + 0] = pal[i].x
		f[i * 3 + 1] = pal[i].y
		f[i * 3 + 2] = pal[i].z
	return f


func bound() -> float:
	return float(_b.get("bound", 1.3))


## The formula parameters at this moment of the breath, keyed by the uniform names the
## march shader uses. One source of truth for both the compute path and the marcher.
func march_params() -> Dictionary:
	var t := clock * float(_b.get("speed", 0.1))
	# Breathing: each formula modulates the parameter that defines its shape.
	var jc: Array = _b.get("juliaC", [0.0, 0.0, 0.0])
	var orbit := float(_b.get("juliaOrbit", 0.0))
	return {
		"power": float(_b.get("power", 8.0)) + float(_b.get("powerBreath", 0.0)) * sin(t),
		"scale": float(_b.get("scale", 2.0)) + float(_b.get("scaleBreath", 0.0)) * sin(t * 0.83),
		"k_angle_a": float(_b.get("kAngleA", 0.0)) + float(_b.get("kAngleBreath", 0.0)) * sin(t),
		"k_angle_b": float(_b.get("kAngleB", 0.0)) + float(_b.get("kAngleBreath", 0.0)) * cos(t * 0.7),
		"julia_c": Vector3(float(jc[0]), float(jc[1]), float(jc[2])) + Vector3(
			sin(t) * orbit, cos(t * 0.9) * orbit, sin(t * 1.3) * orbit),
		"mandelbulb": 1.0 if bool(_b.get("mandelbulb", true)) else 0.0,
		"formula": float(FORMULA_IDS.get(str(_b.get("formula", "mandelbulb")), 0.0)),
		"min_r": float(_b.get("minR", 0.5)),
		"fixed_r": float(_b.get("fixedR", 1.0)),
		"bound": bound(),
	}


## CPU port of the march shader's distance estimators, for placing the viewer: the
## shader cannot tell the host where the hollows are. Same formulas, same iteration
## counts, same early-outs, so the two agree to float precision (tools/de_check.sh
## renders the shader's copy and compares). Keep all three in step.
func de(p: Vector3) -> float:
	return de_with(p, march_params())


func de_with(p: Vector3, mp: Dictionary) -> float:
	var f: float = mp["formula"]
	var d: float
	if f > 3.5:
		d = _de_kifs(p, mp, true)
	elif f > 2.5:
		d = _de_quat(p, mp)
	elif f > 1.5:
		d = _de_kifs(p, mp, false)
	elif f > 0.5:
		d = _de_box(p, mp)
	else:
		d = _de_bulb(p, mp)
	# The quaternion set at its exact origin is 0/0 in both ports. Inside the set is
	# the honest reading, and a NaN would win every comparison in find_hollow.
	if is_nan(d) or is_inf(d):
		return 0.0
	return d


func _de_bulb(q: Vector3, mp: Dictionary) -> float:
	var power: float = mp["power"]
	var z := q
	var c: Vector3 = q if mp["mandelbulb"] > 0.5 else mp["julia_c"]
	var dr := 1.0
	var r := z.length()
	for i in 8:
		r = z.length()
		if r > 2.0:
			break
		var rr := maxf(r, 1e-9)
		var theta := acos(clampf(z.z / rr, -1.0, 1.0))
		var phi := atan2(z.y, z.x)
		dr = pow(rr, power - 1.0) * power * dr + 1.0
		var zr := pow(rr, power)
		theta *= power
		phi *= power
		z = zr * Vector3(sin(theta) * cos(phi), sin(theta) * sin(phi), cos(theta)) + c
	return 0.5 * log(maxf(r, 1e-9)) * r / maxf(dr, 1e-6)


func _de_box(q: Vector3, mp: Dictionary) -> float:
	var scale: float = mp["scale"]
	var min_r: float = mp["min_r"]
	var fixed_r: float = mp["fixed_r"]
	var offset: Vector3 = q if mp["mandelbulb"] > 0.5 else mp["julia_c"]
	var z := q
	var dr := 1.0
	var min_r2 := min_r * min_r
	var fixed_r2 := fixed_r * fixed_r
	for i in 10:
		z = z.clamp(Vector3(-1, -1, -1), Vector3(1, 1, 1)) * 2.0 - z
		var r2 := z.dot(z)
		if r2 < min_r2:
			var t := fixed_r2 / min_r2
			z *= t
			dr *= t
		elif r2 < fixed_r2:
			var t := fixed_r2 / r2
			z *= t
			dr *= t
		z = scale * z + offset
		dr = dr * absf(scale) + 1.0
		if z.dot(z) > 1e4:
			break
	return z.length() / maxf(absf(dr), 1e-6)


func _de_kifs(q: Vector3, mp: Dictionary, tetra: bool) -> float:
	var s: float = mp["scale"]
	var off: Vector3 = mp["julia_c"]
	var fixed_r: float = mp["fixed_r"]
	var ka: float = mp["k_angle_a"]
	var kb: float = mp["k_angle_b"]
	var z := q
	var dr := 1.0
	var sa := sin(ka)
	var ca := cos(ka)
	var sb := sin(kb)
	var cb := cos(kb)
	for i in 12:
		z = Vector3(z.x, ca * z.y - sa * z.z, sa * z.y + ca * z.z)
		if tetra:
			if z.x + z.y < 0.0:
				z = Vector3(-z.y, -z.x, z.z)
			if z.x + z.z < 0.0:
				z = Vector3(-z.z, z.y, -z.x)
			if z.y + z.z < 0.0:
				z = Vector3(z.x, -z.z, -z.y)
		else:
			z = z.abs()
			if z.x - z.y < 0.0:
				z = Vector3(z.y, z.x, z.z)
			if z.x - z.z < 0.0:
				z = Vector3(z.z, z.y, z.x)
			if z.y - z.z < 0.0:
				z = Vector3(z.x, z.z, z.y)
		z = Vector3(cb * z.x - sb * z.y, sb * z.x + cb * z.y, z.z)
		z = z * s - off * (s - 1.0)
		dr *= s
	return (z.length() - fixed_r) / absf(dr)


func _de_quat(pos: Vector3, mp: Dictionary) -> float:
	var z := Vector4(pos.x, pos.y, pos.z, 0.0)
	var jc: Vector3 = mp["julia_c"]
	var c: Vector4 = z if mp["mandelbulb"] > 0.5 else Vector4(jc.x, jc.y, jc.z, 0.0)
	var md2 := 1.0
	var m2 := z.dot(z)
	for i in 11:
		md2 *= 4.0 * m2
		var yzw := Vector3(z.y, z.z, z.w)
		var sq := Vector4(z.x * z.x - yzw.dot(yzw), 2.0 * z.x * z.y, 2.0 * z.x * z.z, 2.0 * z.x * z.w)
		z = sq + c
		m2 = z.dot(z)
		if m2 > 256.0:
			break
	return 0.25 * log(m2) * sqrt(m2 / md2)


## Per-bulb geometry the shader cannot tell the host: the shape's true radial extent
## and its best enclosed room, precomputed by tools/rooms.sh into data/rooms.json
## (the enclosure search is a million DE evaluations per bulb, far too slow for a
## button press on the headset). Keyed by bulb name; a bulb without a record falls
## back to the preset bound and a clearance-only scatter.
const ROOMS_PATH := "res://data/rooms.json"
static var _rooms: Dictionary = {}
static var _rooms_loaded := false


static func _load_rooms() -> void:
	if _rooms_loaded:
		return
	_rooms_loaded = true
	var f := FileAccess.open(ROOMS_PATH, FileAccess.READ)
	if f == null:
		push_warning("[bulb] no %s; ENTER falls back to a clearance scatter" % ROOMS_PATH)
		return
	var parsed = JSON.parse_string(f.get_as_text())
	if typeof(parsed) == TYPE_DICTIONARY:
		_rooms = parsed


func room() -> Dictionary:
	_load_rooms()
	return _rooms.get(display_name, {})


## Radius of the sphere the marcher starts its rays at, in state units. The preset
## bound is the seed ball for the particles and can sit well inside the shape (the
## scale-2 Mandelbox reaches 9.8 against a bound of 5.2), and a sphere that cuts
## through solid paints every ray as a hit at its entry: a ball of noise.
func march_bound() -> float:
	var r := room()
	if r.has("extent"):
		return maxf(bound(), float(r["extent"])) * 1.08
	return bound() * 1.15


## The point ENTER stands the viewer at, in state units. From the precomputed room
## when there is one (refined locally, because the breath has moved the walls since
## the tool ran), else the point of greatest clearance in a scatter through the inner
## two thirds of the shape.
func find_hollow() -> Vector3:
	var mp := march_params()
	var b := bound()
	var best := Vector3.ZERO
	var best_d := de_with(best, mp)
	var golden := PI * (3.0 - sqrt(5.0))
	var r := room()
	var radius := b * 0.66
	if r.has("inside"):
		var inside: Array = r["inside"]
		best = Vector3(float(inside[0]), float(inside[1]), float(inside[2]))
		best_d = de_with(best, mp)
		radius = maxf(float(r.get("clearance", 0.05)), 0.02) * 1.5
	else:
		const N := 600
		for i in N:
			var t := (float(i) + 0.5) / float(N)
			var y := 1.0 - 2.0 * t
			var rr := sqrt(maxf(0.0, 1.0 - y * y))
			var a := golden * float(i)
			var p := Vector3(cos(a) * rr, y, sin(a) * rr) * (radius * pow(t, 1.0 / 3.0))
			var d := de_with(p, mp)
			if d > best_d:
				best_d = d
				best = p
		radius = b * 0.08
	# Local refinement: a tighter scatter around the seed. Stays within the room, so a
	# stored room cannot be swapped for the exterior a wall away.
	var centre := best
	for i in 160:
		var t := (float(i) + 0.5) / 160.0
		var y := 1.0 - 2.0 * t
		var rr := sqrt(maxf(0.0, 1.0 - y * y))
		var a := golden * float(i) * 1.7
		var p := centre + Vector3(cos(a) * rr, y, sin(a) * rr) * (radius * pow(t, 1.0 / 3.0))
		var d := de_with(p, mp)
		if d > best_d:
			best_d = d
			best = p
	return best


func params_bytes(count: int, frame: int, seeding: bool) -> PackedByteArray:
	var mp := march_params()
	var power: float = mp["power"]
	var scale: float = mp["scale"]
	var ang_a: float = mp["k_angle_a"]
	var ang_b: float = mp["k_angle_b"]
	var c: Vector3 = mp["julia_c"]

	var b := PackedByteArray()
	b.resize(96)
	b.encode_s32(0, _tex_size)
	b.encode_s32(4, frame % 16777216)
	b.encode_s32(8, count)
	b.encode_s32(12, 1 if seeding else 0)
	b.encode_s32(16, 1 if seeding else update_mod)
	b.encode_s32(20, 0 if seeding else (frame % maxi(1, update_mod)))
	b.encode_float(24, reseed_prob)
	b.encode_float(28, power)
	# vec4 must sit on a 16-byte boundary.
	b.encode_float(32, c.x)
	b.encode_float(36, c.y)
	b.encode_float(40, c.z)
	b.encode_float(44, 0.0)
	b.encode_float(48, mp["mandelbulb"])
	b.encode_float(52, mp["formula"])
	b.encode_float(56, scale)
	b.encode_float(60, mp["min_r"])
	b.encode_float(64, mp["fixed_r"])
	b.encode_float(68, mp["bound"])
	b.encode_float(72, proj_steps)
	b.encode_float(76, jitter)
	b.encode_float(80, ang_a)
	b.encode_float(84, ang_b)
	b.encode_float(88, 0.0)
	b.encode_float(92, 0.0)
	return b
