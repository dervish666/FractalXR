extends SceneTree

## Desktop render of the raymarched bulb to .spike-out/march.png: proves the shader draws
## a lit surface with the real genome, framing and palette plumbing before it goes on
## the headset. Stereo, cost and how it reads from inside are headset questions.
##
##   tools/march_shot.sh

func _init() -> void:
	var scene: PackedScene = load("res://main.tscn")
	var main := scene.instantiate()
	root.add_child(main)
	for i in 40:
		await process_frame
	main._set_mode("bulb")
	for i in 30:
		await process_frame
	main.surface_idx = 1
	main._apply_surface()
	# Step back so the whole surface is in frame instead of the inside of it.
	main.cloud.scale = Vector3.ONE * 0.9
	main.cloud.position = Vector3(0.0, 0.0, -2.6)
	for i in 30:
		await process_frame
	var img := root.get_viewport().get_texture().get_image()
	var err := img.save_png("res://.spike-out/march.png")
	print("MARCHSHOT %s marching=%s steps=%d" % ["PASS" if err == OK else "FAIL %d" % err,
		str(main.march.visible), main.SURFACE_STEPS[main.surface_idx]])
	quit(0 if err == OK else 1)
