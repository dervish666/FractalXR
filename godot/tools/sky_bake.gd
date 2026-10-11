extends SceneTree

## SKY through the real main scene and the bake the headset runs (FlameSky: chaos.glsl
## walkers, sky_splat.glsl, sky_resolve.glsl). Two jobs:
##
##   tools/sky_bake.sh measure [2560,4096,6144] [Ember]
##       The live bake at each equirect width: frames, Mac wall time, Mac GPU per bake frame,
##       and video memory before, at the peak and after (the device's own count, beside the
##       sizes worked out from the formats). The frame count is the headset's too: the bake
##       runs a fixed slice a frame, so at 72 Hz it takes frames / 72 seconds there.
##   tools/sky_bake.sh bake Vortex,Glacier [8192] [48]
##       Bakes each flame preset in its own palette at that width and samples per texel, and
##       writes the float sky to .spike-out/skies/<name>.rgbah (RGBA half, row 0 = up) with a
##       .json beside it. tools/sky_cube.py turns those into the art/skies/ presets.
##   tools/sky_bake.sh preview vortex,glacier
##       Each imported preset through the app's sky shader from the LOOKS below, to
##       .spike-out/skies/cube_<name>_<look>.png, beside the baked_<name>_<look>.png the bake
##       wrote from its live equirect: the same sky two ways, so a face in the wrong place,
##       turned the wrong way or seamed shows in tools/sky_compare.py.

const OUT := "res://.spike-out/skies/"
## Offline only: more chaos steps a frame. The headset keeps FlameSky.ROUNDS_PER_FRAME.
const OFFLINE_ROUNDS := 24
## Camera rotations (pitch, yaw) for the previews. edge looks along a cube edge (between -Z
## and -X), corner into the -X -Z +Y corner, up and down at the poles of the equirect.
const LOOKS := {"fwd": Vector3(10.0, 0.0, 0.0), "up": Vector3(89.0, 0.0, 0.0),
	"back": Vector3(10.0, 180.0, 0.0), "down": Vector3(-89.0, 0.0, 0.0),
	"edge": Vector3(0.0, 45.0, 0.0), "corner": Vector3(35.26, 45.0, 0.0)}

var _fails := 0


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var mode := args[0] if args.size() > 0 else "measure"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var main = (load("res://main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	for i in 40:
		await process_frame
	main.help.close()
	main.xr_camera.position = Vector3(0.0, 1.6, 0.0)
	main._set_mode("flame")
	main.spin = false
	main._drift = false
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0

	if mode == "measure":
		var widths: Array = [2560, 4096, 6144]
		if args.size() > 1:
			widths = Array(args[1].split(",")).map(func(s): return int(s))
		var flame := args[2] if args.size() > 2 else ""
		if flame != "" and not await _load_flame(main, flame):
			_fails += 1
		elif flame == "":
			await _settle(main)
		for w in widths:
			await _measure(main, int(w))
	elif mode == "bake":
		var names: PackedStringArray = args[1].split(",") if args.size() > 1 else PackedStringArray(["Ember"])
		var w := int(args[2]) if args.size() > 2 else 8192
		var spt := float(args[3]) if args.size() > 3 else 48.0
		for n in names:
			if not await _load_flame(main, n):
				_fails += 1
				continue
			await _bake_out(main, n, w, spt)
	elif mode == "preview":
		var names: PackedStringArray = args[1].split(",") if args.size() > 1 else PackedStringArray()
		await _preview_presets(main, names)
	else:
		print("SKYBAKE FAIL unknown mode %s" % mode)
		_fails += 1
	print("SKYBAKE DONE %s" % ("PASS" if _fails == 0 else "FAIL"))
	quit(0 if _fails == 0 else 1)


func _load_flame(main, flame: String) -> bool:
	for i in main.library.count():
		if main.library.name_at(i) == flame:
			main._load_preset(i)
			await _settle(main)
			return true
	print("SKYBAKE FAIL no flame preset named %s" % flame)
	return false


## The flame has to be on its attractor before the walkers are copied from it.
func _settle(main) -> void:
	var f := 0
	while (main._converge > 0 or not main.cloud.is_ready()) and f < 3000:
		await process_frame
		f += 1
	for i in 60:
		await process_frame


## One bake; returns [frames, wall_ms, mean GPU us a frame, peak device bytes, the longest
## bake frame's GPU us]. The longest is the resolve frame or the accumulator's clear: the
## hitch at the end of a bake, where the mean is the load across it.
func _run_bake(main) -> Array:
	var rd := RenderingServer.get_rendering_device()
	var sky: FlameSky = main.flame_sky
	var peak := 0
	var t0 := Time.get_ticks_usec()
	# The last bake's final reading would otherwise count as this one's first.
	sky.bake_us = 0.0
	if not sky.request_bake(main.cloud, main._theme_palette(), main.COLOUR_CYCLES[main.colour_idx]):
		print("SKYBAKE FAIL request_bake refused")
		_fails += 1
		return [0, 0.0, 0.0, 0, 0.0]
	main.sky_on = true
	var frames := 0
	var us := 0.0
	var us_n := 0
	var last_us := -1.0
	var max_us := 0.0
	while sky.baking and frames < 100000:
		await process_frame
		frames += 1
		peak = maxi(peak, rd.get_memory_usage(RenderingDevice.MEMORY_TOTAL))
		# bake_us is the previous bake frame's timestamps; count each reading once.
		if sky.bake_us > 0.0 and sky.bake_us != last_us:
			us += sky.bake_us
			us_n += 1
			last_us = sky.bake_us
			max_us = maxf(max_us, sky.bake_us)
	var wall := float(Time.get_ticks_usec() - t0) / 1000.0
	# The resolve frame's timestamps land a few frames after baking goes false.
	for i in 6:
		await process_frame
		if sky.bake_us > 0.0 and sky.bake_us != last_us:
			max_us = maxf(max_us, sky.bake_us)
			last_us = sky.bake_us
	return [frames, wall, us / maxf(1.0, us_n), peak, max_us]


func _measure(main, w: int) -> void:
	var rd := RenderingServer.get_rendering_device()
	var sky: FlameSky = main.flame_sky
	sky.set_width(w)
	for i in 10:
		await process_frame
	var before := rd.get_memory_usage(RenderingDevice.MEMORY_TOTAL)
	var r := await _run_bake(main)
	for i in 10:
		await process_frame
	var after := rd.get_memory_usage(RenderingDevice.MEMORY_TOTAL)
	var tex_mb := float(sky.width * sky.height * 8) / 1048576.0
	var acc_mb := float(sky.width * sky.height * 12) / 1048576.0
	print("SKYBAKE measure width=%d height=%d samples=%dM frames=%d quest_s_at_72hz=%.1f mac_wall_s=%.2f mac_gpu_us_per_frame=%.0f mac_gpu_us_longest=%.0f sky_mb=%.1f accumulator_mb=%.1f device_mb before=%.1f peak=%.1f after=%.1f" % [
		sky.width, sky.height, sky.samples / 1000000, r[0], float(r[0]) / 72.0, r[1] / 1000.0, r[2], r[4],
		tex_mb, acc_mb, before / 1048576.0, r[3] / 1048576.0, after / 1048576.0])
	if not sky.ready or r[0] == 0:
		_fails += 1
		print("SKYBAKE FAIL width %d never finished" % w)
	await _save_preview(main, "live_%d" % w)


## Offline: a big, many-sample bake of one flame, written out as raw half floats.
func _bake_out(main, flame: String, w: int, spt: float) -> void:
	var sky: FlameSky = main.flame_sky
	sky.set_width(w)
	sky.samples = int(float(sky.width) * float(sky.height) * spt)
	sky.rounds_per_frame = OFFLINE_ROUNDS
	var r := await _run_bake(main)
	sky.rounds_per_frame = FlameSky.ROUNDS_PER_FRAME
	print("SKYBAKE bake %s width=%d samples=%dM frames=%d mac_wall_s=%.1f mac_gpu_us_per_frame=%.0f" % [
		flame, sky.width, sky.samples / 1000000, r[0], r[1] / 1000.0, r[2]])
	var data := await _readback(sky)
	if data.size() != sky.width * sky.height * 8:
		print("SKYBAKE FAIL %s readback %d bytes" % [flame, data.size()])
		_fails += 1
		return
	var base := OUT + flame.to_lower()
	var f := FileAccess.open(base + ".rgbah", FileAccess.WRITE)
	f.store_buffer(data)
	f.close()
	var meta := {"name": flame, "width": sky.width, "height": sky.height, "samples": sky.samples,
		"frames": r[0], "mac_wall_s": r[1] / 1000.0, "exposure": sky.exposure, "k2": sky.k2,
		"gamma": sky.gamma, "palette": str(main._theme_palette())}
	var fm := FileAccess.open(base + ".json", FileAccess.WRITE)
	fm.store_string(JSON.stringify(meta))
	fm.close()
	print("SKYBAKE wrote %s.rgbah" % ProjectSettings.globalize_path(base))
	# The live path's picture of the same sky, for checking the cube against it.
	await _save_preview(main, "baked_%s" % flame.to_lower())


func _readback(sky: FlameSky) -> PackedByteArray:
	var holder := [PackedByteArray()]
	RenderingServer.call_on_render_thread(func():
		holder[0] = RenderingServer.get_rendering_device().texture_get_data(sky.sky_texture_rid(), 0))
	for i in 3:
		await process_frame
	return holder[0]


func _preview_presets(main, names: PackedStringArray) -> void:
	var sky: FlameSky = main.flame_sky
	print("SKYBAKE presets %s" % str(sky.presets.map(func(e): return e["name"])))
	if sky.presets.is_empty():
		print("SKYBAKE FAIL no presets imported")
		_fails += 1
		return
	main.sky_on = true
	for i in sky.presets.size():
		var n: String = str(sky.presets[i]["name"]).to_lower()
		if not names.is_empty() and not names.has(n):
			continue
		sky.set_pick(i + 1)
		var shown := false
		for f in 30:
			await process_frame
			shown = sky.is_shown()
		if sky.pick != i + 1 or not shown:
			print("SKYBAKE FAIL preset %s: pick %d shown %s" % [n, sky.pick, str(shown)])
			_fails += 1
			continue
		await _save_preview(main, "cube_%s" % n)
		print("SKYBAKE preview %s" % n)
	sky.set_pick(0)


## The sky from the LOOKS through the app's own sky shader, as the headset shows it.
func _save_preview(main, tag: String) -> void:
	var looks := LOOKS
	main.cloud.visible = false
	for k in looks:
		main.xr_camera.rotation_degrees = looks[k]
		for i in 8:
			await process_frame
		var t := Time.get_ticks_msec()
		while main.flame_sky._fade < 1.0 and Time.get_ticks_msec() - t < 4000:
			await process_frame
		root.get_viewport().get_texture().get_image().save_png(OUT + "%s_%s.png" % [tag, k])
	main.cloud.visible = true
	main.xr_camera.rotation_degrees = Vector3.ZERO
