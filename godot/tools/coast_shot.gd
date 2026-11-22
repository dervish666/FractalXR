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

## Measured with the clock stopped between the two shots: 0.017 to 0.018 with the ceiling's
## view mirrored, 0.040 without (the sea pinned to its grazing Fresnel).
const MIRROR_MAX_DIFF := 0.03
## LANTERN at eye height between them must light the ceiling about as much as the floor. With
## the ceiling's +Y normals it faced away and got only the 0.18 ambient term.
const MIRROR_LAMP_MIN := 0.6

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
	ok = await _mirror() and ok
	print("COASTSHOT %s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)


## MIRROR: the same ground overhead, face down. From halfway up, looking up must show the
## floor's view turned top to bottom, view-dependent shading (V3's sea, Fresnel, gloss) and all.
func _mirror() -> bool:
	var g: FractalGround = main.ground
	var sp: Vector3 = SPOTS[0]
	g.wpu = FractalGround.WPU_BASE * sp.z
	g._sync_stage()
	g.set_viewer_fractal(sp.x, sp.y)
	main.ground_relief_idx = FractalMain.GROUND_RELIEF.find("coast")
	main._apply_ground_look()
	g.set_sky(3.0)
	main.xr_camera.position = Vector3(0.0, 1.5, 0.0)
	var shots := []
	var gains := []
	var lamp: Vector3 = main.xr_camera.global_position + Vector3(0.0, 0.0, -0.5)
	for pitch in [-30.0, 30.0]:
		main.xr_camera.rotation_degrees = Vector3(pitch, 0.0, 0.0)
		for i in 150:
			await process_frame
		# Stop the clock so the second view sees the same swell: 150 frames apart, the moving
		# sea alone varied this diff from 0.013 to 0.030.
		Engine.time_scale = 0.0
		for i in 2:
			await process_frame
		var unlit := root.get_viewport().get_texture().get_image()
		shots.append(unlit)
		RenderingServer.global_shader_parameter_set(&"hand_light_pos", lamp)
		RenderingServer.global_shader_parameter_set(&"hand_light_col", Vector3(1.0, 0.9, 0.76) * 0.95)
		for i in 3:
			await process_frame
		gains.append(_gain(unlit, root.get_viewport().get_texture().get_image()))
		RenderingServer.global_shader_parameter_set(&"hand_light_col", Vector3.ZERO)
		for i in 3:
			await process_frame
	Engine.time_scale = 1.0
	g.set_sky(0.0)
	shots[1].save_png("%s/mirror_up.png" % OUT)
	var floor_img: Image = shots[0]
	floor_img.flip_y()
	floor_img.save_png("%s/mirror_floor_flipped.png" % OUT)
	var d := _diff(floor_img, shots[1])
	var good := d < MIRROR_MAX_DIFF
	print("COASTSHOT mirror %s up against the floor flipped: diff %.4f (max %.3f)" % [
		"PASS" if good else "FAIL", d, MIRROR_MAX_DIFF])
	var ratio: float = gains[1] / maxf(gains[0], 1e-6)
	var lamp_ok: bool = gains[0] > 0.002 and ratio > MIRROR_LAMP_MIN
	print("COASTSHOT mirror lantern %s floor gain %.4f, ceiling %.4f (ratio %.2f, min %.2f)" % [
		"PASS" if lamp_ok else "FAIL", gains[0], gains[1], ratio, MIRROR_LAMP_MIN])
	return good and lamp_ok


## Mean signed brightness gain from a to b on a coarse grid (the lantern only adds).
func _gain(a: Image, b: Image) -> float:
	var sum := 0.0
	var n := 0
	var step := maxi(1, a.get_width() / 160)
	for y in range(0, a.get_height(), step):
		for x in range(0, a.get_width(), step):
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			sum += ((cb.r + cb.g + cb.b) - (ca.r + ca.g + ca.b)) / 3.0
			n += 1
	return sum / float(maxi(n, 1))


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
