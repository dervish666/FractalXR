extends Node3D
class_name FractalTree

## A fractal tree as real geometry: a MultiMesh of tapered cylinders grown by recursive
## branching, and a second MultiMesh of glowing leaf discs at the tips. Everything that
## moves is in the shaders (tree.gdshader, tree_leaf.gdshader): growth from the base up
## over GROW_S seconds, and a wind field that bends the whole tree coherently by height,
## so the script builds once per (shape, depth, seed) and then only feeds time and wind.
##
## Sits as a child of the ParticleCloud so grab, scale and spin apply unchanged.

const GROW_S := 6.0            # seconds from seed to full canopy
const MAX_BRANCHES := 80000     # a Quest draws this many 6-sided cylinders comfortably

## Shape presets. `branches` children per node, `angle` tilt from the parent in radians,
## `ratio` length per level, `radius_ratio` thickness per level, `twist` azimuth step
## between siblings, `jitter` randomness 0..1, `droop` bends children toward the ground
## (negative reaches up), `apical` keeps a leader growing straight up the trunk with a
## whorl of `branches` side branches at every level, each of which then splits
## `side_branches` ways (conifers), `height_m` the finished tree's height.
const SHAPES := {
	"oak": {"branches": 3, "depth": 9, "angle": 0.55, "ratio": 0.74, "radius_ratio": 0.68,
		"twist": 0.9, "jitter": 0.5, "droop": -0.15, "apical": false, "height_m": 4.8,
		"trunk_r": 0.10, "leaf_size": 0.09},
	"pine": {"branches": 5, "side_branches": 3, "depth": 9, "angle": 1.15, "ratio": 0.5,
		"radius_ratio": 0.5, "twist": 0.6, "jitter": 0.3, "droop": 0.35, "apical": true,
		"height_m": 6.0, "trunk_r": 0.09, "leaf_size": 0.05},
	"willow": {"branches": 3, "depth": 9, "angle": 0.7, "ratio": 0.78, "radius_ratio": 0.66,
		"twist": 1.2, "jitter": 0.6, "droop": 0.55, "apical": false, "height_m": 4.2,
		"trunk_r": 0.11, "leaf_size": 0.06},
	"coral": {"branches": 4, "depth": 8, "angle": 0.9, "ratio": 0.66, "radius_ratio": 0.62,
		"twist": 0.5, "jitter": 0.7, "droop": -0.3, "apical": false, "height_m": 3.2,
		"trunk_r": 0.13, "leaf_size": 0.12},
}
const SHAPE_NAMES := ["oak", "pine", "willow", "coral"]

var shape := "oak"
var depth_delta := 0
var seed_value := 1
var wind := 0.3
var leaves_on := true
var branch_count := 0
var leaf_count := 0
var height_m := 0.0
var grow_t := 0.0

var _branches: MultiMeshInstance3D
var _leaves: MultiMeshInstance3D
var _branch_mat: ShaderMaterial
var _leaf_mat: ShaderMaterial
var _rng := RandomNumberGenerator.new()


func _init() -> void:
	name = "Tree"
	_branch_mat = ShaderMaterial.new()
	_branch_mat.shader = load("res://shaders/tree.gdshader")
	_leaf_mat = ShaderMaterial.new()
	_leaf_mat.shader = load("res://shaders/tree_leaf.gdshader")
	_branches = MultiMeshInstance3D.new()
	_branches.name = "Branches"
	_branches.material_override = _branch_mat
	_branches.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	var cyl := CylinderMesh.new()
	cyl.radial_segments = 6
	cyl.rings = 1
	cyl.top_radius = 1.0
	cyl.bottom_radius = 1.0
	cyl.height = 1.0
	cyl.cap_top = false
	cyl.cap_bottom = false
	mm.mesh = cyl
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
	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)
	lm.mesh = quad
	_leaves.multimesh = lm
	add_child(_leaves)
	# Displaced and grown in the shader; the flat bounds would cull a swaying canopy.
	var aabb := AABB(Vector3(-8.0, -0.5, -8.0), Vector3(16.0, 10.0, 16.0))
	_branches.custom_aabb = aabb
	_leaves.custom_aabb = aabb
	visible = false


func effective_depth() -> int:
	return clampi(int(SHAPES[shape]["depth"]) + depth_delta, 0, 12)


## Build the geometry for the current shape, depth and seed. Returns the branch count.
## Pure: the same inputs give the same tree, so a seed is a name for a tree.
func build() -> int:
	var sp: Dictionary = SHAPES[shape]
	var depth := effective_depth()
	_rng.seed = seed_value * 7919 + depth * 131 + SHAPE_NAMES.find(shape)
	var branches: int = sp["branches"]
	var angle: float = sp["angle"]
	var ratio: float = sp["ratio"]
	var rr: float = sp["radius_ratio"]
	var twist: float = sp["twist"]
	var jitter: float = sp["jitter"]
	var droop: float = sp["droop"]
	var apical: bool = sp["apical"]
	var side_branches: int = int(sp.get("side_branches", branches))
	var trunk_r: float = sp["trunk_r"]
	if depth <= 0:
		_branches.multimesh.instance_count = 0
		_leaves.multimesh.instance_count = 0
		branch_count = 0
		leaf_count = 0
		return 0

	# Segments: [pos, dir, len, r, level, dist, on_trunk]. Iterative, so depth is not a
	# stack risk.
	var segs: Array = []
	var stack: Array = [[Vector3.ZERO, Vector3.UP, 1.0, trunk_r, 0, 0.0, true]]
	while not stack.is_empty():
		var s: Array = stack.pop_back()
		segs.append(s)
		if segs.size() >= MAX_BRANCHES:
			break
		var level: int = s[4]
		if level + 1 >= depth:
			continue
		var tip: Vector3 = s[0] + s[1] * s[2]
		var pdir: Vector3 = s[1]
		var on_trunk: bool = s[6]
		var side := pdir.cross(Vector3.RIGHT if absf(pdir.x) < 0.9 else Vector3.FORWARD).normalized()
		# A conifer's whorl only happens on the trunk; its side branches split modestly.
		var n := branches if (not apical or on_trunk) else side_branches
		if jitter > 0.0 and _rng.randf() < jitter * 0.3:
			n += 1 if _rng.randf() < 0.5 else -1
		n = maxi(n, 1)
		var az0 := _rng.randf() * TAU
		var level_frac := float(level + 1) / float(depth)
		for k in n:
			var leader := apical and on_trunk and k == 0
			var tilt := angle * (1.0 + jitter * (_rng.randf() - 0.5))
			var lr := ratio
			if leader:
				tilt = angle * 0.12 * jitter * (_rng.randf() - 0.5)
				lr = 0.82
			var az := az0 + twist * float(k) + float(k) * TAU / float(n) + jitter * 0.4 * (_rng.randf() - 0.5)
			var d := pdir.rotated(side, tilt).rotated(pdir, az)
			# Droop: pull toward the ground more at the outer levels (willow), or lift.
			d = (d + Vector3.DOWN * droop * level_frac * (0.4 if leader else 1.0)).normalized()
			var ln: float = s[2] * lr * (1.0 + jitter * 0.4 * (_rng.randf() - 0.5))
			var r: float = s[3] * (0.85 if leader else rr)
			stack.append([tip, d, ln, r, level + 1, s[5] + s[2], leader])

	# Normalise so the tallest point sits at height_m, radii and lengths together.
	var top := 0.0
	for s in segs:
		top = maxf(top, (s[0] + s[1] * s[2]).y)
	var k := float(sp["height_m"]) / maxf(top, 1e-3)
	height_m = float(sp["height_m"])
	var total_dist := 0.0
	for s in segs:
		total_dist = maxf(total_dist, s[5] + s[2])

	# Branch buffer: 12 transform floats, 4 colour, 4 custom per instance.
	var n_b := segs.size()
	var buf := PackedFloat32Array()
	buf.resize(n_b * 20)
	var tips: Array = []
	var leaf_size: float = sp["leaf_size"]
	for i in n_b:
		var s: Array = segs[i]
		var pos: Vector3 = s[0] * k
		var dir: Vector3 = s[1]
		var ln: float = s[2] * k
		var r: float = s[3] * k
		var level: int = s[4]
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
		# Colour: the palette position by level; the shader mixes the real palette.
		buf[o + 12] = level_frac; buf[o + 13] = 0.0; buf[o + 14] = 0.0; buf[o + 15] = 1.0
		# Custom: birth (0..1 along the growth), taper (child radius / own), level, phase.
		var birth: float = (s[5] * k) / maxf(total_dist * k, 1e-3)
		var taper: float = rr if level + 1 < depth else 0.35
		buf[o + 16] = birth; buf[o + 17] = taper; buf[o + 18] = level_frac
		buf[o + 19] = _rng.randf() * TAU
		if level + 1 >= depth or (level + 2 >= depth and _rng.randf() < 0.5):
			tips.append([pos + dir * ln, birth, level_frac, r])
	var mm := _branches.multimesh
	mm.instance_count = 0
	mm.instance_count = n_b
	if n_b > 0:
		mm.buffer = buf
	branch_count = n_b

	# Leaves: a disc at every tip, a couple more scattered along the outermost branches.
	var n_l := tips.size()
	var lbuf := PackedFloat32Array()
	lbuf.resize(n_l * 20)
	for i in n_l:
		var t: Array = tips[i]
		var p: Vector3 = t[0]
		var sz := leaf_size * (0.7 + 0.6 * _rng.randf())
		var o := i * 20
		lbuf[o + 0] = sz; lbuf[o + 1] = 0.0; lbuf[o + 2] = 0.0; lbuf[o + 3] = p.x
		lbuf[o + 4] = 0.0; lbuf[o + 5] = sz; lbuf[o + 6] = 0.0; lbuf[o + 7] = p.y
		lbuf[o + 8] = 0.0; lbuf[o + 9] = 0.0; lbuf[o + 10] = sz; lbuf[o + 11] = p.z
		lbuf[o + 12] = _rng.randf(); lbuf[o + 13] = 0.0; lbuf[o + 14] = 0.0; lbuf[o + 15] = 1.0
		lbuf[o + 16] = float(t[1]); lbuf[o + 17] = 0.0; lbuf[o + 18] = float(t[2])
		lbuf[o + 19] = _rng.randf() * TAU
	var lm := _leaves.multimesh
	lm.instance_count = 0
	lm.instance_count = n_l
	if n_l > 0:
		lm.buffer = lbuf
	leaf_count = n_l
	_leaves.visible = leaves_on
	for m in [_branch_mat, _leaf_mat]:
		m.set_shader_parameter("tree_height", height_m)
		m.set_shader_parameter("grow_s", GROW_S)
	grow_t = 0.0
	return n_b


func regrow() -> void:
	grow_t = 0.0


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
	_leaves.visible = on


func set_palette(pal: Array) -> void:
	for m in [_branch_mat, _leaf_mat]:
		for i in mini(5, pal.size()):
			m.set_shader_parameter("pal%d" % i, pal[i])


## Per frame while showing: growth clock and the wind field, in the tree's own frame so
## grabbing and tilting the cloud carry the sway with it.
func tick(delta: float) -> void:
	grow_t += delta
	var xf := global_transform
	var up := xf.basis.y.normalized()
	var scale := xf.basis.get_scale().y
	for m in [_branch_mat, _leaf_mat]:
		m.set_shader_parameter("grow_t", grow_t)
		m.set_shader_parameter("wind", wind)
		m.set_shader_parameter("tree_origin", xf.origin)
		m.set_shader_parameter("tree_up", up)
		m.set_shader_parameter("tree_scale", scale)
		m.set_shader_parameter("wind_dir", xf.basis.x.normalized())


func grow_progress() -> float:
	return clampf(grow_t / (GROW_S + 1.0), 0.0, 1.0)
