extends SceneTree

## CYCLE through the real main scene (T-55). Three parts.
##
## The clock. The scroll advances at the rung's rate; off glides it home the short way and lands
## on exactly 0, so every shader takes its off branch; the themes rung starts its first
## twenty-second cross-fade at once.
##
## The strips. In every mode, the same view at six points round one cycle, side by side in
## .spike-out/cycle/<mode>.png. A mode passes only if a quarter cycle changes the picture several
## times more than the scene's own motion does over the same frames with the phase held. It also
## reports how far a phase just short of a whole cycle lands from phase 0 (the wrap), and the
## mean luma at each phase: CYCLE moves hue and keeps brightness, so that should barely move.
##
## The control. The flame again with its points shader swapped for a copy whose colour_cycle is
## a constant 0: the strip check must fail on it, or the passes above prove nothing. It has to be
## a render, not a compile: this renderer compiles a global nobody registered without a word
## (and the headless shader_check accepts any name at all), so a typo'd global fails silently.
##
## Cost. With `-- cost` (the .sh runs it under Vulkan, because on Metal this Mac reports no GPU
## time) each strip is replaced by GPU draw time with CYCLE off and at medium, alternated over
## five rounds. In the plain run, TREE also times the script with the themes rung's cross-fade
## running, since that recolours every near tree every frame for twenty seconds.
##
##   tools/cycle_shot.sh

const OUT := "res://.spike-out/cycle/"
const PHASES := [0.0, 1.0 / 6.0, 2.0 / 6.0, 3.0 / 6.0, 4.0 / 6.0, 5.0 / 6.0]
const THUMB := Vector2i(400, 250)
## A quarter cycle must move the picture this many times more than the held phase's own motion.
const RATIO_MIN := 4.0

var main: Node
var fails := 0
var cost := false


func _init() -> void:
	cost = OS.get_cmdline_user_args().has("cost")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	main = (load("res://main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	for i in 40:
		await process_frame
	main.help.close()
	main.spin = false
	main._drift = false
	main.xr_camera.position = Vector3(0.0, 1.6, 0.0)
	main.xr_camera.rotation_degrees = Vector3.ZERO
	for i in 3:
		await process_frame

	if not cost:
		await _clock()
	# A table-sized thing at arm's length is small at the default field; the strips want detail.
	var wide: float = main.xr_camera.fov
	main.xr_camera.fov = 40.0

	# --- FLAME ---------------------------------------------------------------------------------
	var n := 0
	while (main._converge > 0 or main._morph_t < 1.0) and n < 3000:
		await process_frame
		n += 1
	main.cloud.set_framing(main.cloud.target_center, main.cloud.target_fit)
	await _strip("flame")
	await _control()

	# --- BULB: splats, LINES, SOLID ------------------------------------------------------------
	main._set_mode("bulb")
	main.spin = false
	main._drift = false
	main.breath_idx = main.BREATH_STEPS.find(0.0)
	await _bulb_settle()
	main.xr_camera.look_at(main.cloud.global_transform.origin, Vector3.UP)
	await _strip("bulb_splats")
	main.line_idx = main.LINE_SLICES.find(48)
	main.cloud.request_seed()
	main._load_bulb(main.bulb_idx)
	await _bulb_settle()
	await _strip("bulb_lines")
	main.line_idx = 0
	main.cloud.request_seed()
	main._load_bulb(main.bulb_idx)
	await _bulb_settle()
	main.surface_idx = main.SURFACE_SOLID.find(192)
	main._apply_surface()
	n = 0
	while not main.solid.is_ready() and n < 4000:
		await process_frame
		n += 1
		if main.solid.get_error() != "":
			break
	if main.solid.is_ready():
		for i in 90:   # the grow-in
			await process_frame
		# Closer than the toy's home, so the surface fills enough of the frame to judge.
		main.xr_camera.look_at(main.cloud.global_transform.origin, Vector3.UP)
		var fov0: float = main.xr_camera.fov
		main.xr_camera.fov = 22.0
		await _strip("bulb_solid")
		main.xr_camera.fov = fov0
	else:
		_ok("bulb_solid", false, "SOLID never built: %s" % main.solid.get_error())
	# The marched surface, the other per-pixel ramp.
	main.surface_idx = main.SURFACE_STEPS.find(48)
	main._apply_surface()
	for i in 60:
		await process_frame
	main.xr_camera.look_at(main.cloud.global_transform.origin, Vector3.UP)
	await _strip("bulb_march")
	main.surface_idx = 0
	main._apply_surface()

	main.xr_camera.fov = wide
	# --- GROUND --------------------------------------------------------------------------------
	main.xr_camera.rotation_degrees = Vector3(-22.0, 0.0, 0.0)
	main._set_mode("ground")
	# Home stands inside the set, near-black; ground_shot's spot over the cardioid has bands.
	main.ground.centre = Vector2(-0.55, 0.62)
	for i in 240:
		await process_frame
	await _strip("ground")

	# --- TREE: the avenue, grown, from where you stand -----------------------------------------
	main.xr_camera.rotation_degrees = Vector3(-3.0, 0.0, 0.0)
	main.forest.grove_seed = 4321
	main._set_mode("tree")
	for i in 3:
		await process_frame
	main._sow_avenue(false)
	# Wind off: the sway is the scene's own motion, and the check weighs the colour against it.
	main.tree_wind_idx = main.TREE_WIND.find(0.0)
	main._set_forest_wind(0.0)
	Engine.time_scale = 4.0
	n = 0
	while n < 6000 and _grown(main.forest) < 1.0:
		await process_frame
		n += 1
	Engine.time_scale = 1.0
	for i in 30:
		await process_frame
	await _strip("tree")
	if not cost:
		await _theme_walk_cost()

	# --- IFS -----------------------------------------------------------------------------------
	main.xr_camera.rotation_degrees = Vector3.ZERO
	main._set_mode("ifs")
	# MOTION off for the same reason; the IFS's own slow colour scroll still runs under it.
	if main.ifs.ambient:
		main._toggle_ifs_motion()
	# Seconds, not frames: the grow-in is timed, and 240 frames on a quiet Mac was still inside it.
	await _wait_s(4.0)
	await _strip("ifs")

	if not cost:
		await _menu_shots()
	main.cycle_idx = 0
	main._cycle = 0.0
	print("CYCLESHOT %s failures=%d dir=%s" % ["PASS" if fails == 0 else "FAIL", fails,
		ProjectSettings.globalize_path(OUT)])
	quit(0 if fails == 0 else 1)


## The clock, as the menu drives it.
func _clock() -> void:
	# Slow: the phase after a measured stretch of frames is that time over 120 s.
	main._step_cycle(1)
	main._cycle = 0.0
	var t := 0.0
	for i in 120:
		await process_frame
		t += get_root().get_process_delta_time()
	var want := fposmod(t / float(main.CYCLE_STEPS[1]), 1.0)
	var got: float = main._cycle
	_ok("clock slow", main._cycle_label() == "slow · 120s" and absf(got - want) < 0.002,
		"tile '%s', %.3f s gave %.5f cycles, want %.5f" % [main._cycle_label(), t, got, want])
	# Off from 0.9: home the short way (up through 1.0, never down through 0.5), and exactly 0.
	main._step_cycle(-1)
	main._cycle = 0.9
	Engine.time_scale = 4.0
	var short_way := true
	var frames := 0
	t = 0.0
	while main._cycle != 0.0 and frames < 3000:
		await process_frame
		t += get_root().get_process_delta_time()
		frames += 1
		if main._cycle != 0.0 and main._cycle < 0.85:
			short_way = false
	Engine.time_scale = 1.0
	# global_shader_parameter_get returns null outside the editor, so the proof the 0 went out
	# is the value main last sent.
	_ok("clock off", main._cycle == 0.0 and main._cycle_sent == 0.0 and short_way
		and main._cycle_label() == "off",
		"0.9 came home in %.1f game s, the short way %s, sent %s" % [t, str(short_way),
		str(main._cycle_sent)])
	# Themes: a cross-fade to another theme starts on the first frame, over CYCLE_THEME_BLEND_S.
	var theme0: int = main.theme_idx
	main._step_cycle(-1)
	await process_frame
	await process_frame
	_ok("clock themes", main.cycle_idx == main.CYCLE_THEMES_RUNG and main.theme_idx != theme0
		and main._theme_blend < 1.0 and main._theme_blend_s == main.CYCLE_THEME_BLEND_S,
		"tile '%s', theme %d -> %d, blend %.3f over %.0f s" % [main._cycle_label(), theme0,
		main.theme_idx, main._theme_blend, main._theme_blend_s])
	# Back to off and the preset palette, settled, for the strips.
	main._step_cycle(1)
	main._cycle = 0.0
	main.theme_idx = theme0
	main._theme_blend = 1.0
	main._apply_palette()
	await process_frame


## Six phases of one cycle, one strip. Slow is on so the phase is set by hand each frame (the
## tick moves it 1/7200 of a cycle a frame, too little to matter); the shaders read it live.
func _strip(mode: String) -> void:
	if cost:
		await _gpu(mode)
		return
	var m := await _measure()
	main.cycle_idx = 1
	var frames: Array[Image] = []
	var lumas: Array = []
	for ph in PHASES:
		var img := await _at(ph)
		frames.append(img)
		lumas.append(snappedf(_luma(img), 0.001))
	var strip := Image.create(THUMB.x * PHASES.size(), THUMB.y, false, Image.FORMAT_RGB8)
	for i in frames.size():
		strip.blit_rect(frames[i], Rect2i(Vector2i.ZERO, THUMB), Vector2i(i * THUMB.x, 0))
	strip.save_png(OUT + mode + ".png")
	main.cycle_idx = 0
	main._cycle = 0.0
	await process_frame
	_ok(mode, _moved(m), "quarter cycle %.4f against held %.4f (x%.1f), mean colour %.4f against %.4f, wrap %.4f, luma change %.4f, luma by phase %s" % [
		m.turn, m.motion, m.turn / maxf(m.motion, 1e-6), m.turn_mean, m.motion_mean, m.seam,
		m.dluma, str(lumas)])


## Phase 0, a quarter, 0 again, just short of 1: four frames apart each. The held pair spans the
## quarter's frames twice over, so the scene's own motion is counted against the colour in full.
func _measure() -> Dictionary:
	main.cycle_idx = 1
	var a := await _at(0.0)
	var b := await _at(0.25)
	var c := await _at(0.0)
	var w := await _at(0.997)
	main.cycle_idx = 0
	main._cycle = 0.0
	await process_frame
	return {"turn": _diff(a, b), "motion": _diff(a, c), "seam": _diff(a, w),
		"dluma": absf(_luma(a) - _luma(b)),
		"turn_mean": _mean_rgb(a).distance_to(_mean_rgb(b)),
		"motion_mean": _mean_rgb(a).distance_to(_mean_rgb(c))}


## Per pixel, or for a subject that sparkles frame to frame on its own (the marched surface), by
## its mean colour, where the sparkle averages out and a palette turn does not.
func _moved(m: Dictionary) -> bool:
	return (m.turn > RATIO_MIN * m.motion and m.turn > 0.004) \
		or (m.turn_mean > RATIO_MIN * m.motion_mean and m.turn_mean > 0.004)


## GPU draw ms, CYCLE off against medium, alternated over five rounds so the Mac's clock drift
## and whatever else shares its GPU land on both. Min and median per side: a round another
## process lands in reads double, and a mean of three carried that straight into the verdict.
func _gpu(mode: String) -> void:
	var vp := root.get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(vp, true)
	var sums := {"off": [], "on": []}
	for r in 5:
		for k in ["off", "on"]:
			main.cycle_idx = 0 if k == "off" else 2
			main._cycle = 0.0 if k == "off" else 0.3
			for i in 20:
				await process_frame
			var g := 0.0
			for i in 120:
				await process_frame
				g += RenderingServer.viewport_get_measured_render_time_gpu(vp)
			(sums[k] as Array).append(g / 120.0)
	main.cycle_idx = 0
	main._cycle = 0.0
	var off: Array = sums["off"]
	var on: Array = sums["on"]
	off.sort()
	on.sort()
	_ok("cost " + mode, off[0] > 0.0, "draw-gpu off min %.3f med %.3f ms, cycling min %.3f med %.3f ms (min %+.1f%%, med %+.1f%%)" % [
		off[0], off[2], on[0], on[2], 100.0 * (on[0] - off[0]) / off[0], 100.0 * (on[2] - off[2]) / off[2]])


## Script time per frame in TREE, CYCLE off against the themes rung mid cross-fade.
func _theme_walk_cost() -> void:
	var theme0: int = main.theme_idx
	var off := await _proc_ms(180)
	main._step_cycle(-1)   # off -> the themes rung: the cross-fade starts on the next frame
	await process_frame
	var blending: bool = main._theme_blend < 1.0
	var on := await _proc_ms(180)
	blending = blending and main._theme_blend < 1.0
	main._step_cycle(1)
	main._cycle = 0.0
	# Back on the theme the strips started in, at once, so the IFS strip is the same every run.
	main.theme_idx = theme0
	main._theme_blend = 1.0
	main._apply_palette()
	_ok("walk cost", blending, "TREE script %.3f ms a frame off, %.3f ms with the theme cross-fade running (%d trees)" % [
		off, on, main.forest.tree_count()])


func _wait_s(secs: float) -> void:
	var t := 0.0
	while t < secs:
		await process_frame
		t += root.get_process_delta_time()


func _proc_ms(frames: int) -> float:
	main._proc_us_sum = 0
	main._proc_frames = 0
	for i in frames:
		await process_frame
	return float(main._proc_us_sum) / maxf(1.0, main._proc_frames) / 1000.0


## The COLOUR card with CYCLE on its two longest readouts, for the eye: menu_shot only ever
## draws it off. The themes rung is set directly, so its walk does not fire under the shot.
func _menu_shots() -> void:
	var menu = main.menu
	var key := ""
	for k in menu.debug_level_keys():
		if str(k).contains("colour"):
			key = k
	if key == "":
		_ok("menu", false, "no colour card among %s" % str(menu.debug_level_keys()))
		return
	for rung in [2, main.CYCLE_THEMES_RUNG]:
		main.cycle_idx = rung
		main._cycle_theme_t = 0.0
		menu.debug_level("")
		await _settle_menu(menu)
		menu.debug_level(key)
		await _settle_menu(menu)
		menu.debug_force(1.0, -1)
		await _settle_menu(menu)
		var img: Image = menu.debug_composite()
		img.save_png(OUT + "menu_colour_%s.png" % main.CYCLE_NAMES[rung])
		_ok("menu " + main.CYCLE_NAMES[rung], img.get_width() > 0, "COLOUR card with CYCLE reading '%s'" %
			main._cycle_label())
	main.cycle_idx = 0
	main._cycle = 0.0
	menu.debug_level("")


func _settle_menu(menu) -> void:
	for i in 4:
		await process_frame
	menu._sync_back()
	for i in 3:
		await process_frame


## The flame with colour_cycle a constant: the same check has to fail.
func _control() -> void:
	if cost:
		return
	var mat: ShaderMaterial = main.cloud.point_material()
	var real: Shader = mat.shader
	var dead := Shader.new()
	dead.code = real.code.replace("global uniform float colour_cycle;", "const float colour_cycle = 0.0;")
	var swapped := dead.code != real.code
	mat.shader = dead
	var m := await _measure()
	mat.shader = real
	for i in 4:
		await process_frame
	var after := await _measure()
	_ok("control", swapped and not _moved(m) and _moved(after),
		"cycle wired out: quarter %.4f against held %.4f, check says %s; wired back: %s" % [
		m.turn, m.motion, "moved" if _moved(m) else "still", "moved" if _moved(after) else "still"])


func _at(ph: float) -> Image:
	for i in 4:
		main._cycle = ph
		await process_frame
	var img := root.get_viewport().get_texture().get_image()
	img.convert(Image.FORMAT_RGB8)
	img.resize(THUMB.x, THUMB.y, Image.INTERPOLATE_BILINEAR)
	return img


## Mean absolute difference per channel, 0..1, over the pixels lit in either frame: a small
## subject on black is judged on itself, not diluted by the empty frame round it.
func _diff(a: Image, b: Image) -> float:
	var s := 0.0
	var n := 0
	for y in THUMB.y:
		for x in THUMB.x:
			var p := a.get_pixel(x, y)
			var q := b.get_pixel(x, y)
			if maxf(maxf(p.r, p.g), maxf(maxf(p.b, q.r), maxf(q.g, q.b))) < 4.0 / 255.0:
				continue
			s += absf(p.r - q.r) + absf(p.g - q.g) + absf(p.b - q.b)
			n += 1
	return s / (3.0 * maxi(n, 1))


## Mean colour over the lit pixels.
func _mean_rgb(a: Image) -> Vector3:
	var s := Vector3.ZERO
	var n := 0
	for y in THUMB.y:
		for x in THUMB.x:
			var p := a.get_pixel(x, y)
			if maxf(p.r, maxf(p.g, p.b)) < 4.0 / 255.0:
				continue
			s += Vector3(p.r, p.g, p.b)
			n += 1
	return s / maxf(1.0, n)


func _luma(a: Image) -> float:
	var s := 0.0
	for y in THUMB.y:
		for x in THUMB.x:
			var p := a.get_pixel(x, y)
			s += 0.2126 * p.r + 0.7152 * p.g + 0.0722 * p.b
	return s / (THUMB.x * THUMB.y)


func _bulb_settle() -> void:
	var cloud: ParticleCloud = main.cloud
	var f := 0
	while main._bulb_settle > 0 and f < 900:
		await process_frame
		f += 1
	var gen: int = cloud._bake_gen
	while (cloud._bake_gen == gen or cloud.is_baking() or not cloud.bake_ready) and f < 1800:
		await process_frame
		f += 1
	while (absf(cloud.fit - cloud.target_fit) > 0.002 * cloud.target_fit
			or cloud.center.distance_to(cloud.target_center) > 0.002) and f < 2400:
		await process_frame
		f += 1


func _grown(forest: Forest) -> float:
	var trees: Array = forest.trees()
	if trees.is_empty():
		return 0.0
	var g := 0
	for t in trees:
		if t.built and t.grow_t >= t.grow_s + 1.0:
			g += 1
	return float(g) / trees.size()


func _ok(name: String, pass_: bool, detail: String) -> void:
	if not pass_:
		fails += 1
	print("CYCLESHOT %-12s %s  %s" % [name, "PASS" if pass_ else "FAIL", detail])
