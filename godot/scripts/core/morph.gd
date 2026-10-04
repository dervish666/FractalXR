extends RefCounted
class_name Morph

## Genome interpolation, following flam3's default "log" interpolation rather than the
## quaternion decomposition in src/flame/morph.ts.
##
## Lerping the nine matrix entries collapses two differently-oriented transforms through
## a degenerate near-zero-scale middle, so the flame implodes and pops back out. flam3
## solves this by converting each COLUMN of the affine to polar form and interpolating
## the angle and magnitude separately (interpolation.c: convert_linear_to_polar,
## interp_and_convert_back). Each column keeps its own rotation, so shear survives and
## nothing has to collapse.
##
## Two properties matter here and the quaternion approach had neither:
##
##   1. It is EXACT at t=0 and t=1. Decomposing a matrix to a rotation and a scale and
##      recomposing it loses shear, so the endpoints had to be special-cased, and that
##      special case was a visible jump at both ends of every transition.
##   2. The translation is treated as another column, so it arcs between positions
##      instead of sliding straight through the origin.
##
## flam3 also offers Catmull-Rom ("smooth") interpolation across four control points,
## which matters for continuous velocity through a chain of keyframes. Not needed for a
## single A to B transition with smoothstep easing, but the thing to reach for if
## transitions are ever chained without a pause.


static func smoothstep_t(t: float) -> float:
	var x := clampf(t, 0.0, 1.0)
	return x * x * (3.0 - 2.0 * x)


## Godot's Basis constructor takes columns; the genome stores rows.
static func _basis_from_rows(rx: Vector3, ry: Vector3, rz: Vector3) -> Basis:
	return Basis(rx, ry, rz).transposed()


static func _rows_of(b: Basis) -> Array:
	var t := b.transposed()
	return [t.x, t.y, t.z]


static func _v3(a: Array) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2]))


## Slerp two directions on the unit sphere, the 3D analogue of flam3 carrying an angle.
static func _slerp_dir(a: Vector3, b: Vector3, t: float) -> Vector3:
	var d := clampf(a.dot(b), -1.0, 1.0)
	if d > 0.9995:
		# Nearly parallel: slerp is numerically unstable, and lerp is indistinguishable.
		return a.lerp(b, t).normalized()
	if d < -0.9995:
		# Antipodal: every rotation plane is equally valid, so pick a stable one rather
		# than letting a near-zero cross product choose it at random each frame.
		var axis := a.cross(Vector3.UP)
		if axis.length_squared() < 1e-8:
			axis = a.cross(Vector3.RIGHT)
		return a.rotated(axis.normalized(), PI * t)
	var theta := acos(d)
	var st := sin(theta)
	return a * (sin((1.0 - t) * theta) / st) + b * (sin(t * theta) / st)


## Interpolate one column as flam3 does: as a direction and a magnitude, not as three
## independent numbers. Lerping the components collapses a rotating column through zero
## length; carrying the angle rotates it instead.
static func _interp_column(a: Vector3, b: Vector3, t: float) -> Vector3:
	var ma := a.length()
	var mb := b.length()
	if ma < 1e-9 or mb < 1e-9:
		return a.lerp(b, t)   # no direction to carry
	return _slerp_dir(a / ma, b / mb, t) * lerpf(ma, mb, t)


static func _interp_transform(a: Dictionary, b: Dictionary, t: float) -> Dictionary:
	# No endpoint special case, deliberately. Per-column polar interpolation reproduces
	# its inputs exactly at t=0 and t=1, so the interpolated genome joins the real ones
	# without a seam. The previous decompose-to-quaternion approach could not: it threw
	# away shear, so returning the true matrix at the endpoints and the shear-stripped
	# one just inside them put a visible jump at both ends of every transition.
	#
	# This follows flam3's default "log" interpolation (interpolation.c,
	# convert_linear_to_polar / interp_and_convert_back), extended from 2D columns to 3D
	# by slerping the direction instead of carrying a single angle.
	var rows_a := [_v3(a["rowX"]), _v3(a["rowY"]), _v3(a["rowZ"])]
	var rows_b := [_v3(b["rowX"]), _v3(b["rowY"]), _v3(b["rowZ"])]

	# Columns, not rows: a column is where a basis vector goes, which is the thing with
	# a direction and a length worth preserving.
	var out_cols: Array = []
	for c in 3:
		var ca := Vector3(rows_a[0][c], rows_a[1][c], rows_a[2][c])
		var cb := Vector3(rows_b[0][c], rows_b[1][c], rows_b[2][c])
		out_cols.append(_interp_column(ca, cb, t))

	# flam3 treats the translation as another column, so it arcs between the two
	# positions rather than sliding straight through the origin. That is a large part of
	# why its transitions read as organic rather than mechanical.
	var pr := _interp_column(_v3(a["translate"]), _v3(b["translate"]), t)

	var va: Array = a.get("variations", [])
	var vb: Array = b.get("variations", [])
	var vr: Array = []
	for i in maxi(va.size(), vb.size()):
		var x: float = float(va[i]) if i < va.size() else 0.0
		var y: float = float(vb[i]) if i < vb.size() else 0.0
		vr.append(lerpf(x, y, t))

	return {
		"rowX": [out_cols[0].x, out_cols[1].x, out_cols[2].x],
		"rowY": [out_cols[0].y, out_cols[1].y, out_cols[2].y],
		"rowZ": [out_cols[0].z, out_cols[1].z, out_cols[2].z],
		"translate": [pr.x, pr.y, pr.z],
		"weight": lerpf(float(a.get("weight", 1.0)), float(b.get("weight", 1.0)), t),
		"colorIndex": lerpf(float(a.get("colorIndex", 0.0)), float(b.get("colorIndex", 0.0)), t),
		"variations": vr,
	}


## A zero-weight clone, so a transform present in only one genome fades in or out by
## weight instead of popping into existence fully formed.
static func _zero_weight(tx: Dictionary) -> Dictionary:
	var c := tx.duplicate(true)
	c["weight"] = 0.0
	return c


static func _sample_palette(colors: Array, s: float) -> Vector3:
	var segs := maxi(1, colors.size() - 1)
	var f := clampf(s, 0.0, 1.0) * float(segs)
	var i0 := mini(segs, int(f))
	var i1 := mini(segs, i0 + 1)
	var lf := f - float(i0)
	var a: Vector3 = colors[i0]
	var b: Vector3 = colors[i1]
	return a.lerp(b, lf)


static func blend_palettes(a: Array, b: Array, t: float) -> Array:
	var n := maxi(a.size(), b.size())
	var out: Array = []
	for i in n:
		var s := 0.0 if n == 1 else float(i) / float(n - 1)
		out.append(_sample_palette(a, s).lerp(_sample_palette(b, s), t))
	return out


## Interpolate a whole preset A to B at t in [0,1].
static func interpolate(a: Dictionary, b: Dictionary, t: float) -> Dictionary:
	var ta: Array = a.get("transforms", [])
	var tb: Array = b.get("transforms", [])
	var n := maxi(ta.size(), tb.size())
	var out: Array = []
	for i in n:
		var x: Dictionary = ta[i] if i < ta.size() else _zero_weight(tb[i])
		var y: Dictionary = tb[i] if i < tb.size() else _zero_weight(ta[i])
		out.append(_interp_transform(x, y, t))

	var pa := PresetLibrary.palette_of(a)
	var pb := PresetLibrary.palette_of(b)
	var blended := blend_palettes(pa, pb, t)
	var pal: Array = []
	for c in blended:
		pal.append([c.x, c.y, c.z])

	return {
		"name": "%s to %s" % [a.get("name", "?"), b.get("name", "?")],
		"transforms": out,
		"palette": pal,
		"brightness": lerpf(float(a.get("brightness", 0.32)), float(b.get("brightness", 0.32)), t),
		"gamma": lerpf(float(a.get("gamma", 2.4)), float(b.get("gamma", 2.4)), t),
		"k2": lerpf(float(a.get("k2", 55.0)), float(b.get("k2", 55.0)), t),
		"highlightDesat": lerpf(float(a.get("highlightDesat", 0.3)), float(b.get("highlightDesat", 0.3)), t),
		"pointBrightness": lerpf(float(a.get("pointBrightness", 0.9)), float(b.get("pointBrightness", 0.9)), t),
	}


## A transition decomposed once, at its start. interpolate() above rebuilds every transform
## Dictionary, re-normalises every column, re-runs acos and re-samples both palettes on every
## call, and a morph called it every frame for its whole length. A Plan does all of that once
## and leaves sample() a few multiply-adds per column, written straight into FlameSource's
## flat layout so nothing is allocated per frame either. The maths is interpolate()'s,
## operation for operation: tools/morph_cost.gd checks the two agree.
static func plan(a: Dictionary, b: Dictionary) -> Plan:
	return Plan.new(a, b)


class Plan:
	const _LERP := 0      # a zero-length column: plain lerp, nothing to carry
	const _NLERP := 1     # nearly parallel: normalised lerp
	const _ANTI := 2      # antipodal: a fixed rotation plane
	const _SLERP := 3

	var n := 0            # transforms, already clamped to what the flame encodes
	var name := ""
	var _kind := PackedInt32Array()
	var _ua := PackedVector3Array()    # unit direction, or the raw column for _LERP
	var _ub := PackedVector3Array()
	var _axis := PackedVector3Array()  # _ANTI only
	var _ma := PackedFloat32Array()
	var _mb := PackedFloat32Array()
	var _theta := PackedFloat32Array()
	var _inv_sin := PackedFloat32Array()
	var _sa := PackedFloat32Array()    # per transform: weight, colorIndex, NVAR variations
	var _sb := PackedFloat32Array()
	var _pal_a: Array = []             # both palettes sampled where blend_palettes samples them
	var _pal_b: Array = []
	var _tone_a := PackedFloat32Array()
	var _tone_b := PackedFloat32Array()

	const _SCALARS := 2 + FlameSource.NVAR

	func _init(a: Dictionary, b: Dictionary) -> void:
		name = "%s to %s" % [a.get("name", "?"), b.get("name", "?")]
		var ta: Array = a.get("transforms", [])
		var tb: Array = b.get("transforms", [])
		n = mini(maxi(ta.size(), tb.size()), FlameSource.MAX_T)
		_kind.resize(n * 4)
		_ua.resize(n * 4)
		_ub.resize(n * 4)
		_axis.resize(n * 4)
		_ma.resize(n * 4)
		_mb.resize(n * 4)
		_theta.resize(n * 4)
		_inv_sin.resize(n * 4)
		_sa.resize(n * _SCALARS)
		_sb.resize(n * _SCALARS)
		for i in n:
			var x: Dictionary = ta[i] if i < ta.size() else Morph._zero_weight(tb[i])
			var y: Dictionary = tb[i] if i < tb.size() else Morph._zero_weight(ta[i])
			var rx := [Morph._v3(x["rowX"]), Morph._v3(x["rowY"]), Morph._v3(x["rowZ"])]
			var ry := [Morph._v3(y["rowX"]), Morph._v3(y["rowY"]), Morph._v3(y["rowZ"])]
			for c in 3:
				_column(i * 4 + c, Vector3(rx[0][c], rx[1][c], rx[2][c]),
					Vector3(ry[0][c], ry[1][c], ry[2][c]))
			_column(i * 4 + 3, Morph._v3(x["translate"]), Morph._v3(y["translate"]))
			_scalars(_sa, i, x)
			_scalars(_sb, i, y)
		var pa := PresetLibrary.palette_of(a)
		var pb := PresetLibrary.palette_of(b)
		var np := maxi(pa.size(), pb.size())
		for i in np:
			var s := 0.0 if np == 1 else float(i) / float(np - 1)
			_pal_a.append(Morph._sample_palette(pa, s))
			_pal_b.append(Morph._sample_palette(pb, s))
		_tone_a = _tone(a)
		_tone_b = _tone(b)

	## The same branches as _interp_column and _slerp_dir, decided once.
	func _column(j: int, a: Vector3, b: Vector3) -> void:
		var ma := a.length()
		var mb := b.length()
		_ma[j] = ma
		_mb[j] = mb
		if ma < 1e-9 or mb < 1e-9:
			_kind[j] = _LERP
			_ua[j] = a
			_ub[j] = b
			return
		var ua := a / ma
		var ub := b / mb
		_ua[j] = ua
		_ub[j] = ub
		var d := clampf(ua.dot(ub), -1.0, 1.0)
		if d > 0.9995:
			_kind[j] = _NLERP
		elif d < -0.9995:
			_kind[j] = _ANTI
			var axis := ua.cross(Vector3.UP)
			if axis.length_squared() < 1e-8:
				axis = ua.cross(Vector3.RIGHT)
			_axis[j] = axis.normalized()
		else:
			_kind[j] = _SLERP
			var theta := acos(d)
			_theta[j] = theta
			_inv_sin[j] = 1.0 / sin(theta)

	func _scalars(dst: PackedFloat32Array, i: int, tx: Dictionary) -> void:
		var o := i * _SCALARS
		dst[o] = float(tx.get("weight", 1.0))
		dst[o + 1] = float(tx.get("colorIndex", 0.0))
		var vars: Array = tx.get("variations", [])
		for v in FlameSource.NVAR:
			dst[o + 2 + v] = float(vars[v]) if v < vars.size() else 0.0

	static func _tone(p: Dictionary) -> PackedFloat32Array:
		return PackedFloat32Array([
			float(p.get("brightness", 0.32)), float(p.get("gamma", 2.4)),
			float(p.get("k2", 55.0)), float(p.get("highlightDesat", 0.3)),
			float(p.get("pointBrightness", 0.9))])

	func _col(j: int, t: float) -> Vector3:
		match _kind[j]:
			_LERP:
				return _ua[j].lerp(_ub[j], t)
			_NLERP:
				return _ua[j].lerp(_ub[j], t).normalized() * lerpf(_ma[j], _mb[j], t)
			_ANTI:
				return _ua[j].rotated(_axis[j], PI * t) * lerpf(_ma[j], _mb[j], t)
		var th := _theta[j]
		var s := _inv_sin[j]
		return (_ua[j] * (sin((1.0 - t) * th) * s) + _ub[j] * (sin(t * th) * s)) \
			* lerpf(_ma[j], _mb[j], t)

	## Write the genome at t (already eased) into flat, FlameSource.STRIDE floats per
	## transform. flat is resized once and then reused.
	func sample(t: float, flat: PackedFloat32Array) -> void:
		if flat.size() != n * FlameSource.STRIDE:
			flat.resize(n * FlameSource.STRIDE)
		for i in n:
			var o := i * FlameSource.STRIDE
			for c in 3:
				var col := _col(i * 4 + c, t)
				flat[o + c] = col.x        # rowX
				flat[o + 3 + c] = col.y    # rowY
				flat[o + 6 + c] = col.z    # rowZ
			var tr := _col(i * 4 + 3, t)
			flat[o + 9] = tr.x
			flat[o + 10] = tr.y
			flat[o + 11] = tr.z
			var so := i * _SCALARS
			for k in _SCALARS:
				flat[o + 12 + k] = lerpf(_sa[so + k], _sb[so + k], t)

	func palette_at(t: float) -> Array:
		var out: Array = []
		out.resize(_pal_a.size())
		for i in _pal_a.size():
			out[i] = (_pal_a[i] as Vector3).lerp(_pal_b[i], t)
		return out

	## In PresetLibrary.tone_of's shape, which is what the tone-map takes.
	func tone_at(t: float) -> Dictionary:
		return {
			"exposure": lerpf(_tone_a[0], _tone_b[0], t),
			"gamma": lerpf(_tone_a[1], _tone_b[1], t),
			"k2": lerpf(_tone_a[2], _tone_b[2], t),
			"hi_desat": lerpf(_tone_a[3], _tone_b[3], t),
			"point_brightness": lerpf(_tone_a[4], _tone_b[4], t),
		}
