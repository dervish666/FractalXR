extends SceneTree

## The flame at scale through the real main scene: GALAXY, ECHOES and the flame SKY, driven by
## their own wrist-menu tiles, captured, and checked for what a PNG cannot show on its own.
##
##   - GALAXY grows the flame to about RMS_M around the viewer, stops spin and drift, and puts
##     them back on the way out; the flame comes back to arm's length.
##   - ECHOES add light to a view past the hero (off is the control), draw within POINTS_MAX,
##     keep the comfort rules, stay put when the hero is grabbed away, and hide in tree mode.
##   - TO SKY bakes, the sky comes up behind the live FLAME (and the flame still stands out in
##     front of it), in TREE, IFS and GROUND, and in BULB only once BULB's own switch is on; it
##     adds light to each background (SKY off is the control), and yields to passthrough.
##   - The baked equirect itself, dumped from the GPU, so the bake can be judged whole.
##
## Desktop mono render, 1280x800, a 75 degree camera. Stereo, scale and comfort are headset
## questions; this proves the pieces draw and behave.
##
##   tools/flame_scale_shot.sh

const OUT := "res://.spike-out/flame-scale-2026-10-10"
const FWD := Vector3(-8.0, 0.0, 0.0)
## The galaxy's ease is timed in seconds and this window is not vsynced, so its frame count
## swings with the machine: the grow measured 1,903 and 1,995 frames, and a cap of 2,000 cut
## the ease out short with the fade still on.
const GALAXY_MAX_FRAMES := 6000

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
	while main.galaxy.is_moving() and frames < GALAXY_MAX_FRAMES:
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
	# GALAXY's entry state, read before this harness writes either uniform below. The comfort
	# fade: nothing within NEAR_FADE_M of the eye; it lives in the shader, so the check is that
	# the uniform is set while inside and cleared after. V11's depth grade, on the point and the
	# splat material both: SPLAT on draws GALAXY with the quad material, which first shipped
	# ungraded.
	var fade_in: float = main.cloud.point_material().get_shader_parameter("near_fade")
	var grade_in := _grades(main)
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
	# V11 in a picture. The grade tints points and splats past 3.5 m toward (0.68, 0.78, 0.96):
	# with it on the frame must lose linear luma and its blue must gain on its red, against the
	# grade off before and after (the control: the chaos game keeps running).
	# Points at GALAXY's own settings. Measured on this Mac: about -8% luma, blue/red +9%.
	var pg: Array = await _grade_cmp(main, "points")
	_ok("galaxy point grade", pg[0] > 0.03 and pg[2] > pg[1] * 1.03 and pg[3] < 0.01, pg[4])
	# Splats. Inside GALAXY the splats between 0.6 and 3.5 m cover the far ones the grade
	# tints, so at its own settings the frame moves about 0.2%. For this check near_fade goes to
	# 8 m (alpha 0 inside 3.2 m) so the far splats show. Measured: -2.8%, blue/red +3%.
	main.splat_on = true
	main._apply_point_look()
	# SPLAT on inside GALAXY keeps the grade on both materials. Zero both directly (not through
	# set_depth_grade, the code under test) and clear main.gd's cached value, so its own tick
	# must write 1 to each again with SPLAT on; the point comparison above left both at 1.
	for m: ShaderMaterial in main.cloud._mats:
		m.set_shader_parameter("depth_grade", 0.0)
	main._depth_grade = -1.0
	for i in 3:
		await process_frame
	var grade_splat := _grades(main)
	_ok("galaxy splat keeps grade", grade_splat == [1.0, 1.0],
		"depth_grade points, splats %s with SPLAT on" % str(grade_splat))
	main.cloud.set_near_fade(8.0)
	for i in 30:
		await process_frame
	var sgr: Array = await _grade_cmp(main, "splat")
	_ok("galaxy splat grade", sgr[0] > 0.01 and sgr[2] > sgr[1] * 1.015 and sgr[3] < 0.005, sgr[4])
	# SPLAT stays on through the exit below: leaving must clear the grade on both materials
	# whichever one is drawing, or the points keep 1 when SPLAT goes off later.
	main.cloud.set_near_fade(FlameGalaxy.NEAR_FADE_M)
	for i in 6:
		await process_frame

	_ok("galaxy covers the view", gs["lit"] > home_s["lit"],
		"lit %.3f inside against %.3f at home" % [gs["lit"], home_s["lit"]])

	tile.advance.call()
	frames = 0
	while main.galaxy.is_moving() and frames < GALAXY_MAX_FRAMES:
		await process_frame
		frames += 1
	await process_frame
	var s_out: float = main.cloud.global_transform.basis.get_scale().x
	var fade_out: float = main.cloud.point_material().get_shader_parameter("near_fade")
	var grade_out := _grades(main)
	_ok("galaxy leaves", not main.galaxy.active and absf(s_out - 1.0) < 0.01 and main.spin and main._drift
			and main.bright_idx == bright0 and fade_in > 0.0 and fade_out == 0.0
			and grade_in == [1.0, 1.0] and grade_out == [0.0, 0.0],
		"scale %.3f, spin %s, drift %s, bright %d, near_fade %.2f -> %.2f, depth_grade points, splats %s -> %s (left with SPLAT on)" % [
			s_out, main.spin, main._drift, main.bright_idx, fade_in, fade_out, str(grade_in),
			str(grade_out)])
	await _shot(main, "galaxy-out.png", FWD)
	main.splat_on = false
	main._apply_point_look()
	for i in 6:
		await process_frame
	# A recentre mid-galaxy puts everything back at once, the grade included, here with SPLAT
	# off. With the SPLAT-on exit above, set_depth_grade's four cases (SPLAT on or off, grade 0
	# or 1) each have a check: 1 with points on entry, 1 with SPLAT on, 0 with SPLAT on, 0 here.
	tile.advance.call()
	for i in 30:
		await process_frame
	var grade_mid := _grades(main)
	main._go_home()
	for i in 3:
		await process_frame
	var grade_home := _grades(main)
	_ok("galaxy home", not main.galaxy.active and not main.galaxy.is_moving()
			and absf(main.cloud.global_transform.basis.get_scale().x - 1.0) < 0.01 and main.spin
			and grade_mid == [1.0, 1.0] and grade_home == [0.0, 0.0],
		"X mid-grow: scale %.3f, depth_grade points, splats %s -> %s (SPLAT off)" % [
			main.cloud.global_transform.basis.get_scale().x, str(grade_mid), str(grade_home)])
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
	await _sky_flame(main, sky)
	await _sky_bulb(main, sky)

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
	# CYCLE turns the sky's hue (V8) and must keep its brightness: a turn about the grey axis
	# alone took Ember 49% brighter a third of the way round in the texture, +247% in this
	# sky band. The shader keeps each texel's luma exactly, and ACES moves that under 2% at any
	# exposure (modelled on the texture), yet this band reads -11.8%: not explained, most likely
	# 8-bit quantisation near black (the band averages about 11 of 255). So the bound is 20%,
	# which still fails the unkept turn by a factor of twelve. A preset, 40 degrees up (bright enough that 8-bit near black does not
	# swamp it: at 70 degrees the frame averaged 10 of 255). Only the top 55% of the frame is
	# measured: the flame and a ray reach into the lower part, and the ray, moving between the
	# shots, took the control to 3% on its own once the display was awake.
	main.flame_sky.set_pick(1)
	await _settle_sky(main)
	var up := Vector3(40.0, 0.0, 0.0)
	RenderingServer.global_shader_parameter_set(&"colour_cycle", 0.0)
	var c0: Image = await _shot(main, "sky-cycle-0.png", up)
	RenderingServer.global_shader_parameter_set(&"colour_cycle", 0.33)
	var c1: Image = await _shot(main, "sky-cycle-33.png", up)
	RenderingServer.global_shader_parameter_set(&"colour_cycle", 0.0)
	# The control: back at 0 it must read within 3% of before, or something else (a fade still
	# running) moved. Two runs read 0.0% and 1.7%.
	var c2: Image = await _shot(main, "sky-cycle-0b.png", up)
	main.flame_sky.set_pick(0)
	var band := Rect2i(0, 0, c0.get_width(), int(c0.get_height() * 0.55))
	var l0 := _mean_luma(c0.get_region(band))
	var l1 := _mean_luma(c1.get_region(band))
	var l2 := _mean_luma(c2.get_region(band))
	var hue_moved := _mean_rgb_diff(c0, c1)
	var steady := absf(l2 / maxf(l0, 1e-6) - 1.0) < 0.03
	_ok("sky cycle keeps luma", l0 > 0.002 and steady and absf(l1 / l0 - 1.0) < 0.2 and hue_moved > 0.01,
		"Ember linear luma %.4f at 0, %.4f a third round (%+.1f%%), %.4f back at 0, colour moved %.4f" % [
			l0, l1, 100.0 * (l1 / maxf(l0, 1e-6) - 1.0), l2, hue_moved])
	main._set_mode("flame")
	for i in 4:
		await process_frame


## Behind the live flame: the sky the flame was baked into, hung behind the flame itself. The
## pair is sky on and off from the same view; the flame has to keep standing out of the sky.
func _sky_flame(main, sky) -> void:
	var env: Environment = main._env()
	var look := Vector3(12.0, 25.0, 0.0)
	await _settle_sky(main)
	var on_img: Image = await _shot(main, "sky-flame.png", look)
	var shown: bool = env.background_mode == Environment.BG_SKY
	sky.advance.call()
	for i in 4:
		await process_frame
	var off_img: Image = await _shot(main, "nosky-flame.png", look)
	var hidden: bool = env.background_mode == Environment.BG_COLOR
	sky.advance.call()
	var on_s := _stats(on_img)
	var off_s := _stats(off_img)
	_ok("sky over flame", shown and hidden and on_s["lit_n"] > off_s["lit_n"] + 1000,
		"lit samples sky %d against %d without" % [on_s["lit_n"], off_s["lit_n"]])
	# Washed out or not: where the flame draws (lit with the sky off), its mean luminance with
	# the sky on, against the sky's own mean where no flame draws. Additive points over a
	# background, so the flame's pixels carry the sky too; this asks that they still clearly
	# beat it.
	var c := _contrast(on_img, off_img)
	print("FLAMESCALE stats sky-flame %s nosky-flame %s contrast %s" % [str(on_s), str(off_s), str(c)])
	_ok("flame over its sky", c["flame"] > 2.0 * c["sky"] and c["flame_off"] > 0.0,
		"flame pixels %.3f (%.3f without the sky), sky elsewhere %.3f" % [
			c["flame"], c["flame_off"], c["sky"]])
	# Passthrough wins in FLAME too.
	main.passthrough = true
	for i in 4:
		await process_frame
	var yields: bool = env.background_mode == Environment.BG_COLOR
	main.passthrough = false
	for i in 4:
		await process_frame
	_ok("flame sky yields", yields and env.background_mode == Environment.BG_SKY, "passthrough wins in FLAME")


## BULB: the SKY switch there is its own and starts off, whatever the other modes have; on, the
## baked sky hangs behind the bulb as it does everywhere else.
func _sky_bulb(main, sky) -> void:
	var env: Environment = main._env()
	main._set_mode("bulb")
	main.spin = false
	for i in 200:
		await process_frame
	var look := Vector3(8.0, 25.0, 0.0)
	var off_first: bool = env.background_mode == Environment.BG_COLOR \
		and str(sky.read.call()) == "off" and main.sky_on
	var read_first := str(sky.read.call())
	var off_img: Image = await _shot(main, "nosky-bulb.png", look)
	sky.advance.call()
	await _settle_sky(main)
	var on_img: Image = await _shot(main, "sky-bulb.png", look)
	var shown: bool = env.background_mode == Environment.BG_SKY and str(sky.read.call()) == "on"
	sky.advance.call()
	for i in 4:
		await process_frame
	var back_off: bool = env.background_mode == Environment.BG_COLOR and not main.sky_bulb_on \
		and main.sky_on
	var on_s := _stats(on_img)
	var off_s := _stats(off_img)
	print("FLAMESCALE stats sky-bulb %s nosky-bulb %s" % [str(on_s), str(off_s)])
	_ok("bulb sky off at first", off_first, "tile read %s with FLAME's switch %s" % [
		read_first, str(main.sky_on)])
	_ok("sky over bulb", shown and back_off and on_s["lit_n"] > off_s["lit_n"] + 1000,
		"lit samples sky %d against %d without" % [on_s["lit_n"], off_s["lit_n"]])


## Mean luminance of the flame's pixels (lit in the sky-off shot) in both shots, and of the sky
## where the flame does not draw.
func _contrast(on_img: Image, off_img: Image) -> Dictionary:
	var f_on := 0.0
	var f_off := 0.0
	var f_n := 0
	var s_on := 0.0
	var s_n := 0
	for y in range(0, on_img.get_height(), 2):
		for x in range(0, on_img.get_width(), 2):
			var a := off_img.get_pixel(x, y)
			var b := on_img.get_pixel(x, y)
			var ma := maxf(a.r, maxf(a.g, a.b))
			var lb := 0.2126 * b.r + 0.7152 * b.g + 0.0722 * b.b
			if ma > 0.12:
				f_on += lb
				f_off += 0.2126 * a.r + 0.7152 * a.g + 0.0722 * a.b
				f_n += 1
			elif ma < 0.02:
				s_on += lb
				s_n += 1
	return {"flame": f_on / maxi(1, f_n), "flame_off": f_off / maxi(1, f_n),
		"sky": s_on / maxi(1, s_n), "flame_n": f_n, "sky_n": s_n}


## The baked equirect straight off the GPU, through a plain Reinhard so it fits a PNG.
func _dump_sky(main) -> void:
	var holder := [PackedByteArray()]
	RenderingServer.call_on_render_thread(func():
		var rd := RenderingServer.get_rendering_device()
		holder[0] = rd.texture_get_data(main.flame_sky._sky_tex, 0))
	for i in 3:
		await process_frame
	var data: PackedByteArray = holder[0]
	var size: Vector2i = main.flame_sky.texture_size()
	var sw := size.x
	var sh := size.y
	print("FLAMESCALE sky texture %dx%d (SKY RES %d wide)" % [sw, sh, main.flame_sky.width])
	if data.size() != sw * sh * 8 or sw != main.flame_sky.width:
		_ok("sky dump", false, "%d bytes for %dx%d" % [data.size(), sw, sh])
		return
	var img := Image.create_from_data(sw, sh, false, Image.FORMAT_RGBAH, data)
	var peak := 0.0
	var lit := 0
	var n := 0
	for y in range(0, sh, 4):
		for x in range(0, sw, 4):
			var c := img.get_pixel(x, y)
			var m := maxf(c.r, maxf(c.g, c.b))
			peak = maxf(peak, m)
			if m > 0.02:
				lit += 1
			n += 1
	# 1280 across whatever the bake's size, so the PNG and the walk over it stay cheap.
	var step := maxi(1, sw / 1280)
	var out := Image.create(sw / step, sh / step, false, Image.FORMAT_RGB8)
	for y in out.get_height():
		for x in out.get_width():
			var c := img.get_pixel(x * step, y * step)
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


## Mean linear luma of every sample (sRGB decoded first: Rec. 709 weights on encoded values
## are not luminance), and the mean per-channel change between two images.
## depth_grade on the point and the splat material (ParticleCloud._mats), 0 where never set.
func _grades(main) -> Array:
	var out := []
	for m: ShaderMaterial in main.cloud._mats:
		var g = m.get_shader_parameter("depth_grade")
		out.append(float(g) if g != null else 0.0)
	return out


func _mean_luma(img: Image) -> float:
	var sum := 0.0
	var n := 0
	for y in range(0, img.get_height(), 4):
		for x in range(0, img.get_width(), 4):
			var c := img.get_pixel(x, y).srgb_to_linear()
			sum += 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
			n += 1
	return sum / float(maxi(n, 1))


## V11's grade off, on, then off again, looking ahead. Returns [dimming, blue/red off, blue/red
## on, control drift, detail]. Leaves the grade at 1, what main.gd last wrote inside GALAXY
## (it writes only on change).
func _grade_cmp(main, tag: String) -> Array:
	main.cloud.set_depth_grade(0.0)
	var c0 := _mean_lin(await _shot(main, "galaxy-%s-grade0.png" % tag, FWD))
	main.cloud.set_depth_grade(1.0)
	var c1 := _mean_lin(await _shot(main, "galaxy-%s-grade1.png" % tag, FWD))
	main.cloud.set_depth_grade(0.0)
	var c2 := _mean_lin(await _shot(main, "galaxy-%s-grade0-again.png" % tag, FWD))
	main.cloud.set_depth_grade(1.0)
	var W := Vector3(0.2126, 0.7152, 0.0722)
	var l0 := c0.dot(W)
	var l1 := c1.dot(W)
	var dim := (l0 - l1) / maxf(l0, 1e-6)
	var drift := absf(c2.dot(W) - l0) / maxf(l0, 1e-6)
	var br0 := c0.z / maxf(c0.x, 1e-6)
	var br1 := c1.z / maxf(c1.x, 1e-6)
	return [dim, br0, br1, drift, "luma %.5f -> %.5f (%+.1f%%), blue/red %.3f -> %.3f, control drift %.2f%%" % [
		l0, l1, -100.0 * dim, br0, br1, 100.0 * drift]]


## Mean linear RGB, every fourth pixel each way.
func _mean_lin(img: Image) -> Vector3:
	var sum := Vector3.ZERO
	var n := 0
	for y in range(0, img.get_height(), 4):
		for x in range(0, img.get_width(), 4):
			var c := img.get_pixel(x, y).srgb_to_linear()
			sum += Vector3(c.r, c.g, c.b)
			n += 1
	return sum / float(maxi(n, 1))


func _mean_rgb_diff(a: Image, b: Image) -> float:
	var sum := 0.0
	var n := 0
	for y in range(0, a.get_height(), 4):
		for x in range(0, a.get_width(), 4):
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			sum += (absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)) / 3.0
			n += 1
	return sum / float(maxi(n, 1))


func _ok(name: String, pass_: bool, detail: String) -> void:
	if not pass_:
		_fails += 1
	print("FLAMESCALE %-24s %s  %s" % [name, "PASS" if pass_ else "FAIL", detail])


func _shot(main, file: String, look: Vector3) -> Image:
	main.xr_camera.rotation_degrees = look
	# Six drawn frames, not six process ticks: with the window behind others on a desktop in use,
	# ticks ran on while the viewport kept an old frame, and the first shot after a change
	# captured the state before it.
	for i in 6:
		await RenderingServer.frame_post_draw
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
