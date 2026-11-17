extends Node3D
class_name BulbFly

## FLY (spike): a fractal as a place you can shrink into. SOLID meshes the whole bulb on
## one 192-cell grid, which is a centimetre a cell at hand size and a metre a cell once
## you are a hundred times smaller, so the crevices you came for fill in. FLY stacks finer
## cubes round the head, each half the size and twice the resolution of the one outside
## it, the way voxel terrain engines keep detail near the camera. Every level is a
## BulbSolid over its own cube (request_box), so the DE, the surface nets and the baked
## light are SOLID's own.
##
## Two worlds. BULB: level 0 is main.gd's SOLID 192 mesh of the whole shape, built once.
## SPIRES: an endless honeycomb (bulb.glsl's spiresDE) with no outside to mesh, so level 0
## is a cube round the head like the rest, and fog hides where it ends.
##
## A level's cube is fixed in state space and only moves when the head crosses a quarter
## of it, so shrinking never rebuilds anything: it only adds a finer level.
##
## Where a finer level has a mesh, the level outside it drops its triangles in that cube
## (BulbSolid.set_hole, done per vertex in bulb_solid.gdshader). The cut sits HOLE_PAD
## coarse cells inside the finer cube, so the two overlap in a thin band rather than crack.
##
## Sits under the ParticleCloud like BulbSolid; every level gets the same state-to-local
## transform, from the framing frozen at begin().

enum World { BULB, SPIRES }

## Cells per axis for every level the stack builds. Level k has cell h0 / 2^k and side
## N * h0 / 2^k. In BULB the base's 192 cells make level 1 half its cube at twice its
## resolution; in SPIRES level 0 is N cells too.
const N := 96
const MAX_LEVELS := 10
## The finest level wanted is the first whose cell is this small in the world.
const H_TARGET_M := 0.01
## SPIRES is busy at every scale (a bulb's levels are mostly empty air), so it stops at
## a coarser cell to keep the triangle count near the bulb's.
const H_TARGET_SPIRES_M := 0.02
## A level's cube is re-centred on the head in steps of this many of its cells (a quarter
## of the cube), which keeps every level's grid on the level 0 lattice.
const SNAP_CELLS := 24
## Builds allowed in flight at once. Each is SOLID's ~2 ms-a-frame slabs.
const MAX_BUILDING := 2
## How far inside a finer cube the coarser level's cut sits, in coarse cells. The finer
## mesh stops half a coarse cell short of its own cube (surface nets has no quads on the
## outer layer), and dropping every triangle with a corner in the cut pulls the coarse
## surface back up to 1.5 cells further, so anything under 2 leaves a crack. At 1.0 the
## harness showed black seams; 2.5 overlaps instead, and the coarse surface (fattened by
## its larger iso) wins the depth test in that band.
const HOLE_PAD := 2.5
## Every material parameter main.gd sets on the base, copied to the levels in BULB.
const SHARED_PARAMS: Array[StringName] = [&"pal0", &"pal1", &"pal2", &"pal3", &"pal4",
	&"palette_cycles", &"gain", &"light_dir", &"debug_view"]

## SPIRES: a world unit is one honeycomb cell. Level 0 spans this many of them.
const SPIRES_SIDE0 := 16.0
## The genome SPIRES meshes: R2 0.5 puts the arches' feet at the cell corners; thickness
## is per unit of height.
const SPIRES_GENOME := {"formula": "spires", "scale": 0.5, "minR": 0.05, "fixedR": 1.0,
	"mandelbulb": false}
## Navy shadow, steel, brass, sky and cream: the blue-and-gold city in Sam's reference.
const SPIRES_PALETTE := [Vector3(0.06, 0.09, 0.17), Vector3(0.2, 0.31, 0.5),
	Vector3(0.82, 0.62, 0.3), Vector3(0.55, 0.68, 0.86), Vector3(0.95, 0.88, 0.7)]
const SPIRES_SKY := Color(0.58, 0.7, 0.86)
## The sun, low and to one side, in state space (y up, as the world is).
const SPIRES_SUN := Vector3(0.45, 0.55, 0.3)
## SOLID's 10 made jagged white bands along the arches (harness, 2026-11-17).
const SPIRES_SHADOW_K := 3.5

var active := false
var world := World.BULB
## Level 0. In BULB it is main.gd's SOLID; in SPIRES it is _own0.
var base: BulbSolid
var levels: Array[BulbSolid] = []
var _own0 := BulbSolid.new()
## Per level 0..MAX_LEVELS: the cube on screen, the cube being built, and whether the
## screen shows that level (a mesh, or a confirmed empty cube).
var _shown_lo: Array[Vector3] = []
var _shown: Array[bool] = []
var _build_lo: Array[Vector3] = []
var _building: Array[bool] = []
var _mp := {}
var _src: BulbSource
## The cloud's state-to-local framing, frozen at begin(). The particle cloud keeps
## re-measuring itself under the mesh and easing center and fit toward each reading, a
## jitter nobody sees at hand size; a hundred times smaller it moved the walls 4 cm
## toward the head in four seconds of the harness's flight. FLY draws and steers through
## these instead.
var center := Vector3.ZERO
var fit := 1.0
var _light := Vector3.UP
var _h0 := 0.0
## The finest level wanted at the current scale, for the harness and the [perf] line.
var want := 0
## Debug: draw the levels only up to this one (-1 = all).
var cap_levels := -1
## Harness: false hides the finer levels and the cuts (builds go on), so the same pose
## can be shot as plain SOLID; tint_levels colours each level to show the seams.
var show_levels := true
var tint_levels := false
const TINTS := [Color(1.0, 0.55, 0.55), Color(0.55, 1.0, 0.55), Color(0.55, 0.65, 1.0),
	Color(1.0, 1.0, 0.5), Color(1.0, 0.55, 1.0), Color(0.5, 1.0, 1.0)]


func _init() -> void:
	name = "Fly"
	_own0.name = "Level0"
	_own0.grow_in = false
	add_child(_own0)
	for k in MAX_LEVELS:
		var s := BulbSolid.new()
		s.name = "Level%d" % (k + 1)
		s.grow_in = false
		levels.append(s)
		add_child(s)
	for k in MAX_LEVELS + 1:
		_shown_lo.append(Vector3.ZERO)
		_shown.append(false)
		_build_lo.append(Vector3.ZERO)
		_building.append(false)


## BULB: fly over the base mesh main.gd has just requested. The formula is frozen here:
## every level must mesh the same moment of the breath, or the seams open.
func begin(base_solid: BulbSolid, src: BulbSource, light_state: Vector3,
		frame_center: Vector3, frame_fit: float) -> void:
	end()
	active = true
	world = World.BULB
	center = frame_center
	fit = frame_fit
	base = base_solid
	_src = src
	_mp = src.march_params()
	_light = light_state
	_h0 = 2.0 * BulbSolid.half_of(src) / float(base_solid.grid)
	_shown[0] = true   # main.gd builds it; is_settled() checks it there


## SPIRES: the endless honeycomb, every level round the head.
func begin_spires(frame_center: Vector3, frame_fit: float) -> void:
	end()
	active = true
	world = World.SPIRES
	center = frame_center
	fit = frame_fit
	base = _own0
	_src = BulbSource.new(SPIRES_GENOME)
	_mp = _src.march_params()
	_light = SPIRES_SUN.normalized()
	_h0 = SPIRES_SIDE0 / float(N)
	_own0.shared_cdf = PackedFloat32Array()
	for s in _chain():
		s.shadow_k = SPIRES_SHADOW_K
		s.set_palette(SPIRES_PALETTE)
		s.set_palette_cycles(1.0)
		_set_look(s, true)


func end() -> void:
	if base != null:
		base.clear_hole()
		_set_look(base, false)
	_own0.clear()
	_own0.clear_hole()
	for k in MAX_LEVELS:
		levels[k].clear()
		levels[k].clear_hole()
		_set_look(levels[k], false)
	for k in MAX_LEVELS + 1:
		_shown[k] = false
		_building[k] = false
	active = false
	want = 0
	base = null


## SPIRES's air: a sky-blue ambient, a warm sun, and fog to the sky colour that is all
## but complete at the edge of level 0, so nothing is seen to end.
func _set_look(s: BulbSolid, on: bool) -> void:
	var m := s.material()
	m.set_shader_parameter("sky_tint", Vector3(0.62, 0.76, 1.05) * 1.9 if on else Vector3.ONE)
	m.set_shader_parameter("key_colour", Vector3(1.0, 0.86, 0.62) if on else Vector3.ONE)
	m.set_shader_parameter("fog_colour", Vector3(SPIRES_SKY.r, SPIRES_SKY.g, SPIRES_SKY.b))
	m.set_shader_parameter("fog_density", 0.0)
	m.set_shader_parameter("flatten", 0.0 if on else 0.2)
	if not on:
		s.shadow_k = BulbSolid.SHADOW_K


func _chain() -> Array[BulbSolid]:
	var c: Array[BulbSolid] = [base if base != null else _own0]
	c.append_array(levels)
	return c


func cell(k: int) -> float:
	return _h0 / float(1 << k)


func side(k: int) -> float:
	return cell(k) * float(N)


## The CPU distance estimate on the frozen formula, in state units.
func de(state_p: Vector3) -> float:
	if _src == null:
		return 1e9
	return _src.de_with(state_p, _mp)


## The cube level k would take with the head here: centred on the head, snapped to a
## quarter of the cube.
func cube_lo(k: int, head_state: Vector3) -> Vector3:
	var step := cell(k) * float(SNAP_CELLS)
	var c := (head_state / step).round() * step
	return c - Vector3.ONE * (0.5 * side(k))


## Main thread, every frame. head_state: the eye in state units; s2w: metres per state unit.
func update(head_state: Vector3, s2w: float, delta: float) -> void:
	if not active or base == null:
		return
	var chain := _chain()
	var spires := world == World.SPIRES
	# Levels wanted: the first whose cell is the target or finer.
	var target := H_TARGET_SPIRES_M if spires else H_TARGET_M
	var base_cell_m := _h0 * s2w
	want = 0
	if base_cell_m > target:
		want = clampi(int(ceil(log(base_cell_m / target) / log(2.0))), 0, MAX_LEVELS)
	if cap_levels >= 0:
		want = mini(want, cap_levels)
	var d_head := de(head_state)
	var busy := 0
	var first := 0 if spires else 1
	for k in range(first, MAX_LEVELS + 1):
		var s := chain[k]
		s.tick(center, fit, delta)
		if _building[k]:
			if s.is_ready() and s.just_ready:
				s.just_ready = false
				_building[k] = false
				_shown[k] = true
				_shown_lo[k] = _build_lo[k]
				if k == 0 and _own0.shared_cdf.is_empty():
					# The first level 0 sets the colours for the rest of the flight: an
					# equalisation re-measured at every move would recolour the city.
					_own0.shared_cdf = _own0.cdf
			elif s.state == BulbSolid.State.IDLE:
				# No surface in the cube: SOLID gives up and keeps its old mesh. Here an
				# empty cube is an answer, so show nothing for it.
				_building[k] = false
				s.mesh = null
				_shown[k] = true
				_shown_lo[k] = _build_lo[k]
			else:
				busy += 1
	for k in range(first, MAX_LEVELS + 1):
		var s := chain[k]
		if k > want:
			if _shown[k] or _building[k]:
				s.clear()
				_shown[k] = false
				_building[k] = false
			s.visible = false
			continue
		s.visible = _shown[k] and s.mesh != null
		var lo := cube_lo(k, head_state)
		if _building[k]:
			continue   # let it land, then check again: a restart every frame would starve
		if _shown[k] and lo.is_equal_approx(_shown_lo[k]):
			continue
		# A cube the DE says holds no surface is empty without a build. The head is at its
		# centre, so nothing within the half-diagonal means nothing in the cube.
		if d_head > side(k) * 0.87:
			s.clear()
			_shown[k] = true
			_shown_lo[k] = lo
			continue
		# Coarse first: a finer level means nothing until the one round it is up.
		if busy >= MAX_BUILDING or (k > 0 and not _shown[k - 1]):
			continue
		busy += 1
		_building[k] = true
		_build_lo[k] = lo
		if k > 0:
			s.shared_cdf = base.cdf
		if not spires:
			_sync_material(s)
		# AO and shadow reach the same number of cells on every level.
		s.request_box(_mp, N, lo, cell(k), _light, BulbSolid.AO_RADIUS * side(k),
			BulbSolid.SHADOW_REACH * side(k))
	_apply_holes(chain)
	if spires:
		# Squared fog (bulb_solid.gdshader): exp(-1.8^2) leaves 4% at the edge of level 0,
		# and a fifth of the way out it takes 12%.
		var edge_m := 0.5 * side(0) * s2w
		for s in chain:
			s.material().set_shader_parameter("fog_density", 1.8 / maxf(edge_m, 1e-3))
	for k in MAX_LEVELS + 1:
		var s := chain[k]
		if k > 0 and s.visible and not spires:
			_sync_material(s)
		var t: Color = TINTS[k % TINTS.size()] if tint_levels else Color.WHITE
		s.material().set_shader_parameter("tint", Vector3(t.r, t.g, t.b))
		if not show_levels and k > 0:
			s.visible = false
	if not show_levels:
		base.clear_hole()


## Each level drops its triangles inside the next finer level's cube on screen.
func _apply_holes(chain: Array[BulbSolid]) -> void:
	for j in MAX_LEVELS:
		var outer := chain[j]
		var k := j + 1
		if k <= want and _shown[k] and chain[k].visible:
			var pad := HOLE_PAD * cell(j)
			outer.set_hole(_shown_lo[k] + Vector3.ONE * pad,
				_shown_lo[k] + Vector3.ONE * (side(k) - pad))
		else:
			outer.clear_hole()


func _sync_material(s: BulbSolid) -> void:
	var from := base.material()
	var to := s.material()
	for p in SHARED_PARAMS:
		to.set_shader_parameter(p, from.get_shader_parameter(p))


## Render thread, once a frame: the next slab of every level still building.
func step() -> void:
	if _own0.is_building():
		_own0.step()
	for s in levels:
		if s.is_building():
			s.step()


func is_settled() -> bool:
	if base == null or not base.is_ready():
		return false
	for k in range(1, want + 1):
		if _building[k] or not _shown[k]:
			return false
	return not _building[0]


func triangles() -> int:
	var t := 0
	for s in _chain():
		if s.visible and s.is_ready():
			t += s.tri_count
	return t


func describe() -> String:
	var parts: Array[String] = []
	var chain := _chain()
	for k in range(0, want + 1):
		var s := chain[k]
		var st := "empty" if _shown[k] and s.mesh == null else (
			"%dk" % (s.tri_count / 1000) if s.is_ready() else "building")
		parts.append("L%d %s" % [k, st])
	return "%s want %d [%s] tris %d" % [World.keys()[world].to_lower(), want, ", ".join(parts),
		triangles()]
