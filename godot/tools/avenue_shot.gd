extends SceneTree

## Integration proof for TREE's avenue through the real main scene, shot from where you
## stand. The standing avenue: two rows clear of the path, spaced as specified, out to 50 m,
## growing as a wave away from you with the palette phase walking down the rows, and the hero
## out of the path. The walk: a fixed pool of 30, only the first 25 m sprouted, the root
## sliding toward a still viewer while G is held, trees recycled to the far end with no
## rebuild, nothing drawn past 25 m ahead or 5 m behind, the vignette up while moving and
## gone once stopped. Saves .spike-out/avenue_wave.png, avenue.png, walk_start.png,
## walk_moving.png (vignette on) and walk.png.
##
##   tools/avenue_shot.sh

const SPEED := 4.0    # forest clocks run on frame delta; this only shortens the waits
const WALK_GAME_S := 90.0


func _init() -> void:
	var scene: PackedScene = load("res://main.tscn")
	var main := scene.instantiate()
	root.add_child(main)
	for i in 40:
		await process_frame
	main.help.close()
	main.xr_camera.position = Vector3(0.0, 1.6, 0.0)
	main.xr_camera.rotation_degrees = Vector3(-3.0, 0.0, 0.0)
	for i in 3:
		await process_frame
	main.forest.grove_seed = 4321
	main.spin = true
	main._set_mode("tree")
	for i in 3:
		await process_frame
	var forest: Forest = main.forest
	var bad: Array[String] = []

	# --- The standing avenue -------------------------------------------------------------
	var sow_t0 := Time.get_ticks_usec()
	main._sow_avenue(false)
	var sow_avenue_ms := float(Time.get_ticks_usec() - sow_t0) / 1000.0
	await process_frame
	if forest.layout != Forest.Layout.AVENUE:
		bad.append("AVENUE did not set the layout")
	if main.tree.visible:
		bad.append("the hero still stands in the path")
	var rows := _rows(forest)
	bad.append_array(_check_rows(rows, Forest.AVENUE_LEN + 0.5))
	# The wave: sprout delay rises with distance (jitter 0.3 s), and the palette phase walks.
	var by_dist: Array = []
	for t in forest.trees():
		by_dist.append([-t.position.z, t.sprout_delay, t.palette_phase])
	by_dist.sort_custom(func(a, b): return a[0] < b[0])
	var wave_ok := true
	var phase_ok := true
	for i in by_dist.size():
		if i > 0 and by_dist[i][1] < by_dist[i - 1][1] - 0.31:
			wave_ok = false
		var want: float = Forest.AVENUE_PHASE_SPAN * by_dist[i][0] / Forest.AVENUE_LEN
		if absf(by_dist[i][2] - want) > Forest.AVENUE_PHASE_JITTER + 1e-3:
			phase_ok = false
	if not wave_ok:
		bad.append("sprouting does not roll away from the viewer")
	if not phase_ok:
		bad.append("palette phase does not follow distance")
	var first_delay: float = by_dist[0][1]
	var last_delay: float = by_dist[-1][1]

	# Mid-wave: near trees up, far ones still to come.
	Engine.time_scale = SPEED
	while _sprouted_frac(forest) < 0.5:
		await process_frame
	var mid_grown := _grown_frac(forest)
	var mid_unsprouted := 0
	for t in forest.trees():
		if t.grow_t <= 0.0:
			mid_unsprouted += 1
	Engine.time_scale = 1.0
	await process_frame
	_save("avenue_wave")
	Engine.time_scale = SPEED
	var frames := 0
	while frames < 8000 and _grown_frac(forest) < 1.0:
		frames += 1
		await process_frame
	Engine.time_scale = 1.0
	for i in 30:
		await process_frame   # LOD settles at real speed
	forest.apply_lod(main.xr_camera.global_position)
	var cost_avenue := forest.visible_cost
	var branches_avenue := forest.branch_total()
	var leaves_avenue := forest.leaf_total()
	_save("avenue")
	if mid_unsprouted == 0:
		bad.append("mid-wave shot had every tree sprouted: no wave to see")
	print("AVENUESHOT standing trees=%d rows=%d/%d wave=%.1f->%.1fs mid_grown=%.2f mid_unsprouted=%d branches=%d leaves=%d visible=%d budget=%d build_ms mean=%.2f max=%.2f builds=%d" % [
		forest.tree_count(), rows[0].size(), rows[1].size(), first_delay, last_delay, mid_grown,
		mid_unsprouted, branches_avenue, leaves_avenue, cost_avenue, forest.budget,
		forest.build_us_sum / 1000.0 / maxf(1.0, forest.builds), forest.build_us_max / 1000.0,
		forest.builds])

	# Planting still works in the standing avenue.
	if not main._plant_tree_at(Vector2(0.0, -6.0)):
		bad.append("could not plant in the standing avenue")

	# Script time standing still, for comparison with walking.
	var still := _meter(main)
	for i in 120:
		await process_frame
		_sample(main, still)

	# --- The walk -------------------------------------------------------------------------
	sow_t0 = Time.get_ticks_usec()
	main._toggle_walk()
	var sow_walk_ms := float(Time.get_ticks_usec() - sow_t0) / 1000.0
	var pool := _meter(main)
	var builds_seen := forest.builds
	var builds_pre_walk := forest.builds
	var back_to_back := 0
	var built_last := false
	await process_frame
	if not forest.walking():
		bad.append("WALK did not start the walk")
	if forest.tree_count() != Forest.WALK_PER_ROW * 2:
		bad.append("pool is %d trees, expected %d" % [forest.tree_count(), Forest.WALK_PER_ROW * 2])
	if main.plant_marker.visible:
		bad.append("planting ring shows while walking")
	rows = _rows(forest)
	bad.append_array(_check_rows(rows, 1e9))
	for t in forest.trees():
		var ahead: float = -t.position.z
		if (ahead < Forest.WALK_SPROUT) != (t.grow_rate > 0.0):
			bad.append("tree %.1f m ahead: sprouting=%s" % [ahead, str(t.grow_rate > 0.0)])
			break
	Engine.time_scale = SPEED
	frames = 0
	while frames < 6000:
		frames += 1
		await process_frame
		_sample(main, pool)
		var built_now := forest.builds != builds_seen
		builds_seen = forest.builds
		if built_now and built_last:
			back_to_back += 1
		built_last = built_now
		var near_grown := true
		for t in forest.trees():
			if t.grow_rate > 0.0 and (not t.built or t.grow_t < t.grow_s + 1.0):
				near_grown = false
		if near_grown:
			break
	Engine.time_scale = 1.0
	for i in 30:
		await process_frame
	var pool_build_max: float = pool["max"] / 1000.0
	if back_to_back > 0:
		bad.append("%d builds landed on the frame after another build" % back_to_back)
	if forest.builds - builds_pre_walk != Forest.WALK_PER_ROW * 2:
		bad.append("expected each pool tree built once at sow, got %d builds" % (forest.builds - builds_pre_walk))
	print("AVENUESHOT sow avenue=%.2fms walk=%.2fms (node creation, the press frame) pool build frames max=%.2fms back_to_back=%d" % [
		sow_avenue_ms, sow_walk_ms, pool_build_max, back_to_back])
	_save("walk_start")
	var builds_before := forest.builds
	var root_before: Vector3 = forest.get_node("Avenue").global_position
	var eye_before: Vector3 = main.xr_camera.global_position

	# Hold G (the desktop's stand-in for a held trigger) and glide.
	_key(KEY_G, true)
	for i in 3:
		await process_frame
	if not forest.walk_held:
		bad.append("G held did not read as a held trigger")
	var walking := _meter(main)
	var t_game := 0.0
	var seen_far := 0.0      # furthest ahead any drawn tree stood
	var seen_behind := 0.0   # furthest behind any drawn tree stood
	var passed_young := 0
	Engine.time_scale = SPEED * 2.0
	while t_game < WALK_GAME_S:
		await process_frame
		_sample(main, walking)
		t_game = forest.walked / Forest.WALK_SPEED
		var av: Node3D = forest.get_node("Avenue")
		var ez: float = av.to_local(main.xr_camera.global_position).z
		for t in forest.trees():
			if t.grow_t <= 0.0:
				continue
			var ahead: float = ez - t.position.z
			seen_far = maxf(seen_far, ahead)
			seen_behind = minf(seen_behind, ahead)
			if absf(ahead) < 0.5 and t.grow_rate > 0.0 and t.grow_t < t.grow_s + 1.0:
				passed_young += 1
	Engine.time_scale = 1.0
	for i in 40:
		await process_frame   # real speed, so the vignette shot is at full motion
		_sample(main, walking)
	var vig_on: bool = main.vignette.visible and main.vignette.motion > 0.99
	_save("walk_moving")
	var moved: float = forest.get_node("Avenue").global_position.distance_to(root_before)
	var walked_then := forest.walked
	var eye_moved: float = main.xr_camera.global_position.distance_to(eye_before)

	_key(KEY_G, false)
	var stop_frames := 0
	var stop_us := Time.get_ticks_usec()
	while forest.walk_speed > 0.0 and stop_frames < 2000:
		stop_frames += 1
		await process_frame
	var stop_s := float(Time.get_ticks_usec() - stop_us) / 1e6
	await process_frame
	var vig_off: bool = not main.vignette.visible
	for i in 10:
		await process_frame
	_save("walk")
	rows = _rows(forest)
	bad.append_array(_check_rows(rows, 1e9))

	if forest.builds != builds_before:
		bad.append("walking rebuilt %d trees (the pool must only move)" % (forest.builds - builds_before))
	if forest.recycles < 8:
		bad.append("only %d recycles over %.0f m" % [forest.recycles, forest.walked])
	if forest.tree_count() != Forest.WALK_PER_ROW * 2:
		bad.append("pool changed size to %d" % forest.tree_count())
	if seen_far > Forest.WALK_SPROUT + 0.5:
		bad.append("a tree was drawn %.1f m ahead (sprouts at %.0f)" % [seen_far, Forest.WALK_SPROUT])
	if seen_behind < -Forest.WALK_RECYCLE - 0.5:
		bad.append("a tree was drawn %.1f m behind" % -seen_behind)
	if passed_young > 0:
		bad.append("%d frames had a still-growing tree beside the viewer" % passed_young)
	if eye_moved > 1e-4:
		bad.append("the viewer moved %.3f m (the avenue must come to you)" % eye_moved)
	if absf(moved - walked_then) > 0.01:
		bad.append("root moved %.2f m but walked says %.2f" % [moved, walked_then])
	if not vig_on:
		bad.append("vignette not at full while gliding (motion %.2f)" % main.vignette.motion)
	if not vig_off:
		bad.append("vignette still up after stopping")
	if stop_s > Forest.WALK_EASE_S + 0.25:
		bad.append("took %.2f s to stop" % stop_s)
	print("AVENUESHOT walk walked=%.1fm recycles=%d builds_during=%d seen_far=%.1f seen_behind=%.1f stop=%.2fs vignette_on=%s off=%s script_ms still avg=%.2f max=%.2f walking avg=%.2f max=%.2f" % [
		forest.walked, forest.recycles, forest.builds - builds_before, seen_far, -seen_behind,
		stop_s, str(vig_on), str(vig_off), still["sum"] / 1000.0 / maxf(1.0, still["n"]),
		still["max"] / 1000.0, walking["sum"] / 1000.0 / maxf(1.0, walking["n"]),
		walking["max"] / 1000.0])

	# WALK off keeps the avenue and lets the far end grow in; SOW brings the grove back.
	main._toggle_walk()
	await process_frame
	var waiting := 0
	for t in forest.trees():
		if t.grow_rate == 0.0:
			waiting += 1
	if forest.layout != Forest.Layout.AVENUE or waiting != 0:
		bad.append("WALK off: layout %d, %d trees still waiting" % [forest.layout, waiting])
	main._sow_grove()
	await process_frame
	if forest.layout != Forest.Layout.GROVE or not main.tree.visible:
		bad.append("SOW did not bring back the grove and the hero")

	var ok := bad.is_empty()
	for b in bad:
		print("AVENUESHOT problem: ", b)
	print("AVENUESHOT %s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)


## Avenue trees by row (left, right), each sorted nearest first, in the root's frame.
func _rows(forest: Forest) -> Array:
	var out := [[], []]
	for t in forest.trees():
		if t.get_parent() != forest.get_node("Avenue"):
			continue
		out[0 if t.position.x < 0.0 else 1].append(t.position)
	for r in out:
		r.sort_custom(func(a, b): return a.z > b.z)
	return out


func _check_rows(rows: Array, max_len: float) -> Array[String]:
	var bad: Array[String] = []
	for r in 2:
		var row: Array = rows[r]
		if row.size() < 10:
			bad.append("row %d has only %d trees" % [r, row.size()])
		for i in row.size():
			var p: Vector3 = row[i]
			if absf(p.x) < Forest.AVENUE_HALF_W - Forest.AVENUE_HALF_W_JITTER - 1e-3 \
					or absf(p.x) > Forest.AVENUE_HALF_W + Forest.AVENUE_HALF_W_JITTER + 1e-3:
				bad.append("row %d tree %d at %.2f m off the path" % [r, i, absf(p.x)])
			if i > 0:
				var gap: float = (row[i - 1] as Vector3).z - p.z
				if gap < Forest.AVENUE_STEP.x - 1e-3 or gap > Forest.AVENUE_STEP.y + 1e-3:
					bad.append("row %d gap %d is %.2f m" % [r, i, gap])
		if not row.is_empty() and -float((row[-1] as Vector3).z) > max_len:
			bad.append("row %d runs to %.1f m" % [r, -float((row[-1] as Vector3).z)])
	return bad


func _sprouted_frac(forest: Forest) -> float:
	var n := 0
	for t in forest.trees():
		if t.grow_t > 0.0:
			n += 1
	return float(n) / maxf(1.0, forest.tree_count())


## main's own script timer (_proc_us_*), which its [perf] line resets every log window.
## Sampled every frame, between two samples exactly one main._process has run, so a reset
## is seen as the frame count going backwards and nothing is lost.
func _meter(main) -> Dictionary:
	return {"sum": 0, "n": 0, "max": 0, "ls": main._proc_us_sum, "lf": main._proc_frames}


func _sample(main, m: Dictionary) -> void:
	var s: int = main._proc_us_sum
	var f: int = main._proc_frames
	var reset: bool = f < int(m["lf"])
	m["sum"] += s if reset else s - int(m["ls"])
	m["n"] += f if reset else f - int(m["lf"])
	m["max"] = maxi(int(m["max"]), main._proc_us_max)
	m["ls"] = s
	m["lf"] = f


func _grown_frac(forest: Forest) -> float:
	var n := 0
	for t in forest.trees():
		if t.built and t.grow_t > t.grow_s + 1.0:
			n += 1
	return float(n) / maxf(1.0, forest.tree_count())


func _key(code: Key, down: bool) -> void:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.physical_keycode = code
	ev.pressed = down
	Input.parse_input_event(ev)


func _save(name: String) -> void:
	var img := root.get_viewport().get_texture().get_image()
	img.save_png("res://.spike-out/%s.png" % name)
