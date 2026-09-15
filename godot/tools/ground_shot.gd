extends SceneTree

## Desktop render of ground mode to .spike-out/ground.png: the clipmap fill, the shader
## and the displaced radial mesh through the real main scene. Stereo and scale are for
## the headset; this proves the terrain draws.
##
## It also sweeps every escape-time family into .spike-out/ground_<name>.png. That sweep
## is the ONLY thing in the repo that compiles and runs ground.glsl: shader_check.sh
## only handles spatial .gdshader files, so a broken compute shader reaches the headset
## unless something actually dispatches it. Each family must produce a picture, not just
## a saved file.
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
	var ok: bool = err == OK
	print("GROUNDSHOT %s progress=%.2f orbit=%d visible=%s" % ["PASS" if ok else "FAIL %d" % err,
		main.ground.progress(), main.orbit.point_count, str(main.orbit.visible)])

	# Every family, from the same pose. A formula that fails to iterate leaves the tiles
	# at their cleared value, which renders as one flat colour: measuring the spread is
	# what separates "it ran" from "it wrote something".
	main.orbit_on = false
	main.orbit.visible = false
	for f in FractalGround.FORMULA_NAMES.size():
		main.ground.set_formula(f)
		for i in 150:
			await process_frame
		var fi: Image = root.get_viewport().get_texture().get_image()
		var name: String = FractalGround.FORMULA_NAMES[f]
		var fe: int = fi.save_png("res://.spike-out/ground_%s.png" % name.replace(" ", "_"))
		var sp := _spread(fi)
		var drew: bool = sp > 0.02
		ok = ok and fe == OK and drew and main.ground.progress() > 0.99
		print("GROUNDSHOT %s %s spread=%.3f progress=%.2f" % [
			name, "PASS" if (fe == OK and drew) else "FAIL", sp, main.ground.progress()])
	print("GROUNDSHOT %s families=%d" % ["PASS" if ok else "FAIL",
		FractalGround.FORMULA_NAMES.size()])
	quit(0 if ok else 1)


## Standard deviation of luminance over a coarse grid. A cleared or uniformly-fogged
## frame sits near zero however cleanly it saved.
func _spread(img: Image) -> float:
	var n := 0
	var sum := 0.0
	var sum2 := 0.0
	var step := maxi(1, img.get_width() / 80)
	for y in range(0, img.get_height(), step):
		for x in range(0, img.get_width(), step):
			var c := img.get_pixel(x, y)
			var l := 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
			sum += l
			sum2 += l * l
			n += 1
	if n == 0:
		return 0.0
	var mean := sum / float(n)
	return sqrt(maxf(0.0, sum2 / float(n) - mean * mean))
