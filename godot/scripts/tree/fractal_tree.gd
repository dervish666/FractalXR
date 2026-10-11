extends Node3D
class_name FractalTree

## A fractal tree as real geometry: a MultiMesh of tapered cylinders grown by recursive
## branching, and a second MultiMesh of glowing leaf discs at the tips. Everything that
## moves is in the shaders (tree.gdshader, tree_leaf.gdshader): growth from the base up
## over grow_s seconds, and a wind field that bends the whole tree coherently by height,
## so the script builds once per (shape, depth, seed) and then only feeds time and wind.
##
## The hero tree sits as a child of the ParticleCloud so grab, scale and spin apply
## unchanged. Forest trees (forest.gd) are the same class with variety, a size and a
## branch cap set before build().
##
## build() is two halves. compute() is pure (inputs in, buffers out, no node touched), so the
## forest runs it on a worker thread and shares one result between every tree of the same
## species, seed, cap and height; adopt() uploads a result into this tree's own MultiMeshes.
## The nodes and materials are made on first adopt, so a tree the far batch draws (far_forest.gd)
## is a bare Node3D.

const GROW_S := 6.0            # seconds from seed to full canopy (oak; species may differ)
const MAX_BRANCHES := 80000     # the hero's safety cap: a Quest draws this many cylinders

## Shape presets. `branches` children per node, `angle` tilt from the parent in radians,
## `ratio` length per level, `radius_ratio` thickness per level, `twist` azimuth step
## between siblings, `jitter` randomness 0..1, `droop` bends children toward the ground
## (negative reaches up), `apical` keeps a leader growing straight up the trunk with a
## whorl of `branches` side branches at every level, each of which then splits
## `side_branches` ways (conifers), `height_m` the finished hero tree's height.
##
## Optional keys, all off by default so the first four species build exactly what they
## always did:
##   angle_end   tilt at the outermost level; the tilt runs from `angle` to this (acacia)
##   gnarl       random kink added to every child's direction (thorn, sakura)
##   phyllo      fixed azimuth step per level instead of a random start (spiral, crystal)
##   monopodial  every branch keeps a leader, not just the trunk (spiral)
##   bare        trunk segments with no side branches before the crown (palm, baobab)
##   bare_ratio, bare_rr, lean   length and radius per bare segment, curve of the trunk
##   pinnate     past the crown, each node is a continuation plus two short leaflets (palm)
##   leaf_shape  0 disc, 1 blossom, 2 needle star, 3 sparkle (tree_leaf.gdshader)
##   leaf_tint, leaf_mix, leaf_hue   pull the theme colour toward a species colour, or turn
##               its hue (radians); bark_tint, bark_mix, bark_hue the same for wood
##   leaf_gain   additive brightness (the shader default is 0.25)
##   grow_s      seconds to full canopy
const SHAPES := {
	"oak": {"branches": 3, "depth": 9, "angle": 0.55, "ratio": 0.74, "radius_ratio": 0.68,
		"twist": 0.9, "jitter": 0.5, "droop": -0.15, "apical": false, "height_m": 4.8,
		"trunk_r": 0.10, "leaf_size": 0.09,
		"leaf_tint": Color(0.55, 0.85, 0.35), "leaf_mix": 0.0},
	"pine": {"branches": 5, "side_branches": 3, "depth": 9, "angle": 1.15, "ratio": 0.5,
		"radius_ratio": 0.5, "twist": 0.6, "jitter": 0.3, "droop": 0.35, "apical": true,
		"height_m": 6.0, "trunk_r": 0.09, "leaf_size": 0.05,
		"leaf_shape": 2, "leaf_gain": 0.3,
		"leaf_tint": Color(0.25, 0.7, 0.5), "leaf_mix": 0.55, "grow_s": 7.0},
	"willow": {"branches": 3, "depth": 9, "angle": 0.7, "ratio": 0.78, "radius_ratio": 0.66,
		"twist": 1.2, "jitter": 0.6, "droop": 0.55, "apical": false, "height_m": 4.2,
		"trunk_r": 0.11, "leaf_size": 0.06,
		"leaf_tint": Color(0.75, 0.9, 0.45), "leaf_mix": 0.5},
	"coral": {"branches": 4, "depth": 8, "angle": 0.9, "ratio": 0.66, "radius_ratio": 0.62,
		"twist": 0.5, "jitter": 0.7, "droop": -0.3, "apical": false, "height_m": 3.2,
		"trunk_r": 0.13, "leaf_size": 0.12,
		"leaf_tint": Color(1.0, 0.45, 0.4), "leaf_mix": 0.55, "bark_hue": 0.5},
	# Silver birch: slender, a golden-angle twist, fine twigs that hang at the ends.
	"birch": {"branches": 2, "depth": 13, "angle": 0.42, "ratio": 0.8, "radius_ratio": 0.7,
		"twist": 2.4, "jitter": 0.35, "droop": 0.45, "apical": false, "height_m": 5.4,
		"trunk_r": 0.06, "leaf_size": 0.045,
		"leaf_tint": Color(0.95, 0.85, 0.35), "leaf_mix": 0.65,
		"bark_tint": Color(0.95, 0.93, 0.88), "bark_mix": 0.6, "grow_s": 5.5},
	# Lombardy poplar: every fork narrow and pulled hard upward. A green flame.
	"poplar": {"branches": 2, "depth": 12, "angle": 0.26, "ratio": 0.82, "radius_ratio": 0.7,
		"twist": 2.4, "jitter": 0.35, "droop": -0.55, "apical": false, "height_m": 6.5,
		"trunk_r": 0.07, "leaf_size": 0.045,
		"leaf_tint": Color(0.5, 0.95, 0.3), "leaf_mix": 0.6, "grow_s": 5.0},
	# Palm: a curved bare trunk, then a crown of pinnate fronds that arc over and droop.
	"palm": {"branches": 14, "depth": 16, "angle": 0.55, "ratio": 0.86, "radius_ratio": 0.45,
		"twist": 0.0, "jitter": 0.25, "droop": 1.0, "apical": false, "height_m": 5.0,
		"trunk_r": 0.07, "leaf_size": 0.12,
		"bare": 6, "bare_ratio": 0.92, "bare_rr": 0.94, "lean": 0.07, "pinnate": true,
		"leaf_tint": Color(0.55, 0.9, 0.35), "leaf_mix": 0.6,
		"bark_tint": Color(0.7, 0.55, 0.35), "bark_mix": 0.45, "grow_s": 7.0},
	# Acacia: steep forks low, wide flat spread high. An umbrella on a savanna.
	"acacia": {"branches": 2, "depth": 12, "angle": 0.28, "angle_end": 1.6, "ratio": 0.82,
		"radius_ratio": 0.7, "twist": 1.6, "jitter": 0.35, "droop": -0.05, "apical": false,
		"height_m": 4.0, "trunk_r": 0.09, "leaf_size": 0.06, "gnarl": 0.15,
		"leaf_tint": Color(0.75, 0.8, 0.3), "leaf_mix": 0.55, "grow_s": 6.5},
	# Cherry blossom: gnarled and spreading, pink five-petal flowers.
	"sakura": {"branches": 3, "depth": 9, "angle": 0.8, "ratio": 0.71, "radius_ratio": 0.64,
		"twist": 1.1, "jitter": 0.55, "droop": 0.08, "apical": false, "height_m": 3.8,
		"trunk_r": 0.12, "leaf_size": 0.1, "gnarl": 0.3,
		"leaf_shape": 1, "leaf_gain": 0.32,
		"leaf_tint": Color(1.0, 0.62, 0.8), "leaf_mix": 0.85,
		"bark_tint": Color(0.35, 0.2, 0.22), "bark_mix": 0.35},
	# Baobab: a barrel trunk, then a short stubby crown.
	"baobab": {"branches": 5, "depth": 7, "angle": 0.8, "ratio": 0.5, "radius_ratio": 0.5,
		"twist": 0.9, "jitter": 0.5, "droop": -0.2, "apical": false, "height_m": 3.6,
		"trunk_r": 0.34, "leaf_size": 0.08,
		"bare": 2, "bare_ratio": 0.9, "bare_rr": 0.82,
		"leaf_tint": Color(0.6, 0.8, 0.3), "leaf_mix": 0.5,
		"bark_tint": Color(0.75, 0.65, 0.6), "bark_mix": 0.4, "grow_s": 8.5},
	# Spiral: every branch keeps a leader and throws one side shoot per level at the golden
	# angle. A fern-like, very regular fractal.
	"spiral": {"branches": 2, "depth": 12, "angle": 0.95, "ratio": 0.62, "radius_ratio": 0.6,
		"twist": 0.0, "jitter": 0.0, "droop": 0.1, "apical": false, "monopodial": true,
		"leader_ratio": 0.86, "phyllo": 2.39996, "height_m": 3.4,
		"trunk_r": 0.07, "leaf_size": 0.05,
		"leaf_hue": 2.1, "leaf_mix": 0.0, "bark_hue": 1.2, "grow_s": 7.5},
	# Crystal: three-fold, no randomness, sixty degrees of turn per level. Frost on glass.
	"crystal": {"branches": 3, "depth": 9, "angle": 0.62, "ratio": 0.64, "radius_ratio": 0.6,
		"twist": 0.0, "jitter": 0.0, "droop": 0.0, "apical": false, "phyllo": 1.0472,
		"height_m": 3.0, "trunk_r": 0.08, "leaf_size": 0.06,
		"leaf_shape": 3, "leaf_gain": 0.34,
		"leaf_tint": Color(0.65, 0.9, 1.0), "leaf_mix": 0.75,
		"bark_tint": Color(0.7, 0.85, 1.0), "bark_mix": 0.5, "grow_s": 5.0},
	# Thorn: crooked, kinked, dark red berries.
	"thorn": {"branches": 2, "depth": 12, "angle": 0.85, "ratio": 0.8, "radius_ratio": 0.7,
		"twist": 1.7, "jitter": 0.8, "droop": 0.05, "apical": false, "height_m": 3.4,
		"trunk_r": 0.08, "leaf_size": 0.04, "gnarl": 0.6,
		"leaf_tint": Color(0.95, 0.25, 0.3), "leaf_mix": 0.75,
		"bark_tint": Color(0.3, 0.22, 0.25), "bark_mix": 0.4},
}
## Append only: the SPECIES tile and the forest index species by position.
const SHAPE_NAMES := ["oak", "pine", "willow", "coral", "birch", "poplar", "palm", "acacia",
	"sakura", "baobab", "spiral", "crystal", "thorn"]

## Leaves shown per LOD step. A forest tree's leaves are shuffled at build, so any prefix
## of the buffer is a fair sample of the whole canopy.
const LEAF_LOD := [1.0, 0.7, 0.45, 0.25]
const LOD_MAX := 3

var shape := "oak"
var depth_delta := 0
var seed_value := 1
var wind := 0.3
var leaves_on := true
var branch_count := 0
var leaf_count := 0
var height_m := 0.0
var grow_t := 0.0
## Seconds to full canopy, and the clock's direction: negative withers the tree back
## into the ground (leaves close first, then twigs retract toward the trunk).
var grow_s := GROW_S
var grow_rate := 1.0

## Forest controls, set before build(). The hero leaves all of these at their defaults.
var variety := 0.0              # 0 = the species exactly; 1 = per-seed shape and colour
var target_height := 0.0        # metres; 0 = the species height
var branch_cap := MAX_BRANCHES
var whole_levels := false       # cap by thinning the outermost level, not a BFS prefix
var lod_ready := false          # shuffle leaves so a buffer prefix is a fair sample
var hand_planted := false
var sprout_delay := 0.0       # seconds after a regrow before this tree starts
var built := false
var wind_ref: Node3D = null     # whose x axis is the wind; null = the tree's own (hero)
## Where this tree's crown and leaves sit on the theme, in turns. 0 draws the ramps as they
## always were; the avenue walks it down the rows so colour rolls away from you.
var palette_phase := 0.0
## Forest bookkeeping. `row` is the avenue row (side + 2 * ring, -1 off the avenue).
## `tier_far` is where the forest wants the tree drawn, `far` where it is: in the avenue's far
## batch, its own nodes hidden and empty. `shape_data` is the compute() result it wears.
var row := -1
var tier_h := 0.0               # avenue: target_height times the row's scale, for the far line
var tier_size := 0.0            # its height over distance when last measured
var tier_far := false
var far := false
var shape_data: Dictionary = {}
var shape_key := ""
## BARK (tree.gdshader's bark_style): 0 plain, 1 veins, 2 julia. Set before adopt or with set_bark().
var bark_style := 0
## FLOOR's fallen leaves: wanted at all (litter_on), and near enough to be worth a draw (the
## forest's LOD pass decides litter_near; the hero sets it once). Both must hold to show.
var litter_on := false
var litter_near := false

## Instance index where each recursion level ends; level_ends[i] = branches in levels 0..i.
var level_ends := PackedInt32Array()
var lod := 0

var _branches: MultiMeshInstance3D = null
var _leaves: MultiMeshInstance3D = null
var _litter: MultiMeshInstance3D = null   # FLOOR's fallen leaves (tree_litter.gd), drawn with the leaf material
var _branch_mat: ShaderMaterial = null
var _leaf_mat: ShaderMaterial = null
var _palette: Array = []
var _palette_stale := false
var _sway_gain := 1.0
## What tick() last fed the materials, so a still, grown tree costs no uniform writes at all.
var _fed := false
var _fed_g := 0.0
var _fed_xf := Transform3D()
var _fed_wxf := Transform3D()
var _fed_wind := 0.0

static var _cyl: CylinderMesh
static var _quad: QuadMesh


func _init() -> void:
	name = "Tree"
	visible = false


## The tree's own nodes and materials, made the first time it is adopted.
func _guts() -> void:
	if _branches != null:
		return
	_branch_mat = ShaderMaterial.new()
	_branch_mat.shader = load("res://shaders/tree.gdshader")
	_leaf_mat = ShaderMaterial.new()
	_leaf_mat.shader = load("res://shaders/tree_leaf.gdshader")
	unit_meshes()
	_branches = MultiMeshInstance3D.new()
	_branches.name = "Branches"
	_branches.material_override = _branch_mat
	_branches.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = _cyl
	_branches.multimesh = mm
	add_child(_branches)

	_leaves = MultiMeshInstance3D.new()
	_leaves.name = "Leaves"
	_leaves.material_override = _leaf_mat
	_leaves.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var lm := MultiMesh.new()
	lm.transform_format = MultiMesh.TRANSFORM_3D
	lm.use_colors = true
	lm.use_custom_data = true
	lm.mesh = _quad
	_leaves.multimesh = lm
	add_child(_leaves)
	# Displaced and grown in the shader; the flat bounds would cull a swaying canopy.
	# build() replaces this with the tree's own extent plus the sway.
	var aabb := AABB(Vector3(-8.0, -0.5, -8.0), Vector3(16.0, 10.0, 16.0))
	_branches.custom_aabb = aabb
	_leaves.custom_aabb = aabb
	# Whatever was set before there were materials to set it on.
	if not _palette.is_empty():
		set_palette(_palette)
	set_palette_phase(palette_phase)
	_branch_mat.set_shader_parameter(&"bark_style", bark_style)
	_leaves.visible = leaves_on


## One cylinder and one quad for every tree, the far batch's included. rings = 0: a branch is
## two vertex rings and 12 triangles. A middle ring (the old rings = 1) doubled the triangles to
## bend a segment under wind, but the sway is quadratic in height over a whole tree, and across
## one segment the chord misses the curve by well under a millimetre.
static func unit_meshes() -> Array[Mesh]:
	if _cyl == null:
		_cyl = CylinderMesh.new()
		_cyl.radial_segments = 6
		_cyl.rings = 0
		_cyl.top_radius = 1.0
		_cyl.bottom_radius = 1.0
		_cyl.height = 1.0
		_cyl.cap_top = false
		_cyl.cap_bottom = false
		_quad = QuadMesh.new()
		_quad.size = Vector2(1.0, 1.0)
	return [_cyl, _quad]


func effective_depth() -> int:
	return clampi(int(SHAPES[shape]["depth"]) + depth_delta, 0, 16)


## The species table entry with every optional key filled, and this seed's variety
## applied. Variety draws from its own generator, so the hero (variety 0) consumes
## exactly the random numbers it always did and a seed still names the same tree.
func _params() -> Dictionary:
	return params_for(shape, seed_value, variety)


static func params_for(shape: String, seed_value: int, variety: float) -> Dictionary:
	var p: Dictionary = (SHAPES[shape] as Dictionary).duplicate()
	var defaults := {"side_branches": p["branches"], "angle_end": p["angle"], "gnarl": 0.0,
		"phyllo": 0.0, "monopodial": false, "leader_ratio": 0.82, "leader_rr": 0.85,
		"bare": 0, "bare_ratio": 1.0, "bare_rr": 0.92, "lean": 0.0, "pinnate": false,
		"leaf_shape": 0, "leaf_gain": 0.25, "leaf_tint": Color(1, 1, 1), "leaf_mix": 0.0,
		"leaf_hue": 0.0, "bark_tint": Color(1, 1, 1), "bark_mix": 0.0, "bark_hue": 0.0,
		"grow_s": GROW_S}
	for key in defaults:
		if not p.has(key):
			p[key] = defaults[key]
	p["lean_az"] = 0.0
	if variety > 0.0:
		var v := RandomNumberGenerator.new()
		v.seed = seed_value * 31337 + SHAPE_NAMES.find(shape) * 17 + 5
		var s := func(amount: float) -> float: return variety * amount * (v.randf() * 2.0 - 1.0)
		var a_scale: float = 1.0 + s.call(0.18)
		p["angle"] = float(p["angle"]) * a_scale
		p["angle_end"] = float(p["angle_end"]) * a_scale
		p["ratio"] = clampf(float(p["ratio"]) * (1.0 + s.call(0.05)), 0.3, 0.9)
		p["droop"] = float(p["droop"]) + s.call(0.15)
		p["twist"] = float(p["twist"]) + s.call(0.4)
		p["jitter"] = clampf(float(p["jitter"]) + s.call(0.1), 0.0, 1.0)
		p["height_m"] = float(p["height_m"]) * (1.0 + s.call(0.15))
		p["leaf_size"] = float(p["leaf_size"]) * (1.0 + s.call(0.15))
		p["leaf_hue"] = float(p["leaf_hue"]) + s.call(0.3)
		p["bark_hue"] = float(p["bark_hue"]) + s.call(0.15)
		p["grow_s"] = float(p["grow_s"]) * (1.0 + s.call(0.2))
		p["lean_az"] = v.randf() * TAU
		# One more or one fewer limb per fork changes a species' density, never its kind:
		# a three-way oak never drops to a two-way fork.
		var nb := int(p["branches"])
		if v.randf() < 0.25 * variety and nb >= 3 and not bool(p["pinnate"]):
			p["branches"] = nb + (1 if nb == 3 or v.randf() < 0.5 else -1)
	return p


## Build the geometry for the current shape, depth and seed. Returns the branch count.
## Pure: the same inputs give the same tree, so a seed is a name for a tree.
func build() -> int:
	return adopt(compute(spec()))


## Everything compute() reads: what decides the geometry, and nothing else.
func spec() -> Dictionary:
	return {"shape": shape, "seed": seed_value, "depth_delta": depth_delta, "variety": variety,
		"target_height": target_height, "branch_cap": branch_cap, "whole_levels": whole_levels,
		"lod_ready": lod_ready}


## compute() for a worker thread: the result lands in holder[0], its microseconds in holder[1].
static func compute_into(s: Dictionary, holder: Array) -> void:
	var t0 := Time.get_ticks_usec()
	var d := compute(s)
	holder[1] = Time.get_ticks_usec() - t0
	holder[0] = d


## The geometry for a spec, as buffers ready to upload. Static and pure: no node, no member,
## a generator of its own, so it is safe on a worker thread and one result can dress many
## trees.
static func compute(spec_in: Dictionary) -> Dictionary:
	var shape: String = spec_in["shape"]
	var seed_value: int = spec_in["seed"]
	var target_height: float = spec_in["target_height"]
	var branch_cap: int = spec_in["branch_cap"]
	var whole_levels: bool = spec_in["whole_levels"]
	var lod_ready: bool = spec_in["lod_ready"]
	var sp := params_for(shape, seed_value, float(spec_in["variety"]))
	var depth := clampi(int(SHAPES[shape]["depth"]) + int(spec_in["depth_delta"]), 0, 16)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value * 7919 + depth * 131 + SHAPE_NAMES.find(shape)
	var branches: int = sp["branches"]
	var angle: float = sp["angle"]
	var angle_end: float = sp["angle_end"]
	var ratio: float = sp["ratio"]
	var rr: float = sp["radius_ratio"]
	var twist: float = sp["twist"]
	var jitter: float = sp["jitter"]
	var droop: float = sp["droop"]
	var apical: bool = sp["apical"]
	var side_branches: int = int(sp["side_branches"])
	var trunk_r: float = sp["trunk_r"]
	var gnarl: float = sp["gnarl"]
	var phyllo: float = sp["phyllo"]
	var monopodial: bool = sp["monopodial"]
	var leader_ratio: float = sp["leader_ratio"]
	var leader_rr: float = sp["leader_rr"]
	var bare: int = sp["bare"]
	var bare_ratio: float = sp["bare_ratio"]
	var bare_rr: float = sp["bare_rr"]
	var pinnate: bool = sp["pinnate"]
	var lean_axis := Vector3.RIGHT.rotated(Vector3.UP, float(sp["lean_az"]))
	var lean: float = sp["lean"]
	var out := {"n_b": 0, "n_l": 0, "grow_s": float(sp["grow_s"]), "level_ends": PackedInt32Array()}
	if depth <= 0:
		return out

	# Segments: [pos, dir, len, r, level, dist, leader, terminal]. Breadth-first with a
	# cursor (pop_front is O(n) per call), so the hero's cap drops the deepest level evenly
	# across the tree instead of keeping one fully explored strand. A forest tree caps
	# by whole levels instead: at each level boundary the queue holds exactly the next
	# level, and if it does not fit, a uniform sample of it becomes the outermost twigs.
	var segs: Array = []
	var queue: Array = [[Vector3.ZERO, Vector3.UP, 1.0, trunk_r, 0, 0.0, true, false]]
	var head := 0
	var cur_level := 0
	while head < queue.size():
		if whole_levels and int(queue[head][4]) != cur_level:
			cur_level = int(queue[head][4])
			var remaining := queue.size() - head
			if segs.size() + remaining > branch_cap:
				var room := branch_cap - segs.size()
				if room <= 0:
					depth = cur_level
				else:
					segs.append_array(_sample_level(queue, head, room, rng))
					depth = cur_level + 1
				break
		var s: Array = queue[head]
		head += 1
		segs.append(s)
		if segs.size() >= branch_cap:
			break
		var level: int = s[4]
		if level + 1 >= depth or bool(s[7]):
			continue
		var tip: Vector3 = s[0] + s[1] * s[2]
		var pdir: Vector3 = s[1]
		var on_trunk: bool = s[6]
		# A bare trunk: one segment per level, curving gently, no side branches.
		if level + 1 < bare:
			var bd := pdir.rotated(lean_axis, lean) if lean != 0.0 else pdir
			queue.append([tip, bd, s[2] * bare_ratio, s[3] * bare_rr, level + 1,
				s[5] + s[2], true, false])
			continue
		var side := pdir.cross(Vector3.RIGHT if absf(pdir.x) < 0.9 else Vector3.FORWARD).normalized()
		# A frond: the continuation droops on, two short leaflets fan out flat to each side.
		if pinnate and bare > 0 and level >= bare:
			var flat := pdir.cross(Vector3.UP)
			if flat.length_squared() < 1e-4:
				flat = side
			flat = flat.normalized()
			var cd := (pdir + Vector3.DOWN * droop * 0.12).normalized()
			var cl: float = s[2] * ratio * (1.0 + jitter * 0.3 * (rng.randf() - 0.5))
			queue.append([tip, cd, cl, s[3] * 0.8, level + 1, s[5] + s[2], false, false])
			for sgn: float in [-1.0, 1.0]:
				var ld := (pdir * 0.45 + flat * sgn + Vector3.DOWN * 0.25).normalized()
				queue.append([tip, ld, s[2] * 1.6 * (1.0 + jitter * 0.4 * (rng.randf() - 0.5)),
					s[3] * 0.5, level + 1, s[5] + s[2], false, true])
			continue
		# A conifer's whorl only happens on the trunk; its side branches split modestly.
		var n := branches if (not apical or on_trunk) else side_branches
		if jitter > 0.0 and rng.randf() < jitter * 0.3:
			n += 1 if rng.randf() < 0.5 else -1
		n = maxi(n, 1)
		var az0 := float(level) * phyllo if phyllo != 0.0 else rng.randf() * TAU
		var level_frac := float(level + 1) / float(depth)
		var base_angle := lerpf(angle, angle_end, level_frac)
		for k in n:
			var leader := (monopodial or (apical and on_trunk)) and k == 0
			var tilt := base_angle * (1.0 + jitter * (rng.randf() - 0.5))
			var lr := ratio
			if leader:
				tilt = base_angle * 0.12 * jitter * (rng.randf() - 0.5)
				lr = leader_ratio
			var az := az0 + twist * float(k) + float(k) * TAU / float(n) + jitter * 0.4 * (rng.randf() - 0.5)
			var d := pdir.rotated(side, tilt).rotated(pdir, az)
			# Droop: pull toward the ground more at the outer levels (willow), or lift.
			d = (d + Vector3.DOWN * droop * level_frac * (0.4 if leader else 1.0)).normalized()
			if gnarl > 0.0:
				d = (d + Vector3(rng.randf() - 0.5, rng.randf() - 0.5, rng.randf() - 0.5) * gnarl).normalized()
			var ln: float = s[2] * lr * (1.0 + jitter * 0.4 * (rng.randf() - 0.5))
			var r: float = s[3] * (leader_rr if leader else rr)
			queue.append([tip, d, ln, r, level + 1, s[5] + s[2], leader, false])

	# Normalise so the tallest point sits at the target height, radii and lengths together.
	var top := 0.0
	for s in segs:
		top = maxf(top, (s[0] + s[1] * s[2]).y)
	var species_h: float = sp["height_m"]
	var height_m := target_height if target_height > 0.0 else species_h
	var k := height_m / maxf(top, 1e-3)
	var total_dist := 0.0
	for s in segs:
		total_dist = maxf(total_dist, s[5] + s[2])
	# A small tree keeps leaves that read at its size without turning into confetti.
	var leaf_scale := 1.0 if is_equal_approx(height_m, species_h) else pow(height_m / species_h, 0.6)

	# Branch buffer: 12 transform floats, 4 colour, 4 custom per instance.
	var n_b := segs.size()
	var buf := PackedFloat32Array()
	buf.resize(n_b * 20)
	var tips: Array = []
	var leaf_size: float = float(sp["leaf_size"]) * leaf_scale
	var lo := Vector3.ZERO
	var hi := Vector3.ZERO
	var level_ends := PackedInt32Array()
	for i in n_b:
		var s: Array = segs[i]
		var pos: Vector3 = s[0] * k
		var dir: Vector3 = s[1]
		var ln: float = s[2] * k
		var r: float = s[3] * k
		var level: int = s[4]
		var terminal: bool = s[7]
		while level_ends.size() <= level:
			level_ends.append(i)
		level_ends[level] = i + 1
		var end := pos + dir * ln
		lo = lo.min(end)
		hi = hi.max(end)
		# Basis: y along the branch, scaled to (r, len, r); the cylinder is centred so
		# the origin moves half a length up the branch.
		var yv := dir
		var xv := yv.cross(Vector3.FORWARD if absf(yv.z) < 0.9 else Vector3.RIGHT).normalized()
		var zv := xv.cross(yv).normalized()
		var basis := Basis(xv * r, yv * ln, zv * r)
		var origin := pos + dir * (ln * 0.5)
		var o := i * 20
		buf[o + 0] = basis.x.x; buf[o + 1] = basis.y.x; buf[o + 2] = basis.z.x; buf[o + 3] = origin.x
		buf[o + 4] = basis.x.y; buf[o + 5] = basis.y.y; buf[o + 6] = basis.z.y; buf[o + 7] = origin.y
		buf[o + 8] = basis.x.z; buf[o + 9] = basis.y.z; buf[o + 10] = basis.z.z; buf[o + 11] = origin.z
		var level_frac := float(level) / float(maxi(depth - 1, 1))
		# Colour: the palette position by level; the shader mixes the real palette. COLOR.b is
		# BARK's coordinate along the wood: metres from the tree's base to this segment's start
		# (a child starts where its parent ends, so the pattern runs on unbroken).
		buf[o + 12] = level_frac; buf[o + 13] = 0.0; buf[o + 14] = float(s[5]) * k; buf[o + 15] = 1.0
		# Custom: birth (0..1 along the growth), taper (child radius / own), level, phase.
		var birth: float = (s[5] * k) / maxf(total_dist * k, 1e-3)
		# The apical leader continues the trunk at 0.85 of its radius (see the queue above);
		# tapering a trunk segment to rr instead ended it at half the leader's base, and the
		# pine read as stacked cones.
		var taper: float = 0.35
		if level + 1 < depth and not terminal:
			if level + 1 < bare:
				taper = bare_rr
			elif pinnate and bare > 0 and level >= bare:
				taper = 0.8
			else:
				taper = leader_rr if (apical or monopodial) and bool(s[6]) else rr
		buf[o + 16] = birth; buf[o + 17] = taper; buf[o + 18] = level_frac
		buf[o + 19] = rng.randf() * TAU
		if terminal or level + 1 >= depth or (level + 2 >= depth and rng.randf() < 0.5):
			tips.append([end, birth, level_frac, r])

	if lod_ready:
		for i in range(tips.size() - 1, 0, -1):
			var j := rng.randi_range(0, i)
			var t: Variant = tips[i]
			tips[i] = tips[j]
			tips[j] = t

	# Leaves: a disc at every tip, a couple more scattered along the outermost branches.
	var n_l := tips.size()
	var lbuf := PackedFloat32Array()
	lbuf.resize(n_l * 20)
	for i in n_l:
		var t: Array = tips[i]
		var p: Vector3 = t[0]
		var sz := leaf_size * (0.7 + 0.6 * rng.randf())
		var o := i * 20
		lbuf[o + 0] = sz; lbuf[o + 1] = 0.0; lbuf[o + 2] = 0.0; lbuf[o + 3] = p.x
		lbuf[o + 4] = 0.0; lbuf[o + 5] = sz; lbuf[o + 6] = 0.0; lbuf[o + 7] = p.y
		lbuf[o + 8] = 0.0; lbuf[o + 9] = 0.0; lbuf[o + 10] = sz; lbuf[o + 11] = p.z
		lbuf[o + 12] = rng.randf(); lbuf[o + 13] = 0.0; lbuf[o + 14] = 0.0; lbuf[o + 15] = 1.0
		lbuf[o + 16] = float(t[1]); lbuf[o + 17] = 0.0; lbuf[o + 18] = float(t[2])
		lbuf[o + 19] = rng.randf() * TAU

	# Bounds: the built extent, plus the sway (at most 0.12 m x wind at the top) and a leaf.
	var pad := 0.25 + leaf_size * 1.3 + trunk_r * k
	out["aabb"] = AABB(lo, hi - lo).grow(pad)
	out["n_b"] = n_b
	out["n_l"] = n_l
	out["buf"] = buf
	out["lbuf"] = lbuf
	out["level_ends"] = level_ends
	out["height_m"] = height_m
	# Wind sway is in metres at the top, so a knee-high tree would whip about at the same
	# amplitude as a 5 m one. The hero (full species height) keeps exactly 1.0.
	out["sway_gain"] = 1.0 if is_equal_approx(height_m, species_h) else clampf(sqrt(height_m / species_h), 0.3, 1.0)
	for key in ["bark_tint", "leaf_tint"]:
		out[key] = _rgb(sp[key])
	for key in ["bark_mix", "bark_hue", "leaf_mix", "leaf_hue", "leaf_shape", "leaf_gain"]:
		out[key] = float(sp[key])
	return out


## Wear a compute() result: upload its buffers into this tree's own MultiMeshes and set the
## material from it. Resets the growth clock, as a build always has. Returns the branch count.
func adopt(d: Dictionary) -> int:
	_guts()
	take_shape(d)
	lod = 0
	far = false
	var n_b: int = d["n_b"]
	if n_b == 0:
		_branches.multimesh.instance_count = 0
		_leaves.multimesh.instance_count = 0
		return 0
	_upload(d)
	if _palette_stale:
		set_palette(_palette)
	_leaves.visible = leaves_on
	_sway_gain = d["sway_gain"]
	for m in [_branch_mat, _leaf_mat]:
		m.set_shader_parameter("tree_height", height_m)
		m.set_shader_parameter("grow_s", grow_s)
		m.set_shader_parameter("sway_gain", _sway_gain)
	for key in ["bark_tint", "bark_mix", "bark_hue"]:
		_branch_mat.set_shader_parameter(key, d[key])
	for key in ["leaf_tint", "leaf_mix", "leaf_hue", "leaf_shape", "leaf_gain"]:
		_leaf_mat.set_shader_parameter(key, d[key])
	_fed = false
	grow_t = 0.0
	_sync_litter()
	return n_b


## The numbers of a compute() result, uploading nothing: all the far batch's trees carry.
func take_shape(d: Dictionary) -> void:
	shape_data = d
	grow_s = float(d["grow_s"])
	built = true
	branch_count = d["n_b"]
	leaf_count = d["n_l"]
	level_ends = d["level_ends"]
	if branch_count > 0:
		height_m = d["height_m"]


## Back to unplaced: no buffers, hidden, waiting for the forest to adopt it or hand it to the
## far batch again. The shape stays, so neither needs a compute.
func unplace() -> void:
	release()
	far = false
	built = false


func _upload(d: Dictionary) -> void:
	var mm := _branches.multimesh
	mm.instance_count = 0
	mm.instance_count = d["n_b"]
	mm.buffer = d["buf"]
	mm.visible_instance_count = -1
	var lm := _leaves.multimesh
	lm.instance_count = 0
	lm.instance_count = d["n_l"]
	if int(d["n_l"]) > 0:
		lm.buffer = d["lbuf"]
	lm.visible_instance_count = -1
	_branches.custom_aabb = d["aabb"]
	_leaves.custom_aabb = d["aabb"]


## BARK: 0 plain, 1 veins, 2 julia (tree.gdshader). One uniform; no rebuild.
func set_bark(style: int) -> void:
	bark_style = style
	if _branch_mat != null:
		_branch_mat.set_shader_parameter(&"bark_style", style)


## FLOOR's fallen leaves (tree_litter.gd): a shared litter MultiMesh under a node of its own, drawn
## with this tree's leaf material, so the discs wear its leaf colour and shape and grow and wither
## with it. The node is scaled to the crown's reach, so it rides a walk recycle for free.
func set_litter(on: bool) -> void:
	litter_on = on
	_sync_litter()


## The forest's LOD pass: only the nearest trees spend a draw on litter (the shader fades it out
## before the line, so nothing pops).
func set_litter_near(near: bool) -> void:
	if near == litter_near:
		return
	litter_near = near
	_sync_litter()


func litter_node() -> MultiMeshInstance3D:
	return _litter


func _litter_shows() -> bool:
	return litter_on and litter_near and not far and _branches != null and _branches.visible \
		and branch_count > 0


func _sync_litter() -> void:
	if not litter_on:
		if _litter != null:
			_litter.visible = false
		return
	if _branches == null or not built or branch_count == 0:
		return
	if _litter == null:
		_litter = MultiMeshInstance3D.new()
		_litter.name = "Litter"
		_litter.material_override = _leaf_mat
		_litter.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# Per node, not per material: the leaf MultiMesh shares the material and stays a canopy.
		_litter.set_instance_shader_parameter(&"litter", 1.0)
		add_child(_litter)
	_litter.multimesh = TreeLitter.shape(seed_value)
	# Unit frame: radius 1 is the crown's reach, the larger of its two floor half-extents.
	var box: AABB = shape_data.get("aabb", AABB(Vector3(-1, 0, -1), Vector3(2, 1, 2)))
	var reach := maxf(maxf(-box.position.x, box.end.x), maxf(-box.position.z, box.end.z))
	reach = clampf(reach * 0.9, 0.3, height_m * 0.6)
	_litter.transform = Transform3D(Basis(Vector3.UP, float(seed_value % 360) * 0.0174533)
		.scaled(Vector3(reach, reach, reach)), Vector3.ZERO)
	_litter.custom_aabb = AABB(Vector3(-1.1, -0.05, -1.1), Vector3(2.2, 0.2, 2.2))
	_litter.visible = _litter_shows()


## Handed to the far batch: the tree's own nodes go dark and give their buffers back. The
## shape, counts and clock stay, so it can come back with adopt().
func release() -> void:
	far = true
	if _branches == null:
		return
	_branches.visible = false
	_leaves.visible = false
	if _litter != null:
		_litter.visible = false
	_branches.multimesh.instance_count = 0
	_leaves.multimesh.instance_count = 0


## How much of a shape the far batch draws: the largest run of whole levels from the trunk
## that fits `cap` branches (at least the trunk), and the first `leaf_cap` leaves, a fair
## sample since a forest tree's leaves are shuffled.
static func far_counts(d: Dictionary, cap: int, leaf_cap: int) -> Vector2i:
	var ends: PackedInt32Array = d["level_ends"]
	var nb := 0
	for e in ends:
		if e > cap:
			break
		nb = e
	if nb == 0 and not ends.is_empty():
		nb = mini(ends[0], cap)
	return Vector2i(nb, mini(int(d["n_l"]), leaf_cap))


## A uniform sample of `room` segments from the level waiting in queue[head..], kept in
## queue order so the levels stay contiguous for LOD. Every kept segment is a tip.
static func _sample_level(queue: Array, head: int, room: int, rng: RandomNumberGenerator) -> Array:
	var n := queue.size() - head
	var idx: Array[int] = []
	idx.resize(n)
	for i in n:
		idx[i] = i
	for i in room:
		var j := rng.randi_range(i, n - 1)
		var t := idx[i]
		idx[i] = idx[j]
		idx[j] = t
	var pick := idx.slice(0, room)
	pick.sort()
	var out: Array = []
	for i in pick:
		var s: Array = (queue[head + i] as Array).duplicate()
		s[7] = true
		out.append(s)
	return out


static func _rgb(c: Color) -> Vector3:
	return Vector3(c.r, c.g, c.b)


## The colour a species announces itself with (the planting ring uses it): its tint if
## it has one, otherwise null and the caller keeps the theme colour.
static func species_tint(s: String) -> Variant:
	var p: Dictionary = SHAPES.get(s, {})
	if float(p.get("leaf_mix", 0.0)) > 0.0:
		return p["leaf_tint"]
	return null


## Instances drawn at LOD k: whole outer levels of twigs dropped, and a fair share of the
## leaves. Never below the trunk and its first two levels.
func lod_branches(k: int) -> int:
	if level_ends.is_empty():
		return 0
	var keep := maxi(level_ends.size() - k, mini(3, level_ends.size()))
	return level_ends[keep - 1]


func lod_leaves(k: int) -> int:
	return int(ceil(float(leaf_count) * LEAF_LOD[clampi(k, 0, LOD_MAX)]))


func lod_cost(k: int) -> int:
	return lod_branches(k) + (lod_leaves(k) if leaves_on else 0)


func set_lod(k: int) -> void:
	k = clampi(k, 0, LOD_MAX)
	if k == lod or not built or far or _branches == null:
		return
	lod = k
	_branches.multimesh.visible_instance_count = -1 if k == 0 else lod_branches(k)
	_leaves.multimesh.visible_instance_count = -1 if k == 0 else lod_leaves(k)


func regrow() -> void:
	grow_t = 0.0
	grow_rate = 1.0


func reseed() -> void:
	seed_value = randi() % 100000 + 1
	build()


func set_shape(s: String) -> void:
	if SHAPES.has(s):
		shape = s
		build()


func set_wind(w: float) -> void:
	wind = w


func set_leaves(on: bool) -> void:
	leaves_on = on
	if _leaves != null and not far:
		_leaves.visible = on


const _PAL_NAMES: Array[StringName] = [&"pal0", &"pal1", &"pal2", &"pal3", &"pal4"]


func set_palette_phase(p: float) -> void:
	palette_phase = p
	if _branch_mat == null:
		return
	_branch_mat.set_shader_parameter(&"palette_phase", p)
	_leaf_mat.set_shader_parameter(&"palette_phase", p)


## Far or not yet adopted, only kept: adopt() applies it. A far tree costs nothing on a
## theme blend, which recolours every frame of the blend.
func set_palette(pal: Array) -> void:
	_palette = pal
	_palette_stale = _branch_mat == null or far
	if _palette_stale:
		return
	for m in [_branch_mat, _leaf_mat]:
		for i in mini(5, pal.size()):
			m.set_shader_parameter(_PAL_NAMES[i], pal[i])


## Per frame while showing: growth clock and the wind field, in the tree's own frame so
## grabbing and tilting the cloud carry the sway with it. A tree still waiting to sprout
## (negative clock), or drawn by the far batch, is hidden and costs one add.
##
## Only what moved is written. Past grow_s + 2 every branch and leaf in the shaders is fully
## out, so the clock stops being fed there; a tree that has neither moved nor felt the wind
## change since the last frame then costs two transform reads and no uniform writes.
func tick(delta: float) -> void:
	grow_t += delta * grow_rate
	if far or _branches == null:
		return
	if grow_t <= 0.0:
		_branches.visible = false
		_leaves.visible = false
		if _litter != null:
			_litter.visible = false
		return
	if not _branches.visible:
		_branches.visible = true
		_leaves.visible = leaves_on
		if _litter != null:
			_litter.visible = _litter_shows()
	var xf := global_transform
	var wxf := wind_ref.global_transform if wind_ref != null else xf
	var g := minf(grow_t, grow_s + 2.0)
	var moved := not _fed or xf != _fed_xf or wxf != _fed_wxf or wind != _fed_wind
	if not _fed or g != _fed_g:
		_branch_mat.set_shader_parameter(&"grow_t", g)
		_leaf_mat.set_shader_parameter(&"grow_t", g)
		_fed_g = g
	if not moved:
		return
	_fed = true
	_fed_xf = xf
	_fed_wxf = wxf
	_fed_wind = wind
	var up := xf.basis.y.normalized()
	var scale := xf.basis.get_scale().y
	# One wind for a whole forest: a planted tree's random yaw used to give it a private
	# wind direction. The gust reaches a tree later the further downwind it stands.
	var wdir := wxf.basis.x.normalized()
	# Measured from the wind's owner, not the world origin: the walking avenue slides its
	# trees toward you every frame, and a phase taken from world position turned that slide
	# into a faster or slower sway (a Doppler shift on the wind).
	var phase := -wdir.dot(xf.origin - wxf.origin) * 0.9 if wind_ref != null else 0.0
	for m in [_branch_mat, _leaf_mat]:
		m.set_shader_parameter(&"wind", wind)
		m.set_shader_parameter(&"tree_origin", xf.origin)
		m.set_shader_parameter(&"tree_up", up)
		m.set_shader_parameter(&"tree_scale", scale)
		m.set_shader_parameter(&"wind_dir", wdir)
		m.set_shader_parameter(&"sway_phase", phase)


func draws_own() -> bool:
	return is_inside_tree() and visible and _branches != null and _branches.visible \
		and _branches.multimesh.instance_count > 0


func grow_progress() -> float:
	return clampf(grow_t / (grow_s + 1.0), 0.0, 1.0)
