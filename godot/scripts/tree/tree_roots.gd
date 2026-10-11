extends RefCounted
class_name TreeRoots

## ROOTS (forest.gd, the avenue's inner rows): surface roots from each trunk, bent toward the
## path, so the two rows' roots edge a dark walk down the middle.
##
## Same idea as the branches, laid on the floor: a fan of main roots leaves the trunk base on
## the path side, each a chain of tapering cylinders that hugs the ground in low arches, turns
## further toward the path at every segment, and throws a rootlet or two. The instances use the
## branch layout (basis, colour, custom = birth, taper, level, phase), so a tree draws its
## roots with its own branch material: they grow out with the trunk (births in the first
## third of the growth), take the trunk's colour (height is ~0), and never sway (the sway is
## quadratic in height).
##
## Shared, not built per tree. VARIANTS shapes are generated once, in a unit frame (trunk at
## the origin, the path along +X, the furthest tip at x = REACH), each a MultiMesh resource that
## every rooted tree points its Roots node at. forest.gd turns and scales that node so the tips
## stop ROOT_CLEAR short of the centre line: a recycle in the walk is one transform, no build.

const VARIANTS := 8
const REACH := 1.0
const STRIDE := 20

static var _lib: Array = []


## The shared shape for a seed: {"mm": MultiMesh, "tips": PackedVector3Array (unit frame),
## "aabb": AABB, "count": int, "top": the highest segment end above the floor}.
static func shape(seed_value: int) -> Dictionary:
	if _lib.is_empty():
		for v in VARIANTS:
			_lib.append(_build(v))
	return _lib[posmod(seed_value, VARIANTS)]


static func _build(v: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7717 + v * 131
	var segs: Array = []   # [from, to, r0, r1, birth, level]
	var tips := PackedVector3Array()
	var mains := rng.randi_range(7, 9)
	for m in mains:
		# Spread all the way along the row as well as toward the path, so a tree's outer roots
		# run out to meet its neighbours' (3-4 m away) before they turn in: the edge reads as one
		# woven kerb, not a claw per tree. The middle ones reach furthest.
		var a := lerpf(-1.6, 1.6, (float(m) + 0.5) / float(mains)) + rng.randf_range(-0.1, 0.1)
		var reach := REACH * lerpf(0.75, 1.0, cos(a * 0.6)) * rng.randf_range(0.9, 1.0)
		_root(segs, tips, rng, Vector3(cos(a), 0.0, sin(a)) * 0.07 + Vector3(0.0, 0.14, 0.0),
			Vector3(cos(a), -0.35, sin(a)).normalized(), reach, 0.045, 0.0, 0, true)
	# Scale so the furthest tip toward the path sits at exactly x = REACH.
	var far := 0.0
	for t in tips:
		far = maxf(far, t.x)
	var k := REACH / maxf(far, 1e-3)
	var buf := PackedFloat32Array()
	buf.resize(segs.size() * STRIDE)
	var lo := Vector3(INF, INF, INF)
	var hi := -lo
	for i in segs.size():
		var s: Array = segs[i]
		var a: Vector3 = s[0] * k
		var b: Vector3 = s[1] * k
		var d := b - a
		var ln := d.length()
		var dir := d / maxf(ln, 1e-5)
		var r: float = s[2] * k
		var xv := dir.cross(Vector3.FORWARD if absf(dir.z) < 0.9 else Vector3.RIGHT).normalized()
		var zv := xv.cross(dir).normalized()
		var basis := Basis(xv * r, dir * ln, zv * r)
		var o := (a + b) * 0.5
		var w := i * STRIDE
		buf[w + 0] = basis.x.x; buf[w + 1] = basis.y.x; buf[w + 2] = basis.z.x; buf[w + 3] = o.x
		buf[w + 4] = basis.x.y; buf[w + 5] = basis.y.y; buf[w + 6] = basis.z.y; buf[w + 7] = o.y
		buf[w + 8] = basis.x.z; buf[w + 9] = basis.y.z; buf[w + 10] = basis.z.z; buf[w + 11] = o.z
		buf[w + 12] = float(s[5]); buf[w + 13] = 0.0; buf[w + 14] = 0.0; buf[w + 15] = 1.0
		buf[w + 16] = float(s[4]); buf[w + 17] = float(s[3]) / maxf(float(s[2]), 1e-5)
		buf[w + 18] = float(s[5]); buf[w + 19] = rng.randf() * TAU
		lo = lo.min(a).min(b)
		hi = hi.max(a).max(b)
	for i in tips.size():
		tips[i] = tips[i] * k
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = FractalTree.unit_meshes()[0]
	mm.instance_count = segs.size()
	mm.buffer = buf
	return {"mm": mm, "tips": tips, "aabb": AABB(lo, hi - lo).grow(0.1), "count": segs.size(),
		"top": hi.y}


## One root: a chain that dips to the floor, then runs along it in low arches, turning toward
## +X a little more each segment and tapering to a point; a main root throws rootlets.
static func _root(segs: Array, tips: PackedVector3Array, rng: RandomNumberGenerator, at: Vector3,
		dir: Vector3, reach: float, r: float, birth: float, depth: int, main: bool) -> void:
	var n := 5 if main else 3
	var step := reach / float(n)
	var p := at
	var d := dir
	for i in n:
		# Toward the path: the horizontal direction swings to +X by a share each segment.
		var flat := Vector3(d.x, 0.0, d.z).normalized()
		flat = flat.lerp(Vector3.RIGHT, 0.16 if main else 0.1).normalized()
		var y := 0.012 + 0.03 * absf(sin(float(i) * 1.7 + rng.randf() * 0.6)) if i > 0 else 0.03
		var q := p + flat * step * rng.randf_range(0.85, 1.1)
		q.y = y
		var r1 := r * 0.62
		var b1 := birth + 0.06
		segs.append([p, q, r, r1, birth, 0.1 + 0.05 * float(i + depth)])
		if main and (i == 1 or i == 3) and depth == 0:
			var side := 1.0 if rng.randf() < 0.5 else -1.0
			var ld := flat.rotated(Vector3.UP, side * rng.randf_range(0.45, 0.8))
			_root(segs, tips, rng, q, ld, reach * 0.4, r1 * 0.8, b1, 1, false)
		p = q
		d = flat
		r = r1
		birth = b1
	tips.append(p)
