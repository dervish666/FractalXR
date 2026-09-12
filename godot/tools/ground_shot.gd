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
	# Pose the right hand as a pointer at a spot on the floor ahead, so the orbit trace
	# has somewhere to hang its beads.
	main.right_hand.position = Vector3(0.3, 1.2, -0.2)
	main.right_hand.rotation_degrees = Vector3(-35.0, 8.0, 0.0)
	# Turn the left wrist away from the face: at the controller's default pose the panel
	# faces the head, the menu counts as showing, and the trace hides while it shows.
	main.left_hand.position = Vector3(-0.3, 1.0, -0.2)
	main.left_hand.rotation_degrees = Vector3(0.0, 0.0, 180.0)
	for i in 240:
		await process_frame
	var img := root.get_viewport().get_texture().get_image()
	var err := img.save_png("res://.spike-out/ground.png")
	print("GROUNDSHOT %s progress=%.2f orbit=%d visible=%s" % ["PASS" if err == OK else "FAIL %d" % err,
		main.ground.progress(), main.orbit.point_count, str(main.orbit.visible)])
	quit(0 if err == OK else 1)
