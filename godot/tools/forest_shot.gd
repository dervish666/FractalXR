extends SceneTree

## Integration proof for TREE's forest through the real main scene: the grove is sown on
## entry with mixed species inside its ring, every tree respects its branch cap, planting
## grows exactly the species the ring names, planted trees do not orbit under the ambient
## spin, the LOD governor reports, and the planting ring follows the ray. Saves the grown
## grove to .spike-out/forest.png.
##
##   tools/forest_shot.sh

const SPEED := 4.0   # the forest's clocks run on frame delta; this only shortens the wait


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

	var ok: bool = sown == Forest.GROVE_COUNT and species.size() >= 8 and in_ring and clear_of_eye \
		and planted_a and planted_b and promise_kept and capped and still and hero_turned \
		and governor_ok and interior_room and marker_on and marker_matches and label_ok and marker_off and err == OK
	print("FORESTSHOT %s sown=%d species=%d ring=%s eye_clear=%s planted=%s/%s promise=%s(%s,%s) capped=%s max_tree=%d still=%s hero_turned=%s" % [
		"PASS" if ok else "FAIL", sown, species.size(), str(in_ring), str(clear_of_eye),
		str(planted_a), str(planted_b), str(promise_kept), got_a, got_b, str(capped), max_tree,
		str(still), str(hero_turned)])
	print("FORESTSHOT trees=%d branches=%d leaves=%d builds=%d budget=%d visible=%d gpu_ms=%.2f room=%s marker=%s/%s/%s label=%s frames=%d" % [
		main._forest_tree_count(), main._forest_branch_count(), forest.leaf_total(), forest.builds,
		forest.budget, forest.visible_cost, forest.gpu_ms, str(interior_room),
		str(marker_on), str(marker_matches), str(marker_off), label, frames])
	quit(0 if ok else 1)


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
