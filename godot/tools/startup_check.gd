extends SceneTree

## Real render boundary, isolated state, and the composition-layer attachment path
## even on a desktop without OpenXR. Eager-load and signals-only controls must fail.
var _fails := 0
var _first_frame := false
var _boot_frame := false
var _overlap_frame := false
var _boot = null
var _early_session := Session.new()
var _early_focus_msec := -1


class Session extends RefCounted:
	signal session_visible
	signal session_stopping
	signal session_loss_pending
	signal session_focussed
	var state := OpenXRInterface.SESSION_STATE_IDLE
	func is_initialized() -> bool:
		return true
	func get_session_state() -> int:
		return state
	func focus() -> void:
		state = OpenXRInterface.SESSION_STATE_FOCUSED
		session_focussed.emit()



func _initialize() -> void:
	call_deferred("_run")


func _check(ok: bool, message: String) -> void:
	if not ok:
		_fails += 1
		print("STARTUPCHECK FAIL %s" % message)


func _run() -> void:
	_check(ProjectSettings.get_setting("application/run/main_scene") == "res://boot.tscn",
		"project entry does not use boot")
	_boot = load("res://boot.tscn").instantiate()
	_boot.state_path = "res://.spike-out/startup_state.cfg"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_boot.state_path))
	_boot.main_attached.connect(_on_main_attached)
	RenderingServer.frame_post_draw.connect(_inspect_boot_frames)
	root.add_child(_boot)
	current_scene = _boot
	# Focus fires while main is still absent. Its later listener must read the state.
	_early_focus_msec = Time.get_ticks_msec()
	_early_session.focus()
	_boot.first_focus_msec = _early_focus_msec
	if "--eager-control" in OS.get_cmdline_user_args():
		_boot._request_main()
	var main = null
	for i in 600:
		await process_frame
		if is_instance_valid(_boot) and _boot.main != null:
			main = _boot.main
		if not is_instance_valid(_boot):
			break
	_check(_boot_frame, "boot did not draw")
	_check(main != null and not is_instance_valid(_boot), "boot did not free after handover")
	_check(_overlap_frame, "loading view absent from destination camera frame")
	_check(current_scene == main and root.get_camera_3d() == main.xr_camera,
		"handover left the wrong scene or camera")
	RenderingServer.frame_post_draw.disconnect(_inspect_boot_frames)
	if main == null:
		quit(1)
		return
	_check(_first_frame and main._setup_done, "startup did not finish")
	_check(not main.hud.visible, "loading label remained after setup")
	_check(main._xr_focused and main._xr_focus_seen and main._first_focus_msec == _early_focus_msec,
		"focus before main load was lost")
	# All non-focused startup states must pause immediately without waiting for a signal.
	for state in [OpenXRInterface.SESSION_STATE_VISIBLE, OpenXRInterface.SESSION_STATE_STOPPING,
		OpenXRInterface.SESSION_STATE_LOSS_PENDING, OpenXRInterface.SESSION_STATE_SYNCHRONIZED]:
		var session := Session.new()
		session.state = state
		main._xr_focused = true
		main._bind_xr_session(session)
		_check(not main._xr_focused and not main.menu._focused and main.help._suspended,
			"non-focused session snapshot was lost (%d)" % state)
		session.focus()
		_check(main._xr_focused, "focus after main load was lost")
		for signal_name in ["session_visible", "session_stopping", "session_loss_pending"]:
			session.emit_signal(signal_name)
			_check(not main._xr_focused, "later " + signal_name + " ignored")
			session.focus()

	await RenderingServer.frame_post_draw
	var content := root.get_texture().get_image()
	_check(_has_light(content), "first frame without boot was black")
	content.save_png("res://.spike-out/boot_content.png")
	await _check_layers(main)


func _on_main_attached(main: Node3D) -> void:
	_check(_boot_frame, "main attached before boot draw")
	_check(main.xr_origin.transform.is_equal_approx(_boot.origin.transform), "XR origin changed at attachment")
	_check(main.startup_first_focus_msec == _early_focus_msec, "boot focus timestamp lost")
	main._xr_focused = false
	if "--signals-only-control" in OS.get_cmdline_user_args():
		# The old listener only connects future signals. The earlier one is gone.
		_early_session.session_focussed.connect(main._on_session_focussed)
	else:
		main._bind_xr_session(_early_session)
	RenderingServer.frame_post_draw.connect(func():
		_first_frame = true
		_check(main.cloud.get_parent() == null, "cloud setup preceded first draw")
		_check(main.library.count() == 0, "JSON loaded before first draw")
		_check(main.menu._vp == null, "menu built before first draw")
		_check(main.tonemap._rd == null and not main.tonemap._pipeline.is_valid(),
			"Mobile startup compiled the unused flam3 compute pass")
		_check(_boot.loading.visible and _boot.label.text == "Loading FractalXR", "boot label absent during main setup")
		root.get_texture().get_image().save_png("res://.spike-out/startup_loading.png"), CONNECT_ONE_SHOT)
	_check(main._xr_focused and main._xr_focus_seen, "focus before attachment was missed")
	# Exercise real handlers before content enters the tree.
	main._recenter()
	_early_session.session_visible.emit()
	_early_session.focus()


func _inspect_boot_frames() -> void:
	if not _boot_frame:
		_boot_frame = true
		_check(not _boot.load_started and _boot.main == null, "main load preceded boot draw")
		_check(not ResourceLoader.has_cached("res://main.tscn"), "boot eagerly loaded main scene")
		_check(not ResourceLoader.has_cached("res://scripts/main.gd"), "boot eagerly loaded main script")
		_check(_boot.label.visible, "first boot frame has no indicator")
		var first := root.get_texture().get_image()
		_check(_has_light(first), "first boot frame was black")
		first.save_png("res://.spike-out/boot_loading.png")
	if is_instance_valid(_boot) and _boot._handover_pending:
		_overlap_frame = root.get_camera_3d() == _boot.main.xr_camera and _boot.loading.is_visible_in_tree()
		_check(_boot.main._setup_done or _boot.main._failed, "boot removed before content was ready")
		root.get_texture().get_image().save_png("res://.spike-out/boot_overlap.png")
		_check(_boot.camera.global_transform.is_equal_approx(_boot.main.xr_camera.global_transform),
			"camera pose jumped at handover")


func _check_layers(main: Node3D) -> void:
	var host := Node3D.new()
	main.left_hand.add_child(host)
	host.transform = Transform3D(Basis(Vector3.UP, 0.4).scaled(Vector3.ONE * 0.8), Vector3(1, 2, 3))
	var vp := SubViewport.new()
	vp.size = Vector2i(16, 16)
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	host.add_child(vp)
	var quad := WorldQuad.attach(host, main.xr_origin, vp, Vector2.ONE, 1)
	for i in 3:
		await process_frame
	_check(_quad_matches(quad, host, main.xr_origin), "initial layer pose or parent")
	host.reparent(main.xr_origin)
	host.position = Vector3(-2, 1, 4)
	for i in 3:
		await process_frame
	_check(_quad_matches(quad, host, main.xr_origin), "layer pose after menu reparent")
	host.hide()
	_check(not quad.visible, "layer ignored host hide")
	host.show()
	_check(quad.visible, "layer ignored host show")
	main.xr_origin.remove_child(host)
	_check(not quad.visible, "detached host left a visible layer")
	main.left_hand.add_child(host)
	host.position = Vector3(2, 3, -1)
	for i in 3:
		await process_frame
	_check(quad.visible and _quad_matches(quad, host, main.xr_origin), "reattached layer pose or visibility")

	var wrong := OpenXRCompositionLayerQuad.new()
	host.add_child(wrong)
	var control_failed := not _quad_matches(wrong, host, main.xr_origin)
	_check(control_failed, "unsafe-parent control was accepted")
	host.queue_free()
	for i in 3:
		await process_frame
	_check(not is_instance_valid(quad), "host deletion leaked a layer")
	print("STARTUPCHECK %s failures=%d control=%s" % [
		"PASS" if _fails == 0 else "FAIL", _fails, "FAIL" if control_failed else "PASS"])
	quit(0 if _fails == 0 else 1)


func _quad_matches(quad: OpenXRCompositionLayerQuad, host: Node3D, origin: XROrigin3D) -> bool:
	return quad.get_parent() == origin and quad.global_transform.is_equal_approx(host.global_transform)


func _has_light(frame: Image) -> bool:
	for y in frame.get_height():
		for x in frame.get_width():
			var c := frame.get_pixel(x, y)
			if maxf(c.r, maxf(c.g, c.b)) > 0.1:
				return true
	return false
