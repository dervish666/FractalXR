extends RefCounted
class_name Breed

## Genome generation, ported from src/flame/breed.ts.
##
## This is the real answer to "more flames": not a bigger hand-authored gallery, but a
## generator. Random gives you somewhere new, mutate explores around one you like, and
## crossover mixes two.
##
## The constraints matter more than the randomness. A random affine is built as
## rotation times a CONTRACTIVE scale, so the linear part can never blow up and the
## attractor stays bounded. And every genome is checked for a z-injecting variation,
## because without one a 3D flame collapses to a flat sheet, which is the single most
## common way a generated genome comes out worthless.

const VAR_COUNT := 12
## Indices into the variation array that add genuine z extent. Mirrors Z_INJECTORS in
## src/flame/types.ts: bubble3D, sinusoidal, spherical, eyefish.
const Z_INJECTORS := [4, 3, 1, 11]

const DEFAULT_TONE := {
	"brightness": 0.26, "gamma": 2.4, "k2": 55.0,
	"highlightDesat": 0.3, "pointBrightness": 0.9,
}


static func _round2(x: float) -> float:
	return roundf(x * 100.0) / 100.0


## Rotation times a contractive scale. Godot's Basis constructor takes columns and
## three.js compose() scales columns, so scale the columns to match.
static func _random_affine() -> Dictionary:
	var q := Quaternion(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)).normalized()
	var b := Basis(q)
	var s := Vector3(randf_range(0.3, 0.62), randf_range(0.3, 0.62), randf_range(0.3, 0.62))
	var m := Basis(b.x * s.x, b.y * s.y, b.z * s.z)
	var rows := m.transposed()
	var t := Vector3(randf_range(-0.32, 0.32), randf_range(-0.32, 0.32), randf_range(-0.32, 0.32))
	return {
		"rowX": [rows.x.x, rows.x.y, rows.x.z],
		"rowY": [rows.y.x, rows.y.y, rows.y.z],
		"rowZ": [rows.z.x, rows.z.y, rows.z.z],
		"translate": [t.x, t.y, t.z],
	}


static func _random_variations() -> Array:
	var v: Array = []
	v.resize(VAR_COUNT)
	v.fill(0.0)
	for _i in 1 + randi() % 3:      # 1 to 3 active variations
		v[randi() % VAR_COUNT] = _round2(randf_range(0.3, 1.0))
	return v


static func _has_z(transforms: Array) -> bool:
	for t in transforms:
		for z in Z_INJECTORS:
			if float(t["variations"][z]) > 0.0:
				return true
	return false


## A flat 2D sheet is the failure mode, so guarantee at least one z-injecting variation.
static func _ensure_z(transforms: Array) -> void:
	if _has_z(transforms):
		return
	var t: Dictionary = transforms[randi() % transforms.size()]
	t["variations"][Z_INJECTORS[randi() % Z_INJECTORS.size()]] = _round2(randf_range(0.4, 0.8))


static func _hsl(h: float, s: float, l: float) -> Array:
	if is_zero_approx(s):
		return [l, l, l]
	var q := l * (1.0 + s) if l < 0.5 else l + s - l * s
	var p := 2.0 * l - q
	var f := func(t: float) -> float:
		t = fposmod(t, 1.0)
		if t < 1.0 / 6.0: return p + (q - p) * 6.0 * t
		if t < 0.5: return q
		if t < 2.0 / 3.0: return p + (q - p) * (2.0 / 3.0 - t) * 6.0
		return p
	return [f.call(h + 1.0 / 3.0), f.call(h), f.call(h - 1.0 / 3.0)]


## Usually a curated theme, because a cohesive palette beats a random one most of the
## time; occasionally a generated ramp, so the gallery is not closed.
static func _random_palette(themes: Array) -> Array:
	if randf() < 0.6 and not themes.is_empty():
		var t: Array = themes[randi() % themes.size()]
		return t.duplicate(true)
	var h0 := randf()
	var drift := randf_range(-0.22, 0.22)
	var out: Array = []
	for pos in [0.0, 0.2, 0.45, 0.72, 1.0]:
		var h: float = fposmod(h0 + drift * pos, 1.0)
		var sat := clampf(0.55 + 0.45 * sin(pos * PI), 0.0, 1.0)
		var light := clampf(0.02 + pos * 0.95, 0.0, 1.0)
		out.append(_hsl(h, sat, light))
	return out


static func random_genome(serial: int, themes: Array) -> Dictionary:
	var n := 2 + randi() % 3      # 2 to 4 transforms
	var transforms: Array = []
	for i in n:
		var t := _random_affine()
		t["weight"] = _round2(randf_range(0.4, 1.4))
		t["colorIndex"] = clampf(float(i) / float(maxi(1, n - 1)) + randf_range(-0.12, 0.12), 0.0, 1.0)
		t["variations"] = _random_variations()
		transforms.append(t)
	_ensure_z(transforms)
	var g := {"name": "Wild %d" % serial, "transforms": transforms, "palette": _random_palette(themes)}
	g.merge(DEFAULT_TONE)
	return g


## A nearby variation: explore around a flame you liked rather than starting over.
static func mutate(g: Dictionary, serial: int, amt := 0.18) -> Dictionary:
	var transforms: Array = []
	for t in g.get("transforms", []):
		var vars_in: Array = t["variations"]
		var vars_out: Array = []
		vars_out.resize(VAR_COUNT)
		vars_out.fill(0.0)
		for i in VAR_COUNT:
			var base: float = float(vars_in[i]) if i < vars_in.size() else 0.0
			# Already-active variations always jitter; dormant ones sometimes wake, which
			# is what lets a lineage gain new character instead of only drifting.
			if base > 0.0 or randf() < 0.15:
				vars_out[i] = maxf(0.0, _round2(base + randf_range(-amt, amt)))
		transforms.append({
			"rowX": _jitter(t["rowX"], amt),
			"rowY": _jitter(t["rowY"], amt),
			"rowZ": _jitter(t["rowZ"], amt),
			"translate": _jitter(t["translate"], amt),
			"weight": maxf(0.1, float(t.get("weight", 1.0)) + randf_range(-amt, amt)),
			"colorIndex": clampf(float(t.get("colorIndex", 0.0)) + randf_range(-amt, amt), 0.0, 1.0),
			"variations": vars_out,
		})
	_ensure_z(transforms)
	var palette: Array = []
	for c in g.get("palette", []):
		palette.append([
			clampf(float(c[0]) + randf_range(-0.06, 0.06), 0.0, 1.0),
			clampf(float(c[1]) + randf_range(-0.06, 0.06), 0.0, 1.0),
			clampf(float(c[2]) + randf_range(-0.06, 0.06), 0.0, 1.0)])
	return _with_tone(g, {"name": "Mutant %d" % serial, "transforms": transforms, "palette": palette})


## Each transform slot comes from one parent or the other.
static func crossover(a: Dictionary, b: Dictionary, serial: int) -> Dictionary:
	var ta: Array = a.get("transforms", [])
	var tb: Array = b.get("transforms", [])
	var transforms: Array = []
	for i in maxi(ta.size(), tb.size()):
		var in_a := i < ta.size()
		var in_b := i < tb.size()
		var src: Array = (a if randf() < 0.5 else b).get("transforms", []) if (in_a and in_b) else (ta if in_a else tb)
		transforms.append((src[i] as Dictionary).duplicate(true))
	_ensure_z(transforms)
	var parent: Dictionary = a if randf() < 0.5 else b
	return _with_tone(a, {
		"name": "Hybrid %d" % serial,
		"transforms": transforms,
		"palette": (parent.get("palette", []) as Array).duplicate(true),
	})


static func _jitter(row: Array, amt: float) -> Array:
	return [float(row[0]) + randf_range(-amt, amt),
		float(row[1]) + randf_range(-amt, amt),
		float(row[2]) + randf_range(-amt, amt)]


static func _with_tone(from: Dictionary, g: Dictionary) -> Dictionary:
	for k in ["brightness", "gamma", "k2", "highlightDesat", "pointBrightness"]:
		g[k] = from.get(k, DEFAULT_TONE[k])
	return g
