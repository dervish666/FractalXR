extends SceneTree

## RELIEF COAST against TERRAIN from head height, to .spike-out/coast/: the set's edge as a
## flat beach and the open exterior as hills. Two spots, each TERRAIN then COAST at HEIGHT
## 1x, looking along the ground and then down at it. Checks COAST changed the picture (the
## control is the TERRAIN frame) and logs the hills' height range under the camera's view.
##
##   tools/coast_shot.sh

const OUT := "res://.spike-out/coast"
## (fractal x, y, zoom): the cardioid's upper flank at 1x, and seahorse valley at 64x.
const SPOTS := [Vector3(-0.55, 0.62, 1.0), Vector3(-0.7445, 0.118, 64.0)]

var main: Node


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var scene: PackedScene = load("res://main.tscn")
	main = scene.instantiate()
	root.add_child(main)
	for i in 40:
		await process_frame
	main._set_mode("ground")
	main.help.close()
	main.orbit_on = false
	main.orbit.visible = false
	main.left_hand.rotation_degrees = Vector3(0.0, 0.0, 180.0)
	main.xr_camera.position = Vector3(0.0, 1.6, 0.0)
	main.xr_camera.fov = 90.0
	var ok := true
	for si in SPOTS.size():
		var sp: Vector3 = SPOTS[si]
		var g: FractalGround = main.ground
		g.wpu = FractalGround.WPU_BASE * sp.z
		g._sync_stage()
		g.set_viewer_fractal(sp.x, sp.y)
		var frames := {}
		for relief in ["terrain", "coast"]:
			main.ground_relief_idx = FractalMain.GROUND_RELIEF.find(relief)
			main.ground_height_idx = FractalMain.GROUND_HEIGHT.find(1.0)
			main._apply_ground_look()
			# Head height looking along, head height looking down, and from 6 m up, where the
			# hills' shape reads against each other.
			for view: Vector2 in [Vector2(1.6, -8.0), Vector2(1.6, -40.0), Vector2(6.0, -22.0)]:
				var pitch := view.y
				main.xr_camera.position = Vector3(0.0, view.x, 0.0)
				main.xr_camera.rotation_degrees = Vector3(pitch, 0.0, 0.0)
				for i in 150:
					await process_frame
				var img := root.get_viewport().get_texture().get_image()
				var name := "spot%d_%s_%d%s" % [si, relief, int(-pitch), "_up" if view.x > 2.0 else ""]
				img.save_png("%s/%s.png" % [OUT, name])
				frames[name] = img
		var diff := _diff(frames["spot%d_terrain_8" % si], frames["spot%d_coast_8" % si])
		var changed := diff > 0.02
		ok = ok and changed
		print("COASTSHOT spot%d %s diff %.3f progress %.2f" % [si, "PASS" if changed else "FAIL",
			diff, main.ground.progress()])
	print("COASTSHOT %s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)


func _diff(a: Image, b: Image) -> float:
	var sum := 0.0
	var n := 0
	var step := maxi(1, a.get_width() / 160)
	for y in range(0, a.get_height(), step):
		for x in range(0, a.get_width(), step):
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			sum += absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)
			n += 1
	return sum / (3.0 * n)
