extends SceneTree

## Verification, visual capture, and Mac GPU cost measurement for TREE's fractal undergrowth
## (tree_undergrowth.gd) through the real main scene.
##
## Checks (every one falsifiable and designed to fail if undergrowth breaks):
##   1. Library & H1a subset: all VARIANTS x LODS build all 5 plant families inside bounds,
##      LOD 1 cheaper than LOD 0 and a strict geometric subset of LOD 0 in order.
##   2. Grove drawn, M1 density/height/scale, H1b eye-sway stability, H2 spin-on hero bed
##      stillness, M2 trees-first headroom (zero tree LOD loss under tight budget), the LOD 1
##      floor at one governor step under the trees' own cost (2 or more beds), a budget tier
##      change one governor step down and back up with no frame where the drawn stems or the
##      frame luma jump, and a GROVE succession whose fading bed is counted in the pass totals.
##   3. Controls (M4): LEAVES off splits hero + forest undergrowth leaves from stems and changes
##      pixels; WIND gusty moves stems (control) while WIND off holds them completely still.
##   4. Avenue standing, path clearance (> 2 m), H1b sticky LOD hysteresis across boundaries,
##      close-up/macro/hero captures, Mac Vulkan GPU cost ratios.
##   5. WALK stretch (M3 & L1): zero builds across >= 10 recycles, waiting trees clear LOD
##      immediately (L1), withering trees behind you receive no beds (M3), bed count stays up
##      over time, and no eligible tree within the 11 m fade end is denied by budget.
##   6. Far tier (COUNT 500): zero far-tier trees carry visible undergrowth; near count capped.
##   7. CLEAR & mode switch (M4): pre-clear node snapshot + subtree walk verify zero leaked
##      nodes after CLEAR, zero visible in FLAME, and clean restore returning to TREE.
##
##   tools/undergrowth_shot.sh
##   UG_FAST=1 skips the GPU cost pairs; UG_ONLY=grove stops after the grove checks.

const SPEED := 4.0
const ROUNDS := 3
const MEASURE_FRAMES := 90

var _vp: RID
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

	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	_vp = root.get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(_vp, true)

	# --- 1. Built, geometry bounds & H1a strict-subset LOD ----------------------------------
	_check_library()

	# --- 2. Grove standing, M1/H1b/H2/M2 checks, close-ups, controls, GPU cost --------------
	await _grow_all(main, forest, true)
	forest.apply_lod(main.xr_camera.global_position)
	for i in 12:
		await process_frame

	var grove_eye := Vector3(0.0, 1.6, -1.6)
	var grove_rot := Vector3(-16.0, 0.0, 0.0)
	main._set_tree_undergrowth(true)
	forest.apply_lod(grove_eye)
	await _settle_ug(forest, grove_eye)
	await _hold(main, grove_eye, grove_rot)
	var g_on := _capture()
	g_on.save_png("res://.spike-out/ug_grove_stand.png")
	var g_prims_on := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
	var g_ug_trees := _visible_ug_count(main, forest)

	# M1: grove beds on hero + a few inner trees only, none under ~1 m, hero scale <= 1.0.
	var grove_min_h := INF
	var grove_bed_spots: Array[Vector2] = []
	for t in forest.trees():
		if t.undergrowth_lod >= 0:
			grove_min_h = minf(grove_min_h, t.height_m)
			var lp := forest.to_local(t.global_position)
			grove_bed_spots.append(Vector2(lp.x, lp.z))
	var grove_min_gap := INF
	for a in grove_bed_spots.size():
		for b in range(a + 1, grove_bed_spots.size()):
			grove_min_gap = minf(grove_min_gap, grove_bed_spots[a].distance_to(grove_bed_spots[b]))
	var hero_scale: float = main.tree.undergrowth_nodes()[0].transform.basis.get_scale().x
	print("UGSHOT grove_density: forest_beds=%d (max %d) min_h=%.2fm min_gap=%.2fm hero_scale=%.2f" % [
		forest.undergrowth_drawn, Forest.UNDERGROWTH_GROVE_MAX, grove_min_h,
		grove_min_gap if grove_min_gap < INF else 9.99, hero_scale])
	if forest.undergrowth_drawn == 0 or forest.undergrowth_drawn > Forest.UNDERGROWTH_GROVE_MAX \
			or grove_min_h < Forest.UNDERGROWTH_GROVE_MIN_H - 1e-3 \
			or grove_min_gap < Forest.UNDERGROWTH_GROVE_SPACING - 1e-3 \
			or hero_scale > 1.01:
		_bad.append("M1 grove density/scale failed: beds=%d min_h=%.2f gap=%.2f hero_scale=%.2f" % [
			forest.undergrowth_drawn, grove_min_h, grove_min_gap, hero_scale])

	# H1b (GROVE): head sway and walking round the copse must not reshuffle a single grove bed.
	var base_map := _ug_lod_map(forest)
	var grove_sway_flips := 0
	var hero_p: Vector3 = main.tree.global_position
	for eye_p in [grove_eye + Vector3(0.45, 0.0, 0.0), grove_eye + Vector3(-0.45, 0.0, 0.0),
			grove_eye + Vector3(0.0, 0.0, 0.45), hero_p + Vector3(2.2, 1.6, 0.0),
			hero_p + Vector3(-2.2, 1.6, 0.0), hero_p + Vector3(0.0, 1.6, -2.2), grove_eye]:
		forest.apply_lod(eye_p)
		grove_sway_flips += _count_lod_diffs(base_map, _ug_lod_map(forest))
	print("UGSHOT grove_sway: flips=%d across 7 eye positions" % grove_sway_flips)
	if grove_sway_flips != 0:
		_bad.append("H1 grove beds reshuffled under eye movement (%d flips)" % grove_sway_flips)

	# H2: with spin = true (default), hero tree turns while its undergrowth bed stays rooted.
	main._set_forest_wind(0.0)
	main.spin = true
	await process_frame
	var yaw0: float = main.tree.rotation.y
	var bed0: Transform3D = main.tree.undergrowth_nodes()[0].global_transform
	var probe0 := bed0 * Vector3(1.0, 0.2, 0.0)
	Engine.time_scale = 4.0
	var spin_frames := 0
	while absf(main.tree.rotation.y - yaw0) < 0.22 and spin_frames < 1200:
		await process_frame
		spin_frames += 1
	Engine.time_scale = 1.0
	var yaw1: float = main.tree.rotation.y
	var bed1: Transform3D = main.tree.undergrowth_nodes()[0].global_transform
	var probe1 := bed1 * Vector3(1.0, 0.2, 0.0)
	var hero_turn := absf(yaw1 - yaw0)
	var bed_drift := probe1.distance_to(probe0)
	main.spin = false
	main._set_forest_wind(FractalMain.TREE_WIND[main.tree_wind_idx])
	print("UGSHOT hero_spin: hero_turned=%.3frad bed_edge_drift=%.5fm" % [hero_turn, bed_drift])
	if hero_turn < 0.18 or bed_drift > 0.002:
		_bad.append("H2 hero undergrowth spun with trunk: turn=%.3f drift=%.4fm" % [hero_turn, bed_drift])

	# N2 / M2: LOD 1 floor reserved at tight budget before tree detail, shrinks to 0 at
	# BUDGET_MIN, and mid headroom preserves full tree detail.
	var bud_save := forest.budget
	main._set_tree_undergrowth(false)
	forest.budget = Forest.BUDGET_START
	forest.apply_lod(grove_eye)
	var trees_only_cost := forest.visible_cost
	# One governor step (x0.85) under what the trees alone cost: the throttled grove.
	var tight_bud := int(float(trees_only_cost) * 0.85)
	forest.budget = tight_bud
	main._set_tree_undergrowth(true)
	forest.apply_lod(grove_eye)
	await _settle_ug(forest, grove_eye, tight_bud)
	var ug_at_tight := forest.undergrowth_drawn
	var tight_lod0 := 0
	var tight_lod1 := 0
	for t in forest.trees():
		if t.undergrowth_lod == 0:
			tight_lod0 += 1
		elif t.undergrowth_lod == 1:
			tight_lod1 += 1
	var tight_vis := forest.visible_cost

	# Floor shrinks to 0 at BUDGET_MIN with zero tree LOD degradation.
	forest.budget = Forest.BUDGET_MIN
	main._set_tree_undergrowth(false)
	forest.apply_lod(grove_eye)
	var min_lods_off := _tree_lod_map(forest)
	main._set_tree_undergrowth(true)
	forest.apply_lod(grove_eye)
	await _settle_ug(forest, grove_eye, Forest.BUDGET_MIN)
	var min_lods_on := _tree_lod_map(forest)
	var ug_at_min := forest.undergrowth_drawn
	var degraded_min := 0
	for t in min_lods_off:
		if int(min_lods_on.get(t, 99)) > int(min_lods_off[t]):
			degraded_min += 1

	# Partial headroom above full trees + floor: zero tree degradation, undergrowth gets floor + headroom.
	var mid_bud := trees_only_cost + Forest.UNDERGROWTH_FLOOR_BUDGET + 400
	forest.budget = mid_bud
	main._set_tree_undergrowth(false)
	forest.apply_lod(grove_eye)
	var mid_lods_off := _tree_lod_map(forest)
	main._set_tree_undergrowth(true)
	forest.apply_lod(grove_eye)
	await _settle_ug(forest, grove_eye, mid_bud)
	var mid_lods_on := _tree_lod_map(forest)
	var ug_at_mid := forest.undergrowth_drawn
	var degraded_mid := 0
	for t in mid_lods_off:
		if int(mid_lods_on.get(t, 99)) > int(mid_lods_off[t]):
			degraded_mid += 1
	forest.budget = bud_save
	forest.apply_lod(grove_eye)
	await _settle_ug(forest, grove_eye)
	print("UGSHOT headroom: trees_cost=%d tight(%d)_ug=%d(lod0=%d,lod1=%d,vis=%d) min(%d)_ug=%d(deg=%d) mid(%d)_ug=%d(deg=%d)" % [
		trees_only_cost, tight_bud, ug_at_tight, tight_lod0, tight_lod1, tight_vis,
		Forest.BUDGET_MIN, ug_at_min, degraded_min, mid_bud, ug_at_mid, degraded_mid])
	if ug_at_tight < 2 or ug_at_tight > Forest.UNDERGROWTH_FLOOR_BEDS or tight_lod0 != 0 \
			or tight_vis > tight_bud or ug_at_min != 0 or degraded_min != 0 \
			or degraded_mid != 0 or ug_at_mid < 2:
		_bad.append("N2 floor/headroom failed: tight_ug=%d(l0=%d,vis=%d/%d) min_ug=%d(deg=%d) mid_ug=%d(deg=%d)" % [
			ug_at_tight, tight_lod0, tight_vis, tight_bud, ug_at_min, degraded_min, ug_at_mid, degraded_mid])

	main._set_tree_undergrowth(false)
	forest.apply_lod(grove_eye)
	await _hold(main, grove_eye, grove_rot)
	var g_off := _capture()
	g_off.save_png("res://.spike-out/ug_grove_off.png")
	var g_prims_off := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
	var g_diff := _diff(g_on, g_off)
	print("UGSHOT grove drawn: trees=%d prims %d->%d (+%d) diff=%.4f" % [
		g_ug_trees, g_prims_off, g_prims_on, g_prims_on - g_prims_off, g_diff])
	if g_ug_trees < 3 or g_prims_on <= g_prims_off or g_diff < 0.004:
		_bad.append("grove undergrowth not drawn: trees=%d dprims=%d diff=%.4f" % [
			g_ug_trees, g_prims_on - g_prims_off, g_diff])

	var g_cost := await _cost_pair(main, forest, "grove", grove_eye, grove_rot)

	main._set_tree_undergrowth(true)
	forest.apply_lod(grove_eye)
	await _settle_ug(forest, grove_eye)
	# Stand outside the grove's front rim looking low across the nearest grove feet toward the hero.
	var hero_pos: Vector3 = main.tree.global_position
	var cu_eye := hero_pos + Vector3(0.45, 0.72, 2.35)
	var cu_rot := _look(cu_eye, hero_pos + Vector3(0.0, 0.25, 0.55))
	await _hold(main, cu_eye, cu_rot)
	var cu_leaves_on := _capture()
	cu_leaves_on.save_png("res://.spike-out/ug_grove_closeup.png")

	# Hero-foot close-up showing the hero's bed scale and plant mix directly (clear of rim trunks).
	var hc_eye := hero_pos + Vector3(0.08, 0.44, 0.92)
	var hc_rot := _look(hc_eye, hero_pos + Vector3(0.0, 0.20, 0.0))
	await _hold(main, hc_eye, hc_rot)
	_capture().save_png("res://.spike-out/ug_hero_closeup.png")

	# M4 fixed controls: LEAVES off checked on hero + ALL forest undergrowth trees + pixel diff;
	# WIND control isolated strictly to the hero undergrowth bed (forest and hero trunk hidden)
	# so hero/forest sway cannot satisfy it, plus shader presence visual verification (1 / 0.5 / 0).
	await _hold(main, cu_eye, cu_rot)
	main._set_forest_leaves(false)
	await _hold(main, cu_eye, cu_rot)
	var cu_leaves_off := _capture()
	var leaves_diff := _diff(cu_leaves_on, cu_leaves_off)
	var leaves_ok := true
	var checked_forest_ug := 0
	for n in main.tree.undergrowth_nodes():
		if n.name == "UndergrowthStems" and not n.is_visible_in_tree():
			leaves_ok = false
		if n.name == "UndergrowthLeaves" and n.is_visible_in_tree():
			leaves_ok = false
	for t in forest.trees():
		if t.undergrowth_lod < 0:
			continue
		var ns := t.undergrowth_nodes()
		if ns.size() < 2:
			leaves_ok = false
			continue
		checked_forest_ug += 1
		if not ns[0].is_visible_in_tree() or ns[1].is_visible_in_tree():
			leaves_ok = false

	# Isolate ONLY the hero undergrowth bed on pure black for WIND and presence visual checks.
	var hero_br: MultiMeshInstance3D = main.tree.get_node("Branches")
	var hero_lf: MultiMeshInstance3D = main.tree.get_node("Leaves")
	forest.visible = false
	hero_br.multimesh.visible_instance_count = 0
	hero_lf.multimesh.visible_instance_count = 0
	main._set_forest_wind(1.4)
	await _hold(main, hc_eye, hc_rot)
	# Sway is periodic, so one capture 420 ms later can land back near the same phase (it read
	# 0.0014 to 0.014 across identical runs). Take the largest diff over five intervals.
	var w_on_a := _capture()
	var wind_on_diff := 0.0
	Engine.time_scale = 2.0
	for k in 5:
		var wt0 := Time.get_ticks_msec()
		while Time.get_ticks_msec() - wt0 < 150:
			await process_frame
		wind_on_diff = maxf(wind_on_diff, _diff(w_on_a, _capture()))
	Engine.time_scale = 1.0

	main._set_forest_wind(0.0)
	for i in 6:
		await process_frame
	var w_off_a := _capture()
	Engine.time_scale = 2.0
	var wt1 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - wt1 < 420:
		await process_frame
	Engine.time_scale = 1.0
	var w_off_b := _capture()
	var wind_off_diff := _diff(w_off_a, w_off_b)

	# Shader presence check on isolated hero bed: 1.0 visible, 0.5 smaller, 0.0 completely gone.
	var h_ug: Array = main.tree.undergrowth_nodes()
	h_ug[0].set_instance_shader_parameter(&"undergrowth_presence", 1.0)
	h_ug[1].set_instance_shader_parameter(&"undergrowth_presence", 1.0)
	for i in 4:
		await process_frame
	var p_full := _capture()
	h_ug[0].set_instance_shader_parameter(&"undergrowth_presence", 0.5)
	h_ug[1].set_instance_shader_parameter(&"undergrowth_presence", 0.5)
	for i in 4:
		await process_frame
	var p_mid := _capture()
	h_ug[0].set_instance_shader_parameter(&"undergrowth_presence", 0.0)
	h_ug[1].set_instance_shader_parameter(&"undergrowth_presence", 0.0)
	for i in 4:
		await process_frame
	var p_zero := _capture()
	h_ug[0].set_instance_shader_parameter(&"undergrowth_presence", 1.0)
	h_ug[1].set_instance_shader_parameter(&"undergrowth_presence", 1.0)
	var p_full_luma := _mean_luma(p_full)
	var p_mid_luma := _mean_luma(p_mid)
	var p_zero_luma := _mean_luma(p_zero)
	hero_br.multimesh.visible_instance_count = -1
	hero_lf.multimesh.visible_instance_count = -1
	forest.visible = true
	main._set_forest_leaves(true)
	main._set_forest_wind(FractalMain.TREE_WIND[main.tree_wind_idx])
	print("UGSHOT controls: leaves_split=%s forest_checked=%d leaves_diff=%.4f bed_wind_on=%.5f bed_wind_off=%.5f presence_luma=%.5f/%.5f/%.5f" % [
		str(leaves_ok), checked_forest_ug, leaves_diff, wind_on_diff, wind_off_diff,
		p_full_luma, p_mid_luma, p_zero_luma])
	if not leaves_ok or checked_forest_ug < 2 or leaves_diff < 0.001:
		_bad.append("LEAVES off check failed: ok=%s forest=%d diff=%.4f" % [
			str(leaves_ok), checked_forest_ug, leaves_diff])
	if wind_on_diff < 0.0015 or wind_off_diff > 0.0005:
		_bad.append("WIND bed control/still failed: on_diff=%.5f off_diff=%.5f" % [wind_on_diff, wind_off_diff])
	if p_full_luma < 0.005 or p_zero_luma > 0.0003 or p_mid_luma <= p_zero_luma + 0.001 or p_mid_luma >= p_full_luma:
		_bad.append("N1 shader presence visual failed: full=%.5f mid=%.5f zero=%.5f" % [
			p_full_luma, p_mid_luma, p_zero_luma])

	# N1: GROVE succession presence ease (no frame jump in effective drawn stems, revoked
	# withering holder stays drawn and counted while easing out, sticky bonus protects living
	# holders from a nearer sprout, replacement eases in smoothly).
	# M1 (round 4): a budget tier change eases the LOD 0-only plants and swaps the MultiMesh only
	# once they are folded away, one governor step down and back up.
	await _check_budget_tier_ease(main, forest, grove_eye, grove_rot)
	await _check_grove_succession_ease(main, forest, grove_eye)
	if OS.get_environment("UG_ONLY") == "grove":
		print("UGSHOT summary_cost grove=%s" % g_cost)
		_finish()
		return

	# --- 3. Avenue standing, path clearance, H1b sticky hysteresis, LOD 0 fold, fade, cost --
	var av_eye := Vector3(0.0, 1.6, 0.0)
	var av_rot := Vector3(-11.0, 0.0, 0.0)
	await _hold(main, av_eye, av_rot)
	main._sow_avenue(false)
	await _grow_all(main, forest, false)
	forest.apply_lod(av_eye)
	await _settle_ug(forest, av_eye)
	for i in 8:
		await process_frame

	main._set_tree_undergrowth(true)
	forest.apply_lod(av_eye)
	await _settle_ug(forest, av_eye)
	await _hold(main, av_eye, av_rot)
	var a_on := _capture()
	a_on.save_png("res://.spike-out/ug_avenue_stand.png")
	var a_prims_on := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
	var a_ug_trees := _visible_ug_count(main, forest)

	var min_clear := INF
	for t in forest.trees():
		var nodes := t.undergrowth_nodes()
		if nodes.is_empty() or not nodes[0].is_visible_in_tree():
			continue
		var reach := nodes[0].transform.basis.get_scale().x * TreeUndergrowth.MAX_RADIUS * t.transform.basis.get_scale().x
		min_clear = minf(min_clear, absf(t.position.x) - reach)
	print("UGSHOT avenue path clearance: %.2f m half-width (%.2f m clear path)" % [min_clear, 2.0 * min_clear])
	if min_clear < 1.0:
		_bad.append("avenue undergrowth encroaches on path (half-width %.2f m)" % min_clear)

	# H1 residual + N3: LOD 0-only fold (invisible swap at 7.8 and 9.0 m, visible diff at 3.2 m)
	# and avenue fade distances (visible at 9.5 and 12.0 m, fully folded at 14.05 m inside far cut).
	var probe_t := _nearest_avenue_tree(av_eye, forest)
	if probe_t != null:
		await _check_lod0_fold_and_fade(main, forest, probe_t)

	# H1b (AVENUE): sticky allocation under repeated +/- 0.40 m sway oscillations + LOD 0/1 and
	# 14.2/15.2 m far-cut deadband ladder.
	var sway_pts := [Vector3(0.40, 0.0, 0.0), Vector3(-0.40, 0.0, 0.0), Vector3(0.0, 0.0, 0.40),
		Vector3(0.0, 0.0, -0.40), Vector3.ZERO]
	for off in sway_pts:
		forest.apply_lod(av_eye + off)
	var settled_map := _ug_lod_map(forest)
	var av_sway_flips := 0
	for off in sway_pts:
		forest.apply_lod(av_eye + off)
		var cur_map := _ug_lod_map(forest)
		av_sway_flips += _count_lod_diffs(settled_map, cur_map)
		settled_map = cur_map
	var hyst_ok := probe_t != null
	if probe_t != null:
		var tp := probe_t.global_position
		var mid_d := (Forest.UNDERGROWTH_LOD0_IN + Forest.UNDERGROWTH_LOD0_OUT) * 0.5
		var mid_far := (Forest.UNDERGROWTH_FAR_IN + Forest.UNDERGROWTH_FAR_OUT) * 0.5
		forest.apply_lod(tp + Vector3(0.0, 1.6, 4.2))
		var l_in := probe_t.undergrowth_lod
		forest.apply_lod(tp + Vector3(0.0, 1.6, sqrt(maxf(mid_d * mid_d - 1.6 * 1.6, 0.1))))
		var l_hold0 := probe_t.undergrowth_lod
		forest.apply_lod(tp + Vector3(0.0, 1.6, 9.6))
		var l_out := probe_t.undergrowth_lod
		forest.apply_lod(tp + Vector3(0.0, 1.6, sqrt(maxf(mid_d * mid_d - 1.6 * 1.6, 0.1))))
		var l_hold1 := probe_t.undergrowth_lod
		forest.apply_lod(tp + Vector3(0.0, 1.6, sqrt(maxf(mid_far * mid_far - 1.6 * 1.6, 0.1))))
		var l_hold_far := probe_t.undergrowth_lod
		forest.apply_lod(tp + Vector3(0.0, 1.6, 15.8))
		var l_far := probe_t.undergrowth_lod
		forest.apply_lod(tp + Vector3(0.0, 1.6, sqrt(maxf(mid_far * mid_far - 1.6 * 1.6, 0.1))))
		var l_stay_off := probe_t.undergrowth_lod
		hyst_ok = l_in == 0 and l_hold0 == 0 and l_out == 1 and l_hold1 == 1 \
			and l_hold_far == 1 and l_far == -1 and l_stay_off == -1
		print("UGSHOT avenue_hysteresis: sway_flips=%d ladder=%d->%d->%d->%d->%d->%d->%d ok=%s" % [
			av_sway_flips, l_in, l_hold0, l_out, l_hold1, l_hold_far, l_far, l_stay_off, str(hyst_ok)])
	if av_sway_flips != 0 or not hyst_ok:
		_bad.append("H1 avenue hysteresis failed: sway_flips=%d hyst_ok=%s" % [av_sway_flips, str(hyst_ok)])
	forest.apply_lod(av_eye)
	await _settle_ug(forest, av_eye)

	main._set_tree_undergrowth(false)
	forest.apply_lod(av_eye)
	await _hold(main, av_eye, av_rot)
	var a_off := _capture()
	a_off.save_png("res://.spike-out/ug_avenue_off.png")
	var a_prims_off := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
	var a_diff := _diff(a_on, a_off)
	print("UGSHOT avenue drawn: trees=%d prims %d->%d (+%d) diff=%.4f" % [
		a_ug_trees, a_prims_off, a_prims_on, a_prims_on - a_prims_off, a_diff])
	if a_ug_trees < 4 or a_prims_on <= a_prims_off or a_diff < 0.004:
		_bad.append("avenue undergrowth not drawn: trees=%d dprims=%d diff=%.4f" % [
			a_ug_trees, a_prims_on - a_prims_off, a_diff])

	var a_cost := await _cost_pair(main, forest, "avenue_30", av_eye, av_rot)

	main._set_tree_undergrowth(true)
	main._set_tree_floor(3)
	main._set_tree_bark(1)
	forest.apply_lod(av_eye)
	await _settle_ug(forest, av_eye)
	await _hold(main, av_eye, av_rot)
	_capture().save_png("res://.spike-out/ug_avenue_forest.png")
	var near_t := _nearest_avenue_tree(av_eye, forest)
	if near_t != null:
		var tp := near_t.global_position
		var side_sign := 1.0 if tp.x < 0.0 else -1.0
		var ac_eye := tp + Vector3(side_sign * 1.55, 0.68, 1.25)
		var ac_rot := _look(ac_eye, tp + Vector3(0.0, 0.24, 0.0))
		await _hold(main, ac_eye, ac_rot)
		_capture().save_png("res://.spike-out/ug_avenue_closeup.png")
		# Macro botanical view right beside the bed showing ferns, bush, fungi, moss and sedge.
		var mc_eye := tp + Vector3(side_sign * 0.90, 0.40, 0.80)
		var mc_rot := _look(mc_eye, tp + Vector3(0.0, 0.18, 0.0))
		await _hold(main, mc_eye, mc_rot)
		_capture().save_png("res://.spike-out/ug_plants_macro.png")
	main._set_tree_floor(0)
	main._set_tree_bark(0)
	await _hold(main, av_eye, av_rot)

	# --- 4. WALK stretch: M3 (skip withering, bed count over time, fade inside budget) & L1 -
	main._toggle_walk()
	await _grow_all(main, forest, false, true)
	forest.apply_lod(av_eye)
	var b0 := forest.builds
	var r0 := forest.recycles
	_key(KEY_G, true)
	Engine.time_scale = SPEED * 2.0
	var walk_frames := 0
	var w0 := forest.walked
	var walk_waiting_lod_leak := 0
	var walk_wither_leak := 0
	var walk_min_beds := 1 << 30
	var walk_max_beds := 0
	var walk_nearest_denied := INF
	var walk_samples := 0
	var prev_lod_next := false
	while forest.recycles - r0 < 10 and walk_frames < 3000:
		prev_lod_next = forest._lod_next
		await process_frame
		if not forest.walk_held:
			_key(KEY_G, true)
		walk_frames += 1
		# L1 checked on EVERY frame (even between LOD passes): waiting/recycled trees must never
		# keep an old undergrowth LOD or visible node.
		for t in forest.trees():
			if t.grow_t <= 0.0:
				var ns := t.undergrowth_nodes()
				var vis_leak := not ns.is_empty() and (ns[0].is_visible_in_tree() or ns[1].is_visible_in_tree())
				if t.undergrowth_lod >= 0 or vis_leak:
					walk_waiting_lod_leak += 1
		# Sample right after each LOD pass runs (prev_lod_next was true -> _lod_items ran this frame).
		if prev_lod_next:
			walk_samples += 1
			var beds_now := forest.undergrowth_drawn
			walk_min_beds = mini(walk_min_beds, beds_now)
			walk_max_beds = maxi(walk_max_beds, beds_now)
			for t in forest.trees():
				if t.grow_rate < 0.0 and t.undergrowth_lod >= 0:
					walk_wither_leak += 1
				if t.built and not t.far and t.grow_t > 0.0 and t.grow_rate > 0.0 and t.undergrowth_lod == -1:
					walk_nearest_denied = minf(walk_nearest_denied, av_eye.distance_to(t.global_position))
	_key(KEY_G, false)
	Engine.time_scale = 1.0
	for i in 45:
		await process_frame
	forest.apply_lod(av_eye)
	for i in 10:
		await process_frame
	var walk_builds := forest.builds - b0
	var walk_recycles := forest.recycles - r0
	var walk_ug_vis := _visible_ug_count(main, forest)
	var walk_off_trunk := 0.0
	var l1_probe: FractalTree = null
	for t in forest.trees():
		var nodes := t.undergrowth_nodes()
		if not nodes.is_empty() and nodes[0].is_visible_in_tree():
			walk_off_trunk = maxf(walk_off_trunk, nodes[0].position.length())
			if l1_probe == null:
				l1_probe = t
	# Direct L1 check: a live-bed tree whose grow_t drops to <= 0 before an LOD pass must have
	# its undergrowth_lod cleared by _lod_items (so it cannot sprout at 25 m carrying an old bed).
	var l1_lod_ok := false
	if l1_probe != null:
		var saved_gt := l1_probe.grow_t
		l1_probe.grow_t = 0.0
		forest.apply_lod(av_eye)
		l1_lod_ok = l1_probe.undergrowth_lod == -1
		l1_probe.grow_t = saved_gt
		forest.apply_lod(av_eye)
	print("UGSHOT walk: walked=%.1fm recycles=%d builds=%d samples=%d beds=%d..%d wait_leak=%d wither_leak=%d l1_clear=%s near_denied=%.2fm off_trunk=%.4f" % [
		forest.walked - w0, walk_recycles, walk_builds, walk_samples,
		walk_min_beds if walk_samples > 0 else 0, walk_max_beds,
		walk_waiting_lod_leak, walk_wither_leak, str(l1_lod_ok),
		walk_nearest_denied if walk_nearest_denied < INF else 99.0, walk_off_trunk])
	if walk_recycles < 8 or walk_builds != 0 or walk_ug_vis < 4 or walk_samples < 3 \
			or walk_min_beds < 2 or walk_waiting_lod_leak > 0 or walk_wither_leak > 0 \
			or not l1_lod_ok or walk_nearest_denied < 14.0 or walk_off_trunk > 1e-3:
		_bad.append("WALK undergrowth failed: rec=%d bld=%d samples=%d min_beds=%d wait=%d wither=%d l1=%s denied=%.2f off=%.3f" % [
			walk_recycles, walk_builds, walk_samples, walk_min_beds, walk_waiting_lod_leak,
			walk_wither_leak, str(l1_lod_ok), walk_nearest_denied, walk_off_trunk])
	main._toggle_walk()
	await process_frame

	# --- 5. COUNT 60, COUNT 250 and COUNT 500 (LOD 1 floor + far tier) ----------------------
	var a60_cost := await _measure_count_step(main, forest, 1, "avenue_60", av_eye, av_rot, 4)
	var a250_cost := await _measure_count_step(main, forest, 3, "avenue_250", av_eye, av_rot, 3)

	forest.set_count(Forest.STEPS.size() - 1)
	main._sow_avenue(false)
	await process_frame
	while forest.sowing():
		await process_frame
	await _grow_all(main, forest, false)
	forest.apply_lod(av_eye)
	await _settle_ug(forest, av_eye)
	for i in 8:
		await process_frame
	var near_ug := forest.undergrowth_drawn
	var c500_vis := forest.visible_cost
	var c500_bud := forest.budget
	# M3: the floor at COUNT 500 one and two governor steps down (x0.85, x0.72).
	var c500_steps: Array = []
	for f: float in [0.85, 0.72]:
		var sb := int(float(c500_bud) * f)
		forest.budget = sb
		forest.apply_lod(av_eye)
		await _settle_ug(forest, av_eye, sb)
		var sl1 := 0
		for t in forest.trees():
			if t.undergrowth_lod == 1:
				sl1 += 1
		c500_steps.append([sb, forest.undergrowth_drawn, sl1, forest.visible_cost])
	forest.budget = c500_bud
	forest.apply_lod(av_eye)
	await _settle_ug(forest, av_eye, c500_bud)
	print("UGSHOT count_500_steps: x0.85 budget=%d beds=%d (lod1=%d) visible=%d; x0.72 budget=%d beds=%d (lod1=%d) visible=%d" % [
		c500_steps[0][0], c500_steps[0][1], c500_steps[0][2], c500_steps[0][3],
		c500_steps[1][0], c500_steps[1][1], c500_steps[1][2], c500_steps[1][3]])
	if int(c500_steps[0][1]) < 2 or int(c500_steps[1][1]) < 2 \
			or int(c500_steps[0][3]) > int(c500_steps[0][0]) or int(c500_steps[1][3]) > int(c500_steps[1][0]):
		_bad.append("M3 COUNT 500 floor under governor steps failed: x0.85 beds=%d vis=%d/%d x0.72 beds=%d vis=%d/%d" % [
			c500_steps[0][1], c500_steps[0][3], c500_steps[0][0], c500_steps[1][1], c500_steps[1][3], c500_steps[1][0]])
	var far_trees := 0
	var far_ug_leak := 0
	var handoff_tree: FractalTree = null
	var handoff_was_vis := false
	for t in forest.trees():
		if not t.far and t.draws_own():
			handoff_tree = t
			break
	if handoff_tree != null:
		# Ensure the candidate is actively drawing undergrowth before _put_far() so the
		# handoff check genuinely tests release() dropping a live undergrowth bed.
		handoff_tree.set_undergrowth_lod(0)
		await process_frame
		var hns := handoff_tree.undergrowth_nodes()
		handoff_was_vis = not hns.is_empty() and hns[0].is_visible_in_tree()
		handoff_tree.tier_far = true
		forest._put_far(handoff_tree, handoff_tree.shape_data)
		await process_frame
	for t in forest.trees():
		if t.far:
			far_trees += 1
			for n in t.undergrowth_nodes():
				if n.is_visible_in_tree():
					far_ug_leak += 1
	var handoff_dropped := handoff_tree != null and handoff_was_vis \
		and handoff_tree.undergrowth_lod == -1 and handoff_tree.undergrowth_drawn_lod == -1 \
		and far_ug_leak == 0
	print("UGSHOT far_tier (COUNT 500): far_trees=%d far_ug_leak=%d handoff_vis=%s dropped=%s near_ug=%d (floor>=3 cap %d) visible=%d budget=%d" % [
		far_trees, far_ug_leak, str(handoff_was_vis), str(handoff_dropped), near_ug,
		Forest.UNDERGROWTH_NEAR, c500_vis, c500_bud])
	if far_trees < 200 or not handoff_dropped or far_ug_leak > 0 \
			or near_ug < 3 or near_ug > Forest.UNDERGROWTH_NEAR or c500_vis > c500_bud:
		_bad.append("far_tier/floor check failed: far=%d leak=%d handoff=%s near_ug=%d vis=%d bud=%d" % [
			far_trees, far_ug_leak, str(handoff_dropped), near_ug, c500_vis, c500_bud])
	var a500_cost := await _cost_pair(main, forest, "avenue_500", av_eye, av_rot)
	forest.set_count(0)

	# --- 6. CLEAR & mode change (M4 fixed: snapshot pre-clear nodes + walk scene subtree) ---
	main._set_tree_undergrowth(true)
	main._sow_grove()
	await _grow_all(main, forest, true)
	forest.apply_lod(grove_eye)
	await _settle_ug(forest, grove_eye)
	for i in 5:
		await process_frame
	var pre_clear_nodes: Array[Node] = []
	for t in forest.trees():
		for n in t.undergrowth_nodes():
			if n.is_visible_in_tree():
				pre_clear_nodes.append(n)
	main._clear_forest()
	for i in 5:
		await process_frame
	var after_clear_snap := 0
	for n in pre_clear_nodes:
		if is_instance_valid(n) and (n as Node3D).is_visible_in_tree():
			after_clear_snap += 1
	var after_clear_tree := _count_visible_ug_in_subtree(forest)
	print("UGSHOT clear: pre_nodes=%d forest_trees=%d drawn=%d snap_leak=%d subtree_leak=%d" % [
		pre_clear_nodes.size(), forest.tree_count(), forest.undergrowth_drawn,
		after_clear_snap, after_clear_tree])
	if pre_clear_nodes.size() < 4 or forest.tree_count() != 0 or forest.undergrowth_drawn != 0 \
			or after_clear_snap != 0 or after_clear_tree != 0:
		_bad.append("CLEAR check failed: pre=%d trees=%d drawn=%d snap=%d sub=%d" % [
			pre_clear_nodes.size(), forest.tree_count(), forest.undergrowth_drawn,
			after_clear_snap, after_clear_tree])

	main._sow_grove()
	await _grow_all(main, forest, true)
	forest.apply_lod(grove_eye)
	await _settle_ug(forest, grove_eye)
	main._set_mode("flame")
	for i in 5:
		await process_frame
	var mode_leak := _count_visible_ug_in_subtree(main.cloud)
	main._set_mode("tree")
	await _grow_all(main, forest, true)
	forest.apply_lod(grove_eye)
	await _settle_ug(forest, grove_eye)
	for i in 4:
		await process_frame
	var mode_restored := _visible_ug_count(main, forest)
	print("UGSHOT mode_change: flame_leak=%d tree_restored=%d" % [mode_leak, mode_restored])
	if mode_leak != 0 or mode_restored < 3:
		_bad.append("mode switch failed: flame_leak=%d restored=%d" % [mode_leak, mode_restored])

	print("UGSHOT summary_cost grove=%s avenue_30=%s avenue_60=%s avenue_250=%s avenue_500=%s" % [
		g_cost, a_cost, a60_cost, a250_cost, a500_cost])
	_finish()


func _finish() -> void:
	for b in _bad:
		print("UGSHOT problem: ", b)
	var ok := _bad.is_empty()
	print("UGSHOT %s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)


func _check_library() -> void:
	var plants := ["bush", "fern", "tuft", "fungi", "moss"]
	var min_s0 := 1 << 30
	var max_s0 := 0
	var min_l0 := 1 << 30
	var max_s1 := 0
	var max_r := 0.0
	var min_y := INF
	var lod_ok := true
	var plants_ok := true
	var subset_ok := true
	var flag_ok := true
	var v0_counts := {}
	for v in TreeUndergrowth.VARIANTS:
		var e0 := TreeUndergrowth.entry(v, 0)
		var e1 := TreeUndergrowth.entry(v, 1)
		if v == 0:
			v0_counts = e0["counts"]
		var c0 := TreeUndergrowth.cost(v, 0, true)
		var c1 := TreeUndergrowth.cost(v, 1, true)
		lod_ok = lod_ok and c1 > 0 and c1 < c0
		min_s0 = mini(min_s0, int(e0["n_s"]))
		max_s0 = maxi(max_s0, int(e0["n_s"]))
		min_l0 = mini(min_l0, int(e0["n_l"]))
		max_s1 = maxi(max_s1, int(e1["n_s"]))
		var cts0: Dictionary = e0["counts"]
		var cts1: Dictionary = e1["counts"]
		for p in plants:
			if int(cts0.get(p, 0)) <= 0 or int(cts1.get(p, 0)) <= 0:
				plants_ok = false
		var smm0: MultiMesh = e0["stems"]
		var smm1: MultiMesh = e1["stems"]
		var sbuf0 := smm0.buffer
		var sbuf1 := smm1.buffer
		subset_ok = subset_ok and _is_ordered_subset(sbuf0, smm0.instance_count, sbuf1, smm1.instance_count)
		var lmm0: MultiMesh = e0["leaves"]
		var lmm1: MultiMesh = e1["leaves"]
		var lbuf0 := lmm0.buffer
		var lbuf1 := lmm1.buffer
		subset_ok = subset_ok and _is_ordered_subset(lbuf0, lmm0.instance_count, lbuf1, lmm1.instance_count)
		var s_keep := 0
		for i in smm0.instance_count:
			var o := i * TreeUndergrowth.STRIDE
			if sbuf0[o + 15] > 0.5:
				s_keep += 1
			var origin := Vector3(sbuf0[o + 3], sbuf0[o + 7], sbuf0[o + 11])
			var yv := Vector3(sbuf0[o + 1], sbuf0[o + 5], sbuf0[o + 9])
			var base := origin - yv * 0.5
			var tip := origin + yv * 0.5
			max_r = maxf(max_r, maxf(Vector2(base.x, base.z).length(), Vector2(tip.x, tip.z).length()))
			min_y = minf(min_y, minf(base.y, tip.y))
		var l_keep := 0
		for i in lmm0.instance_count:
			if lbuf0[i * TreeUndergrowth.STRIDE + 15] > 0.5:
				l_keep += 1
		flag_ok = flag_ok and s_keep == smm1.instance_count and smm0.instance_count > smm1.instance_count \
			and l_keep == lmm1.instance_count and lmm0.instance_count > lmm1.instance_count
		for i in smm1.instance_count:
			if sbuf1[i * TreeUndergrowth.STRIDE + 15] <= 0.5:
				flag_ok = false
		for i in lmm1.instance_count:
			if lbuf1[i * TreeUndergrowth.STRIDE + 15] <= 0.5:
				flag_ok = false
	print("UGSHOT library: variants=%d stems=%d..%d lod1<=%d leaves>=%d max_r=%.3f min_y=%.4f lod_step=%s subset=%s flag=%s all_plants=%s v0=%s" % [
		TreeUndergrowth.VARIANTS, min_s0, max_s0, max_s1, min_l0, max_r, min_y,
		str(lod_ok), str(subset_ok), str(flag_ok), str(plants_ok), str(v0_counts)])
	if min_s0 <= 0 or min_l0 <= 0 or not lod_ok or not subset_ok or not flag_ok or not plants_ok \
			or max_r > TreeUndergrowth.MAX_RADIUS + 0.01 or min_y < -0.005:
		_bad.append("library geometry/subset/flag check failed: stems=%d leaves=%d subset=%s flag=%s max_r=%.3f min_y=%.4f" % [
			min_s0, min_l0, str(subset_ok), str(flag_ok), max_r, min_y])


func _check_grove_succession_ease(main, forest: Forest, grove_eye: Vector3) -> void:
	main._set_tree_undergrowth(true)
	forest.apply_lod(grove_eye)
	await _settle_ug(forest, grove_eye)
	var orig_holders: Array[FractalTree] = []
	for t in forest.trees():
		if t.undergrowth_lod >= 0 and t.undergrowth_presence >= 0.99:
			orig_holders.append(t)
	if orig_holders.size() < 2:
		_bad.append("N1 succession setup failed: only %d grove holders" % orig_holders.size())
		return
	var wither_t: FractalTree = orig_holders[0]
	var stay_holders: Array[FractalTree] = orig_holders.slice(1)
	# Place a nearer living sprout in the grove ring (clear of stay_holders) to verify sticky
	# bonus protects living holders and a living replacement eases in smoothly once wither_t clears.
	var wl := forest.to_local(wither_t.global_position)
	var w_spot := Vector2(wl.x, wl.z)
	var sprout_spot := w_spot.normalized() * 0.78
	for h in stay_holders:
		var hl := forest.to_local(h.global_position)
		if sprout_spot.distance_to(Vector2(hl.x, hl.z)) < Forest.UNDERGROWTH_GROVE_SPACING + 0.04:
			sprout_spot = w_spot
			break
	var sprout := forest._grove_tree("oak", sprout_spot)
	sprout.target_height = 1.65
	sprout.branch_cap = 600
	sprout.build()
	sprout.grow_t = 3.5
	sprout.grow_rate = 1.0
	# Snapshot initial effective drawn stems for every tree.
	var prev_eff := {}
	var prev_stems := {}
	var prev_p := {}
	for t in forest.trees():
		var st := _tree_active_stems_and_p(t)
		prev_stems[t] = int(st[0])
		prev_p[t] = float(st[1])
		prev_eff[t] = float(st[2])
	# Trigger succession: wither one holder, then run real frames and inspect every frame.
	wither_t.grow_t = wither_t.grow_s + 1.0
	wither_t.grow_rate = Forest.WITHER_RATE
	forest.apply_lod(grove_eye)
	var max_eff_jump := 0.0
	var max_toggle_p := 0.0
	var fade_out_frames := 0
	var fade_in_frames := 0
	var fading_passes := 0
	var fading_counted := 0
	var count_note := ""
	var wither_cleared := false
	var new_bed_full := false
	var stay_lost := 0
	var orig_set := {}
	for h in orig_holders:
		orig_set[h] = true
	Engine.time_scale = 1.0
	var t0_ms := Time.get_ticks_msec()
	var last_lod_ms := t0_ms
	var fr := 0
	while Time.get_ticks_msec() - t0_ms < 3200 and fr < 2000:
		await process_frame
		fr += 1
		var now_ms := Time.get_ticks_msec()
		var did_lod := false
		if now_ms - last_lod_ms >= 120:
			forest.apply_lod(grove_eye)
			last_lod_ms = now_ms
			did_lod = true
		if is_instance_valid(wither_t):
			var wst := _tree_active_stems_and_p(wither_t)
			var ws := int(wst[0])
			var wp := float(wst[1])
			if wither_t.undergrowth_lod == -1 and ws > 0 and wp > 0.12 and wp < 0.88:
				fade_out_frames += 1
				# Right after a pass, the forest's totals must equal what the trees draw, fading
				# bed included. A replacement bed cannot stand in for it: it is on both sides.
				if did_lod:
					fading_passes += 1
					var idn := _pass_identity(forest)
					if bool(idn[0]):
						fading_counted += 1
					elif count_note == "":
						count_note = str(idn[1])
			if wither_t.undergrowth_drawn_lod == -1 and ws == 0 and wp <= 0.001:
				wither_cleared = true
		for h in stay_holders:
			if is_instance_valid(h) and h.undergrowth_lod < 0:
				stay_lost += 1
		for t in forest.trees():
			var st := _tree_active_stems_and_p(t)
			var s_now := int(st[0])
			var p_now := float(st[1])
			var e_now := float(st[2])
			var e_old := float(prev_eff.get(t, 0.0))
			var s_old := int(prev_stems.get(t, 0))
			var p_old := float(prev_p.get(t, 0.0))
			max_eff_jump = maxf(max_eff_jump, absf(e_now - e_old))
			if (s_old == 0) != (s_now == 0):
				max_toggle_p = maxf(max_toggle_p, p_now if s_now > 0 else p_old)
			prev_stems[t] = s_now
			prev_p[t] = p_now
			prev_eff[t] = e_now
			if not orig_set.has(t) and t.undergrowth_lod >= 0 and s_now > 0:
				if p_now > 0.12 and p_now < 0.88:
					fade_in_frames += 1
				if p_now >= 0.99:
					new_bed_full = true
		if wither_cleared and new_bed_full and now_ms - t0_ms > 500:
			break
	var counted_while_fading := fading_passes > 0 and fading_counted == fading_passes
	print("UGSHOT grove_succession: max_eff_jump=%.1f max_toggle_p=%.3f fade_out_fr=%d fade_in_fr=%d counted_fading=%s (%d/%d passes%s) cleared=%s new_full=%s stay_lost=%d" % [
		max_eff_jump, max_toggle_p, fade_out_frames, fade_in_frames,
		str(counted_while_fading), fading_counted, fading_passes,
		"" if count_note == "" else ", first miss " + count_note,
		str(wither_cleared), str(new_bed_full), stay_lost])
	if max_eff_jump > 160.0 or max_toggle_p > 0.15 or fade_out_frames < 3 or fade_in_frames < 3 \
			or not counted_while_fading or not wither_cleared or not new_bed_full or stay_lost > 0:
		_bad.append("N1 grove succession ease failed: jump=%.1f toggle_p=%.3f out=%d in=%d counted=%s cleared=%s new=%s stay_lost=%d" % [
			max_eff_jump, max_toggle_p, fade_out_frames, fade_in_frames,
			str(counted_while_fading), str(wither_cleared), str(new_bed_full), stay_lost])


## M1 (round 4): find the budget below which a grove bed loses LOD 0, settle just above it,
## drop one governor step (x0.85) and come back up, running real frames through both. On every
## frame the effective drawn stems (bound MultiMesh, fed presence and LOD 0 weight) and the frame
## luma must move by at most 30% of their whole change, and each bed must swap its MultiMesh
## exactly once, while its LOD 0-only plants are folded away.
func _check_budget_tier_ease(main, forest: Forest, grove_eye: Vector3, grove_rot: Vector3) -> void:
	var saved_wind: float = FractalMain.TREE_WIND[main.tree_wind_idx]
	var saved_motes := forest.motes_on
	var bud_save := forest.budget
	main._set_forest_wind(0.0)
	forest.set_motes_on(false)
	main._set_tree_undergrowth(true)
	forest.budget = Forest.BUDGET_START
	forest.apply_lod(grove_eye)
	await _settle_ug(forest, grove_eye, Forest.BUDGET_START)
	var holders: Array[FractalTree] = []
	for t in forest.trees():
		if t.undergrowth_lod == 0:
			holders.append(t)
	var edge := Forest.BUDGET_START
	var b := Forest.BUDGET_START
	while b > Forest.BUDGET_MIN + 50:
		b -= 50
		forest.budget = b
		forest.apply_lod(grove_eye)
		var held := true
		for t in holders:
			if t.undergrowth_lod != 0:
				held = false
				break
		if not held:
			break
		edge = b
	var hi := edge + Forest.UNDERGROWTH_BUDGET_HYST + 200
	var lo := int(float(hi) * 0.85)
	forest.budget = hi
	forest.apply_lod(grove_eye)
	await _settle_ug(forest, grove_eye, hi)
	var at_hi := 0
	for t in holders:
		if t.undergrowth_lod == 0 and t.undergrowth_drawn_lod == 0 and t.undergrowth_lod0 >= 0.999:
			at_hi += 1
	main.xr_camera.position = grove_eye
	main.xr_camera.rotation_degrees = grove_rot
	await _pinned_frames(forest, 16, hi)
	var down := await _tier_run(forest, grove_eye, lo, holders, 1)
	var up := await _tier_run(forest, grove_eye, hi, holders, 0)
	forest.budget = bud_save
	forest.apply_lod(grove_eye)
	await _settle_ug(forest, grove_eye)
	main._set_forest_wind(saved_wind)
	forest.set_motes_on(saved_motes)
	var bad := ""
	if holders.size() < 2 or at_hi != holders.size():
		bad = "setup holders=%d at_hi=%d" % [holders.size(), at_hi]
	for r: Dictionary in [down, up]:
		var n: int = r["moving"]
		if n < 1 or not bool(r["settled"]) or int(r["swaps"]) != n or float(r["swap_w"]) > 0.05 \
				or float(r["de_total"]) < 300.0 * n or float(r["max_de"]) > 0.3 * float(r["de_total"]) \
				or float(r["dl_total"]) < maxf(0.0008, 10.0 * float(r["noise"])) \
				or float(r["max_dl"]) > 0.3 * float(r["dl_total"]) + 2.0 * float(r["noise"]):
			bad += " %s" % r["name"]
		if int(r["id_ok"]) != int(r["id_passes"]) or int(r["id_passes"]) < 2:
			bad += " %s_counted(%d/%d passes, first miss %s)" % [r["name"], r["id_ok"],
				r["id_passes"], r["id_miss"]]
	print("UGSHOT budget_tier: edge=%d hi=%d lo=%d holders=%d | %s | %s" % [
		edge, hi, lo, holders.size(), _tier_line(down), _tier_line(up)])
	if bad != "":
		_bad.append("M1 budget tier ease failed:%s" % bad)


func _tier_line(r: Dictionary) -> String:
	return "%s beds=%d frames=%d settled=%s swaps=%d swap_w=%.3f stems %.0f->%.0f max_step=%.1f (%.0f%%) luma %.5f->%.5f max_step=%.5f (%.0f%%) noise=%.5f counted=%d/%d" % [
		r["name"], r["moving"], r["frames"], str(r["settled"]), r["swaps"], r["swap_w"],
		r["e0"], r["e1"], r["max_de"], 100.0 * float(r["max_de"]) / maxf(float(r["de_total"]), 1e-6),
		r["l0"], r["l1"], r["max_dl"], 100.0 * float(r["max_dl"]) / maxf(float(r["dl_total"]), 1e-9),
		r["noise"], r["id_ok"], r["id_passes"]]


func _tier_run(forest: Forest, eye: Vector3, bud: int, holders: Array[FractalTree], target: int) -> Dictionary:
	var cur_bud := forest.budget
	var prev_l := _mean_luma(_capture())
	var noise := 0.0
	for i in 6:
		await _pinned_frames(forest, 1, cur_bud)
		var nl := _mean_luma(_capture())
		noise = maxf(noise, absf(nl - prev_l))
		prev_l = nl
	var l_start := prev_l
	var e_start := _forest_eff(forest)
	var prev_e := e_start
	var prev_n := {}
	var prev_w := {}
	var was := {}
	for t in holders:
		prev_n[t] = _bound_count(t)
		prev_w[t] = _fed_w(t)
		was[t] = t.undergrowth_lod
	forest.budget = bud
	forest._govern_t = 0.0
	forest.apply_lod(eye)
	# Every pass during the ease must count what the trees draw. A downgrading bed is counted
	# at LOD 0 until its swap (forest.gd step 4), and only this run reaches that path.
	var id_passes := 1
	var id_ok := 0
	var id_miss := ""
	var idn0 := _pass_identity(forest)
	if bool(idn0[0]):
		id_ok += 1
	else:
		id_miss = idn0[1]
	# The beds this budget step moves to the target tier.
	var moving: Array[FractalTree] = []
	for t in holders:
		if t.undergrowth_lod == target and int(was[t]) != target:
			moving.append(t)
	var max_de := 0.0
	var max_dl := 0.0
	var swap_w := 0.0
	var swaps := 0
	var frames := 0
	var after := 0
	var settled := false
	var t0 := Time.get_ticks_msec()
	var last_pass := t0
	while frames < 600 and Time.get_ticks_msec() - t0 < 5000:
		# A swap is checked against the LOD 0 weight drawn on the LOD 0 side of it: the frame
		# before a downgrade swap, the frame after an upgrade swap (apply_lod makes that one).
		for t in moving:
			var n := _bound_count(t)
			var pn := int(prev_n[t])
			if n != pn and n > 0 and pn > 0:
				swaps += 1
				var w_at := float(prev_w[t]) if pn > n else _fed_w(t)
				swap_w = maxf(swap_w, w_at * w_at * (3.0 - 2.0 * w_at))
			prev_n[t] = n
			prev_w[t] = _fed_w(t)
		await _pinned_frames(forest, 1, bud)
		frames += 1
		if Time.get_ticks_msec() - last_pass >= 500:
			forest.apply_lod(eye)
			last_pass = Time.get_ticks_msec()
			id_passes += 1
			var idn := _pass_identity(forest)
			if bool(idn[0]):
				id_ok += 1
			elif id_miss == "":
				id_miss = idn[1]
		var nl := _mean_luma(_capture())
		var ne := _forest_eff(forest)
		max_dl = maxf(max_dl, absf(nl - prev_l))
		max_de = maxf(max_de, absf(ne - prev_e))
		prev_l = nl
		prev_e = ne
		var done := true
		for t in moving:
			if t.undergrowth_drawn_lod != target or (target == 0 and t.undergrowth_lod0 < 0.999):
				done = false
				break
		if done:
			settled = true
			after += 1
			if after >= 6:
				break
	return {"name": "down" if target == 1 else "up", "moving": moving.size(), "frames": frames,
		"settled": settled, "swaps": swaps, "swap_w": swap_w, "e0": e_start, "e1": prev_e,
		"de_total": absf(prev_e - e_start), "max_de": max_de, "l0": l_start, "l1": prev_l,
		"dl_total": absf(prev_l - l_start), "max_dl": max_dl, "noise": noise,
		"id_passes": id_passes, "id_ok": id_ok, "id_miss": id_miss}


func _pinned_frames(forest: Forest, n: int, bud: int) -> void:
	for i in n:
		forest.budget = bud
		forest._govern_t = 0.0
		await process_frame


func _bound_count(t: FractalTree) -> int:
	var ns := t.undergrowth_nodes()
	if ns.is_empty() or not ns[0].is_visible_in_tree() or ns[0].multimesh == null:
		return 0
	return ns[0].multimesh.instance_count


func _fed_w(t: FractalTree) -> float:
	var ns := t.undergrowth_nodes()
	if ns.is_empty():
		return 0.0
	var wv: Variant = ns[0].get_instance_shader_parameter(&"undergrowth_lod0")
	return 1.0 if wv == null else clampf(float(wv), 0.0, 1.0)


func _forest_eff(forest: Forest) -> float:
	var sum := 0.0
	for t in forest.trees():
		sum += float(_tree_active_stems_and_p(t)[2])
	return sum


## What the LOD pass reports against what the trees draw: beds, stems and visible cost. The
## pass counts a bed by the tier it draws, so a bed easing out is on both sides or neither.
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


func _check_lod0_fold_and_fade(main, forest: Forest, probe_t: FractalTree) -> void:
	var saved_wind: float = FractalMain.TREE_WIND[main.tree_wind_idx]
	var saved_motes := forest.motes_on
	main._set_forest_wind(0.0)
	forest.set_motes_on(false)
	var tp := probe_t.global_position
	var side_sign := 1.0 if tp.x < 0.0 else -1.0
	var swap_dir := Vector3(side_sign * 0.55, 0.28, 0.78).normalized()

	# 1. LOD 0-only fold: near control (3.2 m < 6.6 m) MUST visibly differ between LOD 0 and LOD 1;
	# across both tier swap thresholds (7.85 m and 9.05 m, both > 7.6 m) LOD 0 vs LOD 1 MUST match.
	var fold_diffs: Array[float] = []
	for dist: float in [3.2, 7.85, 9.05]:
		var eye := tp + swap_dir * dist
		var rot := _look(eye, tp + Vector3(0.0, 0.24, 0.0))
		main.xr_camera.position = eye
		main.xr_camera.rotation_degrees = rot
		forest._govern_t = 0.0
		probe_t.undergrowth_presence = 1.0
		probe_t.undergrowth_lod = 0
		probe_t.undergrowth_drawn_lod = 0
		probe_t.undergrowth_lod0 = 1.0
		probe_t._sync_undergrowth()
		for i in 6:
			forest._govern_t = 0.0
			await process_frame
		var img0 := _capture()
		probe_t.undergrowth_presence = 1.0
		probe_t.undergrowth_lod = 1
		probe_t.undergrowth_drawn_lod = 1
		probe_t.undergrowth_lod0 = 0.0
		probe_t._sync_undergrowth()
		for i in 6:
			forest._govern_t = 0.0
			await process_frame
		var img1 := _capture()
		fold_diffs.append(_diff_center(img0, img1))
	print("UGSHOT lod0_fold: near_3.2m=%.5f swap_7.85m=%.5f swap_9.05m=%.5f" % [
		fold_diffs[0], fold_diffs[1], fold_diffs[2]])
	if fold_diffs[0] < 0.004 or fold_diffs[1] > 0.0003 or fold_diffs[2] > 0.0003:
		_bad.append("H1 lod0_fold failed: near=%.5f swap7.85=%.5f swap9.05=%.5f" % [
			fold_diffs[0], fold_diffs[1], fold_diffs[2]])

	# 2. Avenue fade distances (10.0 to 14.0 m inside 14.2/15.2 m far cut):
	# look down the open path centre (x = 0) at probe_t at exact 3D distances 9.5, 12.0, 14.05 m
	# and toggle ONLY probe_t so the center-crop diff isolates that single bed cleanly.
	var fade_diffs: Array[float] = []
	var fade_lods: Array[int] = []
	for dist: float in [9.5, 12.0, 14.05]:
		var dz := sqrt(maxf(dist * dist - tp.x * tp.x - 1.6 * 1.6, 0.25))
		var eye := Vector3(0.0, 1.6, tp.z + dz)
		var rot := _look(eye, tp + Vector3(0.0, 0.24, 0.0))
		main.xr_camera.position = eye
		main.xr_camera.rotation_degrees = rot
		probe_t.set_undergrowth(true)
		forest.apply_lod(eye)
		await _settle_ug(forest, eye)
		fade_lods.append(probe_t.undergrowth_lod)
		for i in 6:
			forest._govern_t = 0.0
			await process_frame
		var img_on := _capture()
		probe_t.set_undergrowth(false)
		for i in 6:
			forest._govern_t = 0.0
			await process_frame
		var img_off := _capture()
		probe_t.set_undergrowth(true)
		fade_diffs.append(_diff_center(img_on, img_off))
	print("UGSHOT avenue_fade: d9.5m=%.5f(lod=%d) d12.0m=%.5f(lod=%d) d14.05m=%.5f(lod=%d)" % [
		fade_diffs[0], fade_lods[0], fade_diffs[1], fade_lods[1], fade_diffs[2], fade_lods[2]])
	if fade_lods[0] != 1 or fade_lods[1] != 1 or fade_lods[2] != 1 \
			or fade_diffs[0] < 0.0008 or fade_diffs[1] < 0.00012 \
			or fade_diffs[1] >= fade_diffs[0] or fade_diffs[2] > 0.00005:
		_bad.append("N3 avenue_fade failed: d9.5=%.5f(l%d) d12=%.5f(l%d) d14.05=%.5f(l%d)" % [
			fade_diffs[0], fade_lods[0], fade_diffs[1], fade_lods[1], fade_diffs[2], fade_lods[2]])
	main._set_forest_wind(saved_wind)
	forest.set_motes_on(saved_motes)


func _measure_count_step(main, forest: Forest, step_idx: int, label: String,
		av_eye: Vector3, av_rot: Vector3, min_beds: int) -> String:
	forest.set_count(step_idx)
	main._sow_avenue(false)
	await process_frame
	while forest.sowing():
		await process_frame
	await _grow_all(main, forest, false)
	forest.apply_lod(av_eye)
	await _settle_ug(forest, av_eye)
	for i in 8:
		await process_frame
	var l0 := 0
	var l1 := 0
	for t in forest.trees():
		if t.undergrowth_lod == 0:
			l0 += 1
		elif t.undergrowth_lod == 1:
			l1 += 1
	var drawn := forest.undergrowth_drawn
	var vis := forest.visible_cost
	var bud := forest.budget
	print("UGSHOT count_%d: beds=%d (lod0=%d lod1=%d) visible=%d budget=%d" % [
		int(Forest.STEPS[step_idx]["n"]), drawn, l0, l1, vis, bud])
	if drawn < min_beds or vis > bud:
		_bad.append("COUNT %d floor/budget failed: beds=%d vis=%d bud=%d" % [
			int(Forest.STEPS[step_idx]["n"]), drawn, vis, bud])
	return await _cost_pair(main, forest, label, av_eye, av_rot)


func _tree_active_stems_and_p(t: FractalTree) -> Array:
	var ns := t.undergrowth_nodes()
	if ns.is_empty() or not ns[0].is_visible_in_tree() or ns[0].multimesh == null:
		return [0, 0.0, 0.0]
	# Effective stems from what the GPU is given: the bound MultiMesh, and the presence and LOD 0
	# weight it was fed, smoothstepped as the shaders do. Stems past the LOD 1 count are the
	# LOD 0-only ones (LOD 1 is their ordered COLOR.a 1 subset).
	var stems := ns[0].multimesh.instance_count
	var p := clampf(float(ns[0].get_instance_shader_parameter(&"undergrowth_presence")), 0.0, 1.0)
	var wv: Variant = ns[0].get_instance_shader_parameter(&"undergrowth_lod0")
	var w := 1.0 if wv == null else clampf(float(wv), 0.0, 1.0)
	var keep := int(TreeUndergrowth.entry(t.seed_value, 1)["n_s"])
	var sp := p * p * (3.0 - 2.0 * p)
	var sw := w * w * (3.0 - 2.0 * w)
	return [stems, p, sp * (float(mini(stems, keep)) + sw * float(maxi(stems - keep, 0)))]


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


func _is_ordered_subset(buf0: PackedFloat32Array, n0: int, buf1: PackedFloat32Array, n1: int) -> bool:
	var k0 := 0
	for i1 in n1:
		var o1 := i1 * TreeUndergrowth.STRIDE
		var found := false
		while k0 < n0:
			var o0 := k0 * TreeUndergrowth.STRIDE
			k0 += 1
			var ok_row := true
			for f in TreeUndergrowth.STRIDE:
				if absf(buf0[o0 + f] - buf1[o1 + f]) > 1e-5:
					ok_row = false
					break
			if ok_row:
				found = true
				break
		if not found:
			return false
	return true


func _ug_lod_map(forest: Forest) -> Dictionary:
	var out := {}
	for t in forest.trees():
		out[t] = t.undergrowth_lod
	return out


func _tree_lod_map(forest: Forest) -> Dictionary:
	var out := {}
	for t in forest.trees():
		if t.built and not t.far and t.grow_t > 0.0:
			out[t] = t.lod
	return out


func _count_lod_diffs(a: Dictionary, b: Dictionary) -> int:
	var n := 0
	for k in a:
		if int(a[k]) != int(b.get(k, -99)):
			n += 1
	return n


func _count_visible_ug_in_subtree(root_node: Node) -> int:
	var n := 0
	if root_node is MultiMeshInstance3D and (root_node.name == "UndergrowthStems" or root_node.name == "UndergrowthLeaves"):
		if (root_node as Node3D).is_visible_in_tree():
			n += 1
	for c in root_node.get_children():
		n += _count_visible_ug_in_subtree(c)
	return n


func _visible_ug_count(main, forest: Forest) -> int:
	var n := 0
	var hero_nodes: Array = main.tree.undergrowth_nodes()
	if not hero_nodes.is_empty() and hero_nodes[0].is_visible_in_tree():
		n += 1
	for t in forest.trees():
		var nodes := t.undergrowth_nodes()
		if not nodes.is_empty() and nodes[0].is_visible_in_tree():
			n += 1
	return n


func _nearest_avenue_tree(eye: Vector3, forest: Forest) -> FractalTree:
	var best := INF
	var pick: FractalTree = null
	for t in forest.trees():
		if t.row >= 0 and t.draws_own() and t.undergrowth_lod >= 0:
			var d := eye.distance_to(t.global_position)
			if d < best:
				best = d
				pick = t
	return pick


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


func _hold(main, eye: Vector3, rot: Vector3) -> void:
	main.xr_camera.position = eye
	main.xr_camera.rotation_degrees = rot
	for i in 16:
		await process_frame


func _cost_pair(main, forest: Forest, label: String, eye: Vector3, rot: Vector3) -> String:
	if OS.get_environment("UG_FAST") == "1":
		return "skipped (UG_FAST)"
	var off_ms: Array[float] = []
	var on_ms: Array[float] = []
	var prims_off := 0
	var prims_on := 0
	var draws_off := 0
	var draws_on := 0
	for r in ROUNDS:
		main._set_tree_undergrowth(false)
		forest.apply_lod(eye)
		await _hold(main, eye, rot)
		var m0 := await _measure()
		off_ms.append(m0[0])
		prims_off = int(m0[1])
		draws_off = int(m0[2])
		main._set_tree_undergrowth(true)
		forest.apply_lod(eye)
		await _settle_ug(forest, eye)
		await _hold(main, eye, rot)
		var m1 := await _measure()
		on_ms.append(m1[0])
		prims_on = int(m1[1])
		draws_on = int(m1[2])
	off_ms.sort()
	on_ms.sort()
	var g0 := off_ms[off_ms.size() / 2]
	var g1 := on_ms[on_ms.size() / 2]
	var ratio := g1 / maxf(g0, 1e-4)
	var line := "gpu %.3f->%.3fms (%.2fx) draws %d->%d prims %d->%d" % [
		g0, g1, ratio, draws_off, draws_on, prims_off, prims_on]
	print("UGSHOT cost %-12s %s" % [label, line])
	return line


func _measure() -> Array:
	for i in 12:
		await process_frame
	var gpu: Array[float] = []
	var prims := 0.0
	var draws := 0.0
	for i in MEASURE_FRAMES:
		await process_frame
		gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(_vp))
		prims += RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
		draws += RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
	gpu.sort()
	return [gpu[gpu.size() / 2], prims / float(MEASURE_FRAMES), draws / float(MEASURE_FRAMES)]


func _capture() -> Image:
	return root.get_viewport().get_texture().get_image()


func _diff(a: Image, b: Image) -> float:
	var n := 0
	var sum := 0.0
	var step := maxi(1, a.get_width() / 80)
	for y in range(0, a.get_height(), step):
		for x in range(0, a.get_width(), step):
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			sum += (absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)) / 3.0
			n += 1
	return sum / float(maxi(n, 1))


func _diff_center(a: Image, b: Image) -> float:
	var n := 0
	var sum := 0.0
	var w := a.get_width()
	var h := a.get_height()
	var x0 := int(w * 0.35)
	var x1 := int(w * 0.65)
	var y0 := int(h * 0.35)
	var y1 := int(h * 0.65)
	for y in range(y0, y1, 2):
		for x in range(x0, x1, 2):
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			sum += (absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)) / 3.0
			n += 1
	return sum / float(maxi(n, 1))


func _mean_luma(a: Image) -> float:
	var n := 0
	var sum := 0.0
	var step := maxi(1, a.get_width() / 160)
	for y in range(0, a.get_height(), step):
		for x in range(0, a.get_width(), step):
			var c := a.get_pixel(x, y)
			sum += (c.r + c.g + c.b) / 3.0
			n += 1
	return sum / float(maxi(n, 1))


func _look(from: Vector3, to: Vector3) -> Vector3:
	return Basis.looking_at(to - from, Vector3.UP).get_euler() * (180.0 / PI)


func _key(code: Key, down: bool) -> void:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.physical_keycode = code
	ev.pressed = down
	Input.parse_input_event(ev)
