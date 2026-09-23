extends SceneTree

## ECHOES through the real main scene: enter IFS the way the wrist strip does, step the ECHOES
## tile, capture what draws, and check what a PNG cannot show on its own.
##
##   - The tile steps few -> many -> off and prints what it drew.
##   - Echoes add light to a view looking up past the hero, off being the control: a capture
##     that is the same with the echoes on says nothing about the echoes. Up, because the
##     tabletop pose on a desktop frustum is mostly hero and the sight cone keeps echoes out
##     of the rest; the headset's wider view is where they live.
##   - They are anchored to the room, not the grab: moving the sculpture leaves them put.
##   - Leaving the mode hides them with the hero.
##
##   tools/ifs_echo_shot.sh

const OUT := "res://.spike-out/ifs-echoes-2026-09-23"
const TABLE := Vector3(-19.0, 0.0, 0.0)
## Pitched up far enough that the hero, below the eye line and 0.8 m out, is out of frame.
const UP := Vector3(45.0, 0.0, 0.0)

var _fails := 0


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var main = (load("res://main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	for i in 40:
		await process_frame
	main.help.close()
	main.xr_camera.position = Vector3(0.0, 1.6, 0.0)
	main.xr_camera.rotation_degrees = Vector3(-19.0, 0.0, 0.0)
	for i in 40:
		await process_frame
	main._set_mode("ifs")
	for i in 10:
		await process_frame
	var tile = _tile(main, "ECHOES", "look")
	if tile == null:
		_ok("echoes tile", false, "no ECHOES tile in the look section while in IFS")
		quit(1)
		return
	var reads := [str(tile.read.call())]
	await _shot(main, "echoes-few.png", TABLE)
	var few: Image = await _shot(main, "echoes-few-up.png", UP)
	var few_n: int = main.ifs_echoes.count()
	var few_i: int = main.ifs_echoes.instance_total()
	tile.advance.call()
	reads.append(str(tile.read.call()))
	await _shot(main, "echoes-many.png", TABLE)
	var many: Image = await _shot(main, "echoes-many-up.png", UP)
	var many_n: int = main.ifs_echoes.count()
	var many_i: int = main.ifs_echoes.instance_total()
	tile.advance.call()
	reads.append(str(tile.read.call()))
	await _shot(main, "echoes-off.png", TABLE)
	var off: Image = await _shot(main, "echoes-off-up.png", UP)
	var lit := [_lit(off), _lit(few), _lit(many)]
	_ok("echoes tile", reads == ["few · 16", "many · 40", "off"] and main.ifs_echoes.count() == 0,
		"reads %s" % str(reads))
	_ok("echoes draw", lit[1] > lit[0] * 2 + 200 and lit[2] > lit[1],
		("lit samples looking up: off=%d few=%d many=%d, few=%d echoes %d frames, "
			+ "many=%d echoes %d frames, hero %d frames") % [lit[0], lit[1], lit[2], few_n, few_i,
			many_n, many_i, main.ifs.instance_count])

	# Two more views of MANY: turned left and looking up, and turned right, where the hero is
	# out of frame and the room is all there is.
	tile.advance.call()
	tile.advance.call()
	await _shot(main, "echoes-many-left-up.png", Vector3(20.0, 70.0, 0.0))
	await _shot(main, "echoes-many-right.png", Vector3(5.0, -100.0, 0.0))
	main.xr_camera.rotation_degrees = TABLE

	# Room-anchored: a grab moves the hero and nothing else.
	var before: Transform3D = main.ifs_echoes.global_transform
	var echo0: Vector3 = main.ifs_echoes.nodes()[0].global_position
	var hero0: Transform3D = main.ifs.global_transform
	main.cloud.global_transform = main.cloud.global_transform.translated(Vector3(0.3, 0.2, -0.4))
	for i in 3:
		await process_frame
	var still: bool = main.ifs_echoes.global_transform.is_equal_approx(before) \
		and main.ifs_echoes.nodes()[0].global_position.is_equal_approx(echo0)
	var hero_moved: bool = not main.ifs.global_transform.is_equal_approx(hero0)
	_ok("echoes anchored", still and hero_moved,
		"echo root and echo 0 unchanged by a grab=%s, hero moved=%s" % [str(still), str(hero_moved)])

	main._set_mode("flame")
	for i in 6:
		await process_frame
	var hidden: bool = not main.ifs_echoes.nodes()[0].is_visible_in_tree()
	main._set_mode("ifs")
	for i in 6:
		await process_frame
	var back: bool = main.ifs_echoes.nodes()[0].is_visible_in_tree()
	_ok("echoes hide", hidden and back,
		"hidden in flame=%s back in ifs=%s" % [str(hidden), str(back)])

	print("IFSECHO %s failures=%d dir=%s" % ["PASS" if _fails == 0 else "FAIL", _fails, OUT])
	quit(0 if _fails == 0 else 1)


func _ok(name: String, pass_: bool, detail: String) -> void:
	if not pass_:
		_fails += 1
	print("IFSECHO %-16s %s  %s" % [name, "PASS" if pass_ else "FAIL", detail])


func _shot(main, file: String, look: Vector3) -> Image:
	main.xr_camera.rotation_degrees = look
	main.ifs.finish_grow()
	for i in 6:
		await process_frame
	var img := root.get_viewport().get_texture().get_image()
	var err := img.save_png("%s/%s" % [OUT, file])
	if err != OK:
		_ok("capture", false, "%s err=%d" % [file, err])
	return img


func _lit(img: Image) -> int:
	var n := 0
	for y in range(0, img.get_height(), 2):
		for x in range(0, img.get_width(), 2):
			var c := img.get_pixel(x, y)
			if maxf(c.r, maxf(c.g, c.b)) > 0.12:
				n += 1
	return n


func _tile(main, label: String, section: String):
	for it in main.menu.items:
		if it.section == section and it.label == label \
				and (not it.visible_when.is_valid() or bool(it.visible_when.call())):
			return it
	return null
