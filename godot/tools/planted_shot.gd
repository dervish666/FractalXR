extends SceneTree

## Undergrowth on the trees you plant (forest.gd plant_at, _lod_items; fractal_tree.gd _ug_grow),
## through the real main scene.
##
## Checks, each made to fail when what it guards breaks:
##   1. GROVE: six trees planted round the sown grove, one 0.5 m from an inner grove bed. Every one
##      gets a bed; the inner tree beside it gives way; the sown beds keep the 4-bed cap, the 1.05 m
##      floor and the 0.72 m spacing against every bed; the hero keeps its bed; and every LOD pass
##      while they grow in reports the beds, stems and visible cost the trees draw.
##   2. Growth: a sapling planted in view, sampled every frame from the sprout. Its bed is granted
##      within a second of the sprout, stays under the tree's own progress through the first half,
##      never steps more than 4% of its full size in a frame, never shrinks, and is whole by
##      grow_s + 1. Eight frozen frames, bed on against bed off, measure what it adds on screen.
##   3. PLANT_MAX planted at once: all get beds at the start budget, inside the budget; with room
##      for about half their LOD 1 beds over the trees' coarsest cost, planted trees take the floor
##      and no sown tree gets one; at BUDGET_MIN no bed and no tree detail lost; no planted bed
##      flips under head sway.
##   4. AVENUE: planted at 3, 8.6 and 12 m get beds (tiered by distance), one at 20 m does not (far
##      cut); the avenue's own beds keep their cap; the pass totals hold.
##   5. WALK: sowing the walk takes every planted tree and leaves no bed drawn; standing still and
##      planting again grows a bed.
##
##   tools/planted_shot.sh          PS_ONLY=grove stops after checks 1 and 2.

const SPEED := 4.0

var _bad: Array[String] = []


func _init() -> void:
	var scene: PackedScene = load("res://main.tscn")
	var main := scene.instantiate()
	root.add_child(main)
	for i in 40:
		await process_frame
	main.help.close()
	main.spin = false
	main.forest.grove_seed = 4321
	main.xr_camera.position = Vector3(0.0, 1.6, 0.0)
	main.xr_camera.rotation_degrees = Vector3(-12.0, 0.0, 0.0)
	for i in 3:
		await process_frame
	main._set_mode("tree")
	for i in 3:
		await process_frame
	var forest: Forest = main.forest
	# Light on the shared GPU: a headset's frame rate, not an uncapped one.
	Engine.max_fps = 72
	forest.set_succession(false)
	main._set_tree_undergrowth(true)

	# --- 1. GROVE ------------------------------------------------------------------------------
	await _grow_all(main, forest, true)
	var eye: Vector3 = main.xr_camera.global_position
	forest.apply_lod(eye)
	await _settle_ug(forest, eye)
	var hero_w: Vector3 = main.tree.global_position
	var holders: Array[FractalTree] = []
	for t in forest.trees():
		if t.undergrowth_lod >= 0:
			holders.append(t)
	if holders.is_empty():
		_bad.append("setup: no grove bed before planting")
		_finish()
		return
	# The holder nearest you, and a spot 0.5 m further out from the hero than it.
	holders.sort_custom(func(a: FractalTree, b: FractalTree) -> bool:
		return a.global_position.distance_to(eye) < b.global_position.distance_to(eye))
	var beside: FractalTree = holders[0]
	var bw := beside.global_position
	var out := Vector2(bw.x - hero_w.x, bw.z - hero_w.z).normalized()
	var spots: Array[Vector2] = [Vector2(bw.x, bw.z) + out * 0.5]
	for off: Vector2 in [Vector2(-1.3, 1.4), Vector2(1.3, 1.3), Vector2(-2.4, -0.4),
			Vector2(2.3, -0.2), Vector2(0.4, -2.2)]:
		spots.append(Vector2(hero_w.x, hero_w.z) + off)
	var planted: Array[FractalTree] = []
	for s in spots:
		if not main._plant_tree_at(s):
			_bad.append("could not plant at %s" % str(s))
		else:
			planted.append(forest.trees().back())
	var near_p: FractalTree = planted[0] if not planted.is_empty() else null
	var id_grow := await _grow_counted(main, forest, true)
	forest.apply_lod(eye)
	await _settle_ug(forest, eye)
	var p_beds := 0
	var p_full := 0
	var p_note := ""
	for t in planted:
		if t.undergrowth_lod >= 0 and _drawn(t):
			p_beds += 1
		else:
			# Why: its height, its distance from the hero (the grove's rank), the nearest bed.
			var tl := forest.to_local(t.global_position)
			var gap := INF
			for o in forest.trees():
				if o != t and o.undergrowth_lod >= 0:
					var ol := forest.to_local(o.global_position)
					gap = minf(gap, Vector2(tl.x, tl.z).distance_to(Vector2(ol.x, ol.z)))
			p_note += " [%s h=%.2f r_hero=%.2f nearest_bed=%.2f lod=%d]" % [t.shape, t.height_m,
				Vector2(tl.x, tl.z).length(), gap, t.undergrowth_lod]
		if _drawn(t) and absf(_size(t) - 1.0) < 1e-3:
			p_full += 1
	var sown_beds := 0
	var sown_min_h := INF
	var sown_gap := INF
	var bed_spots: Array[Vector2] = []
	var sown_spots: Array[Vector2] = []
	for t in forest.trees():
		if t.undergrowth_lod < 0:
			continue
		var lp := forest.to_local(t.global_position)
		bed_spots.append(Vector2(lp.x, lp.z))
		if not t.hand_planted:
			sown_beds += 1
			sown_min_h = minf(sown_min_h, t.height_m)
			sown_spots.append(Vector2(lp.x, lp.z))
	for a in sown_spots:
		for b in bed_spots:
			if a != b:
				sown_gap = minf(sown_gap, a.distance_to(b))
	var near_gap := INF
	if near_p != null:
		near_gap = Vector2(near_p.global_position.x, near_p.global_position.z).distance_to(
			Vector2(bw.x, bw.z))
	var hero_bed: bool = main.tree.undergrowth_nodes()[0].is_visible_in_tree()
	var idn := _pass_identity(forest)
	print("PLANTSHOT grove: planted=%d beds=%d full=%d%s | beside %.2fm: planted_lod=%d inner_lod=%d (gave way=%s) | sown beds=%d (max %d) min_h=%.2f gap=%.2fm hero_bed=%s | counted %d/%d passes while growing, now %s | visible=%d budget=%d" % [
		planted.size(), p_beds, p_full, ("" if p_note == "" else " bare:" + p_note), near_gap,
		near_p.undergrowth_lod if near_p != null else -9, beside.undergrowth_lod,
		str(beside.undergrowth_lod < 0), sown_beds, Forest.UNDERGROWTH_GROVE_MAX,
		sown_min_h if sown_min_h < INF else 0.0, sown_gap if sown_gap < INF else 9.99,
		str(hero_bed), id_grow[0], id_grow[1], idn[1], forest.visible_cost, forest.budget])
	if planted.size() != spots.size() or p_beds != planted.size():
		_bad.append("grove: %d/%d planted trees have a bed" % [p_beds, planted.size()])
	if near_gap >= Forest.UNDERGROWTH_GROVE_SPACING or near_p == null or near_p.undergrowth_lod < 0 \
			or beside.undergrowth_lod >= 0:
		_bad.append("grove: planted %.2fm from an inner bed did not keep it (planted %d, inner %d)" % [
			near_gap, near_p.undergrowth_lod if near_p != null else -9, beside.undergrowth_lod])
	if sown_beds > Forest.UNDERGROWTH_GROVE_MAX or sown_min_h < Forest.UNDERGROWTH_GROVE_MIN_H - 1e-3 \
			or sown_gap < Forest.UNDERGROWTH_GROVE_SPACING - 1e-3 or not hero_bed:
		_bad.append("grove: sown beds broke cap/height/spacing or the hero lost its bed (beds=%d h=%.2f gap=%.2f hero=%s)" % [
			sown_beds, sown_min_h, sown_gap, str(hero_bed)])
	if p_full != planted.size():
		_bad.append("grove: %d/%d planted beds reached full size" % [p_full, planted.size()])
	if int(id_grow[0]) != int(id_grow[1]) or int(id_grow[1]) < 4 or not bool(idn[0]) \
			or forest.visible_cost > forest.budget:
		_bad.append("grove: pass totals off with planted beds (%d/%d passes, first miss %s; now %s)" % [
			id_grow[0], id_grow[1], id_grow[2], idn[1]])
	await _hold(main, Vector3(0.0, 1.6, 0.0), Vector3(-14.0, 0.0, 0.0))
	_capture().save_png("res://.spike-out/planted_grove.png")
	var side_eye := hero_w + Vector3(-3.6, 1.35, 2.9)
	await _hold(main, side_eye, _look(side_eye, hero_w + Vector3(0.0, 0.5, 0.4)))
	_capture().save_png("res://.spike-out/planted_grove_side.png")

	# --- 2. Growth from the sprout -------------------------------------------------------------
	await _check_growth(main, forest, hero_w)
	if OS.get_environment("PS_ONLY") == "grove":
		_finish()
		return

	# --- 3. PLANT_MAX at once, budget order -----------------------------------------------------
	await _check_full_set(main, forest, hero_w)

	# --- 4. AVENUE ------------------------------------------------------------------------------
	await _check_avenue(main, forest)

	# --- 5. WALK --------------------------------------------------------------------------------
	await _check_walk(main, forest)
	_finish()


func _finish() -> void:
	for b in _bad:
		print("PLANTSHOT problem: ", b)
	var ok := _bad.is_empty()
	print("PLANTSHOT %s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)


## A sapling planted 1.3 m in front of a low camera, wind and motes off. Every frame: the bed's
## drawn size, its node scale over the full bed's times the eased presence it was fed, against
## the tree's progress. At eight progress marks time stops and the bed is drawn, then hidden.
func _check_growth(main, forest: Forest, hero_w: Vector3) -> void:
	main._set_forest_wind(0.0)
	forest.set_motes_on(false)
	# Clear ground left of the grove, shot from outside it so the grown grove is the backdrop and
	# the whole sapling, up to about 4 m, stays in frame.
	var spot := Vector2(hero_w.x - 3.7, hero_w.z + 0.9)
	var cam := Vector3(spot.x - 2.3, 1.45, spot.y + 2.6)
	await _hold(main, cam, _look(cam, Vector3(spot.x, 1.0, spot.y)))
	if not main._plant_tree_at(spot):
		_bad.append("growth: could not plant")
		return
	var t: FractalTree = forest.trees().back()
	var marks := [0.1, 0.25, 0.4, 0.55, 0.7, 0.85, 1.0, 1.4]
	var mark_i := 0
	var shots: Array[Image] = []
	var px: Array[float] = []
	var sizes: Array[float] = []
	var progs: Array[float] = []
	var prev := 0.0
	var max_up := 0.0
	var max_down := 0.0
	var lead_over := -1.0
	var granted_at := -1.0
	var early := 0.0
	var full_at := -1.0
	var h_mismatch := 0.0
	var frames := 0
	while frames < 2400:
		await process_frame
		frames += 1
		if not t.built:
			continue
		var gs := t.grow_s
		var prog := clampf(t.grow_t / gs, 0.0, 2.0)
		var s := _size(t) if _drawn(t) else 0.0
		if granted_at < 0.0 and t.undergrowth_lod >= 0:
			granted_at = t.grow_t
		if _drawn(t):
			# The shaders' `undergrowth` height must scale with the node, or the colour ramp slides.
			var ns := t.undergrowth_nodes()
			var fed_h := float(ns[0].get_instance_shader_parameter(&"undergrowth"))
			var want_h := TreeUndergrowth.REF_HEIGHT * ns[0].transform.basis.get_scale().x
			h_mismatch = maxf(h_mismatch, absf(fed_h - want_h))
		max_up = maxf(max_up, s - prev)
		if granted_at >= 0.0:
			max_down = maxf(max_down, prev - s)
		if prog <= 0.5:
			lead_over = maxf(lead_over, s - prog)
		if absf(prog - 0.25) < 0.03:
			early = maxf(early, s)
		if full_at < 0.0 and s >= 0.999:
			full_at = t.grow_t
		prev = s
		if mark_i < marks.size() and prog >= float(marks[mark_i]):
			Engine.time_scale = 0.0
			for i in 3:
				await process_frame
			var on := _capture()
			var ns := t.undergrowth_nodes()
			var vis: Array[bool] = []
			for n in ns:
				vis.append(n.visible)
				n.visible = false
			for i in 3:
				await process_frame
			var off := _capture()
			for k in ns.size():
				ns[k].visible = vis[k]
			await process_frame
			Engine.time_scale = 1.0
			shots.append(on)
			px.append(_diff_center(on, off))
			sizes.append(s)
			progs.append(prog)
			on.save_png("res://.spike-out/planted_grow_%d.png" % mark_i)
			mark_i += 1
		if mark_i >= marks.size():
			break
	_sheet(shots, "res://.spike-out/planted_grow_sheet.png")
	var px_full: float = px.back() if not px.is_empty() else 0.0
	var px_line := ""
	var px_dip := 0.0
	# Through 55% of the tree's growth the bed may not show more of itself than the tree has grown.
	var px_lead := -1.0
	for k in px.size():
		var share := px[k] / maxf(px_full, 1e-6)
		px_line += " %.2f:%.2f/%.0f%%" % [progs[k], sizes[k], 100.0 * share]
		if k > 0:
			px_dip = maxf(px_dip, px[k - 1] - px[k])
		if progs[k] <= 0.56:
			px_lead = maxf(px_lead, share - progs[k])
	var first_px: float = px[0] / maxf(px_full, 1e-6) if not px.is_empty() else 1.0
	print("PLANTSHOT growth: %s grow_s=%.1f granted_at=%.2fs early(25%%)=%.3f lead_over=%.3f max_step=%.4f max_shrink=%.4f full_at=%.2fs h_err=%.5f | progress:size/pixels%s (full %.5f, pixel lead %.2f)" % [
		t.shape, t.grow_s, granted_at, early, lead_over, max_up, max_down, full_at, h_mismatch,
		px_line, px_full, px_lead])
	if granted_at < 0.0 or granted_at > 1.0:
		_bad.append("growth: bed granted at %.2fs, not from the sprout" % granted_at)
	if early > 0.2 or lead_over > 0.0:
		_bad.append("growth: bed ahead of its tree (%.3f at 25%%, %.3f over in the first half)" % [
			early, lead_over])
	if max_up > 0.04 or max_down > 0.002:
		_bad.append("growth: bed size jumped (step %.4f, shrink %.4f)" % [max_up, max_down])
	if full_at < 0.0 or full_at > t.grow_s + 1.0:
		_bad.append("growth: bed whole at %.2fs, after grow_s + 1" % full_at)
	if h_mismatch > 1e-4:
		_bad.append("growth: shader height off the node scale by %.5f" % h_mismatch)
	if px.size() != marks.size() or px_full < 0.004 or first_px > 0.1 or px_dip > 0.1 * px_full \
			or px_lead > 0.0:
		_bad.append("growth: on-screen bed did not rise from near zero behind its tree (first %.0f%%, ahead by %.2f, dip %.5f, full %.5f)" % [
			100.0 * first_px, px_lead, px_dip, px_full])
	main._set_forest_wind(FractalMain.TREE_WIND[main.tree_wind_idx])
	forest.set_motes_on(true)
	await _grow_all(main, forest, true)


## PLANT_MAX planted trees: all bedded at the start budget; the order under a shrunken floor; none
## at BUDGET_MIN and no tree detail lost; no flips under head sway.
func _check_full_set(main, forest: Forest, hero_w: Vector3) -> void:
	for off: Vector2 in [Vector2(-1.9, 0.6), Vector2(1.9, 0.5), Vector2(-1.0, -2.0),
			Vector2(1.1, -2.1), Vector2(-2.6, 1.6), Vector2(2.7, 1.5)]:
		if not forest.can_plant():
			break
		main._plant_tree_at(Vector2(hero_w.x, hero_w.z) + off)
	var eye := Vector3(0.0, 1.6, 0.0)
	await _hold(main, eye, Vector3(-14.0, 0.0, 0.0))
	await _grow_all(main, forest, true)
	forest.apply_lod(eye)
	await _settle_ug(forest, eye)
	var n_p := forest.planted_count()
	var all := _planted_beds(forest)
	var l0 := 0
	for t in forest.trees():
		if t.hand_planted and t.undergrowth_lod == 0:
			l0 += 1
	var idn := _pass_identity(forest)
	var ug_cost := 0
	for t in forest.trees():
		ug_cost += t.undergrowth_cost(t.undergrowth_drawn_lod)
	var start_vis := forest.visible_cost
	var start_bud := forest.budget
	await _hold(main, eye, Vector3(-14.0, 0.0, 0.0))
	_capture().save_png("res://.spike-out/planted_full_set.png")

	# Head sway must not move a planted bed between tiers or on and off. At the governor's ceiling,
	# where some planted beds hold LOD 0 and the rest LOD 1, so a reshuffle has somewhere to go.
	var top := int(forest.step()["budget_max"])
	forest.budget = top
	forest.apply_lod(eye)
	await _settle_ug(forest, eye, top)
	var top_l0 := 0
	for t in forest.trees():
		if t.hand_planted and t.undergrowth_lod == 0:
			top_l0 += 1
	var base := _lod_map(forest)
	var flips := 0
	for off: Vector3 in [Vector3(0.45, 0.0, 0.0), Vector3(-0.45, 0.0, 0.0), Vector3(0.0, 0.0, 0.45),
			Vector3(0.0, 0.0, -0.45), Vector3(0.3, 0.0, -0.3), Vector3(-0.3, 0.0, 0.3), Vector3.ZERO]:
		forest.budget = top
		forest.apply_lod(eye + off)
		var m := _lod_map(forest)
		for t in base:
			if int(m.get(t, -9)) != int(base[t]):
				flips += 1

	# Room on the floor for about half the planted beds once every tree's coarsest form is paid
	# for (28 trees cost more than the 6000-7800 floor ramp on their own): planted first.
	var bud_save := start_bud
	var coarsest: int = forest._far.drawn
	var half_c1 := 0
	for t in forest.trees():
		if t.built and not t.far and t.grow_t > 0.0:
			coarsest += t.lod_cost(FractalTree.LOD_MAX)
		if t.hand_planted:
			half_c1 += t.undergrowth_cost(1)
	half_c1 /= 2
	var mid := maxi(coarsest + half_c1, Forest.UNDERGROWTH_FLOOR_FULL)
	forest.budget = mid
	forest.apply_lod(eye)
	await _settle_ug(forest, eye, mid)
	var mid_p := _planted_beds(forest)
	var mid_s := 0
	for t in forest.trees():
		if not t.hand_planted and t.undergrowth_lod >= 0:
			mid_s += 1
	var mid_vis := forest.visible_cost
	# BUDGET_MIN: no bed at all, and the trees draw what they draw with undergrowth off.
	forest.budget = Forest.BUDGET_MIN
	main._set_tree_undergrowth(false)
	forest.apply_lod(eye)
	var lods_off := _tree_lods(forest)
	main._set_tree_undergrowth(true)
	forest.apply_lod(eye)
	await _settle_ug(forest, eye, Forest.BUDGET_MIN)
	var lods_on := _tree_lods(forest)
	var min_beds := forest.undergrowth_drawn
	var degraded := 0
	for t in lods_off:
		if int(lods_on.get(t, 99)) > int(lods_off[t]):
			degraded += 1
	forest.budget = bud_save
	forest.apply_lod(eye)
	await _settle_ug(forest, eye)
	print("PLANTSHOT full_set: planted=%d/%d beds=%d (lod0=%d) undergrowth=%d visible=%d budget=%d %s | sway at %d (planted lod0=%d): flips=%d | pressure(%d = coarsest %d + half the planted LOD 1): planted=%d sown=%d visible=%d | min(%d): beds=%d degraded=%d" % [
		n_p, Forest.PLANT_MAX, all, l0, ug_cost, start_vis, start_bud, idn[1], top, top_l0, flips,
		mid, coarsest,
		mid_p, mid_s, mid_vis, Forest.BUDGET_MIN, min_beds, degraded])
	if n_p != Forest.PLANT_MAX or all != n_p or not bool(idn[0]) or start_vis > start_bud:
		_bad.append("full set: %d/%d planted beds, %s" % [all, n_p, idn[1]])
	if flips != 0 or top_l0 < 1 or top_l0 >= n_p:
		_bad.append("full set: %d planted bed flips under head sway (lod0 %d/%d at %d)" % [
			flips, top_l0, n_p, top])
	if mid_p < 3 or mid_p >= n_p or mid_s > 0 or mid_vis > mid:
		_bad.append("full set: under pressure sown trees got beds before planted ones, or nothing thinned (planted %d/%d, sown %d, visible %d/%d)" % [
			mid_p, n_p, mid_s, mid_vis, mid])
	if min_beds != 0 or degraded != 0:
		_bad.append("full set: BUDGET_MIN beds=%d degraded=%d" % [min_beds, degraded])


## AVENUE: planted at 3, 8.6, 12 and 20 m down and beside the path.
func _check_avenue(main, forest: Forest) -> void:
	var eye := Vector3(0.0, 1.6, 0.0)
	await _hold(main, eye, Vector3(-11.0, 0.0, 0.0))
	main._sow_avenue(false)
	await _grow_all(main, forest, false)
	var want: Array[Vector2] = [Vector2(0.4, -3.0), Vector2(-1.0, -8.5), Vector2(1.2, -12.0),
		Vector2(0.0, -20.0)]
	var trees: Array[FractalTree] = []
	for s in want:
		if main._plant_tree_at(s):
			trees.append(forest.trees().back())
	var id_grow := await _grow_counted(main, forest, false)
	forest.apply_lod(eye)
	await _settle_ug(forest, eye)
	var line := ""
	var ok := trees.size() == want.size()
	for k in trees.size():
		var t := trees[k]
		var d := eye.distance_to(t.global_position)
		line += " %.1fm:lod%d" % [d, t.undergrowth_lod]
		var inside := d < Forest.UNDERGROWTH_FAR_IN
		if inside != (t.undergrowth_lod >= 0 and _drawn(t)):
			ok = false
		if inside and d > Forest.UNDERGROWTH_LOD0_OUT and t.undergrowth_lod != 1:
			ok = false
	var av_beds := 0
	for t in forest.trees():
		if t.row >= 0 and t.undergrowth_lod >= 0:
			av_beds += 1
	var idn := _pass_identity(forest)
	await _hold(main, eye, Vector3(-11.0, 0.0, 0.0))
	_capture().save_png("res://.spike-out/planted_avenue.png")
	print("PLANTSHOT avenue: planted%s avenue_beds=%d (max %d) counted %d/%d passes while growing, now %s visible=%d budget=%d" % [
		line, av_beds, Forest.UNDERGROWTH_NEAR, id_grow[0], id_grow[1], idn[1], forest.visible_cost,
		forest.budget])
	if not ok:
		_bad.append("avenue: planted beds wrong:%s" % line)
	if av_beds > Forest.UNDERGROWTH_NEAR or not bool(idn[0]) or int(id_grow[0]) != int(id_grow[1]) \
			or forest.visible_cost > forest.budget:
		_bad.append("avenue: cap or totals off (avenue beds %d, %d/%d passes, %s)" % [
			av_beds, id_grow[0], id_grow[1], idn[1]])


## WALK sows over the planted trees; standing still, planting grows a bed again.
func _check_walk(main, forest: Forest) -> void:
	var old: Array[FractalTree] = []
	for t in forest.trees():
		if t.hand_planted:
			old.append(t)
	main._toggle_walk()
	for i in 3:
		await process_frame
	forest.apply_lod(main.xr_camera.global_position)
	var kept := forest.planted_count()
	var leak := 0
	for t in old:
		if not is_instance_valid(t):
			continue
		for n in t.undergrowth_nodes():
			if n.is_visible_in_tree():
				leak += 1
	var idn := _pass_identity(forest)
	main._toggle_walk()
	await process_frame
	var standing := not forest.walking()
	var again := main._plant_tree_at(Vector2(0.3, -2.6)) as bool
	var t_new: FractalTree = forest.trees().back() if again else null
	await _grow_all(main, forest, false, true)
	forest.apply_lod(main.xr_camera.global_position)
	await _settle_ug(forest, main.xr_camera.global_position)
	var bed := t_new != null and t_new.hand_planted and t_new.undergrowth_lod >= 0 and _drawn(t_new)
	print("PLANTSHOT walk: had=%d planted_after_sow=%d bed_leak=%d %s | stood=%s replanted=%s bed=%s" % [
		old.size(), kept, leak, idn[1], str(standing), str(again), str(bed)])
	if old.is_empty() or kept != 0 or leak != 0 or not bool(idn[0]):
		_bad.append("walk: planted trees or beds survived the walk's sowing (kept %d, leak %d)" % [kept, leak])
	if not standing or not again or not bed:
		_bad.append("walk: standing still, a new planted tree got no bed")


func _drawn(t: FractalTree) -> bool:
	var ns := t.undergrowth_nodes()
	return not ns.is_empty() and ns[0].is_visible_in_tree() and t.undergrowth_drawn_lod >= 0


## The bed's drawn size against the full bed: node scale over the full scale, times the eased
## presence it was fed (smoothstepped, as the shaders read it).
func _size(t: FractalTree) -> float:
	var ns := t.undergrowth_nodes()
	if ns.is_empty():
		return 0.0
	var sc := ns[0].transform.basis.get_scale().x / maxf(t._ug_scale(), 1e-4)
	var p := clampf(float(ns[0].get_instance_shader_parameter(&"undergrowth_presence")), 0.0, 1.0)
	return sc * p * p * (3.0 - 2.0 * p)


func _planted_beds(forest: Forest) -> int:
	var n := 0
	for t in forest.trees():
		if t.hand_planted and t.undergrowth_lod >= 0 and _drawn(t):
			n += 1
	return n


func _lod_map(forest: Forest) -> Dictionary:
	var out := {}
	for t in forest.trees():
		if t.hand_planted:
			out[t] = t.undergrowth_lod
	return out


func _tree_lods(forest: Forest) -> Dictionary:
	var out := {}
	for t in forest.trees():
		if t.built and not t.far and t.grow_t > 0.0:
			out[t] = t.lod
	return out


## What the LOD pass reports against what the trees draw (undergrowth_shot.gd's identity).
func _pass_identity(forest: Forest) -> Array:
	var beds := 0
	var stems := 0
	var cost: int = forest._far.drawn
	for t in forest.trees():
		if t.built and not t.far and t.grow_t > 0.0:
			cost += t.lod_cost(t.lod)
		if t.undergrowth_drawn_lod >= 0:
			beds += 1
			stems += int(TreeUndergrowth.entry(t.seed_value, t.undergrowth_drawn_lod)["n_s"])
			cost += t.undergrowth_cost(t.undergrowth_drawn_lod)
	var ok := beds == forest.undergrowth_drawn and stems == forest.drawn_undergrowth_stems \
		and cost == forest.visible_cost
	return [ok, "beds %d/%d stems %d/%d cost %d/%d" % [forest.undergrowth_drawn, beds,
		forest.drawn_undergrowth_stems, stems, forest.visible_cost, cost]]


## Grow until every tree is whole, running a pass every sixth frame from the eye and checking the
## totals straight after it (a frame's tree ticks run after its own pass, so only a pass's own
## moment can be held to it).
func _grow_counted(main, forest: Forest, include_hero: bool) -> Array:
	Engine.time_scale = SPEED
	var passes := 0
	var ok := 0
	var miss := ""
	var frames := 0
	while frames < 9000:
		await process_frame
		frames += 1
		if frames % 6 == 0:
			forest.apply_lod(main.xr_camera.global_position)
			passes += 1
			var idn := _pass_identity(forest)
			if bool(idn[0]):
				ok += 1
			elif miss == "":
				miss = str(idn[1])
		var done: bool = (not include_hero) or main.tree.grow_t > main.tree.grow_s + 2.0
		for t in forest.trees():
			if t.grow_rate == 0.0:
				continue
			if not (t.built and t.grow_t > t.grow_s + 2.0):
				done = false
				break
		if done and frames > 30:
			break
	Engine.time_scale = 1.0
	return [ok, passes, miss]


func _grow_all(main, forest: Forest, include_hero: bool, sprouting_only := false) -> void:
	Engine.time_scale = SPEED
	var frames := 0
	while frames < 9000:
		frames += 1
		await process_frame
		var done: bool = (not include_hero) or main.tree.grow_t > main.tree.grow_s + 2.0
		for t in forest.trees():
			if sprouting_only and t.grow_rate == 0.0:
				continue
			if not (t.built and t.grow_t > t.grow_s + 2.0):
				done = false
				break
		if done and frames > 30:
			break
	Engine.time_scale = 1.0


func _settle_ug(forest: Forest, eye: Vector3, pin_budget: int = -1) -> void:
	Engine.time_scale = 4.0
	for i in 600:
		if pin_budget > 0:
			forest.budget = pin_budget
			forest._govern_t = 0.0
		await process_frame
		var done := true
		for t in forest.trees():
			if t.undergrowth_lod >= 0 and t.undergrowth_presence < 0.999:
				done = false
				break
			if t.undergrowth_lod >= 0 and (t.undergrowth_drawn_lod != t.undergrowth_lod
					or (t.undergrowth_lod == 0 and t.undergrowth_lod0 < 0.999)):
				done = false
				break
			if t.undergrowth_lod < 0 and (t.undergrowth_drawn_lod >= 0 or t.undergrowth_presence > 0.001):
				done = false
				break
		if done:
			break
	Engine.time_scale = 1.0
	if pin_budget > 0:
		forest.budget = pin_budget
		forest._govern_t = 0.0
	forest.apply_lod(eye)
	for i in 2:
		if pin_budget > 0:
			forest.budget = pin_budget
			forest._govern_t = 0.0
		await process_frame


func _hold(main, eye: Vector3, rot: Vector3) -> void:
	main.xr_camera.position = eye
	main.xr_camera.rotation_degrees = rot
	for i in 16:
		await process_frame


func _capture() -> Image:
	return root.get_viewport().get_texture().get_image()


func _diff_center(a: Image, b: Image) -> float:
	var n := 0
	var sum := 0.0
	var w := a.get_width()
	var h := a.get_height()
	for y in range(int(h * 0.2), int(h * 0.9), 2):
		for x in range(int(w * 0.15), int(w * 0.85), 2):
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			sum += (absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)) / 3.0
			n += 1
	return sum / float(maxi(n, 1))


## Four across, a quarter size each.
func _sheet(shots: Array[Image], path: String) -> void:
	if shots.is_empty():
		return
	var w := shots[0].get_width() / 2
	var h := shots[0].get_height() / 2
	var cols := 4
	var rows := (shots.size() + cols - 1) / cols
	var out := Image.create(w * cols, h * rows, false, Image.FORMAT_RGBA8)
	for k in shots.size():
		var im := shots[k].duplicate() as Image
		im.convert(Image.FORMAT_RGBA8)
		im.resize(w, h)
		out.blit_rect(im, Rect2i(0, 0, w, h), Vector2i((k % cols) * w, (k / cols) * h))
	out.save_png(path)


func _look(from: Vector3, to: Vector3) -> Vector3:
	return Basis.looking_at(to - from, Vector3.UP).get_euler() * (180.0 / PI)
