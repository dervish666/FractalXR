extends SceneTree

## Real render boundary, isolated state, and the composition-layer attachment path
## even on a desktop without OpenXR. The parent control must fail the same assertion.
var _fails := 0
var _first_frame := false


func _initialize() -> void:
	call_deferred("_run")


func _check(ok: bool, message: String) -> void:
	if not ok:
		_fails += 1
		print("STARTUPCHECK FAIL %s" % message)


func _run() -> void:
	var main = load("res://main.tscn").instantiate()
	main.state_path = "res://.spike-out/startup_state.cfg"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(main.state_path))
	RenderingServer.frame_post_draw.connect(func():
		_first_frame = true
		_check(main.cloud.get_parent() == null, "cloud setup preceded first draw")
		_check(main.library.count() == 0, "JSON loaded before first draw")
		_check(main.menu._vp == null, "menu built before first draw")
		_check(main.hud.visible and main.hud.text == "Loading FractalXR...", "loading label absent")
		root.get_texture().get_image().save_png("res://.spike-out/startup_loading.png"), CONNECT_ONE_SHOT)
	root.add_child(main)
	if "--eager-control" in OS.get_cmdline_user_args():
		RenderingServer.frame_post_draw.disconnect(main._on_loading_frame)
		main._start_content()  # Reproduce the old eager startup before the first draw.
	# Exercise signals while content is still detached.
	main._recenter()
	main._on_session_unfocused()
	main._on_session_focussed()
	for i in 80:
		await process_frame
	_check(_first_frame and main._setup_done, "startup did not finish")
	_check(not main.hud.visible, "loading label remained after setup")

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
