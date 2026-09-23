extends Node3D
class_name IfsEchoes

## ECHOES: copies of the IFS sculpture scattered through the room at many sizes, so the space
## around the viewer reads as one more generation of the same fractal. View only. The hero in
## front stays the one thing that is grabbed and edited.
##
## Every echo draws with the hero's material and the hero's seed mesh, and its instances are a
## prefix of the hero's own buffer (FractalIFS.echo_multimesh), so an edit, a breath, a morph
## or a palette change reaches all of them from the one build() with no work here. Sharing the
## hero's MultiMesh outright was the first plan and it does work, but every echo would then
## draw every frame the hero does: 40 x 585 x 144 is 3.4M triangles at the default rung, and
## most of them would be beams far thinner than a pixel. A prefix caps an echo at two
## generations whatever DETAIL the hero is at.
##
## A child of the IFS node so it hides with it, but top_level, so the grab that moves and
## scales the hero leaves the room where it is. place() anchors it to the head when the mode
## opens or recentres, and nothing moves per frame: the echoes already breathe and twist with
## the shared buffer, and an extra drift in peripheral vision is motion nobody asked for.

## Echo counts, default first, as the other ladders open on their default. FEW is the default
## because Sam asked for this and it should be there when the mode opens, at the cost that
## fits whatever else the headset is doing; MANY waits for a measured frame time.
const STEPS := [16, 40, 0]
const STEP_NAMES := ["few", "many", "off"]
const MAX_ECHOES := 40
## Fixed, so the room is the same room every time the mode opens.
const SEED := 20260923
## Echo width as a multiple of the hero's. Power law between the two, N(>s) ~ s^-SIZE_D, so a
## few large echoes sit among many small ones, the way a fractal's parts are distributed.
## 0.2 and not smaller: at the 2 m minimum a 0.1x echo is 6 cm across and its beams are under
## half a pixel, which with MSAA off shimmers instead of reading as a sculpture.
const S_MIN := 0.2
const S_MAX := 2.0
const SIZE_D := 1.3
## Distance grows with size, d = D_MIN * (s / S_MIN)^DIST_POW, jittered. A small echo stays
## near enough to resolve and a large one goes far enough not to loom, and a large echo still
## looks larger than a small one, so the sizes read as sizes and not as perspective. 0.6 was
## tried first and pushed everything so far out that the room read as specks.
const D_MIN := 2.0
const D_MAX := 12.0
const DIST_POW := 0.45
const DIST_JITTER := Vector2(0.85, 1.6)
## Comfort. Nothing reaches within HEAD_CLEAR of the eyes, nothing comes within FLOOR_CLEAR of
## the floor, and no echo sits inside SIGHT_CONE of the line to the hero, so the one you are
## sculpting is never drawn over or behind a copy of itself.
const HEAD_CLEAR := 1.2
const FLOOR_CLEAR := 0.3
const SIGHT_CONE_DEG := 28.0
## Elevation band of the direction, as sin(elevation): a little below the eye line up to high
## overhead. Around and above, never underfoot.
const ELEV_SIN := Vector2(-0.25, 0.9)
## Three in four land in the front 216 degrees, where the empty view is; the rest are behind,
## found by turning round.
const FRONT_SHARE := 0.75
const FRONT_HALF := PI * 0.6
## An echo whose apparent width passes this many radians draws two generations, smaller ones
## one. 0.12 rad is about seven degrees, where a second-generation beam is near one pixel.
const TIER_ANGLE := 0.12
## Palette offset across the shell, in turns, so colour moves outward through the room the way
## it moves outward through the sculpture. Jitter keeps neighbours from matching. 0.5 was tried
## first and left the room one purple, because an echo draws only the inner generations and
## so only the inner end of the ramp.
const PHASE_SPAN := 0.8
const PHASE_JITTER := 0.06
## Far echoes dimmer, so the hero stays the brightest thing in view.
const GAIN_NEAR := 0.85
const GAIN_FAR := 0.5
const TRIES := 400

var step := 0
## One record per placed echo, in placement order: pos and basis in the anchor's frame, the
## width multiple, the distance, the tier and the two shader values. Published for the checks.
var placements: Array = []
var _ifs: FractalIFS
var _nodes: Array[MultiMeshInstance3D] = []


func _init() -> void:
	name = "Echoes"
	top_level = true


func setup(ifs: FractalIFS) -> void:
	_ifs = ifs
	for i in MAX_ECHOES:
		var m := MultiMeshInstance3D.new()
		m.name = "Echo%d" % i
		m.material_override = ifs.material()
		m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		m.visible = false
		add_child(m)
		_nodes.append(m)


func count() -> int:
	return mini(int(STEPS[step]), placements.size())


func step_name() -> String:
	return String(STEP_NAMES[step])


func set_step(i: int) -> void:
	step = wrapi(i, 0, STEPS.size())
	_apply()


## Frames drawn by the visible echoes, from what each tier holds right now. The hero's own
## instance_count is separate; the two together are what the GPU is asked for.
func instance_total() -> int:
	var n := 0
	for i in count():
		n += _ifs.echo_multimesh(int(placements[i]["tier"])).instance_count
	return n


## Scatter the echoes around an anchor at the head, yaw only. `floor_y` is the floor in the
## anchor's frame, `unit` the hero's metres per construction unit and `width_m` the hero's
## width in metres, so an echo of size s is s times the hero as it arrived. `hero` is the
## hero's centre in the anchor's frame, for the sight cone.
func place(anchor: Transform3D, floor_y: float, unit: float, width_m: float, hero: Vector3) -> void:
	global_transform = anchor
	placements = layout(floor_y, width_m, hero)
	for i in _nodes.size():
		var m := _nodes[i]
		if i >= placements.size():
			m.visible = false
			continue
		var p: Dictionary = placements[i]
		m.multimesh = _ifs.echo_multimesh(int(p["tier"]))
		m.transform = Transform3D((p["basis"] as Basis).scaled(Vector3.ONE * float(p["s"]) * unit),
			p["pos"] as Vector3)
		m.set_instance_shader_parameter(&"echo_phase", float(p["phase"]))
		m.set_instance_shader_parameter(&"echo_gain", float(p["gain"]))
	_apply()


func _apply() -> void:
	var n := count()
	for i in _nodes.size():
		_nodes[i].visible = i < n


func nodes() -> Array[MultiMeshInstance3D]:
	return _nodes


## The placement itself, pure and seeded, so a check can run it without a scene. Two groups:
## the first STEPS[0] echoes are placed on their own and the rest around them, so FEW is
## exactly the first part of MANY and stepping up adds echoes without moving any.
static func layout(floor_y: float, width_m: float, hero: Vector3) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	var out: Array = []
	var hero_dir := hero.normalized() if hero.length() > 1e-4 else Vector3.FORWARD
	var groups := [int(STEPS[0]), MAX_ECHOES - int(STEPS[0])]
	for g in groups:
		# Stratified quantiles, so even sixteen echoes span the whole size range.
		var sizes: Array[float] = []
		for k in g:
			sizes.append(size_at((float(k) + rng.randf()) / float(g)))
		# Largest first: they are the hardest to fit, and the small ones fill in around them.
		sizes.sort()
		sizes.reverse()
		for s in sizes:
			var rec := _fit(rng, s, floor_y, width_m, hero_dir, out)
			if not rec.is_empty():
				out.append(rec)
	return out


## Inverse CDF of the truncated power law, q in [0, 1] to a width multiple in [S_MIN, S_MAX].
static func size_at(q: float) -> float:
	var lo := 1.0 - pow(S_MIN / S_MAX, SIZE_D)
	return S_MIN * pow(1.0 - clampf(q, 0.0, 1.0) * lo, -1.0 / SIZE_D)


## Radius of the sphere that holds an echo of width multiple s. The frame is a cube of the
## hero's width at most, so half its diagonal.
static func radius_of(s: float, width_m: float) -> float:
	return s * width_m * 0.5 * sqrt(3.0)


static func _fit(rng: RandomNumberGenerator, s: float, floor_y: float, width_m: float,
		hero_dir: Vector3, placed: Array) -> Dictionary:
	var r := radius_of(s, width_m)
	for t in TRIES:
		var d := clampf(D_MIN * pow(s / S_MIN, DIST_POW) * rng.randf_range(DIST_JITTER.x, DIST_JITTER.y),
			D_MIN, D_MAX)
		var az := rng.randf_range(-PI, PI)
		if rng.randf() < FRONT_SHARE:
			az = rng.randf_range(-FRONT_HALF, FRONT_HALF)
		var y := rng.randf_range(ELEV_SIN.x, ELEV_SIN.y)
		var h := sqrt(1.0 - y * y)
		# Azimuth 0 is straight ahead, -Z, the way the anchor faces.
		var dir := Vector3(sin(az) * h, y, -cos(az) * h)
		var pos := dir * d
		var axis := Vector3(rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0),
			rng.randf_range(-1.0, 1.0))
		if axis.length() < 1e-3:
			axis = Vector3.UP
		var basis := Basis(axis.normalized(), rng.randf_range(0.0, TAU))
		if violates(pos, r, floor_y, hero_dir, placed):
			continue
		var shell := log(d / D_MIN) / log(D_MAX / D_MIN)
		return {
			"pos": pos, "basis": basis, "s": s, "d": d, "r": r,
			"tier": 1 if s * width_m / d >= TIER_ANGLE else 0,
			"phase": PHASE_SPAN * shell + rng.randf_range(-PHASE_JITTER, PHASE_JITTER),
			"gain": lerpf(GAIN_NEAR, GAIN_FAR, shell),
		}
	return {}


## Every comfort rule, as one predicate a check can also hand a bad placement to.
static func violates(pos: Vector3, r: float, floor_y: float, hero_dir: Vector3, placed: Array) -> bool:
	var d := pos.length()
	if d - r < HEAD_CLEAR:
		return true
	if pos.y - r < floor_y + FLOOR_CLEAR:
		return true
	# The cone widens by the echo's own angular radius, so no part of it enters the cone.
	var off := rad_to_deg(pos.normalized().angle_to(hero_dir))
	if off < SIGHT_CONE_DEG + rad_to_deg(asin(clampf(r / d, 0.0, 1.0))):
		return true
	for q in placed:
		if pos.distance_to(q["pos"] as Vector3) < (r + float(q["r"])) * 1.1:
			return true
	return false
