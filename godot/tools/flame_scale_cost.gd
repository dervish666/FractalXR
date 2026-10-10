extends SceneTree

## What the flame at scale costs on this Mac, through the real main scene, unthrottled: GPU
## time of the main viewport's draw, the cloud's compute from its own timestamps, draw calls and
## primitives, per configuration. The hero at three particle counts gives a per-point draw
## slope, so the echoes can be read as a share of the hero's own cost.
##
## Mac numbers (Apple M1 Pro, Metal, mono 1280x800). Read the ratios, not the milliseconds: the
## Quest is a tiler running two eyes at ~1680 square, and README phase 2 found its point draw
## vertex-bound, which a desktop GPU is not.
##
##   tools/flame_scale_cost.sh

const FRAMES := 240
const FWD := Vector3(-8.0, 0.0, 0.0)
## Turned and raised, so most echoes are in the frustum and the hero is not.
const ROOM := Vector3(15.0, 30.0, 0.0)


func _init() -> void:
	var main = (load("res://main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	for i in 40:
		await process_frame
	main.help.close()
	main.xr_camera.position = Vector3(0.0, 1.6, 0.0)
	main.xr_camera.rotation_degrees = FWD
	main._drift = false
	main.spin = false
	for i in 240:
		await process_frame
	main._recenter()
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	var vp := root.get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(vp, true)

	# The hero alone at three counts: the slope is the per-point draw cost here.
	for k in [4, 0, 1]:
		main.particle_idx = k
		main.cloud.set_count(int(main.TEX_SIZE * main.TEX_SIZE * main.PARTICLE_STEPS[k]))
		await _measure(main, vp, "hero %s" % main._fmt_count(main.cloud.get_count()), FWD)
	main.particle_idx = 0
	main.cloud.set_count(int(main.TEX_SIZE * main.TEX_SIZE * main.PARTICLE_STEPS[0]))

	for v in {"fwd": FWD, "room": ROOM}:
		var look: Vector3 = FWD if v == "fwd" else ROOM
		main.flame_echoes.set_step(0)
		await _measure(main, vp, "echoes off  %s" % v, look)
		main._step_flame_echoes(1)
		await _measure(main, vp, "echoes four %s (%d pts)" % [v, main.flame_echoes.point_total()], look)
		main._step_flame_echoes(1)
		await _measure(main, vp, "echoes eight %s (%d pts)" % [v, main.flame_echoes.point_total()], look)
	main.flame_echoes.set_step(0)

	main.xr_camera.rotation_degrees = FWD
	main._toggle_galaxy()
	while main.galaxy.is_moving():
		await process_frame
	await _measure(main, vp, "galaxy inside", FWD)
	main._recenter()

	# The bake, from TREE, the way the SKY switch does it: the cloud is hidden and not iterating,
	# so the bake has the headroom the flame would otherwise be using. The tree finishes growing
	# first, so the on/off pairs below compare the same geometry.
	main._set_mode("tree")
	var tree_look := Vector3(25.0, 20.0, 0.0)
	main.xr_camera.rotation_degrees = tree_look
	var g0 := Time.get_ticks_msec()
	while main.tree.grow_progress() < 1.0 and Time.get_ticks_msec() - g0 < 30000:
		await process_frame
	await _measure(main, vp, "tree, sky off", tree_look)
	var t0 := Time.get_ticks_usec()
	main._toggle_sky()
	var frames := 0
	var us := 0.0
	var us_n := 0
	var walls: Array[float] = []
	var prev := Time.get_ticks_usec()
	while not main.flame_sky.ready and frames < 4000:
		await process_frame
		var now := Time.get_ticks_usec()
		walls.append(float(now - prev) / 1000.0)
		prev = now
		frames += 1
		if main.flame_sky.bake_us > 0.0:
			us += main.flame_sky.bake_us
			us_n += 1
	walls.sort()
	print("FLAMECOST sky bake: %d frames, %.0f ms wall; frame median %.2f ms, worst %.1f, second %.1f; bake GPU %s" % [
		frames, float(Time.get_ticks_usec() - t0) / 1000.0, walls[walls.size() / 2], walls[-1], walls[-2],
		"%.2f ms a frame" % (us / us_n / 1000.0) if us_n > 0 else "unavailable (no timestamps read)"])
	var w0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - w0 < 3000:
		await process_frame
	await _measure(main, vp, "tree, sky on", tree_look)
	main.sky_on = false
	await _measure(main, vp, "tree, sky off again", tree_look)
	main._set_mode("ifs")
	main.ifs.finish_grow()
	await _measure(main, vp, "ifs, sky off", tree_look)
	main.sky_on = true
	w0 = Time.get_ticks_msec()
	while Time.get_ticks_msec() - w0 < 3000:
		await process_frame
	await _measure(main, vp, "ifs, sky on", tree_look)
	print("FLAMECOST DONE")
	quit(0)


func _measure(main, vp: RID, label: String, look: Vector3) -> void:
	main.xr_camera.rotation_degrees = look
	for i in 30:
		await process_frame
	var gpu := 0.0
	var it := 0.0
	var draws := 0.0
	var prims := 0.0
	var w0 := Time.get_ticks_usec()
	for i in FRAMES:
		await process_frame
		gpu += RenderingServer.viewport_get_measured_render_time_gpu(vp)
		it += main.cloud.iterate_us
		draws += RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
		prims += RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
	var wall := float(Time.get_ticks_usec() - w0) / 1000.0 / FRAMES
	print("FLAMECOST %-34s frame %.3f ms  draw-gpu %s  sim %s  draws %.0f  prims %.0f" % [
		label, wall, "%.3f ms" % (gpu / FRAMES) if gpu > 0.0 else "unavailable",
		"%.3f ms" % (it / FRAMES / 1000.0) if it > 0.0 else "unavailable",
		draws / FRAMES, prims / FRAMES])
