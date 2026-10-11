extends SceneTree

## Temporal flicker of the FLAME through the real main scene. Each condition captures FRAMES
## consecutive frames to .spike-out/flicker/<name>/, and tools/flicker_metric.py scores them.
##
## Two kinds of change between frames read as flicker, and each condition turns one cause on
## or off against the default look:
##   - aliasing: the cloud frozen and the camera drifting a fraction of a pixel a frame, the
##     way a Quest head is never still. The drift is a frustum offset, which moves the whole
##     picture by exactly DRIFT pixels a frame with no parallax, so the metric can shift each
##     frame back exactly and score only what changed besides the motion;
##   - resampling: the chaos game moving particles (MOTION, a transition's stagger, the old
##     every-particle-every-frame update), with the camera still.
##
## The window is 1280x800 at a 48.7 degree vertical field of view: about 884 px per radian at
## the centre, the Quest 3 eye buffer's density at DETAIL 1.0 (1680x1760 per eye). Mono, so
## stereo is argued from these numbers, not measured. --cost times the point kernels instead.
##
##   tools/flame_flicker.sh            (every condition, the cost pass, then the metric)

const OUT := "res://.spike-out/flicker"
const FRAMES := 48
const FOV := 48.7
## About one degree a second at the Quest's ~15 px per degree, 72 frames a second. Not a whole
## number of pixels a frame, so every point's position inside its pixel keeps changing.
const DRIFT := Vector2(0.23, 0.16)
const COST_FRAMES := 150
const COST_ROUNDS := 3

## One preset per run, so every condition on it sees the same frozen cloud.
var preset := 0
## The transition partner, visited first so both framings are cached and a transition
## interpolates them instead of measuring on the way.
var partner := 1

var _cam: Camera3D
var _px_near := 0.0
var _exposure0 := 1.0
var _fails := 0
var _index: Array = []


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var only := ""
	for a in args:
		if a.begins_with("--preset="):
			preset = int(a.trim_prefix("--preset="))
		elif a.begins_with("--partner="):
			partner = int(a.trim_prefix("--partner="))
		elif a.begins_with("--only="):
			only = a.trim_prefix("--only=")
	# The cost pass alone: the .sh runs it under Vulkan, because on Metal neither the
	# viewport's GPU timer nor the RenderingDevice timestamps report anything on this Mac.
	var cost_only := "--cost" in args
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))

	var main = (load("res://main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	for i in 40:
		await process_frame
	main.help.close()
	main._drift = false
	main.spin = false
	_cam = main.xr_camera
	_cam.position = Vector3(0.0, 1.6, 0.0)
	_cam.rotation_degrees = Vector3.ZERO
	_cam.projection = Camera3D.PROJECTION_FRUSTUM
	_cam.size = 2.0 * _cam.near * tan(deg_to_rad(FOV) * 0.5)
	_cam.frustum_offset = Vector2.ZERO
	_px_near = _cam.size / root.get_viewport().get_visible_rect().size.y

	# Visit the partner first, then the preset, so both framings are cached.
	for p in [partner, preset]:
		main._load_preset(p)
		await _settled(main)
	main._recenter()
	for i in 10:
		await process_frame
	_exposure0 = main._env().tonemap_exposure
	print("FLICKER preset %s, partner %s, count %d, exposure %.3f, near-plane px %s m" % [
		main.library.name_at(preset), main.library.name_at(partner), main.cloud.get_count(),
		_exposure0, str(_px_near)])

	if cost_only:
		var vp := root.get_viewport().get_viewport_rid()
		RenderingServer.viewport_set_measure_render_time(vp, true)
		await _cost(main)
	else:
		for c: Dictionary in _conditions():
			# --only takes comma-separated name prefixes.
			if only != "" and not Array(only.split(",")).any(
					func(p: String): return (c["name"] as String).begins_with(p)):
				continue
			await _run(main, c)
		_write_index()
	print("FLICKER %s failures=%d dir=%s" % ["PASS" if _fails == 0 else "FAIL", _fails, OUT])
	quit(0 if _fails == 0 else 1)


## Every condition is the default look with one thing changed. The frozen ones come first so
## their stills are of the same particles: only the kernel differs between them.
func _conditions() -> Array:
	var legacy := {"kernel": 0}
	var area := {"kernel": 1, "aa": 0.5}
	return [
		# Still camera, frozen cloud: nothing may change at all. The noise floor.
		_c("s_frozen_new", area, {}),
		_c("s_frozen_legacy", legacy, {}),
		# Head drift, frozen cloud: aliasing alone.
		_c("d_frozen_legacy", legacy, {"drift": true}),
		_c("d_frozen_new", area, {"drift": true}),
		_c("d_frozen_aa0", {"kernel": 1, "aa": 0.0}, {"drift": true}),
		_c("d_frozen_aa1", {"kernel": 1, "aa": 1.0}, {"drift": true}),
		_c("d_frozen_legacy_px2", {"kernel": 0, "px": 2.0, "sharp": 4.0}, {"drift": true}),
		_c("d_frozen_new_px2", {"kernel": 1, "aa": 0.5, "px": 2.0, "sharp": 4.0}, {"drift": true}),
		# Candidates eliminated: the glow, MSAA, and the 10-bit buffer at a fifth of the energy
		# per point paid back in the tone map.
		_c("d_frozen_legacy_noglow", legacy, {"drift": true, "glow": false}),
		_c("d_frozen_new_noglow", area, {"drift": true, "glow": false}),
		_c("d_frozen_legacy_msaa4", legacy, {"drift": true, "msaa": Viewport.MSAA_4X}),
		_c("d_frozen_legacy_b001", legacy, {"drift": true, "bright": 0.01, "exp_mul": 5.0}),
		_c("d_frozen_new_b001", area, {"drift": true, "bright": 0.01, "exp_mul": 5.0}),
		# GALAXY: standing inside the flame, where the points are sparse and far, at its own
		# brightness.
		_c("g_frozen_legacy", legacy, {"drift": true, "galaxy": true, "bright": 0.12}),
		_c("g_frozen_new", area, {"drift": true, "galaxy": true, "bright": 0.12}),
		# Resampling, still camera. mod 1 is the old every-particle-every-frame update, which the
		# metric has to score far worse than frozen or it cannot see this at all.
		_c("s_mod1_legacy", legacy, {"mod": 1}),
		_c("s_mod1_new", area, {"mod": 1}),
		_c("s_mod4_legacy", legacy, {"mod": 4}),
		_c("s_mod16_legacy", legacy, {"mod": 16}),
		# A transition to the same genome: the transition's stagger with nothing moving.
		_c("s_selfmorph_legacy", legacy, {"morph": "self"}),
		_c("s_selfmorph_new", area, {"morph": "self"}),
		# Both at once: a drifting session mid-transition, with the head moving.
		_c("d_selfmorph_legacy", legacy, {"morph": "self", "drift": true}),
		_c("d_selfmorph_new", area, {"morph": "self", "drift": true}),
		# A real transition to the partner, sampled near its start, middle and end and as it
		# lands. The shape moves, so these score real motion too; compare them with each other
		# and across revisions, not with the frozen ones.
		_c("s_morph", area, {"morph": "phases"}),
		# Density: 2.5M points against the default 1.05M.
		_c("d_frozen_legacy_n060", legacy, {"drift": true, "count": 0.6}),
		_c("d_frozen_new_n060", area, {"drift": true, "count": 0.6}),
	]


func _c(name: String, look: Dictionary, rest: Dictionary) -> Dictionary:
	var c := {"name": name}
	c.merge(look)
	c.merge(rest)
	return c


func _run(main, c: Dictionary) -> void:
	_apply_look(main, c)
	var count0: int = main.cloud.get_count()
	if c.has("count"):
		main.cloud.set_count(int(main.TEX_SIZE * main.TEX_SIZE * float(c["count"])))
		# Grown while frozen, the new particles are still seeds; iterate them onto the flame.
		main._converge = main.CONVERGE_FRAMES
		await _settled(main)
	if c.get("galaxy", false):
		main._enter_galaxy()
		while main.galaxy.is_moving():
			await process_frame
		# Entering sets the app's own look (BRIGHT, the AA tile); put the condition's back.
		_apply_look(main, c)
	var mod: int = int(c.get("mod", 0))
	main.stability_idx = maxi(0, main.STABILITY.find(mod))
	var morph: String = c.get("morph", "")
	var drift: bool = c.get("drift", false)
	if morph == "phases":
		var steps: float = main.MORPH_STEPS[main.morph_idx]
		main._morph_to_preset(partner)
		for ph in [["start", 0.02], ["mid", 0.45], ["end", 0.87]]:
			while main._morph_t < float(ph[1]):
				await process_frame
			await _capture(main, "%s_%s" % [c["name"], ph[0]], c, drift)
		while main._morph_t < 1.0:
			await process_frame
		await _capture(main, "%s_land" % c["name"], c, drift)
		print("FLICKER %s: %.1f s transition" % [c["name"], steps])
	elif morph == "self":
		# Captured from the middle, where a transition moves the most particles per frame.
		main._morph_to_preset(main.preset_idx)
		while main._morph_t < 0.45:
			await process_frame
		await _capture(main, c["name"], c, drift)
	else:
		for i in 2 * maxi(mod, 6) + 8:
			await process_frame
		await _capture(main, c["name"], c, drift)

	# Put the default back for the next condition.
	if morph != "":
		while main._morph_t < 1.0 or main._converge > 0:
			await process_frame
		if morph == "phases":
			main._morph_to_preset(preset)
			while main._morph_t < 1.0 or main._converge > 0:
				await process_frame
		main.cloud.set_framing(main.cloud.target_center, main.cloud.target_fit)
	main.stability_idx = 0
	if c.has("count"):
		main.cloud.set_count(count0)
	if c.get("galaxy", false):
		main._recenter()   # leaves the galaxy and puts the flame back where it was
	_apply_look(main, {})
	for i in 4:
		await process_frame


func _capture(main, name: String, c: Dictionary, drift: bool) -> void:
	var dir := "%s/%s" % [OUT, name]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var vp := root.get_viewport().get_viewport_rid()
	var shifts: Array = []
	var mods: Array = []
	var reseeds: Array = []
	var morph_t: Array = []
	# Where the framing puts two fixed points of the flame on screen, frame by frame, less the
	# drift: anything left is the framing itself moving (ease toward a fresh measurement).
	var probe: Array = []
	var p0: Vector3 = main.cloud.target_center
	var p1: Vector3 = p0 + Vector3(main.cloud.target_rms, 0.0, 0.0)
	var lit_first := -1
	for t in FRAMES:
		var sh := DRIFT * float(t) if drift else Vector2.ZERO
		# Positive offset.x moves the window right, so the picture moves left; offset.y up
		# moves it down in image rows. Content shift in image pixels is (sh.x, sh.y).
		_cam.frustum_offset = Vector2(-sh.x, sh.y) * _px_near
		await process_frame
		var img := root.get_viewport().get_texture().get_image()
		img.save_png("%s/f%03d.png" % [dir, t])
		shifts.append([sh.x, sh.y])
		var src = main.cloud.source
		# Slabs moved this frame over the slab count: "1/4" is a quarter, "4/24" a sixth.
		var slabs: int = src.slabs_per_frame if "slabs_per_frame" in src else 1
		mods.append("%d/%d" % [slabs, src.update_mod] if src != null else "-")
		reseeds.append(src.reseed_prob if src != null else -1.0)
		morph_t.append(snappedf(main._morph_t, 0.001))
		var g: Transform3D = main.cloud.global_transform
		var a := _cam.unproject_position(g * ((p0 - main.cloud.center) * main.cloud.fit)) - sh
		var b := _cam.unproject_position(g * ((p1 - main.cloud.center) * main.cloud.fit)) - sh
		probe.append([a.x, a.y, b.x, b.y])
		if t == 0:
			lit_first = _lit(img)
	_cam.frustum_offset = Vector2.ZERO
	var wobble := 0.0
	for q in probe:
		for k in 4:
			wobble = maxf(wobble, absf(float(q[k]) - float(probe[0][k])))
	var meta := {
		"name": name, "frames": FRAMES, "drift": [DRIFT.x, DRIFT.y] if drift else [0.0, 0.0],
		"shifts": shifts, "settings": c, "preset": main.library.name_at(main.preset_idx),
		"count": main.cloud.get_count(), "update_mods": mods, "reseed": reseeds,
		"morph_t": morph_t, "framing_px": wobble, "fov": FOV,
		"brightness": main.cloud.point_material().get_shader_parameter("brightness"),
		"energy_gain": main.cloud.point_material().get_shader_parameter("energy_gain"),
		"point_kernel": main.cloud.point_material().get_shader_parameter("point_kernel"),
		"aa_width": main.cloud.point_material().get_shader_parameter("aa_width"),
		"exposure": main._env().tonemap_exposure, "glow": main._env().glow_enabled,
	}
	var f := FileAccess.open("%s/meta.json" % dir, FileAccess.WRITE)
	f.store_string(JSON.stringify(meta, "  "))
	f.close()
	_index.append(name)
	_ok(name, lit_first > 2000, "lit %d at frame 0, slabs %s, morph t %.2f-%.2f, framing moved %.2f px" % [
		lit_first, str(mods.slice(0, 8)), float(morph_t[0]), float(morph_t[-1]), wobble])


## The default look with the condition's changes on top. An empty dictionary is the default.
func _apply_look(main, c: Dictionary) -> void:
	var cloud = main.cloud
	cloud.set_point_kernel(int(c.get("kernel", 1)))
	cloud.set_aa_width(float(c.get("aa", main.AA_STEPS[0])))
	cloud.set_point_size(float(c.get("px", main.POINT_STEPS[0])))
	cloud.set_sharpness(float(c.get("sharp", main.SHARPNESS[0])))
	cloud.set_brightness(float(c.get("bright", main.BRIGHT_STEPS[2])))
	main._env().tonemap_exposure = _exposure0 * float(c.get("exp_mul", 1.0))
	main._env().glow_enabled = bool(c.get("glow", true))
	root.get_viewport().msaa_3d = int(c.get("msaa", Viewport.MSAA_DISABLED))


## Load or converge, then frozen with the framing cached. The framing eases toward its last
## measurement for a second or two after that (ParticleCloud.ease_framing), which moves the
## whole picture by a pixel or so. Snapped here, so a still camera means a still picture; the
## transition captures measure that motion instead (framing_px).
func _settled(main) -> void:
	for i in 4:
		await process_frame
	var n := 0
	while (main._converge > 0 or main._morph_t < 1.0 or main._pending_cache >= 0) and n < 3000:
		await process_frame
		n += 1
	main.cloud.set_framing(main.cloud.target_center, main.cloud.target_fit)
	for i in 8:
		await process_frame


## GPU draw time per point kernel, frozen and still, alternated so drift in the Mac's clocks
## lands on every kernel alike. Ratios, not milliseconds: the Quest is a different tiler.
func _cost(main) -> void:
	var kernels := [
		["legacy", {"kernel": 0}],
		["area 0.5", {"kernel": 1, "aa": 0.5}],
		["area 0", {"kernel": 1, "aa": 0.0}],
		["area 1", {"kernel": 1, "aa": 1.0}],
	]
	var vp := root.get_viewport().get_viewport_rid()
	var sums := {}
	for k in kernels:
		sums[k[0]] = []
	for r in COST_ROUNDS:
		for k in kernels:
			_apply_look(main, k[1])
			for i in 20:
				await process_frame
			var g := 0.0
			for i in COST_FRAMES:
				await process_frame
				g += RenderingServer.viewport_get_measured_render_time_gpu(vp)
			(sums[k[0]] as Array).append(g / COST_FRAMES)
	_apply_look(main, {})
	for k in kernels:
		var a: Array = sums[k[0]]
		print("FLICKER cost %-9s draw-gpu %s ms (rounds %s), %d points, 1280x800 mono" % [
			k[0], "%.3f" % (a.reduce(func(s, x): return s + x, 0.0) / a.size()),
			str(a.map(func(x): return snappedf(x, 0.001))), main.cloud.get_count()])


func _write_index() -> void:
	var f := FileAccess.open("%s/index.json" % OUT, FileAccess.WRITE)
	f.store_string(JSON.stringify({"conditions": _index, "drift": [DRIFT.x, DRIFT.y],
		"frames": FRAMES, "fov": FOV}, "  "))
	f.close()


func _lit(img: Image) -> int:
	var n := 0
	for y in range(0, img.get_height(), 2):
		for x in range(0, img.get_width(), 2):
			var c := img.get_pixel(x, y)
			if maxf(c.r, maxf(c.g, c.b)) > 0.05:
				n += 1
	return n


func _ok(name: String, pass_: bool, detail: String) -> void:
	if not pass_:
		_fails += 1
	print("FLICKER %-26s %s  %s" % [name, "PASS" if pass_ else "FAIL", detail])
