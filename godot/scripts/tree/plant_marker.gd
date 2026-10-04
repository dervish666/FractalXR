extends Node3D
class_name PlantMarker

## A ring on the floor where the next tree will take root.
##
## Planting is a ray at the floor and a trigger pull, and until this existed the only
## feedback was a tree appearing somewhere near where you thought you were pointing. The
## ring closes that loop: it is drawn from exactly the hit that _plant_tree_at would be
## given, so what you see is where the trunk lands, not an estimate of it.
##
## World-locked, like the orbit trace. It is deliberately NOT a child of the particle
## cloud: grab moves the cloud, and a marker that drifted off the spot you were pointing
## at would be worse than none.
##
## It also names the species the trigger will grow, in that species' colour, because with
## a mixed bag the next tree is otherwise a surprise you cannot plan a grove around.

const RADIUS := 0.12          # metres. A trunk is ~0.10 wide at the base.
const THICKNESS := 0.008
const LIFT := 0.004           # off the floor plane, so it does not fight the ground for z
const FADE_SPEED := 12.0      # ~80 ms; fast enough to feel attached to the hand

var _ring: MeshInstance3D
var _mat: StandardMaterial3D
var _shown := 0.0
var _target := 0.0
var _tint := Color(0.85, 0.95, 0.75)
var _theme_tint := Color(0.85, 0.95, 0.75)
var _label: Label3D
var _species := ""


func _init() -> void:
	name = "PlantMarker"
	var torus := TorusMesh.new()
	torus.inner_radius = RADIUS - THICKNESS
	torus.outer_radius = RADIUS
	torus.rings = 32
	torus.ring_segments = 6
	_mat = StandardMaterial3D.new()
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mat.disable_receive_shadows = true
	_mat.no_depth_test = false
	_ring = MeshInstance3D.new()
	_ring.name = "Ring"
	_ring.mesh = torus
	_ring.material_override = _mat
	_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_ring)
	_label = Label3D.new()
	_label.name = "Species"
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.pixel_size = 0.0009
	_label.font_size = 64
	_label.outline_size = 10
	_label.outline_modulate = Color(0, 0, 0, 0.6)
	_label.position = Vector3(0.0, 0.07, 0.0)
	_label.shaded = false
	_label.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_label)
	visible = false
	_apply_alpha()


## The brightest palette stop, so the marker belongs to whatever theme is showing.
func set_palette(pal: Array) -> void:
	if pal.size() < 5:
		return
	var c: Vector3 = pal[3]
	_theme_tint = Color(clampf(c.x, 0.0, 1.0), clampf(c.y, 0.0, 1.0), clampf(c.z, 0.0, 1.0))
	_species = ""   # recolour on the next set_species
	_tint = _theme_tint
	_apply_alpha()


## The species the next trigger pull grows: its name over the ring, both in its colour
## (or the theme's, for a species that wears the theme unchanged).
func set_species(s: String) -> void:
	if s == _species:
		return
	_species = s
	_label.text = s.to_upper()
	var t: Variant = FractalTree.species_tint(s)
	_tint = _theme_tint.lerp(t, 0.7) if t != null else _theme_tint
	_apply_alpha()


## Called every frame from the tree-mode branch. `hit` is the same world-floor point
## _plant_tree_at receives, so the ring and the trunk cannot disagree.
func show_at(hit: Vector2) -> void:
	global_position = Vector3(hit.x, LIFT, hit.y)
	_target = 1.0
	visible = true


func hide_marker() -> void:
	_target = 0.0


func update(delta: float) -> void:
	if is_equal_approx(_shown, _target):
		if _shown <= 0.001 and visible:
			visible = false
		return
	_shown = move_toward(_shown, _target, delta * FADE_SPEED)
	visible = _shown > 0.01
	_apply_alpha()


func _apply_alpha() -> void:
	if _mat == null:
		return
	var c := _tint
	c.a = 0.75 * _shown
	_mat.albedo_color = c
	if _label != null:
		var lc := _tint
		lc.a = 0.9 * _shown
		_label.modulate = lc
		_label.outline_modulate = Color(0, 0, 0, 0.6 * _shown)
		_label.visible = _species != "" and _shown > 0.01
