extends SceneTree

## GROUND's perturbation fill against df32, as pictures, on Mandelbrot tour stops: the
## minibrot GroundGuide stops at 1774x on its home tour, then smaller ones found round it,
## down to the deepest zoom the ground allows. Each stop is filled three ways, with the stop's
## nucleus pinned as GroundGuide does on a trip, with only the reference by the viewer, and
## with perturbation off (df32), and the two perturbation frames are diffed against df32.
## Two fills of the same kind are diffed too, the control: they must be identical. The fill
## time of each is printed: that wait is what a tour stop costs.
##
##   tools/pert_shot.sh            the 1774x stop only (df32 about 7 s on the M1)
##   STOPS=2 tools/pert_shot.sh    and a 22000x stop: df32 runs flat out for three minutes

const OUT := "res://.spike-out/pert"
## Where GroundGuide's home tour stops at 1774x (beacon_shot.sh): seed and period.
const FIRST := [-0.64011570248696, 0.37754570328187387, 41]

var main: Node
var g: FractalGround
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
	main.xr_camera.rotation_degrees = Vector3(-35.0, 0.0, 0.0)
	main._set_mode("ground")
	main.guide.enabled = false   # no scans pinning references behind the harness's back
	g = main.ground
	for i in 60:
		await process_frame

	var nu := GroundGuide.nucleus(FIRST[0], FIRST[1], FIRST[2])
	var stop := [nu[0], nu[1], FIRST[2], GroundGuide.size_estimate(nu[0], nu[1], FIRST[2])]
	var wpu_max: float = main.guide.wpu_max
	# STOPS=n in the environment: how many stops (default 1, the shallow one, light on the
	# GPU; deeper ones run df32 for minutes on the Mac).
	var stops := int(OS.get_environment("STOPS")) if OS.get_environment("STOPS") != "" else 1
	for k in stops:
		await _stop(k, stop)
		var deeper := _deeper(stop, wpu_max)
		if deeper.is_empty():
			print("PERTSHOT no deeper minibrot round stop %d" % k)
			break
		stop = deeper
	print("PERTSHOT %s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)


## A smaller minibrot near this one, at least 8x deeper and within the ground's range.
func _deeper(stop: Array, wpu_max: float) -> Array:
	var size: float = stop[3]
	var samples := []
	for j in 21:
		for i in 21:
			samples.append([stop[0] + size * 3.0 * (float(i) / 10.0 - 1.0),
				stop[1] + size * 3.0 * (float(j) / 10.0 - 1.0)])
	var found := GroundGuide.scan(samples, 20000)
	var w := GroundGuide.MINI_M / size
	for b in found:
		var wb: float = GroundGuide.MINI_M / float(b["size"])
		if wb > w * 8.0 and wb <= wpu_max and int(b["period"]) * GroundGuide.ITER_PER_PERIOD <= GroundGuide.ITER_HINT_MAX:
			return [b["x"], b["y"], b["period"], b["size"]]
	return []


func _stop(k: int, stop: Array) -> void:
	var p: int = stop[2]
	var w: float = minf(GroundGuide.MINI_M / float(stop[3]), main.guide.wpu_max)
	g.wpu = w
	g._sync_stage()
	# The nucleus AHEAD_M in front of a viewer at the origin facing -z, as a trip lands it.
	g.set_viewer_fractal(stop[0], stop[1] + GroundGuide.AHEAD_M / w)
	g.iter_hint = mini(GroundGuide.ITER_PER_PERIOD * p, GroundGuide.ITER_HINT_MAX)
	var tag := "stop%d" % k
	print("PERTSHOT %s zoom %.0fx period %d iter %d nucleus (%.17f, %.17f)" % [tag, w / FractalGround.WPU_BASE,
		p, g.effective_iter(), stop[0], stop[1]])
	g.perturb = true
	g.set_reference_nucleus(stop[0], stop[1], p)
	var pin := await _fill_and_shot(tag + "_pin")
	g.clear_reference_nucleus()
	var own := await _fill_and_shot(tag + "_own")
	# The control: the same fill twice. Whatever two identical fills differ by is run to run
	# (the floor levelling, temporal shading), not the fill.
	var own2 := await _fill_and_shot(tag + "_own2")
	g.perturb = false
	var df := await _fill_and_shot(tag + "_df")
	var df2 := await _fill_and_shot(tag + "_df2")
	g.perturb = true
	for pair: Array in [["own2(control)", own2, own], ["df2(control)", df2, df], ["pin", pin, df], ["own", own, df]]:
		var d := _diff(pair[1], pair[2], "%s/%s_diff_%s.png" % [OUT, tag, str(pair[0]).get_slice("(", 0)])
		print("PERTSHOT %s %s: mean %.4f, pixels off by >0.1: %.4f" % [tag, pair[0], d[0], d[1]])
		# The controls must be exact or the comparison means nothing. pert against df32 is
		# a report: they differ in grain on chaotic texels (ground_check.sh stop).
		if str(pair[0]).contains("control"):
			ok = ok and d[1] == 0.0


func _fill_and_shot(name: String) -> Image:
	g.invalidate()
	var t0 := Time.get_ticks_msec()
	var frames := 0
	for i in 5:
		await process_frame
	while frames < 6000 and g.progress() < 0.999:
		frames += 1
		await process_frame
	var full := g.progress() >= 0.999
	ok = ok and full
	for i in 5:
		await process_frame
	print("PERTSHOT fill %s: %.1f s, %d frames, progress %.3f %s" % [name,
		(Time.get_ticks_msec() - t0) / 1000.0, frames, g.progress(), "" if full else "TIMEOUT"])
	var img: Image = root.get_viewport().get_texture().get_image()
	img.save_png("%s/%s.png" % [OUT, name])
	return img


## Mean absolute RGB difference, and the fraction of pixels off by more than 0.1 in any channel.
## Saves the difference, times 4.
func _diff(a: Image, b: Image, path: String) -> Array:
	var out := Image.create(a.get_width(), a.get_height(), false, Image.FORMAT_RGB8)
	var sum := 0.0
	var big := 0
	var n := a.get_width() * a.get_height()
	for y in a.get_height():
		for x in a.get_width():
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			var d := Vector3(absf(ca.r - cb.r), absf(ca.g - cb.g), absf(ca.b - cb.b))
			sum += (d.x + d.y + d.z) / 3.0
			if maxf(d.x, maxf(d.y, d.z)) > 0.1:
				big += 1
			out.set_pixel(x, y, Color(minf(1.0, d.x * 4.0), minf(1.0, d.y * 4.0), minf(1.0, d.z * 4.0)))
	out.save_png(path)
	return [sum / float(n), float(big) / float(n)]
