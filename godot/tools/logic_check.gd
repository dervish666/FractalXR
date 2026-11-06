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
	await _reset_undo(main)

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
			[0.1, false], [0.9, false], [0.9, true]]:
		got.append(main._snap_step(step[0], step[1]))
	var want := [1, 0, 0, 0, 0, -1, 0, 0, 1]
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
