extends SceneTree

## BEACONS and TOUR through the real main scene. First the maths against nuclei known to
## many digits, then GROUND's Mandelbrot home: a scan must find beacons, a trip to the first
## must land on its nucleus at its depth (ornament, then the minibrot), and the tour, run at
## speed, must go deeper twice. Shots to .spike-out/beacon/.
##
##   tools/beacon_shot.sh

const OUT := "res://.spike-out/beacon"
## Nuclei to check Newton against: seed, period, the known nucleus.
const KNOWN := [
	[-1.0, 0.05, 2, -1.0, 0.0],
	[-0.12, 0.74, 3, -0.12256116687665361, 0.7448617666197442],
	[-1.75, 0.01, 3, -1.7548776662466927, 0.0],
	[-1.3, 0.05, 4, -1.3107026413368328, 0.0],
]

var main: Node
var ok := true


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	for k in KNOWN:
		var n := GroundGuide.nucleus(k[0], k[1], k[2])
		var err := Vector2(n[0] - k[3], n[1] - k[4]).length()
		var good: bool = n[2] and err < 1e-12 and GroundGuide.exact_period(n[0], n[1], k[2]) == k[2]
		ok = ok and good
		print("BEACON nucleus p=%d err=%s %s" % [k[2], str(err), "PASS" if good else "FAIL"])
	# The control: a period-4 seed beside the period-2 disc must not report period 4 once
	# Newton has slid into the disc's own nucleus, or exact_period could never say no.
	var slid := GroundGuide.exact_period(-1.0, 0.0, 4)
	ok = ok and slid == 2
	print("BEACON exact_period control (-1, 0) as p=4 -> %d %s" % [slid, "PASS" if slid == 2 else "FAIL"])

	var scene: PackedScene = load("res://main.tscn")
	main = scene.instantiate()
	root.add_child(main)
	for i in 40:
		await process_frame
	main.help.close()
	main.xr_camera.position = Vector3(0.0, 1.6, 0.0)
	main.xr_camera.rotation_degrees = Vector3(-35.0, 0.0, 0.0)
	main._set_mode("ground")
	for i in 200:
		await process_frame
	var g: GroundGuide = main.guide
	g.finish_scan()
	for i in 10:
		await process_frame
	print("BEACON scan: %d beacons" % g.beacons.size())
	for b in g.beacons:
		print("BEACON   p=%d size=%s" % [b["period"], str(b["size"])])
	ok = ok and g.beacons.size() > 0
	await _shot("home")
	if g.beacons.is_empty():
		_end()
		return

	# A trip to the first, at pick pace.
	var b: Dictionary = g.beacons[0]
	g.go_to(b, GroundGuide.PICK_MPS * 4.0, GroundGuide.PICK_EFOLD_PER_S * 4.0)
	# Two stops when the ornament is a real stop on the way, one when the minibrot is close.
	var want_stops := 2 if g.trip["then"] != null else 1
	var stops := 0
	var t0 := g.arrivals
	var frames := 0
	while frames < 6000 and (g.arrivals - t0 < want_stops):
		frames += 1
		await process_frame
		if g.arrivals - t0 > stops:
			stops = g.arrivals - t0
			await _hold_and_shot("trip_%d" % stops)
	# The nucleus must sit on the spot ahead, measured in fractal units against its size.
	var hp: Vector3 = main.xr_camera.global_transform.origin
	var spot := Vector2(hp.x, hp.z) + g.facing * GroundGuide.AHEAD_M
	var off: float = (main.ground.fractal64_to_world(b["x"], b["y"]) - spot).length() / main.ground.wpu
	var want_wpu := minf(GroundGuide.MINI_M / float(b["size"]), g.wpu_max)
	var depth_err := absf(log(main.ground.wpu / want_wpu))
	var landed: bool = stops == want_stops and off < float(b["size"]) * 0.05 and depth_err < 0.02
	ok = ok and landed
	print("BEACON trip p=%d stops=%d/%d off=%s (size %s) wpu=%.0f want=%.0f %s" % [b["period"], stops, want_stops,
		str(off), str(b["size"]), main.ground.wpu, want_wpu, "PASS" if landed else "FAIL"])

	# The tour, at speed: two more arrivals, each deeper than the last.
	g.tour_mps = 3.0
	g.tour_efold_per_s = 2.0
	g.tour_dwell_s = 0.5
	g.set_tour(true)
	var w0: float = main.ground.wpu
	var a0 := g.arrivals
	frames = 0
	var seen := 0
	while frames < 40000 and g.arrivals - a0 < 6:
		frames += 1
		await process_frame
		if g.arrivals - a0 > seen:
			seen = g.arrivals - a0
			var hq: Vector3 = main.xr_camera.global_transform.origin
			var spot2: Vector2 = Vector2(hq.x, hq.z) + g.facing * GroundGuide.AHEAD_M
			var sf: PackedFloat64Array = main.ground.world_to_fractal64(spot2)
			print("BEACON tour stop %d zoom %.0fx period %d spot %s %s wpu %s iter %d" % [seen,
				main.ground.wpu / FractalGround.WPU_BASE, g.last_period, var_to_str(sf[0]),
				var_to_str(sf[1]), var_to_str(main.ground.wpu), main.ground.effective_iter()])
			if seen % 2 == 0:
				await _hold_and_shot("tour_%d" % seen)
	var deeper: bool = g.arrivals - a0 >= 2 and main.ground.wpu > w0 * 2.0
	ok = ok and deeper
	print("BEACON tour arrivals=%d zoom %.0fx -> %.0fx %s" % [g.arrivals - a0,
		w0 / FractalGround.WPU_BASE, main.ground.wpu / FractalGround.WPU_BASE, "PASS" if deeper else "FAIL"])
	g.set_tour(false)
	_end()


func _hold_and_shot(name: String) -> void:
	# Let the fill land before the picture, and say how long it took: at tens of thousands
	# of iterations that wait is what a viewer sits through.
	main.guide.paused = true
	var t0 := Time.get_ticks_msec()
	var frames := 0
	for i in 10:
		await process_frame
	while frames < 2500 and main.ground.progress() < 0.999:
		frames += 1
		main.guide.paused = true
		await process_frame
	print("BEACON fill %s iter %d: %d frames, %.1f s, progress %.2f" % [name, main.ground.effective_iter(), frames,
		(Time.get_ticks_msec() - t0) / 1000.0, main.ground.progress()])
	main.guide.paused = false
	await _shot(name)


func _shot(name: String) -> void:
	var img: Image = root.get_viewport().get_texture().get_image()
	img.save_png("%s/%s.png" % [OUT, name])
	print("BEACON shot %s.png zoom %.0fx beacons=%d" % [name, main.ground.wpu / FractalGround.WPU_BASE,
		main.guide.beacons.size()])


func _end() -> void:
	print("BEACON %s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)
