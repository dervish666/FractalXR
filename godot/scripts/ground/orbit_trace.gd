extends Node3D
class_name OrbitTrace

## The orbit of the point under your hand, drawn in the air above the ground: iterate
## z -> z^2 + c from the spot the controller points at and hang each z as a bead over
## its own place on the map, climbing a little per step so the chain lifts off the floor.
## Inside the set the chain spirals and settles; outside it flies off to the bailout.
## This is what the colours on the floor are made of, shown live.
##
## Iteration runs in 64-bit floats on the CPU, so it stays honest well past the float32
## texture's zoom limit; the beads are one MultiMesh of tiny spheres, plus one line strip.

const MAX_POINTS := 120          # a bounded orbit's chain; enough to show it settle
const BAILOUT2 := 16.0          # |z|^2; radius 4, past the classic 2 so the tail shows
const RISE_M := 0.012           # height gained per step
const BASE_M := 0.04            # first bead above the floor
const TOP_M := 1.6              # never higher than this
const REACH_M := 40.0           # world radius the tail is clamped to

var point_count := 0
var _beads: MultiMeshInstance3D
var _line: MeshInstance3D
var _mesh := ImmediateMesh.new()
var _pal: Array = [Vector3(0.1, 0.1, 0.4), Vector3(0.3, 0.2, 0.8), Vector3(0.9, 0.3, 0.6),
	Vector3(1.0, 0.7, 0.2), Vector3(1.0, 1.0, 0.8)]


func _init() -> void:
	name = "Orbit"
	_beads = MultiMeshInstance3D.new()
	_beads.name = "Beads"
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	var sph := SphereMesh.new()
	sph.radius = 1.0
	sph.height = 2.0
	sph.radial_segments = 8
	sph.rings = 4
	mm.mesh = sph
	mm.instance_count = MAX_POINTS
	mm.visible_instance_count = 0
	_beads.multimesh = mm
	var bm := StandardMaterial3D.new()
	bm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bm.vertex_color_use_as_albedo = true
	bm.disable_fog = true
	_beads.material_override = bm
	_beads.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_beads.custom_aabb = AABB(Vector3(-REACH_M, -1.0, -REACH_M), Vector3(2.0 * REACH_M, TOP_M + 2.0, 2.0 * REACH_M))
	add_child(_beads)
	_line = MeshInstance3D.new()
	_line.name = "Line"
	_line.mesh = _mesh
	var lm := StandardMaterial3D.new()
	lm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	lm.vertex_color_use_as_albedo = true
	lm.disable_fog = true
	lm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_line.material_override = lm
	_line.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_line.custom_aabb = _beads.custom_aabb
	add_child(_line)
	visible = false


func set_palette(pal: Array) -> void:
	if pal.size() >= 5:
		_pal = pal.duplicate()


func _colour(t: float) -> Color:
	var f := clampf(t, 0.0, 1.0) * 4.0
	var i := mini(int(f), 3)
	var v: Vector3 = (_pal[i] as Vector3).lerp(_pal[i + 1] as Vector3, f - float(i))
	return Color(v.x, v.y, v.z)


## Pure iteration: the orbit of `p` as fractal-space points, z0 = 0 with c = p for the
## Mandelbrot set, z0 = p with the ground's constant for a Julia set. 64-bit floats.
static func iterate(p: Vector2, julia: bool, julia_c: Vector2) -> PackedVector2Array:
	var zx: float = p.x if julia else 0.0
	var zy: float = p.y if julia else 0.0
	var cx: float = julia_c.x if julia else p.x
	var cy: float = julia_c.y if julia else p.y
	var out := PackedVector2Array()
	for k in MAX_POINTS:
		var nx := zx * zx - zy * zy + cx
		var ny := 2.0 * zx * zy + cy
		zx = nx
		zy = ny
		out.append(Vector2(zx, zy))
		if zx * zx + zy * zy > BAILOUT2:
			break
	return out


## Draw the orbit of the fractal point `p`. `to_world` maps a fractal point to world xz.
func update(p: Vector2, julia: bool, julia_c: Vector2, to_world: Callable, hand_xz: Vector2) -> void:
	var orbit := iterate(p, julia, julia_c)
	var n := orbit.size()
	point_count = n
	var mm := _beads.multimesh
	_mesh.clear_surfaces()
	if n == 0:
		mm.visible_instance_count = 0
		return
	_mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	var escaped := n < MAX_POINTS
	# The start bead marks the spot itself, at the floor.
	var prev := Vector3(hand_xz.x, BASE_M, hand_xz.y)
	_mesh.surface_set_color(_colour(0.0))
	_mesh.surface_add_vertex(prev)
	for k in n:
		var w: Vector2 = to_world.call(orbit[k])
		var d := w - hand_xz
		if d.length() > REACH_M:
			w = hand_xz + d.normalized() * REACH_M
		var t := float(k) / float(maxi(n - 1, 1))
		var y := minf(BASE_M + RISE_M * float(k), TOP_M)
		var pos := Vector3(w.x, y, w.y)
		var c := _colour(t if not escaped else t * 0.8)
		var r := lerpf(0.028, 0.009, t)
		mm.set_instance_transform(k, Transform3D(Basis().scaled(Vector3.ONE * r), pos))
		mm.set_instance_color(k, c)
		# The links fade along the chain: a periodic orbit retraces the same few legs a
		# hundred times, and at full strength that drew a web over the whole map.
		_mesh.surface_set_color(Color(c.r, c.g, c.b, lerpf(0.55, 0.12, t)))
		_mesh.surface_add_vertex(pos)
	_mesh.surface_end()
	mm.visible_instance_count = n
