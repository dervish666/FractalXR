extends Node3D
class_name FlameEchoes

## Flame ECHOES: a few copies of the living flame hung around the room, small lanterns near and
## large ones far out, so the space reads as more of the same fractal. View only, and still:
## nothing here moves, because motion in the periphery is the comfort rule ifs_echoes.gd set
## and Sam agreed to. The flame inside each one lives, since it is the hero's own particles.
##
## THE DRAW. Each echo is the hero's point material (ParticleCloud.point_material(), the same
## instance) on a smaller vertex buffer. points.gdshader reads the live state image by
## VERTEX_ID, so an echo needs no copy of anything: every morph, palette, band and brightness
## change reaches it for free. The instance uniforms echo_stride and echo_offset make it draw a
## block-strided sample of the whole cloud, and echo_gain pays back the particles it skips.
## Additive points need no sort, so a copy really is one more draw.
##
## THE COST is vertices. README phase 2 found the point path vertex-bound (707,788 points,
## 1.4M vertex fetches over two eyes; resolution and point size barely moved it), so an echo
## costs its point count and almost nothing for its screen size. All echoes together are held
## to POINTS_MAX, a quarter of the hero's default 1.05M. Off-screen echoes are frustum-culled
## by their own box. A baked impostor would be cheaper still for the far ones, but it would be
## a still picture of a flame that is otherwise alive, so it was not done.
##
## A child of the cloud, top_level, so the grab leaves it where it is; place() anchors it to
## the head when it is switched on and on every recentre. It hides itself whenever the cloud is
## not drawing a flame as points (bulb, splats, ground, tree, IFS), so no host has to.

## Echo counts. Each is a prefix of the next, so stepping up adds echoes without moving any.
const STEPS := [0, 4, 8]
const STEP_NAMES := ["off", "four", "eight"]
## The cap. Every echo is a draw call and its points; this is the most there can be.
const MAX_ECHOES := 8
## Points over all echoes together, about a quarter of the hero's default 1.05M.
const POINTS_MAX := 262144
## Vertex buffers come in these sizes (multiples of the shader's 64-particle blocks), so the
## echoes share a handful of meshes. The largest is the most any one echo draws.
const TIERS := [16384, 32768, 65536, 131072]
const SEED := 20261010
## Size as a multiple of the hero as it arrives (RMS radius 1 m at 2.6 m), power law between the
## two, so a few large ones sit among smaller ones.
const S_MIN := 0.3
const S_MAX := 5.0
const SIZE_D := 1.0
## Distance grows with size, d = D_MIN * (s / S_MIN)^DIST_POW, jittered: a lantern hangs a few
## metres off and a giant 20-40 m out, so a big one reads as big and not as close.
const D_MIN := 3.0
const D_MAX := 45.0
const DIST_POW := 0.6
const DIST_JITTER := Vector2(0.85, 1.5)
## Comfort, as ifs_echoes.gd holds it: nothing within HEAD_CLEAR of the eyes, nothing within
## FLOOR_CLEAR of the floor, nothing inside SIGHT_CONE of the line to the hero.
const HEAD_CLEAR := 1.2
const FLOOR_CLEAR := 0.3
const SIGHT_CONE_DEG := 28.0
## Elevation band, as sin(elevation): from just under the eye line to high overhead.
const ELEV_SIN := Vector2(-0.1, 0.85)
const FRONT_SHARE := 0.75
const FRONT_HALF := PI * 0.6
## An echo's comfort sphere in its own RMS radii. A flame's points thin out past twice the RMS
## radius; the few beyond are single pixels.
const REACH_RMS := 1.6
## Far echoes dimmer, so the hero stays the brightest thing in view.
const GAIN_NEAR := 0.85
const GAIN_FAR := 0.5
## How far echo_gain may go to pay back skipped particles. Past this a sparse echo would read
## as a few bright sparks rather than a dim flame.
const GAIN_MAX := 6.0
## The hero's angular RMS radius as it arrives: 1 m at main.gd's HOME_DISTANCE.
const HERO_ANGLE := 1.0 / 2.6
## Culling box half-size, in cloud units. The framing puts the RMS radius at 1 or less.
const BOUND := 4.0
const TRIES := 400

var step := 0
## Set by GALAXY: inside a 30 m flame the room's lanterns are clutter.
var suppressed := false
## One record per placed echo: pos and basis in the anchor's frame, size s, distance d, comfort
## radius r, shell gain. Published for the checks.
var placements: Array = []
## Per visible echo: the tier it draws and the gain it was given, for the checks and the HUD.
var drawn: Array = []
var _cloud: ParticleCloud
var _nodes: Array[MeshInstance3D] = []
var _meshes := {}
var _hero_count := -1
var _placed := false


func _init() -> void:
	name = "FlameEchoes"
	top_level = true
	visible = false


func setup(cloud: ParticleCloud) -> void:
	_cloud = cloud
	for i in MAX_ECHOES:
		var m := MeshInstance3D.new()
		m.name = "Echo%d" % i
		m.material_override = cloud.point_material()
		m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		m.custom_aabb = AABB(-Vector3.ONE * BOUND, Vector3.ONE * BOUND * 2.0)
		m.visible = false
		add_child(m)
		_nodes.append(m)


func count() -> int:
	return mini(int(STEPS[step]), placements.size()) if _placed else 0


func step_name() -> String:
	return String(STEP_NAMES[step])


func is_placed() -> bool:
	return _placed


func set_step(i: int) -> void:
	step = wrapi(i, 0, STEPS.size())
	_apply()


## Points the visible echoes draw, all together.
func point_total() -> int:
	var n := 0
	for d in drawn:
		n += int(d["points"])
	return n


## Hang the echoes around an anchor at the head, yaw only. `floor_y` is the floor in the
## anchor's frame and `hero` the hero's centre in it, for the sight cone.
func place(anchor: Transform3D, floor_y: float, hero: Vector3) -> void:
	global_transform = anchor
	placements = layout(ceilf(floor_y * 10.0 - 1e-4) / 10.0, hero)
	_placed = true
	for i in _nodes.size():
		if i < placements.size():
			var p: Dictionary = placements[i]
			_nodes[i].transform = Transform3D((p["basis"] as Basis).scaled(Vector3.ONE * float(p["s"])),
				p["pos"] as Vector3)
	_hero_count = -1
	_apply()


func _process(_delta: float) -> void:
	if _cloud == null:
		return
	var show := count() > 0 and not suppressed and _cloud.flame_drawn()
	if show != visible:
		visible = show
	if show and _cloud.get_count() != _hero_count:
		_apply()


## Which echoes draw, and from how many of the hero's particles. Runs on a count change, a
## placement or a step, never per frame.
func _apply() -> void:
	var n := count()
	for i in _nodes.size():
		_nodes[i].visible = i < n
	drawn = []
	if _cloud == null or n == 0:
		return
	_hero_count = _cloud.get_count()
	var hero_blocks := _hero_count / 64
	# Points that would give each echo the hero's own density on screen: the hero's count
	# times the ratio of their apparent areas.
	var want: Array[float] = []
	var tier: Array[int] = []
	for i in n:
		var p: Dictionary = placements[i]
		var a := float(p["s"]) / float(p["d"]) / HERO_ANGLE
		want.append(float(_hero_count) * a * a)
		var t := 0
		while t + 1 < TIERS.size() and TIERS[t + 1] <= want[i]:
			t += 1
		tier.append(t)
	# Over budget: step down whichever echo a step hurts least, the one that would still be
	# nearest the hero's density. Cutting the biggest draw first starved the giants, which
	# need the points most, and left them as faint ghosts beside crisp lanterns.
	while true:
		var total := 0
		var pick := -1
		var pick_need := INF
		for i in n:
			total += TIERS[tier[i]]
			if tier[i] > 0:
				var need: float = want[i] / float(TIERS[tier[i] - 1])
				if need < pick_need:
					pick_need = need
					pick = i
		if total <= POINTS_MAX or pick < 0:
			break
		tier[pick] -= 1
	for i in n:
		var pts: int = mini(TIERS[tier[i]], hero_blocks * 64)
		var stride := maxi(1, hero_blocks / maxi(1, pts / 64))
		var m := _nodes[i]
		m.mesh = _mesh(pts)
		var p: Dictionary = placements[i]
		var gain := float(p["gain"]) * clampf(want[i] / float(pts), 1.0 / GAIN_MAX, GAIN_MAX)
		m.set_instance_shader_parameter(&"echo_stride", stride)
		# A different run of blocks per echo, so neighbours do not share a noise pattern.
		m.set_instance_shader_parameter(&"echo_offset", (i * 7919) % stride)
		m.set_instance_shader_parameter(&"echo_gain", gain)
		drawn.append({"points": pts, "stride": stride, "gain": gain})


## A bare vertex buffer of n points, shared by every echo of that size. points.gdshader
## indexes the state image by VERTEX_ID, so the buffer carries nothing but its length.
func _mesh(n: int) -> ArrayMesh:
	if _meshes.has(n):
		return _meshes[n]
	var verts := PackedVector3Array()
	verts.resize(n)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_POINTS, arrays)
	mesh.custom_aabb = AABB(-Vector3.ONE * BOUND, Vector3.ONE * BOUND * 2.0)
	_meshes[n] = mesh
	return mesh


## The placement, pure and seeded. Two groups, so FOUR is exactly the first half of EIGHT.
static func layout(floor_y: float, hero: Vector3) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	var out: Array = []
	var hero_dir := hero.normalized() if hero.length() > 1e-4 else Vector3.FORWARD
	var prev := 0
	for c in STEPS:
		var g := int(c) - prev
		if g <= 0:
			continue
		prev = int(c)
		var sizes: Array[float] = []
		for k in g:
			sizes.append(size_at((float(k) + rng.randf()) / float(g)))
		sizes.sort()
		sizes.reverse()
		for s in sizes:
			var rec := _fit(rng, s, floor_y, hero_dir, out)
			if not rec.is_empty():
				out.append(rec)
	return out


static func size_at(q: float) -> float:
	var lo := 1.0 - pow(S_MIN / S_MAX, SIZE_D)
	return S_MIN * pow(1.0 - clampf(q, 0.0, 1.0) * lo, -1.0 / SIZE_D)


static func _fit(rng: RandomNumberGenerator, s: float, floor_y: float, hero_dir: Vector3,
		placed: Array) -> Dictionary:
	var r := s * REACH_RMS
	for t in TRIES:
		var d := clampf(D_MIN * pow(s / S_MIN, DIST_POW) * rng.randf_range(DIST_JITTER.x, DIST_JITTER.y),
			D_MIN, D_MAX)
		var az := rng.randf_range(-PI, PI)
		if rng.randf() < FRONT_SHARE:
			az = rng.randf_range(-FRONT_HALF, FRONT_HALF)
		var y := rng.randf_range(ELEV_SIN.x, ELEV_SIN.y)
		var h := sqrt(1.0 - y * y)
		var pos := Vector3(sin(az) * h, y, -cos(az) * h) * d
		var axis := Vector3(rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0),
			rng.randf_range(-1.0, 1.0))
		if axis.length() < 1e-3:
			axis = Vector3.UP
		var basis := Basis(axis.normalized(), rng.randf_range(0.0, TAU))
		if violates(pos, r, floor_y, hero_dir, placed):
			continue
		var shell := clampf(log(d / D_MIN) / log(D_MAX / D_MIN), 0.0, 1.0)
		return {"pos": pos, "basis": basis, "s": s, "d": d, "r": r,
			"gain": lerpf(GAIN_NEAR, GAIN_FAR, shell)}
	return {}


## Every comfort rule as one predicate, so a check can hand it a bad placement.
static func violates(pos: Vector3, r: float, floor_y: float, hero_dir: Vector3, placed: Array) -> bool:
	var d := pos.length()
	if d - r < HEAD_CLEAR:
		return true
	if pos.y - r < floor_y + FLOOR_CLEAR:
		return true
	var off := rad_to_deg(pos.normalized().angle_to(hero_dir))
	if off < SIGHT_CONE_DEG + rad_to_deg(asin(clampf(r / d, 0.0, 1.0))):
		return true
	for q in placed:
		var lim := (r + float(q["r"])) * 1.1
		if pos.distance_squared_to(q["pos"] as Vector3) < lim * lim:
			return true
	return false
