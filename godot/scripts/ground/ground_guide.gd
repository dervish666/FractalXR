class_name GroundGuide
extends Node3D

## BEACONS and TOUR on the Mandelbrot ground: light pillars standing on the small copies of
## the set (minibrots) near you, found by the maths rather than by eye, and trips to them.
##
## Finding them. Every point c has an atom domain: the step n at which its orbit came
## closest to 0. Round each minibrot of period p lies a region whose points all report p, so
## a grid of samples round the viewer gives the periods present, and Newton's method on
## f_c^p(0) = 0 from a sample of that period lands on the minibrot's nucleus. The standard
## size estimate (b = 1 + sum 1/l_j, l_j = prod 2 z_j, size = |1 / (b l^2)|) says how big
## it is, so a trip knows how far to zoom. All in 64-bit floats on a worker thread: the
## ground's df32 reaches about 8e6x and doubles hold a nucleus well past that.
##
## Going there. A trip glides until the target is under your feet, then zooms about it. A
## minibrot is shown at MINI_M metres; the stop before it, the ornament, is the log-midpoint
## between where you were and that, where the embedded Julia sets that decorate a minibrot
## are at their richest. TOUR runs ornament, minibrot, look round, next, by itself.
##
## Mandelbrot only, not JULIA: the other families fold z with abs() and have no Newton.

const SCAN_GRID := 15              # samples a side
const SCAN_RADIUS_M := 11.0        # half-width of the sampled square round the viewer
const SCAN_ITER_MAX := 60000
## Iterations a trip asks of the ground per period of its minibrot (FractalGround.iter_hint),
## and the most it may ask.
## 24 covers the median stop's 90th percentile (measured 7 to 38 periods); 16384 is where
## the df32 fill stops keeping up on the Mac (1 fps at 33k). Perturbation is the way past it.
const ITER_PER_PERIOD := 24
const ITER_HINT_MAX := 16384
## TOUR moves on only once the ground has filled this far, or after TOUR_FILL_WAIT_S.
const TOUR_FILL := 0.95
const TOUR_FILL_WAIT_S := 30.0
const NEWTON_STEPS := 40
const MAX_TRIES := 18              # distinct periods put through Newton per scan
const MAX_BEACONS := 5
## A minibrot is shown this big (size estimate times wpu, metres): one you can stand beside.
const MINI_M := 2.5
## Already this big in metres, it is in plain sight and not worth a beacon.
const SEEN_M := 0.6
## A trip stops with its target this far ahead, along the way you faced when it began.
const AHEAD_M := 4.5
## The ground's deepest wpu (FractalGround.zoom's clamp): a minibrot whose MINI_M view
## needs more is out of reach.
var wpu_max := FractalGround.WPU_BASE * pow(2.0, float(FractalGround.STAGE_MAX + 1)) * 0.999

## Trip pace. Picked trips are yours and move at about the stick's pace; TOUR is ambient
## motion and goes far slower (see the project's comfort notes).
const PICK_MPS := 1.2
const PICK_EFOLD_PER_S := 0.6
## Vars, so a harness can run the tour at speed.
var tour_mps := 0.5
var tour_efold_per_s := 0.1
var tour_dwell_s := 6.0

var ground: FractalGround
var enabled := true
var tour := false
## Set by the host while the menu or the dash is up: a trip holds still.
var paused := false
## The way the viewer faces on the plane (unit xz), set by the host each frame.
var facing := Vector2(0.0, -1.0)

## Beacons found by the last scan: {x, y (fractal, 64-bit), period, size}.
var beacons: Array[Dictionary] = []
## The trip under way, or empty: {x, y, wpu, mps, efold, then (Dictionary or null)}.
var trip: Dictionary = {}
## 0..1, how hard the trip is moving the world this frame (the comfort tunnel reads it).
var moving := 0.0
## Last arrival, for the tour's dwell and the harness.
var arrived_at := -1.0
var arrivals := 0
## The period of the last stop's minibrot.
var last_period := 0

var _task := -1
var _result: Array = []
var _scan_at := Vector3(INF, INF, 0.0)   # viewer fx, fy and wpu of the last scan
var _scan_due := 0.0
var _pillars: Array[MeshInstance3D] = []
var _rings: Array[MeshInstance3D] = []
var _mat_pillar: StandardMaterial3D
var _mat_ring: StandardMaterial3D
var _clock := 0.0
## The depth the iteration hint was set for; zoomed far back out of it, the hint goes.
var _hint_wpu := 0.0


func _init() -> void:
	_mat_pillar = StandardMaterial3D.new()
	_mat_pillar.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat_pillar.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_mat_pillar.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat_pillar.no_depth_test = false
	_mat_pillar.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mat_pillar.albedo_color = Color(1.0, 0.8, 0.35)
	_mat_ring = _mat_pillar.duplicate()
	var pillar := CylinderMesh.new()
	pillar.top_radius = 0.012
	pillar.bottom_radius = 0.035
	pillar.height = 3.0
	pillar.radial_segments = 10
	pillar.rings = 1
	var ring := TorusMesh.new()
	ring.inner_radius = 0.92
	ring.outer_radius = 1.0
	ring.rings = 48
	ring.ring_segments = 6
	for i in MAX_BEACONS:
		var p := MeshInstance3D.new()
		p.mesh = pillar
		p.material_override = _mat_pillar
		p.visible = false
		add_child(p)
		_pillars.append(p)
		var r := MeshInstance3D.new()
		r.mesh = ring
		r.material_override = _mat_ring
		r.visible = false
		add_child(r)
		_rings.append(r)


## Whether the guide applies to the ground as it is now.
func applies() -> bool:
	return ground != null and ground.formula == 0 and not ground.julia


# --- the maths, static and thread-safe -------------------------------------------------

## The step at which the orbit of c came closest to 0, up to n_max or escape.
static func atom_period(cx: float, cy: float, n_max: int) -> int:
	var zx := 0.0
	var zy := 0.0
	var best := INF
	var p := 0
	# Brent's check, as ground.glsl: an orbit back on its saved point has settled on its
	# cycle, and the closest pass to 0 is already counted.
	var sx := 0.0
	var sy := 0.0
	var check := 1
	for n in range(1, n_max + 1):
		var t := zx * zx - zy * zy + cx
		zy = 2.0 * zx * zy + cy
		zx = t
		var m := zx * zx + zy * zy
		if m < best:
			best = m
			p = n
		if m > 1e8:
			break
		var ex := zx - sx
		var ey := zy - sy
		if ex * ex + ey * ey < 1e-24:
			break
		if n == check:
			sx = zx
			sy = zy
			check *= 2
	return p


## Newton's method on f_c^p(0) = 0 from (cx, cy). [x, y, converged].
static func nucleus(cx: float, cy: float, p: int) -> Array:
	var x := cx
	var y := cy
	var last2 := INF
	for s in NEWTON_STEPS:
		var zx := 0.0
		var zy := 0.0
		var dx := 0.0
		var dy := 0.0
		for i in p:
			var ndx := 2.0 * (zx * dx - zy * dy) + 1.0
			var ndy := 2.0 * (zx * dy + zy * dx)
			var t := zx * zx - zy * zy + x
			zy = 2.0 * zx * zy + y
			zx = t
			dx = ndx
			dy = ndy
		var den := dx * dx + dy * dy
		if den == 0.0 or not is_finite(den):
			return [x, y, false]
		var ux := (zx * dx + zy * dy) / den
		var uy := (zy * dx - zx * dy) / den
		x -= ux
		y -= uy
		last2 = ux * ux + uy * uy
		if last2 <= maxf(x * x + y * y, 1e-300) * 1e-26:
			return [x, y, true]
	# Rounding can keep the last step from shrinking further; near enough is a nucleus.
	return [x, y, last2 <= maxf(x * x + y * y, 1e-300) * 1e-18]


## The smallest q <= p with f_c^q(0) at 0 for this nucleus: p itself when the period is
## exact, less when Newton slid into a bigger component of a divisor's period.
static func exact_period(x: float, y: float, p: int) -> int:
	var zx := 0.0
	var zy := 0.0
	var dx := 1.0
	var dy := 0.0
	for q in range(1, p + 1):
		var t := zx * zx - zy * zy + x
		zy = 2.0 * zx * zy + y
		zx = t
		# |z_q| against the scale of how fast z_q moves with c here: 0 to rounding.
		if q < p and zx * zx + zy * zy < 1e-24 * maxf(dx * dx + dy * dy, 1.0):
			return q
		var ndx := 2.0 * (zx * dx - zy * dy) + 1.0
		var ndy := 2.0 * (zx * dy + zy * dx)
		dx = ndx
		dy = ndy
	return p


## The component size estimate for the nucleus (x, y) of period p.
static func size_estimate(x: float, y: float, p: int) -> float:
	var zx := 0.0
	var zy := 0.0
	var lx := 1.0
	var ly := 0.0
	var bx := 1.0
	var by := 0.0
	for j in range(1, p):
		var t := zx * zx - zy * zy + x
		zy = 2.0 * zx * zy + y
		zx = t
		var nlx := 2.0 * (zx * lx - zy * ly)
		var nly := 2.0 * (zx * ly + zy * lx)
		lx = nlx
		ly = nly
		var l2 := lx * lx + ly * ly
		if l2 == 0.0:
			return 0.0
		bx += lx / l2
		by -= ly / l2
	# s = 1 / (b l^2); |s| = 1 / (|b| |l|^2)
	var bl := sqrt(bx * bx + by * by) * (lx * lx + ly * ly)
	return 1.0 / bl if bl > 0.0 else 0.0


## One scan: samples is [[cx, cy], ...]. Returns [{x, y, period, size}], biggest first.
static func scan(samples: Array, n_max: int) -> Array:
	var by_p := {}
	for s in samples:
		var p := atom_period(s[0], s[1], n_max)
		if p > 0 and not by_p.has(p):
			by_p[p] = s
	var periods := by_p.keys()
	periods.sort()
	var found: Array = []
	var tries := 0
	for p in periods:
		if tries >= MAX_TRIES:
			break
		tries += 1
		var s: Array = by_p[p]
		var n := nucleus(s[0], s[1], p)
		if not n[2]:
			continue
		var q := exact_period(n[0], n[1], p)
		var size := size_estimate(n[0], n[1], q)
		if size <= 0.0 or not is_finite(size):
			continue
		var dup := false
		for f in found:
			if Vector2(f["x"] - n[0], f["y"] - n[1]).length() < f["size"] * 0.5 + size * 0.5:
				dup = true
				break
		if not dup:
			found.append({"x": n[0], "y": n[1], "period": q, "size": size})
	found.sort_custom(func(a, b): return a["size"] > b["size"])
	return found


# --- per frame -------------------------------------------------------------------------

## head_xz: the viewer on the plane, world metres. Called every frame in GROUND.
func update(head_xz: Vector2, delta: float) -> void:
	_clock += delta
	moving = 0.0
	var on := applies() and (enabled or tour or not trip.is_empty())
	visible = on and enabled
	if not applies():
		trip = {}
		tour = false
		beacons.clear()
		_show(head_xz)
		return
	if ground.iter_hint > 0 and trip.is_empty() and ground.wpu < _hint_wpu / 256.0:
		ground.iter_hint = 0
	if not trip.is_empty() and not paused:
		_step_trip(head_xz, delta)
	_poll_scan()
	if enabled or tour:
		_maybe_scan(head_xz)
	var filled := ground.progress() >= TOUR_FILL or _clock - arrived_at > TOUR_FILL_WAIT_S
	if tour and not paused and trip.is_empty() and _task < 0 and filled and _clock - arrived_at > tour_dwell_s:
		_tour_next()
	_show(head_xz)


## Stop where you are (a stick, a grab or a pick of your own takes over).
func cancel() -> void:
	trip = {}


func set_tour(on: bool) -> void:
	tour = on
	if not on:
		trip = {}
	else:
		arrived_at = _clock - tour_dwell_s   # start now


## A trigger with the ray hitting the floor at hit_xz: a beacon near it, or false.
func pick(hit_xz: Vector2, head_xz: Vector2) -> bool:
	if not applies() or not enabled:
		return false
	var best := -1
	var best_d := INF
	for i in beacons.size():
		var w := ground.fractal64_to_world(beacons[i]["x"], beacons[i]["y"])
		var reach := maxf(0.6, 0.15 * (w - head_xz).length())
		var d := (w - hit_xz).length()
		if d < reach and d < best_d:
			best = i
			best_d = d
	if best < 0:
		return false
	tour = false
	go_to(beacons[best], PICK_MPS, PICK_EFOLD_PER_S)
	return true


## Trip to a beacon: the ornament on the way when it is a real stop, then the minibrot.
func go_to(b: Dictionary, mps: float, efold: float) -> void:
	ground.iter_hint = mini(ITER_PER_PERIOD * int(b["period"]), ITER_HINT_MAX)
	_hint_wpu = minf(MINI_M / b["size"], wpu_max)
	var w_mini := minf(MINI_M / b["size"], wpu_max)
	var w_orn := sqrt(ground.wpu * w_mini)
	var ahead := facing * AHEAD_M
	var final := {"x": b["x"], "y": b["y"], "wpu": w_mini, "mps": mps, "efold": efold, "then": null,
		"period": b["period"], "kind": "minibrot", "ahead": ahead}
	if log(w_mini / ground.wpu) > 2.0 * log(4.0):
		trip = {"x": b["x"], "y": b["y"], "wpu": w_orn, "mps": mps, "efold": efold, "then": final,
			"period": b["period"], "kind": "ornament", "ahead": ahead}
	else:
		trip = final


func _tour_next() -> void:
	# The biggest beacon you have not already arrived at.
	for b in beacons:
		var w_mini: float = MINI_M / b["size"]
		if w_mini > ground.wpu * 1.5 and w_mini <= wpu_max:
			go_to(b, tour_mps, tour_efold_per_s)
			return


func _step_trip(head_xz: Vector2, delta: float) -> void:
	# Bring the target to its spot ahead of you, then zoom about that spot, so it grows
	# where you are looking and the ground under you streams past rather than the target.
	var spot: Vector2 = head_xz + (trip["ahead"] as Vector2)
	var e := ground.fractal64_to_world(trip["x"], trip["y"]) - spot
	var d := e.length()
	var mps: float = trip["mps"]
	if d > 0.002:
		var step := (e * (1.0 - exp(-delta * 2.0))).limit_length(mps * delta)
		ground.pan(step)
		moving = maxf(moving, minf(1.0, step.length() / maxf(delta, 1e-4) / mps))
	var gap := log(float(trip["wpu"]) / ground.wpu)
	if d < 0.5 and absf(gap) > 0.005:
		var rate: float = signf(gap) * minf(float(trip["efold"]), absf(gap) * 1.5 + 0.02)
		var f := exp(rate * delta)
		if absf(log(f)) > absf(gap):
			f = exp(gap)
		ground.zoom_about(spot, f)
		moving = maxf(moving, minf(1.0, absf(rate) / PICK_EFOLD_PER_S))
	elif d < 0.02 and absf(gap) <= 0.005:
		var then = trip["then"]
		arrived_at = _clock
		arrivals += 1
		last_period = int(trip["period"])
		trip = then if then != null else {}
		_scan_due = 0.0


func _maybe_scan(head_xz: Vector2) -> void:
	if _task >= 0 or not trip.is_empty():
		return
	var fx := ground.viewer_fx()
	var fy := ground.viewer_fy()
	var moved_m := Vector2(fx - _scan_at.x, fy - _scan_at.y).length() * ground.wpu
	var zoomed := absf(log(ground.wpu / maxf(_scan_at.z, 1e-9))) if _scan_at.z > 0.0 else INF
	if moved_m < 3.0 and zoomed < log(1.6) and _clock < _scan_due:
		return
	_scan_at = Vector3(fx, fy, ground.wpu)
	_scan_due = _clock + 30.0
	var samples: Array = []
	for j in SCAN_GRID:
		for i in SCAN_GRID:
			var o := Vector2((float(i) + 0.5) / SCAN_GRID * 2.0 - 1.0,
				(float(j) + 0.5) / SCAN_GRID * 2.0 - 1.0) * SCAN_RADIUS_M
			var f := ground.world_to_fractal64(head_xz + o)
			samples.append([f[0], f[1]])
	var n_max := mini(maxi(ground.effective_iter() * 2, 500), SCAN_ITER_MAX)
	_result = []
	_task = WorkerThreadPool.add_task(func(): _result = GroundGuide.scan(samples, n_max))


func _poll_scan() -> void:
	if _task < 0 or not WorkerThreadPool.is_task_completed(_task):
		return
	WorkerThreadPool.wait_for_task_completion(_task)
	_task = -1
	beacons.clear()
	for b in _result:
		var size: float = b["size"]
		if size * ground.wpu > SEEN_M or MINI_M / size > wpu_max:
			continue
		beacons.append(b)
		if beacons.size() >= MAX_BEACONS:
			break


## Block until the scan in flight lands (harness only).
func finish_scan() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_poll_scan()


func _show(head_xz: Vector2) -> void:
	var pulse := 0.75 + 0.25 * sin(_clock * 2.4)
	_mat_pillar.albedo_color = Color(1.0, 0.78, 0.32) * pulse
	_mat_ring.albedo_color = Color(1.0, 0.78, 0.32) * (0.6 * pulse)
	for i in MAX_BEACONS:
		# A beacon you have zoomed up to is in plain sight now: let it go.
		var show := visible and i < beacons.size() \
			and float(beacons[i]["size"]) * ground.wpu < SEEN_M * 4.0
		_pillars[i].visible = show
		_rings[i].visible = show
		if not show:
			continue
		var b: Dictionary = beacons[i]
		var w := ground.fractal64_to_world(b["x"], b["y"])
		_pillars[i].position = Vector3(w.x, 1.2, w.y)
		var r := clampf(float(b["size"]) * ground.wpu * 1.5, 0.15, 3.0)
		_rings[i].position = Vector3(w.x, 0.02, w.y)
		_rings[i].scale = Vector3(r, 1.0, r)
