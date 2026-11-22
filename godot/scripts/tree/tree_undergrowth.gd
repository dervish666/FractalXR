extends RefCounted
class_name TreeUndergrowth

## Fractal forest undergrowth (forest.gd, fractal_tree.gd), composing five self-similar woodland
## plant families into shared forest-floor beds round each trunk, drawn with the parent tree's
## own branch and leaf materials (tree.gdshader, tree_leaf.gdshader, via their `undergrowth`
## instance uniform).
##
## Every plant is built by a recursive fractal rule:
##   1. bush, low wide multi-stemmed recursive shrub hugging the foot of the tree.
##   2. fern, Barnsley-inspired recursive arching frond rosettes with swept curved pinnae.
##   3. tuft, recursively tillering golden-angle fountain sedge tussocks with slender weeping blades.
##   4. fungi, recursively budding woodland mushroom clusters with smooth 10-sided dome caps.
##   5. moss, recursively budded soft flat moss-cushion discs crowned with dichotomous lichen sprigs.
##
## Shared across trees like TreeLitter, not built per tree. VARIANTS beds live in a unit frame
## (trunk at the origin, every stem and leaf inside MAX_RADIUS = 1.0, reference height
## REF_HEIGHT = 0.56). One deterministic pass per variant emits both LOD 0 (full) and LOD 1
## (compact), so every stem and leaf in LOD 1 is an exact geometric subset of LOD 0 in the same
## place, with COLOR.a flagging LOD 1 persistence (1 kept, 0 LOD 0 only and folded out over
## 6.6-7.6 m before the 7.8/9.0 m tier swap, and by FractalTree.undergrowth_lod0 before a budget
## swap). `prewarm()` computes the raw buffers on a
## WorkerThreadPool task at boot so opening TREE only wraps prebuilt arrays into MultiMeshes.

const VARIANTS := 6
const LODS := 2
const STRIDE := 20
const MAX_RADIUS := 1.0
const REF_HEIGHT := 0.56

## Plant hue shifts relative to the parent tree's palette (radians, packed into COLOR.g around 0.5).
## Bushes shift distinctly away from the trunk hue so they read as forest shrubs, not extra limbs.
const HUE_BUSH := -0.58
const HUE_FERN := -1.18
const HUE_TUFT := -0.84
const HUE_FUNGI := 0.78
const HUE_MOSS := -1.42

const GOLDEN_ANGLE := 2.39996323

## _lib[variant][lod] = {"stems": MultiMesh, "leaves": MultiMesh, "n_s": int, "n_l": int,
##   "counts": Dictionary}
static var _lib: Array = []
static var _raw: Array = []
static var _warm_task: int = -1
static var _prewarmed_on_worker := false
static var _ug_cyl: CylinderMesh = null


## Compute all VARIANTS raw instance buffers on a background worker at boot. Safe to call
## repeatedly; no Godot scene or RenderingServer calls happen on the worker thread.
static func prewarm() -> void:
	if not _lib.is_empty() or not _raw.is_empty() or _warm_task != -1:
		return
	_warm_task = WorkerThreadPool.add_task(_compute_all_raw_worker, false, "undergrowth lib")


static func wait_prewarm() -> void:
	if _warm_task != -1:
		WorkerThreadPool.wait_for_task_completion(_warm_task)
		_warm_task = -1


static func was_prewarmed() -> bool:
	return _prewarmed_on_worker


static func _compute_all_raw_worker() -> void:
	_compute_all_raw()
	_prewarmed_on_worker = true


static func _compute_all_raw() -> void:
	var out: Array = []
	for v in VARIANTS:
		out.append(compute_variant(v))
	_raw = out


static func _unit_cyl() -> CylinderMesh:
	if _ug_cyl == null:
		# 10 sides (20 tris): rounds mushroom caps out of the 6-sided tree-twig hexagon; leaner
		# per-bed stem counts keep triangle load modest (about 11k tris at LOD 0, 3.5k at LOD 1).
		_ug_cyl = CylinderMesh.new()
		_ug_cyl.radial_segments = 10
		_ug_cyl.rings = 0
		_ug_cyl.top_radius = 1.0
		_ug_cyl.bottom_radius = 1.0
		_ug_cyl.height = 1.0
		_ug_cyl.cap_top = false
		_ug_cyl.cap_bottom = false
	return _ug_cyl


static func _ensure_lib() -> void:
	if not _lib.is_empty():
		return
	wait_prewarm()
	if _raw.is_empty():
		push_warning("TreeUndergrowth: prewarm did not populate buffers; computing on main thread")
		_prewarmed_on_worker = false
		_compute_all_raw()
	var cyl := _unit_cyl()
	var quad := FractalTree.unit_meshes()[1]
	for v in VARIANTS:
		var raw: Dictionary = _raw[v]
		var tiers: Array = []
		for lod in LODS:
			var t: Dictionary = raw["lods"][lod]
			tiers.append(_wrap_tier(t, cyl, quad))
		_lib.append(tiers)
	_raw.clear()


static func _wrap_tier(t: Dictionary, cyl: Mesh, quad: Mesh) -> Dictionary:
	var n_s: int = t["n_s"]
	var n_l: int = t["n_l"]
	var smm := MultiMesh.new()
	smm.transform_format = MultiMesh.TRANSFORM_3D
	smm.use_colors = true
	smm.use_custom_data = true
	smm.mesh = cyl
	smm.instance_count = n_s
	if n_s > 0:
		smm.buffer = t["sbuf"]

	var lmm := MultiMesh.new()
	lmm.transform_format = MultiMesh.TRANSFORM_3D
	lmm.use_colors = true
	lmm.use_custom_data = true
	lmm.mesh = quad
	lmm.instance_count = n_l
	if n_l > 0:
		lmm.buffer = t["lbuf"]

	return {"stems": smm, "leaves": lmm, "n_s": n_s, "n_l": n_l, "counts": t["counts"]}


static func entry(seed_value: int, lod: int) -> Dictionary:
	_ensure_lib()
	var v := posmod(seed_value, VARIANTS)
	var k := clampi(lod, 0, LODS - 1)
	return _lib[v][k]


static func cost(seed_value: int, lod: int, leaves_on: bool) -> int:
	var e := entry(seed_value, lod)
	return int(e["n_s"]) + (int(e["n_l"]) if leaves_on else 0)


static func _pack_hue(rad: float) -> float:
	return clampf(0.5 + rad / TAU, 0.0, 1.0)


## Emit one tapered cylinder segment into `segs0` (and identically into `segs1` when `keep1` is
## true) while enforcing y >= 0.006 and r_xz <= MAX_RADIUS.
## Entry: [pos, dir, len, r, u_col, along, birth, taper, hue_g, phase, keep1_flag]
static func _emit_seg(segs0: Array, segs1: Array, keep1: bool, pos: Vector3, dir: Vector3,
		ln: float, r: float, u_col: float, along: float, birth: float, taper: float,
		hue_g: float, rng: RandomNumberGenerator) -> Vector3:
	var phase := rng.randf() * TAU
	var d := dir.normalized()
	var end := pos + d * ln
	if end.y < 0.006:
		end.y = 0.006
		var dv := end - pos
		var dl := dv.length()
		if dl < 1e-4:
			return pos
		d = dv / dl
		ln = dl
	var horiz := Vector2(end.x, end.z)
	var hr := horiz.length()
	if hr > MAX_RADIUS - 0.02:
		var s := (MAX_RADIUS - 0.02) / hr
		end.x *= s
		end.z *= s
		var dv2 := end - pos
		var dl2 := dv2.length()
		if dl2 < 1e-4:
			return pos
		d = dv2 / dl2
		ln = dl2
	var entry_seg := [pos, d, ln, r, clampf(u_col, 0.0, 1.0), along,
		clampf(birth, 0.05, 0.74), taper, hue_g, phase, 1.0 if keep1 else 0.0]
	segs0.append(entry_seg)
	if keep1:
		segs1.append(entry_seg)
	return end


## Emit one foliage/spore billboard or flat floor moss disc into `leaves0` (and identically into
## `leaves1` when `keep1` is true).
## Entry: [pos, sz, birth, u_col, col_r, hue_g, flat_flag, phase, keep1_flag]
static func _emit_leaf(leaves0: Array, leaves1: Array, keep1: bool, pos: Vector3, sz: float,
		birth: float, u_col: float, hue_g: float, is_flat: bool, rng: RandomNumberGenerator) -> void:
	var col_r := rng.randf()
	var phase := rng.randf() * TAU
	var p := pos
	p.y = maxf(p.y, 0.008 if is_flat else 0.014)
	var horiz := Vector2(p.x, p.z)
	var max_r := maxf(0.12, MAX_RADIUS - sz * 0.5 - 0.02) if is_flat else MAX_RADIUS - 0.02
	if horiz.length() > max_r:
		var s := max_r / horiz.length()
		p.x *= s
		p.z *= s
	var entry_lf := [p, sz, clampf(birth, 0.05, 0.74), clampf(u_col, 0.0, 1.0),
		col_r, hue_g, 1.0 if is_flat else 0.0, phase, 1.0 if keep1 else 0.0]
	leaves0.append(entry_lf)
	if keep1:
		leaves1.append(entry_lf)


## Pure CPU builder for one variant: produces both LOD 0 and strict-subset LOD 1 from a single
## seed so LOD 1 plants sit at the exact same positions, angles, colours and phases as LOD 0.
static func compute_variant(v: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = 42107 + v * 977
	var segs0: Array = []
	var segs1: Array = []
	var leaves0: Array = []
	var leaves1: Array = []
	var counts0 := {"bush": 0, "fern": 0, "tuft": 0, "fungi": 0, "moss": 0}
	var counts1 := {"bush": 0, "fern": 0, "tuft": 0, "fungi": 0, "moss": 0}

	var a0 := float(v) * GOLDEN_ANGLE + rng.randf_range(-0.22, 0.22)

	# 1. Low spreading multi-stemmed fractal woody shrubs anchoring the foot of the tree.
	var s0 := segs0.size()
	var s1 := segs1.size()
	var b0_ang := a0
	var b0_r := rng.randf_range(0.24, 0.34)
	_add_bush(segs0, segs1, leaves0, leaves1,
		Vector3(cos(b0_ang) * b0_r, 0.0, sin(b0_ang) * b0_r),
		b0_ang, rng.randf_range(0.50, 0.60), 4, 3, 4, true, rng)
	var b1_ang := b0_ang + rng.randf_range(2.4, 3.8)
	var b1_r := rng.randf_range(0.30, 0.44)
	_add_bush(segs0, segs1, leaves0, leaves1,
		Vector3(cos(b1_ang) * b1_r, 0.0, sin(b1_ang) * b1_r),
		b1_ang, rng.randf_range(0.34, 0.42), 3, 2, 3, true, rng)
	counts0["bush"] = segs0.size() - s0
	counts1["bush"] = segs1.size() - s1

	# 2. Barnsley-inspired recursive arching fern rosettes with swept curved pinnae.
	s0 = segs0.size()
	s1 = segs1.size()
	for fi in 2:
		var fang := b0_ang + 1.25 + float(fi) * 2.85 + rng.randf_range(-0.22, 0.22)
		var fr := rng.randf_range(0.28, 0.46)
		var fscale := rng.randf_range(1.06, 1.22) if fi == 0 else rng.randf_range(0.84, 0.98)
		var n_fronds := 5 if fi == 0 else 3
		var lod1_fronds := 3 if fi == 0 else 2
		_add_fern(segs0, segs1, leaves0, leaves1,
			Vector3(cos(fang) * fr, 0.0, sin(fang) * fr),
			fang, fscale, n_fronds, lod1_fronds, rng)
	counts0["fern"] = segs0.size() - s0
	counts1["fern"] = segs1.size() - s1

	# 3. Recursively tillering fountain sedge tussocks softening the outer rim.
	s0 = segs0.size()
	s1 = segs1.size()
	for ti in 3:
		var tang := b0_ang + 0.62 + float(ti) * (TAU / 3.0) + rng.randf_range(-0.26, 0.26)
		var tr := rng.randf_range(0.42, 0.74)
		_add_sedge(segs0, segs1, leaves0, leaves1,
			Vector3(cos(tang) * tr, 0.0, sin(tang) * tr),
			tang, rng.randf_range(0.86, 1.10), ti < 2, rng)
	counts0["tuft"] = segs0.size() - s0
	counts1["tuft"] = segs1.size() - s1

	# 4. Recursively budding woodland fungi nestled against the mossy roots and bush shade.
	s0 = segs0.size()
	s1 = segs1.size()
	for mi in 2:
		var mang := b0_ang + 0.48 + float(mi) * PI + rng.randf_range(-0.32, 0.32)
		var mr := rng.randf_range(0.20, 0.44)
		_add_fungi_node(segs0, segs1, leaves0, leaves1,
			Vector3(cos(mang) * mr, 0.0, sin(mang) * mr),
			mang, rng.randf_range(0.92, 1.16), 0, 2, 0.20, true, rng)
	counts0["fungi"] = segs0.size() - s0
	counts1["fungi"] = segs1.size() - s1

	# 5. Soft recursively budded moss-cushion floor discs spanning root flare to open gaps,
	# crowned with tiny dichotomous lichen sprigs.
	s0 = segs0.size()
	s1 = segs1.size()
	for ci in 4:
		var cang := a0 + 0.58 + float(ci) * (TAU / 4.0) + rng.randf_range(-0.20, 0.20)
		var cr := rng.randf_range(0.24, 0.36) if ci % 2 == 0 else rng.randf_range(0.48, 0.64)
		_add_moss_cushion(segs0, segs1, leaves0, leaves1,
			Vector3(cos(cang) * cr, 0.0, sin(cang) * cr),
			cang, rng.randf_range(0.96, 1.22), 0, 1, ci < 3, ci < 2, rng)
	counts0["moss"] = segs0.size() - s0
	counts1["moss"] = segs1.size() - s1

	return {
		"lods": [
			_pack_tier(segs0, leaves0, counts0),
			_pack_tier(segs1, leaves1, counts1),
		]
	}


static func _pack_tier(segs: Array, leaves: Array, counts: Dictionary) -> Dictionary:
	var n_s := segs.size()
	var sbuf := PackedFloat32Array()
	sbuf.resize(n_s * STRIDE)
	for i in n_s:
		var s: Array = segs[i]
		var pos: Vector3 = s[0]
		var dir: Vector3 = s[1]
		var ln: float = s[2]
		var r: float = s[3]
		var yv := dir
		var xv := yv.cross(Vector3.FORWARD if absf(yv.z) < 0.9 else Vector3.RIGHT).normalized()
		var zv := xv.cross(yv).normalized()
		var basis := Basis(xv * r, yv * ln, zv * r)
		var origin := pos + dir * (ln * 0.5)
		var o := i * STRIDE
		sbuf[o + 0] = basis.x.x; sbuf[o + 1] = basis.y.x; sbuf[o + 2] = basis.z.x; sbuf[o + 3] = origin.x
		sbuf[o + 4] = basis.x.y; sbuf[o + 5] = basis.y.y; sbuf[o + 6] = basis.z.y; sbuf[o + 7] = origin.y
		sbuf[o + 8] = basis.x.z; sbuf[o + 9] = basis.y.z; sbuf[o + 10] = basis.z.z; sbuf[o + 11] = origin.z
		# COLOR: r = u_col, g = packed per-plant hue shift, b = distance along stem (BARK),
		# a = LOD 1 persistence (1 kept in LOD 1, 0 LOD 0 only and folded out before tier swap).
		sbuf[o + 12] = float(s[4]); sbuf[o + 13] = float(s[8]); sbuf[o + 14] = float(s[5]); sbuf[o + 15] = float(s[10])
		# CUSTOM: x = birth, y = taper, z = u_col (level coordinate), w = phase.
		sbuf[o + 16] = float(s[6]); sbuf[o + 17] = float(s[7]); sbuf[o + 18] = float(s[4])
		sbuf[o + 19] = float(s[9])

	var n_l := leaves.size()
	var lbuf := PackedFloat32Array()
	lbuf.resize(n_l * STRIDE)
	for i in n_l:
		var lf: Array = leaves[i]
		var p: Vector3 = lf[0]
		var sz: float = lf[1]
		var is_flat: float = lf[6]
		var phase: float = lf[7]
		var o := i * STRIDE
		if is_flat > 0.5:
			var b := Basis(Vector3.UP, phase).scaled(Vector3(sz, sz, sz))
			lbuf[o + 0] = b.x.x; lbuf[o + 1] = b.y.x; lbuf[o + 2] = b.z.x; lbuf[o + 3] = p.x
			lbuf[o + 4] = b.x.y; lbuf[o + 5] = b.y.y; lbuf[o + 6] = b.z.y; lbuf[o + 7] = p.y
			lbuf[o + 8] = b.x.z; lbuf[o + 9] = b.y.z; lbuf[o + 10] = b.z.z; lbuf[o + 11] = p.z
		else:
			lbuf[o + 0] = sz; lbuf[o + 1] = 0.0; lbuf[o + 2] = 0.0; lbuf[o + 3] = p.x
			lbuf[o + 4] = 0.0; lbuf[o + 5] = sz; lbuf[o + 6] = 0.0; lbuf[o + 7] = p.y
			lbuf[o + 8] = 0.0; lbuf[o + 9] = 0.0; lbuf[o + 10] = sz; lbuf[o + 11] = p.z
		# COLOR: r = colour ramp position, g = packed per-plant hue shift, a = LOD 1 persistence.
		lbuf[o + 12] = float(lf[4]); lbuf[o + 13] = float(lf[5]); lbuf[o + 14] = 0.0; lbuf[o + 15] = float(lf[8])
		# CUSTOM: x = birth, y = flat moss flag (1 flat floor disc, 0 billboard), z = u_col, w = phase.
		lbuf[o + 16] = float(lf[2]); lbuf[o + 17] = is_flat; lbuf[o + 18] = float(lf[3])
		lbuf[o + 19] = phase

	return {"sbuf": sbuf, "lbuf": lbuf, "n_s": n_s, "n_l": n_l, "counts": counts}


## 1. Low spreading multi-stemmed recursive woody shrub: splayed basal stems fork rapidly into a
## wide rounded dome with distinct bush hue and clustered soft foliage tips.
static func _add_bush(segs0: Array, segs1: Array, leaves0: Array, leaves1: Array,
		base: Vector3, out_ang: float, target_h: float, depth0: int, depth1: int,
		basal_stems: int, keep_bush: bool, rng: RandomNumberGenerator) -> void:
	var hue_g := _pack_hue(HUE_BUSH)
	var out_dir := Vector3(cos(out_ang), 0.0, sin(out_ang))
	var base_len := target_h * 0.29
	var base_r := target_h * 0.028
	for k in basal_stems:
		var az := out_ang + (float(k) - float(basal_stems - 1) * 0.5) * (TAU / float(basal_stems)) \
			+ rng.randf_range(-0.24, 0.24)
		# Low outward splay (33-53 deg elevation) so the shrub forms a cushion dome, not a sapling.
		var tilt := rng.randf_range(0.65, 0.98)
		var d := (Vector3(cos(az) * sin(tilt), cos(tilt), sin(az) * sin(tilt)) + out_dir * 0.14).normalized()
		var foot := base + Vector3(cos(az), 0.0, sin(az)) * rng.randf_range(0.015, 0.042)
		var stem_keep := keep_bush and k < maxi(basal_stems - 1, 2)
		_add_bush_branch(segs0, segs1, leaves0, leaves1, foot, d,
			base_len * rng.randf_range(0.86, 1.14), base_r, 0, depth0, depth1, 0.0,
			out_dir, hue_g, stem_keep, rng)


static func _add_bush_branch(segs0: Array, segs1: Array, leaves0: Array, leaves1: Array,
		pos: Vector3, dir: Vector3, ln: float, r: float, lv: int, depth0: int, depth1: int,
		along: float, out_dir: Vector3, hue_g: float, keep_branch: bool,
		rng: RandomNumberGenerator) -> void:
	var lv_frac := float(lv) / float(maxi(depth0 - 1, 1))
	var taper := 0.28 if lv + 1 >= depth0 else 0.64
	var birth := lerpf(0.08, 0.58, lv_frac)
	var u_col := lerpf(0.10, 0.62, lv_frac)
	var keep_seg := keep_branch and lv < depth1
	var end := _emit_seg(segs0, segs1, keep_seg, pos, dir, ln, r, u_col, along, birth,
		taper, hue_g, rng)
	if lv + 1 >= depth0:
		_emit_leaf(leaves0, leaves1, keep_seg, end, rng.randf_range(0.056, 0.082),
			birth, 0.78, hue_g, false, rng)
		return
	# Emit interior leaves at depth1-1 so LOD 1 shrubs carry foliage at their own tips while
	# staying a strict subset of LOD 0.
	if lv + 1 == depth1 or (lv + 2 >= depth0 and rng.randf() < 0.72):
		var leaf_keep := keep_branch and lv + 1 == depth1
		_emit_leaf(leaves0, leaves1, leaf_keep, end, rng.randf_range(0.052, 0.074),
			birth, 0.70, hue_g, false, rng)
	var n_kids := 3 if lv == 0 else 2
	var side := dir.cross(Vector3.RIGHT if absf(dir.x) < 0.9 else Vector3.FORWARD).normalized()
	var az0 := rng.randf() * TAU
	for k in n_kids:
		var az := az0 + float(k) * (TAU / float(n_kids)) + rng.randf_range(-0.30, 0.30)
		var tilt := rng.randf_range(0.56, 0.88)
		var kd := dir.rotated(side, tilt).rotated(dir, az)
		kd = (kd + Vector3.DOWN * (0.28 * lv_frac) + out_dir * 0.10
			+ Vector3(rng.randf() - 0.5, rng.randf() - 0.5, rng.randf() - 0.5) * 0.18).normalized()
		if kd.y < -0.14:
			kd.y = -0.14
			kd = kd.normalized()
		var child_keep := keep_seg and (lv + 1 < depth1) and (k < 2)
		_add_bush_branch(segs0, segs1, leaves0, leaves1, end, kd,
			ln * rng.randf_range(0.62, 0.74), r * 0.62, lv + 1, depth0, depth1, along + ln,
			out_dir, hue_g, child_keep, rng)


## 2. Barnsley-inspired recursive fern rosette: gracefully sweeping fronds whose rachis steps
## recursively and spawns swept-forward, slightly V-cupped 2-segment curved pinnae with subtle
## acute secondary leaflets and soft emerald frond-plume accents.
static func _add_fern(segs0: Array, segs1: Array, leaves0: Array, leaves1: Array,
		base: Vector3, out_ang: float, scale: float, n_fronds: int, lod1_fronds: int,
		rng: RandomNumberGenerator) -> void:
	var hue_g := _pack_hue(HUE_FERN)
	var steps := 6
	for f in n_fronds:
		var fan := (float(f) / float(n_fronds) - 0.5) * TAU * 0.92
		var az := out_ang + fan + rng.randf_range(-0.14, 0.14)
		var f_len := rng.randf_range(0.42, 0.54) * scale * (1.0 - 0.10 * absf(sin(fan * 0.5)))
		var pitch := rng.randf_range(0.98, 1.14)
		var pitch_drop := rng.randf_range(1.28, 1.46) / float(steps)
		var curl := rng.randf_range(-0.04, 0.04)
		var pos := base + Vector3(cos(az), 0.0, sin(az)) * 0.014
		var keep_frond := f < lod1_fronds
		_add_fern_rachis(segs0, segs1, leaves0, leaves1, pos, az, pitch, pitch_drop, curl,
			f_len, f_len / float(steps) * 1.22, 0.0086 * scale, scale, 0, steps, 0.0,
			hue_g, keep_frond, rng)


static func _add_fern_rachis(segs0: Array, segs1: Array, leaves0: Array, leaves1: Array,
		pos: Vector3, az: float, pitch: float, pitch_drop: float, curl: float,
		f_len: float, seg_len: float, r: float, scale: float, step: int, steps: int,
		along: float, hue_g: float, keep_frond: bool, rng: RandomNumberGenerator) -> void:
	if step >= steps:
		return
	var t := float(step) / float(steps)
	var t1 := float(step + 1) / float(steps)
	var dir := Vector3(cos(az) * cos(pitch), sin(pitch), sin(az) * cos(pitch)).normalized()
	var birth := lerpf(0.14, 0.62, t)
	var u_col := lerpf(0.18, 0.58, t)
	var taper := 0.12 if step + 1 >= steps else 0.84
	var next_pos := _emit_seg(segs0, segs1, keep_frond, pos, dir, seg_len, r, u_col,
		along, birth, taper, hue_g, rng)
	if step >= 1 and step <= steps - 2:
		var flat := dir.cross(Vector3.UP)
		if flat.length_squared() < 1e-4:
			flat = Vector3(-sin(az), 0.0, cos(az))
		flat = flat.normalized()
		var frond_up := flat.cross(dir).normalized()
		if frond_up.y < 0.0:
			frond_up = -frond_up
		var env := sin(pow(t1, 0.65) * PI)
		var p_len := f_len * 0.38 * env * rng.randf_range(0.92, 1.08)
		var p_r := maxf(r * 0.86, 0.0054)
		var keep_pinna := keep_frond and step <= 3
		for sgn: float in [-1.0, 1.0]:
			_add_fern_pinna(segs0, segs1, leaves0, leaves1, next_pos, dir, flat, frond_up,
				sgn, p_len, p_r, along + seg_len, minf(birth + 0.05, 0.70), t1,
				0, 1 if (step == 1 or step == 2) else 0, hue_g, keep_pinna, step == 1 or step == 2, rng)
	if step == steps - 1:
		_emit_leaf(leaves0, leaves1, keep_frond, next_pos, rng.randf_range(0.028, 0.040) * scale,
			minf(birth + 0.06, 0.72), 0.78, hue_g, false, rng)
	_add_fern_rachis(segs0, segs1, leaves0, leaves1, next_pos, az + curl, pitch - pitch_drop,
		pitch_drop, curl, f_len, seg_len * 0.87, r * 0.82, scale, step + 1, steps,
		along + seg_len, hue_g, keep_frond, rng)


static func _add_fern_pinna(segs0: Array, segs1: Array, leaves0: Array, leaves1: Array,
		origin: Vector3, rdir: Vector3, flat: Vector3, frond_up: Vector3, sgn: float,
		p_len: float, p_r: float, along: float, birth: float, t1: float,
		depth: int, max_depth: int, hue_g: float, keep_pinna: bool, add_plume: bool,
		rng: RandomNumberGenerator) -> void:
	# Swept-forward, V-cupped 2-segment curving pinna instead of stiff 90-degree crossbars.
	var pdir0 := (rdir * 0.56 + flat * sgn * 0.76 + frond_up * 0.22).normalized()
	var mid := _emit_seg(segs0, segs1, keep_pinna, origin, pdir0, p_len * 0.54, p_r,
		lerpf(0.36, 0.62, t1), along, birth, 0.64, hue_g, rng)
	var pdir1 := (rdir * 0.34 + flat * sgn * 0.88 - frond_up * 0.08).normalized()
	_emit_seg(segs0, segs1, keep_pinna, mid, pdir1, p_len * 0.50, p_r * 0.64,
		lerpf(0.48, 0.74, t1), along + p_len * 0.54, minf(birth + 0.04, 0.73), 0.05, hue_g, rng)
	if add_plume:
		_emit_leaf(leaves0, leaves1, keep_pinna, mid, clampf(p_len * 0.44, 0.030, 0.056),
			minf(birth + 0.05, 0.73), 0.72, hue_g, false, rng)
	if depth < max_depth and p_len > 0.075:
		# Acute forward-swept self-similar sub-leaflet (not an orthogonal grid bar).
		var ldir := (pdir0 * 0.82 + rdir * 0.48 + frond_up * 0.14).normalized()
		_emit_seg(segs0, segs1, false, mid, ldir, p_len * 0.34, maxf(p_r * 0.52, 0.0036),
			0.72, along + p_len * 0.54, minf(birth + 0.05, 0.73), 0.06, hue_g, rng)


## 3. Recursively tillering woodland fountain sedge: slender arching blades that weep outward past
## horizontal, budding golden-angle daughter tillers from the basal sheath (no stiff forked sticks).
static func _add_sedge(segs0: Array, segs1: Array, leaves0: Array, leaves1: Array,
		base: Vector3, out_ang: float, scale: float, keep_tuft: bool,
		rng: RandomNumberGenerator) -> void:
	var hue_g := _pack_hue(HUE_TUFT)
	for root_i in 3:
		var az := out_ang + float(root_i) * (TAU / 3.0) + rng.randf_range(-0.28, 0.28)
		_add_sedge_tiller(segs0, segs1, leaves0, leaves1, base, az, scale, 0, 2,
			hue_g, keep_tuft and root_i < 2, rng)


static func _add_sedge_tiller(segs0: Array, segs1: Array, leaves0: Array, leaves1: Array,
		base: Vector3, az: float, scale: float, depth: int, max_depth: int, hue_g: float,
		keep_tiller: bool, rng: RandomNumberGenerator) -> void:
	var b_len := rng.randf_range(0.24, 0.36) * scale
	var pitch := rng.randf_range(1.16, 1.38)
	var drop := rng.randf_range(0.42, 0.54)
	var foot := base + Vector3(cos(az), 0.0, sin(az)) * (0.014 * float(depth))
	var keep_blade := keep_tiller and depth <= 1
	var segs_n := 4 if depth == 0 else 3
	var tip := _add_sedge_blade(segs0, segs1, keep_blade, foot, az, pitch, drop,
		b_len * (0.34 if segs_n == 4 else 0.44), 0.0044 * scale, 0, segs_n, 0.0, hue_g, rng)
	if depth == 0:
		_emit_leaf(leaves0, leaves1, keep_blade, tip, rng.randf_range(0.022, 0.032) * scale,
			0.64, 0.76, hue_g, false, rng)
	if depth >= max_depth:
		return
	var n_kids := 2 if depth == 0 else 1
	for k in n_kids:
		var kaz := az + float(k + 1) * GOLDEN_ANGLE + rng.randf_range(-0.24, 0.24)
		var child_base := base + Vector3(cos(kaz), 0.0, sin(kaz)) * rng.randf_range(0.012, 0.028)
		var child_keep := keep_tiller and depth == 0 and k == 0
		_add_sedge_tiller(segs0, segs1, leaves0, leaves1, child_base, kaz,
			scale * rng.randf_range(0.78, 0.88), depth + 1, max_depth, hue_g, child_keep, rng)


static func _add_sedge_blade(segs0: Array, segs1: Array, keep1: bool, pos: Vector3,
		az: float, pitch: float, drop: float, sl: float, r: float, seg: int, segs_n: int,
		along: float, hue_g: float, rng: RandomNumberGenerator) -> Vector3:
	if seg >= segs_n:
		return pos
	var t := float(seg) / float(maxi(segs_n - 1, 1))
	var dir := Vector3(cos(az) * cos(pitch), sin(pitch), sin(az) * cos(pitch)).normalized()
	var taper := 0.04 if seg == segs_n - 1 else (0.50 if seg == segs_n - 2 else 0.76)
	var next_pos := _emit_seg(segs0, segs1, keep1, pos, dir, sl, r, lerpf(0.14, 0.64, t),
		along, lerpf(0.12, 0.56, t), taper, hue_g, rng)
	return _add_sedge_blade(segs0, segs1, keep1, next_pos, az, pitch - drop, drop * 0.96,
		sl * 0.84, r * taper, seg + 1, segs_n, along + sl, hue_g, rng)


## 4. Recursively budding woodland fungi cluster: a curved parasol mushroom with a 10-sided dome
## cap (downward-normal gill underside, rounded shoulder, closed apex) and recursive daughter
## fruiting bodies budding from both the mycelial root collar and mid-stipe.
static func _add_fungi_node(segs0: Array, segs1: Array, leaves0: Array, leaves1: Array,
		foot: Vector3, az: float, scale: float, depth: int, max_depth: int, birth0: float,
		keep_node: bool, rng: RandomNumberGenerator) -> void:
	var hue_g := _pack_hue(HUE_FUNGI)
	var lean := 0.14 if depth == 0 else rng.randf_range(0.24, 0.44)
	var h := rng.randf_range(0.13, 0.19) * scale
	var stipe_r := 0.0102 * scale
	var cap_r := rng.randf_range(0.048, 0.068) * scale
	var d0 := Vector3(cos(az) * sin(lean), cos(lean), sin(az) * sin(lean)).normalized()
	var mid := _emit_seg(segs0, segs1, keep_node, foot, d0, h * 0.54, stipe_r, 0.22,
		0.0, birth0, 0.84, hue_g, rng)
	var d1 := (d0 * 0.42 + Vector3.UP * 0.58).normalized()
	var neck := _emit_seg(segs0, segs1, keep_node, mid, d1, h * 0.46, stipe_r * 0.84, 0.36,
		h * 0.54, birth0 + 0.06, 0.86, hue_g, rng)
	_add_mushroom_cap(segs0, segs1, leaves0, leaves1, neck, d1, stipe_r * 0.72, cap_r, h,
		birth0 + 0.12, hue_g, keep_node, rng)
	if depth >= max_depth:
		return
	# Daughter 0: mycelial root bud at golden-angle offset.
	var az0 := az + GOLDEN_ANGLE + rng.randf_range(-0.25, 0.25)
	var foot0 := foot + Vector3(cos(az0), 0.0, sin(az0)) * (0.044 * scale)
	_add_fungi_node(segs0, segs1, leaves0, leaves1, foot0, az0, scale * 0.66,
		depth + 1, max_depth, birth0 + 0.08, keep_node and depth == 0, rng)
	# Daughter 1: miniature stipe shelf bud at depth 0, or second root button at depth 1.
	if depth == 0:
		var az1 := az + 2.15 + rng.randf_range(-0.25, 0.25)
		_add_fungi_node(segs0, segs1, leaves0, leaves1, mid, az1, scale * 0.48,
			depth + 1, max_depth, birth0 + 0.16, false, rng)
	elif rng.randf() < 0.75:
		var az2 := az - GOLDEN_ANGLE + rng.randf_range(-0.25, 0.25)
		var foot2 := foot + Vector3(cos(az2), 0.0, sin(az2)) * (0.036 * scale)
		_add_fungi_node(segs0, segs1, leaves0, leaves1, foot2, az2, scale * 0.60,
			depth + 1, max_depth, birth0 + 0.14, false, rng)


static func _add_mushroom_cap(segs0: Array, segs1: Array, leaves0: Array, leaves1: Array,
		neck: Vector3, up_dir: Vector3, neck_r: float, cap_r: float, along: float,
		birth: float, hue_g: float, keep1: bool, rng: RandomNumberGenerator) -> void:
	# Flared gill ring (taper > 1 -> downward cone normal in tree.gdshader, dark underside),
	# then rounded shoulder and closed dome apex (taper < 1 -> upward cone normal).
	var gill_h := cap_r * 0.26
	var flare := cap_r / maxf(neck_r, 0.002)
	var rim := _emit_seg(segs0, segs1, keep1, neck, up_dir, gill_h, neck_r, 0.34,
		along, birth, flare, hue_g, rng)
	var sh_h := cap_r * 0.34
	var shoulder := _emit_seg(segs0, segs1, keep1, rim, up_dir, sh_h, cap_r, 0.70,
		along + gill_h, minf(birth + 0.04, 0.72), 0.62, hue_g, rng)
	var dome_h := cap_r * 0.28
	_emit_seg(segs0, segs1, keep1, shoulder, up_dir, dome_h, cap_r * 0.62, 0.82,
		along + gill_h + sh_h, minf(birth + 0.08, 0.74), 0.02, hue_g, rng)
	var sp := neck + up_dir * (gill_h * 0.30)
	_emit_leaf(leaves0, leaves1, keep1, sp, cap_r * 0.90, minf(birth + 0.06, 0.73),
		0.86, hue_g, false, rng)


## 5. Plush fractal moss cushion: recursively budded soft flat floor discs (drawn via
## tree_leaf.gdshader's scalloped flat-disc path) spanning root flare to the open gaps between
## plants, crowned on inner colonies with delicate recursive dichotomous coral-lichen sprigs.
static func _add_moss_cushion(segs0: Array, segs1: Array, leaves0: Array, leaves1: Array,
		base: Vector3, ang: float, scale: float, depth: int, max_depth: int, keep_cushion: bool,
		add_sprigs: bool, rng: RandomNumberGenerator) -> void:
	var hue_g := _pack_hue(HUE_MOSS)
	var disc_sz := rng.randf_range(0.42, 0.56) * scale
	var disc_y := 0.008 + float(depth) * 0.003
	_emit_leaf(leaves0, leaves1, keep_cushion, Vector3(base.x, disc_y, base.z), disc_sz,
		0.08 + float(depth) * 0.05, 0.45, hue_g, true, rng)
	if depth == 0 and add_sprigs:
		for s in 3:
			var az := ang + float(s) * GOLDEN_ANGLE + rng.randf_range(-0.25, 0.25)
			var sr := rng.randf_range(0.014, disc_sz * 0.22)
			var foot := Vector3(base.x + cos(az) * sr, 0.008, base.z + sin(az) * sr)
			var d0 := Vector3(cos(az) * 0.48, 0.88, sin(az) * 0.48).normalized()
			_add_moss_sprig(segs0, segs1, foot, d0, rng.randf_range(0.022, 0.030) * scale,
				0.0046 * scale, 0, 2, 0.0, az, hue_g, keep_cushion and s < 2, rng)
	if depth >= max_depth:
		return
	for k in 3:
		var kaz := ang + float(k) * (TAU / 3.0) + rng.randf_range(-0.30, 0.30)
		var off := disc_sz * rng.randf_range(0.40, 0.52)
		var child_base := base + Vector3(cos(kaz) * off, 0.0, sin(kaz) * off)
		_add_moss_cushion(segs0, segs1, leaves0, leaves1, child_base, kaz, scale * 0.64,
			depth + 1, max_depth, keep_cushion and k < 2, false, rng)


static func _add_moss_sprig(segs0: Array, segs1: Array, pos: Vector3, dir: Vector3,
		ln: float, r: float, lv: int, depth: int, along: float, roll: float, hue_g: float,
		keep_sprig: bool, rng: RandomNumberGenerator) -> void:
	var lf := float(lv) / float(maxi(depth - 1, 1))
	var birth := lerpf(0.09, 0.38, lf)
	var taper := 0.36 if lv + 1 >= depth else 0.72
	var end := _emit_seg(segs0, segs1, keep_sprig, pos, dir, ln, r, lerpf(0.20, 0.56, lf),
		along, birth, taper, hue_g, rng)
	if lv + 1 >= depth:
		return
	var side := dir.cross(Vector3.RIGHT if absf(dir.x) < 0.9 else Vector3.FORWARD).normalized()
	for k in 2:
		var kaz := roll + float(k) * PI + rng.randf_range(-0.25, 0.25)
		var kd := dir.rotated(side, rng.randf_range(0.56, 0.78)).rotated(dir, kaz)
		kd = (kd + Vector3.UP * 0.14).normalized()
		_add_moss_sprig(segs0, segs1, end, kd, ln * 0.72, r * 0.72, lv + 1, depth,
			along + ln, roll + PI * 0.5, hue_g, keep_sprig and k == 0, rng)
