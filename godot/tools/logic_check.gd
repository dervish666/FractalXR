extends SceneTree

## main.gd's own logic, through the real scene: the [resume] parser against a scratch file, the
## splat guard fed synthetic frame times, the drift's stride, the snap turn's re-arm and what it
## does to the world in a surround mode, and IFS RESET then UNDO. Each piece is driven by calling
## main directly between frames, so the scene's own _process cannot interleave with a sequence.
## The broken control is a steady 72 fps run put through the guard's "it cut" assertion: it has
## to fail, or the assertion cannot tell a cut from no cut.
##
##   tools/logic_check.sh

const STATE := "res://.spike-out/logic_state.cfg"

var _fails := 0


func _init() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(STATE))
	var scene: PackedScene = load("res://main.tscn")
	if scene == null:
		print("LOGICCHECK FAIL: main.tscn would not load")
		quit(1)
		return
	var main = scene.instantiate()
	# Before _ready, so the help card's seen flag and any resume write land in the scratch file and
	# never in the real user:// one every desktop harness shares.
	main.state_path = STATE
	root.add_child(main)
	for i in 40:
		await process_frame
	if not main._setup_done:
		print("LOGICCHECK FAIL: the scene never finished setting up")
		quit(1)
		return
	main.help.close()
	for i in 20:
		await process_frame

	_resume(main)
	var control_cut := _guard(main)
	_stride()
	_snap(main)
	await _surround(main)
	await _tracking_snap(main)
	await _reset_undo(main)
	await _edit_focus(main)
	await _owners(main)
	await _unfocused(main)

	print("LOGICCHECK control=%s (a steady 72 fps run must not pass as a cut)" % (
		"PASS" if control_cut else "FAIL"))
	if control_cut:
		_fails += 1
	print("LOGICCHECK %s failures=%d control=%s" % [
		"PASS" if _fails == 0 else "FAIL", _fails, "PASS" if control_cut else "FAIL"])
	quit(0 if _fails == 0 else 1)


func _ok(name: String, pass_: bool, detail: String) -> void:
	if not pass_:
		_fails += 1
	print("LOGICCHECK %-22s %s  %s" % [name, "PASS" if pass_ else "FAIL", detail])


# --- resume -----------------------------------------------------------------

func _write_state(values: Dictionary) -> void:
	var cfg := ConfigFile.new()
	for k in values:
		cfg.set_value("resume", k, values[k])
	cfg.save(STATE)


func _resume(main) -> void:
	main.resume_on = true
	DirAccess.remove_absolute(ProjectSettings.globalize_path(STATE))
	var r: Dictionary = main._read_resume()
	_ok("resume missing file", r["mode"] == "flame" and r["flame"] == 0 and r["pinned"] == false,
		"mode=%s flame=%s pinned=%s" % [r["mode"], r["flame"], r["pinned"]])

	var dflt_bulb: int = main.bulb_idx
	_write_state({"mode": 3, "bulb": "two", "passthrough": 1, "pinned": "yes"})
	r = main._read_resume()
	_ok("resume bad type", r["mode"] == "flame" and r["bulb"] == dflt_bulb \
		and r["passthrough"] == false and r["pinned"] == false,
		"mode=%s bulb=%s passthrough=%s pinned=%s" % [r["mode"], r["bulb"], r["passthrough"], r["pinned"]])

	var dflt_tree: int = main.tree_shape_idx
	var dflt_theme: int = main.theme_idx
	_write_state({"mode": "orbit", "tree": 999, "theme": -2, "flame": -1,
		"cycle": main.CYCLE_STEPS.size()})
	r = main._read_resume()
	_ok("resume out of range", r["mode"] == "flame" and r["tree"] == dflt_tree \
		and r["theme"] == dflt_theme and r["flame"] == 0 and r["cycle"] != main.CYCLE_STEPS.size(),
		"mode=%s tree=%s theme=%s flame=%s cycle=%s" % [r["mode"], r["tree"], r["theme"], r["flame"], r["cycle"]])

	var good := {"mode": "tree", "flame": main.library.count() - 1, "bulb": 1, "theme": -1,
		"passthrough": true, "pinned": true, "cycle": 2}
	_write_state(good)
	r = main._read_resume()
	var same := true
	for k in good:
		same = same and r[k] == good[k]
	_ok("resume good values", same, str(r))
	# Off again, or the once-a-second save would write this session over the scratch file.
	main.resume_on = false


# --- the splat guard --------------------------------------------------------

func _guard_clear(main) -> void:
	main._perf_scale = 1.0
	main.cloud.set_perf_scale(1.0)
	main._fps_ema = 72.0
	main._guard_hold = 0.0
	main._guard_long = 0
	main._guard_reset()


## Feed the guard `frames` (seconds each) and report whether it cut.
func _guard_cuts(main, frames: Array) -> bool:
	_guard_clear(main)
	for dt in frames:
		main._run_guard(dt)
	return main._perf_scale < 1.0


func _repeat(pattern: Array, n: int) -> Array:
	var out := []
	for i in n:
		out.append_array(pattern)
	return out


## Returns whether the control passed as a cut, which it must not.
func _guard(main) -> bool:
	var was_splat: bool = main.splat_on
	main.splat_on = true
	main.cloud.set_visible_cloud(true)

	var cut := _guard_cuts(main, _repeat([1.0 / 40.0], 60))
	_ok("guard sustained cut", cut, "40 fps x60 -> scale %.2f" % main._perf_scale)
	# Hysteresis: between the lines it neither cuts again nor creeps back, hold or no hold.
	var held: float = main._perf_scale
	for i in 300:
		main._run_guard(1.0 / 62.0)
	_ok("guard hysteresis", is_equal_approx(main._perf_scale, held),
		"62 fps x300 after a cut: %.3f -> %.3f" % [held, main._perf_scale])

	# A cut that lands the rate just over the line (45 -> 58.5 fps) is one cut. The average used
	# to start from the dip and take ~0.56 s to climb past the line, long enough for a second.
	_guard_clear(main)
	for i in 200:
		main._run_guard(1.0 / 45.0)
		if main._perf_scale < 1.0:
			break   # the cut has landed; from here the frame rate is the cut's
	var once: float = main._perf_scale
	for i in 60:
		main._run_guard(1.0 / 58.5)
	_ok("guard one cut per dip", once < 1.0 and is_equal_approx(main._perf_scale, once),
		"45 fps then 58.5 fps x60: %.3f -> %.3f" % [once, main._perf_scale])

	cut = _guard_cuts(main, _repeat([0.0139, 0.0278], 40))
	_ok("guard alternating 1:1", cut, "13.9/27.8 ms -> scale %.2f" % main._perf_scale)
	# Two fast and one slow: the smoothed rate stays above the line (mean 60 fps), so only the
	# window can see it. The old run-length counter reset on every fast frame and never cut.
	cut = _guard_cuts(main, _repeat([0.0139, 0.0139, 0.0278], 30))
	_ok("guard alternating 2:1", cut and main._fps_ema > main.GUARD_CUT_SHARE * 72.0,
		"scale %.2f, ema %.1f fps" % [main._perf_scale, main._fps_ema])

	var stalls := _repeat([1.0 / 72.0], 9)
	stalls.append(0.2)
	cut = _guard_cuts(main, _repeat(stalls, 20))
	_ok("guard lone stall", not cut, "one 200 ms frame in ten, x20 -> scale %.2f" % main._perf_scale)
	cut = _guard_cuts(main, _repeat([0.2], 12))
	_ok("guard 5 fps sustained", cut, "200 ms x12 -> scale %.2f" % main._perf_scale)

	# A bulb drawn MARCHED or SOLID: splat_on, cloud hidden. Neither cut nor reset to 1.
	_guard_clear(main)
	main._perf_scale = 0.5
	main.cloud.set_visible_cloud(false)
	for i in 120:
		main._run_guard(1.0 / 30.0)
	_ok("guard hidden splats", is_equal_approx(main._perf_scale, 0.5) and main._guard_slow_s == 0.0,
		"30 fps x120 hidden -> scale %.2f slow %.2fs" % [main._perf_scale, main._guard_slow_s])
	main.cloud.set_visible_cloud(true)

	var control := _guard_cuts(main, _repeat([1.0 / 72.0], 120))
	_guard_clear(main)
	main.splat_on = was_splat
	return control


# --- drift stride -----------------------------------------------------------

func _stride() -> void:
	var bad := []
	for n in range(1, 64):
		var s := FractalMain._drift_stride(n)
		var ok := s == 1 if n <= 2 else (s >= 1 and s < n and FractalMain._gcd(s, n) == 1)
		if not ok:
			bad.append("%d->%d" % [n, s])
	_ok("drift stride coprime", bad.is_empty(), "n=1..63 %s" % (str(bad) if not bad.is_empty() else "all coprime"))


# --- snap turn --------------------------------------------------------------

func _snap(main) -> void:
	main._snap_armed = true
	var got := []
	for step in [[0.8, true], [0.8, true], [0.5, true], [0.8, true], [0.2, true], [-0.8, true],
			[0.1, false], [0.9, false], [0.9, true], [0.2, true], [0.9, true]]:
		got.append(main._snap_step(step[0], step[1]))
	# The push held through a grab (can_fire false) is spent: releasing the grip with the stick
	# still over must not snap. Centring the stick re-arms it as usual.
	var want := [1, 0, 0, 0, 0, -1, 0, 0, 0, 0, 1]
	_ok("snap re-arm", got == want, "got %s want %s" % [str(got), str(want)])


## The stick in a surround mode (the grove): one 30 degree snap about the head for a held push,
## nothing more until it comes back, and the walk's tunnel while it pushes. A hand-sized flame
## still turns smoothly. Driven through the desktop arrows, which _handle_input reads as the
## right stick when there is no XR.
func _surround(main) -> void:
	main._set_mode("tree")
	for i in 8:
		await process_frame
	var head: Vector3 = main.xr_camera.global_transform.origin
	var before: Transform3D = main.cloud.global_transform
	main._snap_armed = true
	Input.action_press("ui_right")
	for i in 6:
		main._handle_input(1.0 / 72.0)
	Input.action_release("ui_right")
	var after: Transform3D = main.cloud.global_transform
	var yaw := wrapf(after.basis.get_euler().y - before.basis.get_euler().y, -PI, PI)
	var d0 := Vector2(before.origin.x - head.x, before.origin.z - head.z).length()
	var d1 := Vector2(after.origin.x - head.x, after.origin.z - head.z).length()
	_ok("surround snap", is_equal_approx(absf(yaw), main.SNAP_TURN_RAD) and absf(d1 - d0) < 1e-3,
		"yaw %.1f deg over 6 held frames, head distance %.3f -> %.3f" % [rad_to_deg(yaw), d0, d1])
	main._handle_input(1.0 / 72.0)
	_ok("surround re-armed", main._snap_armed, "stick released")

	main._vig_motion = 0.0
	Input.action_press("ui_up")
	main._handle_input(1.0 / 72.0)
	Input.action_release("ui_up")
	_ok("surround push tunnel", main._vig_motion > 0.9 and main._vig_profile == ComfortVignette.WALK,
		"motion %.2f" % main._vig_motion)
	main._vig_motion = 0.0

	main._set_mode("flame")
	for i in 8:
		await process_frame
	before = main.cloud.global_transform
	Input.action_press("ui_right")
	main._handle_input(1.0 / 72.0)
	Input.action_release("ui_right")
	yaw = absf(wrapf(main.cloud.global_transform.basis.get_euler().y - before.basis.get_euler().y, -PI, PI))
	_ok("flame smooth turn", yaw > 0.0 and yaw < 0.1, "one frame turned %.2f deg" % rad_to_deg(yaw))


## Missing tracking must not stand in for a centred stick, even across focus recovery.
func _tracking_snap(main) -> void:
	main._set_mode("tree")
	for i in 8:
		await process_frame
	main.help.close()
	main._menu_active = false
	var saved_xr = main.xr
	main.xr = XRServer.find_interface("OpenXR")
	var tracker := XRControllerTracker.new()
	tracker.name = main.right_hand.tracker
	tracker.type = XRServer.TRACKER_CONTROLLER
	var saved_tracker = XRServer.get_tracker(tracker.name)
	for focus_loss in [false, true]:
		XRServer.add_tracker(tracker)
		tracker.set_pose(main.right_hand.pose, Transform3D.IDENTITY, Vector3.ZERO,
			Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
		tracker.set_input(&"primary", Vector2(0.9, 0.0))
		main._snap_armed = true
		if focus_loss:
			main._on_session_unfocused()
		XRServer.remove_tracker(tracker)
		if focus_loss:
			main._on_session_focussed()
		var before: Transform3D = main.cloud.global_transform
		main._handle_input(1.0 / 72.0)
		var disarmed: bool = not main._snap_armed and not main.right_hand.get_has_tracking_data()
		XRServer.add_tracker(tracker)
		main._handle_input(1.0 / 72.0)
		var held_still: bool = main.cloud.global_transform.is_equal_approx(before)
		var tracked: bool = main.right_hand.get_has_tracking_data()
		tracker.set_input(&"primary", Vector2.ZERO)
		main._handle_input(1.0 / 72.0)
		tracker.set_input(&"primary", Vector2(0.9, 0.0))
		for i in 3:
			main._handle_input(1.0 / 72.0)
		var yaw := wrapf(main.cloud.basis.get_euler().y - before.basis.get_euler().y, -PI, PI)
		_ok("snap tracking " + ("focus" if focus_loss else "loss"),
			disarmed and tracked and held_still and is_equal_approx(yaw, main.SNAP_TURN_RAD),
			"disarmed=%s tracked=%s held_still=%s fresh=%.1f deg" % [
				disarmed, tracked, held_still, rad_to_deg(yaw)])
		XRServer.remove_tracker(tracker)
	if saved_tracker != null:
		XRServer.add_tracker(saved_tracker)
	main.xr = saved_xr


func _edit_focus(main) -> void:
	main._set_mode("ifs")
	for i in 8:
		await process_frame
	main._reset_ifs()
	main.ifs_edit.set_guides(true)
	main.help.close()
	main._menu_active = false
	var hand_before: Transform3D = main.right_hand.global_transform
	main.right_hand.global_position = main.ifs.global_transform * Vector3(0.0, IfsEditor.KNOB_OUT, 0.0)
	main._trig = [false, true]
	main._trig_held = [false, true]
	main._ifs_edit_pass()
	_ok("edit focus captured", main.ifs_edit.held_handle() == IfsEditor.PLANE_A,
		"real editor picked PLANE A")
	var before: Dictionary = main.ifs_edit._params()
	# No frame may cancel the edit between these signals.
	main._on_session_unfocused()
	main._on_session_focussed()
	main.right_hand.global_position += main.ifs.global_basis * (main.ifs.plane1_normal * 0.2)
	main._trig = [false, false]
	main._ifs_edit_pass()
	_ok("edit focus no frame", not main.ifs_edit.is_editing() and main.ifs_edit._params() == before,
		"plane offset %.2f -> %.2f" % [before["plane1_offset"], main.ifs.plane1_offset])
	main.ifs_edit.cancel()
	main.ifs_edit.set_guides(false)
	main._trig_held = [false, false]
	main.right_hand.global_transform = hand_before


# --- IFS RESET then UNDO ----------------------------------------------------

func _reset_undo(main) -> void:
	main._set_mode("ifs")
	for i in 8:
		await process_frame
	var ifs: FractalIFS = main.ifs
	ifs.plane1_offset = 0.12
	main._step_ifs_depth(1)
	main._step_ifs_detail(1)
	var want := {"offset": ifs.plane1_offset, "depth": ifs.depth, "detail": ifs.detail,
		"depth_idx": main.ifs_depth_idx, "detail_idx": main.ifs_detail_idx}
	main._reset_ifs()
	var reset_ok: bool = ifs.plane1_offset == 0.0 and ifs.depth == 1.0 and main.ifs_depth_idx == 0
	main.ifs_edit.undo()
	var got := {"offset": ifs.plane1_offset, "depth": ifs.depth, "detail": ifs.detail,
		"depth_idx": main.ifs_depth_idx, "detail_idx": main.ifs_detail_idx}
	_ok("reset then undo", reset_ok and got == want, "want %s got %s" % [str(want), str(got)])

	# Stretch alone is a sculpt too: RESET has to leave an UNDO for it.
	main._reset_ifs()
	main.ifs_edit.clear_undo()
	main._step_ifs_depth(2)
	var depth: float = ifs.depth
	main._reset_ifs()
	var had: bool = main.ifs_edit.has_undo()
	main.ifs_edit.undo()
	_ok("stretch-only undo", had and ifs.depth == depth and main.ifs_depth_idx == 2,
		"undo offered %s, depth %.2f idx %d" % [str(had), ifs.depth, main.ifs_depth_idx])
	main._set_mode("flame")
	for i in 4:
		await process_frame


# --- higher owners stop the ground ---------------------------------------------

## A trigger glide and a ground grip both stop when the help card takes input. The glide used
## to carry on at 1.5 m/s under the card, and a grip held through it jumped by every move the
## hand made meanwhile. The first frame (card closed) proves the check can see a live glide.
func _owners(main) -> void:
	main._set_mode("ground")
	for i in 8:
		await process_frame
	main.help.close()
	main.ground.glide_to(main.ground._head_xz + Vector2(3.0, 0.0))
	main._process_frame(1.0 / 72.0)
	var live: bool = main.ground._glide.length() > 0.5
	main._gg_hands.assign([1])
	main.help.open()
	main._process_frame(1.0 / 72.0)
	_ok("glide under help", live and main.ground._glide == Vector2.ZERO,
		"live before %s, left %.2f m" % [live, main.ground._glide.length()])
	_ok("ground grip under help", main._gg_hands.is_empty(), "held hands %d" % main._gg_hands.size())
	main.help.close()
	main.ground.stop_glide()


# --- session focus -------------------------------------------------------------

func _focus_safe(main) -> bool:
	return not main.plant_marker.visible and not main.orbit.visible \
		and main.grab.suspended and not main.grab.is_grabbing() \
		and not main._snap_armed and not main.menu.visible and not main.help.visible


func _unfocused(main) -> void:
	var xri := XRServer.find_interface("OpenXR") as OpenXRInterface
	_ok("focus signals available", xri != null and xri.has_signal("session_loss_pending"),
		"installed OpenXR interface exposes loss pending")
	if xri == null:
		return
	main.help.close()
	main.help.update(1.0)
	main._set_mode("tree")
	for i in 8:
		await process_frame
	main.menu.set_suspended(true)
	main.right_hand.global_transform = Transform3D(Basis(Vector3.RIGHT, -PI / 4.0), Vector3(0.5, 1.0, -0.5))
	main._menu_active = false
	main._tick_plant_marker(1.0)
	_ok("plant focus live control", main.plant_marker.visible, "tracked floor hit shows planting ring")
	# This is the same predicate used after every focus-loss signal. A visible marker must fail it.
	main.grab.suspended = true
	main._snap_armed = false
	var broken := _focus_safe(main)
	_ok("focus broken control", not broken, "focus safety control=%s" % ("PASS" if broken else "FAIL"))
	for signal_name in ["session_visible", "session_stopping", "session_loss_pending"]:
		xri.emit_signal("session_focussed")
		main.help.open()
		main.help.update(1.0)
		main.plant_marker.show_at(Vector2.ZERO)
		main.plant_marker.update(1.0)
		main.orbit.visible = true
		main.grab._grabbing.assign([main.right_hand])
		main._snap_armed = true
		xri.emit_signal(signal_name)
		_ok("focus immediate " + signal_name, not main._xr_focused and _focus_safe(main),
			"pointers hidden, grab released, snap disarmed, help hidden on signal")
		for i in 3:
			await process_frame
		_ok("focus frames " + signal_name, _focus_safe(main) and main.help.is_open(),
			"main cannot reopen UI under dash; help intent retained")
		xri.emit_signal("session_focussed")
		for i in 3:
			await process_frame
		_ok("help refocus " + signal_name, main.help.visible and main.help.is_open(), "open intent restored")
		main.help.close()
		main.help.update(1.0)
	# A stick held through focus recovery cannot turn the room until it has centred.
	main._on_session_unfocused()
	main._on_session_focussed()
	var held: int = main._snap_step(0.9, true)
	main._snap_step(0.0, true)
	var fresh: int = main._snap_step(0.9, true)
	_ok("focus snap recentre", held == 0 and fresh == 1, "held=%d fresh=%d" % [held, fresh])

	main._on_session_unfocused()
	main._on_session_focussed()
	Input.action_press("ui_right")
	main._menu_active = true
	main._handle_input(1.0 / 72.0)
	main._menu_active = false
	var before_menu: Transform3D = main.cloud.global_transform
	main._handle_input(1.0 / 72.0)
	_ok("focus snap menu recentre", not main._snap_armed \
		and main.cloud.global_transform.is_equal_approx(before_menu),
		"a stick held over the menu must still centre before snapping")
	Input.action_release("ui_right")

	# First placement is pending while unfocused, then opens the tutorial on focus.
	main.xr_camera.position = Vector3(0.0, 1.6, 0.0)
	main._placed = false
	main._help_pending = true
	main._on_session_unfocused()
	for i in 3:
		await process_frame
	_ok("help first placement pending", not main._placed and main._help_pending and not main.help.visible,
		"unfocused placement preserves tutorial intent")
	main._on_session_focussed()
	for i in 3:
		await process_frame
	_ok("help first placement refocus", main._placed and not main._help_pending and main.help.visible,
		"tracked placement opens tutorial after focus")
	main.help.close()
	main.help.update(1.0)

	main._set_mode("ground")
	for i in 8:
		await process_frame
	main.orbit_on = true
	main.menu.set_suspended(true)
	main._menu_active = false
	main._tick_orbit()
	main.ground.glide_to(main.ground._head_xz + Vector2(3.0, 0.0))
	main._gg_hands.assign([1])
	_ok("ground focus live control", main.orbit.visible and main.ground._glide.length() > 0.5,
		"orbit and glide active before loss")
	main._on_session_unfocused()
	var at: Vector2 = main.ground._head_xz
	for i in 4:
		await process_frame
	_ok("ground unfocused", _focus_safe(main) and main._gg_hands.is_empty() \
		and main.ground._glide == Vector2.ZERO and main.ground._head_xz == at,
		"orbit hidden, ground grip released, glide stopped")
	main.orbit_on = false
	main._on_session_focussed()

	main._set_mode("tree")
	main.forest.sow_avenue(main.xr_camera.global_transform, true, FractalTree.SHAPE_NAMES[0])
	main.forest.walk_held = true
	main.forest.tick(0.25, main.xr_camera.global_position)
	_ok("walk focus live control", main.forest.walk_speed > 0.0, "walk moving before loss")
	main._on_session_unfocused()
	var walked: float = main.forest.walked
	for i in 4:
		await process_frame
	_ok("walk unfocused", main.forest.walk_speed == 0.0 and main.forest.walked == walked,
		"no deceleration movement under dash")
	main._on_session_focussed()

	main._set_mode("ifs")
	for i in 8:
		await process_frame
	main._reset_ifs_shape()
	main.ifs.ambient = false
	main.ifs.build(false)
	main.ifs_dive.set_on(true)
	main.ifs_dive.tick(0.25, true, main.xr_camera.global_transform)
	_ok("dive focus live control", main.ifs_dive.in_step() and main.ifs_dive.motion() > 0.0,
		"dive moving before loss")
	main._on_session_unfocused()
	var pose: Transform3D = main.cloud.global_transform
	var progress: float = main.ifs_dive.progress()
	for i in 4:
		await process_frame
	_ok("dive unfocused", main.cloud.global_transform.is_equal_approx(pose) \
		and main.ifs_dive.progress() == progress and main.ifs_dive.motion() == 0.0,
		"step frozen at current pose")
	main._on_session_focussed()
	main.ifs_dive.set_on(false)

	main._set_mode("flame")
	main._enter_galaxy()
	main._tick_flame_scale(0.25)
	_ok("galaxy focus live control", main.galaxy.is_moving(), "ease moving before loss")
	main._on_session_unfocused()
	pose = main.cloud.global_transform
	main.cycle_idx = 1
	var cycle: float = main._cycle
	for i in 4:
		await process_frame
	_ok("galaxy unfocused", not main.galaxy.is_moving() and main.cloud.global_transform.is_equal_approx(pose),
		"world transform holds under dash")
	_ok("ambient cycle unfocused", main._cycle != cycle, "colour clock still runs")
	main._on_session_focussed()
	main._leave_galaxy(false)
