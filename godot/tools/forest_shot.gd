extends SceneTree

## Integration proof for TREE's forest through the real main scene: the grove is sown on
## entry with mixed species inside its ring, every tree respects its branch cap, planting
## grows exactly the species the ring names, planted trees do not orbit under the ambient
## spin, the LOD governor reports, and the planting ring follows the ray. Saves the grown
## grove to .spike-out/forest.png.
##
##   tools/forest_shot.sh

const SPEED := 4.0   # the forest's clocks run on frame delta; this only shortens the wait
const SCRIPT_CAP_MS := 4.0   # main's whole _process: frames past it are counted (1% allowed)
const FOREST_CAP_MS := 3.0   # the forest's own tick, any one frame, on this Mac


func _init() -> void:
	var scene: PackedScene = load("res://main.tscn")
	var main := scene.instantiate()
	root.add_child(main)
	for i in 40:
		await process_frame
	main.help.close()
	main.xr_camera.position = Vector3(0.0, 1.6, 0.0)
	main.xr_camera.rotation_degrees = Vector3(-14.0, 0.0, 0.0)
	for i in 3:
		await process_frame
	main.forest.grove_seed = 1234
	main.spin = true
	main._set_mode("tree")
	for i in 3:
		await process_frame
	var forest: Forest = main.forest

	# The grove: sown on entry, mixed, inside its ring, clear of the viewer.
	var sown := forest.tree_count()
	var species := {}
	var in_ring := true
	var clear_of_eye := true
	var eye := Vector2(main.xr_camera.global_position.x, main.xr_camera.global_position.z)
	for t in forest.trees():
		species[t.shape] = true
		var p := forest.to_local(t.global_position)
		var r := Vector2(p.x, p.z).length()
		in_ring = in_ring and r >= Forest.GROVE_R_MIN - 1e-3 and r <= Forest.GROVE_R_MAX + 1e-3
		var w := Vector2(t.global_position.x, t.global_position.z)
		clear_of_eye = clear_of_eye and w.distance_to(eye) >= 0.55

	# Planting: two pulls, each must grow the species the ring promised.
	var promised_a: String = forest.peek_plant(FractalTree.SHAPE_NAMES[main.tree_shape_idx])
	var planted_a: bool = main._plant_tree_at(Vector2(-1.9, -1.2))
	var got_a: String = forest.trees().back().shape
	var promised_b: String = forest.peek_plant(FractalTree.SHAPE_NAMES[main.tree_shape_idx])
	var planted_b: bool = main._plant_tree_at(Vector2(1.9, -1.6))
	var got_b: String = forest.trees().back().shape
	var promise_kept := promised_a == got_a and promised_b == got_b
	var planted_pos: Vector3 = forest.trees().back().global_position
	var hero_yaw0: float = main.tree.rotation.y

	main.passthrough = true
	main.ground_inside_room = true
	main._apply_ground_look()

	# Let everything grow on its own clock (sped up), with the ambient spin running.
	Engine.time_scale = SPEED
	var frames := 0
	while frames < 6000:
		frames += 1
		await process_frame
		var all_grown: bool = main.tree.grow_t > main.tree.grow_s + 1.0
		for t in forest.trees():
			all_grown = all_grown and t.built and t.grow_t > t.grow_s + 1.0
		if all_grown and frames > 60:
			break
	Engine.time_scale = 1.0
	for i in 30:
		await process_frame   # two LOD passes at real speed

	var capped := true
	var max_tree := 0
	for t in forest.trees():
		capped = capped and t.branch_count <= t.branch_cap
		max_tree = maxi(max_tree, t.branch_count)
	# No orbit: a planted tree stays on its spot, while the hero has turned on its trunk.
	var still: bool = forest.trees().back().global_position.distance_to(planted_pos) < 1e-3
	var hero_turned: bool = absf(main.tree.rotation.y - hero_yaw0) > 0.01
	var interior_room: bool = is_equal_approx(float(main.ground._material.get_shader_parameter("inside_passthrough")), 1.0)

	var img := root.get_viewport().get_texture().get_image()
	var err := img.save_png("res://.spike-out/forest.png")

	# The governor, driven by hand (the Mac reports no GPU time): a frame running hot must
	# shrink the budget and the drawn forest with it, and a cool one must grow it back.
	var eye3: Vector3 = main.xr_camera.global_position
	forest.apply_lod(eye3)
	var cost0 := forest.visible_cost
	var budget0 := forest.budget
	forest.gpu_ms = 0.0
	for i in 12:
		forest.govern_step(13.5, 13.89)
	forest.apply_lod(eye3)
	var hot_budget := forest.budget
	var hot_cost := forest.visible_cost
	var lods := {}
	for t in forest.trees():
		lods[t.lod] = int(lods.get(t.lod, 0)) + 1
	# Over budget is allowed only when every tree is already at its coarsest.
	var fits := hot_cost <= hot_budget or lods.keys() == [FractalTree.LOD_MAX]
	forest.gpu_ms = 0.0
	for i in 40:
		forest.govern_step(5.0, 13.89)
	forest.apply_lod(eye3)
	var governor_ok: bool = hot_budget < budget0 and hot_cost < cost0 and fits \
		and forest.budget > hot_budget and forest.visible_cost > hot_cost
	print("FORESTSHOT governor %s budget %d->%d->%d drawn %d->%d->%d lods_hot=%s" % [
		"PASS" if governor_ok else "FAIL", budget0, hot_budget, forest.budget,
		cost0, hot_cost, forest.visible_cost, str(lods)])

	# The planting ring has to agree with the planting ray, and has to give up when the
	# ray does. Aim down at a known floor point, then aim at the ceiling, and require the
	# marker to follow and then vanish. A ring that showed wherever you looked would be
	# worse than no ring: it would promise a root the trigger does not deliver.
	var marker_on: bool = await _probe_marker(main, Vector3(0.6, 1.6, 0.4), Vector3(-35.0, 0.0, 0.0))
	var marker_hit: Vector2 = Vector2(main.plant_marker.global_position.x,
		main.plant_marker.global_position.z)
	var expect = main._hand_floor_hit(main.right_hand)
	var marker_matches: bool = expect != null and marker_hit.distance_to(expect) < 0.01
	var label: String = main.plant_marker.get_node("Species").text
	var label_ok: bool = label == forest.peek_plant(FractalTree.SHAPE_NAMES[main.tree_shape_idx]).to_upper()
	var marker_off: bool = not await _probe_marker(main, Vector3(0.6, 1.6, 0.4), Vector3(40.0, 0.0, 0.0))

	var top_ok: bool = await _top_grove(main, forest)

	var ok: bool = sown == Forest.GROVE_COUNT and species.size() >= 8 and in_ring and clear_of_eye \
		and planted_a and planted_b and promise_kept and capped and still and hero_turned \
		and governor_ok and interior_room and marker_on and marker_matches and label_ok and marker_off and err == OK \
		and top_ok
	print("FORESTSHOT %s sown=%d species=%d ring=%s eye_clear=%s planted=%s/%s promise=%s(%s,%s) capped=%s max_tree=%d still=%s hero_turned=%s" % [
		"PASS" if ok else "FAIL", sown, species.size(), str(in_ring), str(clear_of_eye),
		str(planted_a), str(planted_b), str(promise_kept), got_a, got_b, str(capped), max_tree,
		str(still), str(hero_turned)])
	print("FORESTSHOT trees=%d branches=%d leaves=%d builds=%d budget=%d visible=%d gpu_ms=%.2f room=%s marker=%s/%s/%s label=%s frames=%d" % [
		main._forest_tree_count(), main._forest_branch_count(), forest.leaf_total(), forest.builds,
		forest.budget, forest.visible_cost, forest.gpu_ms, str(interior_room),
		str(marker_on), str(marker_matches), str(marker_off), label, frames])
	quit(0 if ok else 1)


## COUNT's top step through its own tile, in the grove: sown afresh at the bigger size, inside
## its wider ring, every trunk clear of the next and in front of you, grown under the script cap
## and drawn within the budget. Then back to the default. Saves forest_<n>.png.
func _top_grove(main, forest: Forest) -> bool:
	var top := Forest.STEPS.size() - 1
	var tile = null
	for it in main.menu.items:
		if it.label == "COUNT" and it.section == "make":
			tile = it
	if tile == null:
		print("FORESTSHOT top FAIL no COUNT tile")
		return false
	main.xr_camera.position = Vector3(0.0, 1.6, 0.0)
	main.xr_camera.rotation_degrees = Vector3(-14.0, 0.0, 0.0)
	main._recenter()
	await process_frame
	var planted0 := forest.planted_count()
	var read0 := str(tile.read.call())
	var b0 := forest.builds
	var t0 := Time.get_ticks_usec()
	tile.step.call(top - forest.count_idx)
	var sow_ms := float(Time.get_ticks_usec() - t0) / 1000.0
	var want: int = forest.step()["grove"]
	var r_max := sqrt(Forest.GROVE_R_MIN * Forest.GROVE_R_MIN + float(want) / Forest.GROVE_COUNT
		* (Forest.GROVE_R_MAX * Forest.GROVE_R_MAX - Forest.GROVE_R_MIN * Forest.GROVE_R_MIN))
	var eye_w: Vector3 = main.xr_camera.global_position
	var eye_l := forest.to_local(eye_w)
	var eye2 := Vector2(eye_l.x, eye_l.z)
	var sown := 0
	var in_ring := true
	var in_front := true
	var clear := true
	var ps: Array[Vector2] = []
	for t in forest.trees():
		if t.hand_planted:
			continue
		sown += 1
		var p := forest.to_local(t.global_position)
		var q := Vector2(p.x, p.z)
		in_ring = in_ring and q.length() >= Forest.GROVE_R_MIN - 1e-3 and q.length() <= r_max + 1e-3
		in_front = in_front and q.dot(eye2.normalized()) <= eye2.length() - Forest.GROVE_EYE_CLEAR + 1e-3
		clear = clear and Vector2(t.global_position.x, t.global_position.z).distance_to(
			Vector2(eye_w.x, eye_w.z)) >= Forest.GROVE_EYE_CLEAR - 1e-3
		ps.append(q)
	var gap := INF
	for a in ps.size():
		for b in range(a + 1, ps.size()):
			gap = minf(gap, ps[a].distance_to(ps[b]))
	var meter := {"sum": 0, "n": 0, "max": 0, "fmax": 0, "over": 0, "ls": main._proc_us_sum,
		"lf": main._proc_frames}
	Engine.time_scale = SPEED
	var frames := 0
	while frames < 8000:
		frames += 1
		await process_frame
		_sample(main, meter)
		var all_grown := true
		for t in forest.trees():
			all_grown = all_grown and t.built and t.grow_t > t.grow_s + 1.0
		if all_grown and frames > 60:
			break
	Engine.time_scale = 1.0
	for i in 30:
		await process_frame
		_sample(main, meter)
	forest.apply_lod(main.xr_camera.global_position)
	for i in 3:
		await process_frame
	# Counted from the scene, all as if in view (a frame difference moves with the menu's redraws).
	var draws := 2 * forest.whole_drawn() + 2 * forest.far_batch().batch_count()
	var img := root.get_viewport().get_texture().get_image()
	img.save_png("res://.spike-out/forest_%d.png" % int(forest.step()["n"]))
	var max_ms: float = meter["max"] / 1000.0
	var fmax_ms: float = meter["fmax"] / 1000.0
	var ok: bool = read0 == "30 trees" and str(tile.read.call()) == "%d trees" % int(forest.step()["n"]) \
		and sown >= int(want * 0.9) and in_ring and in_front and clear and gap >= Forest.GROVE_SPACING - 1e-3 \
		and forest.planted_count() == planted0 and forest.visible_cost <= forest.budget \
		and fmax_ms <= FOREST_CAP_MS and int(meter["over"]) <= maxi(1, int(meter["n"] * 0.01)) \
		and frames < 8000
	print("FORESTSHOT top %s count=%s grove=%d/%d r_max=%.2fm in_ring=%s in_front=%s eye_clear=%s gap=%.2fm planted_kept=%s sow=%.2fms computes=%d script_ms avg=%.2f max=%.2f forest=%.2f (cap %.1f) over %.1fms: %d/%d visible=%d budget=%d branches=%d leaves=%d tree_draws=%d frames=%d" % [
		"PASS" if ok else "FAIL", str(tile.read.call()), sown, want, r_max, str(in_ring), str(in_front),
		str(clear), gap, str(forest.planted_count() == planted0), sow_ms, forest.builds - b0,
		meter["sum"] / 1000.0 / maxf(1.0, meter["n"]), max_ms, fmax_ms, FOREST_CAP_MS, SCRIPT_CAP_MS,
		meter["over"], meter["n"], forest.visible_cost, forest.budget, forest.drawn_branches,
		forest.drawn_leaves, draws, frames])
	tile.step.call(-forest.count_idx)
	await process_frame
	return ok


## One frame of main's script exactly (as avenue_shot.gd's meter), the forest's tick in it, and
## whether the whole script passed SCRIPT_CAP_MS.
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


## Point the right hand somewhere and report whether the planting ring came up. Negative
## rotation on X aims the controller down at the floor; positive aims it at the ceiling.
func _probe_marker(main, origin: Vector3, rot_deg: Vector3) -> bool:
	main.right_hand.position = origin
	main.right_hand.rotation_degrees = rot_deg
	for i in 12:
		main._tick_plant_marker(0.05)
		await process_frame
	# On failure, say which gate closed. "the ring did not appear" is not a diagnosis.
	if not main.plant_marker.visible and rot_deg.x < 0.0:
		print("FORESTSHOT probe-miss help=%s menu_active=%s planted=%d hit=%s" % [
			str(main.help.is_open()), str(main._menu_active),
			main.forest.planted_count(), str(main._hand_floor_hit(main.right_hand))])
	return main.plant_marker.visible
