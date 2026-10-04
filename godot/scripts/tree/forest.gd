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
## built under a per-tree branch cap that thins the outermost level evenly, and each
## build waits until its tree is about to sprout, one build per frame. A distance LOD
## drops outer twig levels and a share of the leaves (the buffers are ordered so a
## prefix is always a whole smaller tree), nearest-largest first, against an instance
## budget. The budget follows the measured GPU time: over 85% of the frame it shrinks,
## under 65% it grows back. On the headset that means thermal throttling thins the far
## trees instead of dropping frames.

const GROVE_COUNT := 16
const GROVE_R_MIN := 0.75         # metres from the hero's trunk
const GROVE_R_MAX := 1.6          # hero is 2.2 m ahead: the rim stays 0.6 m clear of you
const GROVE_SPACING := 0.32       # trunk to trunk
const GROVE_H_INNER := 2.2        # metres, for a species of the oak's 4.8 m hero height
const GROVE_H_OUTER := 0.7
const TREE_CAP_MIN := 450         # branches, rim tree
const TREE_CAP_MAX := 1400        # branches, inner tree and every planted tree
const PLANT_MAX := 12             # hand-planted trees, as before
const PLANT_H := Vector2(0.5, 0.85)   # planted height as a share of the species hero height
const STAGGER_FIRST := 1.5        # seconds after the hero starts before the first sprout
const STAGGER_STEP := 0.85        # then one more tree about this often, inside out

## Instance budget (branches + leaves) for the whole forest, the hero excluded.
const BUDGET_START := 24000
const BUDGET_MIN := 6000           # about a full grove and planted set at the coarsest LOD
const BUDGET_MAX := 40000
const GOVERN_S := 0.5
const LOD_SIZE := [0.45, 0.22, 0.11]  # height / distance above which LOD 0, 1, 2 apply

const SUCCESSION_S := 45.0        # roughly how often one grove tree withers and is replaced
const WITHER_RATE := -1.6         # growth clock speed while withering

var plant_mix := true             # each plant draws the next species from a shuffled bag
var succession := true
var grove_seed := 0               # 0 = random each sowing
var budget := BUDGET_START
var visible_cost := 0
var gpu_ms := 0.0
var builds := 0                   # trees built so far (the harness reads it)

var _trees: Array[FractalTree] = []
var _wind := 0.3
var _leaves_on := true
var _palette: Array = []
var _rng := RandomNumberGenerator.new()
var _bag: Array[String] = []
var _next_plant := ""
var _clock := 0.0
var _govern_t := 0.0
var _succession_at := 0.0


func _init() -> void:
	name = "Forest"
	_rng.randomize()


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


func set_wind(w: float) -> void:
	_wind = w
	for t in _trees:
		t.set_wind(w)


func set_leaves(on: bool) -> void:
	_leaves_on = on
	for t in _trees:
		t.set_leaves(on)


func set_palette(pal: Array) -> void:
	_palette = pal
	for t in _trees:
		t.set_palette(pal)


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
	if grove_seed != 0:
		_rng.seed = grove_seed
		grove_seed += 1
	var spots: Array[Vector2] = []
	var taken: Array[Vector2] = _occupied()
	for i in GROVE_COUNT:
		var p: Variant = _free_spot(taken)
		if p == null:
			break
		spots.append(p)
		taken.append(p)
	# Inside out: the grove spreads from the hero's feet like seed falling from it.
	spots.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.length() < b.length())
	for i in spots.size():
		var t := _grove_tree(_draw_species(), spots[i])
		t.sprout_delay = STAGGER_FIRST + STAGGER_STEP * float(i) + _rng.randf() * 0.5
		t.grow_t = -t.sprout_delay
	_succession_at = _clock + SUCCESSION_S * _rng.randf_range(0.8, 1.2) + float(spots.size()) * STAGGER_STEP


## Regrow every tree from seed, staggered as when it was sown; an empty forest is sown.
func regrow() -> void:
	if _trees.is_empty():
		sow_grove()
		return
	for t in _trees.duplicate():
		if t.grow_rate < 0.0:
			_remove(t)
			continue
		t.regrow()
		t.grow_t = -t.sprout_delay


func clear() -> void:
	for t in _trees.duplicate():
		_remove(t)


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
	_build(t)
	return t


## Per frame in tree mode. `cam` is the eye in world space, for the LOD.
func tick(delta: float, cam: Vector3) -> void:
	_clock += delta
	var built_one := false
	for t in _trees.duplicate():
		# Build just before the sprout, one tree per frame, so sowing never lands as one
		# long frame. A planted tree is built at once (it is one tree, on a trigger pull).
		if not t.built and not built_one and t.grow_t > -0.75:
			_build(t)
			built_one = true
		if t.built:
			t.tick(delta)
		else:
			t.grow_t += delta
		if t.grow_rate < 0.0 and t.grow_t <= 0.0:
			_remove(t)
	_govern_t += delta
	if _govern_t >= GOVERN_S:
		_govern_t = 0.0
		_govern()
		apply_lod(cam)
	if succession:
		_tick_succession()


func _new_tree(species: String) -> FractalTree:
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
	add_child(t)
	_trees.append(t)
	return t


func _grove_tree(species: String, spot: Vector2) -> FractalTree:
	var t := _new_tree(species)
	var size01 := 1.0 - clampf((spot.length() - GROVE_R_MIN) / (GROVE_R_MAX - GROVE_R_MIN), 0.0, 1.0)
	var rel := clampf(float(FractalTree.SHAPES[species]["height_m"]) / 4.8, 0.7, 1.35)
	t.target_height = lerpf(GROVE_H_OUTER, GROVE_H_INNER, size01) * rel * _rng.randf_range(0.85, 1.15)
	t.branch_cap = int(lerpf(TREE_CAP_MIN, TREE_CAP_MAX, size01))
	t.transform = Transform3D(Basis(Vector3.UP, _rng.randf() * TAU), Vector3(spot.x, 0.0, spot.y))
	return t


## build() restarts the clock; a tree waiting its turn keeps its place in the queue.
func _build(t: FractalTree) -> void:
	var keep := t.grow_t
	t.build()
	t.grow_t = minf(keep, 0.0)
	builds += 1


func _remove(t: FractalTree) -> void:
	_trees.erase(t)
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
	for attempt in 40:
		var r := sqrt(_rng.randf_range(GROVE_R_MIN * GROVE_R_MIN, GROVE_R_MAX * GROVE_R_MAX))
		var p := Vector2.from_angle(_rng.randf() * TAU) * r
		var ok := true
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
		budget = mini(BUDGET_MAX, int(budget * 1.06) + 1)


## Largest on screen first: each tree gets the detail its size asks for, then gives up
## outer levels until it fits what the budget has left.
func apply_lod(cam: Vector3) -> void:
	var items: Array = []
	for t in _trees:
		if not t.built or t.grow_t <= 0.0:
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
	var floor_cost := 0
	for it in items:
		floor_cost += (it[1] as FractalTree).lod_cost(FractalTree.LOD_MAX)
	var left := budget - floor_cost
	visible_cost = floor_cost
	for it in items:
		var t: FractalTree = it[1]
		var k: int = it[2]
		var base := t.lod_cost(FractalTree.LOD_MAX)
		while k < FractalTree.LOD_MAX and t.lod_cost(k) - base > left:
			k += 1
		t.set_lod(k)
		left -= t.lod_cost(k) - base
		visible_cost += t.lod_cost(k) - base


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
