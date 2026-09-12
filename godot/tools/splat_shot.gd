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
	quit(0 if err == OK else 1)
