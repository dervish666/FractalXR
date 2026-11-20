extends SceneTree

## MANDEL on SKY PICK over GROUND, to .spike-out/mandel_sky/: the Mandelbrot overview looking
## up and looking ahead, a zoom into seahorse valley driven through zoom_toward() (the trigger's
## path), and the burning ship's overview. Checks the sky is drawn (the upper half has colour
## and structure where SKY off is the plain background: the control) and that a zoom moved it.
## Light: the fill is a few dozen 3k row slices, the zoom stops at 30x.
##
##   tools/mandel_sky_shot.sh

const OUT := "res://.spike-out/mandel_sky"

var main: Node


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var scene: PackedScene = load("res://main.tscn")
	main = scene.instantiate()
	root.add_child(main)
	for i in 40:
		await process_frame
	main.help.close()
	main.xr_camera.position = Vector3(0.0, 1.6, 0.0)
	main.xr_camera.fov = 100.0
	main._set_mode("ground")
	var fs: FlameSky = main.flame_sky
	var ok := true

	_look(70.0)
	for i in 120:
		await process_frame
	var off := _shot("sky_off_up")

	main.sky_on = true
	fs.set_pick(fs.presets.size() + 1)
	var waited := 0
	while not fs.is_shown() and waited < 600:
		await process_frame
		waited += 1
	# The fade, then a settled frame.
	for i in 160:
		await process_frame
	print("MSKYSHOT shown after %d frames, label '%s'" % [waited, main._sky_label()])
	var up := _shot("mandel_up")
	var s_off := _stats(off)
	var s_up := _stats(up)
	var drawn := s_up.x > s_off.x + 0.02 and s_up.y > 0.02
	ok = ok and drawn
	print("MSKYSHOT drawn %s mean %.3f->%.3f spread %.3f->%.3f" % ["PASS" if drawn else "FAIL",
		s_off.x, s_up.x, s_off.y, s_up.y])

	_look(25.0)
	for i in 10:
		await process_frame
	_shot("mandel_ahead")

	# Seahorse valley, -0.745 + 0.11i: its direction under the home view, zoomed at the
	# trigger's rate for a few seconds of frames.
	var ms: MandelSky = fs.mandel
	var c := Vector2(-0.745, 0.11)
	var u := (c - Vector2(-0.75, 0.0)) / 2.0
	var r2 := u.length_squared()
	var dir := Vector3(2.0 * u.x, 1.0 - r2, 2.0 * u.y) / (1.0 + r2)
	_look_at(dir)
	for i in 10:
		await process_frame
	_shot("seahorse_before")
	while ms.zoom < 30.0:
		ms.zoom_toward(dir, MandelSky.ZOOM_RATE, 1.0 / 30.0, main.ground._m)
		await process_frame
	_shot("seahorse_mid_zoom")
	for i in 90:
		await process_frame
	var zoomed := _shot("seahorse_30x")
	print("MSKYSHOT zoom %.1fx label '%s'" % [ms.zoom, main._sky_label()])

	# You are here: the marker over the fractal point under your feet, dead centre when you
	# look along its direction.
	main._go_home()
	for i in 10:
		await process_frame
	main.xr_camera.fov = 40.0
	_look_at(ms._mat.get_shader_parameter(&"here_dir"))
	for i in 10:
		await process_frame
	var here := _shot("here")
	var cc := here.get_pixel(here.get_width() / 2, here.get_height() / 2)
	var marked := cc.r > 0.4 and cc.g > 0.4 and cc.b > 0.4
	ok = ok and marked
	print("MSKYSHOT here %s centre %s" % ["PASS" if marked else "FAIL", cc])

	# Every family's home, straight up through a wide lens: the whole dome in one frame.
	main.xr_camera.fov = 150.0
	for f in FractalGround.FORMULA_NAMES.size():
		main.ground.set_formula(f)
		main._go_home()
		_look(90.0)
		for i in 60:
			await process_frame
		_shot("dome_%s" % str(FractalGround.FORMULA_NAMES[f]).replace(" ", "_"))

	var moved := _stats(zoomed).y > 0.02
	ok = ok and moved
	print("MSKYSHOT %s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)


func _look(pitch_deg: float) -> void:
	main.xr_camera.rotation_degrees = Vector3(pitch_deg, 0.0, 0.0)


func _look_at(dir: Vector3) -> void:
	var cam: Camera3D = main.xr_camera
	cam.look_at(cam.global_position + dir, Vector3.FORWARD if absf(dir.y) > 0.99 else Vector3.UP)


func _shot(name: String) -> Image:
	var img: Image = root.get_viewport().get_texture().get_image()
	img.save_png("%s/%s.png" % [OUT, name])
	return img


## Over the upper half: x mean luma, y its standard deviation.
func _stats(a: Image) -> Vector2:
	var n := 0
	var sum := 0.0
	var sq := 0.0
	var step := maxi(1, a.get_width() / 160)
	for y in range(0, a.get_height() / 2, step):
		for x in range(0, a.get_width(), step):
			var c := a.get_pixel(x, y)
			var l := 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
			sum += l
			sq += l * l
			n += 1
	var m := sum / n
	return Vector2(m, sqrt(maxf(0.0, sq / n - m * m)))
