extends SceneTree

## Every tree species grown as the hero, one frame each, through the real main scene, to
## .spike-out/species/<name>.png. species_shot.sh tiles them into species.png. The grove
## is cleared so each frame is one species against the void. Sway, scale and stereo are
## for the headset.
##
##   tools/species_shot.sh

func _init() -> void:
	var scene: PackedScene = load("res://main.tscn")
	var main := scene.instantiate()
	root.add_child(main)
	for i in 40:
		await process_frame
	main.help.close()
	main.xr_camera.position = Vector3(0.0, 1.6, 0.0)
	main.xr_camera.rotation_degrees = Vector3(0.0, 0.0, 0.0)
	for i in 3:
		await process_frame
	main.spin = false
	main._set_mode("tree")
	main.forest.succession = false
	main.forest.clear()
	# Step back and look at the hero's middle: it stands 2.2 m ahead of the eye above.
	main.xr_camera.position = Vector3(0.0, 2.8, 5.2)
	main.xr_camera.look_at(Vector3(0.0, 2.5, -2.2))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://.spike-out/species"))
	var ok := 0
	for i in FractalTree.SHAPE_NAMES.size():
		main._cycle_tree_shape(i - main.tree_shape_idx)
		main.tree.seed_value = 7
		main.tree.build()
		main.tree.grow_t = main.tree.grow_s + 2.0
		for f in 6:
			await process_frame
		var img := root.get_viewport().get_texture().get_image()
		var s: String = FractalTree.SHAPE_NAMES[i]
		if img.save_png("res://.spike-out/species/%s.png" % s) == OK:
			ok += 1
		print("SPECIES %s branches=%d leaves=%d height=%.1f" % [s, main.tree.branch_count,
			main.tree.leaf_count, main.tree.height_m])
	print("SPECIESSHOT %s %d/%d" % ["PASS" if ok == FractalTree.SHAPE_NAMES.size() else "FAIL",
		ok, FractalTree.SHAPE_NAMES.size()])
	quit(0 if ok == FractalTree.SHAPE_NAMES.size() else 1)
