extends SceneTree

## STYLE in GROUND, TREES and IFS through the real main scene: every style in every mode to
## .spike-out/style/<mode>_<style>.png, then natural again, which must match the first
## natural shot (STYLE must put the old look back). A blank frame fails.
## Also per mode: LANTERN (V9) lit by hand, since there are no controllers here, to
## <mode>_lantern.png, which must change the picture and go away again; and TREE's forest
## (and V7's motes with it) drawn in TREE only.
##
##   tools/style_shot.sh
##   STYLE_MODES=ground tools/style_shot.sh    # the ground only

const OUT := "res://.spike-out/style"

var main: Node
var ok := true


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var scene: PackedScene = load("res://main.tscn")
	main = scene.instantiate()
	root.add_child(main)
	for i in 40:
		await process_frame
	main.help.close()
	main.xr_camera.position = Vector3(0.0, 1.6, 0.0)

	main.xr_camera.rotation_degrees = Vector3(-22.0, 0.0, 0.0)
	main._set_mode("ground")
	main.ground.centre = Vector2(-0.55, 0.62)
	for i in 240:
		await process_frame
	await _styles("ground")

	# STYLE_MODES=ground stops here: the light run for work on the ground alone.
	if OS.get_environment("STYLE_MODES") == "ground":
		print("STYLESHOT %s" % ("PASS" if ok else "FAIL"))
		quit(0 if ok else 1)
		return

	main.xr_camera.rotation_degrees = Vector3(-8.0, 0.0, 0.0)
	main._set_mode("tree")
	var frames := 0
	while main.tree.grow_t < FractalTree.GROW_S + 2.5 and frames < 4000:
		frames += 1
		await process_frame
	await _styles("tree")

	main.xr_camera.rotation_degrees = Vector3(-19.0, 0.0, 0.0)
	main._set_mode("ifs")
	# Grow-in runs on its own clock: wait it out in time, not frames.
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 5000:
		await process_frame
	await _styles("ifs")
	print("STYLESHOT %s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)


func _styles(mode: String) -> void:
	const MIN_DIFF := 0.05
	const MIN_LIT_RATIO := 0.35
	for st in FractalMain.ART_NAMES.size():
		main._set_art(st)
		for i in 30:
			await process_frame
		var img: Image = root.get_viewport().get_texture().get_image()
		var name: String = "%s_%s" % [mode, FractalMain.ART_NAMES[st]]
		img.save_png("%s/%s.png" % [OUT, name])
		var sp := _spread(img)
		ok = ok and sp > 0.02
		print("STYLESHOT %s %s spread=%.3f" % [name, "PASS" if sp > 0.02 else "FAIL", sp])

	# Frozen distinctness sweep for physical finishes (5..12): still moving geometry and
	# overlays that ignore art_style (TREE's wind, leaves and motes; IFS's ambient breath,
	# echoes clock and palette scroll) so identical shaders compare near zero.
	var ifs_amb0: bool = main.ifs.ambient
	if mode == "tree":
		main._set_forest_wind(0.0)
		main.forest._motes.visible = false
		main._set_forest_leaves(false)
		for i in 8:
			await process_frame
	elif mode == "ifs":
		main.ifs.ambient = false
		main.ifs.build(false)
		main.ifs._mat.set_shader_parameter("scroll", 0.0)
		for p in main.ifs_echoes._pool:
			p._mat.set_shader_parameter("scroll", 0.0)
		for i in 6:
			await process_frame
	main._set_art(0)
	for i in 4:
		await process_frame
	var nat: Image = root.get_viewport().get_texture().get_image()
	var nat_lit := _lit_frac(nat)
	var shots: Dictionary = {}
	for st in range(5, FractalMain.ART_NAMES.size()):
		main._set_art(st)
		for i in 4:
			await process_frame
		shots[st] = root.get_viewport().get_texture().get_image()
	# Unmapped style index: exercises physical_finish's plain fallback so a deleted branch or
	# fall-through finish matches it and fails.
	RenderingServer.global_shader_parameter_set(&"art_style", 99)
	for i in 4:
		await process_frame
	var fb: Image = root.get_viewport().get_texture().get_image()
	main._set_art(0)
	if mode == "tree":
		main._set_forest_wind(FractalMain.TREE_WIND[main.tree_wind_idx])
		main.forest._motes.visible = true
		main._set_forest_leaves(true)
	elif mode == "ifs":
		main.ifs.ambient = ifs_amb0
		main.ifs._mat.set_shader_parameter("scroll", FractalIFS.SCROLL)
		for p in main.ifs_echoes._pool:
			p._mat.set_shader_parameter("scroll", FractalIFS.SCROLL)
	for st in range(5, FractalMain.ART_NAMES.size()):
		var img: Image = shots[st]
		var sname: String = FractalMain.ART_NAMES[st]
		var sp := _spread(img)
		var lit_ratio := _lit_frac(img) / maxf(nat_lit, 1e-4)
		var d_nat := _lit_diff(nat, img)
		var d_fb := _lit_diff(fb, img)
		var near_d := 1e9
		var near_name := ""
		for other in range(5, FractalMain.ART_NAMES.size()):
			if other == st:
				continue
			var dp := _lit_diff(img, shots[other])
			if dp < near_d:
				near_d = dp
				near_name = FractalMain.ART_NAMES[other]
		var f_ok := sp > 0.02 and lit_ratio >= MIN_LIT_RATIO and d_nat >= MIN_DIFF \
			and d_fb >= MIN_DIFF and near_d >= MIN_DIFF
		ok = ok and f_ok
		print("STYLESHOT %s finish %s %s lit_ratio=%.2f vs_nat=%.4f vs_fb=%.4f nearest=%s(%.4f)" % [
			mode, sname, "PASS" if f_ok else "FAIL", lit_ratio, d_nat, d_fb, near_name, near_d])
	# STYLE must put the old look back. Natural, a style, natural again a few frames apart,
	# so palette drift and wind have no time to move anything.
	main._set_art(0)
	for i in 4:
		await process_frame
	var a: Image = root.get_viewport().get_texture().get_image()
	main._set_art(1)
	for i in 3:
		await process_frame
	var styled: Image = root.get_viewport().get_texture().get_image()
	main._set_art(0)
	for i in 3:
		await process_frame
	var b: Image = root.get_viewport().get_texture().get_image()
	var d := _diff(a, b)
	# The control: the styled frame must differ, or the comparison could not have failed.
	var dc := _diff(a, styled)
	var good := d < 0.01 and dc > 0.015
	ok = ok and good
	print("STYLESHOT %s back_to_natural %s diff=%.4f control=%.4f" % [mode, "PASS" if good else "FAIL", d, dc])

	# The forest, motes and all, belongs to TREE: it drew in every mode until TREE was left once.
	var forest_ok: bool = main.forest.visible == (mode == "tree")
	ok = ok and forest_ok
	print("STYLESHOT %s forest_visible=%s %s" % [mode, str(main.forest.visible), "PASS" if forest_ok else "FAIL"])

	# LANTERN: main.gd only lights it from a tracked controller, so set its globals by hand at a
	# point just off this mode's subject, then put them back.
	# TREE sways in the wind, which moves more pixels than the light does: still it first and
	# compare against a frame taken just before lighting, not the natural frame from earlier.
	var at: Vector3 = {"ground": Vector3(0.0, 0.35, -2.0), "tree": Vector3(0.25, 1.1, -0.9),
		"ifs": Vector3(0.22, 1.42, -0.5)}[mode]
	if mode == "tree":
		main._set_forest_wind(0.0)
		# Next to the hero tree's trunk, a metre up and a little toward the eye: the forest
		# fills little of the frame, so a light in open air barely beat the motes' flicker.
		var trunk: Vector3 = main.tree.global_position + Vector3(0.0, 1.0, 0.0)
		at = trunk + (main.xr_camera.global_position - trunk).normalized() * 0.35
		# The motes drift and twinkle, and the leaves flutter, whatever WIND says
		# (tree_leaf.gdshader); neither reads the lantern, so both go for the capture.
		main.forest._motes.visible = false
		main._set_forest_leaves(false)
	for i in 12:
		await process_frame
	var pre: Image = root.get_viewport().get_texture().get_image()
	RenderingServer.global_shader_parameter_set(&"hand_light_pos", at)
	# Three times the lantern in TREE: a thin trunk catches little light, and the branches' own
	# flutter moves the window by 0.002-0.003 a frame. The check is on and off, not how bright.
	var boost := 3.0 if mode == "tree" else 1.0
	RenderingServer.global_shader_parameter_set(&"hand_light_col", Vector3(1.0, 0.9, 0.76) * 0.95 * boost)
	for i in 3:
		await process_frame
	var lit: Image = root.get_viewport().get_texture().get_image()
	lit.save_png("%s/%s_lantern.png" % [OUT, mode])
	RenderingServer.global_shader_parameter_set(&"hand_light_col", Vector3.ZERO)
	for i in 3:
		await process_frame
	var off: Image = root.get_viewport().get_texture().get_image()
	if mode == "tree":
		main._set_forest_wind(FractalMain.TREE_WIND[main.tree_wind_idx])
		main.forest._motes.visible = true
		main._set_forest_leaves(true)
	# Signed: the lantern only adds light, while sway and motes move pixels both ways and
	# average out, which an absolute difference cannot tell apart.
	# Within a window round the light's place on screen: the light falls off within a metre or
	# so, and the rest of the frame only adds whatever else moves (TREE's leaves and LOD).
	var cam: Camera3D = root.get_viewport().get_camera_3d()
	var sp := cam.unproject_position(at)
	var rad := 0.2 * float(pre.get_width())
	var dl := _brighter(pre, lit, sp, rad)
	var doff := _brighter(pre, off, sp, rad)
	var lantern_ok := dl > 0.002 and absf(doff) < 0.3 * dl
	ok = ok and lantern_ok
	print("STYLESHOT %s lantern %s lit=%.4f off=%.4f" % [mode, "PASS" if lantern_ok else "FAIL", dl, doff])


func _spread(img: Image) -> float:
	var n := 0
	var sum := 0.0
	var sum2 := 0.0
	var step := maxi(1, img.get_width() / 80)
	for y in range(0, img.get_height(), step):
		for x in range(0, img.get_width(), step):
			var c := img.get_pixel(x, y)
			var l := 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
			sum += l
			sum2 += l * l
			n += 1
	var mean := sum / float(maxi(n, 1))
	return sqrt(maxf(sum2 / float(maxi(n, 1)) - mean * mean, 0.0))


## Mean absolute luma difference over a sample grid.
func _diff(a: Image, b: Image) -> float:
	var n := 0
	var sum := 0.0
	var step := maxi(1, a.get_width() / 80)
	for y in range(0, a.get_height(), step):
		for x in range(0, a.get_width(), step):
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			sum += absf((ca.r + ca.g + ca.b) - (cb.r + cb.g + cb.b)) / 3.0
			n += 1
	return sum / float(maxi(n, 1))


## Share of the sample grid with luminance above 0.02.
func _lit_frac(img: Image) -> float:
	var n := 0
	var lit := 0
	var step := maxi(1, img.get_width() / 80)
	for y in range(0, img.get_height(), step):
		for x in range(0, img.get_width(), step):
			n += 1
			if img.get_pixel(x, y).get_luminance() > 0.02:
				lit += 1
	return float(lit) / float(maxi(n, 1))


## Mean per-channel RGB difference over the union of lit (luma > 0.02) pixels.
func _lit_diff(a: Image, b: Image) -> float:
	var n := 0
	var sum := 0.0
	var step := maxi(1, a.get_width() / 80)
	for y in range(0, a.get_height(), step):
		for x in range(0, a.get_width(), step):
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			if ca.get_luminance() <= 0.02 and cb.get_luminance() <= 0.02:
				continue
			sum += (absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)) / 3.0
			n += 1
	return sum / float(maxi(n, 1))


## Mean signed brightness gain from a to b on a sample grid, within rad pixels of centre.
func _brighter(a: Image, b: Image, centre: Vector2, rad: float) -> float:
	var n := 0
	var sum := 0.0
	var step := maxi(1, a.get_width() / 160)
	for y in range(0, a.get_height(), step):
		for x in range(0, a.get_width(), step):
			if Vector2(x, y).distance_to(centre) > rad:
				continue
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			sum += ((cb.r + cb.g + cb.b) - (ca.r + ca.g + ca.b)) / 3.0
			n += 1
	return sum / float(maxi(n, 1))
