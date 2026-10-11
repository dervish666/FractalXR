extends SceneTree

## FLOOR and BARK (T-55) through the real main scene: how they look and what they cost on this
## Mac's GPU. Sows the default avenue (seed 4321), grows it, and from eye height down the path
## shoots FLOOR off, fractal, leaves and both, then BARK plain, veins and julia from 0.8 m off the
## nearest trunk and from 4 m. Each configuration is held still and timed: the viewport's GPU time,
## its draws and primitives. Then COUNT 500 standing, floor and bark off against both on.
## Ratios on this Mac, not Quest milliseconds.
##
##   tools/tree_look_shot.sh    (.spike-out/look_*.png, look.log)

const FRAMES := 120
const EYE := Vector3(0.0, 1.6, 0.0)
const DOWN_PATH := Vector3(-8.0, 0.0, 0.0)

var _vp: RID


func _init() -> void:
	var main = (load("res://main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	for i in 40:
		await process_frame
	main.help.close()
	main.xr_camera.position = EYE
	main.xr_camera.rotation_degrees = DOWN_PATH
	main.forest.grove_seed = 4321
	main.spin = false
	main._set_mode("tree")
	for i in 3:
		await process_frame
	var forest: Forest = main.forest
	main._sow_avenue(false)
	await _grow(forest)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	_vp = root.get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(_vp, true)

	# FLOOR, down the path.
	for i in Forest.FLOOR_STEPS.size():
		main._set_tree_floor(i)
		forest.apply_lod(main.xr_camera.global_position)
		await _hold(main, EYE, DOWN_PATH)
		_save("look_floor_%s" % Forest.FLOOR_STEPS[i])
		await _measure(main, "floor %s" % Forest.FLOOR_STEPS[i])
	main._set_tree_floor(0)

	# BARK: close on the nearest left-row trunk, then the whole tree from 4 m.
	var trunk := _nearest_trunk(main, forest)
	var near_eye := trunk + Vector3(0.8, 1.2, 0.0)
	var near_rot := _look(near_eye, trunk + Vector3(0.0, 0.9, 0.0))
	var mid_eye := trunk + Vector3(4.0, 1.6, 0.0)
	var mid_rot := _look(mid_eye, trunk + Vector3(0.0, 1.5, 0.0))
	for i in Forest.BARK_STEPS.size():
		main._set_tree_bark(i)
		var name: String = Forest.BARK_STEPS[i]
		await _hold(main, near_eye, near_rot)
		_save("look_bark_%s_near" % name)
		await _measure(main, "bark %s, 0.8 m off a trunk" % name)
		await _hold(main, mid_eye, mid_rot)
		_save("look_bark_%s_mid" % name)
		await _hold(main, EYE, DOWN_PATH)
		_save("look_bark_%s_path" % name)
		await _measure(main, "bark %s, down the path" % name)
	main._set_tree_bark(0)

	# Everything on, down the path, as Sam would see it with both.
	main._set_tree_floor(3)
	main._set_tree_bark(1)
	forest.apply_lod(main.xr_camera.global_position)
	await _hold(main, EYE, DOWN_PATH)
	_save("look_both_veins")
	main._set_tree_bark(2)
	await _hold(main, EYE, DOWN_PATH)
	_save("look_both_julia")
	# Gliding, as the headset would see it: the walk's tunnel with its rest frame, over the floor.
	main._set_tree_bark(1)
	await _hold(main, EYE, DOWN_PATH)
	main._toggle_walk()
	await _grow(forest, true)
	_key(KEY_G, true)
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 1500:
		await process_frame
		if not forest.walk_held:
			_key(KEY_G, true)
	_save("look_walk_moving")
	print("LOOKSHOT walking at %.2f m/s, tunnel %.2f" % [forest.walk_speed, main.vignette.motion])
	_key(KEY_G, false)
	for i in 60:
		await process_frame
	main._toggle_walk()
	main._set_tree_floor(0)
	main._set_tree_bark(0)

	# Fill tests: the cost per pixel, with the effect covering most of the frame. The floor from
	# eye height looking 70 degrees down; the bark 0.2 m off the thickest trunk in the avenue. This
	# Mac's GPU clock wanders (the same view read 0.63 and 1.27 ms on two runs), so each set is
	# measured ROUNDS times, interleaved, and the spread is printed with the medians.
	var down := Vector3(-70.0, 0.0, 0.0)
	main._set_tree_floor(1)
	await _hold(main, EYE, down)
	_save("look_fill_floor")
	await _rounds(main, "fill: floor, looking down (all of the frame)", ["off", "fractal"],
		func(i: int): main._set_tree_floor(i), EYE, down)
	main._set_tree_floor(0)
	var fat := _thickest_trunk(forest)
	var fill_eye: Vector3 = fat[0] + Vector3(float(fat[1]) + 0.2, 0.8, 0.0)
	var fill_rot := _look(fill_eye, fat[0] + Vector3(0.0, 0.8, 0.0))
	for i in Forest.BARK_STEPS.size():
		main._set_tree_bark(i)
		await _hold(main, fill_eye, fill_rot)
		_save("look_fill_bark_%s" % Forest.BARK_STEPS[i])
	main._set_tree_bark(0)
	await _hold(main, fill_eye, fill_rot)
	var share := _lit_share(root.get_viewport().get_texture().get_image())
	await _rounds(main, "fill: bark 0.2 m off a %s trunk (%.2f m radius, %.0f%% of the frame)" % [
		fat[2], fat[1], 100.0 * share], Forest.BARK_STEPS,
		func(i: int): main._set_tree_bark(i), fill_eye, fill_rot)
	main._set_tree_bark(0)


	# COUNT 500 standing: off against floor both and bark veins.
	forest.set_count(Forest.STEPS.size() - 1)
	await _hold(main, EYE, DOWN_PATH)   # the avenue is laid down the way the camera faces
	main._sow_avenue(false)
	await process_frame
	while forest.sowing():
		await process_frame
	await _grow(forest)
	forest.apply_lod(main.xr_camera.global_position)
	await _hold(main, EYE, DOWN_PATH)
	await _measure(main, "COUNT 500, floor off, bark plain")
	main._set_tree_floor(3)
	main._set_tree_bark(1)
	forest.apply_lod(main.xr_camera.global_position)
	await _hold(main, EYE, DOWN_PATH)
	_save("look_500_both_veins")
	await _measure(main, "COUNT 500, floor both, bark veins (litter on %d)" % forest.litter_drawn)
	main._set_tree_bark(2)
	await _measure(main, "COUNT 500, floor both, bark julia")
	print("LOOKSHOT DONE")
	quit(0)


## Fast-forward until every tree is grown (`sprouting_only`: every tree that is not waiting at the
## walk's far end to sprout).
func _grow(forest: Forest, sprouting_only := false) -> void:
	Engine.time_scale = 4.0
	var frames := 0
	while frames < 12000:
		frames += 1
		await process_frame
		var done := true
		for t in forest.trees():
			if sprouting_only and t.grow_rate == 0.0:
				continue
			if not (t.built and t.grow_t > t.grow_s + 2.5):
				done = false
				break
		if done:
			break
	Engine.time_scale = 1.0


func _hold(main, eye: Vector3, rot: Vector3) -> void:
	main.xr_camera.position = eye
	main.xr_camera.rotation_degrees = rot
	for i in 20:
		await process_frame


func _nearest_trunk(main, forest: Forest) -> Vector3:
	var best := INF
	var at := Vector3.ZERO
	var cam: Vector3 = main.xr_camera.global_position
	for t in forest.trees():
		if t.row == 0 and t.draws_own():
			var d := cam.distance_to(t.global_position)
			if d < best:
				best = d
				at = t.global_position
	return at


## The avenue tree with the thickest trunk drawn whole: [base, trunk radius in metres, species].
func _thickest_trunk(forest: Forest) -> Array:
	var best: Array = [Vector3.ZERO, 0.0, ""]
	for t in forest.trees():
		if not t.draws_own() or t.shape_data.is_empty():
			continue
		var buf: PackedFloat32Array = t.shape_data["buf"]
		# Instance 0 is the trunk; its basis x column is the radius times the node's scale.
		var r := Vector3(buf[0], buf[4], buf[8]).length() * t.global_transform.basis.get_scale().x
		if r > float(best[1]):
			best = [t.global_position, r, t.shape]
	return best


## Share of the frame that is not black: the wood in a fill shot (floor off, void behind).
func _lit_share(img: Image) -> float:
	var n := 0
	var lit := 0
	for y in range(0, img.get_height(), 4):
		for x in range(0, img.get_width(), 4):
			n += 1
			if img.get_pixel(x, y).get_luminance() > 0.02:
				lit += 1
	return float(lit) / maxf(1.0, n)


## Euler degrees for a camera at `from` looking at `to`.
func _look(from: Vector3, to: Vector3) -> Vector3:
	var b := Basis.looking_at(to - from, Vector3.UP)
	return b.get_euler() * (180.0 / PI)


## The GPU median of each setting, ROUNDS times over, the settings interleaved so a drift in the
## clock lands on all of them alike. Prints each setting's lowest median, its spread, and its
## difference from the first setting's.
const ROUNDS := 4


func _rounds(main, label: String, names: Array, apply: Callable, eye: Vector3, rot: Vector3) -> void:
	var meds := {}
	for n in names:
		meds[n] = []
	for r in ROUNDS:
		for i in names.size():
			apply.call(i)
			await _hold(main, eye, rot)
			meds[names[i]].append(await _measure(main, "", 240, false))
	print("LOOKSHOT %s" % label)
	var base := 0.0
	for i in names.size():
		var m: Array = meds[names[i]]
		m.sort()
		var best: float = m[0]
		var mid: float = m[m.size() / 2]
		if i == 0:
			base = mid
		print("LOOKSHOT   %-10s gpu median of medians %.3f ms (lowest %.3f, highest %.3f)  vs %s %+.3f ms" % [
			names[i], mid, best, m[-1], names[0], mid - base])


func _measure(main, label: String, frames := FRAMES, report := true) -> float:
	for i in 20:
		await process_frame
	var gpu: Array[float] = []
	var draws := 0.0
	var prims := 0.0
	var w0 := Time.get_ticks_usec()
	for i in frames:
		await process_frame
		gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(_vp))
		draws += RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
		prims += RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
	var wall := float(Time.get_ticks_usec() - w0) / 1000.0 / frames
	gpu.sort()
	var med := gpu[gpu.size() / 2]
	if report:
		print("LOOKSHOT %-52s frame %.3f ms  gpu median %s  draws %.0f  prims %.0f" % [label, wall,
			"%.3f ms" % med if med > 0.0 else "unavailable", draws / frames, prims / frames])
	return med


func _key(code: Key, down: bool) -> void:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.physical_keycode = code
	ev.pressed = down
	Input.parse_input_event(ev)


func _save(name: String) -> void:
	root.get_viewport().get_texture().get_image().save_png("res://.spike-out/%s.png" % name)
