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
## slides toward you along the path, at a held speed only, eased in and out over half a
## second, level and straight, so letting go stops it. A fixed pool of trees is built once.
## A tree sprouts as it comes within 25 m, withers once it is behind you, and by 5 m behind
## it is hidden, moved to the far end of its row and left waiting to sprout again. Moving a
## tree is a transform and two uniforms, never a rebuild, so the walk costs no build at all
## once the pool is up and the avenue never ends.

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
## At least this long between two builds. A build is one long GDScript call (an avenue tree:
## 4 ms mean, 6-11 ms worst, measured on an M1 Pro; the Quest is slower), and without the gap
## the walk's pool would build its sixteen far trees on sixteen frames in a row.
const BUILD_GAP_S := 0.1

## Instance budget (branches + leaves) for the whole forest, the hero excluded.
const BUDGET_START := 24000
const BUDGET_MIN := 6000           # about a full grove and planted set at the coarsest LOD
const BUDGET_MAX := 40000
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
const WALK_PER_ROW := 15          # a pool of 30 trees, built once for the walk, never rebuilt
## Held speed. Instinct said a stroll, about 1.2 m/s; the ambient-motion rule is a quarter of
## instinct, and 0.3 m/s still crosses one 3.5 m tree gap every twelve seconds.
const WALK_SPEED := 0.3
const WALK_EASE_S := 0.5          # seconds from still to full speed, and back
const WALK_SPROUT := 25.0         # metres ahead at which a waiting tree sprouts
const WALK_WITHER := 1.5          # metres behind you at which a grown tree starts to wither
const WALK_RECYCLE := 5.0         # metres behind you by which it goes to the far end
const WAITING_T := -0.5           # a built pool tree held hidden (grow_rate 0) until its turn

var plant_mix := true             # each plant draws the next species from a shuffled bag
var succession := true
var grove_seed := 0               # 0 = random each sowing
var budget := BUDGET_START
var visible_cost := 0
var gpu_ms := 0.0
var builds := 0                   # trees built so far (the harness reads it)
var build_us_max := 0             # the slowest single build, microseconds (the harness reads it)
var build_us_sum := 0
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
var _avenue_frame := Transform3D()
var _walk_s := 0.0
var _row_far := PackedFloat32Array([0.0, 0.0])   # the furthest trunk's z in each row
var _eye_z := 0.0                 # your z in the avenue's root frame, last tick
var _build_ready_at := 0.0
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
	_avenue.name = "Avenue"
	add_child(_avenue)


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
	_set_layout(Layout.GROVE)
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
	# The avenue regrows as a wave from where you stand now, which after a walk is not where
	# it was sown; trees you planted regrow as before.
	if layout != Layout.GROVE:
		_walk_wave(WALK_SPROUT if layout == Layout.WALK else INF, true)
	for t in _trees.duplicate():
		if t.get_parent() == _avenue:
			continue
		if t.grow_rate < 0.0:
			_remove(t)
			continue
		t.regrow()
		t.grow_t = -t.sprout_delay


func clear() -> void:
	for t in _trees.duplicate():
		_remove(t)
	_set_layout(Layout.GROVE)


func walking() -> bool:
	return layout == Layout.WALK


## 0 still, 1 at full walking speed: what a comfort vignette should follow.
func walk_motion() -> float:
	return walk_speed / WALK_SPEED


## The avenue: two rows from your feet down the way `eye` faces. Every tree goes, planted
## ones too, since they would stand still while a walk slid the rows past them. MIX picks
## the species as it does for planting: the bag, or `selected` for the whole avenue.
## `walk` builds the fixed pool instead, with only the first 25 m sprouting.
func sow_avenue(eye: Transform3D, walk: bool, selected: String) -> void:
	clear()
	_set_layout(Layout.WALK if walk else Layout.AVENUE)
	if grove_seed != 0:
		_rng.seed = grove_seed
		grove_seed += 1
	place_avenue(eye)
	var mean := (AVENUE_STEP.x + AVENUE_STEP.y) * 0.5
	for row in 2:
		var z := -AVENUE_FIRST - _rng.randf_range(0.0, mean * 0.5)
		var n := 0
		while (walk and n < WALK_PER_ROW) or (not walk and -z <= AVENUE_LEN):
			var far01 := clampf((-z - AVENUE_FIRST) / (AVENUE_LEN - AVENUE_FIRST), 0.0, 1.0)
			var cap := TREE_CAP_MAX if walk else int(lerpf(TREE_CAP_MAX, AVENUE_CAP_FAR, far01))
			var t := _new_tree(_draw_species() if plant_mix else selected, _avenue)
			t.wind_ref = _avenue
			t.branch_cap = cap
			var rel := clampf(float(FractalTree.SHAPES[t.shape]["height_m"]) / 4.8, 0.7, 1.35)
			t.target_height = AVENUE_H * rel * _rng.randf_range(0.9, 1.1)
			_place_in_row(t, row, z, 1.0)
			_row_far[row] = z
			z -= _rng.randf_range(AVENUE_STEP.x, AVENUE_STEP.y)
			n += 1
	_walk_wave(WALK_SPROUT if walk else INF, true)


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


## Stop walking and keep the avenue: the trees still waiting beyond 25 m sprout in a wave,
## and the trigger plants again.
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
	if layout == Layout.WALK:
		_tick_walk(delta, cam)
	var built_one := false
	for t in _trees.duplicate():
		# Build just before the sprout, one tree per frame, so sowing never lands as one
		# long frame. A planted tree is built at once (it is one tree, on a trigger pull).
		if not t.built and not built_one and t.grow_t > -0.75 and _clock >= _build_ready_at:
			_build(t)
			built_one = true
			_build_ready_at = _clock + BUILD_GAP_S
		if t.built:
			t.tick(delta)
		else:
			t.grow_t += delta * t.grow_rate   # a waiting pool tree (rate 0) holds its place
		# A withered pool tree is recycled by _tick_walk, never freed.
		if t.grow_rate < 0.0 and t.grow_t <= 0.0 and layout != Layout.WALK:
			_remove(t)
	_govern_t += delta
	if _govern_t >= GOVERN_S:
		_govern_t = 0.0
		_govern()
		apply_lod(cam)
	# Succession reseeds the grove's ring; the avenue has no ring to reseed.
	if succession and layout == Layout.GROVE:
		_tick_succession()


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
	for t in _trees:
		if t.get_parent() != _avenue:
			continue
		var ahead := _eye_z - t.position.z
		if ahead < -WALK_RECYCLE or (t.grow_rate < 0.0 and t.grow_t <= 0.0):
			_recycle(t)
		elif t.grow_rate == 0.0 and ahead < WALK_SPROUT:
			t.grow_rate = 1.0
		elif t.grow_rate > 0.0 and ahead < -WALK_WITHER:
			t.grow_t = minf(t.grow_t, t.grow_s + 1.0)
			t.grow_rate = WITHER_RATE


## A tree that has fallen behind goes to the far end of its own row, turned and resized a
## little so a pool of thirty does not read as the same thirty trees, and waits there,
## hidden, to sprout at WALK_SPROUT.
func _recycle(t: FractalTree) -> void:
	var row := 0 if t.position.x < 0.0 else 1
	var z := _row_far[row] - _rng.randf_range(AVENUE_STEP.x, AVENUE_STEP.y)
	_row_far[row] = z
	_place_in_row(t, row, z, _rng.randf_range(0.9, 1.1))
	t.grow_t = WAITING_T
	t.grow_rate = 0.0
	recycles += 1


## Trunk on the row line (left is row 0), a random turn about it, and a palette phase from how
## far down the avenue it stands, so colour rolls away from you as growth does.
func _place_in_row(t: FractalTree, row: int, z: float, s: float) -> void:
	var x := (-1.0 if row == 0 else 1.0) * (AVENUE_HALF_W
		+ _rng.randf_range(-AVENUE_HALF_W_JITTER, AVENUE_HALF_W_JITTER))
	t.transform = Transform3D(Basis(Vector3.UP, _rng.randf() * TAU).scaled(Vector3(s, s, s)),
		Vector3(x, 0.0, z))
	t.set_palette_phase(AVENUE_PHASE_SPAN * -z / AVENUE_LEN
		+ _rng.randf_range(-AVENUE_PHASE_JITTER, AVENUE_PHASE_JITTER))


## Growth as a wave rolling away from you: each avenue tree within `reach` sprouts after a
## delay that grows by STAGGER_STEP per average trunk step past the nearest one taking part,
## and the rest wait, built and hidden. `all` restarts every tree; otherwise only the ones
## already waiting join (WALK switched off, so the far end grows in).
func _walk_wave(reach: float, all: bool) -> void:
	var mean := (AVENUE_STEP.x + AVENUE_STEP.y) * 0.5
	var near := INF
	for t in _trees:
		if t.get_parent() == _avenue and (all or t.grow_rate == 0.0):
			near = minf(near, maxf(_eye_z - t.position.z, 0.0))
	for t in _trees:
		if t.get_parent() != _avenue or not (all or t.grow_rate == 0.0):
			continue
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
	parent.add_child(t)
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
	var t0 := Time.get_ticks_usec()
	t.build()
	var us := Time.get_ticks_usec() - t0
	build_us_max = maxi(build_us_max, us)
	build_us_sum += us
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
