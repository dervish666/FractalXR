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
## opens or recentres.
##
## Each echo also lives a life of its own (Sam: "the outer ones are not doing anything"). It
## spins about its own axis, drifts about its placed spot, swells and dims, slides along the
## palette, and every few minutes folds its shape away and grows another preset in its place.
## Each echo draws its own mix at its own rates from a seeded clock offset, so no two move
## together. All of it runs in the vertex shader off one clock uniform, so the CPU writes
## nothing per echo per frame: the only per-echo work is a shape swap, two writes once every
## few minutes. Rates follow the ambient-motion rule, about four times slower than first
## instinct: nothing here should be seen moving, only found to have moved.

## Echo counts. Sam called MANY rock solid and asked for more, then for a lot more, so LOTS
## now opens and SWARM and HOST go past it. Each count is a prefix of the next, so stepping up
## adds echoes without moving any. An echo is one draw call of 9 or 73 frames, and its motion
## costs the CPU nothing per frame (see the header), which is what makes HOST affordable.
const STEPS := [16, 40, 96, 192, 288, 0]
const STEP_NAMES := ["few", "many", "lots", "swarm", "host", "off"]
const DEFAULT_STEP := 2
const MAX_ECHOES := 288
## Fixed, so the room is the same room every time the mode opens.
const SEED := 20260923
## Echo width as a multiple of the hero's. Power law between the two, N(>s) ~ s^-SIZE_D, so a
## few large echoes sit among many small ones, the way a fractal's parts are distributed.
## 0.2 and not smaller: at the 2 m minimum a 0.1x echo is 6 cm across and its beams are under
## half a pixel, which with MSAA off shimmers instead of reading as a sculpture.
## 12x at the top: at 2x the largest echo was still a thing in the room, and Sam asked for
## much larger ones further off, where a sculpture tens of metres across reads as scenery.
## SIZE_D 1.0 rather than 1.3 so the giants are a handful and not one or two.
const S_MIN := 0.2
const S_MAX := 12.0
const SIZE_D := 1.0
## Distance grows with size, d = D_MIN * (s / S_MIN)^DIST_POW, jittered. A small echo stays
## near enough to resolve and a large one goes far enough not to loom, and a large echo still
## looks larger than a small one, so the sizes read as sizes and not as perspective. 0.6 was
## tried first and pushed everything so far out that the room read as specks.
## DIST_POW rose from 0.45 with the size range, so a 12x echo lands 25-40 m out (about 10-17
## degrees across) instead of looming at 15 m. The camera's far plane is 200 m.
const D_MIN := 2.0
const D_MAX := 40.0
const DIST_POW := 0.6
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

## The life of an echo. Each effect is drawn per echo with its own share, so the room is a mix
## of spinners, drifters, breathers and shape-shifters rather than one motion everywhere, and
## every echo does at least two things. Periods in seconds, drawn per echo.
## Spin: one turn in 4-10 minutes, up to half again slower for the giants far out.
const SPIN_S := Vector2(240.0, 600.0)
const SPIN_SHARE := 0.8
## Wander: a three-axis Lissajous about the placed spot. Amplitude is a share of the echo's
## own radius plus a share of its distance, so a near echo shifts by centimetres and a giant
## 30 m out by a couple of metres, a few degrees of view either way.
const WANDER_S := Vector2(90.0, 200.0)
const WANDER_R := 0.25
const WANDER_D := 0.03
const WANDER_SHARE := 0.75
## Swell: a slow breath in size and, through the shader's echo_glow, in brightness.
const SWELL_S := Vector2(40.0, 100.0)
const SWELL_AMP := Vector2(0.03, 0.08)
const SWELL_SHARE := 0.6
## Palette drift on top of the shared scroll, turns per second either way. The hero scrolls
## at 0.02, so an echo runs up to a fifth faster or slower and the room slowly decorrelates.
const DRIFT := 0.004
## Shape swap: the echo folds its frames back into their parents and grows another preset out
## of the root. Half the swaps from a preset land back on the hero's own shape, so the room
## keeps echoing what is being sculpted. At HOST, about one swap starts somewhere in the
## room every two seconds, mostly out of view.
const SWAP_EVERY := Vector2(150.0, 420.0)
const SWAP_SHARE := 0.6
const HERO_SHARE := 0.5
const SWAP_GROW_S := 1.6
const SWAP_SPAN := 2.4
## Far from any echo_t the shader will see: the "never" of a swap time.
const NEVER := 1.0e9

var step := DEFAULT_STEP
## One record per placed echo, in placement order: pos and basis in the anchor's frame, the
## width multiple, the distance, the tier and the two shader values. Published for the checks.
var placements: Array = []
var _ifs: FractalIFS
var _nodes: Array[MultiMeshInstance3D] = []
## One hidden FractalIFS per preset, built once at the deepest echo rung, so an echo can wear
## a shape the hero is not. Each keeps its own material for its own origin_span and seed fade
## and samples the hero's ramp, so a palette change still reaches every echo.
var _pool: Array[FractalIFS] = []
## The echoes' clock, behind the shader's echo_t. Advances only while MOTION is on.
var echo_t := 0.0
## Per echo: the shape it wears (-1 the hero's, else a PRESETS index), whether it is folding
## away, and the echo_t of its next swap event. _next_any is the earliest of those, so a frame
## with nothing due costs one comparison.
var _shape := PackedInt32Array()
var _folding := PackedByteArray()
var _next := PackedFloat64Array()
var _next_any := INF
var _unit := 1.0


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
	for p in FractalIFS.PRESETS.size():
		var f := FractalIFS.new()
		f.name = "Pool%d" % p
		f.ambient = false
		f.set_preset(p)
		f.detail = int(FractalIFS.ECHO_LEVELS.back())
		f.build(false)
		f.material().set_shader_parameter(&"ramp", ifs.ramp_texture())
		# Hidden by its own _init, so only the echoes that borrow its tiers draw it.
		add_child(f)
		_pool.append(f)
	for mat in _materials():
		mat.set_shader_parameter(&"swap_s", SWAP_GROW_S)
		mat.set_shader_parameter(&"swap_span", SWAP_SPAN)
	_shape.resize(MAX_ECHOES)
	_shape.fill(-1)
	_folding.resize(MAX_ECHOES)
	_next.resize(MAX_ECHOES)
	_next.fill(INF)
	_apply()


func _materials() -> Array[ShaderMaterial]:
	var out: Array[ShaderMaterial] = [_ifs.material()]
	for f in _pool:
		out.append(f.material())
	return out


## The MultiMesh an echo wearing `shape` at `tier` draws, and the material that decodes it.
func shape_multimesh(shape: int, tier: int) -> MultiMesh:
	return _ifs.echo_multimesh(tier) if shape < 0 else _pool[shape].echo_multimesh(tier)


func shape_material(shape: int) -> ShaderMaterial:
	return _ifs.material() if shape < 0 else _pool[shape].material()


func shape_of(i: int) -> int:
	return _shape[i]


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
		n += _nodes[i].multimesh.instance_count
	return n


## Scatter the echoes around an anchor at the head, yaw only. `floor_y` is the floor in the
## anchor's frame, `unit` the hero's metres per construction unit and `width_m` the hero's
## width in metres, so an echo of size s is s times the hero as it arrived. `hero` is the
## hero's centre in the anchor's frame, for the sight cone.
func place(anchor: Transform3D, floor_y: float, unit: float, width_m: float, hero: Vector3) -> void:
	global_transform = anchor
	_unit = unit
	placements = layout(floor_y, width_m, hero)
	_next_any = INF
	for i in _nodes.size():
		var m := _nodes[i]
		if i >= placements.size():
			m.visible = false
			_next[i] = INF
			continue
		var p: Dictionary = placements[i]
		var life: Dictionary = p["life"]
		m.set_instance_shader_parameter(&"echo_phase", float(p["phase"]))
		m.set_instance_shader_parameter(&"echo_gain", float(p["gain"]))
		m.set_instance_shader_parameter(&"echo_live", 1.0)
		m.set_instance_shader_parameter(&"echo_centre", anchor * (p["pos"] as Vector3))
		# The life is drawn in the anchor's frame; the shader works in world space.
		var spin: Vector3 = anchor.basis * (life["spin_axis"] as Vector3)
		m.set_instance_shader_parameter(&"echo_spin", Vector4(spin.x, spin.y, spin.z,
			float(life["spin_w"])))
		var wa: Vector3 = anchor.basis * (life["wander"] as Vector3)
		m.set_instance_shader_parameter(&"echo_wander", Vector4(wa.x, wa.y, wa.z,
			float(life["wander_w"])))
		m.set_instance_shader_parameter(&"echo_life", Vector4(float(life["t_off"]),
			float(life["swell"]), float(life["swell_w"]), float(life["drift"])))
		m.set_instance_shader_parameter(&"echo_swap", Vector2(NEVER, -NEVER))
		_folding[i] = 0
		_wear(i, int(life["shape0"]))
		var every := float(life["swap_every"])
		_next[i] = echo_t + every * float(life["swap_first"]) if every > 0.0 else INF
		_next_any = minf(_next_any, _next[i])
	_apply()


## Put shape `shape` on echo i: its tier's MultiMesh, the material that decodes it, and a
## scale that keeps a wider preset inside the sphere the placement cleared.
func _wear(i: int, shape: int) -> void:
	var p: Dictionary = placements[i]
	var m := _nodes[i]
	_shape[i] = shape
	m.multimesh = shape_multimesh(shape, int(p["tier"]))
	m.material_override = shape_material(shape)
	var k := 1.0
	if shape >= 0:
		k = minf(1.0, hero_reach() / corner(m.multimesh.custom_aabb))
	var sigma := float(p["s"]) * _unit * k
	m.transform = Transform3D((p["basis"] as Basis).scaled(Vector3.ONE * sigma), p["pos"] as Vector3)
	# Culling sees the static box; the shader moves frames outside it. A spin stays inside the
	# sphere through the box's far corner, and swell and wander add to that, all in this node's
	# local units, which is the space Godot grows the margin in.
	var life: Dictionary = p["life"]
	m.extra_cull_margin = corner(m.multimesh.custom_aabb) * (1.0 + SWELL_AMP.y) \
		+ (life["wander"] as Vector3).length() / maxf(sigma, 1e-6)


## Construction-space reach of the hero's frame: the half-diagonal of the seed cube, which is
## the sphere radius_of() assumes.
static func hero_reach() -> float:
	return FractalIFS.SEED_HALF * sqrt(3.0)


static func corner(box: AABB) -> float:
	var far := 0.0
	for c in 8:
		far = maxf(far, box.get_endpoint(c).length())
	return maxf(far, 1e-4)


## The clock and the swaps. Nothing per echo unless a swap is due.
func _process(delta: float) -> void:
	if _ifs == null or count() == 0 or not is_visible_in_tree():
		return
	advance(delta if _ifs.ambient else 0.0)


## One step of the echoes' clock, public so a check can drive it without frames.
func advance(dt: float) -> void:
	echo_t += dt
	var bright: Variant = _ifs.material().get_shader_parameter(&"brightness")
	for f in _pool:
		f.material().set_shader_parameter(&"anim_t", _ifs.anim_t)
		if bright != null:
			f.material().set_shader_parameter(&"brightness", bright)
	for mat in _materials():
		mat.set_shader_parameter(&"echo_t", echo_t)
	if echo_t < _next_any:
		return
	_next_any = INF
	for i in count():
		if echo_t >= _next[i]:
			_swap_step(i)
		_next_any = minf(_next_any, _next[i])


## One step of a swap. The first folds the shape away; the second, once the root has folded,
## puts on the next shape and grows it back out.
func _swap_step(i: int) -> void:
	var m := _nodes[i]
	var life: Dictionary = placements[i]["life"]
	if _folding[i] == 0:
		_folding[i] = 1
		m.set_instance_shader_parameter(&"echo_swap", Vector2(echo_t, -NEVER))
		_next[i] = echo_t + SWAP_SPAN + SWAP_GROW_S + 0.1
		return
	_folding[i] = 0
	_wear(i, next_shape(_shape[i], _ifs.preset, i, echo_t))
	m.set_instance_shader_parameter(&"echo_swap", Vector2(NEVER, echo_t))
	_next[i] = echo_t + SWAP_SPAN + SWAP_GROW_S \
		+ float(life["swap_every"]) * (0.7 + 0.6 * _unit_hash(i, echo_t))


## The shape after `cur`: from a preset, the hero's own half the time; otherwise a preset that
## is neither the one being left nor the hero's, which would read as no change.
static func next_shape(cur: int, hero_preset: int, i: int, t: float) -> int:
	if cur >= 0 and _unit_hash(i + 7, t) < HERO_SHARE:
		return -1
	var pick: Array[int] = []
	for p in FractalIFS.PRESETS.size():
		if p != cur and p != hero_preset:
			pick.append(p)
	if pick.is_empty():
		return -1
	return pick[int(_unit_hash(i + 13, t) * pick.size()) % pick.size()]


static func _unit_hash(i: int, t: float) -> float:
	return float(hash(Vector2i(i, int(t * 10.0))) & 0xffff) / 65536.0


func _apply() -> void:
	var n := count()
	for i in _nodes.size():
		_nodes[i].visible = i < n
	# With nothing drawing them, the hero's rebuilds skip the echo tiers altogether.
	if _ifs != null:
		_ifs.set_echoes_live(n > 0)


func nodes() -> Array[MultiMeshInstance3D]:
	return _nodes


## The placement itself, pure and seeded, so a check can run it without a scene. Two groups:
## each rung's echoes are placed around the smaller rung's, so FEW is exactly the first part
## of MANY, MANY of LOTS, and stepping up adds echoes without moving any.
static func layout(floor_y: float, width_m: float, hero: Vector3) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	var out: Array = []
	var hero_dir := hero.normalized() if hero.length() > 1e-4 else Vector3.FORWARD
	# One group per ladder rung, so each count is placed around the smaller one before it.
	var counts: Array[int] = []
	for c in STEPS:
		if int(c) > 0:
			counts.append(int(c))
	counts.sort()
	var groups: Array[int] = []
	var prev := 0
	for c in counts:
		groups.append(c - prev)
		prev = c
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
	# The life is drawn after, from its own stream per echo, so it cannot shift a placement and
	# each echo keeps its life when a bigger rung is added around it.
	for i in out.size():
		var rec: Dictionary = out[i]
		rec["life"] = life_of(i, float(rec["s"]), float(rec["d"]), width_m)
	return out


## Everything an echo does, drawn from its own seeded stream. Amplitudes stay inside the bound
## reach() charges the placement for; the check holds them to it.
static func life_of(i: int, s: float, d: float, width_m: float) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector2i(SEED, i))
	var shell := clampf(log(d / D_MIN) / log(D_MAX / D_MIN), 0.0, 1.0)
	var on := [rng.randf() < SPIN_SHARE, rng.randf() < WANDER_SHARE, rng.randf() < SWELL_SHARE,
		rng.randf() < SWAP_SHARE]
	if on.count(true) < 2:
		on[0] = true
		on[1] = true
	var axis := Vector3(rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0),
		rng.randf_range(-1.0, 1.0))
	if axis.length() < 1e-3:
		axis = Vector3.UP
	var spin_w := TAU / (rng.randf_range(SPIN_S.x, SPIN_S.y) * (1.0 + 0.5 * shell))
	if rng.randf() < 0.5:
		spin_w = -spin_w
	var w_max := wander_of(s, d, width_m)
	var wander := Vector3(rng.randf_range(0.5, 1.0), rng.randf_range(0.3, 0.8),
		rng.randf_range(0.5, 1.0))
	wander = wander / sqrt(3.0) * w_max
	var drift := rng.randf_range(0.3, 1.0) * DRIFT * (1.0 if rng.randf() < 0.5 else -1.0)
	return {
		"spin_axis": axis.normalized(),
		"spin_w": spin_w if on[0] else 0.0,
		"wander": wander if on[1] else Vector3.ZERO,
		"wander_w": TAU / rng.randf_range(WANDER_S.x, WANDER_S.y),
		"swell": rng.randf_range(SWELL_AMP.x, SWELL_AMP.y) if on[2] else 0.0,
		"swell_w": TAU / rng.randf_range(SWELL_S.x, SWELL_S.y),
		"t_off": rng.randf_range(0.0, 1000.0),
		"drift": drift,
		"swap_every": rng.randf_range(SWAP_EVERY.x, SWAP_EVERY.y) if on[3] else 0.0,
		"swap_first": rng.randf(),
		# Shape-shifters open in a mix: about a third wear another preset from the start.
		"shape0": rng.randi_range(0, FractalIFS.PRESETS.size() - 1)
			if on[3] and rng.randf() < 0.35 else -1,
	}


## The most an echo's centre can wander, in metres.
static func wander_of(s: float, d: float, width_m: float) -> float:
	return WANDER_R * radius_of(s, width_m) + WANDER_D * d


## The sphere an echo can ever touch: its frame's radius at the top of a swell, plus the
## wander. Spin turns the frame about its own centre and adds nothing. This is the radius every
## comfort rule is held to, so a moving echo keeps them at every moment, not just at rest.
static func reach(s: float, d: float, width_m: float) -> float:
	return radius_of(s, width_m) * (1.0 + SWELL_AMP.y) + wander_of(s, d, width_m)


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
		r = reach(s, d, width_m)
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
