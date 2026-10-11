extends SceneTree

## LINES (T-49 spike) against splats, through the real main scene on this Mac. For each
## bulb and each LINES rung (0 is today's splats) it settles and bakes the cloud, then for
## three views saves a PNG and the main viewport's GPU time:
##
##   side   the slice planes edge-on, the slice axis 90 degrees from the view
##   45     the axis 45 degrees from the view
##   axial  looking straight down the slice axis (rings concentric)
##
## Sim time is sampled during the settle, the only time a frozen bulb simulates. Each run
## also dumps the visible particles (state, normal + hide flag, bake) for
## tools/line_check.py, and checks the CPU distance estimate at a sample of them, which is
## what says whether a point on a "ring" is actually on the surface.
##
## Mac numbers: read them as ratios between modes, not as Quest milliseconds.
##
##   tools/line_shot.sh [Classic,Citadel] [0,24,48,96]

## name: [tilt of the slice axis toward the camera in degrees, cloud offset from the eye
## in metres, cloud node scale]. The first three are the kill-criterion views at the
## gallery framing; toy is the hand-held framing, held low and looked down on.
const VIEWS := {
	"side": [0.0, [0.0, -0.2, -2.6], 0.9],
	"45": [45.0, [0.0, -0.2, -2.6], 0.9],
	"axial": [90.0, [0.0, -0.2, -2.6], 0.9],
	"toy": [30.0, [0.0, -0.12, -0.75], 0.22],
}
const FRAMES := 90
const OUT := "res://.spike-out/lines/"


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var bulbs: PackedStringArray = ["Classic", "Citadel"]
	var modes: Array = [0, 24, 48, 96]
	if args.size() > 0:
		bulbs = args[0].split(",")
	if args.size() > 1:
		modes = Array(args[1].split(",")).map(func(s): return int(s))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))

	var main = (load("res://main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	for i in 40:
		await process_frame
	main.help.close()
	main.xr_camera.position = Vector3(0.0, 1.6, 0.0)
	for i in 3:
		await process_frame
	main._set_mode("bulb")
	main.spin = false
	main._drift = false
	main.breath_idx = 2   # BREATH_STEPS[2] = 0: a still shape, so the DE check is fair
	var vp := root.get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(vp, true)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	var cloud: ParticleCloud = main.cloud
	var rd := RenderingServer.get_rendering_device()
	var ok := true

	for bname in bulbs:
		var bi := -1
		for i in main.library.bulbs.size():
			if str(main.library.bulbs[i].get("name", "")) == bname:
				bi = i
		if bi < 0:
			print("LINESHOT FAIL no bulb named %s" % bname)
			ok = false
			continue
		for slices in modes:
			var li: int = main.LINE_SLICES.find(slices)
			if li < 0:
				print("LINESHOT FAIL %d is not a LINES rung" % slices)
				ok = false
				continue
			# The menu path, minus the press: reseed, reload, settle, bake.
			main.line_idx = li
			cloud.request_seed()
			main._load_bulb(bi)
			var sim := 0.0
			var ns := 0
			var f := 0
			while main._bulb_settle > 0 and f < 600:
				await process_frame
				f += 1
				# Skip the seed frame and the reseed-free tail; sample the steady settle.
				if f > 10 and main._bulb_settle > main.FUSE_FRAMES:
					sim += cloud.iterate_us
					ns += 1
			var gen: int = cloud._bake_gen
			var g := 0
			while (cloud._bake_gen == gen or cloud.is_baking() or not cloud.bake_ready) and g < 600:
				await process_frame
				g += 1
			# The framing eases toward its target; the first run on a new bulb was being shot
			# mid-ease, at a different size from the rest.
			while (absf(cloud.fit - cloud.target_fit) > 0.002 * cloud.target_fit
					or cloud.center.distance_to(cloud.target_center) > 0.002) and g < 1200:
				await process_frame
				g += 1
			if not cloud.bake_ready or cloud._bake_gen == gen:
				print("LINESHOT FAIL %s/%d: bake never landed (%d frames)" % [bname, slices, g])
				ok = false
			var sim_ms := (sim / ns / 1000.0) if ns > 0 else 0.0
			var tag := "%s_%s" % [bname.to_lower(), "splats" if slices == 0 else "lines%d" % slices]

			for vname in VIEWS:
				var v: Array = VIEWS[vname]
				main.cloud.scale = Vector3.ONE * float(v[2])
				main.cloud.global_position = main.xr_camera.global_transform.origin + Vector3(
					v[1][0], v[1][1], v[1][2])
				main.cloud.rotation = Vector3(deg_to_rad(float(v[0])), 0.0, 0.0)
				for i in 20:
					await process_frame
				var m1 := await _measure(vp)
				var img := root.get_viewport().get_texture().get_image()
				var err := img.save_png(OUT + "%s_%s.png" % [tag, vname])
				if err != OK:
					ok = false
				# Again at 2x the pixels (3D scale 2 = 4.1M, nearer two Quest eyes' 5.9M),
				# because the splat cost is fill and fill is what lines change.
				root.get_viewport().scaling_3d_scale = 2.0
				for i in 10:
					await process_frame
				var m2 := await _measure(vp)
				root.get_viewport().scaling_3d_scale = 1.0
				print("LINESHOT bulb=%s slices=%d view=%-5s draw_gpu_ms=%s draw_gpu_ms_x2=%s frame_ms=%.3f sim_settle_ms=%s png=%s" % [
					bname, slices, vname, _fmt(m1[0]), _fmt(m2[0]), m1[1],
					_fmt(sim_ms), "ok" if err == OK else "FAIL %d" % err])

			_dump(rd, main, cloud, tag, slices)
	print("LINESHOT DONE %s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)


## Mean GPU time of the main viewport and wall time per frame over FRAMES frames.
func _measure(vp: RID) -> Array:
	var gpu := 0.0
	var w0 := Time.get_ticks_usec()
	for i in FRAMES:
		await process_frame
		gpu += RenderingServer.viewport_get_measured_render_time_gpu(vp)
	return [gpu / FRAMES, float(Time.get_ticks_usec() - w0) * 0.001 / FRAMES]


## A zero from a timer that never spoke is not a measurement.
func _fmt(ms: float) -> String:
	return "%.3f" % ms if ms > 0.0 else "unavailable"


## Raw dump of the live particles for line_check.py, plus a CPU distance-estimate check at
## a sample of the visible ones. The DE is BulbSource's own port (de_check.sh keeps it
## honest), so no fourth copy of the five formulas.
func _dump(rd: RenderingDevice, main, cloud: ParticleCloud, tag: String, slices: int) -> void:
	var n: int = cloud.get_count()
	var st := rd.texture_get_data(cloud.state_texture_rid(), 0).slice(0, n * 16)
	var nm := rd.texture_get_data(cloud._normal_tex, 0).slice(0, n * 16)
	var bk := rd.texture_get_data(cloud.bake_texture_rid(), 0).slice(0, n * 8)
	for pair in [["state.f32", st], ["normal.f32", nm], ["bake.f16", bk]]:
		var fa := FileAccess.open(OUT + "%s.%s" % [tag, pair[0]], FileAccess.WRITE)
		fa.store_buffer(pair[1])
		fa.close()
	var bulb: BulbSource = main._bulb
	var mp := bulb.march_params()
	var shell := 0.012 * bulb.bound() if absf(float(mp["formula"]) - 1.0) < 0.5 else 0.0
	var h := bulb.slice_spacing()
	if slices > 0:
		shell = maxf(shell, bulb.slice_offset * h)   # bulb.glsl's ring level
	var hidden := 0
	var res: Array[float] = []
	for i in n:
		if nm.decode_float(i * 16 + 12) > 0.5:
			hidden += 1
			continue
		if i % 37 != 0:
			continue
		var p := Vector3(st.decode_float(i * 16), st.decode_float(i * 16 + 4), st.decode_float(i * 16 + 8))
		res.append(absf(bulb.de_with(p, mp) - shell))
	res.sort()
	var med := res[res.size() / 2] if res.size() > 0 else -1.0
	var p90 := res[int(res.size() * 0.9)] if res.size() > 0 else -1.0
	var meta := {
		"tag": tag, "count": n, "slices": slices, "axis": bulb.slice_axis, "spacing": h,
		"extent": float(bulb.room().get("extent", bulb.bound())), "bound": bulb.bound(),
		"shell_eps": shell, "coverage": main.BULB_COVERAGE[main.coverage_idx],
		"line_stretch": main.LINE_STRETCH if slices > 0 else 1.0,
		"line_width": main.LINE_WIDTH * h, "line_cap": main.LINE_CAP,
		"hidden": hidden, "de_median": med, "de_p90": p90, "de_samples": res.size(),
		# What line_check.py needs to rebuild every splat's on-screen quad (its fill model):
		# the camera, the cloud's transform relative to it, and the shader's sizing inputs.
		"fov_y": main.xr_camera.fov, "viewport": [root.get_viewport().get_visible_rect().size.x,
			root.get_viewport().get_visible_rect().size.y],
		"fit": cloud.fit, "center": [cloud.center.x, cloud.center.y, cloud.center.z],
		"views": VIEWS,
		"opacity": float(cloud._splat_material.get_shader_parameter("splat_opacity")),
	}
	var fm := FileAccess.open(OUT + "%s.json" % tag, FileAccess.WRITE)
	fm.store_string(JSON.stringify(meta))
	fm.close()
	print("LINESHOT dump %s count=%d hidden=%d (%.1f%%) de_median=%.5f de_p90=%.5f spacing=%.4f" % [
		tag, n, hidden, 100.0 * hidden / maxf(1.0, n), med, p90, h])
