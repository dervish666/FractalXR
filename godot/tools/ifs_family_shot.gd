extends SceneTree

## FAMILY, room size and DIVE through the real main scene. Enters IFS the way the wrist strip
## does, works the LAYOUT, SIZE and DIVE tiles, and captures what draws. Prints the numbers a
## PNG cannot show: echo counts, the hero's width and where the eyes sit in it, and the dive's
## progress and landing.
##
##   tools/ifs_family_shot.sh

const OUT := "res://.spike-out/ifs-family-2026-10-10"
const TABLE := Vector3(-19.0, 0.0, 0.0)
const UP := Vector3(40.0, 0.0, 0.0)
const LEFT := Vector3(-5.0, 70.0, 0.0)
const LEVEL := Vector3(0.0, 0.0, 0.0)
const DT := 1.0 / 72.0

var _fails := 0


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var main = (load("res://main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	for i in 40:
		await process_frame
	main.help.close()
	main.xr_camera.position = Vector3(0.0, 1.6, 0.0)
	main.xr_camera.rotation_degrees = TABLE
	for i in 40:
		await process_frame
	main._set_mode("ifs")
	for i in 10:
		await process_frame
	# Hold the breath, so a capture is the banked shape and a dive's maps hold still.
	main.ifs.ambient = false
	main.ifs.build(false)
	var layout = _tile(main, "LAYOUT", "look")
	var size = _tile(main, "SIZE", "look")
	var dive = _tile(main, "DIVE", "make")
	if layout == null or size == null or dive == null:
		_ok("tiles", false, "LAYOUT=%s SIZE=%s DIVE=%s" % [layout != null, size != null, dive != null])
		quit(1)
		return
	_ok("tiles", true, "LAYOUT '%s' SIZE '%s' DIVE '%s'" % [layout.read.call(), size.read.call(),
		dive.read.call()])

	# Tabletop, scatter then family. The family fades in over the swap's span, so run its clock.
	await _shot(main, "table-scatter.png", TABLE)
	layout.advance.call()
	await _settle_relayout(main)
	_ok("family on", main.ifs_echoes.family and main.ifs_echoes.count() > 0,
		"tile '%s', %d echoes (%d frames), %d instances" % [layout.read.call(),
		main.ifs_echoes.count(), _frames(main), main.ifs_echoes.instance_total()])
	await _shot(main, "table-family.png", TABLE)
	await _shot(main, "table-family-up.png", UP)
	await _shot(main, "table-family-left.png", LEFT)

	# Room size: the hero around the eyes, the family at room scale.
	size.advance.call()
	for i in 4:
		await process_frame
	var hero: Transform3D = main.cloud.global_transform * main.ifs.transform
	var u := pow(absf(hero.basis.determinant()), 1.0 / 3.0)
	var width := u * maxf(main.ifs.bounds.size.x, main.ifs.bounds.size.y)
	var eye_local: Vector3 = hero.affine_inverse() * main.xr_camera.global_transform.origin
	var clear: float = main.ifs.clear_radius_at(eye_local) * u
	var bottom: float = (hero * main.ifs.bounds.position).y
	_ok("room size", size.read.call() == "room" and width > 2.3 and clear >= FractalIFS.HEAD_CLIP,
		"tile '%s', %.2f m wide, eyes %.2f m from the nearest beam, lowest beam at y=%.2f, %d echoes" % [
		size.read.call(), width, clear, bottom, main.ifs_echoes.count()])
	await _shot(main, "room-family.png", LEVEL)
	await _shot(main, "room-family-up.png", UP)
	await _shot(main, "room-family-left.png", LEFT)
	layout.advance.call()
	await _settle_relayout(main)
	await _shot(main, "room-scatter.png", LEVEL)
	layout.advance.call()
	await _settle_relayout(main)

	# Back to the table for the dive.
	size.advance.call()
	for i in 4:
		await process_frame
	dive.advance.call()
	_ok("dive on", main.ifs_dive.on and main.ifs.material().shader.code.contains("dive_fade"),
		"tile '%s', clip shader on=%s" % [dive.read.call(),
		main.ifs.material().shader.code.contains("discard")])
	main.xr_camera.rotation_degrees = TABLE
	await _shot(main, "dive-0.png", TABLE)
	var hero0: Transform3D = main.cloud.global_transform * main.ifs.transform
	var echo0: Transform3D = main.ifs_echoes.nodes()[0].global_transform
	await _dive_to(main, 0.25)
	await _shot(main, "dive-25.png", TABLE)
	await _dive_to(main, 0.6)
	await _shot(main, "dive-60.png", TABLE)
	# Seamless: the last frame of the step and the first after the re-root, before the new
	# deepest generation has grown, must be the same picture. The control is the step at 60%.
	# The step drawn at exactly its end, then the re-root, so the comparison is the swap alone.
	await _dive_to(main, 0.99)
	main.ifs_dive._t = 1.0
	main.ifs_dive.apply()
	var pre: Image = await _shot(main, "dive-pre-snap.png", TABLE, false)
	main.ifs_dive.finish()
	var post: Image = await _shot(main, "dive-snap.png", TABLE, false)
	var mid := Image.load_from_file(ProjectSettings.globalize_path("%s/dive-60.png" % OUT))
	# At an eighth of the size, box-averaged: stopping the step at 99.7% shifts thin lines by a
	# pixel or two, which a full-size diff counts and an eye does not; a colour or shape pop
	# moves the region averages and survives.
	var d := _diff(_small(pre), _small(post))
	var ctl := _diff(_small(mid), _small(post))
	var full := _diff(pre, post)
	_ok("seamless", d.x < 0.006 and ctl.x > 4.0 * d.x,
		("re-root changes the 1/8 picture by mean %.4f (max %.3f, full size %.4f); "
			+ "60%% vs landed control %.4f") % [d.x, d.y, full.x, ctl.x])
	await _shot(main, "dive-landed.png", TABLE)
	var hero1: Transform3D = main.cloud.global_transform * main.ifs.transform
	var size0 := pow(absf(hero0.basis.determinant()), 1.0 / 3.0)
	var size1 := pow(absf(hero1.basis.determinant()), 1.0 / 3.0)
	var echo1: Transform3D = main.ifs_echoes.nodes()[0].global_transform
	_ok("dive lands", main.ifs_dive.steps == 1 and hero1.origin.distance_to(hero0.origin) < 1e-3
			and absf(size1 - size0) < 1e-4 and echo1.is_equal_approx(echo0),
		"steps=%d, new hero %.5f m from the old, size %.4f -> %.4f, echoes stayed put=%s" % [
		main.ifs_dive.steps, hero1.origin.distance_to(hero0.origin), size0, size1,
		str(echo1.is_equal_approx(echo0))])
	await _dive_to(main, 0.5)
	await _shot(main, "dive-2-50.png", TABLE)

	# Room size, mid-dive: the clip sphere's case.
	dive.advance.call()
	size.advance.call()
	for i in 4:
		await process_frame
	dive.advance.call()
	await _dive_to(main, 0.5)
	await _shot(main, "room-dive-50.png", LEVEL)
	dive.advance.call()
	_ok("dive off", not main.ifs_dive.on and not main.ifs_dive.in_step(),
		"tile '%s', in step=%s" % [dive.read.call(), str(main.ifs_dive.in_step())])
	print("IFSFAMILY %s failures=%d dir=%s" % ["PASS" if _fails == 0 else "FAIL", _fails, OUT])
	quit(0 if _fails == 0 else 1)


## Hold the trigger, as the dive sees it, until the current step reaches `p` (a value past 1
## lands the step in progress). main's own tick sees no trigger on the desktop, so the eased
## hold is zeroed after, or main would coast the step on while frames render.
func _dive_to(main, p: float) -> void:
	var cam: Transform3D = main.xr_camera.global_transform
	var n := 0
	var start_steps: int = main.ifs_dive.steps
	while n < 72 * 60:
		# Fine steps near a target close to 1, so the step cannot land past it.
		var near: bool = p <= 1.0 and main.ifs_dive.in_step() and main.ifs_dive.progress() > p - 0.01
		main.ifs_dive.tick(DT * (0.02 if near else 1.0), true, cam)
		n += 1
		if p > 1.0 and main.ifs_dive.steps > start_steps:
			break
		if p <= 1.0 and main.ifs_dive.in_step() and main.ifs_dive.progress() >= p:
			break
	if p > 1.0 and main.ifs_dive.in_step():
		main.ifs_dive.cancel()   # the held trigger began the next step on the landing frame
	main.ifs_dive._v = 0.0
	print("IFSFAMILY dive at %.2f after %.1f s held, step %d, fade %.2f" % [main.ifs_dive.progress(),
		float(n) * DT, main.ifs_dive.steps,
		float(main.ifs.material().get_shader_parameter(&"dive_fade"))])
	await process_frame


func _settle_relayout(main) -> void:
	var n := 0
	while main.ifs_echoes.is_relayouting() and n < 72 * 20:
		main.ifs_echoes.advance(DT)
		n += 1
	# The regrowth: run the clock through it.
	for i in 72 * 5:
		main.ifs_echoes.advance(DT)
	await process_frame


func _frames(main) -> int:
	var n := 0
	for i in main.ifs_echoes.count():
		n += 1 if int(main.ifs_echoes.placements[i]["tier"]) < 0 else 0
	return n


func _ok(name: String, pass_: bool, detail: String) -> void:
	if not pass_:
		_fails += 1
	print("IFSFAMILY %-12s %s  %s" % [name, "PASS" if pass_ else "FAIL", detail])


func _small(img: Image) -> Image:
	var s: Image = img.duplicate()
	s.convert(Image.FORMAT_RGBA8)
	for i in 3:
		s.shrink_x2()
	return s


func _diff(a: Image, b: Image) -> Vector2:
	var sum := 0.0
	var mx := 0.0
	var n := 0
	for y in range(0, mini(a.get_height(), b.get_height()), 2):
		for x in range(0, mini(a.get_width(), b.get_width()), 2):
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			var e := maxf(absf(ca.r - cb.r), maxf(absf(ca.g - cb.g), absf(ca.b - cb.b)))
			sum += e
			mx = maxf(mx, e)
			n += 1
	return Vector2(sum / float(maxi(n, 1)), mx)


## `grown` false leaves a grow-in where it is, and renders two frames rather than six, so the
## picture is the state the last call left rather than one the clock has since moved on.
func _shot(main, file: String, look: Vector3, grown := true) -> Image:
	main.xr_camera.rotation_degrees = look
	if grown:
		main.ifs.finish_grow()
	for i in (6 if grown else 2):
		await process_frame
	var img := root.get_viewport().get_texture().get_image()
	var err := img.save_png("%s/%s" % [OUT, file])
	if err != OK:
		_ok("capture", false, "%s err=%d" % [file, err])
	return img


func _tile(main, label: String, section: String):
	for it in main.menu.items:
		if it.section == section and it.label == label \
				and (not it.visible_when.is_valid() or bool(it.visible_when.call())):
			return it
	return null
