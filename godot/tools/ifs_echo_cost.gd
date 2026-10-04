extends SceneTree

## What each ECHOES rung costs, through the real main scene: GPU time of the main viewport,
## draw calls, primitives, and the CPU time of IfsEchoes.advance(). Two views: the tabletop
## (hero in front, most echoes culled) and a turned, raised view where the room is all there
## is. Mac numbers, so read them as ratios between rungs, not as Quest milliseconds.
##
##   tools/ifs_echo_cost.sh

const FRAMES := 120
const VIEWS := {"table": Vector3(-19.0, 0.0, 0.0), "room": Vector3(25.0, 40.0, 0.0)}


func _init() -> void:
	var main = (load("res://main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	for i in 40:
		await process_frame
	main.help.close()
	main.xr_camera.position = Vector3(0.0, 1.6, 0.0)
	main.xr_camera.rotation_degrees = VIEWS["table"]
	for i in 40:
		await process_frame
	main._set_mode("ifs")
	for i in 20:
		await process_frame
	var vp := root.get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(vp, true)
	# Unthrottled, so wall time per frame is the work and not the display's refresh.
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	var ech: IfsEchoes = main.ifs_echoes
	for view in VIEWS:
		main.xr_camera.rotation_degrees = VIEWS[view]
		for step in [5, 0, 1, 2, 3, 4]:
			ech.set_step(step)
			for i in 20:
				await process_frame
			var gpu := 0.0
			var draws := 0.0
			var prims := 0.0
			var w0 := Time.get_ticks_usec()
			for i in FRAMES:
				await process_frame
				gpu += RenderingServer.viewport_get_measured_render_time_gpu(vp)
				draws += RenderingServer.get_rendering_info(
					RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
				prims += RenderingServer.get_rendering_info(
					RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
			var wall_ms := float(Time.get_ticks_usec() - w0) * 0.001 / FRAMES
			var t0 := Time.get_ticks_usec()
			for i in 1000:
				ech.advance(1.0 / 72.0)
			var cpu_us := float(Time.get_ticks_usec() - t0) / 1000.0
			print("IFSCOST view=%-5s step=%-5s echoes=%3d frames=%4d frame_ms=%.3f gpu_ms=%s draws=%.0f prims=%.0f advance_us=%.1f" % [
				view, ech.step_name(), ech.count(), ech.instance_total(), wall_ms,
				"%.3f" % (gpu / FRAMES) if gpu > 0.0 else "unavailable",
				draws / FRAMES, prims / FRAMES, cpu_us])
	print("IFSCOST DONE")
	quit(0)
