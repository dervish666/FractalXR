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
## Three worlds (WORLDS below says how each is set up):
##   BULB    level 0 is main.gd's SOLID 192 mesh of the bulb on show, built once.
##   SPIRES  an endless honeycomb (bulb.glsl's spiresDE): no outside to mesh, so level 0 is
##           a cube round the head like the rest, and fog hides where it ends.
##   VAULT   a Mandelbox at scale 2.39, walked from inside: bounded, so level 0 is one mesh
##           of all of it, built here, and the finer levels follow the head.
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

enum World { BULB, SPIRES, VAULT }

## Cells per axis for every level above 0. Level k has cell h0 / 2^k and side N cells.
const N := 96
const MAX_LEVELS := 10
## The finest level wanted is the first whose cell is this small in the world.
const H_TARGET_M := 0.01
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
	&"palette_cycles", &"gain", &"light_dir", &"debug_view", &"art_style"]
## Per-pixel colour (bulb_solid.gdshader's pixel_trap) reaches this many level 0 cells of
## SPIRES (one honeycomb cell each) from the eye; VAULT's reach is in metres per its own.
const PIXEL_TRAP_CELLS := 2.4

## The worlds FLY builds itself. genome: what BulbSource meshes. side0 / grid0: level 0's
## cube in state units and its cells; static0: level 0 is built once round the origin
## rather than following the head. h_target: the finest cell wanted, in metres (busier
## worlds stop coarser to hold the triangle count). trap: the per-pixel colour key in
## fly_de.gdshaderinc, 1 honeycomb, 2 box. start_clear_m: VAULT opens scaled so the
## roomiest spot it finds has this much clearance; SPIRES opens at m_per_unit.
## Palettes run shadow to highlight; sky is the fog and the background; sun is in state
## space, where y is up as the world is.
## The worlds' surface: slate, grey, stone, warm stone, sand, close in value. In Sam's
## reference renders the surface is nearly neutral and the colour is the light: sky blue
## in the shade, sun gold on the lit faces. A navy-to-cream palette instead put hard-edged
## shards of colour wherever the orbit trap jumps between vertices.
const NEUTRAL_STONE := [Vector3(0.2, 0.23, 0.29), Vector3(0.27, 0.29, 0.33),
	Vector3(0.34, 0.33, 0.31), Vector3(0.42, 0.37, 0.3), Vector3(0.5, 0.45, 0.36)]

const WORLDS := {
	World.SPIRES: {
		"genome": {"formula": "spires", "scale": 0.5, "minR": 0.05, "fixedR": 1.0,
			"mandelbulb": false},
		"side0": 16.0, "grid0": 96, "static0": false, "h_target": 0.02, "trap": 1,
		"m_per_unit": 6.0, "start_y": Vector2(0.4, 0.8),
		# Near-neutral stone, slate to warm: the blue and the gold are the light's (see
		# NEUTRAL_STONE). Was navy to cream, which Sam found odd (2026-11-17).
		"palette": NEUTRAL_STONE,
		"sky": Color(0.58, 0.7, 0.86), "zenith": Color(0.14, 0.24, 0.48),
		"sun": Vector3(0.45, 0.55, 0.3), "sun_scatter": 0.55,
		"sky_tint": Vector3(1.18, 1.44, 2.0), "key_colour": Vector3(1.0, 0.86, 0.62),
		"shadow_k": 12.0, "fog_edges": 1.8,
	},
	World.VAULT: {
		# The standard Mandelbox: fold limit 1, min radius 0.5, fixed radius 1, scale 2.39.
		# At 2.0 (our gallery's Mandelbox) it is a solid cube with 2% pores; 2.39 opens it
		# into halls.
		"genome": {"formula": "mandelbox", "scale": 2.39, "minR": 0.5, "fixedR": 1.0,
			"mandelbulb": true},
		# Extent 2 (s + 1) / (s - 1) = 4.88, plus a margin.
		# 192 cells made 1.8M triangles of level 0 alone: the inside is all wall.
		# No per-pixel colour (trap 0): the box's key jumps at every fold, and one sample a
		# pixel against the vertices' neighbourhood average scattered gold confetti.
		"side0": 10.4, "grid0": 128, "static0": true, "h_target": 0.01, "trap": 0,
		# Opens just off the outer surface, facing in along start_dir: the roomiest hollow
		# inside was the central chamber, flat walls and a few holes (harness, 2026-11-17),
		# where the outside is towers and canyons. start_clear: DE there, in state units.
		"start_clear_m": 2.2, "start_dir": Vector3(0.82, 0.32, 0.47), "start_clear": 0.05,
		# Almost one stone: the box's colour key jumps between neighbouring vertices, and
		# even NEUTRAL_STONE's spread drew those jumps as pale polygons (harness, 2026-11-17).
		"palette": [Vector3(0.31, 0.31, 0.32), Vector3(0.33, 0.32, 0.31),
			Vector3(0.35, 0.33, 0.3), Vector3(0.37, 0.34, 0.3), Vector3(0.39, 0.36, 0.31)],
		# Darker haze and less sky in the shade than SPIRES: the reference's shadows are deep
		# blue, and the first pass read washed out (harness, 2026-11-17).
		"sky": Color(0.34, 0.44, 0.6), "zenith": Color(0.08, 0.13, 0.28),
		"sun": Vector3(0.35, 0.7, 0.25), "sun_scatter": 0.42,
		"sky_tint": Vector3(0.8, 1.0, 1.55), "key_colour": Vector3(1.15, 0.9, 0.55),
		"rim": 0.25,
		# Baked per vertex, a sharp penumbra drew pale polygons across the sunlit faces.
		"shadow_k": 4.0,
		"fog_edges": 1.2,
		# A little lamp at the eye for the canyons the sun never reaches.
		"ambient": 0.2, "head_light": 0.3, "lamp_clear": 4.0,
	},
}

var active := false
var world := World.BULB
var _cfg := {}
## Level 0. In BULB it is main.gd's SOLID; otherwise _own0.
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
var _grid0 := 192
## The finest level wanted at the current scale, for the harness and the [perf] line.
var want := 0
## Debug: draw the levels only up to this one (-1 = all).
var cap_levels := -1
## Harness: false hides the finer levels and the cuts (builds go on), so the same pose
## can be shot as plain SOLID; tint_levels colours each level to show the seams.
var show_levels := true
var tint_levels := false
## The per-pixel sun shadow (bulb_solid.gdshader), SPIRES only (its DE is the one in
## fly_de.gdshaderinc). Default off: the jagged bands it was written for turned out to be
## colour (fixed by pixel_trap), and on the Mac it doubled an eye's draw (2.5 to 4.5 ms)
## for a change the harness shots barely show.
var pixel_shadows := false
## FLY's STYLE (bulb_solid.gdshader art_style): 0 natural, 1 neon, 2 toon, 3 pencil,
## 4 circuit, 5 iridescent, 6 magma, 7 jade, 8 chrome. Names in main.gd.
var art := 0
## Neon's night: a dark blue haze to hold the silhouettes, nearly black overhead.
## Each STYLE's sky, and so its fog (natural and iridescent/jade/chrome keep the world's).
## By art: neon, toon, pencil (the paper), circuit, magma (volcanic twilight).
const STYLE_SKY := {1: Color(0.02, 0.025, 0.06), 2: Color(0.45, 0.72, 1.0),
	3: Color(0.92, 0.9, 0.85), 4: Color(0.01, 0.03, 0.02), 6: Color(0.03, 0.012, 0.015)}

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
	_cfg = {}
	center = frame_center
	fit = frame_fit
	base = base_solid
	_src = src
	_mp = src.march_params()
	_light = light_state
	_grid0 = base_solid.grid
	_h0 = 2.0 * BulbSolid.half_of(src) / float(_grid0)
	_shown[0] = true   # main.gd builds it; is_settled() checks it there


## SPIRES or VAULT: a world FLY builds itself, level 0 included.
func begin_world(w: World, frame_center: Vector3, frame_fit: float) -> void:
	end()
	active = true
	world = w
	_cfg = WORLDS[w]
	center = frame_center
	fit = frame_fit
	base = _own0
	_src = BulbSource.new(_cfg["genome"])
	_mp = _src.march_params()
	_light = (_cfg["sun"] as Vector3).normalized()
	_grid0 = int(_cfg["grid0"])
	_h0 = float(_cfg["side0"]) / float(_grid0)
	_own0.shared_cdf = PackedFloat32Array()
	var chain := _chain()
	for k in chain.size():
		var s := chain[k]
		s.shadow_k = float(_cfg["shadow_k"])
		s.set_palette(_cfg["palette"])
		s.set_palette_cycles(1.0)
		_set_look(s, true)
		var m := s.material()
		m.set_shader_parameter("shadow_cell", cell(k))
		m.set_shader_parameter("shadow_iso", BulbSolid.ISO_VOXELS * cell(k))
		m.set_shader_parameter("shadow_reach", BulbSolid.SHADOW_REACH * N * cell(k))
		m.set_shader_parameter("shadow_sharp", float(_cfg["shadow_k"]))
		m.set_shader_parameter("fp_scale", float(_mp["scale"]))
		m.set_shader_parameter("fp_min_r", float(_mp["min_r"]))
		m.set_shader_parameter("fp_fixed_r", float(_mp["fixed_r"]))


## Where a world opens: [state point, metres per state unit, facing in state space].
## SPIRES stands you in the roomiest spot of one cell at a fixed size; VAULT comes in from
## outside along start_dir until the surface is start_clear away, sized to start_clear_m.
func start_pose() -> Array:
	var golden := PI * (3.0 - sqrt(5.0))
	var best := Vector3.ZERO
	var best_d := -1.0
	if world == World.SPIRES:
		var ys: Vector2 = _cfg["start_y"]
		for i in 400:
			var t := (float(i) + 0.5) / 400.0
			var a := float(i) * golden
			var q := Vector3(0.5 + 0.45 * cos(a) * sqrt(t), lerpf(ys.x, ys.y,
				fposmod(float(i) * 0.618, 1.0)), 0.5 + 0.45 * sin(a) * sqrt(t))
			var d := de(q)
			if d > best_d:
				best_d = d
				best = q
		return [best, float(_cfg["m_per_unit"]), Vector3.FORWARD]
	var dir: Vector3 = (_cfg["start_dir"] as Vector3).normalized()
	var want_d := float(_cfg["start_clear"])
	var t := 0.6 * side(0)
	for i in 4000:
		var d := de(dir * t)
		if d < want_d:
			break
		t -= maxf(d - want_d, 1e-4) * 0.8
	var at := dir * t
	return [at, float(_cfg["start_clear_m"]) / maxf(de(at), 1e-6), -dir]


func sky_colour() -> Color:
	return STYLE_SKY.get(art, _cfg.get("sky", Color.BLACK))


## V5: parameters for the procedural Rayleigh/Mie sky behind SPIRES and VAULT.
func world_sky_params() -> Dictionary:
	return {
		"procedural": active and world != World.BULB and not STYLE_SKY.has(art),
		"horizon": sky_colour(),
		"zenith": _cfg.get("zenith", Color(0.12, 0.2, 0.4)),
		"sun_state": _light,
		"sun_colour": _cfg.get("key_colour", Vector3.ONE),
		"sun_scatter": float(_cfg.get("sun_scatter", 0.0)),
	}


## STYLE, from the menu: re-dress every level.
func set_art(a: int) -> void:
	art = a
	if not active or world == World.BULB:
		return
	for s in _chain():
		_set_look(s, true)


func end() -> void:
	if base != null:
		base.clear_hole()
		_set_look(base, false)
	_own0.clear()
	_own0.clear_hole()
	_set_look(_own0, false)
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


## A world's air: a sky-tinted ambient, a warm sun, fog to the sky colour (set per frame
## in update), and colour per pixel near the eye. Off puts SOLID's look back.
func _set_look(s: BulbSolid, on: bool) -> void:
	var m := s.material()
	m.set_shader_parameter("sky_tint", _cfg["sky_tint"] if on else Vector3.ONE)
	m.set_shader_parameter("key_colour", _cfg["key_colour"] if on else Vector3.ONE)
	var sky: Color = sky_colour()
	m.set_shader_parameter("fog_colour", Vector3(sky.r, sky.g, sky.b))
	m.set_shader_parameter("fog_density", 0.0)
	var scat := float(_cfg.get("sun_scatter", 0.0)) if (on and not STYLE_SKY.has(art)) else 0.0
	m.set_shader_parameter("sun_scatter", scat)
	m.set_shader_parameter("flatten", 0.0 if on else 0.2)
	m.set_shader_parameter("pixel_shadow", 1 if on and pixel_shadows and world == World.SPIRES else 0)
	m.set_shader_parameter("art_style", art if on else 0)
	# Neon draws its lines from the key per pixel in every world, VAULT's box key included:
	# its jumps, confetti as colour, are the fold lines here.
	var fam := int(_cfg.get("trap", 0))
	if on and art == 1 and fam == 0 and _cfg.has("genome") and str(_cfg["genome"]["formula"]) == "mandelbox":
		fam = 2
	m.set_shader_parameter("trap_family", fam)
	m.set_shader_parameter("pixel_trap", 1 if on and int(_cfg.get("trap", 0)) > 0 else 0)
	m.set_shader_parameter("ambient", float(_cfg.get("ambient", 0.22)) if on else 0.22)
	m.set_shader_parameter("head_light", float(_cfg.get("head_light", 0.0)) if on else 0.0)
	m.set_shader_parameter("rim", float(_cfg.get("rim", 0.9)) if on else 0.9)
	if not on:
		s.shadow_k = BulbSolid.SHADOW_K


func _chain() -> Array[BulbSolid]:
	var c: Array[BulbSolid] = [base if base != null else _own0]
	c.append_array(levels)
	return c


func cell(k: int) -> float:
	return _h0 / float(1 << k)


func cells(k: int) -> int:
	return _grid0 if k == 0 else N


func side(k: int) -> float:
	return cell(k) * float(cells(k))


## The CPU distance estimate on the frozen formula, in state units.
func de(state_p: Vector3) -> float:
	if _src == null:
		return 1e9
	return _src.de_with(state_p, _mp)


## The cube level k would take with the head here: centred on the head, snapped to a
## quarter of the cube. A static level 0 sits on the origin.
func cube_lo(k: int, head_state: Vector3) -> Vector3:
	if k == 0 and bool(_cfg.get("static0", true)):
		return Vector3.ONE * (-0.5 * side(0))
	var step := cell(k) * float(SNAP_CELLS)
	var c := (head_state / step).round() * step
	return c - Vector3.ONE * (0.5 * side(k))


## Main thread, every frame. head_state: the eye in state units; s2w: metres per state unit.
func update(head_state: Vector3, s2w: float, delta: float) -> void:
	if not active or base == null:
		return
	var chain := _chain()
	var own := world != World.BULB
	# Levels wanted: the first whose cell is the target or finer.
	var target := float(_cfg.get("h_target", H_TARGET_M))
	var base_cell_m := _h0 * s2w
	want = 0
	if base_cell_m > target:
		want = clampi(int(ceil(log(base_cell_m / target) / log(2.0))), 0, MAX_LEVELS)
	if cap_levels >= 0:
		want = mini(want, cap_levels)
	var d_head := de(head_state)
	var busy := 0
	var first := 0 if own else 1
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
					# equalisation re-measured at every move would recolour the world.
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
		if k > want and k > 0:
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
		if k > 0 and d_head > side(k) * 0.87:
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
		if not own:
			_sync_material(s)
		# AO and shadow reach the same number of cells on every level.
		s.request_box(_mp, cells(k), lo, cell(k), _light, BulbSolid.AO_RADIUS * N * cell(k),
			BulbSolid.SHADOW_REACH * N * cell(k))
	_apply_holes(chain)
	if own:
		# Squared fog (bulb_solid.gdshader): exp(-e^2) left at the edge of level 0.
		var edge_m := 0.5 * side(0) * s2w
		var near_m := PIXEL_TRAP_CELLS * s2w if world == World.SPIRES else 30.0 * cell(want) * s2w
		for s in chain:
			s.material().set_shader_parameter("fog_density",
				float(_cfg["fog_edges"]) / maxf(edge_m, 1e-3))
			s.material().set_shader_parameter("pixel_trap_m", near_m)
			s.material().set_shader_parameter("neon_far", 0.6 * edge_m)
			# The lamp reaches a few times the start clearance, in metres at this size.
			s.material().set_shader_parameter("lamp_m", float(_cfg.get("lamp_clear", 1.0))
				* float(_cfg.get("start_clear_m", 1.0)))
	for k in MAX_LEVELS + 1:
		var s := chain[k]
		if k > 0 and s.visible and not own:
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
