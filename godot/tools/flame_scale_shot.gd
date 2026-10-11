extends SceneTree

## The flame at scale through the real main scene: GALAXY, ECHOES and the flame SKY, driven by
## their own wrist-menu tiles, captured, and checked for what a PNG cannot show on its own.
##
##   - GALAXY grows the flame to about RMS_M around the viewer, stops spin and drift, and puts
##     them back on the way out; the flame comes back to arm's length.
##   - ECHOES add light to a view past the hero (off is the control), draw within POINTS_MAX,
##     keep the comfort rules, stay put when the hero is grabbed away, and hide in tree mode.
##   - TO SKY bakes, the sky stays off in FLAME, comes up in TREE, IFS and GROUND, adds light to
##     their backgrounds (SKY off is the control), and yields to passthrough.
##   - The baked equirect itself, dumped from the GPU, so the bake can be judged whole.
##
## Desktop mono render, 1280x800, a 75 degree camera. Stereo, scale and comfort are headset
## questions; this proves the pieces draw and behave.
##
##   tools/flame_scale_shot.sh

const OUT := "res://.spike-out/flame-scale-2026-10-10"
const FWD := Vector3(-8.0, 0.0, 0.0)

var _fails := 0


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var main = (load("res://main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	for i in 40:
		await process_frame
	main.help.close()
	main.xr_camera.position = Vector3(0.0, 1.6, 0.0)
	main.xr_camera.rotation_degrees = FWD
	# Still pictures: no drift to another flame mid-run, no turntable between captures.
	main._drift = false
	main.spin = false
	for i in 240:
		await process_frame
	main._recenter()
	for i in 30:
		await process_frame
	var home: Image = await _shot(main, "flame-home.png", FWD)
	var home_s := _stats(home)
	print("FLAMESCALE stats home %s" % str(home_s))
	# What the point shader actually draws with, so a BRIGHT ladder change can be checked
	# against the uniform and not only against a noisy chaos-game frame.
	print("FLAMESCALE home bright_idx=%d step=%.3f uniform=%.3f" % [main.bright_idx,
		main.BRIGHT_STEPS[main.bright_idx], main.cloud.point_material().get_shader_parameter("brightness")])

	await _galaxy(main, home_s)
	await _echoes(main)
	await _sky(main)
	print("FLAMESCALE %s failures=%d dir=%s" % ["PASS" if _fails == 0 else "FAIL", _fails, OUT])
	quit(0 if _fails == 0 else 1)


# --- GALAXY ------------------------------------------------------------------

func _galaxy(main, home_s: Dictionary) -> void:
	var tile = _tile(main, "GALAXY", "scene")
	if tile == null:
		_ok("galaxy tile", false, "no GALAXY tile in the flame's scene section")
		return
	main.spin = true
	main._drift = true
	var bright0: int = main.bright_idx
	tile.advance.call()
	var settings_in: bool = main.galaxy.active and not main.spin and not main._drift \
		and main.BRIGHT_STEPS[main.bright_idx] == maxf(main.BRIGHT_STEPS[bright0], FlameGalaxy.BRIGHT)
	var mid: Image = null
	var frames := 0
	while main.galaxy.is_moving() and frames < 2000:
		await process_frame
		frames += 1
		if mid == null and frames > 0 and main.galaxy._t > 0.5:
			mid = await _shot(main, "galaxy-growing.png", FWD)
	var s: float = main.cloud.global_transform.basis.get_scale().x
	var rms_m: float = s * main.cloud.target_rms * main.cloud.target_fit
	var centre: Vector3 = main.cloud.global_transform.origin
	var head: Vector3 = main.xr_camera.global_transform.origin
	_ok("galaxy grows", main.galaxy.active and absf(rms_m - FlameGalaxy.RMS_M) < 0.5
			and absf(centre.distance_to(head) - Vector2(FlameGalaxy.AHEAD, FlameGalaxy.DROP).length()) < 0.05,
		"scale %.2f, rms %.2f m, centre %.2f m from the head, %d frames" % [
			s, rms_m, centre.distance_to(head), frames])
	_ok("galaxy settings", settings_in, "spin off, drift off, bright %d -> %d, uniform %.3f" % [
		bright0, main.bright_idx, main.cloud.point_material().get_shader_parameter("brightness")])
	var fwd: Image = await _shot(main, "galaxy-fwd.png", FWD)
	await _shot(main, "galaxy-up.png", Vector3(50.0, 0.0, 0.0))
	await _shot(main, "galaxy-left.png", Vector3(0.0, 80.0, 0.0))
	await _shot(main, "galaxy-back.png", Vector3(0.0, 180.0, 0.0))
	var gs := _stats(fwd)
	print("FLAMESCALE stats galaxy %s" % str(gs))
	# The brightness ladder from inside (0.05, 0.12, 0.3), so FlameGalaxy.BRIGHT is chosen
	# against numbers. 0.05 is the default; the two detents below it are dimmer still.
	var keep: int = main.bright_idx
	for b in [2, 3, 4]:
		main.bright_idx = b
		main._apply_point_look()
		var im: Image = await _shot(main, "galaxy-bright-%d.png" % b, FWD)
		print("FLAMESCALE stats galaxy bright=%.3f %s" % [main.BRIGHT_STEPS[b], str(_stats(im))])
	main.bright_idx = keep
	main._apply_point_look()
	# The comfort fade: nothing within NEAR_FADE_M of the eye. The fade lives in the shader, so
	# the check is that the uniform is set while inside and cleared after.
	var fade_in: float = main.cloud.point_material().get_shader_parameter("near_fade")
	_ok("galaxy covers the view", gs["lit"] > home_s["lit"],
		"lit %.3f inside against %.3f at home" % [gs["lit"], home_s["lit"]])

	tile.advance.call()
	frames = 0
	while main.galaxy.is_moving() and frames < 2000:
		await process_frame
		frames += 1
	await process_frame
	var s_out: float = main.cloud.global_transform.basis.get_scale().x
	var fade_out: float = main.cloud.point_material().get_shader_parameter("near_fade")
	_ok("galaxy leaves", not main.galaxy.active and absf(s_out - 1.0) < 0.01 and main.spin and main._drift
			and main.bright_idx == bright0 and fade_in > 0.0 and fade_out == 0.0,
		"scale %.3f, spin %s, drift %s, bright %d, near_fade %.2f -> %.2f" % [
			s_out, main.spin, main._drift, main.bright_idx, fade_in, fade_out])
	await _shot(main, "galaxy-out.png", FWD)
	# A recentre mid-galaxy puts everything back at once.
	tile.advance.call()
	for i in 30:
		await process_frame
	main._go_home()
	await process_frame
	_ok("galaxy home", not main.galaxy.active and not main.galaxy.is_moving()
			and absf(main.cloud.global_transform.basis.get_scale().x - 1.0) < 0.01 and main.spin,
		"X mid-grow: scale %.3f" % main.cloud.global_transform.basis.get_scale().x)
	main.spin = false
	main._drift = false
	main._recenter()
	for i in 10:
		await process_frame


# --- ECHOES ------------------------------------------------------------------

func _echoes(main) -> void:
	var tile = _tile(main, "ECHOES", "scene")
	if tile == null:
		_ok("echoes tile", false, "no ECHOES tile in the flame's scene section")
		return
	var views := {"left": Vector3(10.0, 60.0, 0.0), "right": Vector3(10.0, -60.0, 0.0),
		"up": Vector3(40.0, 0.0, 0.0), "wide": Vector3(15.0, 30.0, 0.0)}
	var off := {}
	for v in views:
		off[v] = await _shot(main, "echoes-off-%s.png" % v, views[v])
	var reads := [str(tile.read.call())]
	tile.advance.call()
	reads.append(str(tile.read.call()))
	for i in 4:
		await process_frame
	var four := {}
	for v in views:
		four[v] = await _shot(main, "echoes-four-%s.png" % v, views[v])
	var four_pts: int = main.flame_echoes.point_total()
	tile.advance.call()
	reads.append(str(tile.read.call()))
	for i in 4:
		await process_frame
	var eight := {}
	for v in views:
		eight[v] = await _shot(main, "echoes-eight-%s.png" % v, views[v])
	await _shot(main, "echoes-eight-fwd.png", FWD)
	var eight_pts: int = main.flame_echoes.point_total()
	var lit_off := 0
	var lit_four := 0
	var lit_eight := 0
	for v in views:
		lit_off += _stats(off[v])["lit_n"]
		lit_four += _stats(four[v])["lit_n"]
		lit_eight += _stats(eight[v])["lit_n"]
	_ok("echoes tile", reads[0] == "off" and reads[1].begins_with("four") and reads[2].begins_with("eight")
			and main.flame_echoes.count() == 8, "reads %s" % str(reads))
	_ok("echoes draw", lit_four > lit_off + 500 and lit_eight > lit_four,
		"lit samples off %d, four %d, eight %d" % [lit_off, lit_four, lit_eight])
	# Both under the cap. Not monotonic: tiers halve, so eight echoes can leave more slack than four.
	_ok("echoes budget", eight_pts <= FlameEchoes.POINTS_MAX and four_pts <= FlameEchoes.POINTS_MAX
			and four_pts > 0 and eight_pts > 0,
		"four %d points, eight %d, cap %d; hero %d; drawn %s" % [four_pts, eight_pts,
			FlameEchoes.POINTS_MAX, main.cloud.get_count(), str(main.flame_echoes.drawn)])
	# Every placement keeps the comfort rules, held to the same predicate the layout used.
	var bad := 0
	var floor_y: float = main.xr_origin.global_position.y - main.xr_camera.global_transform.origin.y
	var hero := Vector3(0.0, -main.HOME_DROP, -main.HOME_DISTANCE)
	var placed: Array = main.flame_echoes.placements
	for i in placed.size():
		var p: Dictionary = placed[i]
		if FlameEchoes.violates(p["pos"], p["r"], floor_y, hero.normalized(), placed.slice(0, i)):
			bad += 1
	var near := INF
	for p in placed:
		near = minf(near, (p["pos"] as Vector3).length() - float(p["r"]))
	_ok("echoes comfort", bad == 0 and placed.size() == FlameEchoes.MAX_ECHOES and near >= FlameEchoes.HEAD_CLEAR,
		"%d placed, %d violations, nearest surface %.2f m from the head" % [placed.size(), bad, near])
	# Room-anchored: grabbing the hero away leaves them where they hang.
	var e0: Transform3D = main.flame_echoes.global_transform
	main.cloud.global_translate(Vector3(1.5, 0.3, -0.5))
	await process_frame
	_ok("echoes stay put", main.flame_echoes.global_transform.is_equal_approx(e0), "")
	main._recenter()
	# Hidden with the flame: tree mode and splats.
	main._set_mode("tree")
	for i in 4:
		await process_frame
	var hid_tree: bool = not main.flame_echoes.visible
	main._set_mode("flame")
	for i in 4:
		await process_frame
	var back: bool = main.flame_echoes.visible
	main.splat_on = true
	main._apply_point_look()
	for i in 4:
		await process_frame
	var hid_splat: bool = not main.flame_echoes.visible
	main.splat_on = false
	main._apply_point_look()
	_ok("echoes follow the flame", hid_tree and back and hid_splat,
		"tree hidden %s, back %s, splat hidden %s" % [hid_tree, back, hid_splat])
	main.flame_echoes.set_step(0)
	for i in 4:
		await process_frame


# --- SKY ---------------------------------------------------------------------

func _sky(main) -> void:
	var bake = _tile(main, "TO SKY", "scene")
	var sky = _tile(main, "SKY", "scene")
	if bake == null or sky == null:
		_ok("sky tiles", false, "TO SKY %s, SKY %s" % [bake != null, sky != null])
		return
	var env: Environment = main._env()
	var read0 := str(sky.read.call())
	bake.advance.call()
	var frames := 0
	var us_sum := 0.0
	var us_n := 0
	var reads := []
	while not main.flame_sky.ready and frames < 3000:
		await process_frame
		frames += 1
		if main.flame_sky.bake_us > 0.0:
			us_sum += main.flame_sky.bake_us
			us_n += 1
		if frames % 60 == 0:
			reads.append(str(bake.read.call()))
	print("FLAMESCALE sky bake: %d frames, %s us a frame on this Mac (%d timed), reads %s" % [
		frames, "%.0f" % (us_sum / us_n) if us_n > 0 else "unavailable", us_n, str(reads)])
	_ok("sky bakes", main.flame_sky.ready and main.sky_on and read0 == "off",
		"%d frames; SKY read %s before, %s after" % [frames, read0, str(sky.read.call())])
	await _dump_sky(main)
	# Not in FLAME: the live flame is the scene there.
	for i in 10:
		await process_frame
	_ok("sky not in flame", env.background_mode == Environment.BG_COLOR, "mode %d" % env.background_mode)

	for mode in ["tree", "ifs", "ground"]:
		main._set_mode(mode)
		var look: Vector3 = Vector3(25.0, 20.0, 0.0) if mode != "ground" else Vector3(12.0, 0.0, 0.0)
		main.xr_camera.rotation_degrees = look
		var fading: Image = null
		if mode == "tree":
			# Mid-fade, to prove the sky comes up rather than snapping in.
			var f := 0
			while main.flame_sky._fade < 0.3 and f < 5000:
				await process_frame
				f += 1
			fading = root.get_viewport().get_texture().get_image()
			fading.save_png("%s/sky-tree-fading.png" % OUT)
		# The fade is timed in seconds and this window is not vsynced, so wait on it, not frames.
		await _settle_sky(main)
		var on_img: Image = await _shot(main, "sky-%s.png" % mode, look)
		if fading != null:
			var a := _stats(fading)
			var b := _stats(on_img)
			_ok("sky fades in", a["lit_n"] < b["lit_n"], "lit samples %d at 30%% of the fade, %d after" % [
				a["lit_n"], b["lit_n"]])
		var shown: bool = env.background_mode == Environment.BG_SKY
		sky.advance.call()
		for i in 4:
			await process_frame
		var off_img: Image = await _shot(main, "nosky-%s.png" % mode, look)
		var hidden: bool = env.background_mode == Environment.BG_COLOR
		sky.advance.call()
		var on_s := _stats(on_img)
		var off_s := _stats(off_img)
		_ok("sky over %s" % mode, shown and hidden and on_s["lit_n"] > off_s["lit_n"] + 1000,
			"lit samples sky %d against %d without" % [on_s["lit_n"], off_s["lit_n"]])
	# Passthrough wins. The desktop has no XR to start it, so set the flag the rule reads.
	main.passthrough = true
	for i in 4:
		await process_frame
	var yields: bool = env.background_mode == Environment.BG_COLOR
	main.passthrough = false
	for i in 4:
		await process_frame
	_ok("sky yields to passthrough", yields and env.background_mode == Environment.BG_SKY, "")
	main._set_mode("flame")
	for i in 4:
		await process_frame


## The baked equirect straight off the GPU, through a plain Reinhard so it fits a PNG.
func _dump_sky(main) -> void:
	var holder := [PackedByteArray()]
	RenderingServer.call_on_render_thread(func():
		var rd := RenderingServer.get_rendering_device()
		holder[0] = rd.texture_get_data(main.flame_sky._sky_tex, 0))
	for i in 3:
		await process_frame
	var data: PackedByteArray = holder[0]
	if data.size() != FlameSky.W * FlameSky.H * 8:
		_ok("sky dump", false, "%d bytes" % data.size())
		return
	var img := Image.create_from_data(FlameSky.W, FlameSky.H, false, Image.FORMAT_RGBAH, data)
	var peak := 0.0
	var lit := 0
	var n := 0
	for y in range(0, FlameSky.H, 4):
		for x in range(0, FlameSky.W, 4):
			var c := img.get_pixel(x, y)
			var m := maxf(c.r, maxf(c.g, c.b))
			peak = maxf(peak, m)
			if m > 0.02:
				lit += 1
			n += 1
	var out := Image.create(FlameSky.W / 2, FlameSky.H / 2, false, Image.FORMAT_RGB8)
	for y in out.get_height():
		for x in out.get_width():
			var c := img.get_pixel(x * 2, y * 2)
			out.set_pixel(x, y, Color(c.r / (1.0 + c.r), c.g / (1.0 + c.g), c.b / (1.0 + c.b)).linear_to_srgb())
	out.save_png("%s/sky-equirect.png" % OUT)
	_ok("sky texture", lit > n / 50 and peak > 0.2 and is_finite(peak),
		"%.1f%% of texels lit, peak %.2f" % [100.0 * lit / n, peak])


# --- helpers -----------------------------------------------------------------

func _settle_sky(main) -> void:
	for i in 10:
		await process_frame
	var frames := 0
	while main.flame_sky.is_shown() and main.flame_sky._fade < 1.0 and frames < 5000:
		await process_frame
		frames += 1
	# Ground fills its terrain over a few seconds of its own; give every mode the same wait.
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 1500:
		await process_frame


func _ok(name: String, pass_: bool, detail: String) -> void:
	if not pass_:
		_fails += 1
	print("FLAMESCALE %-24s %s  %s" % [name, "PASS" if pass_ else "FAIL", detail])


func _shot(main, file: String, look: Vector3) -> Image:
	main.xr_camera.rotation_degrees = look
	for i in 6:
		await process_frame
	var img := root.get_viewport().get_texture().get_image()
	var err := img.save_png("%s/%s" % [OUT, file])
	if err != OK:
		_ok("capture", false, "%s err=%d" % [file, err])
	return img


## lit: share of samples with any channel over 0.12; sat: over 0.95; lum: mean luminance of
## the lit samples; lit_n: the count, for sums across views.
func _stats(img: Image) -> Dictionary:
	var lit := 0
	var sat := 0
	var lum := 0.0
	var n := 0
	for y in range(0, img.get_height(), 2):
		for x in range(0, img.get_width(), 2):
			var c := img.get_pixel(x, y)
			var m := maxf(c.r, maxf(c.g, c.b))
			n += 1
			if m > 0.12:
				lit += 1
				lum += 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
			if m > 0.95:
				sat += 1
	return {"lit": snappedf(float(lit) / n, 0.001), "sat": snappedf(float(sat) / n, 0.0001),
		"lum": snappedf(lum / maxi(1, lit), 0.001), "lit_n": lit}


func _tile(main, label: String, section: String):
	for it in main.menu.items:
		if it.section == section and it.label == label \
				and (not it.visible_when.is_valid() or bool(it.visible_when.call())):
			return it
	return null
