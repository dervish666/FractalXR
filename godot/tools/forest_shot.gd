extends SceneTree

## Integration proof for TREE's world interactions. It exercises the real main scene:
## select a species, plant it at two world-floor points, verify the secondary depth cap,
## and turn on the ground interior room uniform before saving the resulting grove.

func _init() -> void:
	var scene: PackedScene = load("res://main.tscn")
	var main := scene.instantiate()
	root.add_child(main)
	for i in 40:
		await process_frame
	main.help.close()
	main.xr_camera.position = Vector3(0.0, 1.6, 0.0)
	main.xr_camera.rotation_degrees = Vector3(-12.0, 0.0, 0.0)
	for i in 3:
		await process_frame
	main._set_mode("tree")
	for i in 3:
		await process_frame
	var first_shape: String = FractalTree.SHAPE_NAMES[main.tree_shape_idx]
	var planted_a: bool = main._plant_tree_at(Vector2(-1.5, -1.0))
	main._cycle_tree_shape(1)
	var second_shape: String = FractalTree.SHAPE_NAMES[main.tree_shape_idx]
	var planted_b: bool = main._plant_tree_at(Vector2(1.5, -1.5))
	main.passthrough = true
	main.ground_inside_room = true
	main._apply_ground_look()
	main.tree.grow_t = FractalTree.GROW_S + 1.0
	var capped := true
	for planted in main._forest_trees:
		planted.grow_t = FractalTree.GROW_S + 1.0
		capped = capped and planted.effective_depth() <= main.FOREST_SECONDARY_DEPTH_MAX
	for i in 3:
		await process_frame
	var interior_room: bool = is_equal_approx(float(main.ground._material.get_shader_parameter("inside_passthrough")), 1.0)

	# The planting ring has to agree with the planting ray, and has to give up when the
	# ray does. Aim down at a known floor point, then aim at the ceiling, and require the
	# marker to follow and then vanish. A ring that showed wherever you looked would be
	# worse than no ring: it would promise a root the trigger does not deliver.
	var marker_on: bool = await _probe_marker(main, Vector3(0.6, 1.6, 0.4), Vector3(-35.0, 0.0, 0.0))
	var marker_hit: Vector2 = Vector2(main.plant_marker.global_position.x,
		main.plant_marker.global_position.z)
	var expect = main._hand_floor_hit(main.right_hand)
	var marker_matches: bool = expect != null and marker_hit.distance_to(expect) < 0.01
	var marker_off: bool = not await _probe_marker(main, Vector3(0.6, 1.6, 0.4), Vector3(40.0, 0.0, 0.0))

	var img := root.get_viewport().get_texture().get_image()
	var err := img.save_png("res://.spike-out/forest.png")
	var ok: bool = planted_a and planted_b and main._forest_tree_count() == 3 and capped and interior_room \
		and first_shape != second_shape and marker_on and marker_matches and marker_off and err == OK
	print("FORESTSHOT %s trees=%d branches=%d species=%s/%s room=%s marker=%s/%s/%s" % [
		"PASS" if ok else "FAIL", main._forest_tree_count(), main._forest_branch_count(),
		first_shape, second_shape, str(interior_room),
		str(marker_on), str(marker_matches), str(marker_off)])
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
		print("FORESTSHOT probe-miss help=%s menu_active=%s forest=%d hit=%s" % [
			str(main.help.is_open()), str(main._menu_active),
			main._forest_trees.size(), str(main._hand_floor_hit(main.right_hand))])
	return main.plant_marker.visible
