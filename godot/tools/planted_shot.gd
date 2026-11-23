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
##      and no sown tree gets one; no planted bed flips under head sway.
##   4. AVENUE: planted at 3, 8.6 and 12 m get beds (tiered by distance), one at 20 m does not (far
##      cut); the pass totals hold.
##   5. WALK: sowing the walk takes every planted tree and leaves no bed drawn; standing still and
##      planting again grows a bed.
##   6. A cleared grove. Two planted beds 1 m apart straddling the last LOD 0 upgrade (headroom
##      pinned between one upgrade plus the hysteresis and both) keep their tiers under a 15 cm lean.
##      Seen from off to one side at a floor rounded to no beds, with one LOD 1 bed of headroom,
##      the nearer keeps it while the farther drops out of LOD 0. At BUDGET_MIN, with 12 planted
##      trees short of detail, beds take none of it. 12 planted on a 13 m ring round you at 7800:
##      fresh at 14.0 m and under head sway the floor spends nothing and no tree draws coarser;
##      inside 13.5 m every bed stands on the floor, at 13.7 m it stays, at 14.1 m and back at
##      13.7 m it is gone.
##   7. A sown grove and one fresh planted tree, swept over 6000-6360 (the floor rounds to no
##      beds): whenever the headroom covers the planted bed's LOD 1 and the cheapest held sown
##      bed's, the planted bed has one. A second planted tree beside a holder, on the grove at
##      0.5x: once it has crowded the holder out, the first plant pays its margin. Then the grove
##      at 0.25x. The holder beside the tree planted at 1x stays bare, no other sown bed changes,
##      and a tree planted after the shrink 0.5 m from a sown holder takes its place.
##   8. AVENUE at COUNT 60, seen from 10 m above its middle with over 16 sown trees inside the
##      cut, keeps the sown beds to their 16 cap. Then 12 planted at 14.1 m, past where the shaders
##      fold a bed away, leave the floor as it was and hold no bed while a nearer sown bed that
##      shows goes without.
##   Every pass total is counted from what the MultiMesh nodes draw (each visible bed node and its
##   drawn instances, so foliage over hidden stems counts), not from the allocator's own cost table.
##
##   tools/planted_shot.sh          PS_ONLY=grove stops after checks 1 and 2; PS_ONLY=order runs
##                                  only checks 6 to 8.

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

	if OS.get_environment("PS_ONLY") == "order":
		await _grow_all(main, forest, true)
		await _check_order(main, forest)
		_finish()
		return

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

	# --- 6 to 8. Budget order ----------------------------------------------------------------
	await _check_order(main, forest)
	_finish()


func _check_order(main, forest: Forest) -> void:
	# 6. LOD 0 pair under a lean, BUDGET_MIN with detail to lose.
	await _check_lod0_pair(main, forest)
	await _check_min_budget(main, forest)
	await _check_fold_floor(main, forest)
	# 7. Fresh planted against held sown at 6000-6360; the second plant's waiver; the scaled grove.
	await _check_sweep_and_scale(main, forest)
	# 8. Avenue cap with more than 16 sown candidates; folded planted beds.
	await _check_cap_and_fold(main, forest)


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


## PLANT_MAX planted trees: all bedded at the start budget; the order under a shrunken floor; no
## flips under head sway. (BUDGET_MIN is check 6: 28 trees cost 7302 at their coarsest, so 6000
## leaves them no detail to lose.)
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
	forest.budget = bud_save
	forest.apply_lod(eye)
	await _settle_ug(forest, eye)
	print("PLANTSHOT full_set: planted=%d/%d beds=%d (lod0=%d) undergrowth=%d visible=%d budget=%d %s | sway at %d (planted lod0=%d): flips=%d | pressure(%d = coarsest %d + half the planted LOD 1): planted=%d sown=%d visible=%d" % [
		n_p, Forest.PLANT_MAX, all, l0, ug_cost, start_vis, start_bud, idn[1], top, top_l0, flips,
		mid, coarsest, mid_p, mid_s, mid_vis])
	if n_p != Forest.PLANT_MAX or all != n_p or not bool(idn[0]) or start_vis > start_bud:
		_bad.append("full set: %d/%d planted beds, %s" % [all, n_p, idn[1]])
	if flips != 0 or top_l0 < 1 or top_l0 >= n_p:
		_bad.append("full set: %d planted bed flips under head sway (lod0 %d/%d at %d)" % [
			flips, top_l0, n_p, top])
	if mid_p < 3 or mid_p >= n_p or mid_s > 0 or mid_vis > mid:
		_bad.append("full set: under pressure sown trees got beds before planted ones, or nothing thinned (planted %d/%d, sown %d, visible %d/%d)" % [
			mid_p, n_p, mid_s, mid_vis, mid])


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
	print("PLANTSHOT avenue: planted%s avenue_beds=%d counted %d/%d passes while growing, now %s visible=%d budget=%d" % [
		line, av_beds, id_grow[0], id_grow[1], idn[1], forest.visible_cost,
		forest.budget])
	if not ok:
		_bad.append("avenue: planted beds wrong:%s" % line)
	if not bool(idn[0]) or int(id_grow[0]) != int(id_grow[1]) or forest.visible_cost > forest.budget:
		_bad.append("avenue: totals off (%d/%d passes, %s)" % [id_grow[0], id_grow[1], idn[1]])


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


## Two planted beds 1 m apart, 3 m ahead, on a cleared grove. The budget is pinned so step 4 has
## between one LOD 0 upgrade plus the hysteresis and the two upgrades together. The nearer bed takes
## LOD 0, then the eye leans 15 cm to bring the other nearer. Neither may change tier. Six more
## planted 11.5 m behind (LOD 1 beds, ranked after the pair) lift the trees' cost over the floor ramp,
## so both of the pair stand on the LOD 1 floor as they would in a planted grove.
func _check_lod0_pair(main, forest: Forest) -> void:
	forest.clear()
	var lean := 0.15
	var eye := Vector3(-lean, 1.6, 0.0)
	await _hold(main, eye, Vector3(-14.0, 0.0, 0.0))
	for deg: float in [-50.0, -30.0, -10.0, 10.0, 30.0, 50.0]:
		main._plant_tree_at(Vector2(11.5 * sin(deg_to_rad(deg)), 11.5 * cos(deg_to_rad(deg))))
	main._plant_tree_at(Vector2(-0.5, -3.0))
	var a: FractalTree = forest.trees().back()
	main._plant_tree_at(Vector2(0.5, -3.0))
	var b: FractalTree = forest.trees().back()
	await _grow_all(main, forest, false)
	var costs := ""
	for v in TreeUndergrowth.VARIANTS:
		costs += " v%d:%d/%d" % [v, TreeUndergrowth.cost(v, 0, true), TreeUndergrowth.cost(v, 1, true)]
	var da := a.undergrowth_cost(0) - a.undergrowth_cost(1)
	var db := b.undergrowth_cost(0) - b.undergrowth_cost(1)
	var lo := maxi(da, db) + Forest.UNDERGROWTH_BUDGET_HYST
	var hi := da + db
	if lo >= hi:
		_bad.append("lod0 pair: no straddle window (upgrades %d and %d)" % [da, db])
		print("PLANTSHOT lod0_pair: costs%s upgrades %d %d" % [costs, da, db])
		return
	var want_h := (lo + hi) / 2
	# The budget is what the trees draw when fully satisfied, plus every LOD 1 floor bed, plus the
	# headroom wanted, then trimmed by what step 4 actually saw.
	forest.budget = Forest.BUDGET_START
	forest.apply_lod(eye)
	var tree_cost: int = forest._far.drawn
	for t in forest.trees():
		if t.built and not t.far and t.grow_t > 0.0:
			tree_cost += t.lod_cost(t.lod)
	var floor_c := 0
	for t in forest.trees():
		floor_c += t.undergrowth_cost(1)
	var bud := tree_cost + floor_c + want_h
	for i in 3:
		for t in forest.trees():
			t.clear_undergrowth()
		forest.budget = bud
		forest.apply_lod(eye)
		if forest.ug_headroom == want_h:
			break
		bud += want_h - forest.ug_headroom
	await _settle_ug(forest, eye, bud)
	var la0 := a.undergrowth_lod
	var lb0 := b.undergrowth_lod
	var flips := 0
	var h_line := ""
	var h_bad := 0
	for off: float in [lean, -lean, lean, 0.0, lean, -lean]:
		var e := Vector3(off, 1.6, 0.0)
		main.xr_camera.position = e
		forest.budget = bud
		forest.apply_lod(e)
		h_line += " %d" % forest.ug_headroom
		if forest.ug_headroom < lo or forest.ug_headroom >= hi:
			h_bad += 1
		if a.undergrowth_lod != la0:
			flips += 1
		if b.undergrowth_lod != lb0:
			flips += 1
	main.xr_camera.position = eye
	var idn := _pass_identity(forest)
	print("PLANTSHOT lod0_pair: costs%s | upgrades %d %d, window [%d, %d) budget=%d | before lean A=%d B=%d, headroom per lean%s | flips=%d %s" % [
		costs, da, db, lo, hi, bud, la0, lb0, h_line, flips, idn[1]])
	if la0 != 0 or lb0 != 1 or h_bad != 0:
		_bad.append("lod0 pair: fixture did not straddle the last slot (A=%d B=%d, %d leans outside [%d, %d))" % [
			la0, lb0, h_bad, lo, hi])
	if flips != 0:
		_bad.append("lod0 pair: %d tier changes under a %.2f m lean" % [flips, lean])
	_totals_ok("lod0 pair", idn)

	# The handoff at a floor that rounds to no beds (6000-6299 with two planted beds that show).
	# Seen from off to one side, the pair sits under 1 m apart in depth: X, farther, holds LOD 0 past
	# the 9.0 m cut and must drop to LOD 1; Y, nearer, holds LOD 1 past 7.8 m and can only keep it.
	# The headroom pays one LOD 1 bed. Y is nearer, so Y keeps it; the LOD 0 bonus would have put X
	# first, and then Y needs its margin to come back. The ballast stands over 14.2 m off, bedless.
	main._set_tree_undergrowth(false)
	var x := a
	var y := b
	var ho_eye := Vector3.INF
	var ho_t := 0
	var ho_line := ""
	for deg in range(25, 80, 5):
		var dir := Vector2(cos(deg_to_rad(float(deg))), -sin(deg_to_rad(float(deg))))
		for k in 19:
			var s := 7.5 + 0.25 * k
			var g := Vector2(0.0, -3.0) + dir * s
			var e := Vector3(g.x, 1.6, g.y)
			var dx := x.global_position.distance_to(e)
			var dy := y.global_position.distance_to(e)
			if dx < Forest.UNDERGROWTH_LOD0_OUT + 0.03 or dx >= Forest.UNDERGROWTH_FOLD_IN - 0.1 \
					or dy < Forest.UNDERGROWTH_LOD0_IN + 0.03 or dy >= dx - 0.05:
				continue
			var clear := true
			for t in forest.trees():
				if t != x and t != y and t.global_position.distance_to(e) < Forest.UNDERGROWTH_FAR_IN + 0.1:
					clear = false
			if not clear:
				continue
			forest.budget = 60000
			forest.apply_lod(e)
			var tc: int = forest._far.drawn
			for t in forest.trees():
				if t.built and not t.far and t.grow_t > 0.0:
					tc += t.lod_cost(t.lod)
			if k == 0:
				ho_line += " %d:%d" % [deg, tc]
			if tc > Forest.BUDGET_MIN - x.undergrowth_cost(1) - y.undergrowth_cost(1) + 8 and tc <= 6299 - x.undergrowth_cost(1) - 8:
				ho_eye = e
				ho_t = tc
				break
		if ho_eye != Vector3.INF:
			break
	main._set_tree_undergrowth(true)
	if ho_eye == Vector3.INF:
		_bad.append("handoff: no eye off to the side where the trees cost 5540-6060 whole (%s)" % ho_line)
	else:
		var c1x := x.undergrowth_cost(1)
		var c1y := y.undergrowth_cost(1)
		var ho_bud := clampi(ho_t + (c1x + c1y) / 2 + 60, Forest.BUDGET_MIN, 6299)
		main.xr_camera.position = ho_eye
		for t in forest.trees():
			t.clear_undergrowth()
		x.set_undergrowth_lod(0)
		y.set_undergrowth_lod(1)
		var ho_h := ""
		var ho_floor := 0
		var ho_off := 0
		for i in 2:
			forest.budget = ho_bud
			forest.apply_lod(ho_eye)
			ho_h += " %d" % forest.ug_headroom
			ho_floor = maxi(ho_floor, forest.ug_floor)
			if forest.ug_headroom < maxi(c1x, c1y) or forest.ug_headroom >= c1x + c1y:
				ho_off += 1
		print("PLANTSHOT handoff: budget %d, trees %d whole | X %.2f m (held LOD 0) Y %.2f m (held LOD 1) | floor %d, headroom per pass%s | X lod %d, Y lod %d" % [
			ho_bud, ho_t, x.global_position.distance_to(ho_eye), y.global_position.distance_to(ho_eye),
			ho_floor, ho_h, x.undergrowth_lod, y.undergrowth_lod])
		if ho_floor != 0 or ho_off != 0:
			_bad.append("handoff: fixture off (floor %d, headroom%s against one LOD 1 bed [%d, %d))" % [
				ho_floor, ho_h, maxi(c1x, c1y), c1x + c1y])
		if y.undergrowth_lod != 1 or x.undergrowth_lod != -1:
			_bad.append("handoff: the farther bed dropping out of LOD 0 took the one LOD 1 slot from the nearer (X %d, Y %d)" % [
				x.undergrowth_lod, y.undergrowth_lod])
	main.xr_camera.position = eye
	for t in forest.trees():
		t.clear_undergrowth()
	forest.budget = Forest.BUDGET_START


## The pair, its ballast and four more planted round them. At BUDGET_MIN the trees are short of
## detail, and the beds take none of it (each tree draws what it draws with undergrowth off). Beds
## bought there come from headroom the trees leave.
func _check_min_budget(main, forest: Forest) -> void:
	for s: Vector2 in [Vector2(-1.6, -2.4), Vector2(1.6, -2.5), Vector2(-0.9, -4.3), Vector2(1.0, -4.4)]:
		main._plant_tree_at(s)
	var eye := Vector3(0.0, 1.6, 0.0)
	await _hold(main, eye, Vector3(-14.0, 0.0, 0.0))
	await _grow_all(main, forest, false)
	main._set_tree_undergrowth(false)
	forest.budget = 60000
	forest.apply_lod(eye)
	var lods_full := _tree_lods(forest)
	forest.budget = Forest.BUDGET_MIN
	forest.apply_lod(eye)
	var lods_off := _tree_lods(forest)
	main._set_tree_undergrowth(true)
	forest.apply_lod(eye)
	await _settle_ug(forest, eye, Forest.BUDGET_MIN)
	var lods_on := _tree_lods(forest)
	var cut := 0
	var detail := 0
	var degraded := 0
	var c1_min := 1 << 30
	for t in lods_off:
		if int(lods_off[t]) > int(lods_full.get(t, 99)):
			cut += 1
		detail += t.lod_cost(int(lods_off[t])) - t.lod_cost(FractalTree.LOD_MAX)
		if int(lods_on.get(t, 99)) > int(lods_off[t]):
			degraded += 1
		c1_min = mini(c1_min, t.undergrowth_cost(1))
	var idn := _pass_identity(forest)
	print("PLANTSHOT min_budget: planted trees=%d cut_by_budget=%d detail_held=%d (cheapest bed %d) | undergrowth on: beds=%d degraded=%d headroom=%d %s" % [
		lods_off.size(), cut, detail, c1_min, forest.undergrowth_drawn, degraded, forest.ug_headroom,
		idn[1]])
	if cut < 1 or detail < c1_min:
		_bad.append("min budget: fixture has no detail to lose (cut %d, detail %d)" % [cut, detail])
	if degraded != 0:
		_bad.append("min budget: beds took tree detail at BUDGET_MIN (%d trees coarser)" % degraded)
	_totals_ok("min budget", idn)
	forest.budget = Forest.BUDGET_START


## PLANT_MAX planted on a 13 m ring round you, your eye raised to set how far every bed is (all
## twelve at once), at a pinned 7800 where the LOD 1 floor is full. Each eye is first run with
## undergrowth off for the tree detail it gets. Fresh at 14.0 m, under head sway across 14.0 m,
## the floor spends nothing and no tree draws coarser. Inside 13.5 m every bed stands on the floor
## and the trees give up detail for it (the detail there is to lose); 13.7 m keeps the floor; 14.1 m
## folds them, so floor 0 and the trees whole again; back at 13.7 m they stay off the floor.
func _check_fold_floor(main, forest: Forest) -> void:
	forest.clear()
	var r := 13.0
	var at := func(d: float, dy: float) -> Vector3:
		return Vector3(0.0, sqrt(d * d - r * r) + dy, 0.0)
	var start: Vector3 = at.call(14.0, 0.0)
	await _hold(main, start, Vector3(-14.0, 0.0, 0.0))
	var ring: Array[FractalTree] = []
	for k in Forest.PLANT_MAX:
		var th := deg_to_rad(360.0 * k / Forest.PLANT_MAX)
		if main._plant_tree_at(Vector2(r * sin(th), r * cos(th))):
			ring.append(forest.trees().back())
	await _grow_all(main, forest, false)
	var bud := Forest.UNDERGROWTH_FLOOR_FULL
	var sway: Array[Vector3] = []
	for dy: float in [-0.15, 0.15, -0.15, 0.15, 0.0]:
		sway.append(at.call(14.0, dy))
	var steps: Array[Vector3] = [at.call(13.3, 0.0), at.call(13.7, 0.0), at.call(14.1, 0.0),
		at.call(13.7, 0.0)]
	main._set_tree_undergrowth(false)
	var off_lods: Array = []
	var eyes: Array[Vector3] = [start]
	eyes.append_array(sway)
	eyes.append_array(steps)
	for e in eyes:
		forest.budget = bud
		forest.apply_lod(e)
		off_lods.append(_tree_lods(forest))
	forest.budget = 60000
	forest.apply_lod(steps[0])
	var t_sat: int = forest._far.drawn
	for t in forest.trees():
		if t.built and not t.far and t.grow_t > 0.0:
			t_sat += t.lod_cost(t.lod)
	main._set_tree_undergrowth(true)
	var c1_all := 0
	for t in ring:
		c1_all += t.undergrowth_cost(1)
	var coarser := func(now: Dictionary, base: Dictionary) -> int:
		var n := 0
		for t in base:
			if int(now.get(t, 99)) > int(base[t]):
				n += 1
		return n
	# Fresh at 14.0 m, then the sway, one pass per head position.
	main.xr_camera.position = start
	forest.apply_lod(start)
	await _settle_ug(forest, start, bud)
	var fresh_floor := forest.ug_floor
	var fresh_deg: int = coarser.call(_tree_lods(forest), off_lods[0])
	var sway_line := ""
	var sway_floor := 0
	var sway_deg := 0
	for i in sway.size():
		main.xr_camera.position = sway[i]
		forest.budget = bud
		forest.apply_lod(sway[i])
		sway_line += " %.2fm:%d" % [ring[0].global_position.distance_to(sway[i]), forest.ug_floor]
		sway_floor = maxi(sway_floor, forest.ug_floor)
		sway_deg += coarser.call(_tree_lods(forest), off_lods[1 + i])
	# Both sides of the fold, settled at each.
	var floors: Array[int] = []
	var degs: Array[int] = []
	var step_line := ""
	for i in steps.size():
		main.xr_camera.position = steps[i]
		forest.apply_lod(steps[i])
		await _settle_ug(forest, steps[i], bud)
		floors.append(forest.ug_floor)
		degs.append(coarser.call(_tree_lods(forest), off_lods[1 + sway.size() + i]))
		step_line += " %.1fm:%d(%d coarser)" % [ring[0].global_position.distance_to(steps[i]),
			floors[i], degs[i]]
	# In to 13.3 m, out to 13.7 m, then UNDERGROWTH off for one pass and on again without moving:
	# the beds still count as showing, so the floor must come back whole.
	main.xr_camera.position = steps[0]
	forest.apply_lod(steps[0])
	await _settle_ug(forest, steps[0], bud)
	main.xr_camera.position = steps[1]
	forest.apply_lod(steps[1])
	main._set_tree_undergrowth(false)
	forest.budget = bud
	forest.apply_lod(steps[1])
	main._set_tree_undergrowth(true)
	forest.apply_lod(steps[1])
	await _settle_ug(forest, steps[1], bud)
	var toggle_floor := forest.ug_floor
	step_line += " | toggled at 13.7m:%d" % toggle_floor
	var idn := _pass_identity(forest)
	print("PLANTSHOT fold_floor: %d planted on a 13 m ring at %d, trees %d whole, LOD 1 beds %d | fresh at 14.0 m: floor %d, %d trees coarser | sway%s, %d coarser | floor by distance%s %s" % [
		ring.size(), bud, t_sat, c1_all, fresh_floor, fresh_deg, sway_line, sway_deg, step_line, idn[1]])
	if ring.size() != Forest.PLANT_MAX or floors[0] != c1_all or degs[0] < 1:
		_bad.append("fold floor: fixture off (%d planted; inside 13.5 m floor %d of %d, %d trees coarser for it)" % [
			ring.size(), floors[0], c1_all, degs[0]])
	if fresh_floor != 0 or fresh_deg != 0 or sway_floor != 0 or sway_deg != 0:
		_bad.append("fold floor: beds at 14.0 m spent tree detail (floor %d, sway max %d, %d and %d trees coarser)" % [
			fresh_floor, sway_floor, fresh_deg, sway_deg])
	if floors[1] != c1_all:
		_bad.append("fold floor: 13.7 m dropped beds that showed off the floor (%d of %d)" % [floors[1], c1_all])
	if floors[2] != 0 or degs[2] != 0 or floors[3] != 0 or degs[3] != 0:
		_bad.append("fold floor: folded beds kept floor spend (14.1 m: %d, %d coarser; back at 13.7 m: %d, %d coarser)" % [
			floors[2], degs[2], floors[3], degs[3]])
	if toggle_floor != c1_all:
		_bad.append("fold floor: UNDERGROWTH off and on at 13.7 m forgot the beds were showing (floor %d of %d)" % [
			toggle_floor, c1_all])
	_totals_ok("fold floor", idn)
	main.xr_camera.position = Vector3(0.0, 1.6, 0.0)
	forest.clear()
	forest.budget = Forest.BUDGET_START
	for i in 3:
		await process_frame


## A sown grove and one fresh planted tree clear of every bed. Over 6000-6360 the floor rounds down
## to no beds, so every bed comes from step 4's headroom; each pass starts from the sown beds held as
## at the start budget and the planted bed fresh. Whenever the headroom covers both the planted bed's
## LOD 1 and the cheapest holder's, the planted tree must have one. Then a second planted tree beside
## a holder (7b), and the grove shrunk to 0.25x.
func _check_sweep_and_scale(main, forest: Forest) -> void:
	forest.clear()
	var eye := Vector3(0.0, 1.6, 0.0)
	await _hold(main, eye, Vector3(-14.0, 0.0, 0.0))
	main._sow_grove()
	await _grow_all(main, forest, true)
	forest.budget = Forest.BUDGET_START
	forest.apply_lod(eye)
	await _settle_ug(forest, eye, Forest.BUDGET_START)
	var hero_w: Vector3 = main.tree.global_position
	var spot := Vector2.INF
	for off: Vector2 in [Vector2(-2.4, -0.4), Vector2(2.3, -0.2), Vector2(-1.9, 0.6), Vector2(1.9, 0.5)]:
		var c := Vector2(hero_w.x, hero_w.z) + off
		var clear := true
		for t in forest.trees():
			if Vector2(t.global_position.x, t.global_position.z).distance_to(c) < 1.0:
				clear = false
				break
		if clear:
			spot = c
			break
	if spot == Vector2.INF or not main._plant_tree_at(spot):
		_bad.append("sweep: no clear spot to plant")
		return
	var p: FractalTree = forest.trees().back()
	await _grow_all(main, forest, false, true)
	forest.apply_lod(eye)
	await _settle_ug(forest, eye, Forest.BUDGET_START)
	var snap := {}
	var c1_sown := 1 << 30
	for t in forest.trees():
		if not t.hand_planted:
			snap[t] = t.undergrowth_lod
			if t.undergrowth_lod >= 0:
				c1_sown = mini(c1_sown, t.undergrowth_cost(1))
	var c1p := p.undergrowth_cost(1)
	# Step back from the grove until the trees, given all the detail they ask for, cost 5650-6050:
	# then 6000-6360 leaves them whole and step 4 a headroom of budget minus that, swept through
	# the planted bed's LOD 1 cost and its hysteresis margin. At the grove's own eye the trees
	# soak up any budget and leave step 4 a few dozen instances. The planted tree must stay inside
	# 13.3 m, where its bed shows, so the eye may stand on any side of the grove.
	var found := _eye_for_cost(forest, hero_w, 5650, 6050, func(e: Vector3) -> bool:
		return p.global_position.distance_to(e) < 13.3)
	var sweep_eye: Vector3 = found[0]
	var t_cost: int = found[1]
	if sweep_eye == Vector3.INF:
		_bad.append("sweep: no eye with the planted tree inside 13.3 m where the satisfied trees cost 5650-6050 (%s)" % found[2])
		return
	eye = sweep_eye
	var sweep_d := p.global_position.distance_to(eye)
	main.xr_camera.position = eye
	var passes := 0
	var window := 0
	var bad := 0
	var kept_bare := 0
	var bad_line := ""
	var planted_beds := 0
	for bud in range(Forest.BUDGET_MIN, 6360, 3):
		p.clear_undergrowth()
		for t in snap:
			t.set_undergrowth_lod(int(snap[t]))
		forest.budget = bud
		forest.apply_lod(eye)
		passes += 1
		var h := forest.ug_headroom
		var sown_held := 0
		for t in snap:
			if t.undergrowth_lod >= 0:
				sown_held += 1
		if c1p <= h and h < c1p + Forest.UNDERGROWTH_BUDGET_HYST and c1_sown <= h:
			window += 1
		if p.undergrowth_lod >= 0:
			planted_beds += 1
		elif c1p <= h and c1_sown <= h:
			# Each pass starts with a sown holder that could pay its LOD 1 out of this headroom, so
			# the planted bed is owed one whether or not the holder ends up keeping its own.
			bad += 1
			if sown_held > 0:
				kept_bare += 1
			if bad_line == "":
				bad_line = " first at %d: headroom %d, %d sown held after, planted LOD 1 %d" % [bud, h, sown_held, c1p]
	print("PLANTSHOT sweep: %.2f m from the hero the trees cost %d whole, planted %.2f m off | %d passes over %d-6359, planted LOD 1 %d, cheapest sown holder %d | in the margin window %d | planted bedded %d | planted bare with an affordable holder at the start %d (sown kept meanwhile %d)%s" % [
		found[3], t_cost, sweep_d, passes, Forest.BUDGET_MIN, c1p, c1_sown, window, planted_beds, bad,
		kept_bare, bad_line])
	if window < 1:
		_bad.append("sweep: no pass landed between the planted bed's LOD 1 cost and its hysteresis margin")
	if bad != 0:
		_bad.append("sweep: the planted bed went without while a sown holder could pay out of the headroom it could pay from (%d passes)%s" % [bad, bad_line])

	# 7b. A second planted tree 0.5 m out from the sown holder (as held at the start budget)
	# furthest round the hero from the first plant, and an eye that ranks it ahead of the first. Each pass holds only that sown bed,
	# both planted beds fresh. With headroom for both planted LOD 1 beds but not the second's
	# margin, the nearer plant waives the margin against the holder and crowds it out; the second
	# has no holder left to waive against and goes without. The floor rounds to no beds only below
	# 6300 here, and at 1x the 16-tree grove costs over 6600 whole wherever both planted beds show,
	# so this runs on the grove grabbed to 0.5x (tree detail follows size on screen, and the
	# spacing rule scales with the trees).
	var hero2: Vector3 = main.tree.global_position
	var pdir := Vector2(p.global_position.x - hero2.x, p.global_position.z - hero2.z).normalized()
	var s_hold: FractalTree = null
	var s_ang := -1.0
	for t in snap:
		if int(snap[t]) < 0:
			continue
		var sd := Vector2(t.global_position.x - hero2.x, t.global_position.z - hero2.z).normalized()
		if absf(sd.angle_to(pdir)) > s_ang:
			s_ang = absf(sd.angle_to(pdir))
			s_hold = t
	if s_hold == null:
		_bad.append("waiver: no sown holder to plant beside")
		return
	var sw := s_hold.global_position
	var p1_spot := Vector2(sw.x, sw.z) + Vector2(sw.x - hero2.x, sw.z - hero2.z).normalized() * 0.5
	if not main._plant_tree_at(p1_spot):
		_bad.append("waiver: could not plant beside the holder")
		return
	var p1: FractalTree = forest.trees().back()
	await _grow_all(main, forest, false, true)
	main.cloud.scale = Vector3.ONE * 0.5
	for i in 2:
		await process_frame
	var grove_mid := Vector3.ZERO
	for t in snap:
		grove_mid += t.global_position / float(snap.size())
	var c1p1 := p1.undergrowth_cost(1)
	var c1s := s_hold.undergrowth_cost(1)
	var w_lo := c1p1 + c1p
	var w_hi := w_lo + Forest.UNDERGROWTH_BUDGET_HYST
	# Floor off below 6300 with two planted beds; the window [w_lo, w_hi) must fall inside
	# 6000-6299 minus what the satisfied trees cost.
	var found2 := _eye_for_cost(forest, grove_mid, Forest.BUDGET_MIN - w_hi + 10, 6299 - w_lo - 10,
		func(e: Vector3) -> bool:
			var a1 := p1.global_position.distance_to(e)
			var a2 := p.global_position.distance_to(e)
			return a2 < 13.3 and a1 < a2 - 0.1)
	var eye2: Vector3 = found2[0]
	var t2: int = found2[1]
	if eye2 == Vector3.INF:
		_bad.append("waiver: no eye ranking the near plant first where the headroom window [%d, %d) fits 6000-6299 (%s)" % [
			w_lo, w_hi, found2[2]])
		main.cloud.scale = Vector3.ONE
		return
	main.xr_camera.position = eye2
	var dp1 := p1.global_position.distance_to(eye2)
	var dp := p.global_position.distance_to(eye2)
	var gap1 := Vector2(p1.global_position.x, p1.global_position.z).distance_to(
		Vector2(s_hold.global_position.x, s_hold.global_position.z))
	var window2 := 0
	var bad2 := 0
	var bad2_line := ""
	for bud in range(Forest.BUDGET_MIN, 6300, 3):
		p.clear_undergrowth()
		p1.clear_undergrowth()
		for t in snap:
			t.clear_undergrowth()
		s_hold.set_undergrowth_lod(1)
		forest.budget = bud
		forest.apply_lod(eye2)
		var h := forest.ug_headroom
		if forest.ug_floor != 0 or h < w_lo or h >= w_hi or c1s > h:
			continue
		window2 += 1
		if p1.undergrowth_lod < 0 or s_hold.undergrowth_lod >= 0 or p.undergrowth_lod >= 0:
			bad2 += 1
			if bad2_line == "":
				bad2_line = " first at %d: headroom %d, near plant %d, holder %d, second plant %d" % [
					bud, h, p1.undergrowth_lod, s_hold.undergrowth_lod, p.undergrowth_lod]
	main.cloud.scale = Vector3.ONE
	eye = Vector3(0.0, 1.6, 0.0)
	await _hold(main, eye, Vector3(-14.0, 0.0, 0.0))
	forest.budget = Forest.BUDGET_START
	forest.apply_lod(eye)
	await _settle_ug(forest, eye, Forest.BUDGET_START)
	print("PLANTSHOT waiver: grove 0.5x, %.2f m from its middle the trees cost %d whole | near plant %.2fm (world) from the holder, %.2f m from you, the first plant %.2f m | headroom window [%d, %d) hit %d times | the second plant waived against a crowded-out holder %d%s" % [
		found2[3], t2, gap1, dp1, dp, w_lo, w_hi, window2, bad2, bad2_line])
	if dp1 >= dp - 1e-3 or gap1 >= Forest.UNDERGROWTH_GROVE_SPACING * 0.5:
		_bad.append("waiver: fixture off (near plant %.2f m from you against %.2f m, %.2f m from the holder)" % [dp1, dp, gap1])
	if window2 < 1:
		_bad.append("waiver: no pass had headroom for both planted LOD 1 beds but not the second's margin")
	if bad2 != 0:
		_bad.append("waiver: a second planted bed waived the margin against a holder the first had crowded out (%d passes)%s" % [bad2, bad2_line])

	# Shrink the grove (grab scales the cloud, the forest's parent). Both planted trees shrink with
	# it, so they crowd exactly the sown beds they crowded at 1x: the holder beside the near plant
	# stays bare, and the rest keep theirs.
	var held_1x: Array[FractalTree] = []
	for t in forest.trees():
		if not t.hand_planted and t.undergrowth_lod >= 0:
			held_1x.append(t)
	var s_1x := s_hold.undergrowth_lod
	main.cloud.scale = Vector3.ONE * 0.25
	await _settle_ug(forest, eye, Forest.BUDGET_START)
	var held_small: Array[FractalTree] = []
	for t in forest.trees():
		if not t.hand_planted and t.undergrowth_lod >= 0:
			held_small.append(t)
	var s_small := s_hold.undergrowth_lod
	var same := held_small.size() == held_1x.size()
	for t in held_1x:
		if not held_small.has(t):
			same = false
	# A world-sized tree planted 0.5 m from the sown holder nearest the eye, away from the hero.
	var hero_s: Vector3 = main.tree.global_position
	var near_h: FractalTree = null
	for t in held_small:
		if near_h == null or t.global_position.distance_to(eye) < near_h.global_position.distance_to(eye):
			near_h = t
	var q_ok := false
	var q: FractalTree = null
	var gap := 0.0
	if near_h != null:
		var hw := near_h.global_position
		var out := Vector2(hw.x - hero_s.x, hw.z - hero_s.z).normalized()
		var qs := Vector2(hw.x, hw.z) + out * 0.5
		if main._plant_tree_at(qs):
			q = forest.trees().back()
			await _grow_all(main, forest, false, true)
			forest.apply_lod(eye)
			await _settle_ug(forest, eye, Forest.BUDGET_START)
			gap = Vector2(q.global_position.x, q.global_position.z).distance_to(Vector2(hw.x, hw.z))
			q_ok = q.undergrowth_lod >= 0 and _drawn(q) and near_h.undergrowth_lod < 0
			var cam := hw + Vector3(-1.2, 1.1, 1.6)
			await _hold(main, cam, _look(cam, hw + Vector3(0.0, 0.2, 0.0)))
			_capture().save_png("res://.spike-out/planted_scaled.png")
			await _hold(main, eye, Vector3(-14.0, 0.0, 0.0))
	var idn := _pass_identity(forest)
	print("PLANTSHOT scaled: grove 0.25x | sown beds at 1x %d, at 0.25x %d (same=%s) | holder beside the near plant: lod %d at 1x, %d at 0.25x | planted after the shrink %.2fm from a holder: planted_lod=%d holder_lod=%d (gave way=%s) %s" % [
		held_1x.size(), held_small.size(), str(same), s_1x, s_small, gap,
		q.undergrowth_lod if q != null else -9, near_h.undergrowth_lod if near_h != null else -9,
		str(near_h != null and near_h.undergrowth_lod < 0), idn[1]])
	if held_1x.is_empty() or not same:
		_bad.append("scaled: shrinking the grove changed which sown beds a tree planted at 1x crowds (%d at 1x, %d at 0.25x)" % [
			held_1x.size(), held_small.size()])
	if s_1x >= 0 or s_small >= 0:
		_bad.append("scaled: the sown bed 0.5 m from a tree planted at 1x held one (lod %d at 1x, %d at 0.25x)" % [
			s_1x, s_small])
	if not q_ok:
		_bad.append("scaled: planted %.2fm (world) from a sown holder in a 0.25x grove did not take its place" % gap)
	_totals_ok("scaled", idn)
	forest.clear()
	main.cloud.scale = Vector3.ONE
	for i in 3:
		await process_frame


## COUNT 60 sown from the eye. From 10 m above the middle of the path, at the step's 44000 ceiling,
## over 16 avenue trees stand inside the bed cut, all past 9 m so every bed wants LOD 1 and the
## 6400 bed budget could pay for more than 16: the avenue's beds keep the 16 cap. (On the ground the
## LOD 0 beds near you spend the 6400 before 16, so the cap never binds there.) Then, standing at
## the middle at the step's start budget, 12 trees planted 14.0 m out (14.1 m from the eye, inside
## the 14.2 m cut, past the 14.0 m fold): the floor spends what it spent before they were
## planted, and a folded planted bed holds a bed only once every nearer sown bed that shows has one.
func _check_cap_and_fold(main, forest: Forest) -> void:
	forest.clear()
	forest.set_count(1)
	var start := Vector3(0.0, 1.6, 0.0)
	await _hold(main, start, Vector3(-11.0, 0.0, 0.0))
	main._sow_avenue(false)
	await _grow_all(main, forest, false)
	var bud := int(forest.step()["budget"])
	var top := int(forest.step()["budget_max"])
	var high := Vector3(0.0, 10.0, -26.0)
	await _hold(main, high, Vector3(-62.0, 0.0, 0.0))
	forest.apply_lod(high)
	await _settle_ug(forest, high, top)
	var elig := 0
	var near_min := INF
	var av_beds := 0
	var av_l1 := 0
	for t in forest.trees():
		if t.row < 0:
			continue
		var d := t.global_position.distance_to(high)
		if d < Forest.UNDERGROWTH_FAR_IN:
			elig += 1
			near_min = minf(near_min, d)
		if t.undergrowth_lod >= 0:
			av_beds += 1
			if t.undergrowth_lod == 1:
				av_l1 += 1
	var idn := _pass_identity(forest)
	var spare := Forest.UNDERGROWTH_BUDGET_MAX
	for t in forest.trees():
		spare -= t.undergrowth_cost(t.undergrowth_lod)
	print("PLANTSHOT cap: COUNT %d from 10 m above the path at %d: %d sown trees inside the cut (nearest %.1f m), %d sown beds (max %d, %d at LOD 1), bed budget left %d, headroom %d %s visible=%d" % [
		int(forest.step()["n"]), top, elig, near_min, av_beds, Forest.UNDERGROWTH_NEAR, av_l1, spare,
		forest.ug_headroom, idn[1], forest.visible_cost])
	if elig <= Forest.UNDERGROWTH_NEAR or near_min < Forest.UNDERGROWTH_LOD0_OUT:
		_bad.append("cap: fixture off (%d sown candidates, nearest %.1f m)" % [elig, near_min])
	if av_beds != Forest.UNDERGROWTH_NEAR:
		_bad.append("cap: %d sown beds against the %d cap" % [av_beds, Forest.UNDERGROWTH_NEAR])
	_totals_ok("cap", idn)

	var eye := Vector3(0.0, 1.6, -26.0)
	await _hold(main, eye, Vector3(-11.0, 0.0, 0.0))
	forest.apply_lod(eye)
	await _settle_ug(forest, eye, bud)
	var floor_before := forest.ug_floor

	var r := sqrt(14.1 * 14.1 - 1.6 * 1.6)
	var planted: Array[FractalTree] = []
	for side: float in [-1.0, 1.0]:
		for deg: float in [45.0, 63.0, 81.0, 99.0, 117.0, 135.0]:
			var th := deg_to_rad(deg)
			if main._plant_tree_at(Vector2(eye.x + side * r * sin(th), eye.z + r * cos(th))):
				planted.append(forest.trees().back())
	await _grow_all(main, forest, false, true)
	await _hold(main, eye, Vector3(-11.0, 0.0, 0.0))
	forest.apply_lod(eye)
	await _settle_ug(forest, eye, bud)
	var folded := 0
	var folded_held := 0
	for t in planted:
		var d := t.global_position.distance_to(eye)
		if d >= Forest.UNDERGROWTH_FOLD_M and d < Forest.UNDERGROWTH_FAR_IN:
			folded += 1
		if t.undergrowth_lod >= 0:
			folded_held += 1
	# The sown candidates the cap admits, nearest first; those inside the fold draw.
	var sown: Array = []
	for t in forest.trees():
		if t.row >= 0 and t.global_position.distance_to(eye) < Forest.UNDERGROWTH_FAR_IN:
			sown.append([t.global_position.distance_to(eye), t])
	sown.sort_custom(func(x: Array, y: Array) -> bool: return float(x[0]) < float(y[0]))
	var vis_bare := 0
	var vis := 0
	for k in mini(sown.size(), Forest.UNDERGROWTH_NEAR):
		if float(sown[k][0]) < Forest.UNDERGROWTH_FOLD_M:
			vis += 1
			if (sown[k][1] as FractalTree).undergrowth_lod < 0:
				vis_bare += 1
	var idf := _pass_identity(forest)
	print("PLANTSHOT fold: %d planted at %.1f m, %d of them folded inside the cut, %d holding a bed | nearest sown that show: %d, %d bare | sown beds %d, floor %d (before planting %d) %s visible=%d budget=%d" % [
		planted.size(), sqrt(r * r + 1.6 * 1.6), folded, folded_held, vis, vis_bare,
		_sown_beds(forest), forest.ug_floor, floor_before, idf[1], forest.visible_cost, bud])
	if forest.ug_floor != floor_before:
		_bad.append("fold: planting 12 folded beds moved the floor from %d to %d" % [
			floor_before, forest.ug_floor])
	if planted.size() != Forest.PLANT_MAX or folded != planted.size() or vis < 1:
		_bad.append("fold: fixture off (%d planted, %d folded, %d sown that show)" % [planted.size(), folded, vis])
	if folded_held > 0 and vis_bare > 0:
		_bad.append("fold: %d folded planted beds held while %d nearer sown beds that show had none" % [
			folded_held, vis_bare])
	_totals_ok("fold", idf)
	forest.clear()
	forest.set_count(0)


## The nearest eye at 1.6 m round `mid` (every 10 degrees, 3 to 15 m out) where the trees, given
## all the detail they ask for, cost lo..hi and `ok` holds. [eye or Vector3.INF, cost, trail, metres out].
func _eye_for_cost(forest: Forest, hero: Vector3, lo: int, hi: int, ok: Callable) -> Array:
	var trail := ""
	for k in 49:
		var s := 3.0 + 0.25 * k
		var noted := k % 8 != 0
		for j in 36:
			var phi := deg_to_rad(10.0 * j)
			var e := Vector3(hero.x + s * sin(phi), 1.6, hero.z + s * cos(phi))
			if not bool(ok.call(e)):
				continue
			forest.budget = 60000
			forest.apply_lod(e)
			var tc := _whole_cost(forest)
			if not noted:
				trail += " %.1fm:%d" % [s, tc]
				noted = true
			if tc >= lo and tc <= hi:
				return [e, tc, trail, s]
	return [Vector3.INF, 0, trail, 0.0]


func _whole_cost(forest: Forest) -> int:
	var tc: int = forest._far.drawn
	for t in forest.trees():
		if t.built and not t.far and t.grow_t > 0.0:
			tc += t.lod_cost(t.lod)
	return tc


func _totals_ok(what: String, idn: Array) -> void:
	if not bool(idn[0]):
		_bad.append("%s: pass totals off from what the nodes draw (%s)" % [what, idn[1]])


func _sown_beds(forest: Forest) -> int:
	var n := 0
	for t in forest.trees():
		if not t.hand_planted and t.undergrowth_lod >= 0:
			n += 1
	return n


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


## What the LOD pass reports against what the forest's MultiMesh nodes draw, from every visible
## node and the instances it draws (visible_instance_count, or all of them at -1), so a bed hidden,
## left visible, or handed the wrong tier's MultiMesh shows up even where the allocator's own table
## agrees with itself. Each bed node counts on its own, so foliage left showing over hidden stems
## is a bed and its cost. The far batch reports its own drawn range.
func _pass_identity(forest: Forest) -> Array:
	var beds := 0
	var stems := 0
	var leaves := 0
	var cost: int = forest._far.drawn
	for t in forest.trees():
		cost += _mm_drawn(t._branches) + _mm_drawn(t._leaves)
		var ns := t.undergrowth_nodes()
		var shown := false
		for n in ns:
			if n.is_visible_in_tree():
				shown = true
			cost += _mm_drawn(n)
		if not shown:
			continue
		beds += 1
		stems += _mm_drawn(ns[0])
		if ns.size() > 1:
			leaves += _mm_drawn(ns[1])
	var ok := beds == forest.undergrowth_drawn and stems == forest.drawn_undergrowth_stems \
		and leaves == forest.drawn_undergrowth_leaves and cost == forest.visible_cost
	return [ok, "beds %d/%d stems %d/%d leaves %d/%d cost %d/%d" % [forest.undergrowth_drawn, beds,
		forest.drawn_undergrowth_stems, stems, forest.drawn_undergrowth_leaves, leaves,
		forest.visible_cost, cost]]


func _mm_drawn(n: MultiMeshInstance3D) -> int:
	if n == null or n.multimesh == null or not n.is_visible_in_tree():
		return 0
	var all := n.multimesh.instance_count
	var v := n.multimesh.visible_instance_count
	return all if v < 0 else mini(v, all)


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
