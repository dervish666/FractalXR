extends RefCounted
class_name TreeLitter

## FLOOR's fallen leaves (forest.gd): glowing discs lying on the floor round each trunk, thick at
## the trunk and thinning out to about the crown's reach, on every side. They replace ROOTS,
## which failed on both counts Sam named in the headset: the roots never met the trunk, and they
## all ran one way.
##
## Drawn with the tree's own leaf material (tree_leaf.gdshader, its `litter` instance uniform), so
## a disc wears its tree's leaf colour, species outline (a sakura drops petals, a pine needles)
## and palette phase, and picks up whatever palette the theme brings. Litter never sways, falls in
## over the two seconds after the canopy is out, and goes first when the tree withers.
##
## Shared, not built per tree: VARIANTS shapes in a unit frame (trunk at the origin, the crown's
## reach at radius 1), each one MultiMesh that every tree's Litter node points at. The tree
## scales its node to its own crown (FractalTree._sync_litter), so a walk recycle moves the litter
## with the tree and builds nothing.

const VARIANTS := 6
const COUNT := 220
const STRIDE := 20
## The innermost discs touch the bark: a 3 m avenue oak's trunk is about 7 cm across and its
## crown reaches about 1.3 m, so 0.03 of the reach sits against it.
const R_MIN := 0.03
## Radius = reach * u^THIN for uniform u: discs per square metre fall off as r^(1/THIN - 2), so
## half of them lie inside a quarter of the reach and the outer ring is a scatter.
const THIN := 2.0

static var _lib: Array[MultiMesh] = []


static func shape(seed_value: int) -> MultiMesh:
	if _lib.is_empty():
		for v in VARIANTS:
			_lib.append(_build(v))
	return _lib[posmod(seed_value, VARIANTS)]


static func _build(v: int) -> MultiMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = 9133 + v * 173
	var buf := PackedFloat32Array()
	buf.resize(COUNT * STRIDE)
	for i in COUNT:
		var r := lerpf(R_MIN, 1.0, pow(rng.randf(), THIN))
		var a := rng.randf() * TAU
		# Unit frame: a 3 m oak's 1.3 m reach makes these 6-12 cm, a little over a canopy leaf.
		var sz := rng.randf_range(0.05, 0.09)
		var b := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(sz, sz, sz))
		var p := Vector3(cos(a) * r, 0.003 + 0.002 * rng.randf(), sin(a) * r)
		var o := i * STRIDE
		buf[o + 0] = b.x.x; buf[o + 1] = b.y.x; buf[o + 2] = b.z.x; buf[o + 3] = p.x
		buf[o + 4] = b.x.y; buf[o + 5] = b.y.y; buf[o + 6] = b.z.y; buf[o + 7] = p.y
		buf[o + 8] = b.x.z; buf[o + 9] = b.y.z; buf[o + 10] = b.z.z; buf[o + 11] = p.z
		# Colour: where on the leaf ramp, as a canopy leaf's. Custom: when it falls (0..1 of the
		# fall), unused, unused, its turn.
		buf[o + 12] = rng.randf(); buf[o + 13] = 0.0; buf[o + 14] = 0.0; buf[o + 15] = 1.0
		buf[o + 16] = rng.randf(); buf[o + 17] = 0.0; buf[o + 18] = 0.0
		buf[o + 19] = rng.randf() * TAU
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = FractalTree.unit_meshes()[1]
	mm.instance_count = COUNT
	mm.buffer = buf
	return mm
