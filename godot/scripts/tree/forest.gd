extends Node3D
class_name Forest

## Every tree in TREE mode except the hero: a sown grove of mixed species around the
## hero's trunk, the trees you plant with the trigger, and the slow succession that keeps
## the grove changing.
##
## Shape. A copse, not a wood you stand inside. Trees take root in a ring 0.75-1.6 m
## from the hero's trunk; the hero stands 2.2 m ahead of you, so the grove spans about
## 70 degrees of view, every tree is in front of you, and the near rim is knee-to-chest
## height half a metre beyond your reach. Tall inside, short at the rim, like a real
## copse, so nothing near you hides the hero. Grab still scales the lot, so the same
## grove becomes a tabletop diorama with a grip. Surrounding the viewer is what the
## within-reach rule warns against: every pixel pays and nothing reads as an object.
##
## Stillness. Child of the particle cloud so grab moves it, but the ambient spin turns
## only the hero about its own trunk (main.gd). Spinning the cloud orbited every planted
## tree around the hero, and a grove on a turntable sweeps trunks through the viewer.
##
## Cost. Every tree is two draws (a branch MultiMesh and a leaf MultiMesh). The grove is
## built under a per-tree branch cap that thins the outermost level evenly. A distance LOD
## drops outer twig levels and a share of the leaves (the buffers are ordered so a
## prefix is always a whole smaller tree), nearest-largest first, against an instance
## budget. The budget follows the measured GPU time: over 85% of the frame it shrinks,
## under 65% it grows back. On the headset that means thermal throttling thins the far
## trees instead of dropping frames.
##
## Building. A tree's geometry is computed on a worker thread (FractalTree.compute, pure), so
## the main thread only ever uploads a finished buffer: at most one upload per frame, each when
## its tree is about to sprout. A result is shared by every tree with the same species, seed,
## cap and height, so a big avenue draws its trees from a small library of shapes (COUNT).
##
## The avenue (AVENUE, WALK). Two rows either side of a path that starts at your feet and
## runs 50 m along the way you were facing, 2.5-3 m either side of you, trunks 3-4 m apart
## along each row. The hero steps aside (main.gd hides it): it would stand in the path,
## dead centre on the vanishing point. Growth rolls away from you as a wave (STAGGER_STEP
## per average step), and the crowns walk the theme's palette down the rows, the per-echo
## palette phase from ifs_echoes.gd (PHASE_SPAN), so colour rolls away too. Trees stand
## 3 m tall for an oak, so at 3-4 m spacing each crown keeps clear of the next and a row
## reads as trees, not a hedge (avenue_shot.sh shoots it from where you stand).
##
## WALK is the same rows with a held trigger. The viewer never moves: the avenue's root
## slides toward you along the path, at a held speed only, eased in and out over a
## second, level and straight, so letting go stops it. A fixed pool of trees is built once.
## A tree sprouts as it comes within 25 m, withers once it is behind you, and by 5 m behind
## it is hidden, moved to the far end of its row and left waiting to sprout again. Moving a
## tree is a transform and two uniforms, never a rebuild, so the walk costs no build at all
## once the pool is up and the avenue never ends.
##
## COUNT. The default is the avenue above (about 30 trees) and the 16-tree grove. Higher steps
## add rows behind the first, 2.6 m further out each and looser, then lengthen the avenue, so
## the spacing that keeps every crown clear of the next never tightens; the walk's pool and
## its sprouting distance grow with the length. The grove grows outward from the hero at the
## same density, clipped to stay 0.6 m in front of you. From 120 up, only the trees nearest you
## are drawn whole; the rest go to the far batch (far_forest.gd): a trunk, its first branches
## and a sample of its leaves, all trees of a species in one draw.

const GROVE_COUNT := 16
const GROVE_R_MIN := 0.75         # metres from the hero's trunk
const GROVE_R_MAX := 1.6          # hero is 2.2 m ahead: the rim stays 0.6 m clear of you
const GROVE_SPACING := 0.32       # trunk to trunk
const GROVE_H_INNER := 2.2        # metres, for a species of the oak's 4.8 m hero height
const GROVE_H_OUTER := 0.7
## A bigger grove's rim passes the default's 0.6 m clearance, so its spots are kept this far in
## front of you along the line to the hero (the default never comes near it).
const GROVE_EYE_CLEAR := 0.6
const GROVE_EYE_FALLBACK := Vector2(0.0, 2.2)
const TREE_CAP_MIN := 450         # branches, rim tree
const TREE_CAP_MAX := 1400        # branches, inner tree and every planted tree
const PLANT_MAX := 12             # hand-planted trees, as before
const PLANT_H := Vector2(0.5, 0.85)   # planted height as a share of the species hero height
const STAGGER_FIRST := 1.5        # seconds after the hero starts before the first sprout
const STAGGER_STEP := 0.85        # then one more tree about this often, inside out

## Instance budget (branches + leaves) for the whole forest, the hero excluded. COUNT's steps
## start higher and have their own ceilings (STEPS: 24000 and 40000 at the default); the
## governor moves it between BUDGET_MIN and the step's ceiling.
const BUDGET_START := 24000
const BUDGET_MIN := 6000           # about a full grove and planted set at the coarsest LOD
const GOVERN_S := 0.5
const LOD_SIZE := [0.45, 0.22, 0.11]  # height / distance above which LOD 0, 1, 2 apply

const SUCCESSION_S := 45.0        # roughly how often one grove tree withers and is replaced
const WITHER_RATE := -1.6         # growth clock speed while withering

enum Layout { GROVE, AVENUE, WALK }
const AVENUE_HALF_W := 2.75       # row line, metres either side of the path's centre
const AVENUE_HALF_W_JITTER := 0.25  # so trunks land 2.5-3.0 m out
const AVENUE_STEP := Vector2(3.0, 4.0)  # trunk to trunk along a row
const AVENUE_FIRST := 2.0         # the nearest trunks, metres ahead of your feet
const AVENUE_LEN := 50.0
const AVENUE_H := 3.0             # metres, for a species of the oak's 4.8 m hero height
const AVENUE_CAP_FAR := 700       # branches at the far end of a standing avenue (near: TREE_CAP_MAX)
const AVENUE_PHASE_SPAN := 0.8    # palette turns over AVENUE_LEN, as ifs_echoes' PHASE_SPAN
const AVENUE_PHASE_JITTER := 0.06
## Rows behind the first (COUNT above 30): this much further out each, with this much play, so
## an oak's 2-2.5 m crown clears its neighbour across and the outer rows read as a wood, not a
## plantation.
const ROW_GAP := 2.6
const ROW_GAP_JITTER := 0.5
const WALK_PER_ROW := 15          # a pool of 30 trees, built once for the walk, never rebuilt
## Held speed: a slow stroll, under the 1.3 m/s of a normal walk. 0.3 m/s read as too slow
## in the headset. The glide is constant, straight, held and level under a vignette, which is
## where steady speed near walking pace is tolerated; the ramp is what has to stay gentle.
const WALK_SPEED := 1.0
const WALK_EASE_S := 1.0          # seconds from still to full speed, and back: 1 m/s², 0.5 m to stop
const WALK_SPROUT := 25.0         # metres ahead at which a waiting tree sprouts
const WALK_WITHER := 1.5          # metres behind you at which a grown tree starts to wither
const WALK_RECYCLE := 5.0         # metres behind you by which it goes to the far end
const WAITING_T := -0.5           # a built pool tree held hidden (grow_rate 0) until its turn

## COUNT, the MAKE card's tile. n: the label, about the standing avenue's tree count. rows: rows
## each side of the path. len: metres. grove: trees sown round the hero. variants: shapes per
## species in the avenue (0: every tree its own seed, as before). near: avenue trees drawn whole,
## the rest go to the far batch (0: no far batch). far_size: height/distance under which a tree is
## far whatever the rank. far_b, far_l: at most this many branches and leaves in a far tree.
## budget, budget_max: the instance budget's start and the governor's ceiling.
##
## Why the bigger steps start higher. An instance is a 12-triangle twig or a 2-triangle leaf,
## so even 64k of them is a few hundred thousand triangles, small for a Quest 3; what costs on
## the headset is leaf fill close to you and draw calls, which `near` caps. Every tree near you
## still costs its coarsest LOD (about 300) before any detail, so 40 near trees and the far
## batch need most of a 24k budget just to stand: the start leaves the nearest few their twigs.
## The governor still owns the number on the headset and pulls it down if the GPU runs hot.
const STEPS := [
	{"n": 30, "rows": 1, "len": 50.0, "grove": 16, "variants": 0, "near": 0, "far_size": 0.11,
		"far_b": 0, "far_l": 0, "budget": 24000, "budget_max": 40000},
	{"n": 60, "rows": 2, "len": 50.0, "grove": 28, "variants": 0, "near": 0, "far_size": 0.11,
		"far_b": 0, "far_l": 0, "budget": 28000, "budget_max": 44000},
	{"n": 120, "rows": 3, "len": 70.0, "grove": 44, "variants": 0, "near": 40, "far_size": 0.11,
		"far_b": 64, "far_l": 120, "budget": 32000, "budget_max": 48000},
	{"n": 250, "rows": 4, "len": 108.0, "grove": 64, "variants": 6, "near": 40, "far_size": 0.11,
		"far_b": 40, "far_l": 72, "budget": 40000, "budget_max": 56000},
	{"n": 500, "rows": 6, "len": 144.0, "grove": 90, "variants": 6, "near": 40, "far_size": 0.11,
		"far_b": 24, "far_l": 40, "budget": 48000, "budget_max": 64000},
]
const VARIANT_SEED := 1000        # a species' library shapes are seeds VARIANT_SEED + 0..variants-1
## ROOTS (off by default): the inner rows' surface roots (tree_roots.gd) reach for the centre
## line and stop this far either side of it, so the walk down the middle stays clear.
const ROOT_CLEAR := 0.55
## Placement (uploads and far-batch writes) stops for the frame once this much of it is spent.
## Real microseconds, so a slower headset simply places fewer trees a frame.
const PLACE_BUDGET_US := 1000
## Avenue trees re-measured for near or far each frame: 500 trees go round in about 20 frames.
const TIER_SLICE := 24
## Shape computes handed to the worker pool per frame, and library keys made per frame.
const LAUNCH_PER_FRAME := 16
const KEYS_PER_FRAME := 64
## Removed trees freed per frame.
const FREE_PER_FRAME := 48
## Shapes kept for reuse. The 120 step's unique avenue and its grove need about 165 at once; a
## cap-1400 shape is about 170 KB of buffers, a grove sapling a third of that.
const SHAPE_CACHE_MAX := 200

var plant_mix := true             # each plant draws the next species from a shuffled bag
var succession := true
var roots_on := false
var grove_seed := 0               # 0 = random each sowing
var budget := BUDGET_START
var visible_cost := 0
var drawn_branches := 0           # instances drawn at the last LOD pass, near and far
var drawn_leaves := 0
var gpu_ms := 0.0
var count_idx := 0
## Shapes computed so far, and the compute time on the worker (the harness reads these).
var builds := 0
var build_us_max := 0
var build_us_sum := 0
## Main-thread placement: uploads into a tree's own MultiMeshes, and the slowest frame of it.
var adopts := 0
var adopt_us_max := 0
var place_us_max := 0
var tick_us_max := 0              # the slowest tick() as a whole, its LOD half, its far upload
var lod_us_max := 0
var flush_us_max := 0
var last_tick_us := 0
var threaded := true              # false computes on the main thread, one a frame (comparison)
var layout := Layout.GROVE
var walk_held := false            # main.gd: a trigger is held and nothing else owns it
var walk_speed := 0.0             # m/s, eased
var walked := 0.0                 # metres walked since the avenue was sown
var recycles := 0                 # trees moved to the far end so far

var _trees: Array[FractalTree] = []
## The avenue's root, a child of the forest so grab carries it. _avenue_frame is where it was
## laid out (in the forest's space: origin at your feet, -Z down the path); the root sits
## _walk_s metres further toward you along +Z.
var _avenue := Node3D.new()
var _far := FarForest.new()
var _avenue_frame := Transform3D()
var _walk_s := 0.0
var _row_far := PackedFloat32Array([0.0, 0.0])   # the furthest trunk's z in each row
var _eye_z := 0.0                 # your z in the avenue's root frame, last tick
var _eye_world := Vector3.INF
var _wind := 0.3
var _leaves_on := true
var _palette: Array = []
var _rng := RandomNumberGenerator.new()
var _bag: Array[String] = []
var _next_plant := ""
var _clock := 0.0
var _govern_t := 0.0
var _succession_at := 0.0
## key -> {"data": compute() result or null, "holder": [result, us], "task": id}
var _shapes := {}
var _pending: Array = []
var _tier_cursor := 0
var _lod_next := false
var _placed_last := false
var _launched := 0
var _keyed := 0
var _graveyard: Array[FractalTree] = []
var _sow_row := 0
var _sow_row_end := 0
var _sow_selected := ""
var _wave_near := INF


func _init() -> void:
	name = "Forest"
	_rng.randomize()
	_avenue.name = "Avenue"
	add_child(_avenue)
	_avenue.add_child(_far)


func _notification(what: int) -> void:
	# Every task is waited on, finished or not, before the forest goes.
	if what == NOTIFICATION_PREDELETE:
		for e in _pending:
			WorkerThreadPool.wait_for_task_completion(int(e["task"]))
		_pending.clear()
		# Avenue trees the far batch drew were never added to the scene, so nothing frees them
		# with it; nor the buried ones still waiting their turn.
		for t in _trees + _graveyard:
			if is_instance_valid(t) and t.get_parent() == null:
				t.free()


func trees() -> Array[FractalTree]:
	return _trees


func tree_count() -> int:
	return _trees.size()


func planted_count() -> int:
	var n := 0
	for t in _trees:
		if t.hand_planted:
			n += 1
	return n


func branch_total() -> int:
	var n := 0
	for t in _trees:
		n += t.branch_count
	return n


func leaf_total() -> int:
	var n := 0
	for t in _trees:
		n += t.leaf_count
	return n


func can_plant() -> bool:
	return planted_count() < PLANT_MAX


func step() -> Dictionary:
	return STEPS[count_idx]


func far_batch() -> FarForest:
	return _far


func shapes_cached() -> int:
	return _shapes.size()


## Trees drawing with their own two MultiMeshes this frame (the harness checks the far batch
## really took the rest).
func whole_drawn() -> int:
	var n := 0
	for t in _trees:
		if t.draws_own():
			n += 1
	return n


func shapes_pending() -> int:
	return _pending.size()


## COUNT: pick a step. The caller sows again; the budget restarts at the step's own.
func set_count(i: int) -> void:
	count_idx = clampi(i, 0, STEPS.size() - 1)
	budget = int(step()["budget"])
	_far.configure(maxi(1, int(step()["far_b"])), maxi(1, int(step()["far_l"])))


func avenue_len() -> float:
	return float(step()["len"])


func walk_per_row() -> int:
	return int(round(WALK_PER_ROW * avenue_len() / AVENUE_LEN))


func walk_sprout() -> float:
	return WALK_SPROUT * avenue_len() / AVENUE_LEN


func walk_pool() -> int:
	return walk_per_row() * 2 * int(step()["rows"])


func _far_on() -> bool:
	return int(step()["near"]) > 0


func set_wind(w: float) -> void:
	_wind = w
	for t in _trees:
		t.set_wind(w)


func set_leaves(on: bool) -> void:
	_leaves_on = on
	for t in _trees:
		t.set_leaves(on)
	_far.set_leaves(on)


func set_palette(pal: Array) -> void:
	_palette = pal
	for t in _trees:
		t.set_palette(pal)
	_far.set_palette(pal)


## ROOTS: surface roots on the avenue's inner rows, bent toward the path. Trees drawn whole
## get them now and as they come near; far ones never carry them.
func set_roots(on: bool) -> void:
	roots_on = on
	for t in _trees:
		_fit_roots(t)


## Give `t` its roots, turned toward the centre line and scaled so the tips stop ROOT_CLEAR short
## of it, or take them away. A transform on a shared MultiMesh, so a walk recycle is free.
func _fit_roots(t: FractalTree) -> void:
	if not roots_on or t.row < 0 or t.row > 1 or t.far or not t.is_inside_tree():
		if t.roots_node() != null:
			t.set_roots(null, Transform3D(), AABB())
		return
	var v := TreeRoots.shape(t.seed_value)
	var tb := t.transform.basis
	var s := tb.get_scale().y
	# Unit frame +X along the floor toward the path: +X for the left row, -X for the right.
	var toward := Basis(Vector3.UP, 0.0 if t.position.x < 0.0 else PI)
	var k := (absf(t.position.x) - ROOT_CLEAR) / (TreeRoots.REACH * s)
	var local := tb.orthonormalized().inverse() * toward * Basis.from_scale(Vector3.ONE * k)
	t.set_roots(v["mm"], Transform3D(local, Vector3.ZERO), v["aabb"])


func set_plant_mix(on: bool) -> void:
	plant_mix = on
	_next_plant = ""


func set_succession(on: bool) -> void:
	succession = on
	_succession_at = _clock + SUCCESSION_S


## A fresh grove of mixed species around the hero. Hand-planted trees stay.
func sow_grove() -> void:
	for t in _trees.duplicate():
		if not t.hand_planted:
			_remove(t)
	_set_layout(Layout.GROVE)
	if grove_seed != 0:
		_rng.seed = grove_seed
		grove_seed += 1
	var count: int = step()["grove"]
	var spots: Array[Vector2] = []
	var taken: Array[Vector2] = _occupied()
	for i in count:
		var p: Variant = _free_spot(taken)
		if p == null:
			break
		spots.append(p)
		taken.append(p)
	# Inside out: the grove spreads from the hero's feet like seed falling from it. A bigger
	# grove staggers faster, so it fills in about sqrt(count) times the default's time.
	spots.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.length() < b.length())
	var stagger := STAGGER_STEP * minf(1.0, sqrt(float(GROVE_COUNT) / float(count)))
	for i in spots.size():
		var t := _grove_tree(_draw_species(), spots[i])
		t.sprout_delay = STAGGER_FIRST + stagger * float(i) + _rng.randf() * 0.5
		t.grow_t = -t.sprout_delay
	_succession_at = _clock + SUCCESSION_S * _rng.randf_range(0.8, 1.2) + float(spots.size()) * stagger


## Regrow every tree from seed, staggered as when it was sown; an empty forest is sown.
func regrow() -> void:
	if _trees.is_empty():
		sow_grove()
		return
	# The avenue regrows as a wave from where you stand now, which after a walk is not where
	# it was sown; trees you planted regrow as before. A far tree's birth is baked into the far
	# batch, so it is taken out and put back with the new one.
	if layout != Layout.GROVE:
		for t in _trees:
			if t.far:
				_far.drop(t)
				t.unplace()
		_walk_wave(walk_sprout() if layout == Layout.WALK else INF, true)
	for t in _trees.duplicate():
		if t.row >= 0:
			continue
		if t.grow_rate < 0.0:
			_remove(t)
			continue
		t.regrow()
		t.grow_t = -t.sprout_delay


func clear() -> void:
	for t in _trees:
		_bury(t)
	_trees.clear()
	_far.clear()
	_sow_row_end = 0
	_set_layout(Layout.GROVE)


func walking() -> bool:
	return layout == Layout.WALK


## 0 still, 1 at full walking speed: what a comfort vignette should follow.
func walk_motion() -> float:
	return walk_speed / WALK_SPEED


## The avenue: two rows from your feet down the way `eye` faces (more behind them at higher
## COUNT). Every tree goes, planted ones too, since they would stand still while a walk slid the
## rows past them. MIX picks the species as it does for planting: the bag, or `selected` for the
## whole avenue. `walk` builds the fixed pool instead, with only the nearest sprouting.
##
## The two rows beside the path are sown on the press; each row further out on a frame of its
## own after it (tick), so 500 trees never land in one frame. They join the wave where it
## already is, and the next LOD pass ranks them near or far.
func sow_avenue(eye: Transform3D, walk: bool, selected: String) -> void:
	clear()
	_set_layout(Layout.WALK if walk else Layout.AVENUE)
	if grove_seed != 0:
		_rng.seed = grove_seed
		grove_seed += 1
	place_avenue(eye)
	_eye_world = eye.origin
	_row_far.resize(2 * int(step()["rows"]))
	_sow_selected = selected
	_sow_rows(0, 2, walk)
	_wave_near = INF
	_walk_wave(walk_sprout() if walk else INF, true)
	_sow_row = 2
	_sow_row_end = 2 * int(step()["rows"])


## True while outer rows are still to come.
func sowing() -> bool:
	return _sow_row < _sow_row_end and layout != Layout.GROVE


## Rows [from, to): even rows left of the path, odd right, each pair a ring further out.
func _sow_rows(from: int, to: int, walk: bool) -> Array[FractalTree]:
	var st := step()
	var length := avenue_len()
	var variants: int = st["variants"]
	var per_row := walk_per_row()
	var mean := (AVENUE_STEP.x + AVENUE_STEP.y) * 0.5
	var selected := _sow_selected
	var made: Array[FractalTree] = []
	for row in range(from, to):
		var z := -AVENUE_FIRST - _rng.randf_range(0.0, mean * 0.5)
		var n := 0
		while (walk and n < per_row) or (not walk and -z <= length):
			var far01 := clampf((-z - AVENUE_FIRST) / (length - AVENUE_FIRST), 0.0, 1.0)
			var cap := TREE_CAP_MAX if walk else int(lerpf(TREE_CAP_MAX, AVENUE_CAP_FAR, far01))
			var t := _new_tree(_draw_species() if plant_mix else selected, _avenue)
			t.wind_ref = _avenue
			var rel := clampf(float(FractalTree.SHAPES[t.shape]["height_m"]) / 4.8, 0.7, 1.35)
			var s := 1.0
			if variants > 0:
				# A library shape: the species' height exactly, the tree's own size in its scale,
				# one cap (the LOD and the far batch thin the distance instead).
				t.seed_value = VARIANT_SEED + _rng.randi_range(0, variants - 1)
				t.branch_cap = TREE_CAP_MAX
				t.target_height = AVENUE_H * rel
				s = _rng.randf_range(0.9, 1.1)
			else:
				t.branch_cap = cap
				t.target_height = AVENUE_H * rel * _rng.randf_range(0.9, 1.1)
			_place_in_row(t, row, z, s)
			_row_far[row] = z
			z -= _rng.randf_range(AVENUE_STEP.x, AVENUE_STEP.y)
			n += 1
			made.append(t)
	return made


## The next row of a big avenue, a frame after the last: sown, put into the wave at the same
## nearest trunk the first rows used, and measured against the far line.
func _sow_next_row() -> void:
	var walk := layout == Layout.WALK
	var made := _sow_rows(_sow_row, _sow_row + 1, walk)
	_sow_row += 1
	var near := _wave_near
	if near == INF:
		for t in made:
			near = minf(near, maxf(_eye_z - t.position.z, 0.0))
	_wave_trees(made, walk_sprout() if walk else INF, near)
	if _tiers_on():
		var eye := _avenue.to_local(_eye_world)
		var far_size: float = step()["far_size"]
		for t in made:
			_judge(t, eye, far_size)


## Re-lay the avenue from where you stand now, facing where you face (entering TREE, or a
## recentre). The trees keep their places along the path relative to you.
func place_avenue(eye: Transform3D) -> void:
	if layout == Layout.GROVE:
		return
	var fwd := -eye.basis.z
	fwd.y = 0.0
	if fwd.length_squared() < 1e-4:
		fwd = Vector3.FORWARD
	var feet := Transform3D(Basis.looking_at(fwd.normalized(), Vector3.UP),
		Vector3(eye.origin.x, 0.0, eye.origin.z))
	_avenue_frame = global_transform.affine_inverse() * feet
	walk_speed = 0.0
	_avenue.transform = _avenue_frame.translated_local(Vector3(0.0, 0.0, _walk_s))
	_eye_z = -_walk_s


## Stop walking and keep the avenue: the trees still waiting beyond the sprouting distance
## sprout in a wave, and the trigger plants again.
func stand_still() -> void:
	if layout != Layout.WALK:
		return
	_set_layout(Layout.AVENUE)
	_walk_wave(INF, false)


## The species the next plant will be: the selected one, or the next from the bag. The
## planting ring shows this, so what it promises is what grows.
func peek_plant(selected: String) -> String:
	if not plant_mix:
		return selected
	if _next_plant == "":
		_next_plant = _draw_species()
	return _next_plant


## Plant at a world floor point (x, z). Unit scale in the world, like before: grab may
## have shrunk the grove to a tabletop, but a tree planted on the floor is floor-sized.
## It sprouts once its shape is computed, a frame or two later.
func plant_at(hit: Vector2, selected: String) -> FractalTree:
	if not can_plant():
		return null
	var species := peek_plant(selected)
	_next_plant = ""
	var t := _new_tree(species)
	t.hand_planted = true
	var sh: float = FractalTree.SHAPES[species]["height_m"]
	t.target_height = sh * _rng.randf_range(PLANT_H.x, PLANT_H.y)
	t.branch_cap = TREE_CAP_MAX
	var yaw := _rng.randf() * TAU
	t.global_transform = Transform3D(Basis(Vector3.UP, yaw), Vector3(hit.x, 0.0, hit.y))
	_shape_of(t)
	return t


## Per frame in tree mode. `cam` is the eye in world space, for the LOD.
func tick(delta: float, cam: Vector3) -> void:
	_clock += delta
	_eye_world = cam
	var t0 := Time.get_ticks_usec()
	_launched = 0
	_keyed = 0
	_free_some()
	_poll_shapes()
	if sowing():
		_sow_next_row()
	if layout == Layout.WALK:
		_tick_walk(delta, cam)
	_tier_slice()
	# The LOD pass, split over two frames so neither carries all of it: the governor and the
	# near/far ranking, then the detail per tree. It runs before placement, which gets what
	# is left of PLACE_BUDGET_US.
	_govern_t += delta
	if _lod_next:
		_lod_next = false
		var l0 := Time.get_ticks_usec()
		_lod_items(cam)
		lod_us_max = maxi(lod_us_max, Time.get_ticks_usec() - l0)
	elif _govern_t >= GOVERN_S:
		_govern_t = 0.0
		var l0 := Time.get_ticks_usec()
		_govern()
		if _tiers_on():
			_rank_near()
		_lod_next = true
		lod_us_max = maxi(lod_us_max, Time.get_ticks_usec() - l0)
	var adopted := false
	var placed := 0
	var spent := Time.get_ticks_usec() - t0
	# A frame whose walk and LOD used the budget up places nothing, unless the last one did not
	# either: placement never stalls for more than a frame.
	var budget_us := PLACE_BUDGET_US if spent < PLACE_BUDGET_US or not _placed_last else spent + 1
	var far_on := _far_on()
	var walk := layout == Layout.WALK
	for t in (_trees if walk else _trees.duplicate()):
		# A far tree's clock is all it needs here: the batch draws it. A pool tree waiting
		# unplaced at the far end needs nothing at all.
		if t.far and t.tier_far:
			t.grow_t += delta * t.grow_rate
			continue
		if far_on and not t.built and t.grow_rate == 0.0:
			continue
		# Placement: a tree is uploaded into its own MultiMeshes just before it sprouts, one a
		# frame, or written into the far batch as soon as its shape and schedule are known; a
		# tree crossing between the two moves when the frame has the time.
		if not t.built:
			var d: Variant = _shape_of(t)
			if d != null and spent < budget_us:
				if t.tier_far:
					if t.grow_rate > 0.0:
						_put_far(t, d)
						placed += 1
				elif t.grow_t > -0.75 and not adopted and (t.grow_rate != 0.0 or not far_on):
					# (A waiting pool tree is built at once only without a far batch, as
					# before; with one, it sprouts far off and the batch takes it.)
					_adopt(t, d, true)
					adopted = true
					placed += 1
				spent = Time.get_ticks_usec() - t0
		elif t.tier_far != t.far and spent < budget_us:
			if t.tier_far:
				if t.grow_rate > 0.0:
					_put_far(t, t.shape_data)
					placed += 1
			elif not adopted:
				_adopt(t, t.shape_data, false)
				_far.drop(t)
				adopted = true
				placed += 1
			spent = Time.get_ticks_usec() - t0
		if t.built:
			t.tick(delta)
		else:
			t.grow_t += delta * t.grow_rate   # a waiting tree (rate 0) holds its place
		# A withered pool tree is recycled by _tick_walk, never freed.
		if t.grow_rate < 0.0 and t.grow_t <= 0.0 and not walk:
			_remove(t)
	if placed > 0:
		place_us_max = maxi(place_us_max, Time.get_ticks_usec() - t0)
	_placed_last = placed > 0
	var f0 := Time.get_ticks_usec()
	_far.flush(_clock)
	flush_us_max = maxi(flush_us_max, Time.get_ticks_usec() - f0)
	last_tick_us = Time.get_ticks_usec() - t0
	tick_us_max = maxi(tick_us_max, last_tick_us)
	# Succession reseeds the grove's ring; the avenue has no ring to reseed.
	if succession and layout == Layout.GROVE:
		_tick_succession()


## Upload a shape into the tree's own nodes. A fresh tree starts its clock no later than now,
## as a build always did; one coming back from the far batch keeps its place in its growth.
func _adopt(t: FractalTree, d: Dictionary, fresh: bool) -> void:
	var keep := t.grow_t
	var u0 := Time.get_ticks_usec()
	if not t.is_inside_tree():
		_avenue.add_child(t)
	t.adopt(d)
	if roots_on:
		_fit_roots(t)
	adopt_us_max = maxi(adopt_us_max, Time.get_ticks_usec() - u0)
	t.grow_t = minf(keep, 0.0) if fresh else keep
	adopts += 1


func _put_far(t: FractalTree, d: Dictionary) -> void:
	if not t.built:
		t.grow_t = minf(t.grow_t, 0.0)
	t.take_shape(d)
	_far.put(t, _clock - t.grow_t)
	t.release()


## The compute() result for a tree, or null while it is being computed (the first ask starts
## it). Threaded, any number may be in flight; otherwise one is computed per frame, here.
func _shape_of(t: FractalTree) -> Variant:
	# A key is a formatted string, about 3 us each: a sowing of 500 keys them over a few frames.
	if t.shape_key == "":
		if _keyed >= KEYS_PER_FRAME:
			return null
		_keyed += 1
	var e: Variant = _shapes.get(_key_of(t))
	if e != null:
		e["used"] = _clock
		return e["data"]
	# Handing a task to the pool costs the main thread too: a sowing of 120 new shapes asked
	# for them all in one frame. LAUNCH_PER_FRAME a frame instead, nearest rows first.
	if _launched >= LAUNCH_PER_FRAME:
		return null
	_launched += 1
	var spec := t.spec()
	var holder := [null, 0]
	var entry := {"data": null, "holder": holder, "task": -1, "used": _clock}
	_shapes[t.shape_key] = entry
	if threaded:
		entry["task"] = WorkerThreadPool.add_task(FractalTree.compute_into.bind(spec, holder),
			false, "tree shape")
		_pending.append(entry)
		return null
	FractalTree.compute_into(spec, holder)
	_finish_shape(entry)
	return entry["data"]


func _poll_shapes() -> void:
	var i := 0
	while i < _pending.size():
		var e: Dictionary = _pending[i]
		if WorkerThreadPool.is_task_completed(int(e["task"])):
			WorkerThreadPool.wait_for_task_completion(int(e["task"]))
			_finish_shape(e)
			_pending.remove_at(i)
		else:
			i += 1


func _finish_shape(e: Dictionary) -> void:
	e["data"] = e["holder"][0]
	var us: int = e["holder"][1]
	build_us_max = maxi(build_us_max, us)
	build_us_sum += us
	builds += 1
	if _shapes.size() > SHAPE_CACHE_MAX:
		_trim_shapes()


## The library key: everything compute() reads. Set once, when the tree's spec is final.
func _key_of(t: FractalTree) -> String:
	if t.shape_key == "":
		t.shape_key = "%s:%d:%d:%d:%.4f:%.3f:%s:%s" % [t.shape, t.seed_value, t.depth_delta,
			t.branch_cap, t.target_height, t.variety, "w" if t.whole_levels else "b",
			"s" if t.lod_ready else "o"]
	return t.shape_key


## Over SHAPE_CACHE_MAX, drop the finished shapes asked for longest ago until a quarter of the
## room is free again. A tree already wearing one keeps it (shape_data); a tree that asks again
## computes it again. No pass over the trees: at 500 that pass cost more than the sowing.
func _trim_shapes() -> void:
	var done: Array = []
	for k in _shapes:
		if _shapes[k]["data"] != null:
			done.append([float(_shapes[k]["used"]), k])
	done.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var drop := _shapes.size() - SHAPE_CACHE_MAX * 3 / 4
	for i in mini(drop, done.size()):
		_shapes.erase(done[i][1])


## The walk, before the trees tick: ease the speed toward the held target, slide the root
## toward you, then sprout, wither and recycle by each tree's distance ahead. No allocation:
## the loop walks the live array, and a recycle only moves a tree within it.
func _tick_walk(delta: float, cam: Vector3) -> void:
	var target := WALK_SPEED if walk_held else 0.0
	walk_speed = move_toward(walk_speed, target, WALK_SPEED / WALK_EASE_S * delta)
	if walk_speed > 0.0:
		_walk_s += walk_speed * delta
		walked += walk_speed * delta
		_avenue.transform = _avenue_frame.translated_local(Vector3(0.0, 0.0, _walk_s))
	_eye_z = _avenue.to_local(cam).z
	var sprout := walk_sprout()
	var far_on := _far_on()
	for t in _trees:
		if t.row < 0:
			continue   # not an avenue tree (planted)
		var ahead := _eye_z - t.position.z
		if ahead < -WALK_RECYCLE or (t.grow_rate < 0.0 and t.grow_t <= 0.0):
			_recycle(t)
		elif t.grow_rate == 0.0 and ahead < sprout:
			t.grow_rate = 1.0
			# Sprouting this far off, it is a far tree until it is measured again.
			t.tier_far = far_on
			t.tier_size = 0.0
		elif t.grow_rate > 0.0 and ahead < -WALK_WITHER:
			t.grow_t = minf(t.grow_t, t.grow_s + 1.0)
			t.grow_rate = WITHER_RATE


## A tree that has fallen behind goes to the far end of its own row, turned and resized a
## little so a pool of thirty does not read as the same thirty trees, and waits there,
## hidden, to sprout at the sprouting distance. With a far batch it also gives back its
## buffers: it will sprout far away, where the batch draws it.
func _recycle(t: FractalTree) -> void:
	var row := t.row
	var z := _row_far[row] - _rng.randf_range(AVENUE_STEP.x, AVENUE_STEP.y)
	_row_far[row] = z
	_place_in_row(t, row, z, _rng.randf_range(0.9, 1.1))
	t.grow_t = WAITING_T
	t.grow_rate = 0.0
	t.tier_far = false
	if t.far:
		_far.drop(t)
	if _far_on():
		t.unplace()
	elif roots_on:
		_fit_roots(t)   # its turn and size changed with the move
	recycles += 1


## Trunk on the row line (left is row 0, rows behind the first further out), a random turn
## about it, and a palette phase from how far down the avenue it stands, so colour rolls away
## from you as growth does.
func _place_in_row(t: FractalTree, row: int, z: float, s: float) -> void:
	var ring := row / 2
	var jitter := AVENUE_HALF_W_JITTER if ring == 0 else ROW_GAP_JITTER
	var x := (-1.0 if row % 2 == 0 else 1.0) * (AVENUE_HALF_W + ROW_GAP * float(ring)
		+ _rng.randf_range(-jitter, jitter))
	t.row = row
	t.tier_h = t.target_height * s
	t.transform = Transform3D(Basis(Vector3.UP, _rng.randf() * TAU).scaled(Vector3(s, s, s)),
		Vector3(x, 0.0, z))
	t.set_palette_phase(AVENUE_PHASE_SPAN * -z / AVENUE_LEN
		+ _rng.randf_range(-AVENUE_PHASE_JITTER, AVENUE_PHASE_JITTER))


## Growth as a wave rolling away from you: each avenue tree within `reach` sprouts after a
## delay that grows by STAGGER_STEP per average trunk step past the nearest one taking part,
## and the rest wait, built and hidden. `all` restarts every tree; otherwise only the ones
## already waiting join (WALK switched off, so the far end grows in).
func _walk_wave(reach: float, all: bool) -> void:
	var near := INF
	var joining: Array[FractalTree] = []
	for t in _trees:
		if t.row >= 0 and (all or t.grow_rate == 0.0):
			near = minf(near, maxf(_eye_z - t.position.z, 0.0))
			joining.append(t)
	_wave_near = near
	_wave_trees(joining, reach, near)
	_assign_tiers()


## The wave's schedule for `trees`, measured from the trunk `near` metres ahead.
func _wave_trees(trees: Array[FractalTree], reach: float, near: float) -> void:
	var mean := (AVENUE_STEP.x + AVENUE_STEP.y) * 0.5
	for t in trees:
		var ahead := maxf(_eye_z - t.position.z, 0.0)
		if ahead < reach:
			t.sprout_delay = STAGGER_FIRST + STAGGER_STEP * (ahead - near) / mean + _rng.randf() * 0.3
			t.grow_t = -t.sprout_delay
			t.grow_rate = 1.0
		else:
			t.sprout_delay = 0.0
			t.grow_t = WAITING_T
			t.grow_rate = 0.0


func _set_layout(l: Layout) -> void:
	layout = l
	walk_speed = 0.0
	if l == Layout.GROVE:
		_walk_s = 0.0
		walked = 0.0
		_avenue.transform = Transform3D()


func _new_tree(species: String, parent: Node3D = self) -> FractalTree:
	var t := FractalTree.new()
	t.shape = species
	t.seed_value = _rng.randi_range(1, 100000)
	t.variety = 1.0
	t.whole_levels = true
	t.lod_ready = true
	t.wind_ref = self
	t.wind = _wind
	t.leaves_on = _leaves_on
	t.set_palette(_palette)
	t.visible = true
	# An avenue tree joins the scene when it is first uploaded (_adopt): one the far batch
	# draws never needs to, and 500 add_childs on the press frame were most of its cost.
	if parent != _avenue:
		parent.add_child(t)
	_trees.append(t)
	return t


func _grove_tree(species: String, spot: Vector2) -> FractalTree:
	var t := _new_tree(species)
	# A bigger grove keeps the default's copse exactly (tall inside, rim-high at 1.6 m) and
	# spreads past it as rim-high saplings, so nothing between you and the hero grows taller
	# than before and the extra trees never stand up as a wall at eye height.
	var size01 := 1.0 - clampf((spot.length() - GROVE_R_MIN) / (GROVE_R_MAX - GROVE_R_MIN), 0.0, 1.0)
	var rel := clampf(float(FractalTree.SHAPES[species]["height_m"]) / 4.8, 0.7, 1.35)
	t.target_height = lerpf(GROVE_H_OUTER, GROVE_H_INNER, size01) * rel * _rng.randf_range(0.85, 1.15)
	t.branch_cap = int(lerpf(TREE_CAP_MIN, TREE_CAP_MAX, size01))
	t.transform = Transform3D(Basis(Vector3.UP, _rng.randf() * TAU), Vector3(spot.x, 0.0, spot.y))
	return t


## The grove's outer radius at this COUNT: the default ring, or one whose area grows with the
## tree count so the density holds.
func _grove_r_max() -> float:
	var count: int = step()["grove"]
	if count <= GROVE_COUNT:
		return GROVE_R_MAX
	return sqrt(GROVE_R_MIN * GROVE_R_MIN
		+ float(count) / GROVE_COUNT * (GROVE_R_MAX * GROVE_R_MAX - GROVE_R_MIN * GROVE_R_MIN))


## Where you stand in the forest's floor plane, for a big grove's clearance. main.gd recentres
## before it sows, so on entering TREE this is already the hero 2.2 m ahead of you.
func _grove_eye() -> Vector2:
	var vp := get_viewport() if is_inside_tree() else null
	var cam := vp.get_camera_3d() if vp != null else null
	if cam == null:
		return GROVE_EYE_FALLBACK
	var e := to_local(cam.global_position)
	return Vector2(e.x, e.z)


func _remove(t: FractalTree) -> void:
	if t.far:
		_far.drop(t)
	_trees.erase(t)
	_bury(t)


## Out of sight at once, freed a few at a time by tick(): clearing 500 trees was 2 ms of frees
## on the press frame.
func _bury(t: FractalTree) -> void:
	if t.is_inside_tree():
		t.visible = false
	_graveyard.append(t)


func _free_some() -> void:
	for i in mini(FREE_PER_FRAME, _graveyard.size()):
		var t: FractalTree = _graveyard.pop_back()
		if t.get_parent() == null:
			t.free()
		else:
			t.queue_free()


func _draw_species() -> String:
	if _bag.is_empty():
		for s in FractalTree.SHAPE_NAMES:
			_bag.append(s)
		for i in range(_bag.size() - 1, 0, -1):
			var j := _rng.randi_range(0, i)
			var tmp := _bag[i]
			_bag[i] = _bag[j]
			_bag[j] = tmp
	return _bag.pop_back()


## Grove trees' trunks in the forest's own plane (hand-planted ones too, mapped back from
## the world), so new trees keep their distance from everything already standing.
func _occupied() -> Array[Vector2]:
	var out: Array[Vector2] = []
	for t in _trees:
		if t.grow_rate < 0.0:
			continue
		var p := to_local(t.global_transform.origin)
		out.append(Vector2(p.x, p.z))
	return out


func _free_spot(taken: Array[Vector2]) -> Variant:
	var r_max := _grove_r_max()
	# Only a grove bigger than the default can reach you; the default ring never does.
	var clip := r_max > GROVE_R_MAX
	var eye := _grove_eye() if clip else Vector2.ZERO
	var toward := eye.normalized() if clip else Vector2.ZERO
	var limit := eye.length() - GROVE_EYE_CLEAR
	for attempt in 40:
		var r := sqrt(_rng.randf_range(GROVE_R_MIN * GROVE_R_MIN, r_max * r_max))
		var p := Vector2.from_angle(_rng.randf() * TAU) * r
		var ok := not clip or p.dot(toward) <= limit
		if ok:
			for q in taken:
				if p.distance_to(q) < GROVE_SPACING:
					ok = false
					break
		if ok:
			return p
	return null


## Shrink the forest budget when the GPU is near the frame, grow it back when it is not.
## The hero is never thinned: it is the tree you chose.
func _govern() -> void:
	var vp := get_viewport()
	if vp == null:
		return
	var g := RenderingServer.viewport_get_measured_render_time_gpu(vp.get_viewport_rid())
	if g <= 0.0:
		return  # headless, or the Mac (no GPU timings): no evidence, so no change
	var hz := 72.0
	var xri := XRServer.primary_interface
	if xri != null and xri.has_method("get_display_refresh_rate"):
		var r: float = xri.call("get_display_refresh_rate")
		if r > 1.0:
			hz = r
	govern_step(g, 1000.0 / hz)


## One governor step from a GPU reading against a frame budget, both in ms. Split out so a
## harness can drive it: the Mac returns no GPU timings, so there it never runs by itself.
func govern_step(g: float, frame_ms: float) -> void:
	gpu_ms = g if gpu_ms <= 0.0 else lerpf(gpu_ms, g, 0.3)
	if gpu_ms > 0.85 * frame_ms:
		budget = maxi(BUDGET_MIN, int(budget * 0.85))
	elif gpu_ms < 0.65 * frame_ms:
		budget = mini(int(step()["budget_max"]), int(budget * 1.06) + 1)


## Which avenue trees the far batch draws: every one whose height over distance is under the
## step's far_size, and past the step's `near` largest the rest. A tree drawn whole keeps it
## until it is 15% smaller than the line, so one standing on it does not flicker between the
## two. Waiting and withering trees are never far. Placement in tick() acts on the answer.
##
## Spread out: each frame re-measures TIER_SLICE trees (_tier_slice), and only the LOD pass
## ranks the few above the line against `near`. All at once (here) only when sowing.
func _assign_tiers() -> void:
	if not _tiers_on():
		return
	var eye := _avenue.to_local(_eye_world)
	var far_size: float = step()["far_size"]
	for t in _trees:
		_judge(t, eye, far_size)
	_rank_near()


func _tiers_on() -> bool:
	return _far_on() and layout != Layout.GROVE and _eye_world != Vector3.INF


func _tier_slice() -> void:
	var n := _trees.size()
	if n == 0 or not _tiers_on():
		return
	var eye := _avenue.to_local(_eye_world)
	var far_size: float = step()["far_size"]
	for k in mini(TIER_SLICE, n):
		_tier_cursor = (_tier_cursor + 1) % n
		_judge(_trees[_tier_cursor], eye, far_size)


func _judge(t: FractalTree, eye: Vector3, far_size: float) -> void:
	if t.row < 0:
		return
	if t.grow_rate <= 0.0:
		t.tier_far = false
		return
	var h := t.tier_h
	var p := t.position
	t.tier_size = h / maxf(Vector3(p.x, h * 0.5, p.z).distance_to(eye), 0.3)
	if t.tier_size * (1.0 if t.tier_far else 1.15) < far_size:
		t.tier_far = true


## The rank half: of the trees above the far line, the `near` largest are drawn whole.
func _rank_near() -> void:
	var near_max: int = step()["near"]
	var far_size: float = step()["far_size"]
	var cands: Array = []
	for t in _trees:
		if t.row < 0 or t.grow_rate <= 0.0:
			continue
		var size := t.tier_size * (1.0 if t.tier_far else 1.15)
		if size >= far_size:
			cands.append([size, t])
	if cands.size() > near_max:
		cands.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	for i in cands.size():
		(cands[i][1] as FractalTree).tier_far = i >= near_max


## Largest on screen first: each tree gets the detail its size asks for, then gives up
## outer levels until it fits what the budget has left. The far batch is a fixed cost
## reserved before anything else. tick() runs the two halves on two frames.
func apply_lod(cam: Vector3) -> void:
	if _tiers_on():
		_rank_near()
	_lod_items(cam)


func _lod_items(cam: Vector3) -> void:
	var items: Array = []
	for t in _trees:
		if not t.built or t.far or t.grow_t <= 0.0:
			continue
		var xf := t.global_transform
		var sc := xf.basis.get_scale().y
		var mid := xf.origin + xf.basis.y.normalized() * (t.height_m * sc * 0.5)
		var size := t.height_m * sc / maxf(cam.distance_to(mid), 0.3)
		var want := FractalTree.LOD_MAX
		for i in LOD_SIZE.size():
			if size > LOD_SIZE[i]:
				want = i
				break
		items.append([size, t, want])
	items.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	# Every tree's coarsest form is reserved first, so the biggest trees cannot spend the
	# budget the rest need just to stand there. Only what is left buys detail.
	var floor_cost := _far.drawn
	for it in items:
		floor_cost += (it[1] as FractalTree).lod_cost(FractalTree.LOD_MAX)
	var left := budget - floor_cost
	visible_cost = floor_cost
	drawn_branches = _far.branches
	drawn_leaves = _far.leaves if _leaves_on else 0
	for it in items:
		var t: FractalTree = it[1]
		var k: int = it[2]
		var base := t.lod_cost(FractalTree.LOD_MAX)
		while k < FractalTree.LOD_MAX and t.lod_cost(k) - base > left:
			k += 1
		t.set_lod(k)
		left -= t.lod_cost(k) - base
		visible_cost += t.lod_cost(k) - base
		drawn_branches += t.lod_branches(k)
		drawn_leaves += t.lod_leaves(k) if _leaves_on else 0


## One grove tree at a time withers back into the ground and a seedling of another
## species takes root somewhere else in the ring. Only once the grove is fully grown,
## and never a tree you planted.
func _tick_succession() -> void:
	if _clock < _succession_at:
		return
	var grove: Array[FractalTree] = []
	for t in _trees:
		if t.hand_planted:
			continue
		if t.grow_rate < 0.0 or t.grow_t < t.grow_s + 1.0:
			_succession_at = _clock + 5.0  # still growing or already withering: wait
			return
		grove.append(t)
	if grove.size() < 2:
		_succession_at = _clock + SUCCESSION_S
		return
	var old: FractalTree = grove[_rng.randi_range(0, grove.size() - 1)]
	old.grow_t = old.grow_s + 1.0
	old.grow_rate = WITHER_RATE
	var spot: Variant = _free_spot(_occupied())
	if spot != null:
		var species := _draw_species()
		if species == old.shape:
			species = _draw_species()
		var t := _grove_tree(species, spot)
		t.sprout_delay = (old.grow_s + 1.0) / -WITHER_RATE * 0.6
		t.grow_t = -t.sprout_delay
	_succession_at = _clock + SUCCESSION_S * _rng.randf_range(0.8, 1.2)
