extends SceneTree

## Desktop render of ground mode to .spike-out/ground.png: the clipmap fill, the shader
## and the displaced radial mesh through the real main scene. Stereo and scale are for
## the headset; this proves the terrain draws.
##
##   tools/ground_shot.sh

func _init() -> void:
	var scene: PackedScene = load("res://main.tscn")
	var main := scene.instantiate()
	root.add_child(main)
	for i in 40:
		await process_frame
	main._set_mode("ground")
	main.help.close()
	# Home stands inside the set, whose floor is deliberately near-black, so stand on
	# the exterior above the cardioid instead: a standing eye looking down and along.
	main.ground.centre = Vector2(-0.55, 0.62)
	main.xr_camera.position = Vector3(0.0, 1.6, 0.0)
	main.xr_camera.rotation_degrees = Vector3(-22.0, 0.0, 0.0)
	for i in 240:
		await process_frame
	var img := root.get_viewport().get_texture().get_image()
	var err := img.save_png("res://.spike-out/ground.png")
	print("GROUNDSHOT %s progress=%.2f" % ["PASS" if err == OK else "FAIL %d" % err, main.ground.progress()])
	quit(0 if err == OK else 1)
