extends SceneTree

## Desktop render of bulb mode as SPLATS (not the marcher) to .spike-out/splat.png, from
## outside, after the settle and bake. The check that a change to the splat mesh or
## shader moved cost and not pixels: diff against the previous frame with
## tools/png_diff.py.
##
##   tools/splat_shot.sh

func _init() -> void:
	var scene: PackedScene = load("res://main.tscn")
	var main := scene.instantiate()
	root.add_child(main)
	for i in 40:
		await process_frame
	main.help.close()
	main.xr_camera.position = Vector3(0.0, 1.6, 0.0)
	for i in 3:
		await process_frame
	main._set_mode("bulb")
	main.spin = false
	main.breath_idx = 2
	for i in 200:
		await process_frame
	main.cloud.scale = Vector3.ONE * 0.9
	main.cloud.global_position = main.xr_camera.global_transform.origin + Vector3(0.0, -0.2, -2.6)
	main.cloud.rotation = Vector3.ZERO
	for i in 20:
		await process_frame
	var img := root.get_viewport().get_texture().get_image()
	var err := img.save_png("res://.spike-out/splat.png")
	print("SPLATSHOT %s count=%d baked=%s" % ["PASS" if err == OK else "FAIL %d" % err,
		main.cloud.get_count(), str(main.cloud.bake_ready)])
	var adapt_ok := await _adapt_ladder(main)
	quit(0 if err == OK and adapt_ok else 1)


## ADAPT's three rungs (100%, 50%, off) must be three different pictures. The density sizing
## only runs on unfitted surface splats, so FIT SPLATS goes off first. The 50% rung once
## rendered exactly as 100%: the shader read density_strength only as an on/off switch.
func _adapt_ladder(main) -> bool:
	main.auto_bake = false
	main.cloud.clear_bake()
	for i in 90:
		await process_frame
	# The bulb keeps drifting, so rungs are compared two frames apart, interleaved: 100%,
	# 100% again (what two frames of drift alone move), 50%, off. Six rounds, summed.
	var noise := 0.0
	var d01 := 0.0
	var d12 := 0.0
	for round in 6:
		var g: Array[PackedByteArray] = []
		for idx in [0, 0, 1, 2]:
			main.density_idx = idx
			main._apply_point_look()
			await process_frame
			await process_frame
			var im := root.get_viewport().get_texture().get_image()
			im.convert(Image.FORMAT_RGB8)
			im.resize(320, 200, Image.INTERPOLATE_BILINEAR)
			g.append(im.get_data())
		noise += _diff(g[0], g[1]) / 6.0
		d01 += _diff(g[1], g[2]) / 6.0
		d12 += _diff(g[2], g[3]) / 6.0
	main.density_idx = 0
	main._apply_point_look()
	# Fixed, each step moves about 3x the drift; with the 50% rung broken, 100%->50% moves
	# about 0.9x it. A 3x bar sat on the fixed value and flaked, so the bar is 2x.
	var bar := maxf(0.001, noise * 2.0)
	var ok := d01 > bar and d12 > bar
	print("SPLATSHOT adapt %s 100%%->50%% %.4f 50%%->off %.4f noise %.4f (each must be > %.4f)" % [
		"PASS" if ok else "FAIL", d01, d12, noise, bar])
	return ok


func _diff(a: PackedByteArray, b: PackedByteArray) -> float:
	var s := 0
	for j in a.size():
		s += absi(a[j] - b[j])
	return float(s) / (255.0 * float(a.size()))
