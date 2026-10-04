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

const OUT := "res://.spike-out/ifs-echoes-2026-10-04"
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
	# LOTS opens by default; start the walk from FEW.
	var opened := str(tile.read.call())
	main.ifs_echoes.set_step(0)
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
	await _shot(main, "echoes-lots.png", TABLE)
	var lots: Image = await _shot(main, "echoes-lots-up.png", UP)
	var lots_i: int = main.ifs_echoes.instance_total()
	tile.advance.call()
	reads.append(str(tile.read.call()))
	var swarm: Image = await _shot(main, "echoes-swarm-up.png", UP)
	tile.advance.call()
	reads.append(str(tile.read.call()))
	await _shot(main, "echoes-host.png", TABLE)
	var host: Image = await _shot(main, "echoes-host-up.png", UP)
	await _shot(main, "echoes-host-far.png", Vector3(8.0, 30.0, 0.0))
	var host_i: int = main.ifs_echoes.instance_total()
	tile.advance.call()
	reads.append(str(tile.read.call()))
	await _shot(main, "echoes-off.png", TABLE)
	var off: Image = await _shot(main, "echoes-off-up.png", UP)
	var lit := [_lit(off), _lit(few), _lit(many), _lit(lots), _lit(swarm), _lit(host)]
	_ok("echoes tile", opened == "lots · 96"
			and reads == ["few · 16", "many · 40", "lots · 96", "swarm · 192", "host · 288", "off"]
			and main.ifs_echoes.count() == 0,
		"opened %s, reads %s" % [opened, str(reads)])
	_ok("echoes draw", lit[1] > lit[0] * 2 + 200 and lit[2] > lit[1] and lit[3] > lit[2]
			and lit[4] > lit[3] and lit[5] > lit[4],
		("lit samples looking up: off=%d few=%d many=%d lots=%d swarm=%d host=%d, few=%d echoes %d "
			+ "frames, many=%d echoes %d frames, lots %d frames, host %d frames, hero %d frames") % [
			lit[0], lit[1], lit[2], lit[3], lit[4], lit[5], few_n, few_i, many_n, many_i, lots_i,
			host_i, main.ifs.instance_count])

	# Off -> few -> many -> lots.
	tile.advance.call()
	tile.advance.call()
	tile.advance.call()
	await _life(main)

	# Three more views of LOTS: turned left and looking up, and turned right, where the hero is
	# out of frame and the room is all there is.
	await _shot(main, "echoes-lots-left-up.png", Vector3(20.0, 70.0, 0.0))
	await _shot(main, "echoes-lots-right.png", Vector3(5.0, -100.0, 0.0))
	await _shot(main, "echoes-lots-far.png", Vector3(8.0, 30.0, 0.0))
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


## The life, rendered. The shader takes every echo vertex out to world space and back to
## move it; with the motion zeroed that round trip must draw what the plain path draws, or the
## matrices are wrong and every echo is misplaced. Then ten minutes on, the same view must
## differ (the echoes moved) and still be lit about as much (nothing flew off or collapsed).
## The palette scroll and the hero's breathing are held still so only the echoes can change.
func _life(main) -> void:
	var ech: IfsEchoes = main.ifs_echoes
	main.ifs.ambient = false
	var mats: Array = ech._materials()
	for m in mats:
		m.set_shader_parameter(&"scroll", 0.0)
	var keys := [&"echo_live", &"echo_spin", &"echo_wander", &"echo_life"]
	var saved := []
	for i in ech.count():
		var n: MultiMeshInstance3D = ech.nodes()[i]
		var row := {}
		for k in keys:
			row[k] = n.get_instance_shader_parameter(k)
		saved.append(row)
		n.set_instance_shader_parameter(&"echo_live", 0.0)
	var plain: Image = await _shot(main, "life-plain.png", UP)
	for i in ech.count():
		var n: MultiMeshInstance3D = ech.nodes()[i]
		n.set_instance_shader_parameter(&"echo_live", 1.0)
		n.set_instance_shader_parameter(&"echo_spin", Vector4(0.0, 1.0, 0.0, 0.0))
		n.set_instance_shader_parameter(&"echo_wander", Vector4.ZERO)
		var l: Vector4 = saved[i][&"echo_life"]
		n.set_instance_shader_parameter(&"echo_life", Vector4(l.x, 0.0, l.z, l.w))
	var still: Image = await _shot(main, "life-zeroed.png", UP)
	for i in ech.count():
		var n: MultiMeshInstance3D = ech.nodes()[i]
		for k in keys:
			n.set_instance_shader_parameter(k, saved[i][k])
	var now: Image = await _shot(main, "life-t0.png", UP)
	ech.echo_t += 600.0
	ech.advance(0.0)
	var later: Image = await _shot(main, "life-t600.png", UP)
	await _shot(main, "life-t600-left-up.png", Vector3(20.0, 70.0, 0.0))
	var round_trip := _diff(plain, still)
	var moved := _diff(now, later)
	var ln := _lit(now)
	var ll := _lit(later)
	_ok("echoes life", round_trip.x < 0.0015 and moved.x > 0.002 and ll > ln * 0.6 and ll < ln * 1.6,
		("zeroed motion vs plain path: mean %.5f max %.4f; t0 vs t+600 s: mean %.5f max %.4f; "
			+ "lit %d -> %d") % [round_trip.x, round_trip.y, moved.x, moved.y, ln, ll])
	main.ifs.ambient = true
	for m in mats:
		m.set_shader_parameter(&"scroll", FractalIFS.SCROLL)


## Mean and max per-channel difference, sampled every other pixel.
func _diff(a: Image, b: Image) -> Vector2:
	var sum := 0.0
	var mx := 0.0
	var n := 0
	for y in range(0, a.get_height(), 2):
		for x in range(0, a.get_width(), 2):
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			var d := maxf(absf(ca.r - cb.r), maxf(absf(ca.g - cb.g), absf(ca.b - cb.b)))
			sum += d
			mx = maxf(mx, d)
			n += 1
	return Vector2(sum / float(n), mx)


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
