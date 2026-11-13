extends SceneTree

## One trailer shot through the real app, frame by frame at a fixed step.
##
## trailer.py starts one Godot per shot. This script drives main.tscn with the XR session off:
## a spline camera, keyed tracks (colour scroll, ground zoom, subject pose, clock speed) and
## timed events that call the app's own systems (flame morphs, theme blends, IFS shape morphs,
## DIVE, GALAXY). Frames are read back from the root viewport and written raw into a FIFO that
## ffmpeg encodes, so frames that exist only to let the ground clipmap or the forest builds
## catch up are rendered and never recorded. Movie Maker records every drawn frame, which is
## why this does not use it.
##
## Args after --: shot list, shot index, fps, output directory, kind, sink.
##   kind "movie": every frame goes to the sink, a local TCP port where ffmpeg listens for
##   raw RGBA frames. (FileAccess cannot open a FIFO, and a socket needs no disk.)
##   kind "strip": the whole shot is simulated, and STRIP_N evenly spaced frames are saved as
##   PNGs under <output>/strips/, for judging motion without encoding.
const STRIP_N := 6
## Extra unrecorded frames allowed per recorded frame while the ground or forest catches up.
const SETTLE_MAX := 24

var main
var shot: Dictionary
var fps := 60
var out := ""
var kind := "movie"
var sink: StreamPeerTCP = null
var size := Vector2i.ZERO
var _events: Array = []
var _fired := 0
var _zoom_prev := 0.0
var _dive_v := 0.0
var _galaxy := {}
var _cam_keys: Array = []
var _cam_ease := Vector2(1, 1)
var _orbit: Dictionary = {}


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 6:
		_die("expected shot-list, shot index, fps, output directory, movie/strip, sink")
		return
	var document = JSON.parse_string(FileAccess.get_file_as_string(args[0]))
	if not document is Dictionary:
		_die("invalid shot list")
		return
	shot = document["shots"][int(args[1])]
	fps = int(args[2])
	out = args[3]
	kind = args[4]
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
	# Offline time has no relationship to the Quest frame budget. Focus gates input, drift and
	# the adaptive guard; the mode ticks still run, and the few focus-gated systems a shot
	# uses (DIVE, GALAXY) are driven from here.
	main._xr_focused = false
	if bool(shot.get("msaa", false)):
		root.msaa_3d = Viewport.MSAA_4X
	main.xr_origin.transform = Transform3D.IDENTITY
	main.xr_camera.near = float(shot.get("near", 0.02))
	main.xr_camera.far = float(shot.get("far", 400.0))
	_setup_camera()
	# Every mode places its subject from a standing head at the origin facing -z, so shot
	# coordinates are fixed whatever the first camera key is: flame centre (0, 1.45, -2.6),
	# bulb solid (0, 1.45, -0.7) about 0.35 m across, IFS (0, 1.42, -0.6) 0.32 m across or
	# centred on (0, 1.6, 0) at room size, tree trunk (0, 0, -5.5).
	main.xr_camera.transform = Transform3D(Basis(), Vector3(0, 1.6, 0))
	main._set_mode(String(shot["mode"]).to_lower())
	if not _configure():
		return
	_pose(0.0)
	_hide_ui()
	_events = shot.get("events", []).duplicate()
	_events.sort_custom(func(a, b): return float(a["at"]) < float(b["at"]))
	var warm_dt := float(shot.get("warmup_dt", 1.0 / fps))
	for i in int(shot.get("warmup_frames", 180)):
		_pose(0.0)
		_tick(warm_dt)
		await RenderingServer.frame_post_draw
		await process_frame
	var ready := false
	for i in 1800:
		ready = _settled(true)
		if ready:
			break
		_pose(0.0)
		_tick(1.0 / fps)
		await RenderingServer.frame_post_draw
		await process_frame
	if not ready or main.cloud.get_error() != "":
		_die("shot did not settle: %s" % main.cloud.get_error())
		return
	_after_settle()
	# A settled scene can still be easing in (a SOLID mesh grows in over 0.35 s): run on,
	# unrecorded, at the first pose.
	for i in roundi(float(shot.get("hold", 0.6)) * fps):
		_pose(0.0)
		_tick(1.0 / fps)
		await RenderingServer.frame_post_draw
		await process_frame
	size = root.get_texture().get_size()
	if kind == "movie":
		sink = StreamPeerTCP.new()
		if sink.connect_to_host("127.0.0.1", int(args[5])) != OK:
			_die("cannot connect to the encoder on port %s" % args[5])
			return
		for i in 500:
			sink.poll()
			if sink.get_status() != StreamPeerTCP.STATUS_CONNECTING:
				break
			OS.delay_msec(10)
		if sink.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			_die("encoder on port %s did not accept" % args[5])
			return
	else:
		DirAccess.make_dir_recursive_absolute(out.path_join("strips"))
	var frames := roundi(float(shot["duration"]) * fps)
	var strip_at := {}
	for k in STRIP_N:
		strip_at[roundi(float(k) * (frames - 1) / float(STRIP_N - 1))] = k
	var settles := 0
	for frame in frames:
		var t := float(frame) / fps
		_fire(t)
		_apply_tracks(t)
		_pose(t)
		_tick(_track("sim_speed", t, 1.0) / fps)
		await RenderingServer.frame_post_draw
		var extra := 0
		while extra < SETTLE_MAX and not _settled(false):
			extra += 1
			_settle_tick()
			await process_frame
			await RenderingServer.frame_post_draw
		settles += extra
		var img := root.get_texture().get_image()
		if img.get_size() != size:
			_die("frame size changed")
			return
		if kind == "movie":
			if img.get_format() != Image.FORMAT_RGBA8:
				img.convert(Image.FORMAT_RGBA8)
			if sink.put_data(img.get_data()) != OK:
				_die("encoder connection lost at frame %d" % frame)
				return
		elif strip_at.has(frame):
			var path := out.path_join("strips/%s_%d.png" % [shot["id"], strip_at[frame]])
			if img.save_png(path) != OK:
				_die("cannot save %s" % path)
				return
		if frame == frames / 2 and kind == "movie":
			img.save_jpg(out.path_join(String(shot["id"]) + ".jpg"), 0.9)
		if frame < frames - 1:
			await process_frame
	if sink != null:
		sink.disconnect_from_host()
	print("TRAILERSHOT PASS id=%s frames=%d size=%dx%d settle_frames=%d" % [
		shot["id"], frames, size.x, size.y, settles])
	quit()


# --- setup --------------------------------------------------------------------------------

func _configure() -> bool:
	var name := String(shot["preset"])
	var idx := -1
	match String(shot["mode"]).to_lower():
		"flame":
			idx = _flame_index(name)
			if idx >= 0:
				# Flame is the mode the app starts in, so _set_mode never recentred it.
				main._recenter()
				if shot.has("particles"):
					main.particle_idx = int(shot["particles"])
					main.cloud.set_count(int(main.TEX_SIZE * main.TEX_SIZE * main.PARTICLE_STEPS[main.particle_idx]))
				main._load_preset(idx)
				main.point_idx = int(shot.get("point_style", 3))
				main.bright_idx = int(shot.get("bright", main.bright_idx))
				main._apply_point_look()
				main._apply_exposure()
				if shot.has("flame_echoes"):
					main.flame_echoes.set_step(int(shot["flame_echoes"]))
		"bulb":
			var entries: Array = main.library.bulbs
			for i in entries.size():
				if String(entries[i]["name"]).nocasecmp_to(name) == 0:
					idx = i
			if idx >= 0:
				main.breath_idx = int(shot.get("breath", 2))
				main.surface_idx = int(shot.get("surface", 5))
				main._apply_surface()
				main._load_bulb(idx)
		"tree":
			idx = FractalTree.SHAPE_NAMES.find(name.to_lower())
			if idx >= 0:
				main.forest.succession = false
				main.forest.clear()
				main.tree.seed_value = int(shot.get("seed", 7))
				main._cycle_tree_shape(idx - main.tree_shape_idx)
				main._set_forest_wind(float(shot.get("wind", 0.3)))
				main._set_tree_bark(int(shot.get("bark", 1)))
				main._set_tree_floor(int(shot.get("floor", 0)))
				var layout := String(shot.get("layout", "hero"))
				if layout != "hero":
					main.forest.grove_seed = int(shot.get("seed", 7))
					main.forest.set_count(int(shot.get("count", 0)))
					main.forest.plant_mix = bool(shot.get("mix", true))
					if layout == "grove":
						main._sow_grove()
					else:
						main._sow_avenue(false)
		"ifs":
			for i in FractalIFS.PRESETS.size():
				if FractalIFS.preset_name(i).nocasecmp_to(name) == 0:
					idx = i
			if idx >= 0:
				main.ifs_preset_idx = idx
				main.ifs.ambient = bool(shot.get("evolve", false))
				main.ifs.set_preset(idx)
				main.ifs.detail = int(shot.get("detail", main.ifs.preset_detail()))
				main.ifs.depth = 1.0
				main.ifs.build(false)
				main.ifs.finish_grow()
				main.ifs_echoes.set_family(bool(shot.get("family", false)))
				main.ifs_echoes.set_step(int(shot.get("echoes", 0)))
				if bool(shot.get("room", false)):
					main._set_ifs_room(true)
				else:
					main._recenter()
				if bool(shot.get("dive", false)):
					main._set_ifs_dive(true)
		"ground":
			idx = FractalGround.FORMULA_NAMES.find(name.to_lower())
			if idx >= 0:
				main.orbit_on = false
				main.ground.set_formula(idx)
				main.ground_relief_idx = int(shot.get("relief", 0))
				main.ground_height_idx = int(shot.get("height", 0))
				main.ground_sky_idx = int(shot.get("ground_sky", 0))
				main.ground_hue = float(shot.get("hue", 0.0))
				main._apply_ground_look()
				if shot.has("iterations"):
					main.ground.auto_iter = false
					main.ground.set_max_iter(int(shot["iterations"]))
				if bool(shot.get("render_hq", false)):
					main._set_render_hq(true)
				main.ground.wpu = float(shot["ground_wpu"])
				var head: Vector3 = main.xr_camera.global_transform.origin
				main.ground.update(Vector2(head.x, head.z), 0.0)
				var centre: Array = shot["ground_centre"]
				main.ground.set_viewer_fractal(float(centre[0]), float(centre[1]))
				if shot.has("ground_turn"):
					main.ground.rotate_about_head(deg_to_rad(float(shot["ground_turn"])))
	if idx < 0:
		_die("unknown %s preset '%s'" % [shot["mode"], name])
		return false
	_apply_subject(0.0)
	main.theme_idx = int(shot.get("theme", -1))
	main._apply_palette()
	if shot.has("cycle"):
		main.cycle_idx = int(shot["cycle"])
	return true


## After the warm-up: things that must start from a settled scene.
func _after_settle() -> void:
	if String(shot["mode"]) == "BULB":
		if bool(shot.get("inside", false)):
			main._enter_inside()
		if shot.has("march_steps"):
			main.march.set_steps(int(shot["march_steps"]))
	if shot.has("galaxy_start"):
		var g: Dictionary = shot["galaxy_start"]
		_galaxy_begin(float(g.get("seconds", 0.0)))


func _flame_index(name: String) -> int:
	var entries: Array = main.library.presets
	for i in entries.size():
		if String(entries[i]["name"]).nocasecmp_to(name) == 0:
			return i
	return -1


func _settled(first: bool) -> bool:
	if main.ground_mode:
		return main.ground.progress() > 0.999
	if main.tree_mode:
		return main.forest.shapes_pending() == 0
	if main.ifs_mode:
		return true
	if not first:
		return true
	var ready: bool = main._converge <= 0 and not main.cloud.is_baking()
	if main.bulb_mode and main.SURFACE_SOLID[main.surface_idx] > 0:
		ready = ready and main.solid.is_ready()
	return ready


## A frame drawn only so queued work lands: no clocks advance.
func _settle_tick() -> void:
	var head: Vector3 = main.xr_camera.global_transform.origin
	if main.ground_mode:
		main.ground.update(Vector2(head.x, head.z), 0.0)
	elif main.tree_mode:
		main.forest.tick(0.0, head)
	_hide_ui()


# --- per frame ------------------------------------------------------------------------------

func _tick(dt: float) -> void:
	main._tick_cycle(dt)
	main._process_frame(dt)
	if main._palette_dirty:
		main._palette_dirty = false
		main._apply_palette()
	if main.ifs_mode and main.ifs_dive.on and _dive_v > 0.0:
		# _process_frame pauses the dive while unfocused; hold its eased speed here instead.
		main.ifs_dive._v = _dive_v
		main.ifs_dive.tick(dt, true, main.xr_camera.global_transform)
		_dive_v = main.ifs_dive._v
	if not _galaxy.is_empty():
		_galaxy["t"] = minf(1.0, float(_galaxy["t"]) + dt / float(_galaxy["s"]))
		var k: float = Morph.smoothstep_t(float(_galaxy["t"]))
		var a: Transform3D = _galaxy["from"]
		var b: Transform3D = _galaxy["to"]
		main.cloud.global_transform = Transform3D(
			a.basis.slerp(b.basis.orthonormalized(), k).scaled(Vector3.ONE * lerpf(a.basis.get_scale().x, b.basis.get_scale().x, k)),
			a.origin.lerp(b.origin, k))
	_hide_ui()


func _fire(t: float) -> void:
	while _fired < _events.size() and float(_events[_fired]["at"]) <= t + 0.5 / fps:
		var e: Dictionary = _events[_fired]
		_fired += 1
		match String(e["do"]):
			"theme":
				main._begin_theme_blend(float(e.get("seconds", 2.0)))
				main.theme_idx = int(e["theme"])
				main._palette_dirty = true
			"flame_morph":
				var i := _flame_index(String(e["preset"]))
				if i < 0:
					_die("unknown flame %s" % e["preset"])
				var steps: Array = main.MORPH_STEPS
				var want := float(e.get("seconds", 3.0))
				var best := 0
				for j in steps.size():
					if absf(float(steps[j]) - want) < absf(float(steps[best]) - want):
						best = j
				main.morph_idx = best
				main._morph_to_preset(i)
			"ifs_morph":
				var j := -1
				for i in FractalIFS.PRESETS.size():
					if FractalIFS.preset_name(i).nocasecmp_to(String(e["preset"])) == 0:
						j = i
				if j < 0:
					_die("unknown IFS %s" % e["preset"])
				main.ifs_preset_idx = j
				main.ifs.begin_morph(j)
				if main.ifs_echoes.family:
					main.ifs_echoes.relayout()
			"dive":
				if not main.ifs_dive.on:
					main._set_ifs_dive(true)
				_dive_v = 0.001
			"galaxy":
				_galaxy_begin(float(e.get("seconds", FlameGalaxy.TWEEN_S)))
			"cycle":
				main.cycle_idx = int(e["rung"])
			_:
				_die("unknown event %s" % e["do"])


func _galaxy_begin(seconds: float) -> void:
	main.bright_idx = maxi(main.bright_idx, main.BRIGHT_STEPS.find(FlameGalaxy.BRIGHT))
	main._apply_point_look()
	main.cloud.set_near_fade(FlameGalaxy.NEAR_FADE_M)
	var from: Transform3D = main.cloud.global_transform
	var to := FlameGalaxy.target(main.xr_camera.global_transform, from.basis,
		main.cloud.target_rms * main.cloud.target_fit)
	if shot.has("galaxy_rms"):
		var s := float(shot["galaxy_rms"]) / maxf(main.cloud.target_rms * main.cloud.target_fit, 0.05)
		to = Transform3D(from.basis.orthonormalized().scaled(Vector3.ONE * s), to.origin)
	if seconds <= 0.0:
		main.cloud.global_transform = to
		return
	_galaxy = {"from": from, "to": to, "t": 0.0, "s": seconds}


func _apply_tracks(t: float) -> void:
	var tracks: Dictionary = shot.get("tracks", {})
	if tracks.has("colour_cycle"):
		RenderingServer.global_shader_parameter_set(&"colour_cycle", fposmod(_track("colour_cycle", t, 0.0), 1.0))
	if tracks.has("ground_zoom") and main.ground_mode:
		var z := _track("ground_zoom", t, 0.0)
		main.ground.zoom(pow(2.0, z - _zoom_prev))
		_zoom_prev = z
	if tracks.has("ground_hue") and main.ground_mode:
		main.ground.set_look(&"colour_offset", _track("ground_hue", t, 0.0))
	if tracks.has("ifs_depth") and main.ifs_mode:
		main.ifs.depth = _track("ifs_depth", t, 1.0)
		main.ifs.build(false)
	if tracks.has("bulb_clock") and main._bulb != null:
		main._bulb.clock = _track("bulb_clock", t, 0.0)
	if tracks.has("subject_pos") or tracks.has("subject_scale") or tracks.has("subject_rot"):
		_apply_subject(t)


func _apply_subject(t: float) -> void:
	var subject: Dictionary = shot.get("subject", {})
	var tracks: Dictionary = shot.get("tracks", {})
	if subject.is_empty() and not (tracks.has("subject_pos") or tracks.has("subject_scale") or tracks.has("subject_rot")):
		return
	var pos: Vector3 = _vtrack("subject_pos", t, _vec(subject.get("position", [0, 0, 0])))
	var rot: Vector3 = _vtrack("subject_rot", t, _vec(subject.get("rotation", [0, 0, 0])))
	var s := _track("subject_scale", t, float(subject.get("scale", 1.0)))
	main.cloud.transform = Transform3D(Basis.from_euler(rot * PI / 180.0).scaled(Vector3.ONE * s), pos)


# --- camera ---------------------------------------------------------------------------------

func _setup_camera() -> void:
	var cam: Dictionary = shot["camera"]
	var easing: Array = cam.get("ease", [1.0, 1.0])
	_cam_ease = Vector2(float(easing[0]), float(easing[1]))
	if cam.has("orbit"):
		_orbit = cam["orbit"]
		return
	_cam_keys = cam["keys"]


func _pose(t: float) -> void:
	var pos: Vector3
	var aim: Vector3
	var fov := float(shot.get("fov", 50.0))
	var roll := 0.0
	var dur := float(shot["duration"])
	if not _orbit.is_empty():
		var u: float = _spline([[0.0, 0.0], [dur, 1.0]], t, _cam_ease)
		var o := _orbit
		var c := _vec(o["centre"])
		var ang := deg_to_rad(_lerp2(o["angle"], u))
		var r := _lerp2(o["radius"], u)
		var h := _lerp2(o["height"], u)
		pos = c + Vector3(sin(ang) * r, h, cos(ang) * r)
		aim = c + _vec(o.get("look_offset", [0, 0, 0]))
		if o.has("fov"):
			fov = _lerp2(o["fov"], u)
		if o.has("roll"):
			roll = _lerp2(o["roll"], u)
	else:
		var pk: Array = []
		var lk: Array = []
		var fk: Array = []
		var rk: Array = []
		for k in _cam_keys:
			var kt := float(k["t"])
			var still := bool(k.get("still", false))
			pk.append([kt, _vec(k["pos"]), still])
			lk.append([kt, _vec(k["look"]), still])
			fk.append([kt, float(k.get("fov", fov)), still])
			rk.append([kt, float(k.get("roll", 0.0)), still])
		pos = _spline(pk, t, _cam_ease)
		aim = _spline(lk, t, _cam_ease)
		fov = _spline(fk, t, _cam_ease)
		roll = _spline(rk, t, _cam_ease)
	main.xr_camera.fov = fov
	main.xr_camera.position = pos
	var up := Vector3.UP
	if absf((aim - pos).normalized().dot(up)) > 0.999:
		up = Vector3.FORWARD
	main.xr_camera.look_at(aim, up)
	if roll != 0.0:
		main.xr_camera.rotate_object_local(Vector3.FORWARD, deg_to_rad(roll))


## Cubic Hermite through [time, value] keys with Catmull-Rom tangents, so speed is continuous
## through every interior key. `ease` scales the end tangents: 1 starts and stops at rest, 0
## enters and leaves at the speed of the first and last segments. A key whose third element
## is true is passed at rest (a camera key's "still"), for a hold inside a move.
func _spline(keys: Array, t: float, easing: Vector2) -> Variant:
	var n := keys.size()
	if n == 1:
		return keys[0][1]
	if t <= float(keys[0][0]):
		return keys[0][1]
	if t >= float(keys[n - 1][0]):
		return keys[n - 1][1]
	var i := 0
	while i < n - 2 and t > float(keys[i + 1][0]):
		i += 1
	var t0 := float(keys[i][0])
	var t1 := float(keys[i + 1][0])
	var p0 = keys[i][1]
	var p1 = keys[i + 1][1]
	var h := t1 - t0
	var m0
	var m1
	if i == 0:
		m0 = (p1 - p0) / h * (1.0 - easing.x)
	else:
		m0 = (p1 - keys[i - 1][1]) / (t1 - float(keys[i - 1][0]))
	if i == n - 2:
		m1 = (p1 - p0) / h * (1.0 - easing.y)
	else:
		m1 = (keys[i + 2][1] - p0) / (float(keys[i + 2][0]) - t0)
	if _still(keys[i]):
		m0 = m0 * 0.0
	if _still(keys[i + 1]):
		m1 = m1 * 0.0
	var s := (t - t0) / h
	var s2 := s * s
	var s3 := s2 * s
	return p0 * (2 * s3 - 3 * s2 + 1) + m0 * (h * (s3 - 2 * s2 + s)) \
		+ p1 * (-2 * s3 + 3 * s2) + m1 * (h * (s3 - s2))


func _still(key: Array) -> bool:
	return key.size() > 2 and bool(key[2])


## A keyed scalar: {"keys": [[t, v], ...], "ease": [a, b]} or a bare key list (eased at rest).
func _track(name: String, t: float, fallback: float) -> float:
	var tracks: Dictionary = shot.get("tracks", {})
	if not tracks.has(name):
		return fallback
	var spec = tracks[name]
	var keys: Array = spec["keys"] if spec is Dictionary else spec
	var e: Array = spec.get("ease", [1.0, 1.0]) if spec is Dictionary else [1.0, 1.0]
	var fk: Array = []
	for k in keys:
		fk.append([float(k[0]), float(k[1])])
	return _spline(fk, t, Vector2(float(e[0]), float(e[1])))


func _vtrack(name: String, t: float, fallback: Vector3) -> Vector3:
	var tracks: Dictionary = shot.get("tracks", {})
	if not tracks.has(name):
		return fallback
	var spec = tracks[name]
	var keys: Array = spec["keys"] if spec is Dictionary else spec
	var e: Array = spec.get("ease", [1.0, 1.0]) if spec is Dictionary else [1.0, 1.0]
	var vk: Array = []
	for k in keys:
		vk.append([float(k[0]), _vec(k[1])])
	return _spline(vk, t, Vector2(float(e[0]), float(e[1])))


func _lerp2(v, u: float) -> float:
	if v is Array:
		return lerpf(float(v[0]), float(v[1]), u)
	return float(v)


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
	if sink != null:
		sink.disconnect_from_host()
	quit(1)
