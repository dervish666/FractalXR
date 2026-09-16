extends Node3D
class_name FractalIFS

## A finite IFS assembly: one open polyhedron frame repeated by two mirror planes and a short
## list of contracting base maps. Every base map is composed with {I, R1, R2, R2*R1}, the group
## the two planes generate, so the branching factor is four times the base count. The result is
## drawn as a single MultiMesh.
##
## Construction space is [-1, 1] on each axis. The node transform belongs to world grab;
## DEPTH is a separate final Z stretch held outside it, so an outer scale cannot swallow it.
##
## Sits as a child of the ParticleCloud, following FractalTree, so grab and scale apply
## unchanged. Geometry is rebuilt synchronously by build().
##
## Three things make it move, in rising order of what they cost. The palette drift and the
## grow-in are shader uniforms over a static buffer. Breathing and morphing rebuild, but only
## at the preset's drag rung, which is the rung a drag already pays for every frame. Neither
## of them writes `base`: an ambient offset is applied at build time, so MOTION off is the
## shape you banked, exactly.

const BEAM_W := 0.06
const BEAM_HW := BEAM_W * 0.5
## Beams run the full edge and meet flush, so the cube frame reaches half a width past 1.0.
## The tetrahedron and octahedron frames are built to the same [-1, 1] box and land within a
## thousandth of the same reach, which is why a preset can swap its seed without re-tuning.
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

## Face shade baked into the seed mesh, by axis. There is no light in the main
## scene and the material is unshaded, so without this the whole frame is one flat blob.
## Keyed by the axis and not the facing, so a mirrored copy shades like its original.
const AXIS_SHADE := [0.66, 1.0, 0.82]

## Colour when nothing has handed over a palette yet, so the first frame after _init draws
## the frames rather than sampling an unset ramp and coming out black.
const DEFAULT_PALETTE := [Color(0.20, 0.24, 0.40), Color(0.82, 0.86, 0.95)]

## Ambient rates. All of them are slower than they first read on paper: at arm's length a
## hand-sized sculpture magnifies every one of them, and the house rule for ambient motion is
## to land about four times slower than instinct.
const GROW_S := 0.6          # seconds for one generation to reach full size
const GROW_STAGGER := 0.18   # seconds between one generation starting and the next
## Part of a generation's stagger comes from how far out the frame sits, so a level arrives
## from the middle outward instead of the whole shell popping at once.
const BIRTH_RADIUS := 0.35
const SCROLL := 0.02         # palette turns per second: 50 s to drift one palette through
const RADIUS_MIX := 0.45     # colour coordinate: level at 0, radial distance at 1
const BREATHE_S := 30.0      # seconds for one contraction cycle
## Fraction of the contraction, either side of the banked value. Four percent on the
## contraction is about twelve on where the third generation ends up, because the offsets
## compound: the readable movement is in the outer frames, not in the number.
const BREATHE_AMP := 0.04
## Seconds for the added twist to turn one full circle. 3 degrees a second at the first
## generation and nine at the third, because the turn compounds with every level. At half this
## the outer frames churned; the cube and octahedron seeds are symmetric under a quarter turn,
## so a cube preset comes back to itself every 30 s rather than every 120.
const TWIST_S := 120.0
const MORPH_S := 2.0         # seconds from one preset's maps to the next
## The ramp texture the shader samples. 256 is more than a five-stop palette needs and still
## a rounding-free number of texels per stop for the sizes a palette actually comes in.
const RAMP_W := 256

## The three seed frames, as vertices in construction units and the edge pairs between them.
## All three sit in the same [-1, 1] box. The cube's edges are listed in long-axis order
## (x, then y, then z, each with its four offsets) because that order is the one the beam list,
## the seed mesh and therefore every published vertex inherited from the original hand-rolled
## builder; reordering them would change the mesh for no gain.
const FRAME_VERTS := {
	"cube": [
		Vector3(-1, -1, -1), Vector3(-1, -1, 1), Vector3(-1, 1, -1), Vector3(-1, 1, 1),
		Vector3(1, -1, -1), Vector3(1, -1, 1), Vector3(1, 1, -1), Vector3(1, 1, 1),
	],
	"tetra": [
		Vector3(1, 1, 1), Vector3(1, -1, -1), Vector3(-1, 1, -1), Vector3(-1, -1, 1),
	],
	"octa": [
		Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 1, 0),
		Vector3(0, -1, 0), Vector3(0, 0, 1), Vector3(0, 0, -1),
	],
}
const FRAME_EDGES := {
	"cube": [
		[0, 4], [1, 5], [2, 6], [3, 7],
		[0, 2], [4, 6], [1, 3], [5, 7],
		[0, 1], [2, 3], [4, 5], [6, 7],
	],
	"tetra": [[0, 1], [0, 2], [0, 3], [1, 2], [1, 3], [2, 3]],
	"octa": [
		[0, 2], [0, 3], [0, 4], [0, 5], [1, 2], [1, 3],
		[1, 4], [1, 5], [2, 4], [2, 5], [3, 4], [3, 5],
	],
}

## The gallery. Each entry names its seed frame, its base child maps, the rung the mode opens
## at and the rung a held handle rebuilds at. A base map is [contraction, offset] or
## [contraction, offset, euler degrees]; the mirror planes multiply every one of them by
## {I, R1, R2, R2*R1}, so all five presets are sculptable by the same two handles and the
## branching factor is four times the base count.
##
## Why no base map sits on a default mirror plane: a child centred on a plane is its own
## reflection. For a frame that plane also fixes, and the cube and the octahedron are symmetric
## under every sign flip, the mirrored copy lands exactly on top of the original and the
## instance budget pays twice for one visible frame. A child merely near a plane overlaps its
## own reflection instead, which reads as mush rather than as repetition. That is why CROSS,
## the one preset whose children do sit on the axes, uses the tetrahedron: a single mirror
## turns a tetrahedron into its dual rather than back into itself, so its axis children come
## out as two interlocked tetrahedra and not as two coincident copies.
##
## drag: 585 instances measured 2.0 ms to rebuild on Quest and 4681 measured 15 ms, so a preset
## with twelve children per level gives up a rung to keep a per-frame rebuild inside the budget.
const PRESETS := [
	# The original rule, unchanged. Small children pushed into the eight corners, so the middle
	# stays empty at every level: 1 + 8 + 64 + 512 = 585 frames at detail 3.
	{"name": "FRAMES", "seed": "cube", "detail": 3, "drag": 3,
		"maps": [[0.35, Vector3(0.6, 0.6, 0.6)], [0.35, Vector3(0.6, 0.6, -0.6)]]},
	# Half-size tetrahedra at those same eight corners. A single mirror flips a tetrahedron to
	# its dual, so neighbouring corners hold opposite handedness and the lattice interlocks.
	{"name": "TETRA", "seed": "tetra", "detail": 3, "drag": 3,
		"maps": [[0.38, Vector3(0.62, 0.62, 0.62)], [0.38, Vector3(0.62, 0.62, -0.62)]]},
	# Twelve children per level: a ring of four round the equator and a cap of four above and
	# below, so the octahedra radiate outward instead of stacking into corners. 1885 at detail 3.
	# The contraction is the smallest here on purpose. Twelve children at 0.36 filled the box
	# uniformly by the third generation and read as fuzz; at 0.30 each satellite stays a
	# readable octahedron with space around it.
	{"name": "STAR", "seed": "octa", "detail": 3, "drag": 2,
		"maps": [[0.3, Vector3(0.7, 0.7, 0.0)], [0.3, Vector3(0.28, 0.28, 0.78)],
			[0.3, Vector3(0.28, 0.28, -0.78)]]},
	# Four arms along x and y, lifted and dropped in z so the cross is a pinwheel and not a flat
	# plus. Each arm node holds a tetrahedron and its mirror image: a stella octangula.
	{"name": "CROSS", "seed": "tetra", "detail": 3, "drag": 3,
		"maps": [[0.5, Vector3(0.86, 0.0, 0.34)], [0.5, Vector3(0.0, 0.86, -0.34)]]},
	# FRAMES with a turn folded into each base map, so every generation twists further about Y
	# and the eight corner chains spiral instead of stacking straight. 34 degrees and not 20:
	# at 20 the spiral was invisible at arm's length, and at 45 the turn compounds to a right
	# angle by the second generation, which is a symmetry of the cube frame and so undoes
	# itself. A bigger contraction than FRAMES too, because a small child cannot show a turn.
	{"name": "TWIST", "seed": "cube", "detail": 3, "drag": 3,
		"maps": [[0.4, Vector3(0.62, 0.62, 0.62), Vector3(0.0, 34.0, 0.0)],
			[0.4, Vector3(0.62, 0.62, -0.62), Vector3(0.0, 34.0, 0.0)]]},
]

var plane1_normal := DEFAULT_N1
var plane1_offset := 0.0
var plane2_normal := DEFAULT_N2
var plane2_offset := 0.0
var depth := 1.0
var detail := 3
## Which entry of PRESETS is loaded, and the base maps it loaded. `base` is a working copy, so a
## harness can try a rule that is not in the table without editing the table to do it.
var preset := 0
var base: Array = []
## Ambient breathing, on when the mode opens the way the tree's wind is. The sculpture read
## as a still life beside the other modes, and a MOTION tile nobody finds does not fix that.
## `ambient_hold` freezes the clock without changing the state, which is what keeps a captured
## handle tracking the hand exactly and leaves no jump on release.
var ambient := true
var ambient_hold := false
## The one clock. Seconds since the node was made, pushed to the shader every tick, and the
## origin the grow-in and the palette drift are both measured from. A harness can step it by
## calling tick() with the delta it wants, which the shader's own TIME would not allow.
var anim_t := 0.0
var breathe_t := 0.0
## Morph progress, 1.0 when there is none. `morph_to` is the preset it is heading for.
var morph_t := 1.0
var morph_to := -1

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
## The seed frame's own box, walked from its real beam corners. Every published bound is merged
## from this, so a frame that is not a cube still reports its reach honestly.
var seed_box := AABB()

var _mmi: MultiMeshInstance3D
var _mat: ShaderMaterial
var _shader: Shader
var _shader_nocull: Shader
var _grad: Gradient
var _ramp: GradientTexture1D
var _palette: Array = []
var _seed_kind := ""
var _born_at := -10000.0
## The maps the morph runs between, both padded to a common length, and the seed frame it
## has to swap to halfway. Kept apart from `base` so landing can restore the table's own
## entry rather than whatever the last interpolation rounded to.
var _morph_from: Array = []
var _morph_to_maps: Array = []
var _morph_seed := ""


func _init() -> void:
	name = "IFS"
	# Half the child maps have a negative determinant, and Godot flips the front face for a
	# mirrored MeshInstance3D but not per instance inside a MultiMesh. The beams are closed
	# boxes shaded by axis rather than by facing, so a mirrored frame draws its far faces in
	# the same colours: IFS-1 measured no visible difference between culling and not. The
	# shader therefore declares culling on, and set_cull_disabled() serves the harness probe.
	_shader = load("res://shaders/ifs.gdshader")
	_mat = ShaderMaterial.new()
	_mat.shader = _shader
	_grad = Gradient.new()
	_ramp = GradientTexture1D.new()
	_ramp.gradient = _grad
	_ramp.width = RAMP_W
	# Float texels, so a palette entry survives the ramp unrounded and the check can compare
	# what it asked for with what the shader will sample.
	_ramp.use_hdr = true
	_mat.set_shader_parameter("ramp", _ramp)
	_mat.set_shader_parameter("grow_s", GROW_S)
	_mat.set_shader_parameter("scroll", SCROLL)
	_mat.set_shader_parameter("radius_mix", RADIUS_MIX)
	set_palette([])
	_mmi = MultiMeshInstance3D.new()
	_mmi.name = "Frames"
	_mmi.material_override = _mat
	_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	# Colours carry the packed parent origin, custom data the level, radius and birth. See
	# the note at the top of shaders/ifs.gdshader for why the origin lives in the colour.
	mm.use_colors = true
	mm.use_custom_data = true
	_mmi.multimesh = mm
	add_child(_mmi)
	set_preset(0)
	visible = false


## Load a preset: its seed frame, its base maps and its own default detail rung. Geometry is
## not rebuilt here; the caller builds, because a preset change usually resets other parameters
## in the same breath and one rebuild is enough.
func set_preset(i: int) -> void:
	preset = clampi(i, 0, PRESETS.size() - 1)
	var p: Dictionary = PRESETS[preset]
	# duplicate(), because PRESETS is a const and therefore read-only: assigning its array
	# straight through would hand callers a `base` they cannot experiment on.
	base = (p["maps"] as Array).duplicate()
	detail = int(p["detail"])
	# Setting a preset outright is the other direction from morphing to one, so it ends any
	# morph in flight rather than letting the next tick drag the shape back off this one.
	morph_t = 1.0
	morph_to = -1
	_load_seed(String(p["seed"]))


## The seed frame and everything derived from it. Apart from set_preset this is what a morph
## calls at its midpoint, where the frame changes under the grow-in rather than beside it.
func _load_seed(kind: String) -> void:
	if kind == _seed_kind:
		return
	_seed_kind = kind
	beams = _frame_beams(kind)
	seed_mesh = _build_seed()
	seed_tris = _triangles_of(seed_mesh)
	seed_box = _box_of(beams)
	_mmi.multimesh.mesh = seed_mesh


static func preset_name(i: int) -> String:
	return String(PRESETS[clampi(i, 0, PRESETS.size() - 1)]["name"])


## The rung the current preset opens at, so RESET and a preset change land on the same shape.
func preset_detail() -> int:
	return int(PRESETS[preset]["detail"])


## The rung a held handle previews at. Per preset, because the branching factor is too.
func drag_detail() -> int:
	return int(PRESETS[preset]["drag"])


# --- ambient ----------------------------------------------------------------

## Advance the clocks and do whatever per-frame rebuild breathing or a morph is asking for.
## Returns true on the one frame a morph lands, which is when the caller has to resync the
## DETAIL rung and the guides against the preset that just arrived.
func tick(delta: float) -> bool:
	anim_t += delta
	_mat.set_shader_parameter("anim_t", anim_t)
	# A captured handle owns the shape. Freezing the clock rather than dropping the offset is
	# what leaves no jump at capture and none on release either.
	if ambient_hold:
		return false
	if morph_t < 1.0:
		morph_t = minf(morph_t + delta / MORPH_S, 1.0)
		if morph_t >= 0.5 and _morph_seed != _seed_kind:
			# Halfway, where the two rules are equally far away and the swap has the least to
			# disagree with. The grow-in on landing covers the rest.
			_load_seed(_morph_seed)
		if morph_t >= 1.0:
			# Land on the table's own entry, not on whatever the last interpolation rounded
			# to, and take the preset's opening rung with it.
			set_preset(morph_to)
			morph_to = -1
			build()
			return true
		_rebuild_live()
		return false
	if ambient:
		breathe_t += delta
		_rebuild_live()
	return false


## Travel to another preset's maps over MORPH_S. Retargets from wherever the shape is now, so
## stepping again mid-morph continues from the interpolated state rather than snapping back.
## The caller owns the mirrors, the depth and the undo, as it does for a plain preset change.
func begin_morph(i: int) -> void:
	var target := clampi(i, 0, PRESETS.size() - 1)
	var from: Array = live_maps()
	var to: Array = PRESETS[target]["maps"] as Array
	var n := maxi(from.size(), to.size())
	_morph_from = _pad(from, n)
	_morph_to_maps = _pad(to, n)
	_morph_seed = String(PRESETS[target]["seed"])
	morph_to = target
	morph_t = 0.0
	_rebuild_live()


func is_morphing() -> bool:
	return morph_t < 1.0


## Land any morph on its target now, without animating the rest of it. MOTION is deliberately
## left alone: it is a look setting like the palette, not part of the shape.
func settle() -> void:
	if morph_to >= 0:
		set_preset(morph_to)
	morph_t = 1.0
	morph_to = -1
	build(false)


## Skip to the end of the grow-in. For a still capture, where four rendered frames is not
## enough time for a 0.6 s animation and every picture would come back half built.
func finish_grow() -> void:
	_born_at = anim_t - 10000.0
	_mat.set_shader_parameter("born_at", _born_at)


## The maps build() actually uses: the banked rule, or the morph's interpolation of it, with
## the ambient offset on top. Nothing here is ever written back to `base`.
func live_base() -> Array:
	var b := live_maps()
	if not ambient:
		return b
	return _breathed(b, breathe_t)


## The maps without the ambient offset: `base`, or where the morph has got to. This is the
## state a retarget continues from, which is why breathing must not be in it.
func live_maps() -> Array:
	if morph_t >= 1.0:
		return base
	var t := morph_t * morph_t * (3.0 - 2.0 * morph_t)
	var out: Array = []
	for i in _morph_from.size():
		var a: Array = _morph_from[i]
		var b: Array = _morph_to_maps[i]
		out.append([
			lerpf(float(a[0]), float(b[0]), t),
			(a[1] as Vector3).lerp(b[1] as Vector3, t),
			(a[2] as Vector3).lerp(b[2] as Vector3, t)])
	return out


## The ambient offset. The contraction breathes a few percent and the twist turns, both of
## which compound with every generation, so the outer frames carry the visible movement.
static func _breathed(b: Array, t: float) -> Array:
	var s := 1.0 + BREATHE_AMP * sin(TAU * t / BREATHE_S)
	var deg := 360.0 * fposmod(t / TWIST_S, 1.0)
	var out: Array = []
	for m in b:
		var e: Vector3 = (m[2] as Vector3) if m.size() > 2 else Vector3.ZERO
		out.append([float(m[0]) * s, m[1] as Vector3, e + Vector3(0.0, deg, 0.0)])
	return out


## A map list at a fixed length and a fixed shape, so a morph can walk two rules of different
## sizes index by index. The shorter one repeats its last map, which lands the extra child on
## top of its neighbour at the start and separates it as the morph runs.
static func _pad(maps: Array, n: int) -> Array:
	var out: Array = []
	for i in n:
		var m: Array = maps[mini(i, maps.size() - 1)]
		out.append([float(m[0]), m[1] as Vector3,
			(m[2] as Vector3) if m.size() > 2 else Vector3.ZERO])
	return out


## The per-frame rebuild that breathing and morphing share: the drag rung, never the full
## one, and never a grow-in. A morph takes the lower of the two presets' rungs, because the
## branching factor is already the target's from the first frame that pads the map list.
func _rebuild_live() -> void:
	var want := detail
	var rung := drag_detail()
	if morph_to >= 0:
		rung = mini(rung, int(PRESETS[morph_to]["drag"]))
	detail = mini(want, rung)
	build(false)
	detail = want


## Rebuild for the current parameters. Synchronous and deterministic: same parameters in,
## identical buffer out. Returns the instance count.
##
## `grow` restarts the grow-in, which every full rebuild wants and no per-frame one does: a
## drag has to track the hand exactly, and breathing or morphing would restart the animation
## on every frame and so never show any of it.
func build(grow := true) -> int:
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
	var dep := clampf(depth, DEPTH_MIN, DEPTH_MAX)
	var maps := child_maps(n1.normalized(), d1, n2.normalized(), d2, live_base())
	# Where each child map sends the origin back to, which is the parent's origin expressed in
	# the child's own mesh space and a constant per map. The grow-in scales up out of it.
	var back := PackedVector3Array()
	var span := 1e-3
	for m in maps:
		var p: Vector3 = m.affine_inverse().origin
		back.append(p)
		span = maxf(span, maxf(absf(p.x), maxf(absf(p.y), absf(p.z))))

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
	# Which child map produced each instance, and so which entry of `back` its parent sits at.
	# The root has no parent and grows out of its own centre.
	var from_map := PackedInt32Array([-1])
	var start := 0
	for k in range(1, fit + 1):
		var stop := xforms.size()
		for i in range(start, stop):
			for j in maps.size():
				xforms.append(xforms[i] * maps[j])
				levels.append(k)
				from_map.append(j)
		start = stop
	levels_built = fit
	instance_count = xforms.size()
	triangle_count = instance_count * seed_tris

	# The outermost instance, so the radial coordinate the shader colours by spans exactly
	# [0, 1] whatever the preset, the rung and the depth stretch have made of the shape.
	var far := 0.0
	for t in xforms:
		far = maxf(far, t.origin.length())
	var inv_r := 1.0 / maxf(far, 1e-4)
	var inv_lvl := 1.0 / float(maxi(levels_built, 1))
	var birth_span := float(levels_built) + BIRTH_RADIUS
	var inv_birth := 1.0 / maxf(birth_span, 1e-3)
	var inv_span := 0.5 / span

	var buf := PackedFloat32Array()
	buf.resize(instance_count * 20)
	bounds = xforms[0] * seed_box
	for i in instance_count:
		var t: Transform3D = xforms[i]
		bounds = bounds.merge(t * seed_box)
		var b := t.basis
		var o := t.origin
		var j := i * 20
		buf[j + 0] = b.x.x; buf[j + 1] = b.y.x; buf[j + 2] = b.z.x; buf[j + 3] = o.x
		buf[j + 4] = b.x.y; buf[j + 5] = b.y.y; buf[j + 6] = b.z.y; buf[j + 7] = o.y
		buf[j + 8] = b.x.z; buf[j + 9] = b.y.z; buf[j + 10] = b.z.z; buf[j + 11] = o.z
		var p: Vector3 = back[from_map[i]] if from_map[i] >= 0 else Vector3.ZERO
		buf[j + 12] = p.x * inv_span + 0.5
		buf[j + 13] = p.y * inv_span + 0.5
		buf[j + 14] = p.z * inv_span + 0.5
		buf[j + 15] = 1.0
		var rad := clampf(o.length() * inv_r, 0.0, 1.0)
		buf[j + 16] = clampf(float(levels[i]) * inv_lvl, 0.0, 1.0)
		buf[j + 17] = rad
		buf[j + 18] = clampf((float(levels[i]) + BIRTH_RADIUS * rad) * inv_birth, 0.0, 1.0)
		buf[j + 19] = 0.0

	var mm := _mmi.multimesh
	mm.instance_count = 0
	mm.instance_count = instance_count
	if instance_count > 0:
		mm.buffer = buf
	# MultiMesh instances are not culled individually, and an auto AABB would be recomputed
	# from the buffer anyway. Publishing ours makes the bounds check mean something. Grown
	# from the parent origins, every instance stays inside its finished box, so the bound a
	# still shape publishes covers the animation too.
	_mmi.custom_aabb = bounds
	_mat.set_shader_parameter("origin_span", span)
	_mat.set_shader_parameter("grow_span", birth_span * GROW_STAGGER)
	# A grow-in started mid-morph would be restarted by the next frame's rebuild and never be
	# seen; the morph runs its own on the frame it lands.
	if grow and morph_t >= 1.0:
		_born_at = anim_t
		_mat.set_shader_parameter("born_at", _born_at)
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


## Every child map: each base map composed with each of {I, R1, R2, R2*R1}. Reflecting after
## the offset is what spreads the children over the mirrored copies of their base position;
## reflecting first would stack them all back onto it. A base map's own optional rotation goes
## inside the contraction, so a child is reflect(rotate(contract(p)) + offset) and the turn
## compounds with every generation.
static func child_maps(n1: Vector3, d1: float, n2: Vector3, d2: float,
		base_maps: Array) -> Array[Transform3D]:
	var r1 := reflection(n1, d1)
	var r2 := reflection(n2, d2)
	var rots: Array[Transform3D] = [Transform3D.IDENTITY, r1, r2, r2 * r1]
	var maps: Array[Transform3D] = []
	for m in base_maps:
		var c := clampf(float(m[0]), 0.05, 0.9)
		var bas := Basis.from_scale(Vector3(c, c, c))
		if m.size() > 2:
			var e: Vector3 = m[2]
			bas = Basis.from_euler(Vector3(deg_to_rad(e.x), deg_to_rad(e.y), deg_to_rad(e.z))) * bas
		var b := Transform3D(bas, m[1] as Vector3)
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
		for beam in beams:
			# The beam's own frame carried into the instance: column 2 is its length and the
			# other two its cross-section, so a tetrahedron edge measures like a cube edge.
			var bb: Basis = t.basis * (beam[2] as Basis)
			var h: Vector3 = beam[1]
			var half: Vector3 = _col(bb, 2) * h.z
			var mid: Vector3 = t * (beam[0] as Vector3)
			var r: float = _col(bb, 0).length() * h.x + _col(bb, 1).length() * h.y
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
## Rebuilds the ramp the shader samples and nothing else, so a theme change costs one small
## texture and never touches the geometry or the instance buffer.
##
## The ramp is cyclic: N palette entries land on the N sample points i/N, and the first
## colour is repeated at 1.0. The colour coordinate scrolls, so an open ramp would drift
## through a seam once a cycle; a closed one has nowhere to tear.
func set_palette(pal: Array) -> void:
	_palette = pal
	var cols: Array = pal if not pal.is_empty() else DEFAULT_PALETTE
	var n := cols.size()
	var offs := PackedFloat32Array()
	var out := PackedColorArray()
	for i in n + 1:
		offs.append(float(i) / float(n))
		out.append(Color(cols[i % n]))
	_grad.offsets = offs
	_grad.colors = out


## The texture the shader samples, for a check that wants to read what was built rather than
## trust that building it was asked for.
func ramp_texture() -> GradientTexture1D:
	return _ramp


func set_cull_disabled(on: bool) -> void:
	# A render_mode is compile-time, so the other setting is a second compiled shader rather
	# than a property. It is the same source with one word changed, built the first time the
	# probe asks for it, so there is no second file to keep in step and the app never pays.
	if on and _shader_nocull == null:
		_shader_nocull = Shader.new()
		_shader_nocull.code = _shader.code.replace("cull_back", "cull_disabled")
	_mat.shader = _shader_nocull if on else _shader


## [centre, half-extents, frame] for every edge of a seed polyhedron. The frame's z column is
## the edge direction and the other two are the cross-section, so one beam shape serves a cube
## edge and a tetrahedron edge alike.
static func _frame_beams(kind: String) -> Array:
	var verts: Array = FRAME_VERTS[kind]
	var out: Array = []
	for e in FRAME_EDGES[kind]:
		var a: Vector3 = verts[e[0]]
		var b: Vector3 = verts[e[1]]
		var d: Vector3 = b - a
		var h := Vector3(BEAM_HW, BEAM_HW, d.length() * 0.5 + BEAM_HW)
		out.append([(a + b) * 0.5, h, _beam_basis(d.normalized())])
	return out


## A right-handed frame whose z column is the edge direction. Both cross products come out
## exact for an axis-aligned edge, which is what keeps the cube frame's vertices identical to
## the hand-rolled builder this replaced.
static func _beam_basis(dir: Vector3) -> Basis:
	var up := Vector3.UP if absf(dir.y) < 0.9 else Vector3.RIGHT
	var p := up.cross(dir).normalized()
	return Basis(p, dir.cross(p).normalized(), dir)


## The box a set of beams occupies, walked from their real corners rather than assumed from a
## half-extent constant. For the cube frame it comes out at exactly +-SEED_HALF.
static func _box_of(bs: Array) -> AABB:
	var lo := Vector3.ZERO
	var hi := Vector3.ZERO
	var first := true
	for beam in bs:
		var c: Vector3 = beam[0]
		var h: Vector3 = beam[1]
		var b: Basis = beam[2]
		for sx in [-1.0, 1.0]:
			for sy in [-1.0, 1.0]:
				for sz in [-1.0, 1.0]:
					var p: Vector3 = c + _col(b, 0) * (h.x * sx) + _col(b, 1) * (h.y * sy) \
						+ _col(b, 2) * (h.z * sz)
					if first:
						lo = p
						hi = p
						first = false
					lo = Vector3(minf(lo.x, p.x), minf(lo.y, p.y), minf(lo.z, p.z))
					hi = Vector3(maxf(hi.x, p.x), maxf(hi.y, p.y), maxf(hi.z, p.z))
	return AABB(lo, hi - lo)


func _build_seed() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for beam in beams:
		_add_beam(st, beam[0], beam[1], beam[2])
	# No index(): it merged corner vertices that different beams shade differently, and at
	# 144 triangles there is nothing worth saving.
	return st.commit()


func _add_beam(st: SurfaceTool, c: Vector3, h: Vector3, b: Basis) -> void:
	for a in 3:
		var u := (a + 1) % 3
		var v := (a + 2) % 3
		for s in [1.0, -1.0]:
			var n: Vector3 = _col(b, a) * s
			var shade := _shade_of(n)
			var uu: Vector3 = _col(b, u) * (h[u] * s)
			var vv: Vector3 = _col(b, v) * h[v]
			var o: Vector3 = c + _col(b, a) * (h[a] * s)
			var quad := [o - uu - vv, o + uu - vv, o + uu + vv, o - uu + vv]
			for idx in [0, 1, 2, 0, 2, 3]:
				st.set_normal(n)
				# In the UV and not in vertex colour: a MultiMesh multiplies the instance
				# colour into the vertex one, and the instance colour is carrying the parent
				# origin the grow-in needs. The UV is otherwise unused on this mesh.
				st.set_uv(Vector2(shade, 0.0))
				st.add_vertex(quad[idx])


## Face shade from the face normal, weighted by the square of its construction-axis components.
## An axis-aligned face reads exactly AXIS_SHADE[a], which is what the cube frame has always
## done; a tetrahedron or octahedron beam, whose faces point between two axes, lands between
## the two shades instead of being snapped to whichever one is nearest.
static func _shade_of(n: Vector3) -> float:
	return n.x * n.x * AXIS_SHADE[0] + n.y * n.y * AXIS_SHADE[1] + n.z * n.z * AXIS_SHADE[2]


static func _triangles_of(m: ArrayMesh) -> int:
	var arr := m.surface_get_arrays(0)
	var idx = arr[Mesh.ARRAY_INDEX]
	if idx != null:
		return (idx as PackedInt32Array).size() / 3
	return (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
