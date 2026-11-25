extends Node3D

## No main script, fractal shaders or gallery resources before the first draw.
signal main_attached(main: Node3D)

const MAIN_PATH := "res://main.tscn"
var xr: OpenXRInterface
var main = null
var state_path := ""  # Harnesses use an isolated resume file.
var first_frame_msec := -1
var first_focus_msec := -1
var load_started := false
var _loading_failed := false
var _placed := false
var _handover_pending := false
var _angle := 0.0
@onready var origin: XROrigin3D = $XROrigin3D
@onready var camera: XRCamera3D = $XROrigin3D/XRCamera3D
@onready var loading: Node3D = $XROrigin3D/Loading
@onready var label: Label3D = $XROrigin3D/Loading/Label


func _ready() -> void:
	# Godot initializes OpenXR at engine startup (project xr/openxr/enabled).
	# Both entry scenes reuse it. Neither reinitializes or tears down the session.
	xr = XRServer.find_interface("OpenXR") as OpenXRInterface
	if xr != null and xr.is_initialized():
		get_viewport().use_xr = true
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		xr.session_focussed.connect(_on_focussed)
		xr.session_begun.connect(_request_refresh_rate)
		_request_refresh_rate()
		if xr.get_session_state() == OpenXRInterface.SESSION_STATE_FOCUSED:
			_on_focussed()
	else:
		xr = null
		camera.position.y = 1.6
	RenderingServer.frame_post_draw.connect(_on_first_frame, CONNECT_ONE_SHOT)


func _on_focussed() -> void:
	if first_focus_msec < 0:
		first_focus_msec = Time.get_ticks_msec()
		print("[startup] boot session_focussed ticks_msec=%d" % first_focus_msec)


func _request_refresh_rate() -> void:
	if xr.get_available_display_refresh_rates().has(72.0) and not is_equal_approx(xr.get_display_refresh_rate(), 72.0):
		xr.set_display_refresh_rate(72.0)


func _on_first_frame() -> void:
	first_frame_msec = Time.get_ticks_msec()
	print("[startup] boot first frame ticks_msec=%d" % first_frame_msec)
	call_deferred("_request_main")


func _request_main() -> void:
	if load_started:
		return
	load_started = true
	print("[startup] main load requested ticks_msec=%d" % Time.get_ticks_msec())
	var error := ResourceLoader.load_threaded_request(MAIN_PATH, "PackedScene")
	if error != OK:
		_fail("Main scene request failed (%d)" % error)


func _process(delta: float) -> void:
	_angle += delta * 0.9
	$XROrigin3D/Loading/Indicator.rotation.z = _angle
	# Place once at the tracked head's height and yaw, then leave it world-locked.
	if not _placed and (xr == null or camera.position.length_squared() > 0.000001):
		_placed = true
		loading.position = camera.position + camera.basis * Vector3(0, 0, -1.3)
		loading.rotation.y = camera.rotation.y
	if not load_started or _loading_failed or _handover_pending:
		return
	if main == null:
		match ResourceLoader.load_threaded_get_status(MAIN_PATH):
			ResourceLoader.THREAD_LOAD_LOADED:
				_attach_main()
			ResourceLoader.THREAD_LOAD_FAILED, ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
				_fail("Main scene could not be loaded")
	elif main._setup_done or main._failed:
		# A desktop draw alone cannot establish an XR handoff. Keep submitting the
		# loading view until the runtime reports it can present the replacement.
		if xr != null and xr.get_session_state() not in [
			OpenXRInterface.SESSION_STATE_VISIBLE, OpenXRInterface.SESSION_STATE_FOCUSED]:
			return
		_handover_pending = true
		main.xr_origin.current = true
		main.xr_camera.make_current()
		# Draw with the destination camera AND loading geometry, then remove boot.
		RenderingServer.frame_post_draw.connect(_on_content_frame, CONNECT_ONE_SHOT)


func _attach_main() -> void:
	var scene := ResourceLoader.load_threaded_get(MAIN_PATH) as PackedScene
	if scene == null:
		_fail("Main scene is not a PackedScene")
		return
	main = scene.instantiate()
	main.boot_managed = true
	main.startup_first_focus_msec = first_focus_msec
	if not state_path.is_empty():
		main.state_path = state_path
	# Enter at the same world origin. Never reset XRServer's reference space.
	main.get_node("XROrigin3D").transform = origin.transform
	main.get_node("XROrigin3D/XRCamera3D").transform = camera.transform
	get_tree().root.add_child(main)
	origin.current = true
	camera.make_current()
	print("[startup] main attached ticks_msec=%d" % Time.get_ticks_msec())
	main_attached.emit(main)


func _on_content_frame() -> void:
	call_deferred("_finish_handover")


func _finish_handover() -> void:
	get_tree().current_scene = main
	print("[startup] boot handover ticks_msec=%d" % Time.get_ticks_msec())
	queue_free()


func _fail(message: String) -> void:
	_loading_failed = true
	label.text = "Something went wrong\n%s\nRestart the app" % message
	push_error("[boot] %s" % message)
