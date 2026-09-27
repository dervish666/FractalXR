extends SceneTree

## Deep zoom through the real main scene: stand over a boundary point, zoom to each stage,
## let the clipmap fill, save .spike-out/ground_deep_s<stage>.png and report what the fill
## cost. ground_us is the GPU time of each frame's fill (timestamps), so the sum over the
## fill is the whole bill and frames-to-fill is how long the picture takes to sharpen.
##
##   tools/ground_deep_shot.sh [stage ...]      (default 3 11 13)
##
## A picture shows blocks; it cannot show a df32 path that is subtly wrong. That is
## tools/ground_check.sh's job. This one answers "does it look like zooming in" and "what
## does it cost in the app".

## Seahorse valley, a classic deep-zoom target with structure at every scale, written to
## more digits than a double holds.
const SPOT := [-0.743643887037158704752191506114774, 0.131825904205311970493132056385139]


func _init() -> void:
	var stages: Array[int] = []
	for a in OS.get_cmdline_user_args():
		if a.is_valid_int():
			stages.append(int(a))
	if stages.is_empty():
		stages = [3, 11, 13]
	var main = (load("res://main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	for i in 40:
		await process_frame
	main._set_mode("ground")
	main.help.close()
	main.orbit_on = false
	main.orbit.visible = false
	main.xr_camera.position = Vector3(0.0, 1.6, 0.0)
	main.xr_camera.rotation_degrees = Vector3(-50.0, 0.0, 0.0)
	main.left_hand.position = Vector3(-0.3, 1.0, -0.2)
	main.left_hand.rotation_degrees = Vector3(0.0, 0.0, 180.0)
	var g: FractalGround = main.ground
	var ok := true
	for st in stages:
		# A shade over the stage boundary, so level 0 is that stage's texel.
		g.home()
		g.zoom(pow(2.0, float(st)) * 1.05)
		if g.has_method("set_viewer_fractal"):
			g.set_viewer_fractal(SPOT[0], SPOT[1])
		else:   # the pre-df32 build, for a before/after
			g.centre = Vector2(SPOT[0], SPOT[1]) - g._m.basis_xform(g._head_xz) / g.wpu
		await process_frame
		var frames := 0
		var sum_us := 0.0
		var max_us := 0.0
		for i in 6000:
			await process_frame
			frames += 1
			sum_us += g.ground_us
			max_us = maxf(max_us, g.ground_us)
			if i > 5 and g.pending_texels() == 0:
				break
		for i in 10:
			await process_frame
		var img := root.get_viewport().get_texture().get_image()
		var path := "res://.spike-out/ground_deep_s%d.png" % st
		var err := img.save_png(path)
		var filled := g.pending_texels() == 0
		ok = ok and err == OK and filled
		# No timestamps (Metal) reads as a zero cost; say so rather than print it as one.
		var cost := "fill_ms=%.1f mean_us=%.0f max_us=%.0f df_cost=%.1f" % [sum_us / 1000.0,
			sum_us / float(maxi(1, frames)), max_us, g._df_cost] if max_us > 0.0 \
			else "fill cost unavailable (no GPU timestamps on this driver)"
		print("GROUNDDEEP stage=%d zoom=%s frames=%d %s %s %s" % [st, main._zoom_text(g.zoom_factor()),
			frames, cost, "filled" if filled else "NOT FILLED", path])
	print("GROUNDDEEP %s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)
