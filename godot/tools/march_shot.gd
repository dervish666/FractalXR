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
	# STYLE on the marched surface (V2, V4): neon and chrome must each change the picture and
	# draw something. Then LANTERN lit by hand: the light only adds, so the signed gain rises
	# and comes back when it is put out.
	# Hold the bulb still first: the ambient spin and the breath move more pixels than the
	# lantern lights, and the gain is signed over the whole frame.
	main.spin = false
	main._drift = false
	main.breath_idx = main.BREATH_STEPS.find(0.0)
	var styled_ok := true
	for st in [[1, "neon"], [8, "chrome"], [9, "opal"], [10, "verdigris"], [11, "frost"], [12, "velvet"]]:
		main._set_art(st[0])
		for i in 6:
			await process_frame
		var s_img := root.get_viewport().get_texture().get_image()
		s_img.save_png("res://.spike-out/march_%s.png" % st[1])
		var d := _gain(img, s_img, true)
		var lit_px := _lit(s_img)
		var good := d > 0.01 and lit_px > 0.02
		styled_ok = styled_ok and good
		print("MARCHSHOT %s style=%s diff=%.4f lit=%.3f" % ["PASS" if good else "FAIL", st[1], d, lit_px])
	main._set_art(0)
	for i in 30:
		await process_frame
	var pre := root.get_viewport().get_texture().get_image()
	var at: Vector3 = main.xr_camera.global_position.lerp(main.cloud.global_position, 0.55)
	RenderingServer.global_shader_parameter_set(&"hand_light_pos", at)
	RenderingServer.global_shader_parameter_set(&"hand_light_col", Vector3(1.0, 0.9, 0.76) * 0.95)
	for i in 3:
		await process_frame
	var lit_img := root.get_viewport().get_texture().get_image()
	lit_img.save_png("res://.spike-out/march_lantern.png")
	RenderingServer.global_shader_parameter_set(&"hand_light_col", Vector3.ZERO)
	for i in 3:
		await process_frame
	var off_img := root.get_viewport().get_texture().get_image()
	var dl := _gain(pre, lit_img, false)
	var doff := _gain(pre, off_img, false)
	var lantern_ok := dl > 0.002 and absf(doff) < 0.3 * dl
	styled_ok = styled_ok and lantern_ok
	print("MARCHSHOT %s lantern lit=%.4f off=%.4f" % ["PASS" if lantern_ok else "FAIL", dl, doff])
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
	quit(0 if err == OK and err2 == OK and styled_ok else 1)


## Mean brightness change from a to b on a coarse grid: absolute, or signed (b brighter > 0).
func _gain(a: Image, b: Image, absolute: bool) -> float:
	var n := 0
	var sum := 0.0
	var step := maxi(1, a.get_width() / 80)
	for y in range(0, a.get_height(), step):
		for x in range(0, a.get_width(), step):
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			var d := ((cb.r + cb.g + cb.b) - (ca.r + ca.g + ca.b)) / 3.0
			sum += absf(d) if absolute else d
			n += 1
	return sum / float(maxi(n, 1))


## Share of the coarse grid that is not black.
func _lit(img: Image) -> float:
	var n := 0
	var on := 0
	var step := maxi(1, img.get_width() / 80)
	for y in range(0, img.get_height(), step):
		for x in range(0, img.get_width(), step):
			n += 1
			if img.get_pixel(x, y).get_luminance() > 0.02:
				on += 1
	return float(on) / float(maxi(n, 1))
