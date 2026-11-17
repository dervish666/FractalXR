extends SceneTree

## NEAR on the ground: the per-pixel escape where texels span pixels. The same view with
## NEAR off and on, natural and neon, at about the headset's pixels per degree, to
## .spike-out/near/. The two must agree on the picture (a small mean difference: the
## per-pixel count is the texture's own maths, only finer) and must differ somewhere (the
## control: NEAR did something). Light: one shallow view, no deep fill.
##
##   tools/near_shot.sh

const OUT := "res://.spike-out/near"

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
	main.xr_camera.rotation_degrees = Vector3(-40.0, 0.0, 0.0)
	main._set_mode("ground")
	main.ground.centre = Vector2(-0.55, 0.62)
	for i in 240:
		await process_frame
	var ok := true
	for st in [0, 1]:
		main._set_art(st)
		main.ground.near_iter = 0
		for i in 20:
			await process_frame
		var off: Image = root.get_viewport().get_texture().get_image()
		main.ground.near_iter = 256
		for i in 20:
			await process_frame
		var on: Image = root.get_viewport().get_texture().get_image()
		var name: String = FractalMain.ART_NAMES[st]
		off.save_png("%s/%s_off.png" % [OUT, name])
		on.save_png("%s/%s_on.png" % [OUT, name])
		var d := _diff(off, on)
		# Natural must agree closely; neon draws lines a pixel wide, so a sharper count
		# moves more of them.
		var lim := 0.04 if st == 0 else 0.08
		var good := d.x < lim and d.y > 0.001
		ok = ok and good
		print("NEARSHOT %s %s mean=%.4f changed=%.4f" % [name, "PASS" if good else "FAIL", d.x, d.y])
	print("NEARSHOT %s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)


## x: mean absolute luma difference; y: share of sampled pixels that moved past 0.1.
func _diff(a: Image, b: Image) -> Vector2:
	var n := 0
	var sum := 0.0
	var moved := 0
	var step := maxi(1, a.get_width() / 200)
	for y in range(0, a.get_height(), step):
		for x in range(0, a.get_width(), step):
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			var la := 0.2126 * ca.r + 0.7152 * ca.g + 0.0722 * ca.b
			var lb := 0.2126 * cb.r + 0.7152 * cb.g + 0.0722 * cb.b
			sum += absf(la - lb)
			moved += 1 if absf(la - lb) > 0.1 else 0
			n += 1
	return Vector2(sum / n, float(moved) / n)
