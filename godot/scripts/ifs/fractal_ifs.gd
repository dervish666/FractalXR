extends Node3D
class_name FractalIFS

## A finite IFS assembly: one open cube frame repeated by two mirror planes and a pair of
## contracting corner maps. The eight child maps are {I, R1, R2, R2*R1} applied after each
## of B+ and B-, composed recursively from the seed, and drawn as a single MultiMesh.
##
## Construction space is [-1, 1] on each axis. The node transform belongs to world grab;
## DEPTH is a separate final Z stretch held outside it, so an outer scale cannot swallow it.
##
## Sits as a child of the ParticleCloud, following FractalTree, so grab and scale apply
## unchanged. Geometry is rebuilt synchronously by build(); nothing here runs per frame.

const BEAM_W := 0.06
const BEAM_HW := BEAM_W * 0.5
## Beams run the full edge and meet flush, so the frame reaches half a width past 1.0.
const SEED_HALF := 1.0 + BEAM_HW
const AXIS := [Vector3(1.0, 0.0, 0.0), Vector3(0.0, 1.0, 0.0), Vector3(0.0, 0.0, 1.0)]

## Rungs 1..4 are the ones a menu should offer. 5 exists so the caps have something to
## refuse: a check that never trips the cap has not tested it.
const MAX_DETAIL := 5
const MAX_INSTANCES := 8192
const MAX_TRIANGLES := 1000000
const DEPTH_MIN := 0.08
const DEPTH_MAX := 2.0
const DEFAULT_N1 := Vector3(1.0, 0.0, 0.0)
const DEFAULT_N2 := Vector3(0.0, 1.0, 0.0)

## Face shade baked into the seed's vertex colours, by axis. There is no light in the main
## scene and the material is unshaded, so without this the whole frame is one flat blob.
## Keyed by the axis and not the facing, so a mirrored copy shades like its original.
const AXIS_SHADE := [0.66, 1.0, 0.82]

var plane1_normal := DEFAULT_N1
var plane1_offset := 0.0
var plane2_normal := DEFAULT_N2
var plane2_offset := 0.0
var depth := 1.0
var detail := 3
var contraction := 0.35
var offset := Vector3(0.6, 0.6, 0.6)

## Published after build(). xforms already include the depth stretch.
var xforms: Array[Transform3D] = []
var levels := PackedInt32Array()
var bounds := AABB()
var instance_count := 0
var triangle_count := 0
var seed_tris := 0
var build_ms := 0.0
var levels_built := 0
var cap_note := ""
var rejected := 0

var seed_mesh: ArrayMesh
var beams: Array = []

var _mmi: MultiMeshInstance3D
var _mat: StandardMaterial3D
var _palette: Array = []


func _init() -> void:
	name = "IFS"
	beams = _seed_beams()
	seed_mesh = _build_seed()
	seed_tris = _triangles_of(seed_mesh)
	_mat = StandardMaterial3D.new()
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat.vertex_color_use_as_albedo = true
	# Half the child maps have a negative determinant. Godot flips the front face for a
	# mirrored MeshInstance3D but not per instance inside a MultiMesh, so back-face culling
	# would delete one frame in two. The beams are thin, so the extra fill is small.
	_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mmi = MultiMeshInstance3D.new()
	_mmi.name = "Frames"
	_mmi.material_override = _mat
	_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = seed_mesh
	_mmi.multimesh = mm
	add_child(_mmi)
	visible = false


## Rebuild for the current parameters. Synchronous and deterministic: same parameters in,
## identical buffer out. Returns the instance count.
func build() -> int:
	var t0 := Time.get_ticks_usec()
	rejected = 0
	cap_note = ""
	var n1 := plane1_normal
	var d1 := plane1_offset
	var n2 := plane2_normal
	var d2 := plane2_offset
	if not valid_plane(n1, d1):
		n1 = DEFAULT_N1
		d1 = 0.0
		rejected += 1
	if not valid_plane(n2, d2):
		n2 = DEFAULT_N2
		d2 = 0.0
		rejected += 1
	var c := clampf(contraction, 0.05, 0.9)
	var dep := clampf(depth, DEPTH_MIN, DEPTH_MAX)
	var maps := child_maps(n1.normalized(), d1, n2.normalized(), d2, c, offset)

	# Count before allocating and stop at the last level that fits whole. One fully
	# detailed corner beside seven coarse ones would read as a bug, not as a limit.
	var want := clampi(detail, 0, MAX_DETAIL)
	var total := 1
	var fit := 0
	var per_level := 1
	# Count with the real map list, not a constant beside it. Two sources of truth for the
	# branching factor let the cap agree with a walk that has stopped matching it.
	var branch := maps.size()
	for k in range(1, want + 1):
		per_level *= branch
		var next := total + per_level
		if next > MAX_INSTANCES or next * seed_tris > MAX_TRIANGLES:
			cap_note = "detail %d capped to level %d: level %d would need %d instances / %d triangles" % [
				want, k - 1, k, next, next * seed_tris]
			break
		total = next
		fit = k

	var stretch := Transform3D(Basis.from_scale(Vector3(1.0, 1.0, dep)), Vector3.ZERO)
	xforms = [stretch]
	levels = PackedInt32Array([0])
	var start := 0
	for k in range(1, fit + 1):
		var stop := xforms.size()
		for i in range(start, stop):
			for m in maps:
				xforms.append(xforms[i] * m)
				levels.append(k)
		start = stop
	levels_built = fit
	instance_count = xforms.size()
	triangle_count = instance_count * seed_tris

	var buf := PackedFloat32Array()
	buf.resize(instance_count * 16)
	var seed_box := AABB(Vector3.ONE * -SEED_HALF, Vector3.ONE * (2.0 * SEED_HALF))
	bounds = xforms[0] * seed_box
	for i in instance_count:
		var t: Transform3D = xforms[i]
		bounds = bounds.merge(t * seed_box)
		var b := t.basis
		var o := t.origin
		var j := i * 16
		buf[j + 0] = b.x.x; buf[j + 1] = b.y.x; buf[j + 2] = b.z.x; buf[j + 3] = o.x
		buf[j + 4] = b.x.y; buf[j + 5] = b.y.y; buf[j + 6] = b.z.y; buf[j + 7] = o.y
		buf[j + 8] = b.x.z; buf[j + 9] = b.y.z; buf[j + 10] = b.z.z; buf[j + 11] = o.z
		var col := level_colour(levels[i])
		buf[j + 12] = col.r; buf[j + 13] = col.g; buf[j + 14] = col.b; buf[j + 15] = col.a

	var mm := _mmi.multimesh
	mm.instance_count = 0
	mm.instance_count = instance_count
	if instance_count > 0:
		mm.buffer = buf
	# MultiMesh instances are not culled individually, and an auto AABB would be recomputed
	# from the buffer anyway. Publishing ours makes the bounds check mean something.
	_mmi.custom_aabb = bounds
	build_ms = float(Time.get_ticks_usec() - t0) * 0.001
	return instance_count


## Reject a plane we cannot reflect through: a zero normal gives a singular map and a
## non-finite one poisons every transform downstream of it.
static func valid_plane(n: Vector3, d: float) -> bool:
	return n.is_finite() and is_finite(d) and n.length() > 1e-4


## R(p) = p - 2 * (dot(n, p) - d) * n, as a transform so the basis reflects with the origin.
static func reflection(n: Vector3, d: float) -> Transform3D:
	var b := Basis(
		AXIS[0] - 2.0 * n.x * n,
		AXIS[1] - 2.0 * n.y * n,
		AXIS[2] - 2.0 * n.z * n)
	return Transform3D(b, 2.0 * d * n)


## The eight child maps: contract into a corner, then mirror. Reflecting after the offset is
## what spreads the children over the eight octants; reflecting first would stack them all
## in the same corner.
static func child_maps(n1: Vector3, d1: float, n2: Vector3, d2: float, c: float,
		off: Vector3) -> Array[Transform3D]:
	var r1 := reflection(n1, d1)
	var r2 := reflection(n2, d2)
	var rots: Array[Transform3D] = [Transform3D.IDENTITY, r1, r2, r2 * r1]
	var maps: Array[Transform3D] = []
	for sz in [1.0, -1.0]:
		var b := Transform3D(Basis.from_scale(Vector3(c, c, c)),
			Vector3(off.x, off.y, off.z * sz))
		for r in rots:
			maps.append(r * b)
	return maps


## Conservative distance from p to the nearest beam, for the Enter clearance test in IFS-4.
## Each beam is treated as a capsule around its long axis with the two short half-extents
## summed into the radius, which always contains the real box, so the answer never claims
## more room than there is.
func clear_radius_at(p: Vector3) -> float:
	var best := INF
	for i in xforms.size():
		var t: Transform3D = xforms[i]
		var b := t.basis
		for beam in beams:
			var a: int = beam[2]
			var h: Vector3 = beam[1]
			var half: Vector3 = _col(b, a) * h[a]
			var mid: Vector3 = t * (beam[0] as Vector3)
			var r := 0.0
			for k in 3:
				if k != a:
					r += _col(b, k).length() * h[k]
			best = minf(best, _point_to_segment(p, mid - half, mid + half) - r)
			if best <= 0.0:
				return 0.0
	return maxf(best, 0.0)


## Basis indexing returns a row in some engine versions and a column in others; the
## generated transforms only make sense column-wise, so say which we mean.
static func _col(b: Basis, i: int) -> Vector3:
	if i == 0:
		return b.x
	return b.y if i == 1 else b.z


static func _point_to_segment(p: Vector3, a: Vector3, b: Vector3) -> float:
	var ab := b - a
	var l2 := ab.length_squared()
	if l2 < 1e-12:
		return p.distance_to(a)
	var t := clampf((p - a).dot(ab) / l2, 0.0, 1.0)
	return p.distance_to(a + ab * t)


## Palette hook shaped like FractalTree.set_palette: an array of Colors, coarse to fine.
## Recolours in place, so a theme change never rebuilds geometry.
func set_palette(pal: Array) -> void:
	_palette = pal
	var mm := _mmi.multimesh
	for i in mm.instance_count:
		mm.set_instance_color(i, level_colour(levels[i]))


func level_colour(level: int) -> Color:
	if _palette.is_empty():
		return Color(0.82, 0.86, 0.95)
	var f := float(level) / float(maxi(levels_built, 1)) * float(_palette.size() - 1)
	var i0 := clampi(int(f), 0, _palette.size() - 1)
	var i1 := mini(i0 + 1, _palette.size() - 1)
	return Color(_palette[i0]).lerp(Color(_palette[i1]), f - float(i0))


func set_cull_disabled(on: bool) -> void:
	_mat.cull_mode = BaseMaterial3D.CULL_DISABLED if on else BaseMaterial3D.CULL_BACK


## [centre, half-extents, long axis] for the twelve edges of the cube.
static func _seed_beams() -> Array:
	var out: Array = []
	for a in 3:
		var u := (a + 1) % 3
		var v := (a + 2) % 3
		for su in [-1.0, 1.0]:
			for sv in [-1.0, 1.0]:
				var c := Vector3.ZERO
				c[u] = su
				c[v] = sv
				var h := Vector3(BEAM_HW, BEAM_HW, BEAM_HW)
				h[a] = SEED_HALF
				out.append([c, h, a])
	return out


func _build_seed() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for beam in beams:
		_add_box(st, beam[0], beam[1])
	# No index(): it merged corner vertices that different beams shade differently, and at
	# 144 triangles there is nothing worth saving.
	return st.commit()


func _add_box(st: SurfaceTool, c: Vector3, h: Vector3) -> void:
	for a in 3:
		var u := (a + 1) % 3
		var v := (a + 2) % 3
		var shade: float = AXIS_SHADE[a]
		for s in [1.0, -1.0]:
			var n: Vector3 = AXIS[a] * s
			var uu: Vector3 = AXIS[u] * (h[u] * s)
			var vv: Vector3 = AXIS[v] * h[v]
			var o: Vector3 = c + AXIS[a] * (h[a] * s)
			var quad := [o - uu - vv, o + uu - vv, o + uu + vv, o - uu + vv]
			for idx in [0, 1, 2, 0, 2, 3]:
				st.set_normal(n)
				st.set_color(Color(shade, shade, shade))
				st.add_vertex(quad[idx])


static func _triangles_of(m: ArrayMesh) -> int:
	var arr := m.surface_get_arrays(0)
	var idx = arr[Mesh.ARRAY_INDEX]
	if idx != null:
		return (idx as PackedInt32Array).size() / 3
	return (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
