extends SceneTree

## STYLE in GROUND, TREES and IFS through the real main scene: every style in every mode to
## .spike-out/style/<mode>_<style>.png, then natural again, which must match the first
## natural shot (STYLE must put the old look back). A blank frame fails.
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
