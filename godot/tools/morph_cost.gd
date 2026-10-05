extends SceneTree

## Script cost of a flame preset morph, per frame, on the desktop. The headset log showed
## proc_ms at 12-15 for the whole ~5 s of every morph; this times the same frames here so a
## fix can be measured before it goes on the Quest.
##
## Two runs, menu closed and menu pinned open (the headset session restored a pinned menu),
## each reporting the mean and max of main.gd's own _process time over the morph frames and
## over the settled frames after it. Then the morph path's pieces in isolation, so the
## culprit has a name. Mac numbers: the Quest's cores run GDScript several times slower.
##
##   tools/morph_cost.sh

var main: Node


func _init() -> void:
	var scene: PackedScene = load("res://main.tscn")
	main = scene.instantiate()
	root.add_child(main)
	for i in 60:
		await process_frame
	if not main._setup_done:
		print("MORPHCOST FAIL setup never finished: %s" % main._status)
		quit(1)
		return
	main.morph_idx = MORPH_IDX_FAST
	var closed := await _run_morph(false)
	var open := await _run_morph(true)
	_bench_pieces()
	var same := _check_plan()
	var verdict := "PASS" if closed["morph_mean"] < 2.0 and open["morph_mean"] < 2.0 and same else "FAIL"
	print("MORPHCOST %s closed_mean=%.3f open_mean=%.3f (ms, budget 2.0) plan_matches=%s" % [
		verdict, closed["morph_mean"], open["morph_mean"], str(same)])
	quit(0)


## The 3 s transition (MORPH_STEPS[5]) is enough frames on an unthrottled Mac.
const MORPH_IDX_FAST := 5


func _run_morph(menu_open: bool) -> Dictionary:
	main.menu.set_pinned(menu_open, true)
	for i in 30:
		await process_frame
	var settled_before := await _sample(60)
	print("MORPHCOST menu state: visible=%s shown=%.2f pinned=%s layer=%s" % [
		str(main.menu.visible), main.menu._shown, str(main.menu.is_pinned()), str(main.menu._layer != null)])
	main._morph_to_preset(main.preset_idx + 1)
	var during: Array = []
	var guard := 0
	while main._morph_t < 1.0 and guard < 4000:
		during.append(await _one())
		guard += 1
	var after := await _sample(60)
	var r := {
		"morph_mean": _mean(during), "morph_max": _max(during), "frames": during.size(),
		"idle_mean": _mean(settled_before), "after_mean": _mean(after),
	}
	print("MORPHCOST menu=%s frames=%d morph_mean_ms=%.3f morph_max_ms=%.3f idle_mean_ms=%.3f after_mean_ms=%.3f" % [
		"open" if menu_open else "closed", r["frames"], r["morph_mean"], r["morph_max"],
		r["idle_mean"], r["after_mean"]])
	return r


## main.gd's own _process time for the next frame, in ms. _perf_tail zeroes the sums on
## its own clock, so a reset mid-frame is read as the frame starting from zero.
func _one() -> float:
	var s0: int = main._proc_us_sum
	var f0: int = main._proc_frames
	await process_frame
	var s1: int = main._proc_us_sum
	var f1: int = main._proc_frames
	var us := s1 - s0 if f1 > f0 else s1
	return float(us) / 1000.0


func _sample(n: int) -> Array:
	var out: Array = []
	for i in n:
		out.append(await _one())
	return out


func _mean(a: Array) -> float:
	if a.is_empty():
		return -1.0
	var s := 0.0
	for x in a:
		s += x
	return s / float(a.size())


func _max(a: Array) -> float:
	var m := 0.0
	for x in a:
		m = maxf(m, x)
	return m


## Each piece of the morph frame, called N times back to back.
func _bench_pieces() -> void:
	const N := 200
	var a: Dictionary = main.library.at(0)
	var b: Dictionary = main.library.at(1)
	var g := Morph.interpolate(a, b, 0.5)
	var src: FlameSource = main.cloud.source as FlameSource
	var pal: Array = PresetLibrary.palette_of(g)
	var plan := Morph.plan(a, b)
	var flat := PackedFloat32Array()
	var pieces := {
		"Morph.interpolate": func(): Morph.interpolate(a, b, 0.5),
		"_apply_tone": func(): main._apply_tone(g),
		"src.set_preset": func(): src.set_preset(g),
		"src.update_params": func(): RenderingServer.call_on_render_thread(src.update_params),
		"cloud.override_palette": func(): main.cloud.override_palette(pal),
		"menu.set_palette": func(): main.menu.set_palette(pal),
		"march.set_palette": func(): main.march.set_palette(pal),
		"_apply_palette": func(): main._apply_palette(),
		"Morph.plan (once/morph)": func(): Morph.plan(a, b),
		"Plan.sample+palette+tone": func():
			var p: Morph.Plan = plan
			p.sample(0.5, flat)
			p.palette_at(0.5)
			p.tone_at(0.5),
		"src.set_frame": func(): src.set_frame(flat, plan.n, plan.palette_at(0.5), plan.name),
		"menu._apply_theme": func(): main.menu._apply_theme(),
		"menu._refresh": func(): main.menu._refresh(),
		"menu.update": func(): main.menu.update(1.0 / 72.0),
	}
	if src == null:
		pieces.erase("src.set_preset")
		pieces.erase("src.update_params")
	for k in pieces:
		var c: Callable = pieces[k]
		var t0 := Time.get_ticks_usec()
		for i in N:
			c.call()
		var ms := float(Time.get_ticks_usec() - t0) / 1000.0 / float(N)
		print("MORPHCOST piece %-24s %.4f ms" % [k, ms])


## The Plan path must encode the same 224 floats as the Dictionary path it replaced, for
## every pair of presets and through the whole curve. Falsified by a deliberately wrong t.
func _check_plan() -> bool:
	var lib = main.library
	var worst := 0.0
	var control := 0.0
	var flat := PackedFloat32Array()
	var live := PackedFloat32Array()
	for i in lib.count():
		for j in [i + 1, i + 3, i + 7]:
			var a: Dictionary = lib.at(i)
			var b: Dictionary = lib.at(j)
			var plan := Morph.plan(a, b)
			for t in [0.0, 0.13, 0.5, 0.77, 1.0]:
				var g := Morph.interpolate(a, b, t)
				var ref := FlameSource.new(g).param_buffer_floats()
				plan.sample(t, flat)
				FlameSource.encode_into(live, flat, plan.n, plan.palette_at(t))
				worst = maxf(worst, _diff(ref, live))
				# Control: the plan sampled at the wrong t must NOT match.
				if t == 0.5:
					plan.sample(0.6, flat)
					FlameSource.encode_into(live, flat, plan.n, plan.palette_at(0.6))
					control = maxf(control, _diff(ref, live))
				var tone := plan.tone_at(t)
				var tref := PresetLibrary.tone_of(g)
				for k in tref:
					worst = maxf(worst, absf(float(tref[k]) - float(tone[k])))
	print("MORPHCOST plan vs interpolate: worst_abs_diff=%.7f control_diff=%.5f" % [worst, control])
	return worst < 1e-4 and control > 1e-3


func _diff(x: PackedFloat32Array, y: PackedFloat32Array) -> float:
	if x.size() != y.size():
		return INF
	var m := 0.0
	for k in x.size():
		m = maxf(m, absf(x[k] - y[k]))
	return m
