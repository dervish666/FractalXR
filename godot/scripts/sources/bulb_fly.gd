extends Node3D
class_name BulbFly

## FLY (spike): the bulb as a place you can shrink into. SOLID meshes the whole shape on
## one 192-cell grid, which is a centimetre a cell at hand size and a metre a cell once
## you are a hundred times smaller, so the crevices you came for fill in. FLY keeps that
## mesh as level 0 and stacks finer cubes round the head, each half the size and twice
## the resolution of the one outside it, the way voxel terrain engines keep detail near
## the camera. Every level is a BulbSolid over its own cube (request_box), so the DE,
## the surface nets and the baked light are SOLID's own.
##
## A level's cube is fixed in state space and only moves when the head crosses a quarter
## of it, so shrinking never rebuilds anything: it only adds a finer level. Moving does,
## finest first in practice since those cubes are smallest.
##
## Where a finer level has a mesh, the level outside it drops its triangles in that cube
## (BulbSolid.set_hole, done per vertex in bulb_solid.gdshader). The cut is ragged by one
## coarse cell, so a thin band of both draws; the seam is the open question of the spike.
##
## Sits under the ParticleCloud like BulbSolid; tick() gives every level the same
## state-to-local transform.

## Cells per axis for every level above the base. Level k has cell h0 / 2^k and side
## N * h0 / 2^k, so level 1 is half the base cube at twice the resolution.
const N := 96
const MAX_LEVELS := 10
## The finest level wanted is the first whose cell is this small in the world.
const H_TARGET_M := 0.01
## A level's cube is re-centred on the head in steps of this many of its cells (a quarter
## of the cube), which keeps every level's grid on the base grid's lattice.
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
## Every material parameter main.gd sets on the base, copied to the levels.
const SHARED_PARAMS: Array[StringName] = [&"pal0", &"pal1", &"pal2", &"pal3", &"pal4",
	&"palette_cycles", &"gain", &"light_dir", &"debug_view"]

var active := false
var base: BulbSolid
var levels: Array[BulbSolid] = []
## Per level (index k - 1): the cube on screen, the cube being built, and whether the
## screen shows that level at all (a mesh, or a confirmed empty cube).
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
var _lo0 := Vector3.ZERO
## Levels wanted at the current scale, for the harness and the [perf] line.
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
	for k in MAX_LEVELS:
		var s := BulbSolid.new()
		s.name = "Level%d" % (k + 1)
		s.grow_in = false
		levels.append(s)
		add_child(s)
		_shown_lo.append(Vector3.ZERO)
		_shown.append(false)
		_build_lo.append(Vector3.ZERO)
		_building.append(false)


## Start flying over the base mesh main.gd has just requested. The formula is frozen
## here: every level must mesh the same moment of the breath, or the seams open.
func begin(base_solid: BulbSolid, src: BulbSource, light_state: Vector3,
		frame_center: Vector3, frame_fit: float) -> void:
	end()
	active = true
	center = frame_center
	fit = frame_fit
	base = base_solid
	_src = src
	_mp = src.march_params()
	_light = light_state
	var half := BulbSolid.half_of(src)
	_h0 = 2.0 * half / float(base_solid.grid)
	_lo0 = Vector3.ONE * -half


func end() -> void:
	if base != null:
		base.clear_hole()
	for k in MAX_LEVELS:
		levels[k].clear()
		levels[k].clear_hole()
		_shown[k] = false
		_building[k] = false
	active = false
	want = 0


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
	# Levels wanted: the first whose cell is H_TARGET_M or finer.
	var base_cell_m := _h0 * s2w
	want = 0
	if base_cell_m > H_TARGET_M:
		want = clampi(int(ceil(log(base_cell_m / H_TARGET_M) / log(2.0))), 0, MAX_LEVELS)
	if cap_levels >= 0:
		want = mini(want, cap_levels)
	var d_head := de(head_state)
	var busy := 0
	for k in MAX_LEVELS:
		var s := levels[k]
		s.tick(center, fit, delta)
		if _building[k]:
			if s.is_ready() and s.just_ready:
				s.just_ready = false
				_building[k] = false
				_shown[k] = true
				_shown_lo[k] = _build_lo[k]
			elif s.state == BulbSolid.State.IDLE:
				# No surface in the cube: SOLID gives up and keeps its old mesh. Here an
				# empty cube is an answer, so show nothing for it.
				_building[k] = false
				s.mesh = null
				_shown[k] = true
				_shown_lo[k] = _build_lo[k]
			else:
				busy += 1
	for k in MAX_LEVELS:
		var s := levels[k]
		var lvl := k + 1
		if lvl > want:
			if _shown[k] or _building[k]:
				s.clear()
				_shown[k] = false
				_building[k] = false
			s.visible = false
			continue
		s.visible = _shown[k] and s.mesh != null
		var lo := cube_lo(lvl, head_state)
		if _building[k]:
			continue   # let it land, then check again: a restart every frame would starve
		if _shown[k] and lo.is_equal_approx(_shown_lo[k]):
			continue
		# A cube the DE says holds no surface is empty without a build. The head is at its
		# centre, so nothing within the half-diagonal means nothing in the cube.
		if d_head > side(lvl) * 0.87:
			s.clear()
			_shown[k] = true
			_shown_lo[k] = lo
			continue
		if busy >= MAX_BUILDING:
			continue
		busy += 1
		_building[k] = true
		_build_lo[k] = lo
		s.shared_cdf = base.cdf
		_sync_material(s)
		var h := cell(lvl)
		# AO and shadow reach the same number of cells as on the base.
		s.request_box(_mp, N, lo, h, _light, BulbSolid.AO_RADIUS * side(lvl),
			BulbSolid.SHADOW_REACH * side(lvl))
	_apply_holes()
	for k in MAX_LEVELS:
		if levels[k].visible:
			_sync_material(levels[k])
		var t: Color = TINTS[(k + 1) % TINTS.size()] if tint_levels else Color.WHITE
		levels[k].material().set_shader_parameter("tint", Vector3(t.r, t.g, t.b))
		if not show_levels:
			levels[k].visible = false
	var t0: Color = TINTS[0] if tint_levels else Color.WHITE
	base.material().set_shader_parameter("tint", Vector3(t0.r, t0.g, t0.b))
	if not show_levels:
		base.clear_hole()


## Each level drops its triangles inside the next finer level's cube on screen.
func _apply_holes() -> void:
	var chain: Array[BulbSolid] = [base]
	chain.append_array(levels)
	for j in MAX_LEVELS:
		var outer := chain[j]
		var k := j   # the finer level is levels[j], level j + 1
		if j + 1 <= want and _shown[k]:
			var pad := HOLE_PAD * (_h0 / float(1 << j))
			var lo := _shown_lo[k] + Vector3.ONE * pad
			var hi := _shown_lo[k] + Vector3.ONE * (side(j + 1) - pad)
			outer.set_hole(lo, hi)
		else:
			outer.clear_hole()


func _sync_material(s: BulbSolid) -> void:
	var from := base.material()
	var to := s.material()
	for p in SHARED_PARAMS:
		to.set_shader_parameter(p, from.get_shader_parameter(p))


## Render thread, once a frame: the next slab of every level still building.
func step() -> void:
	for s in levels:
		if s.is_building():
			s.step()


func is_settled() -> bool:
	for k in want:
		if _building[k] or not _shown[k]:
			return false
	return true


func triangles() -> int:
	var t := base.tri_count if base != null and base.is_ready() else 0
	for s in levels:
		if s.visible and s.is_ready():
			t += s.tri_count
	return t


func describe() -> String:
	var parts: Array[String] = []
	for k in want:
		var s := levels[k]
		var st := "empty" if _shown[k] and s.mesh == null else (
			"%dk" % (s.tri_count / 1000) if s.is_ready() else "building")
		parts.append("L%d %s" % [k + 1, st])
	return "want %d [%s] tris %d" % [want, ", ".join(parts), triangles()]
