extends SceneTree

## IFS-2's integration proof. It drives the REAL main scene the way forest_shot does: enter
## IFS through the same _set_mode the wrist strip calls, capture what draws, and check the
## things a PNG cannot show. A saved image proves neither the active mode nor that the chaos
## game stopped.
##
## What it asserts, in the order it runs them:
##
##   - IFS mode is really on: the flag, the geometry, a non-zero instance count, and the
##     particle cloud's own draw hidden underneath it.
##   - The cloud stopped iterating. ParticleCloud._frame counts dispatches, so the delta over
##     a run of frames is the measurement; flame mode is the control, because a zero from a
##     counter that never moves is not evidence of anything.
##   - Ambient spin is off, and the trigger neither steps a preset nor plants a tree.
##   - Mode pairs: flame -> ifs -> tree keeps the tree's species, wind, depth and planted
##     trees; bulb -> ifs -> bulb comes back to the same bulb with the marcher put away;
##     ifs -> ground -> ifs keeps the terrain settings and returns to live geometry.
##   - The three IFS tiles do what they say: DETAIL changes the count, DEPTH changes the z
##     extent and not the count, RESET returns both.
##   - IFS-3 sculpting, driven through the real input path: registered XR controller trackers
##     under the names main.tscn already references, so a pose is a pose and a trigger is a
##     trigger. Capture, drag, the second controller being ignored, release, UNDO, and a mode
##     change mid-edit leaving no ownership behind and the snapshot restored.
##   - The SHAPE gallery: the tile and the face buttons step it, a preset change puts the
##     mirrors, the depth and the undo back where a new sculpture starts, and leaves the
##     tabletop pose alone. One capture per preset through the real scene.
##
##   tools/ifs_mode_shot.sh

const OUT := "res://.spike-out/ifs-2026-09-16"
## Frames to sample the cloud's dispatch counter over. Long enough that a slow first frame
## cannot be mistaken for a stopped simulation.
const SAMPLE_FRAMES := 20
## What each preset must draw in the real scene, written here rather than asked of the table,
## so the numbers the standalone harness reports have something to disagree with.
const PRESET_INSTANCES := {
	"FRAMES": 585, "TETRA": 585, "STAR": 1885, "CROSS": 585, "TWIST": 585,
}

var _fails := 0
## The fake controllers. Made in _sculpt and kept alive for _shapes, which banks an edit of its
## own before checking that a preset change throws it away.
var _lt: XRControllerTracker
var _rt: XRControllerTracker


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var scene: PackedScene = load("res://main.tscn")
	if scene == null:
		print("IFSMODE FAIL: main.tscn would not load")
		quit(1)
		return
	var main := scene.instantiate()
	root.add_child(main)
	for i in 40:
		await process_frame
	main.help.close()
	main.xr_camera.position = Vector3(0.0, 1.6, 0.0)
	# Pitched at the tabletop pose, so the capture frames what the viewer would be looking at.
	main.xr_camera.rotation_degrees = Vector3(-19.0, 0.0, 0.0)
	# The card eats the triggers while it fades, and the fade is measured in seconds.
	for i in 40:
		await process_frame

	await _tree_settings(main)
	await _enter_from_flame(main)
	await _tree_pair(main)
	await _bulb_pair(main)
	await _ground_pair(main)
	await _tiles(main)
	await _sculpt(main)
	await _shapes(main)
	if _lt != null:
		XRServer.remove_tracker(_lt)
	if _rt != null:
		XRServer.remove_tracker(_rt)

	print("IFSMODE %s failures=%d dir=%s" % ["PASS" if _fails == 0 else "FAIL", _fails, OUT])
	quit(0 if _fails == 0 else 1)


func _ok(name: String, pass_: bool, detail: String) -> void:
	if not pass_:
		_fails += 1
	print("IFSMODE %-18s %s  %s" % [name, "PASS" if pass_ else "FAIL", detail])


## Choose something in tree mode that IFS must not touch on the way past.
var _tree_want := {}


func _tree_settings(main) -> void:
	main._set_mode("tree")
	for i in 8:
		await process_frame
	main._cycle_tree_shape(1)
	main.tree_wind_idx = 2
	main._set_forest_wind(main.TREE_WIND[main.tree_wind_idx])
	main.tree_depth_idx = 1
	main.tree.depth_delta = main.TREE_DEPTH_DELTA[main.tree_depth_idx]
	main.tree.build()
	main._plant_tree_at(Vector2(-1.2, -0.8))
	for i in 4:
		await process_frame
	_tree_want = {
		"shape": main.tree_shape_idx,
		"wind": main.tree_wind_idx,
		"depth": main.tree_depth_idx,
		"seed": main.tree.seed_value,
		"planted": main._forest_trees.size(),
	}


func _enter_from_flame(main) -> void:
	main._set_mode("flame")
	for i in 10:
		await process_frame
	# Control first. If the flame is not dispatching either, "IFS does not dispatch" says
	# nothing about IFS.
	var flame_dispatches := await _dispatches(main)

	main._set_mode("ifs")
	for i in 10:
		await process_frame
	var on: bool = main.ifs_mode and main.ifs.visible and main.ifs.instance_count > 0 \
		and not main.cloud._mesh_instance.visible
	_ok("ifs mode", on, "flag=%s visible=%s instances=%d triangles=%d cloud drawn=%s" % [
		str(main.ifs_mode), str(main.ifs.visible), main.ifs.instance_count,
		main.ifs.triangle_count, str(main.cloud._mesh_instance.visible)])

	# The tabletop framing, measured rather than eyeballed from a PNG. Width is what the
	# plan specifies; the near face is what decides whether it can be focused on and reached.
	var world_scale: float = main.ifs.global_transform.basis.get_scale().x
	var world_w: float = world_scale * main.ifs.bounds.size.x
	var to_centre: float = main.ifs.global_position.distance_to(main.xr_camera.global_position)
	var near_face: float = to_centre - world_w * 0.5
	_ok("tabletop framing", absf(world_w - main.IFS_WIDTH_M) < 0.02 and near_face > 0.4 \
		and to_centre < 1.1,
		"width %.3f m (want %.2f) centre %.3f m out, near face %.3f m from the eyes" % [
			world_w, main.IFS_WIDTH_M, to_centre, near_face])

	var ifs_dispatches := await _dispatches(main)
	_ok("particles idle", ifs_dispatches == 0 and flame_dispatches > 0,
		"cloud dispatches over %d frames: flame=%d ifs=%d" % [
			SAMPLE_FRAMES, flame_dispatches, ifs_dispatches])

	# Ambient spin is a rotation of the cloud, and the sculpture is its child. A shape about
	# to be edited has to hold still, so the gate must hold even with SPIN on.
	main.spin = true
	var before: Basis = main.cloud.global_transform.basis
	for i in SAMPLE_FRAMES:
		await process_frame
	var drift: float = (main.cloud.global_transform.basis.x - before.x).length()
	_ok("no ambient spin", drift < 1e-6, "SPIN on, basis moved %.9f over %d frames" % [
		drift, SAMPLE_FRAMES])

	# The trigger must not fall through to the flame gallery or the forest. The flame
	# control at the end proves the key actually reaches _handle_input.
	var preset_before: int = main.preset_idx
	var planted_before: int = main._forest_trees.size()
	await _tap(main, KEY_RIGHT)
	await _tap(main, KEY_LEFT)
	var quiet: bool = main.preset_idx == preset_before and main._forest_trees.size() == planted_before

	var img := root.get_viewport().get_texture().get_image()
	var err := img.save_png("%s/mode-ifs.png" % OUT)
	var lit := _lit(img)
	_ok("capture", err == OK and lit > 500, "%s/mode-ifs.png lit=%d err=%d" % [OUT, lit, err])

	main._set_mode("flame")
	for i in 8:
		await process_frame
	var flame_preset: int = main.preset_idx
	await _tap(main, KEY_RIGHT)
	for i in 4:
		await process_frame
	var key_live: bool = main.preset_idx != flame_preset
	_ok("trigger quiet", quiet and key_live,
		"in ifs: preset %d->%d planted %d->%d; flame control stepped=%s" % [
			preset_before, main.preset_idx if not quiet else preset_before,
			planted_before, main._forest_trees.size(), str(key_live)])


func _tree_pair(main) -> void:
	main._set_mode("ifs")
	for i in 6:
		await process_frame
	main._set_mode("tree")
	for i in 8:
		await process_frame
	var kept: bool = main.tree_shape_idx == _tree_want["shape"] \
		and main.tree_wind_idx == _tree_want["wind"] \
		and main.tree_depth_idx == _tree_want["depth"] \
		and main.tree.seed_value == _tree_want["seed"] \
		and main._forest_trees.size() == _tree_want["planted"] \
		and main.tree_mode and not main.ifs_mode and not main.ifs.visible
	_ok("flame-ifs-tree", kept, "species=%d/%d wind=%d/%d depth=%d/%d planted=%d/%d ifs hidden=%s" % [
		main.tree_shape_idx, _tree_want["shape"], main.tree_wind_idx, _tree_want["wind"],
		main.tree_depth_idx, _tree_want["depth"], main._forest_trees.size(),
		_tree_want["planted"], str(not main.ifs.visible)])


## Leaving BULB while the marcher is running is the pair the plan calls out by name: the
## reduced eye buffer and the interior state both belong to that mode and must not follow.
func _bulb_pair(main) -> void:
	main._set_mode("bulb")
	for i in 12:
		await process_frame
	var want_bulb: int = main.bulb_idx
	main.surface_idx = 1
	main._apply_surface()
	for i in 4:
		await process_frame
	var was_marching: bool = main.march.is_on()
	var render_want: int = main._march_render_saved

	main._set_mode("ifs")
	for i in 8:
		await process_frame
	var clean: bool = not main.march.is_on() and not main._inside and main._bulb == null \
		and main.render_idx == render_want and main.ifs_mode
	_ok("bulb-ifs", clean and was_marching,
		"was marching=%s now marching=%s inside=%s source cleared=%s eye idx=%d/%d" % [
			str(was_marching), str(main.march.is_on()), str(main._inside),
			str(main._bulb == null), main.render_idx, render_want])

	main._set_mode("bulb")
	for i in 12:
		await process_frame
	var back: bool = main.bulb_mode and main.bulb_idx == want_bulb and not main.ifs_mode \
		and not main.ifs.visible and main.splat_on
	_ok("bulb-ifs-bulb", back, "bulb=%d/%d mode=%s ifs hidden=%s splats=%s" % [
		main.bulb_idx, want_bulb, str(main.bulb_mode), str(not main.ifs.visible),
		str(main.splat_on)])


func _ground_pair(main) -> void:
	main._set_mode("ifs")
	for i in 6:
		await process_frame
	main._set_mode("ground")
	for i in 8:
		await process_frame
	main.ground_iter_idx = 1
	main.ground.set_max_iter(main.GROUND_ITER[main.ground_iter_idx])
	main.ground_relief_idx = 2
	main.ground_sky_idx = 1
	main.ground_hue = 0.375
	main._apply_ground_look()
	var formula: int = main.ground.formula
	for i in 4:
		await process_frame

	main._set_mode("ifs")
	for i in 8:
		await process_frame
	var ifs_clean: bool = main.ifs_mode and main.ifs.visible and not main.ground_mode \
		and not main.ground.visible
	main._set_mode("ground")
	for i in 8:
		await process_frame
	var kept: bool = main.ground_iter_idx == 1 and main.ground_relief_idx == 2 \
		and main.ground_sky_idx == 1 and is_equal_approx(main.ground_hue, 0.375) \
		and main.ground.formula == formula and main.ground_mode and not main.ifs.visible
	_ok("ifs-ground-ifs", ifs_clean and kept,
		"iter=%d/1 relief=%d/2 sky=%d/1 hue=%.3f/0.375 set=%d/%d ifs clean=%s" % [
			main.ground_iter_idx, main.ground_relief_idx, main.ground_sky_idx, main.ground_hue,
			main.ground.formula, formula, str(ifs_clean)])

	main._set_mode("ifs")
	for i in 8:
		await process_frame
	_ok("ground-ifs", main.ifs_mode and main.ifs.instance_count > 0 and not main.ground.visible,
		"instances=%d ground drawn=%s" % [main.ifs.instance_count, str(main.ground.visible)])


## The three tiles, through the same functions the wrist menu calls.
func _tiles(main) -> void:
	var base: int = main.ifs.instance_count
	var base_z: float = main.ifs.bounds.size.z
	main._step_ifs_detail(1)
	for i in 3:
		await process_frame
	var finer: int = main.ifs.instance_count
	main._step_ifs_depth(1)
	for i in 3:
		await process_frame
	var deep_n: int = main.ifs.instance_count
	var deep_z: float = main.ifs.bounds.size.z
	main._reset_ifs()
	for i in 3:
		await process_frame
	var reset_ok: bool = main.ifs.instance_count == base \
		and absf(main.ifs.bounds.size.z - base_z) < 1e-4 \
		and main.ifs.detail == main.IFS_DETAIL[main.IFS_DETAIL_DEFAULT] \
		and is_equal_approx(main.ifs.depth, main.IFS_DEPTH[0])
	_ok("detail tile", finer != base, "instances %d -> %d" % [base, finer])
	_ok("depth tile", deep_n == finer and deep_z > base_z,
		"instances %d -> %d, z span %.4f -> %.4f" % [finer, deep_n, base_z, deep_z])
	_ok("reset tile", reset_ok, "instances %d z span %.4f detail=%d depth=%.2f" % [
		main.ifs.instance_count, main.ifs.bounds.size.z, main.ifs.detail, main.ifs.depth])

	var img := root.get_viewport().get_texture().get_image()
	var err := img.save_png("%s/mode-ifs-reset.png" % OUT)
	_ok("reset capture", err == OK and _lit(img) > 500, "%s/mode-ifs-reset.png err=%d" % [OUT, err])


## IFS-3, driven end to end. Registering trackers under the names main.tscn's controllers
## already reference is what makes this the real path: main's own _pressed edge detection, its
## own ownership resolution, the editor's own picking, and a WorldGrab that is genuinely
## polling grips underneath it all.
func _sculpt(main) -> void:
	var lt := _tracker(&"left_hand")
	var rt := _tracker(&"right_hand")
	_lt = lt
	_rt = rt
	# Parked out of the way to start with, and pointing nowhere near the sculpture, so the
	# wrist panel cannot take the ray. That is asserted below rather than assumed.
	_pose(lt, Transform3D(Basis(), Vector3(0.35, 1.05, 0.30)))
	main._set_mode("ifs")
	main._reset_ifs()
	for i in 10:
		await process_frame

	var edit_tile = _tile(main, "EDIT")
	var undo_tile = _tile(main, "UNDO")
	if edit_tile == null or undo_tile == null:
		_ok("sculpt tiles", false, "EDIT or UNDO missing from the make section")
		return
	edit_tile.advance.call()
	for i in 4:
		await process_frame
	_ok("edit tile", main.ifs_edit.guides_on and main.ifs_edit.visible
			and str(edit_tile.read.call()) == "handles on",
		"guides_on=%s visible=%s tile reads '%s'" % [str(main.ifs_edit.guides_on),
			str(main.ifs_edit.visible), str(edit_tile.read.call())])

	# PLANE A's grab target is a fixed point in construction space. Where it lands in the room
	# is whatever the tabletop framing made of it, which is the conversion being tested.
	var knob: Vector3 = main.ifs.global_transform * Vector3(0.0, IfsEditor.KNOB_OUT, 0.0)
	var pulled: Vector3 = main.ifs.global_transform * Vector3(0.25, IfsEditor.KNOB_OUT, 0.0)
	_pose(rt, Transform3D(Basis(), knob))
	for i in 4:
		await process_frame
	# A pose that never reached the node would make every assertion below vacuous.
	var reached: bool = main.right_hand.global_position.distance_to(knob) < 1e-3
	await _shot(main, "sculpt-guides.png")

	var before_bounds: AABB = main.ifs.bounds
	var before_count: int = main.ifs.instance_count
	var before_offset: float = main.ifs.plane1_offset
	# The published instance buffer, not the bounds. Every generation of this shape fits inside
	# the seed frame's own box, so the AABB is the same at every plane offset: a bounds check
	# would have read as "nothing changed" however far the mirror moved.
	var before_buf: PackedFloat32Array = main.ifs.get_node("Frames").multimesh.buffer
	var preset_before: int = main.preset_idx
	var detail_before: int = main.ifs_detail_idx

	rt.set_input(&"trigger_click", true)
	for i in 4:
		await process_frame
	_ok("capture", reached and main.ifs_edit.is_editing()
			and main.ifs_edit.held_handle() == IfsEditor.PLANE_A
			and main.grab.suspended and main._trig_owned and not main._menu_active,
		"reached the handle=%s editing=%s handle=%d grab suspended=%s trigger owned=%s menu=%s" % [
			str(reached), str(main.ifs_edit.is_editing()), main.ifs_edit.held_handle(),
			str(main.grab.suspended), str(main._trig_owned), str(main._menu_active)])

	_pose(rt, Transform3D(Basis(), pulled))
	for i in 6:
		await process_frame
	var changed: bool = absf(main.ifs.plane1_offset - before_offset) > 0.2 \
		and main.ifs.get_node("Frames").multimesh.buffer != before_buf
	await _shot(main, "sculpt-drag.png")

	# The second controller, parked ON the other plane's grab target so it genuinely would
	# capture if one-edit-at-a-time were missing. A trigger spent on an edit must also step
	# neither the detail rung nor the flame gallery behind the sculpture.
	_pose(lt, Transform3D(Basis(), main.ifs.global_transform * Vector3(-IfsEditor.KNOB_OUT, 0.0, 0.0)))
	for i in 3:
		await process_frame
	lt.set_input(&"trigger_click", true)
	for i in 4:
		await process_frame
	await _tap(main, KEY_RIGHT)
	var alone: bool = main.ifs_edit.is_editing() \
		and main.ifs_edit.held_handle() == IfsEditor.PLANE_A \
		and main.ifs_detail_idx == detail_before and main.preset_idx == preset_before \
		and not main._menu_active
	lt.set_input(&"trigger_click", false)
	_pose(lt, Transform3D(Basis(), Vector3(0.35, 1.05, 0.30)))
	_ok("one edit at a time", changed and alone,
		"offset %.4f -> %.4f, second trigger holds handle %d, detail %d/%d preset %d/%d" % [
			before_offset, main.ifs.plane1_offset, main.ifs_edit.held_handle(),
			main.ifs_detail_idx, detail_before, main.preset_idx, preset_before])

	rt.set_input(&"trigger_click", false)
	for i in 6:
		await process_frame
	_ok("release", not main.ifs_edit.is_editing() and not main.grab.suspended
			and main.ifs_edit.has_undo()
			and main.ifs.detail == main.IFS_DETAIL[main.ifs_detail_idx],
		"editing=%s grab suspended=%s undo offered=%s detail=%d/%d" % [
			str(main.ifs_edit.is_editing()), str(main.grab.suspended),
			str(main.ifs_edit.has_undo()), main.ifs.detail,
			main.IFS_DETAIL[main.ifs_detail_idx]])

	undo_tile.advance.call()
	for i in 4:
		await process_frame
	await _shot(main, "sculpt-undo.png")
	var back_buf: PackedFloat32Array = main.ifs.get_node("Frames").multimesh.buffer
	_ok("undo tile", main.ifs.instance_count == before_count
			and main.ifs.bounds == before_bounds and back_buf == before_buf
			and main.ifs.plane1_offset == before_offset and not main.ifs_edit.has_undo(),
		"instances %d/%d bounds identical=%s every transform identical=%s offset %.6f/%.6f undo still offered=%s" % [
			main.ifs.instance_count, before_count, str(main.ifs.bounds == before_bounds),
			str(back_buf == before_buf), main.ifs.plane1_offset, before_offset,
			str(main.ifs_edit.has_undo())])

	# Leaving the mode mid-drag: ownership gone, grab handed back, snapshot restored.
	_pose(rt, Transform3D(Basis(), knob))
	for i in 4:
		await process_frame
	var mid: float = main.ifs.plane1_offset
	rt.set_input(&"trigger_click", true)
	for i in 4:
		await process_frame
	_pose(rt, Transform3D(Basis(), pulled))
	for i in 5:
		await process_frame
	var was_editing: bool = main.ifs_edit.is_editing() and main.ifs.plane1_offset != mid
	main._set_mode("tree")
	for i in 8:
		await process_frame
	var clean: bool = not main.ifs_edit.is_editing() and not main.grab.suspended \
		and main.ifs.plane1_offset == mid and not main.ifs_edit.has_undo()
	rt.set_input(&"trigger_click", false)
	_ok("mode change mid-edit", was_editing and clean,
		"was editing=%s after: editing=%s grab suspended=%s offset %.6f/%.6f undo recorded=%s" % [
			str(was_editing), str(main.ifs_edit.is_editing()), str(main.grab.suspended),
			main.ifs.plane1_offset, mid, str(main.ifs_edit.has_undo())])


## The gallery. A preset is a new sculpture, so the check is not only that the shape changed:
## it is that everything the old sculpture accumulated went with it, and that the one thing the
## user owns, where the sculpture is sitting, did not.
func _shapes(main) -> void:
	main._set_mode("ifs")
	main._reset_ifs()
	for i in 10:
		await process_frame
	var shape_tile = _visible_tile(main, "SHAPE")
	if shape_tile == null:
		_ok("shape tile", false, "no SHAPE tile visible in the make section while in IFS")
		return
	var first_name: String = str(shape_tile.read.call())
	_ok("shape tile", first_name == FractalIFS.preset_name(main.ifs_preset_idx),
		"tile reads '%s' at preset %d" % [first_name, main.ifs_preset_idx])

	# Give the preset change something real to throw away: a completed edit, a moved mirror, a
	# stretched depth and a sculpture that has been pushed somewhere. A reset that clears
	# nothing proves nothing.
	main.ifs_edit.set_guides(true)
	for i in 4:
		await process_frame
	var knob: Vector3 = main.ifs.global_transform * Vector3(0.0, IfsEditor.KNOB_OUT, 0.0)
	_pose(_rt, Transform3D(Basis(), knob))
	for i in 4:
		await process_frame
	_rt.set_input(&"trigger_click", true)
	for i in 4:
		await process_frame
	_pose(_rt, Transform3D(Basis(), main.ifs.global_transform * Vector3(0.25, IfsEditor.KNOB_OUT, 0.0)))
	for i in 6:
		await process_frame
	_rt.set_input(&"trigger_click", false)
	for i in 6:
		await process_frame
	main._step_ifs_depth(1)
	main.cloud.global_transform = main.cloud.global_transform.translated(Vector3(0.13, 0.0, 0.0))
	for i in 4:
		await process_frame
	var dirty: bool = main.ifs_edit.has_undo() and absf(main.ifs.plane1_offset) > 0.05 \
		and not is_equal_approx(main.ifs.depth, main.IFS_DEPTH[0])
	var pose_before: Transform3D = main.cloud.global_transform
	var idx_before: int = main.ifs_preset_idx

	shape_tile.advance.call()
	for i in 6:
		await process_frame
	var name_now := FractalIFS.preset_name(main.ifs_preset_idx)
	var cleared: bool = main.ifs_preset_idx == idx_before + 1 \
		and str(shape_tile.read.call()) == name_now and name_now != first_name \
		and main.ifs.preset == main.ifs_preset_idx \
		and main.ifs.plane1_offset == 0.0 and main.ifs.plane2_offset == 0.0 \
		and main.ifs.plane1_normal == FractalIFS.DEFAULT_N1 \
		and is_equal_approx(main.ifs.depth, main.IFS_DEPTH[0]) \
		and not main.ifs_edit.has_undo() and not main.ifs_edit.is_editing() \
		and main.ifs.detail == main.ifs.preset_detail() \
		and main.ifs.detail == main.IFS_DETAIL[main.ifs_detail_idx]
	# The pose is the one thing a preset change must leave alone: a sculpture you moved must
	# stay where you put it when you swap what it is.
	var kept_pose: bool = main.cloud.global_transform.is_equal_approx(pose_before)
	_ok("shape step", dirty and cleared and kept_pose,
		"%s -> %s, had an edit to lose=%s planes/depth/undo cleared=%s detail=%d pose kept=%s" % [
			first_name, name_now, str(dirty), str(cleared), main.ifs.detail, str(kept_pose)])

	# A and B, the same ladder from the face buttons. Forward then back must land where it
	# started, or the two directions disagree about what "next" means.
	var before_ab: int = main.ifs_preset_idx
	await _tap(main, KEY_2)
	var stepped: int = main.ifs_preset_idx
	await _tap(main, KEY_1)
	_ok("shape a/b", stepped == wrapi(before_ab + 1, 0, FractalIFS.PRESETS.size())
			and main.ifs_preset_idx == before_ab,
		"B: %d -> %d, A: -> %d (of %d)" % [before_ab, stepped, main.ifs_preset_idx,
			FractalIFS.PRESETS.size()])

	# One capture of each, walked with the tile so the pictures come from the path a user
	# takes rather than from a private setter.
	main.ifs_edit.set_guides(false)
	while main.ifs_preset_idx != 0:
		shape_tile.advance.call()
		for i in 3:
			await process_frame
	for p in FractalIFS.PRESETS.size():
		for i in 6:
			await process_frame
		var name_ := FractalIFS.preset_name(main.ifs_preset_idx)
		var want: int = int(PRESET_INSTANCES[name_])
		var img := root.get_viewport().get_texture().get_image()
		var file := "shape-%s.png" % name_.to_lower()
		var err := img.save_png("%s/%s" % [OUT, file])
		var lit := _lit(img)
		_ok("shape %s" % name_.to_lower(),
			err == OK and lit > 500 and main.ifs.instance_count == want,
			"%s lit=%d instances=%d/%d triangles=%d build=%.2fms" % [
				file, lit, main.ifs.instance_count, want, main.ifs.triangle_count,
				main.ifs.build_ms])
		shape_tile.advance.call()
	for i in 4:
		await process_frame


func _tracker(n: StringName) -> XRControllerTracker:
	var t := XRControllerTracker.new()
	t.name = n
	t.type = XRServer.TRACKER_CONTROLLER
	XRServer.add_tracker(t)
	return t


## Both pose names, because main.tscn leaves the controllers on the engine default and a pose
## written under the wrong name is a silent no-op that makes every later assertion vacuous.
func _pose(t: XRControllerTracker, xf: Transform3D) -> void:
	t.set_pose(&"default", xf, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	t.set_pose(&"aim", xf, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)


func _tile(main, label: String):
	for it in main.menu.items:
		if it.section == "make" and it.label == label:
			return it
	return null


## The tile with this label that the CURRENT mode actually shows. IFS and TREE both have a
## SHAPE, and taking whichever was declared first would quietly test the tree's.
func _visible_tile(main, label: String):
	for it in main.menu.items:
		if it.section == "make" and it.label == label \
				and (not it.visible_when.is_valid() or bool(it.visible_when.call())):
			return it
	return null


func _shot(main, file: String) -> void:
	for i in 3:
		await process_frame
	var img := root.get_viewport().get_texture().get_image()
	var err := img.save_png("%s/%s" % [OUT, file])
	var lit := _lit(img)
	_ok("shot %s" % file.get_basename(), err == OK and lit > 500,
		"%s/%s lit=%d err=%d" % [OUT, file, lit, err])


## Compute dispatches the particle cloud made over a fixed run of frames. ParticleCloud
## bumps _frame inside iterate(), so this counts the thing that costs, not a visibility flag.
func _dispatches(main) -> int:
	var before: int = main.cloud._frame
	for i in SAMPLE_FRAMES:
		await process_frame
	return main.cloud._frame - before


## Press and release a key through the input singleton, so main's own _key() edge detection
## runs. There is no controller here, and the trigger paths are what this file is about.
func _tap(main, code: Key) -> void:
	var down := InputEventKey.new()
	down.keycode = code
	down.physical_keycode = code
	down.pressed = true
	Input.parse_input_event(down)
	for i in 3:
		await process_frame
	var up := InputEventKey.new()
	up.keycode = code
	up.physical_keycode = code
	up.pressed = false
	Input.parse_input_event(up)
	for i in 3:
		await process_frame


## Lit pixels. A PNG that saved is not a PNG that drew anything.
func _lit(img: Image) -> int:
	var n := 0
	for y in range(0, img.get_height(), 2):
		for x in range(0, img.get_width(), 2):
			var c := img.get_pixel(x, y)
			if maxf(c.r, maxf(c.g, c.b)) > 0.12:
				n += 1
	return n
