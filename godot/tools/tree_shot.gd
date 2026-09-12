extends SceneTree

## Desktop render of tree mode to .spike-out/tree.png through the real main scene,
## after the growth has finished. Sway, scale and stereo are for the headset.
##
##   tools/tree_shot.sh

func _init() -> void:
	var scene: PackedScene = load("res://main.tscn")
	var main := scene.instantiate()
	root.add_child(main)
	for i in 40:
		await process_frame
	main.help.close()
	# A standing eye, placed before the mode switch so the one-time placement recenter
	# has already fired.
	main.xr_camera.position = Vector3(0.0, 1.6, 0.0)
	main.xr_camera.rotation_degrees = Vector3(-8.0, 0.0, 0.0)
	for i in 3:
		await process_frame
	main._set_mode("tree")
	# Let it grow: the tree's own clock runs on real frame time, so wait on that rather
	# than counting frames (the Mac window runs unthrottled and 500 frames was 2.8 s).
	var frames := 0
	while main.tree.grow_t < FractalTree.GROW_S + 2.5 and frames < 4000:
		frames += 1
		await process_frame
	var img := root.get_viewport().get_texture().get_image()
	var err := img.save_png("res://.spike-out/tree.png")
	print("TREESHOT %s branches=%d leaves=%d shape=%s grow=%.2f" % ["PASS" if err == OK else "FAIL %d" % err,
		main.tree.branch_count, main.tree.leaf_count, main.tree.shape, main.tree.grow_progress()])
	quit(0 if err == OK else 1)
