extends SceneTree

## One shot through the real app. Movie Maker records startup too; trailer.py trims
## exactly the final N frames, after convergence, clipmap fill and mesh construction.
var main
var shot: Dictionary
var fps := 60
var still := false
var out := ""


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 5:
		_die("expected shot-list, shot index, fps, output directory, still/movie")
		return
	var document = JSON.parse_string(FileAccess.get_file_as_string(args[0]))
	if not document is Dictionary:
		_die("invalid shot list")
		return
	shot = document["shots"][int(args[1])]
	fps = int(args[2])
	out = args[3]
	still = args[4] == "still"
	seed(int(shot.get("seed", 7)))
	main = (load("res://main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	for i in 600:
		await process_frame
		if main._setup_done:
			break
	if not main._setup_done:
		_die("GPU setup did not finish")
		return
	main.set_process(false)
	main.set_process_input(false)
	main.set_process_unhandled_input(false)
	main._placed = true
	main._help_pending = false
	main.resume_on = false
	main.spin = false
	main._drift = false
	# Offline time has no relationship to Quest frame budget. Focus gates input and
	# the adaptive guard, while the real mode tick still drives geometry and compute.
	main._xr_focused = false
	main.xr_origin.transform = Transform3D.IDENTITY
	main.xr_camera.position = Vector3(0, 1.6, 0)
	main.xr_camera.rotation = Vector3.ZERO
	main.xr_camera.fov = float(shot["fov"])
	main.xr_camera.near = 0.02
	main.xr_camera.far = 250.0
	main._set_mode(String(shot["mode"]).to_lower())
	if not _configure():
		return
	_hide_ui()
	_pose(0.5 if still else 0.0)
	for i in int(shot.get("warmup_frames", 180)):
		_tick()
		await RenderingServer.frame_post_draw
		await process_frame
	# Convergence alone does not prove a complete ground or splat bake.
	var ready := false
	for i in 1800:
		ready = main._converge <= 0 and not main.cloud.is_baking()
		if main.ground_mode:
			ready = main.ground.progress() > 0.999
		if main.bulb_mode and main.SURFACE_SOLID[main.surface_idx] > 0:
			ready = ready and main.solid.is_ready()
		if main.tree_mode or main.ifs_mode:
			ready = true
		if ready:
			break
		_tick()
		await RenderingServer.frame_post_draw
		await process_frame
	if not ready or main.cloud.get_error() != "":
		_die("shot did not settle: %s" % main.cloud.get_error())
		return
	if String(shot["mode"]) == "FLAME":
		main.point_idx = int(shot.get("point_style", 0))
		main._apply_point_look()
	var frames := 1 if still else roundi(float(shot["duration"]) * fps)
	for frame in frames:
		var t := 0.5 if still else float(frame) / maxf(1.0, frames - 1)
		_pose(t)
		_tick()
		_animate(t)
		await RenderingServer.frame_post_draw
		if frame == frames / 2:
			var img := root.get_texture().get_image()
			if img.save_png(out.path_join(String(shot["id"]) + ".png")) != OK:
				_die("cannot save contact frame")
				return
		if frame < frames - 1:
			await process_frame
	print("TRAILERSHOT PASS id=%s frames=%d size=%s" % [shot["id"], frames, root.size])
	# Quit after post_draw so the last frame is the last Movie Maker frame, with no
	# teardown image. trailer.py checks the decoded frame count after trimming.
	quit()


func _configure() -> bool:
	var name := String(shot["preset"])
	var idx := -1
	match String(shot["mode"]).to_lower():
		"flame", "bulb":
			var entries: Array = main.library.bulbs if main.bulb_mode else main.library.presets
			for i in entries.size():
				if String(entries[i]["name"]).nocasecmp_to(name) == 0:
					idx = i
			if idx >= 0:
				if main.bulb_mode:
					main.breath_idx = 2
					main.surface_idx = int(shot.get("surface", 1))
					main._apply_surface()
					main._load_bulb(idx)
				else:
					main._load_preset(idx)
		"tree":
			idx = FractalTree.SHAPE_NAMES.find(name.to_lower())
			if idx >= 0:
				main.forest.succession = false
				main.forest.clear()
				main.tree.seed_value = int(shot.get("seed", 7))
				main._cycle_tree_shape(idx - main.tree_shape_idx)
				main.tree.grow_t = main.tree.grow_s + 3.0
				main.tree.set_wind(float(shot.get("wind", 0.12)))
				main._set_tree_bark(int(shot.get("bark", 1)))
		"ifs":
			for i in FractalIFS.PRESETS.size():
				if FractalIFS.preset_name(i).nocasecmp_to(name) == 0:
					idx = i
			if idx >= 0:
				main.ifs.ambient = bool(shot.get("ambient", false))
				main.ifs.set_preset(idx)
				main.ifs.detail = int(shot.get("detail", main.ifs.preset_detail()))
				main.ifs.build(false)
				main.ifs.finish_grow()
				main.ifs_echoes.set_step(int(shot.get("echoes", 0)))
		"ground":
			idx = FractalGround.FORMULA_NAMES.find(name.to_lower())
			if idx >= 0:
				main.orbit_on = false
				main.ground.set_formula(idx)
				var centre: Array = shot["ground_centre"]
				main.ground.set_viewer_fractal(float(centre[0]), float(centre[1]))
				main.ground.wpu = float(shot["ground_wpu"])
	if idx < 0:
		_die("unknown %s preset '%s'" % [shot["mode"], name])
		return false
	var subject: Dictionary = shot.get("subject", {})
	main.cloud.transform = Transform3D(Basis.from_euler(_vec(subject.get("rotation", [0, 0, 0])) * PI / 180.0)
		.scaled(Vector3.ONE * float(subject.get("scale", 1.0))), _vec(subject.get("position", [0, 0, 0])))
	main.theme_idx = int(shot.get("theme", -1))
	main._apply_palette()
	return true


func _pose(t: float) -> void:
	var a: Dictionary = shot["camera_start"]
	var b: Dictionary = shot["camera_end"]
	main.xr_camera.position = _vec(a["position"]).lerp(_vec(b["position"]), t)
	var aim := _vec(a["look_at"]).lerp(_vec(b["look_at"]), t)
	main.xr_camera.look_at(aim, Vector3.UP)


func _tick() -> void:
	main._process_frame(1.0 / fps)
	_hide_ui()


func _animate(t: float) -> void:
	var animation: Dictionary = shot.get("animation", {})
	if animation.has("colour_cycle"):
		var v: Array = animation["colour_cycle"]
		RenderingServer.global_shader_parameter_set("colour_cycle", lerpf(float(v[0]), float(v[1]), t))
	if animation.has("ifs_depth"):
		var v: Array = animation["ifs_depth"]
		main.ifs.depth = lerpf(float(v[0]), float(v[1]), t)
		main.ifs.build(false)


func _hide_ui() -> void:
	main.help.close()
	main.menu.visible = false
	main.hud.visible = false
	main.left_hand.visible = false
	main.right_hand.visible = false
	main.ifs_edit.visible = false
	main.plant_marker.visible = false
	main.orbit.visible = false
	main.vignette.visible = false


func _vec(a: Array) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2]))


func _die(message: String) -> void:
	push_error("TRAILERSHOT FAIL " + message)
	quit(1)
