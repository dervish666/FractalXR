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

## Per preset, written out rather than computed, so the check keeps its own opinion of the
## branching factor instead of agreeing with whatever the table has come to say. counts are
## levels 0..3; cap is what MAX_DETAIL must hand back; tris is the seed frame's own count.
const PRESET_COUNTS := {
	"FRAMES": [1, 9, 73, 585],
	"TETRA": [1, 9, 73, 585],
	"STAR": [1, 13, 157, 1885],
	"CROSS": [1, 9, 73, 585],
	"TWIST": [1, 9, 73, 585],
}
const PRESET_CAP := {"FRAMES": 4681, "TETRA": 4681, "STAR": 1885, "CROSS": 4681, "TWIST": 4681}
const PRESET_TRIS := {"FRAMES": 144, "TETRA": 72, "STAR": 144, "CROSS": 72, "TWIST": 144}
## FRAMES' eight children, written from the rule in the plan and not read back from the table:
## contract by 0.35 into a corner, then mirror. The second vector is the sign of each basis
## column, which is what says which of {I, R1, R2, R2*R1} produced that child. This is the
## regression guard on preset 0 staying exactly what it was before there were presets.
const FRAMES_CHILDREN := [
	[Vector3(0.6, 0.6, 0.6), Vector3(1, 1, 1)],
	[Vector3(-0.6, 0.6, 0.6), Vector3(-1, 1, 1)],
	[Vector3(0.6, -0.6, 0.6), Vector3(1, -1, 1)],
	[Vector3(-0.6, -0.6, 0.6), Vector3(-1, -1, 1)],
	[Vector3(0.6, 0.6, -0.6), Vector3(1, 1, 1)],
	[Vector3(-0.6, 0.6, -0.6), Vector3(-1, 1, 1)],
	[Vector3(0.6, -0.6, -0.6), Vector3(1, -1, 1)],
	[Vector3(-0.6, -0.6, -0.6), Vector3(-1, -1, 1)],
]

var _fails := 0


func _init() -> void:
	var ifs := FractalIFS.new()
	root.add_child(ifs)
	_seed(ifs)
	_winding(ifs)
	_reflection()
	_children(ifs)
	_determinism(ifs)
	_depth(ifs)
	_detail(ifs)
	_extremes(ifs)
	_presets(ifs)
	_preset_bounds(ifs)
	_preset_caps(ifs)
	_round_trip(ifs)
	_ramp(ifs)
	_instance_data(ifs)
	_ambient(ifs)
	_morph(ifs)
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


## All three seed frames, not just the cube: each must have the triangle count its edge list
## implies, must reach about a beam half-width past 1.0 so a preset can swap seeds without
## re-tuning its offsets, and must publish a seed_box that actually contains its own vertices.
func _seed(ifs: FractalIFS) -> void:
	var lines := PackedStringArray()
	var all_ok := true
	for kind in ["cube", "tetra", "octa"]:
		var want_tris: int = int(FractalIFS.FRAME_EDGES[kind].size()) * 12
		var idx := _preset_of_seed(kind)
		ifs.set_preset(idx)
		var verts: PackedVector3Array = ifs.seed_mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var far := 0.0
		var outside := 0.0
		var box: AABB = ifs.seed_box.grow(1e-6)
		for v in verts:
			far = maxf(far, maxf(absf(v.x), maxf(absf(v.y), absf(v.z))))
			if not box.has_point(v):
				outside = maxf(outside, 1.0)
		var ok: bool = ifs.seed_tris == want_tris and verts.size() == want_tris * 3 \
			and absf(far - FractalIFS.SEED_HALF) < 0.02 and outside == 0.0
		all_ok = all_ok and ok
		lines.append("%s %d tri reach %.4f" % [kind, ifs.seed_tris, far])
	# The cube is the one with a derived reach to hold to exactly, because SEED_HALF is its.
	ifs.set_preset(0)
	var cube_verts: PackedVector3Array = ifs.seed_mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var cube_far := 0.0
	for v in cube_verts:
		cube_far = maxf(cube_far, maxf(absf(v.x), maxf(absf(v.y), absf(v.z))))
	var exact: bool = ifs.seed_tris == 144 and is_equal_approx(cube_far, FractalIFS.SEED_HALF)
	_defaults(ifs)
	_ok("seed", all_ok and exact, "%s (cube exact at %.4f, beam half-width %.3f past 1.0)" % [
		String(", ").join(lines), cube_far, FractalIFS.BEAM_HW])


## Winding, which only started mattering when the material stopped disabling back-face culling.
## Every triangle's geometric normal must agree with the normal its vertices carry, or half the
## faces of a frame would be culled away and the sculpture would read as full of holes. The
## control reverses one triangle and must be caught, or the test is measuring nothing.
func _winding(ifs: FractalIFS) -> void:
	var worst := 1.0
	var checked := 0
	var ctl := 1.0
	for kind in ["cube", "tetra", "octa"]:
		ifs.set_preset(_preset_of_seed(kind))
		var arr := ifs.seed_mesh.surface_get_arrays(0)
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var n: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
		for t in range(0, v.size(), 3):
			var face := (v[t + 1] - v[t]).cross(v[t + 2] - v[t])
			if face.length() < 1e-9:
				continue
			var dot := face.normalized().dot(n[t])
			worst = minf(worst, dot)
			# Control: the same triangle wound the other way.
			ctl = minf(ctl, (v[t + 2] - v[t]).cross(v[t + 1] - v[t]).normalized().dot(n[t]))
			checked += 1
	ifs.set_preset(0)
	_defaults(ifs)
	_ok("winding", worst > 0.999 and ctl < -0.999,
		"%d triangles, worst normal agreement %.6f, reversed control %.6f" % [checked, worst, ctl])


## The first preset that uses a given seed frame, so a seed test can reach a frame through the
## same set_preset the app uses rather than through a private door.
static func _preset_of_seed(kind: String) -> int:
	for i in FractalIFS.PRESETS.size():
		if String(FractalIFS.PRESETS[i]["seed"]) == kind:
			return i
	return 0


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


## FRAMES' child maps, in order, against the values written above rather than against the
## table they came from. Order is load-bearing downstream: the walk composes maps in this order
## and the published buffer inherits it, so a reordered list is a changed sculpture.
func _children(ifs: FractalIFS) -> void:
	var maps := FractalIFS.child_maps(Vector3(1, 0, 0), 0.0, Vector3(0, 1, 0), 0.0,
		FractalIFS.PRESETS[0]["maps"])
	var off_err := 0.0
	var basis_err := 0.0
	var det_err := 0.0
	var mirrored := 0
	for i in mini(maps.size(), FRAMES_CHILDREN.size()):
		var m: Transform3D = maps[i]
		var want: Array = FRAMES_CHILDREN[i]
		off_err = maxf(off_err, (m.origin - (want[0] as Vector3)).length())
		var signs: Vector3 = want[1]
		for k in 3:
			basis_err = maxf(basis_err,
				(FractalIFS._col(m.basis, k) - FractalIFS.AXIS[k] * (0.35 * signs[k])).length())
		det_err = maxf(det_err, absf(absf(m.basis.determinant()) - pow(0.35, 3)))
		if m.basis.determinant() < 0.0:
			mirrored += 1
	# Four of the eight children mirror, which is why the seed's shade is keyed by axis rather
	# than by facing: a mirrored frame has to read like its original under back-face culling.
	var pass_ := maps.size() == 8 and off_err < EPS and basis_err < EPS and det_err < EPS \
		and mirrored == 4
	_ok("child maps", pass_, "n=%d offset err=%.9f basis err=%.9f |det| err=%.9f mirrored=%d" % [
		maps.size(), off_err, basis_err, det_err, mirrored])


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
	var params_held: bool = ifs.depth == 1.0 and ifs.plane1_offset == 0.0 \
		and ifs.preset == 0 and float(ifs.base[0][0]) == 0.35
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


## Every preset at rungs 0..3, against the counts written at the top of this file. A preset
## whose branching factor drifted, or whose seed frame changed triangle count, shows up here as
## a number and not as a picture nobody looked at.
func _presets(ifs: FractalIFS) -> void:
	var lines := PackedStringArray()
	var all_ok := true
	for i in FractalIFS.PRESETS.size():
		var name_ := FractalIFS.preset_name(i)
		var want: Array = PRESET_COUNTS[name_]
		var got: Array[int] = []
		for d in 4:
			ifs.set_preset(i)
			_planes(ifs)
			ifs.detail = d
			got.append(ifs.build())
		var counts_ok := true
		for d in 4:
			counts_ok = counts_ok and got[d] == int(want[d])
		var tris_ok: bool = ifs.seed_tris == int(PRESET_TRIS[name_])
		# The rung the preset opens at has to be one the DETAIL tile can show, and has to land
		# somewhere a headset can rebuild. Both are the point of the field existing.
		var open: int = int(FractalIFS.PRESETS[i]["detail"])
		var open_ok: bool = open >= 1 and open <= 4 and int(want[open]) >= 500 \
			and int(want[open]) <= 3000
		var drag: int = int(FractalIFS.PRESETS[i]["drag"])
		var drag_ok: bool = drag >= 1 and drag <= open and int(want[drag]) <= 600
		all_ok = all_ok and counts_ok and tris_ok and open_ok and drag_ok
		lines.append("%s %s seed=%d tri opens at %d (%d frames) drags at %d (%d)" % [
			name_, str(got), ifs.seed_tris, open, int(want[open]), drag, int(want[drag])])
	_defaults(ifs)
	_ok("preset counts", all_ok, String(" | ").join(lines))


## Bounds containment for every preset at its own opening rung, plus the shrunk-box control, so
## a frame whose beams are not axis-aligned cannot hide outside a bound that was derived from a
## cube's half-extent.
func _preset_bounds(ifs: FractalIFS) -> void:
	var worst := 0.0
	var worst_name := "none"
	var all_ok := true
	var ctl := INF
	for i in FractalIFS.PRESETS.size():
		ifs.set_preset(i)
		_planes(ifs)
		ifs.build()
		var out := _worst_escape(ifs, ifs.bounds)
		if out > worst:
			worst = out
			worst_name = FractalIFS.preset_name(i)
		all_ok = all_ok and out < 1e-4
		var shrunk := AABB(ifs.bounds.position + ifs.bounds.size * 0.05, ifs.bounds.size * 0.9)
		ctl = minf(ctl, _worst_escape(ifs, shrunk))
	_defaults(ifs)
	_ok("preset bounds", all_ok and ctl > 1e-2,
		"%d presets at their own rung, worst escape %.9f (%s), weakest shrunk-box control %.4f" % [
			FractalIFS.PRESETS.size(), worst, worst_name, ctl])


## Every preset driven past MAX_DETAIL at every plane extreme the editor allows. A cap has to
## hand back a whole level whatever the branching factor is; STAR gives up a whole rung earlier
## than the rest because twelve children per level reach the instance ceiling sooner.
func _preset_caps(ifs: FractalIFS) -> void:
	var lines := PackedStringArray()
	var all_ok := true
	for i in FractalIFS.PRESETS.size():
		var name_ := FractalIFS.preset_name(i)
		var want_cap: int = int(PRESET_CAP[name_])
		var worst_n := 0
		var worst_tri := 0
		var ok := true
		for case in _cases():
			ifs.set_preset(i)
			_planes(ifs)
			_apply(ifs, case[1])
			ifs.detail = FractalIFS.MAX_DETAIL
			ifs.build()
			worst_n = maxi(worst_n, ifs.instance_count)
			worst_tri = maxi(worst_tri, ifs.triangle_count)
			ok = ok and ifs.instance_count == want_cap and ifs.cap_note != "" \
				and ifs.instance_count <= FractalIFS.MAX_INSTANCES \
				and ifs.triangle_count <= FractalIFS.MAX_TRIANGLES
		all_ok = all_ok and ok
		lines.append("%s %d/%d inst %d tri" % [name_, worst_n, want_cap, worst_tri])
	_defaults(ifs)
	_ok("preset caps", all_ok, "at detail %d over %d cases each: %s" % [
		FractalIFS.MAX_DETAIL, _cases().size(), String(", ").join(lines)])


## Preset 0 after a full trip round the gallery. Nothing a preset loads may outlive it, so the
## buffer FRAMES publishes on the way back has to be the one it published on the way out. The
## control is a different preset's buffer, which must not match.
func _round_trip(ifs: FractalIFS) -> void:
	_defaults(ifs)
	ifs.build()
	var first: PackedFloat32Array = ifs.get_node("Frames").multimesh.buffer
	var first_tris := ifs.seed_tris
	var other := PackedFloat32Array()
	for i in range(1, FractalIFS.PRESETS.size()):
		ifs.set_preset(i)
		_planes(ifs)
		ifs.build()
		if i == 1:
			other = ifs.get_node("Frames").multimesh.buffer
	_defaults(ifs)
	ifs.build()
	var back: PackedFloat32Array = ifs.get_node("Frames").multimesh.buffer
	_ok("preset round trip", first == back and first != other and ifs.seed_tris == first_tris,
		"%d presets visited, FRAMES identical on return=%s, seed %d tri, control differs=%s" % [
			FractalIFS.PRESETS.size(), str(first == back), ifs.seed_tris, str(first != other)])


## The palette ramp the shader samples. N palette entries have to land on the N sample points
## i/N, and the two ends have to match, because the colour coordinate scrolls and an open ramp
## would drift through a seam once a cycle. The control is a second palette, which must move
## every stop it touches.
##
## Sampled from the Gradient the texture is generated from, not from its texels: the headless
## driver hands back no image for a generated texture. That the ramp reaches the GPU at all is
## ifs_shot's colour drift capture, which is a picture of this texture being sampled.
func _ramp(ifs: FractalIFS) -> void:
	_defaults(ifs)
	var pal := [Color(0.9, 0.2, 0.1), Color(0.2, 0.8, 0.3), Color(0.1, 0.3, 0.9),
		Color(0.9, 0.9, 0.2), Color(0.5, 0.1, 0.6)]
	ifs.set_palette(pal)
	var tex := ifs.ramp_texture()
	var g: Gradient = tex.gradient
	var worst := 0.0
	var firsts: PackedColorArray = PackedColorArray()
	for i in pal.size():
		var c := g.sample(float(i) / float(pal.size()))
		firsts.append(c)
		var want: Color = pal[i]
		worst = maxf(worst, absf(c.r - want.r) + absf(c.g - want.g) + absf(c.b - want.b))
	var a := g.sample(0.0)
	var b := g.sample(1.0)
	var ends := absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b)
	# Control: a different palette through the same call has to move every stop.
	ifs.set_palette([Color(0.05, 0.05, 0.05), Color(0.1, 0.1, 0.1)])
	var moved := 10.0
	for i in pal.size():
		var c := g.sample(float(i) / float(pal.size()))
		var p0: Color = firsts[i]
		moved = minf(moved, absf(c.r - p0.r) + absf(c.g - p0.g) + absf(c.b - p0.b))
	ifs.set_palette([])
	var shaped: bool = tex.width == FractalIFS.RAMP_W and tex.use_hdr
	_ok("palette ramp", worst < 1e-4 and ends < 1e-6 and moved > 0.1 and shaped,
		"%d entries, worst stop err=%.7f, ends differ by %.7f, control moved every stop by >=%.4f, %d texels hdr=%s" % [
			pal.size(), worst, ends, moved, tex.width, str(tex.use_hdr)])


## What the shader reads per instance. The three custom-data channels must all land inside
## [0, 1] at every preset and every rung, or the colour coordinate and the grow-in clock walk
## off the ends of the palette and of the animation. The packed parent origin must decode back
## to the origin of the instance's actual parent: growing out of the wrong point would still
## animate, so a control that grows out of the instance's own centre has to fail the same test.
func _instance_data(ifs: FractalIFS) -> void:
	var lo := 2.0
	var hi := -1.0
	var worst := 1.0
	var ctl := 1.0
	var checked := 0
	var span_ok := true
	for pi in FractalIFS.PRESETS.size():
		ifs.set_preset(pi)
		_planes(ifs)
		for d in range(0, 4):
			ifs.detail = d
			ifs.build(false)
			var buf: PackedFloat32Array = ifs.get_node("Frames").multimesh.buffer
			var mat: ShaderMaterial = ifs.get_node("Frames").material_override
			var span := float(mat.get_shader_parameter("origin_span"))
			span_ok = span_ok and span > 0.0
			# Origins by level, so a parent can be looked for among the level above.
			# Plain Arrays, not packed ones: a packed array read back out of a Dictionary is
			# a copy, so appending to it would quietly leave every level empty.
			var by_level: Dictionary = {}
			for i in ifs.instance_count:
				var k: int = ifs.levels[i]
				if not by_level.has(k):
					by_level[k] = []
				(by_level[k] as Array).append(ifs.xforms[i].origin)
			for i in ifs.instance_count:
				var j := i * 20
				for c in range(16, 19):
					lo = minf(lo, buf[j + c])
					hi = maxf(hi, buf[j + c])
				for c in range(12, 15):
					lo = minf(lo, buf[j + c])
					hi = maxf(hi, buf[j + c])
				var k: int = ifs.levels[i]
				if k == 0:
					continue
				var packed := Vector3(buf[j + 12], buf[j + 13], buf[j + 14])
				var local := (packed - Vector3(0.5, 0.5, 0.5)) * (2.0 * span)
				worst = minf(worst, _nearest_in(ifs.xforms[i] * local, by_level[k - 1]))
				# Control: grow out of the instance's own centre instead.
				ctl = minf(ctl, _nearest_in(ifs.xforms[i].origin, by_level[k - 1]))
				checked += 1
	_defaults(ifs)
	var ranged: bool = lo >= -1e-6 and hi <= 1.0 + 1e-6
	_ok("instance data", ranged and span_ok and worst > -1e-4 and ctl < -1e-3,
		"%d instances, channels in [%.6f, %.6f], parent origin err=%.7f, own-centre control=%.4f" % [
			checked, lo, hi, -worst, -ctl])


## Negative distance from p to the nearest point in the list, so a perfect hit reads 0 and the
## comparisons above can take a minimum over every instance.
static func _nearest_in(p: Vector3, pts: Array) -> float:
	var best := INF
	for q in pts:
		best = minf(best, p.distance_to(q))
	return -best


## Breathing is an offset applied at build time. It has to change what is drawn, stop dead when
## a handle is captured, leave `base` untouched, and hand back the banked buffer byte for byte
## the moment it is switched off.
func _ambient(ifs: FractalIFS) -> void:
	_defaults(ifs)
	ifs.build(false)
	var banked: PackedFloat32Array = ifs.get_node("Frames").multimesh.buffer
	var base_before: Array = ifs.base.duplicate(true)
	ifs.ambient = true
	ifs.breathe_t = 0.0
	ifs.tick(7.0)
	var breathing: PackedFloat32Array = ifs.get_node("Frames").multimesh.buffer
	var t_held := ifs.breathe_t
	# A captured handle stops the clock without changing the state, so nothing moves and
	# nothing jumps when it is released.
	ifs.ambient_hold = true
	ifs.tick(5.0)
	var held: PackedFloat32Array = ifs.get_node("Frames").multimesh.buffer
	ifs.ambient_hold = false
	var maps_differ: bool = not _maps_same(ifs.live_base(), ifs.base, 1e-9)
	ifs.ambient = false
	ifs.build(false)
	var back: PackedFloat32Array = ifs.get_node("Frames").multimesh.buffer
	var untouched: bool = _maps_same(ifs.base, base_before, 0.0)
	_defaults(ifs)
	_ok("breathing", breathing != banked and held == breathing and back == banked
			and untouched and maps_differ and is_equal_approx(ifs.breathe_t, 0.0),
		("moved=%s held still at t=%.1f=%s off restores exactly=%s stored maps untouched=%s "
			+ "live maps offset=%s") % [str(breathing != banked), t_held,
			str(held == breathing), str(back == banked), str(untouched), str(maps_differ)])


## The morph's two ends and its middle. t=0 has to be the source rule padded to the common
## length, t=1 has to be the target's own table entry down to the byte, the seed frame has to
## change at the midpoint and not before, and a second step part way through has to carry on
## from where the shape is rather than snapping back to the rule it started from.
func _morph(ifs: FractalIFS) -> void:
	_defaults(ifs)
	ifs.build(false)
	var src: Array = ifs.base.duplicate(true)
	var tris_before := ifs.seed_tris
	ifs.begin_morph(1)
	var at_zero: bool = _maps_same(ifs.live_maps(), src, 1e-9)
	# Just short of halfway: the seed frame is still the one it started with.
	ifs.tick(FractalIFS.MORPH_S * 0.49)
	var early_seed := ifs.seed_tris
	ifs.tick(FractalIFS.MORPH_S * 0.02)
	var mid_seed := ifs.seed_tris
	var guard := 0
	while ifs.is_morphing() and guard < 200:
		ifs.tick(0.1)
		guard += 1
	var landed: PackedFloat32Array = ifs.get_node("Frames").multimesh.buffer
	var landed_preset := ifs.preset
	var landed_detail := ifs.detail
	# Independent reference: a second node told to be TETRA outright, never morphed into it.
	var ref := FractalIFS.new()
	root.add_child(ref)
	ref.set_preset(1)
	_planes(ref)
	ref.build(false)
	var want: PackedFloat32Array = ref.get_node("Frames").multimesh.buffer
	var ref_detail := ref.detail
	ref.queue_free()

	# Retarget. Half way from FRAMES to STAR, step again to CROSS: the new morph must start
	# from the interpolated maps, which are neither FRAMES' nor STAR's.
	_defaults(ifs)
	ifs.build(false)
	ifs.begin_morph(2)
	ifs.tick(FractalIFS.MORPH_S * 0.5)
	var mid_maps: Array = ifs.live_maps().duplicate(true)
	ifs.begin_morph(3)
	var after: Array = ifs.live_maps()
	var padded_src: Array = FractalIFS._pad(src, mid_maps.size())
	var continuous: bool = _maps_same(after, mid_maps, 1e-9) 		and not _maps_same(mid_maps, padded_src, 1e-4)
	_defaults(ifs)
	ifs.build(false)
	_ok("morph ends", at_zero and landed == want and landed_preset == 1
			and landed_detail == ref_detail and tris_before == 144 and early_seed == 144
			and mid_seed == 72,
		("t=0 is the source=%s, t=1 identical to a plain TETRA build=%s (preset %d, rung %d), "
			+ "seed %d -> %d at 0.49, %d at 0.51") % [str(at_zero), str(landed == want),
			landed_preset, landed_detail, tris_before, early_seed, mid_seed])
	_ok("morph retarget", continuous,
		"%d maps, second step continues from the interpolated state=%s, differs from the source=%s" % [
			mid_maps.size(), str(_maps_same(after, mid_maps, 1e-9)),
			str(not _maps_same(mid_maps, padded_src, 1e-4))])


## Two base-map lists the same, to a tolerance. A shorter list is padded the way a morph pads
## it, so a 2-map rule and its 3-map padding compare equal.
static func _maps_same(a: Array, b: Array, eps: float) -> bool:
	var n := maxi(a.size(), b.size())
	if n == 0:
		return a.size() == b.size()
	var pa: Array = FractalIFS._pad(a, n)
	var pb: Array = FractalIFS._pad(b, n)
	for i in n:
		if absf(float(pa[i][0]) - float(pb[i][0])) > eps:
			return false
		if (pa[i][1] as Vector3).distance_to(pb[i][1] as Vector3) > eps:
			return false
		if (pa[i][2] as Vector3).distance_to(pb[i][2] as Vector3) > eps:
			return false
	return true


func _clearance(ifs: FractalIFS) -> void:
	_defaults(ifs)
	ifs.build()
	var c: float = float(ifs.base[0][0])
	# FRAMES only: the nearest beam to the centre is a generation-1 beam lying along one axis at
	# (offset - c) on the other two, ending at (offset - c * SEED_HALF). Its capsule radius
	# is both short half-extents of the beam.
	var off: Vector3 = ifs.base[0][1]
	var end_: float = off.x - c * FractalIFS.SEED_HALF
	var lat: float = off.x - c
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
		# Through the beam's own frame, not as an axis-aligned box: a tetrahedron edge runs
		# diagonally, and walking it as if it were axis-aligned would test a shape nothing draws.
		var b: Basis = beam[2]
		for sx in [-1.0, 1.0]:
			for sy in [-1.0, 1.0]:
				for sz in [-1.0, 1.0]:
					corners.append(c + b.x * (h.x * sx) + b.y * (h.y * sy) + b.z * (h.z * sz))
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
	ifs.set_preset(0)
	_planes(ifs)
	ifs.detail = 3
	# The ambient state too, or a section that leaves the sculpture breathing hands the next
	# one a shape that is not the one it thinks it is asking about.
	ifs.ambient = false
	ifs.ambient_hold = false
	ifs.anim_t = 0.0
	ifs.breathe_t = 0.0


## The parameters the two handles own, back where they start. Separate from _defaults, because
## a preset sweep needs the planes reset without also being dragged back to preset 0.
func _planes(ifs: FractalIFS) -> void:
	ifs.plane1_normal = FractalIFS.DEFAULT_N1
	ifs.plane2_normal = FractalIFS.DEFAULT_N2
	ifs.plane1_offset = 0.0
	ifs.plane2_offset = 0.0
	ifs.depth = 1.0
