extends SceneTree

## Headless numeric checks for FractalIFS: the reflection algebra, determinism, what depth
## and detail are each allowed to change, the published counts, bounds and caps at every
## parameter extreme, and the Enter clearance query. Each section carries a control that
## must fail, because a check that cannot fail has not been run.
##
## Also WorldGrab.suspended, the input-ownership hook IFS-3 needs. It lives here rather than
## in a scene capture because a fake XR tracker makes the whole grab path runnable headless.
##
##   tools/ifs_check.sh

const EPS := 1e-5
const EXPECTED_COUNTS := [1, 9, 73, 585, 4681]

var _fails := 0


func _init() -> void:
	var ifs := FractalIFS.new()
	root.add_child(ifs)
	_seed(ifs)
	_reflection()
	_children(ifs)
	_determinism(ifs)
	_depth(ifs)
	_detail(ifs)
	_extremes(ifs)
	_clearance(ifs)
	_rejection(ifs)
	await _grab_suspend()
	_editor_setup()
	await _editor_space()
	await _editor_reach()
	await _editor_clamps()
	await _editor_undo()
	await _editor_cancel()
	await _editor_gate()
	_editor_teardown()
	print("IFSCHECK %s failures=%d" % ["PASS" if _fails == 0 else "FAIL", _fails])
	quit(0 if _fails == 0 else 1)


func _ok(name: String, pass_: bool, detail: String) -> void:
	if not pass_:
		_fails += 1
	print("  %-22s %s  %s" % [name, "PASS" if pass_ else "FAIL", detail])


func _seed(ifs: FractalIFS) -> void:
	var verts: PackedVector3Array = ifs.seed_mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var far := 0.0
	for v in verts:
		far = maxf(far, maxf(absf(v.x), maxf(absf(v.y), absf(v.z))))
	_ok("seed", ifs.seed_tris == 144 and is_equal_approx(far, FractalIFS.SEED_HALF),
		"triangles=%d vertices=%d reach=%.4f (beam half-width %.3f past 1.0)" % [
			ifs.seed_tris, verts.size(), far, FractalIFS.BEAM_HW])


func _reflection() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var fixed := 0.0
	var involution := 0.0
	var ctl := 0.0
	for i in 200:
		var n := Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1))
		if n.length() < 0.1:
			continue
		n = n.normalized()
		var d := rng.randf_range(-0.5, 0.5)
		var r := FractalIFS.reflection(n, d)
		var q := Vector3(rng.randf_range(-2, 2), rng.randf_range(-2, 2), rng.randf_range(-2, 2))
		# A point on the plane: drop q's signed distance along the normal.
		var on := q - (n.dot(q) - d) * n
		fixed = maxf(fixed, (r * on - on).length())
		involution = maxf(involution, (r * (r * q) - q).length())
		# Control: the projection onto the same plane, which also fixes on-plane points but
		# halves the step instead of doubling it. Applying it twice must not return q, or
		# the involution test above would pass for a map that is not a reflection.
		var proj := Transform3D(Basis(
			Vector3(1, 0, 0) - n.x * n, Vector3(0, 1, 0) - n.y * n, Vector3(0, 0, 1) - n.z * n),
			d * n)
		ctl = maxf(ctl, (proj * (proj * q) - q).length())
	var pass_ := fixed < EPS and involution < EPS and ctl > 1e-2
	_ok("reflection", pass_, "on-plane err=%.9f involution err=%.9f projection control err=%.4f" % [
		fixed, involution, ctl])


func _children(ifs: FractalIFS) -> void:
	var maps := FractalIFS.child_maps(Vector3(1, 0, 0), 0.0, Vector3(0, 1, 0), 0.0, 0.35,
		Vector3(0.6, 0.6, 0.6))
	var want: Array[Vector3] = []
	for sz in [0.6, -0.6]:
		for sy in [0.6, -0.6]:
			for sx in [0.6, -0.6]:
				want.append(Vector3(sx, sy, sz))
	var seen: Array[Vector3] = []
	var det_err := 0.0
	var mirrored := 0
	for m in maps:
		seen.append(m.origin)
		det_err = maxf(det_err, absf(absf(m.basis.determinant()) - pow(0.35, 3)))
		if m.basis.determinant() < 0.0:
			mirrored += 1
	var covered := 0
	for w in want:
		for s in seen:
			if (s - w).length() < EPS:
				covered += 1
				break
	# Four of the eight children mirror, which is exactly why the material disables culling.
	var pass_ := maps.size() == 8 and covered == 8 and det_err < EPS and mirrored == 4
	_ok("child maps", pass_, "n=%d octants covered=%d/8 |det| err=%.9f mirrored=%d" % [
		maps.size(), covered, det_err, mirrored])


func _determinism(ifs: FractalIFS) -> void:
	_defaults(ifs)
	ifs.build()
	var a: PackedFloat32Array = ifs.get_node("Frames").multimesh.buffer
	var xa := ifs.xforms.duplicate()
	ifs.build()
	var b: PackedFloat32Array = ifs.get_node("Frames").multimesh.buffer
	var same_xf := true
	for i in xa.size():
		same_xf = same_xf and xa[i] == ifs.xforms[i]
	ifs.plane1_offset = 0.11
	ifs.build()
	var c: PackedFloat32Array = ifs.get_node("Frames").multimesh.buffer
	_defaults(ifs)
	_ok("determinism", a == b and same_xf and a != c,
		"same params identical=%s transforms identical=%s moved plane differs=%s" % [
			str(a == b), str(same_xf), str(a != c)])


func _depth(ifs: FractalIFS) -> void:
	_defaults(ifs)
	ifs.depth = 1.0
	ifs.build()
	var n1 := ifs.instance_count
	var b1 := ifs.bounds
	var z1: Array[float] = []
	for t in ifs.xforms:
		z1.append(t.origin.z)
	ifs.depth = 2.0
	ifs.build()
	var n2 := ifs.instance_count
	var b2 := ifs.bounds
	var z_scaled := true
	var xy_still := absf(b2.size.x - b1.size.x) < EPS and absf(b2.size.y - b1.size.y) < EPS
	for i in ifs.xforms.size():
		z_scaled = z_scaled and absf(ifs.xforms[i].origin.z - z1[i] * 2.0) < EPS
	ifs.depth = FractalIFS.DEPTH_MIN
	ifs.build()
	var b0 := ifs.bounds
	var flat := b0.size.z < b1.size.z * 0.2
	_defaults(ifs)
	var pass_ := n1 == n2 and z_scaled and xy_still and absf(b2.size.z - b1.size.z * 2.0) < 1e-4 and flat
	_ok("depth", pass_, "count %d->%d z span %.4f -> %.4f (min %.4f) xy unchanged=%s" % [
		n1, n2, b1.size.z, b2.size.z, b0.size.z, str(xy_still)])


func _detail(ifs: FractalIFS) -> void:
	_defaults(ifs)
	var counts: Array[int] = []
	for d in 5:
		ifs.detail = d
		counts.append(ifs.build())
	var match_ := true
	for d in 5:
		match_ = match_ and counts[d] == EXPECTED_COUNTS[d]
	ifs.detail = 5
	var capped := ifs.build()
	var cap_ok: bool = capped == 4681 and ifs.levels_built == 4 and ifs.cap_note != ""
	var params_held: bool = ifs.depth == 1.0 and ifs.plane1_offset == 0.0 and ifs.contraction == 0.35
	_defaults(ifs)
	_ok("detail counts", match_ and params_held, "0..4 = %s (want %s) params unchanged=%s" % [
		str(counts), str(EXPECTED_COUNTS), str(params_held)])
	_ok("detail cap", cap_ok, "detail 5 -> %d instances, %d triangles; %s" % [
		capped, capped * ifs.seed_tris, ifs.cap_note])


## Every extreme the editor will allow: plane offsets +-0.3, plane rotations +-30 degrees,
## both depth limits, and all of them at once. At each one every beam corner must land inside
## the published bounds, and both caps must hold even when detail asks for more than fits.
func _extremes(ifs: FractalIFS) -> void:
	var cases := _cases()
	var worst := 0.0
	var worst_name := "none"
	var all_ok := true
	var caps_ok := true
	var max_inst := 0
	var max_tri := 0
	var walks := 0
	for case in cases:
		# The corner walk is the expensive part, so it runs at the working rung for every
		# case and at the top rung only where the geometry is most stretched.
		var details: Array = [3, 4] if case[0] == "default" or case[0] == "all at once" else [3]
		for d in details:
			_defaults(ifs)
			_apply(ifs, case[1])
			ifs.detail = d
			ifs.build()
			var out := _worst_escape(ifs, ifs.bounds)
			walks += 1
			if out > worst:
				worst = out
				worst_name = "%s@detail%d" % [case[0], d]
			all_ok = all_ok and out < 1e-4
		# Caps: ask for more detail than the budget allows and require a whole level back.
		_defaults(ifs)
		_apply(ifs, case[1])
		ifs.detail = FractalIFS.MAX_DETAIL
		ifs.build()
		max_inst = maxi(max_inst, ifs.instance_count)
		max_tri = maxi(max_tri, ifs.triangle_count)
		# A capped build must hand back a whole level, not one detailed corner beside
		# seven coarse ones.
		var whole: bool = ifs.instance_count == EXPECTED_COUNTS[ifs.levels_built]
		caps_ok = caps_ok and whole and ifs.instance_count <= FractalIFS.MAX_INSTANCES \
			and ifs.triangle_count <= FractalIFS.MAX_TRIANGLES
	# Control: shave the bounds and the same corners must escape. A containment test run
	# against a box derived from those corners would otherwise pass against anything.
	_defaults(ifs)
	ifs.build()
	var shrunk := AABB(ifs.bounds.position + ifs.bounds.size * 0.05, ifs.bounds.size * 0.9)
	var ctl := _worst_escape(ifs, shrunk)
	_defaults(ifs)
	_ok("bounds", all_ok and ctl > 1e-2, "%d corner walks, worst escape %.9f (%s), control escape %.4f" % [
		walks, worst, worst_name, ctl])
	_ok("caps", caps_ok,
		"at detail %d over %d cases: max instances=%d/%d max triangles=%d/%d" % [
			FractalIFS.MAX_DETAIL, cases.size(), max_inst, FractalIFS.MAX_INSTANCES,
			max_tri, FractalIFS.MAX_TRIANGLES])


func _clearance(ifs: FractalIFS) -> void:
	_defaults(ifs)
	ifs.build()
	var c: float = ifs.contraction
	# The nearest beam to the centre is a generation-1 beam lying along one axis at
	# (offset - c) on the other two, ending at (offset - c * SEED_HALF). Its capsule radius
	# is both short half-extents of the beam.
	var end_: float = ifs.offset.x - c * FractalIFS.SEED_HALF
	var lat: float = ifs.offset.x - c
	var r := 2.0 * c * FractalIFS.BEAM_HW
	var want := sqrt(end_ * end_ + 2.0 * lat * lat) - r
	var got := ifs.clear_radius_at(Vector3.ZERO)
	var on_beam := ifs.clear_radius_at(Vector3(0.0, 1.0, 1.0))
	var far := ifs.clear_radius_at(Vector3(0.0, 0.0, 6.0))
	# Plan section 3: a plane offset of 0.3 shifts reflected children by 0.6 and can push
	# them through the centre, which is the reason Enter needs this query at all.
	ifs.plane1_offset = 0.3
	ifs.build()
	var shifted := ifs.clear_radius_at(Vector3.ZERO)
	_defaults(ifs)
	var pass_ := absf(got - want) < 1e-3 and on_beam == 0.0 and far > 4.0 and shifted < got
	_ok("clearance", pass_, "origin=%.4f (derived %.4f) on beam=%.4f far=%.3f offset plane=%.4f" % [
		got, want, on_beam, far, shifted])


func _rejection(ifs: FractalIFS) -> void:
	_defaults(ifs)
	ifs.build()
	var clean := ifs.rejected
	var base := ifs.instance_count
	ifs.plane1_normal = Vector3.ZERO
	ifs.build()
	var zero := ifs.rejected
	var zero_n := ifs.instance_count
	ifs.plane1_normal = Vector3(NAN, 0.0, 0.0)
	ifs.plane2_offset = INF
	ifs.build()
	var bad := ifs.rejected
	var finite := true
	for t in ifs.xforms:
		finite = finite and t.origin.is_finite() and t.basis.determinant() != 0.0
	_defaults(ifs)
	_ok("bad planes", clean == 0 and zero == 1 and zero_n == base and bad == 2 and finite,
		"valid=%d zero normal=%d nan+inf=%d all transforms finite=%s" % [clean, zero, bad, str(finite)])


## WorldGrab.suspended, the hook that lets an IFS handle edit take the grips away from world
## manipulation. Driven through a registered XRControllerTracker, so the hand is genuinely
## tracked and genuinely gripping and update() runs its whole path rather than bailing at the
## poll. The "it followed" step is the control for the "it stopped" step: without it, a target
## that did not move proves only that nothing was ever holding it.
func _grab_suspend() -> void:
	var tracker := XRControllerTracker.new()
	tracker.name = &"ifs_check_hand"
	tracker.type = XRServer.TRACKER_CONTROLLER
	XRServer.add_tracker(tracker)
	var origin := XROrigin3D.new()
	root.add_child(origin)
	var hand := XRController3D.new()
	hand.tracker = &"ifs_check_hand"
	hand.pose = &"aim"
	origin.add_child(hand)
	var target := Node3D.new()
	root.add_child(target)
	target.global_transform = Transform3D(Basis(), Vector3(0.0, 1.0, -1.0))
	var hands: Array[XRController3D] = [hand]
	var grab := WorldGrab.new(hands, target)
	tracker.set_input(&"grip_click", true)

	await _pose(tracker, Vector3(0.2, 1.2, -0.3))
	grab.update(0.016)
	# Followed: one grip moves the target rigidly with the hand.
	await _pose(tracker, Vector3(0.7, 1.2, -0.3))
	grab.update(0.016)
	var followed := target.global_transform.origin
	var moved: bool = followed.distance_to(Vector3(0.5, 1.0, -1.0)) < 1e-4

	# Suspended: the same held grip, the same moving hand, and the target stays put.
	grab.suspended = true
	await _pose(tracker, Vector3(1.4, 1.2, -0.3))
	grab.update(0.016)
	var stopped: bool = target.global_transform.origin.distance_to(followed) < 1e-6 \
		and not grab.is_grabbing() and grab.grip_count() == 0

	# Resumed: the first frame back recaptures from wherever the hand now is, so the target
	# does not snap by the distance it was moved while suspended.
	grab.suspended = false
	grab.update(0.016)
	var no_jump: bool = target.global_transform.origin.distance_to(followed) < 1e-6
	await _pose(tracker, Vector3(1.65, 1.2, -0.3))
	grab.update(0.016)
	var resumed: bool = target.global_transform.origin.distance_to(followed + Vector3(0.25, 0.0, 0.0)) < 1e-4

	tracker.set_input(&"grip_click", false)
	XRServer.remove_tracker(tracker)
	_ok("grab suspend", moved and stopped and no_jump and resumed,
		"followed=%s held while suspended=%s no jump on resume=%s followed again=%s" % [
			str(moved), str(stopped), str(no_jump), str(resumed)])


# --- IfsEditor -------------------------------------------------------------
#
# Everything below drives the real editor through its real entry point, with the sculpture
# somewhere genuinely awkward: turned about two axes and shrunk the way the tabletop framing
# shrinks it. An editor that quietly did its arithmetic in world space would pass every one of
# these at identity, which is why none of them runs at identity.

var _rig := {}


func _editor_setup() -> void:
	var holder := Node3D.new()
	root.add_child(holder)
	var b := Basis(Vector3.UP, deg_to_rad(37.0)) * Basis(Vector3.RIGHT, deg_to_rad(-14.0))
	holder.transform = Transform3D(b.scaled(Vector3.ONE * 0.27), Vector3(0.3, 1.4, -0.8))
	var ifs := FractalIFS.new()
	holder.add_child(ifs)
	_defaults(ifs)
	ifs.build()
	var ed := IfsEditor.new()
	ifs.add_child(ed)
	ed.setup(ifs)
	ed.set_guides(true)
	var tracker := XRControllerTracker.new()
	tracker.name = &"ifs_edit_hand"
	tracker.type = XRServer.TRACKER_CONTROLLER
	XRServer.add_tracker(tracker)
	var origin := XROrigin3D.new()
	root.add_child(origin)
	var hand := XRController3D.new()
	hand.tracker = &"ifs_edit_hand"
	hand.pose = &"aim"
	origin.add_child(hand)
	var hands: Array[XRController3D] = [hand]
	_rig = {"ifs": ifs, "ed": ed, "tracker": tracker, "hands": hands}


func _editor_teardown() -> void:
	if _rig.has("tracker"):
		XRServer.remove_tracker(_rig["tracker"])


## Controller-space to construction-space, the conversion every drag depends on. The hand moves
## by a displacement stated in construction units; the offset that comes out must be that
## displacement's component along the plane normal, and the world-space reading must not be.
func _editor_space() -> void:
	var ifs: FractalIFS = _rig["ifs"]
	var ed: IfsEditor = _rig["ed"]
	_reset_edit()
	await _hand_to(Transform3D(Basis(), _world_of(_knob_a())))
	var took := _feed(true, true)
	var got_a: bool = took and ed.is_editing() and ed.held_handle() == IfsEditor.PLANE_A
	var want := Vector3(0.14, 0.05, -0.03)
	var dw: Vector3 = _cbasis() * want
	await _hand_to(Transform3D(Basis(), _world_of(_knob_a() + want)))
	_feed(false, true)
	var got := ifs.plane1_offset
	# Control: the same hand motion read in world space, which is what dropping the conversion
	# would produce. If these two agreed the check would prove nothing.
	var naive: float = FractalIFS.DEFAULT_N1.dot(dw)
	_feed(false, false)

	# Rotation, in the same space. Turning the wrist about the world axis that IS construction
	# +Z must tilt the normal about construction +Z by the same angle, exactly.
	_reset_edit()
	var at := _world_of(_knob_a())
	await _hand_to(Transform3D(Basis(), at))
	_feed(true, true)
	var axis: Vector3 = (_cbasis() * Vector3(0.0, 0.0, 1.0)).normalized()
	await _hand_to(Transform3D(Basis(axis, deg_to_rad(12.0)), at))
	_feed(false, true)
	var n := ifs.plane1_normal
	var want_n := FractalIFS.DEFAULT_N1.rotated(Vector3(0.0, 0.0, 1.0), deg_to_rad(12.0))
	var naive_n := FractalIFS.DEFAULT_N1.rotated(axis, deg_to_rad(12.0))
	_feed(false, false)
	_reset_edit()
	_ok("editor space", got_a and absf(got - want.x) < 1e-4 and absf(naive - want.x) > 1e-2 \
			and (n - want_n).length() < 1e-5 and (naive_n - want_n).length() > 1e-2,
		"picked=%s offset=%.5f (want %.5f, world-space control %.5f) normal err=%.8f (control %.4f)" % [
			str(got_a), got, want.x, naive, (n - want_n).length(), (naive_n - want_n).length()])


## Near and far picking. A metre of reach is the whole point of a ray; a ray that ignores its
## own direction is not a ray, so the control aims well off and must come back empty.
func _editor_reach() -> void:
	var ed: IfsEditor = _rig["ed"]
	_reset_edit()
	var target := _world_of(_knob_a())
	var from := target + Vector3(0.0, 0.35, 1.05)
	await _hand_to(_looking(from, target))
	var took := _feed(true, true)
	var far_ok: bool = took and ed.is_editing() and ed.held_handle() == IfsEditor.PLANE_A
	_feed(false, false)
	_reset_edit()
	var off := _looking(from, target)
	off.basis = off.basis.rotated(Vector3.UP, deg_to_rad(40.0))
	await _hand_to(off)
	var stray := _feed(true, true)
	var miss: bool = not ed.is_editing() and not stray
	_feed(false, false)
	_reset_edit()
	_ok("editor reach", far_ok and miss, "ray pick at %.3f m=%s, same ray 40 degrees off=%s" % [
		from.distance_to(target), str(far_ok), str(not miss)])


## Every limit, driven past it by a mile. A clamp that holds at the extreme is the only kind
## worth having: the interesting failure is a handle that keeps going, not one that stops early.
func _editor_clamps() -> void:
	var ifs: FractalIFS = _rig["ifs"]
	var offs: Array[float] = []
	for s in [1.0, -1.0]:
		_reset_edit()
		await _hand_to(Transform3D(Basis(), _world_of(_knob_a())))
		_feed(true, true)
		await _hand_to(Transform3D(Basis(), _world_of(_knob_a() + Vector3(5.0 * s, 0.0, 0.0))))
		_feed(false, true)
		offs.append(ifs.plane1_offset)
		_feed(false, false)

	_reset_edit()
	var at := _world_of(_knob_a())
	await _hand_to(Transform3D(Basis(), at))
	_feed(true, true)
	var axis: Vector3 = (_cbasis() * Vector3(0.0, 0.0, 1.0)).normalized()
	await _hand_to(Transform3D(Basis(axis, deg_to_rad(70.0)), at))
	_feed(false, true)
	var tilt := rad_to_deg(ifs.plane1_normal.angle_to(FractalIFS.DEFAULT_N1))
	_feed(false, false)

	var depths: Array[float] = []
	for s in [1.0, -1.0]:
		_reset_edit()
		var dp := _knob_depth()
		await _hand_to(Transform3D(Basis(), _world_of(dp)))
		_feed(true, true)
		await _hand_to(Transform3D(Basis(), _world_of(dp + Vector3(0.0, 0.0, 6.0 * s))))
		_feed(false, true)
		depths.append(ifs.depth)
		_feed(false, false)
	_reset_edit()
	var pass_ := is_equal_approx(offs[0], IfsEditor.MAX_OFFSET) \
		and is_equal_approx(offs[1], -IfsEditor.MAX_OFFSET) \
		and absf(tilt - IfsEditor.MAX_TILT_DEG) < 1e-3 \
		and is_equal_approx(depths[0], FractalIFS.DEPTH_MAX) \
		and is_equal_approx(depths[1], FractalIFS.DEPTH_MIN)
	_ok("editor clamps", pass_,
		"offset %+.4f / %+.4f (limit %.2f) tilt %.4f deg (limit %.0f) depth %.4f / %.4f" % [
			offs[0], offs[1], IfsEditor.MAX_OFFSET, tilt, IfsEditor.MAX_TILT_DEG,
			depths[0], depths[1]])


## Undo restores the capture snapshot exactly, once. Starting from parameters that are not the
## defaults, or "restored" could pass by landing on defaults it was heading for anyway.
func _editor_undo() -> void:
	var ifs: FractalIFS = _rig["ifs"]
	var ed: IfsEditor = _rig["ed"]
	_reset_edit()
	ifs.plane2_offset = -0.12
	ifs.depth = 1.4
	ifs.build()
	ed.refresh()
	var before := _snapshot(ifs)
	await _hand_to(Transform3D(Basis(), _world_of(_knob_a())))
	_feed(true, true)
	await _hand_to(Transform3D(Basis(), _world_of(_knob_a() + Vector3(0.2, 0.1, 0.0))))
	_feed(false, true)
	var moved := not _same(before, _snapshot(ifs))
	_feed(false, false)                       # release: one completed edit
	var offered := ed.has_undo()
	var undone := ed.undo()
	var back := _same(before, _snapshot(ifs))
	var once: bool = not ed.has_undo() and not ed.undo()
	_reset_edit()
	_ok("editor undo", moved and offered and undone and back and once,
		"drag changed=%s undo offered=%s restored exactly=%s second undo refused=%s" % [
			str(moved), str(offered), str(back), str(once)])


## A cancel restores exactly, records no undo, drops ownership, and leaves the trigger needing
## a release before it can take anything again.
func _editor_cancel() -> void:
	var ifs: FractalIFS = _rig["ifs"]
	var ed: IfsEditor = _rig["ed"]
	_reset_edit()
	ifs.plane1_offset = 0.07
	ifs.depth = 0.8
	ifs.build()
	ed.refresh()
	var before := _snapshot(ifs)
	await _hand_to(Transform3D(Basis(), _world_of(_knob_a())))
	_feed(true, true)
	await _hand_to(Transform3D(Basis(), _world_of(_knob_a() + Vector3(0.18, 0.0, 0.0))))
	_feed(false, true)
	var moved := not _same(before, _snapshot(ifs))
	# The wrist menu taking the ray is a cancel, not a pause.
	var owned := _feed(false, true, false)
	var restored := _same(before, _snapshot(ifs))
	var idle: bool = not ed.is_editing() and not ed.has_undo() and not owned
	var sticky := _feed(true, true)
	var blocked: bool = not ed.is_editing() and not sticky
	_feed(false, false)                       # release re-arms
	var again := _feed(true, true)
	var rearmed: bool = ed.is_editing() and again
	_feed(false, false)
	_reset_edit()
	_ok("editor cancel", moved and restored and idle and blocked and rearmed,
		"drag changed=%s restored exactly=%s ownership dropped=%s held trigger refused=%s re-press took it=%s" % [
			str(moved), str(restored), str(idle), str(blocked), str(rearmed)])


## EDIT is the gate: with the guides down the trigger belongs to whatever is below the editor.
func _editor_gate() -> void:
	var ed: IfsEditor = _rig["ed"]
	_reset_edit()
	await _hand_to(Transform3D(Basis(), _world_of(_knob_a())))
	ed.set_guides(false)
	var off := _feed(true, true)
	var blocked: bool = not ed.is_editing() and not off
	_feed(false, false)
	ed.set_guides(true)
	var on := _feed(true, true)
	var picked: bool = ed.is_editing() and on
	_feed(false, false)
	_reset_edit()
	_ok("editor gate", blocked and picked, "guides off captured=%s, guides on captured=%s" % [
		str(not blocked), str(picked)])


## One frame of the editor's real entry point, with the trigger state the caller would pass.
func _feed(edge: bool, held: bool, allow := true) -> bool:
	return bool(_rig["ed"].update(_rig["hands"], [edge], [held], [true], allow))


func _hand_to(xf: Transform3D) -> void:
	_rig["tracker"].set_pose(&"aim", xf, Vector3.ZERO, Vector3.ZERO,
		XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	await process_frame
	await process_frame


func _reset_edit() -> void:
	var ifs: FractalIFS = _rig["ifs"]
	var ed: IfsEditor = _rig["ed"]
	ed.cancel()
	ed.clear_undo()
	_defaults(ifs)
	ifs.build()
	ed.refresh()
	ed.set_guides(true)
	_feed(false, false)   # a released trigger clears the re-arm a cancel leaves behind


## The handle positions, derived here from the plan's geometry rather than asked of the editor,
## so a handle that moved would be caught instead of followed.
func _knob_a() -> Vector3:
	return Vector3(0.0, IfsEditor.KNOB_OUT, 0.0)


func _knob_depth() -> Vector3:
	var b: AABB = (_rig["ifs"] as FractalIFS).bounds
	return Vector3(0.0, 0.0, b.position.z + b.size.z + IfsEditor.DEPTH_MARGIN)


func _world_of(p: Vector3) -> Vector3:
	return (_rig["ifs"] as FractalIFS).global_transform * p


func _cbasis() -> Basis:
	return (_rig["ifs"] as FractalIFS).global_transform.basis.orthonormalized()


static func _looking(from: Vector3, at: Vector3) -> Transform3D:
	return Transform3D(Basis.looking_at(at - from, Vector3.UP), from)


func _snapshot(ifs: FractalIFS) -> Array:
	return [ifs.plane1_normal, ifs.plane1_offset, ifs.plane2_normal, ifs.plane2_offset, ifs.depth]


static func _same(a: Array, b: Array) -> bool:
	for i in a.size():
		if a[i] != b[i]:
			return false
	return true


## Move the fake hand and let the pose reach the XRController3D node.
func _pose(tracker: XRControllerTracker, p: Vector3) -> void:
	tracker.set_pose(&"aim", Transform3D(Basis(), p), Vector3.ZERO, Vector3.ZERO,
		XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	await process_frame
	await process_frame


## Largest distance any beam corner lands outside the given box. Beam corners, not the seed
## AABB the bounds were merged from, so the two derivations have to agree.
func _worst_escape(ifs: FractalIFS, box: AABB) -> float:
	var grown := box.grow(1e-6)
	var corners: Array[Vector3] = []
	for beam in ifs.beams:
		var c: Vector3 = beam[0]
		var h: Vector3 = beam[1]
		for sx in [-1.0, 1.0]:
			for sy in [-1.0, 1.0]:
				for sz in [-1.0, 1.0]:
					corners.append(c + Vector3(h.x * sx, h.y * sy, h.z * sz))
	var lo := grown.position
	var hi := grown.position + grown.size
	var worst := 0.0
	for t in ifs.xforms:
		for p in corners:
			var w: Vector3 = t * p
			for k in 3:
				worst = maxf(worst, maxf(lo[k] - w[k], w[k] - hi[k]))
	return maxf(worst, 0.0)


func _cases() -> Array:
	var rot1_p := Vector3(1, 0, 0).rotated(Vector3(0, 0, 1), deg_to_rad(30.0))
	var rot1_m := Vector3(1, 0, 0).rotated(Vector3(0, 0, 1), deg_to_rad(-30.0))
	var rot2_p := Vector3(0, 1, 0).rotated(Vector3(1, 0, 0), deg_to_rad(30.0))
	var rot2_m := Vector3(0, 1, 0).rotated(Vector3(1, 0, 0), deg_to_rad(-30.0))
	return [
		["default", {}],
		["off1+", {"plane1_offset": 0.3}],
		["off1-", {"plane1_offset": -0.3}],
		["off2+", {"plane2_offset": 0.3}],
		["off2-", {"plane2_offset": -0.3}],
		["rot1+30", {"plane1_normal": rot1_p}],
		["rot1-30", {"plane1_normal": rot1_m}],
		["rot2+30", {"plane2_normal": rot2_p}],
		["rot2-30", {"plane2_normal": rot2_m}],
		["depth min", {"depth": FractalIFS.DEPTH_MIN}],
		["depth max", {"depth": FractalIFS.DEPTH_MAX}],
		["all at once", {"plane1_offset": 0.3, "plane2_offset": -0.3, "plane1_normal": rot1_p,
			"plane2_normal": rot2_m, "depth": FractalIFS.DEPTH_MAX}],
	]


func _apply(ifs: FractalIFS, params: Dictionary) -> void:
	for k in params:
		ifs.set(k, params[k])


func _defaults(ifs: FractalIFS) -> void:
	ifs.plane1_normal = FractalIFS.DEFAULT_N1
	ifs.plane2_normal = FractalIFS.DEFAULT_N2
	ifs.plane1_offset = 0.0
	ifs.plane2_offset = 0.0
	ifs.depth = 1.0
	ifs.detail = 3
	ifs.contraction = 0.35
	ifs.offset = Vector3(0.6, 0.6, 0.6)
