extends SceneTree

## Does the displaced ground stay put when you turn your head? A fixed spectator camera films
## the ground with HEIGHT at 4x while the XR camera, the one ground.update() follows, turns in
## place. The ground's fragment is swapped for one that paints the displaced height, linear
## value 0.5 + 2y, so two captures read back as millimetres of surface movement rather than
## as luminance, which parallax on a texture this fine would swamp.
##
##   - Pure rotation, eye on the pivot: nothing may change at all.
##   - Rotation about a neck, the eye swinging 9 cm as a real head does: the surface may move
##     by the triangulation and the 8-bit readback, not by a re-levelled field. Before the
##     fix this measured 9-21 mm mean two thirds of a second after the turn (up to 50 mm
##     once the old reference lag had settled); after it, 2-3 mm.
##   - Control: a 0.6 m step does move the floor reference, and the capture must see the
##     field change, or a pass above proves nothing.
##
## The headset is still the judge of how it feels; this only proves the geometry is a
## function of the world and the floor reference, not of where the eye points.
##
##   tools/ground_turn.sh

const NECK := 0.09          # metres from the neck pivot to the centre eye, roughly
const LIMIT_MM := 4.0       # mean surface movement allowed for a neck turn
const CONTROL_MM := 8.0     # a real step must move it at least this much

var main
var _fails := 0


func _init() -> void:
	main = (load("res://main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	for i in 40:
		await process_frame
	main._set_mode("ground")
	main.help.close()
	main.ground.centre = Vector2(-0.55, 0.62)
	main.orbit_on = false
	main.orbit.visible = false
	main.ground_height_idx = 3
	main._apply_ground_look()
	var code: String = main.ground._material.shader.code
	var painted := code.replace("ALBEDO = mix(col, fog_colour, fog);",
		"ALBEDO = vec3(clamp(0.5 + 2.0 * v_world.y, 0.0, 1.0));")
	if painted == code:
		print("GROUNDTURN FAIL: the fragment's last line moved; update the height paint")
		quit(1)
		return
	var sh := Shader.new()
	sh.code = painted
	main.ground._material.shader = sh
	var spec := Camera3D.new()
	root.add_child(spec)
	spec.position = Vector3(0.0, 1.6, 0.6)
	spec.rotation_degrees = Vector3(-38.0, 0.0, 0.0)
	spec.current = true
	_place(0.0, false, Vector3.ZERO)
	for i in 900:
		await process_frame
		if i > 200 and main.ground.pending_texels() == 0:
			break

	for neck in [false, true]:
		_place(0.0, neck, Vector3.ZERO)
		var ref := await _shot(240)
		var worst := 0.0
		var lines := PackedStringArray()
		for yaw in [30.0, 90.0, -90.0]:
			_place(yaw, neck, Vector3.ZERO)
			var d := _mm(ref, await _shot(20))
			worst = maxf(worst, d)
			lines.append("%+.0f: %.2f mm" % [yaw, d])
		_place(0.0, neck, Vector3.ZERO)
		var back := _mm(ref, await _shot(20))
		var limit := 0.0 if not neck else LIMIT_MM
		_ok("turn %s" % ("about neck" if neck else "in place"), worst <= limit + 1e-6 and back <= limit,
			"%s, back to 0: %.2f mm (limit %.1f)" % [", ".join(lines), back, limit])

	# Control: a real step. The reference follows once the eye is 0.3 m away, so the field
	# re-levels and the capture has to say so.
	_place(0.0, true, Vector3.ZERO)
	var before := await _shot(60)
	_place(0.0, true, Vector3(0.6, 0.0, 0.0))
	var after := _mm(before, await _shot(360))
	_ok("control step", after >= CONTROL_MM, "0.6 m step moved the surface %.2f mm" % after)

	print("GROUNDTURN %s failures=%d" % ["PASS" if _fails == 0 else "FAIL", _fails])
	quit(0 if _fails == 0 else 1)


func _ok(name: String, pass_: bool, detail: String) -> void:
	if not pass_:
		_fails += 1
	print("  %-20s %s  %s" % [name, "PASS" if pass_ else "FAIL", detail])


## Turn the XR camera to `yaw` about a neck pivot at (0, 1.5, 0) + `at`. Without the neck
## the eye stays on the pivot and only the orientation changes.
func _place(yaw: float, neck: bool, at: Vector3) -> void:
	var b := Basis.from_euler(Vector3(deg_to_rad(-20.0), deg_to_rad(yaw), 0.0))
	var off := b * Vector3(0.0, 0.1, -NECK) if neck else Vector3.ZERO
	main.xr_camera.position = Vector3(0.0, 1.5, 0.0) + at + off
	main.xr_camera.basis = b


## force_draw, because an occluded desktop window skips its draws and the viewport would
## hand back the same stale frame every time.
func _shot(frames: int) -> Image:
	for i in frames:
		await process_frame
	RenderingServer.force_draw(false, 0.0)
	return root.get_viewport().get_texture().get_image()


## Mean height change in millimetres over the pixels that are not clipped in either capture.
func _mm(a: Image, b: Image) -> float:
	var s := 0.0
	var n := 0
	for y in range(0, a.get_height(), 3):
		for x in range(0, a.get_width(), 3):
			var la := a.get_pixel(x, y).srgb_to_linear().r
			var lb := b.get_pixel(x, y).srgb_to_linear().r
			if la <= 0.002 or la >= 0.998 or lb <= 0.002 or lb >= 0.998:
				continue
			s += absf(la - lb) * 0.5
			n += 1
	return s / float(maxi(n, 1)) * 1000.0
