extends SceneTree

## FLY spike harness. Loads Classic through the real main scene, picks FLY, finds a
## point on the surface with the CPU DE, then for each shrink stands the eye 45 cm off
## that point (in world metres, so every shot frames the same amount of space) and
## shoots, into .spike-out/fly/:
##   fly_<across>.png        the stack
##   fly_<across>_tint.png   the stack, each level tinted (base red, then green, blue...)
##   solid_<across>.png      SOLID 192 alone from the same eye: what shrinking gave before
##   march_<across>.png      the marcher at 80 steps, the per-pixel reference
## <across> is the bulb's width in metres at that shrink. Prints the stack's levels,
## triangles and build time per shot, and with FLY_DRIVER=vulkan one Quest-sized eye's
## GPU time for the stack and for SOLID alone.
##
##   tools/fly_shot.sh                 everything
##   tools/fly_shot.sh -- quick        two shrinks, no marcher, no timing

const OUT := "res://.spike-out/fly/"
const ACROSS_M := [0.35, 3.0, 25.0, 200.0, 1600.0]
const STANDOFF_M := 0.45
const EYE := Vector2i(1680, 1760)
const EYE_FOV := 96.0

var main: Node
var eye_vp: SubViewport
var eye_cam: Camera3D
var last_prims := 0


func _init() -> void:
	var quick := OS.get_cmdline_user_args().has("quick")
	var spires_only := OS.get_cmdline_user_args().has("spires")
	var vault_only := OS.get_cmdline_user_args().has("vault")
	var style := 0
	for k in FractalMain.FLY_STYLE_NAMES.size():
		if OS.get_cmdline_user_args().has(str(FractalMain.FLY_STYLE_NAMES[k])):
			style = k
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var scene: PackedScene = load("res://main.tscn")
	main = scene.instantiate()
	root.add_child(main)
	main.fly_style = style
	for i in 40:
		await process_frame
	main.help.close()
	main.xr_camera.position = Vector3(0.0, 1.6, 0.0)
	main.xr_camera.rotation = Vector3.ZERO
	for i in 3:
		await process_frame
	main._set_mode("bulb")
	main.spin = false
	main._drift = false
	main.breath_idx = main.BREATH_STEPS.find(0.0)
	main._load_bulb(_bulb_index("Classic"))
	main._bulb.clock = 0.0
	for i in 400:
		await process_frame
	main.surface_idx = main.SURFACE_FLY_IDX
	main._apply_surface()
	var frames := 0
	while not main.solid.is_ready() and frames < 3000:
		await process_frame
		frames += 1
	if not main.solid.is_ready():
		print("FLYSHOT FAIL base never built: %s" % main.solid.get_error())
		quit(1)
		return
	print("FLYSHOT base ready after %d frames, %d tris" % [frames, main.solid.tri_count])
	var fly: BulbFly = main.fly
	if spires_only or vault_only:
		var good := await _spires(BulbFly.World.VAULT if vault_only else BulbFly.World.SPIRES)
		print("FLYSHOT %s" % ("PASS" if good else "FAIL"))
		quit(0 if good else 1)
		return
	var surf := _surface_point()
	print("FLYSHOT surface point %s de %.7f" % [str(surf[0]), fly.de(surf[0])])

	var ok := true
	var list: Array = [ACROSS_M[1], ACROSS_M[3]] if quick else ACROSS_M
	for across: float in list:
		var tag := _tag(across)
		_pose(surf, across)
		frames = 0
		var t0 := Time.get_ticks_msec()
		# A frame or two for update() to see the new scale, then wait for the stack.
		for i in 3:
			_pose(surf, across)
			await process_frame
		while not fly.is_settled() and frames < 4000:
			_pose(surf, across)
			await process_frame
			frames += 1
		for i in 10:
			_pose(surf, across)
			await process_frame
		var settled := fly.is_settled()
		ok = ok and settled
		print("FLYSHOT %s across=%.2fm s2w=%.1f %s settled=%s in %d frames (%d ms)" % [
			tag, across, main._fly_s2w(), fly.describe(), str(settled), frames,
			Time.get_ticks_msec() - t0])
		for k in fly.want:
			var s: BulbSolid = fly.levels[k]
			if s.is_ready():
				print("FLYSHOT   L%d gpu %.1f ms wall %.0f ms upload %.1f ms, %d tris%s" % [
					k + 1, s.gpu_ms, s.wall_ms, s.upload_ms, s.tri_count,
					" OVERFLOW" if s.overflow else ""])
		_shot("fly_%s.png" % tag)
		if not quick:
			print("FLYSHOT %s eye fly ms=%.3f prims=%d" % [tag, await _time_eye(surf, across), last_prims])
		fly.tint_levels = true
		await _frames(surf, across, 3)
		_shot("fly_%s_tint.png" % tag)
		fly.tint_levels = false
		fly.show_levels = false
		await _frames(surf, across, 3)
		_shot("solid_%s.png" % tag)
		if not quick:
			print("FLYSHOT %s eye solid ms=%.3f prims=%d" % [tag, await _time_eye(surf, across), last_prims])
		fly.show_levels = true

	ok = await _flight(surf) and ok

	if not quick:
		# The marcher from the same eyes. Leaving FLY ends the stack.
		main.surface_idx = main.SURFACE_STEPS.find(80)
		main._apply_surface()
		for across: float in list:
			await _frames(surf, across, 30)
			_shot("march_%s.png" % _tag(across))
			print("FLYSHOT %s march surface=%s" % [_tag(across), main.SURFACE_NAMES[main.surface_idx]])
	print("FLYSHOT %s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)


func _tag(across: float) -> String:
	return ("%.2f" % across).replace(".", "p") if across < 1.0 else "%d" % int(across)


func _frames(surf: Array, across: float, n: int) -> void:
	for i in n:
		_pose(surf, across)
		await process_frame


func _bulb_index(bname: String) -> int:
	for i in main.library.bulbs.size():
		if main.library.bulbs[i].get("name", "") == bname:
			return i
	return 0


## March a CPU ray in from outside along a fixed direction until it touches the surface.
## Returns [point, outward direction, a tangent].
func _surface_point() -> Array:
	var fly: BulbFly = main.fly
	var d := Vector3(0.35, 0.55, 0.76).normalized()
	var t := BulbSolid.extent_of(main._bulb) * 1.2
	for i in 2000:
		var e := fly.de(d * t)
		if e < 1e-6:
			break
		t -= e * 0.8
	var p := d * t
	var tan := d.cross(Vector3.UP).normalized()
	return [p, d, tan]


## The eye STANDOFF_M from the surface point, off to one side so the shot looks across the
## surface, the world scaled so the bulb is `across` metres wide.
func _pose(surf: Array, across: float) -> void:
	var p: Vector3 = surf[0]
	var d: Vector3 = surf[1]
	var tan: Vector3 = surf[2]
	var c: Node3D = main.cloud
	var fly: BulbFly = main.fly
	var fit: float = fly.fit
	var ctr: Vector3 = fly.center
	var s2w := across / (2.0 * BulbSolid.extent_of(main._bulb))
	var head_state := p + (d * 0.75 + tan * 0.55).normalized() * (STANDOFF_M / s2w)
	var cam_pos := Vector3(0.0, 1.6, 0.0)
	var k := s2w / fit
	c.global_transform = Transform3D(Basis().scaled(Vector3.ONE * k),
		cam_pos - s2w * (head_state - ctr))
	main.xr_camera.position = cam_pos
	main.xr_camera.fov = 80.0
	var target: Vector3 = c.global_transform * ((p - ctr) * fit)
	main.xr_camera.look_at(target, Vector3.UP)


func _shot(file: String) -> void:
	var img := root.get_viewport().get_texture().get_image()
	img.save_png(OUT + file)
	print("FLYSHOT shot %s" % file)


## One Quest-sized eye from the harness camera: the quietest of four windows of mean GPU ms.
func _time_eye(surf: Array, across: float) -> float:
	if eye_vp == null:
		eye_vp = SubViewport.new()
		eye_vp.size = EYE
		eye_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		eye_vp.msaa_3d = Viewport.MSAA_4X
		eye_cam = Camera3D.new()
		eye_cam.fov = EYE_FOV
		eye_cam.near = 0.05
		eye_vp.add_child(eye_cam)
		root.add_child(eye_vp)
		RenderingServer.viewport_set_measure_render_time(eye_vp.get_viewport_rid(), true)
	var best := INF
	for w in 4:
		var acc := 0.0
		for i in 15:
			_pose(surf, across)
			eye_cam.global_transform = main.xr_camera.global_transform
			await process_frame
			acc += RenderingServer.viewport_get_measured_render_time_gpu(eye_vp.get_viewport_rid())
		best = minf(best, acc / 15.0)
	last_prims = eye_vp.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE,
		Viewport.RENDER_INFO_PRIMITIVES_IN_FRAME)
	return snappedf(best, 0.001)


## Drive FLY's own stick code from the 200 m pose: full right stick toward the surface for
## four seconds of 72 Hz frames, then full left stick for two. Passes if the clearance never
## drops under FLY_MIN_CLEAR_M, the flight slows as it closes, the shrink is 2^(0.7 * 2),
## and the stack keeps up (frames unsettled are printed, not gated).
func _flight(surf: Array) -> bool:
	var fly: BulbFly = main.fly
	await _frames(surf, 200.0, 5)
	var dt := 1.0 / 72.0
	var s2w: float = main._fly_s2w()
	var min_clear := INF
	var unsettled := 0
	var speeds: Array[float] = []
	var last: Vector3 = main._fly_head_state()
	var start_clear: float = fly.de(last) * s2w
	for i in 288:
		main._fly_sticks(Vector2(0.0, 1.0), Vector2.ZERO, 0.0, false, dt)
		await process_frame
		var st: Vector3 = main._fly_head_state()
		min_clear = minf(min_clear, fly.de(st) * s2w)
		if i % 72 == 71:
			speeds.append((st - last).length() * s2w / (72.0 * dt))
			last = st
		if not fly.is_settled():
			unsettled += 1
	var s0: float = main.cloud.global_transform.basis.get_scale().x
	for i in 144:
		main._fly_sticks(Vector2.ZERO, Vector2(0.0, 1.0), 0.0, false, dt)
		await process_frame
	var ratio: float = main.cloud.global_transform.basis.get_scale().x / s0
	var want: float = pow(2.0, main.FLY_OCTAVES_PER_S * 2.0)
	# The DE reads about half the true distance on a Mandelbulb, so the pose can start under
	# the floor; then flight may only have held the clearance it started with.
	var good: bool = min_clear >= minf(start_clear, main.FLY_MIN_CLEAR_M) * 0.98 and absf(ratio / want - 1.0) < 0.02 \
		and speeds.size() == 4 and speeds[3] <= speeds[0]
	_shot("flight_end.png")
	print("FLYSHOT flight start_clear=%.3fm min_clear=%.3fm (floor %.2f) speeds m/s=%s unsettled=%d/288 shrink=%.3f (want %.3f) %s %s" % [
		start_clear, min_clear, main.FLY_MIN_CLEAR_M, str(speeds.map(func(v): return snappedf(v, 0.01))),
		unsettled, ratio, want, fly.describe(), "PASS" if good else "FAIL"])
	return good


## SPIRES: WORLD to the city, then four views from where it puts you, the same after
## shrinking 8x, and four seconds of flight straight ahead with the clearance tracked.
func _spires(w: BulbFly.World) -> bool:
	var fly: BulbFly = main.fly
	main.xr_camera.position = Vector3(0.0, 1.6, 0.0)
	main.xr_camera.rotation = Vector3.ZERO
	main.xr_camera.fov = 80.0
	main._set_fly_world(w)
	var wn: String = main.FLY_WORLD_NAMES[w] + ("_" + main.FLY_STYLE_NAMES[main.fly_style] if main.fly_style > 0 else "")
	var good := true
	for shrink in [1.0, 8.0]:
		if shrink > 1.0:
			var head: Vector3 = main.xr_camera.global_transform.origin
			main.cloud.global_transform = Transform3D(Basis().scaled(Vector3.ONE * shrink),
				head - head * shrink) * main.cloud.global_transform
		var frames := 0
		var t0 := Time.get_ticks_msec()
		for i in 3:
			await process_frame
		while not fly.is_settled() and frames < 4000:
			await process_frame
			frames += 1
		for i in 10:
			await process_frame
		good = good and fly.is_settled()
		print("FLYSHOT %s x%d unit=%.2fm %s settled=%s in %d frames (%d ms) clear=%.2fm" % [
			wn, int(shrink), main._fly_s2w(), fly.describe(), str(fly.is_settled()), frames,
			Time.get_ticks_msec() - t0, fly.de(main._fly_head_state()) * main._fly_s2w()])
		for v in [["ahead", 0.0, 0.0], ["up", 35.0, 0.0], ["down", -40.0, 0.0], ["back", 0.0, 150.0]]:
			main.xr_camera.rotation_degrees = Vector3(v[1], v[2], 0.0)
			for i in 3:
				await process_frame
			_shot("%s_x%d_%s.png" % [wn, int(shrink), v[0]])
		main.xr_camera.rotation = Vector3.ZERO
		if shrink == 1.0:
			# Per-pixel shadows off for the before, then which pixels march (debug 4), and
			# with FLY_DRIVER=vulkan one Quest-sized eye's GPU time each way.
			for on in [false, true]:
				fly.pixel_shadows = on
				for s in fly._chain():
					s.material().set_shader_parameter("pixel_shadow", 1 if on else 0)
				main.xr_camera.rotation_degrees = Vector3(-40.0, 0.0, 0.0)
				for i in 3:
					await process_frame
				_shot("%s_x1_down_px%d.png" % [wn, int(on)])
				print("FLYSHOT " + wn + " eye pixel_shadow=%s ms=%.3f" % [str(on), await _time_eye_here()])
			for dv in [[4, "marching"], [2, "shadow"], [5, "albedo"]]:
				for s in fly._chain():
					s.material().set_shader_parameter("debug_view", dv[0])
				await process_frame
				await process_frame
				_shot("%s_x1_down_%s.png" % [wn, dv[1]])
			for s in fly._chain():
				s.material().set_shader_parameter("debug_view", 0)
			main.xr_camera.rotation = Vector3.ZERO
		fly.tint_levels = true
		for i in 3:
			await process_frame
		_shot("%s_x%d_tint.png" % [wn, int(shrink)])
		fly.tint_levels = false
	# Flight: right stick forward for four seconds of 72 Hz frames.
	var dt := 1.0 / 72.0
	var s2w: float = main._fly_s2w()
	var start: Vector3 = main._fly_head_state()
	var start_clear := fly.de(start) * s2w
	var min_clear := INF
	var unsettled := 0
	for i in 288:
		main._fly_sticks(Vector2(0.0, 1.0), Vector2.ZERO, 0.0, false, dt)
		await process_frame
		min_clear = minf(min_clear, fly.de(main._fly_head_state()) * s2w)
		if not fly.is_settled():
			unsettled += 1
	var moved: float = (main._fly_head_state() - start).length() * s2w
	_shot("%s_flight_end.png" % wn)
	var ok_flight: bool = min_clear >= minf(start_clear, main.FLY_MIN_CLEAR_M) * 0.98 and moved > 0.05
	print("FLYSHOT %s flight moved=%.2fm start_clear=%.2fm min_clear=%.3fm unsettled=%d/288 %s %s" % [
		wn, moved, start_clear, min_clear, unsettled, fly.describe(), "PASS" if ok_flight else "FAIL"])
	return good and ok_flight


## _time_eye without re-posing: the eye wherever the harness camera stands now.
func _time_eye_here() -> float:
	if eye_vp == null:
		eye_vp = SubViewport.new()
		eye_vp.size = EYE
		eye_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		eye_vp.msaa_3d = Viewport.MSAA_4X
		eye_cam = Camera3D.new()
		eye_cam.fov = EYE_FOV
		eye_cam.near = 0.05
		eye_vp.add_child(eye_cam)
		root.add_child(eye_vp)
		RenderingServer.viewport_set_measure_render_time(eye_vp.get_viewport_rid(), true)
	eye_cam.global_transform = main.xr_camera.global_transform
	var best := INF
	for w in 4:
		var acc := 0.0
		for i in 15:
			await process_frame
			acc += RenderingServer.viewport_get_measured_render_time_gpu(eye_vp.get_viewport_rid())
		best = minf(best, acc / 15.0)
	return snappedf(best, 0.001)
