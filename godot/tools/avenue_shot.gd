extends SceneTree

## Integration proof for TREE's avenue through the real main scene, shot from where you
## stand. The standing avenue: two rows clear of the path, spaced as specified, out to 50 m,
## growing as a wave away from you with the palette phase walking down the rows, and the hero
## out of the path. The walk: a fixed pool of 30, only the first 25 m sprouted, the root
## sliding toward a still viewer while G is held, trees recycled to the far end with no
## rebuild, nothing drawn past 25 m ahead or 5 m behind, the vignette up while moving and
## gone once stopped. Saves .spike-out/avenue_wave.png, avenue.png, walk_start.png,
## walk_moving.png (vignette on) and walk.png.
##
## Then COUNT: every step sown standing and grown, with the script time per frame, the shape
## computes, the instances and draws it costs; the top step is also walked. The top step must
## keep every frame's script under SCRIPT_CAP_MS, its drawn instances within the budget, its
## draws far under a draw per tree, and its rows clear of each other. Saves avenue_<n>.png per
## step and walk_<n>.png for the top one.
##
##   tools/avenue_shot.sh

const SPEED := 4.0    # forest clocks run on frame delta; this only shortens the waits
const WALK_GAME_S := 90.0
## The walk loop ends on distance walked, so a G key that stops reading as held (the window lost
## focus) would otherwise spin until the shell's 420 s watchdog. 90 game seconds at 8x is about
## 700 frames at 60 Hz; the cap leaves room for a fast window, the stall check fires in 2 s.
const WALK_MAX_FRAMES := 6000
const WALK_STALL_FRAMES := 120
## main's whole _process, any one frame, on this Mac: frames past it are counted. The Quest is
## guessed at 2-3x slower, so this is about a 72 Hz frame's script share there.
const SCRIPT_CAP_MS := 4.0
## The forest's own tick, any one frame: the part of the script that COUNT scales, and the cap
## the top step is held to. main's total carries the rest of the app and whatever else this
## Mac is running, so it is reported beside it, with the frames that passed SCRIPT_CAP_MS.
const FOREST_CAP_MS := 3.0
## main's frames past SCRIPT_CAP_MS at the top step, as a share of its frames.
const OVER_SHARE := 0.01
const TOP_WALK_M := 40.0


func _init() -> void:
	var scene: PackedScene = load("res://main.tscn")
	var main := scene.instantiate()
	root.add_child(main)
	for i in 40:
		await process_frame
	main.help.close()
	main.xr_camera.position = Vector3(0.0, 1.6, 0.0)
	main.xr_camera.rotation_degrees = Vector3(-3.0, 0.0, 0.0)
	for i in 3:
		await process_frame
	main.forest.grove_seed = 4321
	main.spin = true
	main._set_mode("tree")
	for i in 3:
		await process_frame
	var forest: Forest = main.forest
	var bad: Array[String] = []

	# --- The standing avenue -------------------------------------------------------------
	var sow_t0 := Time.get_ticks_usec()
	main._sow_avenue(false)
	var sow_avenue_ms := float(Time.get_ticks_usec() - sow_t0) / 1000.0
	await process_frame
	if forest.layout != Forest.Layout.AVENUE:
		bad.append("AVENUE did not set the layout")
	if main.tree.visible:
		bad.append("the hero still stands in the path")
	var rows := _rows(forest)
	bad.append_array(_check_rows(rows, Forest.AVENUE_LEN + 0.5))
	# The wave: sprout delay rises with distance (jitter 0.3 s), and the palette phase walks.
	var by_dist: Array = []
	for t in forest.trees():
		by_dist.append([-t.position.z, t.sprout_delay, t.palette_phase])
	by_dist.sort_custom(func(a, b): return a[0] < b[0])
	var wave_ok := true
	var phase_ok := true
	for i in by_dist.size():
		if i > 0 and by_dist[i][1] < by_dist[i - 1][1] - 0.31:
			wave_ok = false
		var want: float = Forest.AVENUE_PHASE_SPAN * by_dist[i][0] / Forest.AVENUE_LEN
		if absf(by_dist[i][2] - want) > Forest.AVENUE_PHASE_JITTER + 1e-3:
			phase_ok = false
	if not wave_ok:
		bad.append("sprouting does not roll away from the viewer")
	if not phase_ok:
		bad.append("palette phase does not follow distance")
	var first_delay: float = by_dist[0][1]
	var last_delay: float = by_dist[-1][1]

	# Mid-wave: near trees up, far ones still to come.
	Engine.time_scale = SPEED
	var sprout_frames := 0
	while _sprouted_frac(forest) < 0.5:
		sprout_frames += 1
		if sprout_frames > 8000:
			_abort("half the avenue never sprouted (%.2f after %d frames)" % [
				_sprouted_frac(forest), sprout_frames])
			return
		await process_frame
	var mid_grown := _grown_frac(forest)
	var mid_unsprouted := 0
	for t in forest.trees():
		if t.grow_t <= 0.0:
			mid_unsprouted += 1
	Engine.time_scale = 1.0
	await process_frame
	_save("avenue_wave")
	Engine.time_scale = SPEED
	var frames := 0
	while frames < 8000 and _grown_frac(forest) < 1.0:
		frames += 1
		await process_frame
	Engine.time_scale = 1.0
	for i in 30:
		await process_frame   # LOD settles at real speed
	forest.apply_lod(main.xr_camera.global_position)
	var cost_avenue := forest.visible_cost
	var branches_avenue := forest.branch_total()
	var leaves_avenue := forest.leaf_total()
	_save("avenue")
	if mid_unsprouted == 0:
		bad.append("mid-wave shot had every tree sprouted: no wave to see")
	print("AVENUESHOT standing trees=%d rows=%d/%d wave=%.1f->%.1fs mid_grown=%.2f mid_unsprouted=%d branches=%d leaves=%d visible=%d budget=%d build_ms mean=%.2f max=%.2f builds=%d" % [
		forest.tree_count(), rows[0].size(), rows[1].size(), first_delay, last_delay, mid_grown,
		mid_unsprouted, branches_avenue, leaves_avenue, cost_avenue, forest.budget,
		forest.build_us_sum / 1000.0 / maxf(1.0, forest.builds), forest.build_us_max / 1000.0,
		forest.builds])

	# ROOTS (T-51), switched on here and left on through the walk so recycling carries them.
	bad.append_array(await _roots_standing(main, forest))

	# Planting still works in the standing avenue.
	if not main._plant_tree_at(Vector2(0.0, -6.0)):
		bad.append("could not plant in the standing avenue")

	# Script time standing still, for comparison with walking.
	var still := _meter(main)
	for i in 120:
		await process_frame
		_sample(main, still)

	# --- The walk -------------------------------------------------------------------------
	sow_t0 = Time.get_ticks_usec()
	main._toggle_walk()
	var sow_walk_ms := float(Time.get_ticks_usec() - sow_t0) / 1000.0
	var pool := _meter(main)
	var builds_pre_walk := forest.builds
	await process_frame
	if not forest.walking():
		bad.append("WALK did not start the walk")
	if forest.tree_count() != Forest.WALK_PER_ROW * 2 or forest.walk_pool() != Forest.WALK_PER_ROW * 2:
		bad.append("pool is %d trees, expected %d" % [forest.tree_count(), Forest.WALK_PER_ROW * 2])
	if main.plant_marker.visible:
		bad.append("planting ring shows while walking")
	rows = _rows(forest)
	bad.append_array(_check_rows(rows, 1e9))
	for t in forest.trees():
		var ahead: float = -t.position.z
		if (ahead < Forest.WALK_SPROUT) != (t.grow_rate > 0.0):
			bad.append("tree %.1f m ahead: sprouting=%s" % [ahead, str(t.grow_rate > 0.0)])
			break
	Engine.time_scale = SPEED
	frames = 0
	while frames < 6000:
		frames += 1
		await process_frame
		_sample(main, pool)
		var near_grown := true
		for t in forest.trees():
			if t.grow_rate > 0.0 and (not t.built or t.grow_t < t.grow_s + 1.0):
				near_grown = false
		if near_grown:
			break
	Engine.time_scale = 1.0
	for i in 30:
		await process_frame
	# The shapes compute on worker threads; what the main thread pays is the upload, one a
	# frame. So the check is the frame, not the spacing of builds: the forest's own tick.
	if pool["fmax"] / 1000.0 > FOREST_CAP_MS:
		bad.append("a pool build frame took %.2f ms of forest tick (cap %.1f)" % [
			pool["fmax"] / 1000.0, FOREST_CAP_MS])
	if forest.builds - builds_pre_walk != Forest.WALK_PER_ROW * 2:
		bad.append("expected each pool tree built once at sow, got %d builds" % (forest.builds - builds_pre_walk))
	print("AVENUESHOT sow avenue=%.2fms walk=%.2fms (node creation, the press frame) pool build frames %s upload max=%.2fms" % [
		sow_avenue_ms, sow_walk_ms, _ms(pool), forest.adopt_us_max / 1000.0])
	_save("walk_start")
	var builds_before := forest.builds
	var root_before: Vector3 = forest.get_node("Avenue").global_position
	var eye_before: Vector3 = main.xr_camera.global_position

	# Hold G (the desktop's stand-in for a held trigger) and glide.
	_key(KEY_G, true)
	for i in 3:
		await process_frame
	if not forest.walk_held:
		bad.append("G held did not read as a held trigger")
	var walking := _meter(main)
	var t_game := 0.0
	var seen_far := 0.0      # furthest ahead any drawn tree stood
	var seen_behind := 0.0   # furthest behind any drawn tree stood
	var passed_young := 0
	Engine.time_scale = SPEED * 2.0
	var walk_frames := 0
	var stalled := 0
	var walked_last := forest.walked
	while t_game < WALK_GAME_S:
		await process_frame
		_hold_g(forest)
		walk_frames += 1
		stalled = stalled + 1 if forest.walked <= walked_last else 0
		walked_last = forest.walked
		if stalled >= WALK_STALL_FRAMES or walk_frames >= WALK_MAX_FRAMES:
			_abort("the walk stopped short: %.1f of %.0f m after %d frames, no progress for %d, walk_held=%s (G lost? check window focus)" % [
				forest.walked, WALK_GAME_S * Forest.WALK_SPEED, walk_frames, stalled,
				str(forest.walk_held)])
			return
		_sample(main, walking)
		t_game = forest.walked / Forest.WALK_SPEED
		var av: Node3D = forest.get_node("Avenue")
		var ez: float = av.to_local(main.xr_camera.global_position).z
		for t in forest.trees():
			if t.grow_t <= 0.0:
				continue
			var ahead: float = ez - t.position.z
			seen_far = maxf(seen_far, ahead)
			seen_behind = minf(seen_behind, ahead)
			if absf(ahead) < 0.5 and t.grow_rate > 0.0 and t.grow_t < t.grow_s + 1.0:
				passed_young += 1
	Engine.time_scale = 1.0
	for i in 40:
		await process_frame   # real speed, so the vignette shot is at full motion
		_sample(main, walking)
	var vig_on: bool = main.vignette.visible and main.vignette.motion > 0.99
	_save("walk_moving")
	var moved: float = forest.get_node("Avenue").global_position.distance_to(root_before)
	var walked_then := forest.walked
	var eye_moved: float = main.xr_camera.global_position.distance_to(eye_before)

	_key(KEY_G, false)
	var stop_frames := 0
	var stop_us := Time.get_ticks_usec()
	while forest.walk_speed > 0.0 and stop_frames < 2000:
		stop_frames += 1
		await process_frame
	var stop_s := float(Time.get_ticks_usec() - stop_us) / 1e6
	await process_frame
	var vig_off: bool = not main.vignette.visible
	for i in 10:
		await process_frame
	_save("walk")
	rows = _rows(forest)
	bad.append_array(_check_rows(rows, 1e9))
	# The roots went round with their trees: every recycled inner-row tree still edges the path.
	bad.append_array(_roots_tips(forest, "after the walk"))
	forest.set_roots(false)

	if forest.builds != builds_before:
		bad.append("walking rebuilt %d trees (the pool must only move)" % (forest.builds - builds_before))
	if forest.recycles < 8:
		bad.append("only %d recycles over %.0f m" % [forest.recycles, forest.walked])
	if forest.tree_count() != Forest.WALK_PER_ROW * 2:
		bad.append("pool changed size to %d" % forest.tree_count())
	if seen_far > Forest.WALK_SPROUT + 0.5:
		bad.append("a tree was drawn %.1f m ahead (sprouts at %.0f)" % [seen_far, Forest.WALK_SPROUT])
	if seen_behind < -Forest.WALK_RECYCLE - 0.5:
		bad.append("a tree was drawn %.1f m behind" % -seen_behind)
	if passed_young > 0:
		bad.append("%d frames had a still-growing tree beside the viewer" % passed_young)
	if eye_moved > 1e-4:
		bad.append("the viewer moved %.3f m (the avenue must come to you)" % eye_moved)
	if absf(moved - walked_then) > 0.01:
		bad.append("root moved %.2f m but walked says %.2f" % [moved, walked_then])
	if not vig_on:
		bad.append("vignette not at full while gliding (motion %.2f)" % main.vignette.motion)
	if not vig_off:
		bad.append("vignette still up after stopping")
	if stop_s > Forest.WALK_EASE_S + 0.25:
		bad.append("took %.2f s to stop" % stop_s)
	print("AVENUESHOT walk walked=%.1fm recycles=%d builds_during=%d seen_far=%.1f seen_behind=%.1f stop=%.2fs vignette_on=%s off=%s script_ms still %s; walking %s" % [
		forest.walked, forest.recycles, forest.builds - builds_before, seen_far, -seen_behind,
		stop_s, str(vig_on), str(vig_off), _ms(still), _ms(walking)])

	# WALK off keeps the avenue and lets the far end grow in; SOW brings the grove back.
	main._toggle_walk()
	await process_frame
	var waiting := 0
	for t in forest.trees():
		if t.grow_rate == 0.0:
			waiting += 1
	if forest.layout != Forest.Layout.AVENUE or waiting != 0:
		bad.append("WALK off: layout %d, %d trees still waiting" % [forest.layout, waiting])
	main._sow_grove()
	await process_frame
	if forest.layout != Forest.Layout.GROVE or not main.tree.visible:
		bad.append("SOW did not bring back the grove and the hero")

	# --- COUNT ----------------------------------------------------------------------------
	main.xr_camera.rotation_degrees = Vector3(-3.0, 0.0, 0.0)
	print("AVENUESHOT count  n  trees near far | sow_ms grow_ms avg/max still_ms avg/max | shapes compute_ms mean/max upload_ms place_ms put_ms | drawn branches leaves far_instances budget | draws prims")
	var top := Forest.STEPS.size() - 1
	for i in Forest.STEPS.size():
		bad.append_array(await _count_step(main, forest, i, i == top))
		if i == top:
			bad.append_array(await _count_walk(main, forest))
	forest.set_count(0)
	main._sow_grove()
	await process_frame

	var ok := bad.is_empty()
	for b in bad:
		print("AVENUESHOT problem: ", b)
	print("AVENUESHOT %s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)


## ROOTS on the grown default avenue: the same views from eye height without and with, what they
## cost, and where the tips land. Leaves ROOTS on.
func _roots_standing(main, forest: Forest) -> Array[String]:
	var bad: Array[String] = []
	var views := {"": Vector3(-3.0, 0.0, 0.0), "_down": Vector3(-20.0, 0.0, 0.0)}
	var off := {}
	for v in views:
		main.xr_camera.rotation_degrees = views[v]
		var dp := await _tree_draws(main, forest)
		off[v] = dp.y
		_save("avenue_noroots%s" % v)
	var m0 := _meter(main)
	for i in 60:
		await process_frame
		_sample(main, m0)
	var t0 := Time.get_ticks_usec()
	forest.set_roots(true)
	var on_ms := float(Time.get_ticks_usec() - t0) / 1000.0
	var on := {}
	for v in views:
		main.xr_camera.rotation_degrees = views[v]
		var dp := await _tree_draws(main, forest)
		on[v] = dp.y
		_save("avenue_roots%s" % v)
	var m1 := _meter(main)
	for i in 60:
		await process_frame
		_sample(main, m1)
	main.xr_camera.rotation_degrees = views[""]
	var rooted := 0
	var inner := 0
	var segs := 0
	for t in forest.trees():
		if t.row == 0 or t.row == 1:
			inner += 1
		if t.roots_node() != null:
			rooted += 1
			segs += t.roots_node().multimesh.instance_count
	print("AVENUESHOT roots rooted=%d of %d inner-row trees, %d root segments (%.0f a tree), switch %.2fms; tris in view %d -> %d (eye level), %d -> %d (looking down); draws +%d; script_ms off %s; on %s" % [
		rooted, inner, segs, float(segs) / maxi(1, rooted), on_ms, off[""], on[""], off["_down"],
		on["_down"], rooted, _ms(m0), _ms(m1)])
	if rooted != inner or rooted == 0:
		bad.append("ROOTS: %d of %d inner-row trees have roots" % [rooted, inner])
	if on["_down"] <= off["_down"]:
		bad.append("ROOTS: drew nothing more looking down (%d -> %d triangles)" % [off["_down"], on["_down"]])
	bad.append_array(_roots_tips(forest, "standing"))
	return bad


## Where the root tips land, in the avenue's frame: none inside ROOT_CLEAR of the centre line (the
## walk stays open), every rooted tree reaching within 0.35 m of that edge (they do reach for the
## middle), and the whole system on the floor (no root higher than 0.4 m).
func _roots_tips(forest: Forest, when: String) -> Array[String]:
	var bad: Array[String] = []
	var av: Node3D = forest.get_node("Avenue")
	var closest := INF
	var furthest_short := 0.0
	var top := 0.0
	var n := 0
	for t in forest.trees():
		var r: MultiMeshInstance3D = t.roots_node()
		if r == null or not t.is_inside_tree():
			continue
		n += 1
		var xf: Transform3D = av.global_transform.affine_inverse() * r.global_transform
		var near_x := INF
		var shape := TreeRoots.shape(t.seed_value)
		for tip in shape["tips"]:
			near_x = minf(near_x, absf((xf * tip).x))
		closest = minf(closest, near_x)
		furthest_short = maxf(furthest_short, near_x - Forest.ROOT_CLEAR)
		top = maxf(top, (xf * Vector3(0.0, float(shape["top"]), 0.0)).y)
	print("AVENUESHOT roots %s: %d rooted, nearest tip %.2f m from the centre line (clear %.2f), the shortest tree stops %.2f m short of the edge, highest %.2f m" % [
		when, n, closest, Forest.ROOT_CLEAR, furthest_short, top])
	if n == 0:
		bad.append("ROOTS %s: no rooted trees" % when)
	elif closest < Forest.ROOT_CLEAR - 0.01:
		bad.append("ROOTS %s: a tip %.2f m from the centre line blocks the path" % [when, closest])
	elif furthest_short > 0.35:
		bad.append("ROOTS %s: a tree's roots stop %.2f m short of the path" % [when, furthest_short])
	elif top > 0.4:
		bad.append("ROOTS %s: roots reach %.2f m up" % [when, top])
	return bad


## One COUNT step, standing: sow, grow at speed, settle, measure, shoot.
func _count_step(main, forest: Forest, i: int, top: bool) -> Array[String]:
	var bad: Array[String] = []
	var st: Dictionary = Forest.STEPS[i]
	forest.set_count(i)
	var b0 := forest.builds
	forest.build_us_max = 0
	var bsum0 := forest.build_us_sum
	forest.adopt_us_max = 0
	forest.place_us_max = 0
	forest.tick_us_max = 0
	forest.lod_us_max = 0
	forest.flush_us_max = 0
	forest.far_batch().put_us_max = 0
	var t0 := Time.get_ticks_usec()
	main._sow_avenue(false)
	var sow_ms := float(Time.get_ticks_usec() - t0) / 1000.0
	var grow := _meter(main)
	# The outer rows come a frame each after the press.
	await process_frame
	_sample(main, grow)
	while forest.sowing():
		await process_frame
		_sample(main, grow)
	var rows := _rows(forest)
	bad.append_array(_check_rows(rows, forest.avenue_len() + 0.5))
	var gap := _nearest_trunks(forest)
	Engine.time_scale = SPEED
	var frames := 0
	while _grown_frac(forest) < 1.0 and frames < 12000:
		frames += 1
		await process_frame
		_sample(main, grow)
	Engine.time_scale = 1.0
	var still := _meter(main)
	for k in 60:
		await process_frame
		_sample(main, still)
	forest.apply_lod(main.xr_camera.global_position)
	var dp := await _tree_draws(main, forest)
	# Draws counted from the scene, every one as if in view: the frame-to-frame difference moves
	# with the wrist menu's own redraws (it measured 19 and 58 for the same 29 trees).
	var draws: int = 2 * forest.whole_drawn() + 2 * forest.far_batch().batch_count()
	var prims: int = dp.y
	_save("avenue_%d" % int(st["n"]))
	var far := forest.far_batch()
	var computes := forest.builds - b0
	var near := forest.tree_count() - far.tree_total()
	print("AVENUESHOT count %3d %4d %4d %4d | %6.2f %5.2f/%5.2f %5.2f/%5.2f | %3d %5.2f/%5.2f %5.2f %5.2f %5.2f | %6d %6d %6d %6d %6d | %4d %8d  frames=%d grown=%.2f gap=%.2fm batches=%d forest_tick max growing %.2f standing %.2f lod_max=%.2fms flush_max=%.2fms over_cap %d/%d" % [
		int(st["n"]), forest.tree_count(), near, far.tree_total(), sow_ms,
		grow["sum"] / 1000.0 / maxf(1.0, grow["n"]), grow["max"] / 1000.0,
		still["sum"] / 1000.0 / maxf(1.0, still["n"]), still["max"] / 1000.0,
		computes, (forest.build_us_sum - bsum0) / 1000.0 / maxf(1.0, computes), forest.build_us_max / 1000.0,
		forest.adopt_us_max / 1000.0, forest.place_us_max / 1000.0, far.put_us_max / 1000.0,
		forest.visible_cost, forest.drawn_branches, forest.drawn_leaves, far.drawn, forest.budget,
		draws, prims, frames, _grown_frac(forest), gap, far.batch_count(),
		grow["fmax"] / 1000.0, still["fmax"] / 1000.0, forest.lod_us_max / 1000.0,
		forest.flush_us_max / 1000.0, grow["over"] + still["over"], grow["n"] + still["n"]])
	if _grown_frac(forest) < 1.0:
		bad.append("COUNT %d: only %.2f of the avenue grew in %d frames" % [int(st["n"]), _grown_frac(forest), frames])
	if forest.visible_cost > forest.budget:
		bad.append("COUNT %d: drew %d instances over a budget of %d" % [int(st["n"]), forest.visible_cost, forest.budget])
	if gap < Forest.AVENUE_STEP.x * 0.5:
		bad.append("COUNT %d: two trunks %.2f m apart" % [int(st["n"]), gap])
	if absf(forest.tree_count() - int(st["n"])) > int(st["n"]) * 0.15:
		bad.append("COUNT %d: sowed %d trees" % [int(st["n"]), forest.tree_count()])
	# The trees nearest you are the ones the eye judges: they must be drawn whole, the nearest in
	# its finer LODs.
	var eye: Vector3 = forest.get_node("Avenue").to_local(main.xr_camera.global_position)
	var by_d: Array = []
	for t in forest.trees():
		by_d.append([Vector2(t.position.x - eye.x, t.position.z - eye.z).length(), t])
	by_d.sort_custom(func(a, b): return a[0] < b[0])
	var nearest := []
	var near_whole := true
	for k in mini(8, by_d.size()):
		var t: FractalTree = by_d[k][1]
		nearest.append("%.1fm:%s" % [by_d[k][0], "far" if t.far else "lod%d" % t.lod])
		near_whole = near_whole and not t.far
	print("AVENUESHOT count %d nearest %s; drawing whole %d, far batch %d trees in %d batches" % [
		int(st["n"]), " ".join(PackedStringArray(nearest)), forest.whole_drawn(), far.tree_total(),
		far.batch_count()])
	if not near_whole or (by_d[0][1] as FractalTree).lod > 1:
		bad.append("COUNT %d: the nearest trees are not drawn whole: %s" % [int(st["n"]), str(nearest)])
	# Every step is one Sam can pick, so every step is held to the frame caps.
	bad.append_array(_caps("COUNT %d standing" % int(st["n"]), [grow, still]))
	if int(st["near"]) > 0:
		# Two draws per tree drawn whole and two per species batch, at most.
		var draw_cap := 2 * int(st["near"]) + 2 * FractalTree.SHAPE_NAMES.size()
		if draws > draw_cap or forest.whole_drawn() > int(st["near"]) or far.tree_total() < forest.tree_count() / 2:
			bad.append("COUNT %d: %d tree draws (cap %d), %d drawn whole, %d trees far" % [int(st["n"]),
				draws, draw_cap, forest.whole_drawn(), far.tree_total()])
	if top:
		if computes > FractalTree.SHAPE_NAMES.size() * int(st["variants"]):
			bad.append("COUNT %d: %d shape computes for a library of %d" % [int(st["n"]), computes,
				FractalTree.SHAPE_NAMES.size() * int(st["variants"])])
	return bad


## The top step walked: the pool, recycling into the far batch and back, under the same caps.
func _count_walk(main, forest: Forest) -> Array[String]:
	var bad: Array[String] = []
	var st := forest.step()
	forest.place_us_max = 0
	forest.tick_us_max = 0
	forest.lod_us_max = 0
	forest.flush_us_max = 0
	var t0 := Time.get_ticks_usec()
	main._toggle_walk()
	var sow_ms := float(Time.get_ticks_usec() - t0) / 1000.0
	await process_frame
	while forest.sowing():
		await process_frame
	print("AVENUESHOT count %d walk sow=%.2fms on the press" % [int(st["n"]), sow_ms])
	if forest.tree_count() != forest.walk_pool():
		bad.append("COUNT %d walk: pool %d, expected %d" % [int(st["n"]), forest.tree_count(), forest.walk_pool()])
	var grow := _meter(main)
	Engine.time_scale = SPEED
	for k in 600:
		await process_frame
		_sample(main, grow)
	Engine.time_scale = 1.0
	var b0 := forest.builds
	var r0 := forest.recycles
	_key(KEY_G, true)
	for k in 3:
		await process_frame
	var walking := _meter(main)
	var seen_far := 0.0
	var frames := 0
	var stalled := 0
	var walked_last := forest.walked
	var w0 := forest.walked
	Engine.time_scale = SPEED * 2.0
	while forest.walked - w0 < TOP_WALK_M:
		await process_frame
		_hold_g(forest)
		frames += 1
		stalled = stalled + 1 if forest.walked <= walked_last else 0
		walked_last = forest.walked
		if stalled >= WALK_STALL_FRAMES or frames >= WALK_MAX_FRAMES:
			bad.append("COUNT %d walk stopped short at %.1f m (G lost?)" % [int(st["n"]), forest.walked - w0])
			break
		_sample(main, walking)
		var ez: float = forest.get_node("Avenue").to_local(main.xr_camera.global_position).z
		for t in forest.trees():
			if t.grow_t > 0.0:
				seen_far = maxf(seen_far, ez - t.position.z)
	Engine.time_scale = 1.0
	for k in 40:
		await process_frame
		_sample(main, walking)
	_save("walk_moving_%d" % int(st["n"]))
	_key(KEY_G, false)
	for k in 90:
		await process_frame
	forest.apply_lod(main.xr_camera.global_position)
	var dp := await _tree_draws(main, forest)
	_save("walk_%d" % int(st["n"]))
	var far := forest.far_batch()
	print("AVENUESHOT count %d walk pool=%d sprout=%.0fm walked=%.1fm recycles=%d computes_during=%d seen_far=%.1f script_ms sprouting %s; walking %s; place_max=%.2fms lod_max=%.2fms flush_max=%.2fms drawn=%d budget=%d far=%d prims=%d" % [
		int(st["n"]), forest.walk_pool(), forest.walk_sprout(), forest.walked - w0, forest.recycles - r0,
		forest.builds - b0, seen_far, _ms(grow), _ms(walking),
		forest.place_us_max / 1000.0, forest.lod_us_max / 1000.0, forest.flush_us_max / 1000.0,
		forest.visible_cost, forest.budget, far.tree_total(), dp.y])
	bad.append_array(_caps("COUNT %d walk" % int(st["n"]), [grow, walking]))
	# Trees withering behind you are drawn whole until they go, outside the `near` count: the
	# cap holds for the rest, and the draws for the lot.
	var draw_cap := 2 * int(st["near"]) + 2 * FractalTree.SHAPE_NAMES.size()
	var whole := 0
	var withering := 0
	for t in forest.trees():
		if t.draws_own():
			if t.grow_rate < 0.0:
				withering += 1
			else:
				whole += 1
	print("AVENUESHOT count %d walk drawing whole %d, withering behind %d" % [int(st["n"]), whole, withering])
	var draws := 2 * (whole + withering) + 2 * far.batch_count()
	if draws > draw_cap + 2 * withering or whole > int(st["near"]):
		bad.append("COUNT %d walk: %d tree draws (cap %d + 2 per withering tree), %d drawn whole, %d withering" % [
			int(st["n"]), draws, draw_cap, whole, withering])
	if forest.builds != b0:
		bad.append("COUNT %d walk: %d shapes computed while walking (the library must cover it)" % [
			int(st["n"]), forest.builds - b0])
	if forest.recycles - r0 < 10:
		bad.append("COUNT %d walk: only %d recycles" % [int(st["n"]), forest.recycles - r0])
	if seen_far > forest.walk_sprout() + 0.5:
		bad.append("COUNT %d walk: a tree drawn %.1f m ahead" % [int(st["n"]), seen_far])
	if forest.visible_cost > forest.budget:
		bad.append("COUNT %d walk: drew %d over a budget of %d" % [int(st["n"]), forest.visible_cost, forest.budget])
	main._toggle_walk()
	await process_frame
	return bad


## The forest's own draws and primitives in a frame: the frame's totals less the same view with
## the forest hidden (the HUD, the menu, the controllers and the rest). Only the primitives are
## used: the draw count moves with the wrist menu's redraws.
func _tree_draws(main, forest: Forest) -> Vector2i:
	forest.visible = false
	for k in 3:
		await process_frame
	var d0 := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
	var p0 := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
	forest.visible = true
	for k in 3:
		await process_frame
	var d1 := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
	var p1 := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
	return Vector2i(d1 - d0, p1 - p0)


## The closest two avenue trunks, in the root's floor plane.
func _nearest_trunks(forest: Forest) -> float:
	var ps: Array[Vector2] = []
	for t in forest.trees():
		if t.row >= 0:
			ps.append(Vector2(t.position.x, t.position.z))
	var best := INF
	for a in ps.size():
		for b in range(a + 1, ps.size()):
			best = minf(best, ps[a].distance_to(ps[b]))
	return best


## Avenue trees by row (row 0 left, 1 right, then each pair further out), each sorted nearest
## first, in the root's frame.
func _rows(forest: Forest) -> Array:
	var out := []
	for t in forest.trees():
		if t.row < 0:
			continue
		while out.size() <= t.row:
			out.append([])
		out[t.row].append(t.position)
	for r in out:
		r.sort_custom(func(a, b): return a.z > b.z)
	return out


func _check_rows(rows: Array, max_len: float) -> Array[String]:
	var bad: Array[String] = []
	if rows.size() < 2:
		bad.append("only %d rows" % rows.size())
	for r in rows.size():
		var row: Array = rows[r]
		var ring := r / 2
		var line := Forest.AVENUE_HALF_W + Forest.ROW_GAP * ring
		var jitter := Forest.AVENUE_HALF_W_JITTER if ring == 0 else Forest.ROW_GAP_JITTER
		if row.size() < 10:
			bad.append("row %d has only %d trees" % [r, row.size()])
		for i in row.size():
			var p: Vector3 = row[i]
			if (p.x < 0.0) != (r % 2 == 0) or absf(p.x) < line - jitter - 1e-3 \
					or absf(p.x) > line + jitter + 1e-3:
				bad.append("row %d tree %d at %.2f m off the path" % [r, i, p.x])
			if i > 0:
				var gap: float = (row[i - 1] as Vector3).z - p.z
				if gap < Forest.AVENUE_STEP.x - 1e-3 or gap > Forest.AVENUE_STEP.y + 1e-3:
					bad.append("row %d gap %d is %.2f m" % [r, i, gap])
		if not row.is_empty() and -float((row[-1] as Vector3).z) > max_len:
			bad.append("row %d runs to %.1f m" % [r, -float((row[-1] as Vector3).z)])
	return bad


func _sprouted_frac(forest: Forest) -> float:
	var n := 0
	for t in forest.trees():
		if t.grow_t > 0.0:
			n += 1
	return float(n) / maxf(1.0, forest.tree_count())


## main's own script timer (_proc_us_*), which its [perf] line resets every log window.
## Sampled every frame, between two samples exactly one main._process has run, so a reset
## is seen as the frame count going backwards and nothing is lost. "max" is that one frame's
## time exactly (main's own _proc_us_max is the whole log window's, frames before the meter
## started included), "fmax" the forest's tick in the same frame, and "over" the frames whose
## whole script passed SCRIPT_CAP_MS.
func _meter(main) -> Dictionary:
	return {"sum": 0, "n": 0, "max": 0, "fmax": 0, "over": 0, "ls": main._proc_us_sum,
		"lf": main._proc_frames}


func _sample(main, m: Dictionary) -> void:
	var s: int = main._proc_us_sum
	var f: int = main._proc_frames
	var reset: bool = f < int(m["lf"])
	var ds: int = s if reset else s - int(m["ls"])
	var df: int = f if reset else f - int(m["lf"])
	m["sum"] += ds
	m["n"] += df
	if df == 1:
		m["max"] = maxi(int(m["max"]), ds)
		m["fmax"] = maxi(int(m["fmax"]), main.forest.last_tick_us)
		if ds > SCRIPT_CAP_MS * 1000.0:
			m["over"] += 1
	m["ls"] = s
	m["lf"] = f


## The top step's frame caps: no forest tick over FOREST_CAP_MS, and main's whole script past
## SCRIPT_CAP_MS on no more than OVER_SHARE of the frames.
func _caps(what: String, meters: Array) -> Array[String]:
	var bad: Array[String] = []
	var fmax := 0
	var over := 0
	var n := 0
	for m in meters:
		fmax = maxi(fmax, int(m["fmax"]))
		over += int(m["over"])
		n += int(m["n"])
	if fmax / 1000.0 > FOREST_CAP_MS:
		bad.append("%s: a forest tick took %.2f ms (cap %.1f)" % [what, fmax / 1000.0, FOREST_CAP_MS])
	if over > maxi(1, int(n * OVER_SHARE)):
		bad.append("%s: %d of %d frames took over %.1f ms of script" % [what, over, n, SCRIPT_CAP_MS])
	return bad


func _ms(m: Dictionary) -> String:
	return "avg %.2f max %.2f forest %.2f over %d/%d" % [m["sum"] / 1000.0 / maxf(1.0, m["n"]),
		m["max"] / 1000.0, m["fmax"] / 1000.0, m["over"], m["n"]]


func _grown_frac(forest: Forest) -> float:
	var n := 0
	for t in forest.trees():
		if t.built and t.grow_t > t.grow_s + 1.0:
			n += 1
	return float(n) / maxf(1.0, forest.tree_count())


## Godot releases every held key when the window loses focus, and on a shared desktop something
## else takes it now and then (two walks aborted at 31 and 66 m that way). Pressing G again
## whenever the walk stops reading it as held keeps the run about the forest; the stall check
## still catches a walk that will not move with G down.
func _hold_g(forest: Forest) -> void:
	if not forest.walk_held:
		_key(KEY_G, true)


func _key(code: Key, down: bool) -> void:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.physical_keycode = code
	ev.pressed = down
	Input.parse_input_event(ev)


func _save(name: String) -> void:
	var img := root.get_viewport().get_texture().get_image()
	img.save_png("res://.spike-out/%s.png" % name)


## Stop now with the reason, rather than wait for the shell's watchdog to kill a run that can
## no longer pass. Everything after a broken wait would only measure the breakage.
func _abort(why: String) -> void:
	Engine.time_scale = 1.0
	_key(KEY_G, false)
	print("AVENUESHOT problem: ", why)
	print("AVENUESHOT FAIL (aborted)")
	quit(1)
