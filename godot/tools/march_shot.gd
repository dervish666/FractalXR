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
	# Second frame: the Mandelbox from inside its roomiest pore, the ENTER path. (A
	# scale-3 box was tried for bigger rooms and turned out to be a Cantor dust: every
	# "room" was a gap between grains and the marcher painted speckle.)
	var box := -1
	for i in main.library.bulbs.size():
		if main.library.bulbs[i].get("name", "") == "Mandelbox":
			box = i
	main._load_bulb(box)
	for i in 30:
		await process_frame
	main.surface_idx = 2
	main._apply_surface()
	# A standing eye, placed BEFORE entering: the first frame the camera leaves the
	# origin triggers the app's one-time placement recenter, which would undo ENTER.
	main.xr_camera.position = Vector3(0.0, 1.6, 0.0)
	main.xr_camera.rotation_degrees = Vector3(-5.0, 35.0, 0.0)
	for i in 3:
		await process_frame
	main._enter_inside()
	for i in 30:
		await process_frame
	var img2 := root.get_viewport().get_texture().get_image()
	var err2 := img2.save_png("res://.spike-out/march_inside.png")
	print("MARCHSHOT %s inside box=%d steps=%d scale=%.1f" % ["PASS" if err2 == OK else "FAIL %d" % err2,
		box, main.SURFACE_STEPS[main.surface_idx], main.cloud.scale.x])
	quit(0 if err == OK and err2 == OK else 1)
