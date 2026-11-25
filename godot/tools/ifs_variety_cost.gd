extends SceneTree

## Desktop comparison at fixed resolution, camera and simulated motion rate.
## Optional baseline script is generated from git into ignored .spike-out by the caller.
## Run through env.sh with --rendering-method mobile --resolution 1280x800.
const SAMPLES := 240

func _init() -> void:
	await process_frame
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	var camera := Camera3D.new()
	camera.position = Vector3(3.4, 2.5, 4.3)
	root.add_child(camera)
	camera.look_at(Vector3.ZERO)
	var vp := root.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(vp, true)
	var paths := ["res://scripts/ifs/fractal_ifs.gd"]
	if FileAccess.file_exists("res://.spike-out/ifs-baseline.gd"):
		paths.push_front("res://.spike-out/ifs-baseline.gd")
	# Two passes, opposite order, reduce warm-up and ordering bias.
	for pass_ in 2:
		for path in paths:
			var f = load(path).new()
			root.add_child(f)
			f.visible = true
			f.set_echoes_live(false)
			for preset in [0, 2]:
				for moving in [false, true]:
					f.set_preset(preset)
					f.ambient = moving
					f.build(false)
					f.finish_grow()
					for i in 60:
						f.tick(1.0 / 72.0)
						await process_frame
					var gpu := 0.0
					var cpu := 0.0
					var tick_us := 0.0
					var start := Time.get_ticks_usec()
					for i in SAMPLES:
						var t0 := Time.get_ticks_usec()
						f.tick(1.0 / 72.0)
						tick_us += Time.get_ticks_usec() - t0
						await process_frame
						gpu += RenderingServer.viewport_get_measured_render_time_gpu(vp)
						cpu += RenderingServer.viewport_get_measured_render_time_cpu(vp)
					print("IFSVARIETYCOST pass=%d source=%s preset=%s moving=%s instances=%d triangles=%d wall_ms=%.3f cpu_render_ms=%.3f gpu_ms=%s tick_us=%.1f" % [
						pass_, "before" if "baseline" in path else "after", f.preset_name(preset), str(moving),
						f.instance_count, f.triangle_count, float(Time.get_ticks_usec() - start) / 1000.0 / SAMPLES,
						cpu / SAMPLES, "%.3f" % (gpu / SAMPLES) if gpu > 0 else "unavailable", tick_us / SAMPLES])
			f.free()
		paths.reverse()
	print("IFSVARIETYCOST DONE desktop only")
	quit()
