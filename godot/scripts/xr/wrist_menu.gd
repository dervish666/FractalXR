extends Node3D
class_name WristMenu

## Wrist menu: a real Godot UI rendered to a SubViewport and shown on the left forearm.
##
## The first version used Label3D rows to avoid viewport plumbing. That plumbing is
## worth it at this fidelity: StyleBoxFlat gives rounded corners, borders and proper
## layout containers, and the result matches the refined WebXR panel rather than looking
## like debug text floating in space.
##
## Hit testing does NOT synthesise mouse events. The controller ray is intersected with
## the panel plane, converted to viewport pixels, and tested against each tile's rect.
## That is fewer moving parts than faking input, and it cannot get out of step with
## Godot's focus handling.
##
## ADDING A SETTING is one entry in the spec passed to build(): a section, a label, a
## closure that reads the current value, and a closure that advances it. Nothing in here
## knows what a particle count is.

# Shaped for a forearm: narrow and long, rather than a square slab sitting across it.
# The viewport is generously tall because the content is laid out top-down and anything
# that overflows is simply clipped, with no scrollbar to tell you it happened.
const VIEW_SIZE := Vector2i(760, 900)
const PANEL_METRES := Vector2(0.185, 0.219)
## Tiles per row. Sections wrap instead of squeezing, so a section with six settings
## does not shrink every tile in it past the point of being readable or hittable.
const COLUMNS := 4
const REVEAL_DOT := 0.55
const FADE_SPEED := 7.0

const BG := Color(0.055, 0.075, 0.115, 0.94)
const BORDER := Color(0.30, 0.38, 0.50, 0.55)
const TILE_BG := Color(0.11, 0.14, 0.20, 0.95)
const TILE_BORDER := Color(0.26, 0.33, 0.44, 0.7)
const HOT_BG := Color(0.22, 0.16, 0.24, 0.98)
const HOT_BORDER := Color(0.95, 0.55, 0.75, 0.95)
const LABEL := Color(0.90, 0.93, 0.98)
const VALUE := Color(0.98, 0.62, 0.80)
const SECTION := Color(0.48, 0.56, 0.68)
const DIM := Color(0.62, 0.70, 0.80)

class Item:
	var section: String
	var label: String
	var read: Callable
	var advance: Callable
	var wide := false
	## Optional predicate. A false tile is hidden, and a Container skips hidden children,
	## so the grid reflows around it. That is how a bulb-only setting can exist without
	## taking a slot in flame mode.
	var visible_when: Callable
	func _init(sec: String, l: String, r: Callable, a: Callable, w := false,
			vis := Callable()) -> void:
		section = sec
		label = l
		read = r
		advance = a
		wide = w
		visible_when = vis

var items: Array[Item] = []
var status_main: Callable = Callable()
var status_side: Callable = Callable()
var title: Callable = Callable()

var _vp: SubViewport
var _tiles: Array[PanelContainer] = []
var _values: Array[Label] = []
var _title_label: Label
var _side_label: Label
var _status_label: Label
var _quad: MeshInstance3D          # desktop preview fallback
var _layer: OpenXRCompositionLayerQuad
var _hovered := -1
var _hit_distance := 0.35
var _shown := 0.0
var _head: Node3D
var _pointer: Node3D
## An OpenXR composition layer keeps being composited when the app loses focus, so it
## draws OVER the Quest system menu and hides the system pointer. That is not a cosmetic
## bug: it left the headset effectively unusable until it was restarted. The layer must
## be hidden the moment focus is lost.
var _focused := true
## A beam from the pointing hand. Highlighting the hovered tile is not enough on its own:
## without a visible ray there is nothing to aim, so you hunt for the highlight instead
## of pointing at what you want.
var _ray: MeshInstance3D
var _dot: MeshInstance3D


func setup(head: Node3D, pointer: Node3D) -> void:
	_head = head
	_pointer = pointer
	_build_viewport()
	_build_quad()
	_build_pointer()
	var xri := XRServer.find_interface("OpenXR") as OpenXRInterface
	if xri != null:
		# session_visible means visible but NOT focused: the system menu is up.
		xri.session_visible.connect(func(): _set_focus(false))
		xri.session_focussed.connect(func(): _set_focus(true))
		xri.session_stopping.connect(func(): _set_focus(false))


func _build_pointer() -> void:
	if _pointer == null:
		return
	var beam := CylinderMesh.new()
	beam.top_radius = 0.0015
	beam.bottom_radius = 0.0025
	beam.height = 1.0
	beam.radial_segments = 6
	beam.rings = 0
	_ray = MeshInstance3D.new()
	_ray.mesh = beam
	_ray.material_override = _emissive(Color(0.55, 0.8, 1.0, 0.5))
	# The cylinder runs along Y, the controller points down -Z.
	_ray.rotation_degrees = Vector3(-90, 0, 0)
	_ray.visible = false
	_pointer.add_child(_ray)

	var tip := SphereMesh.new()
	tip.radius = 0.006
	tip.height = 0.012
	tip.radial_segments = 10
	tip.rings = 6
	_dot = MeshInstance3D.new()
	_dot.mesh = tip
	_dot.material_override = _emissive(Color(1.0, 0.72, 0.85, 0.95))
	_dot.visible = false
	_pointer.add_child(_dot)


func _emissive(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = c
	m.no_depth_test = true
	m.render_priority = 95
	return m


func _show_pointer(on: bool, distance: float) -> void:
	if _ray == null:
		return
	_ray.visible = on
	_dot.visible = on
	if not on:
		return
	# The cylinder is centred on its own origin, so push it half its length forward.
	_ray.scale = Vector3(1.0, distance, 1.0)
	_ray.position = Vector3(0, 0, -distance * 0.5)
	_dot.position = Vector3(0, 0, -distance)


func _set_focus(f: bool) -> void:
	_focused = f
	if not f:
		_shown = 0.0
		visible = false
		if _layer != null:
			_layer.quad_size = Vector2(0.001, 0.001)
		_show_pointer(false, 0.0)


func _build_viewport() -> void:
	_vp = SubViewport.new()
	_vp.size = VIEW_SIZE
	_vp.transparent_bg = true
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.disable_3d = true
	add_child(_vp)

	var root := PanelContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_stylebox_override("panel", _box(BG, BORDER, 22, 2))
	_vp.add_child(root)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 7)
	root.add_child(col)
	var pad := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, 14)
	root.remove_child(col)
	root.add_child(pad)
	pad.add_child(col)

	# Header: name on the left, live status on the right, as in the web build.
	var head_row := HBoxContainer.new()
	col.add_child(head_row)
	_title_label = _label("", 30, LABEL)
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head_row.add_child(_title_label)
	var head_right := VBoxContainer.new()
	head_right.alignment = BoxContainer.ALIGNMENT_END
	head_row.add_child(head_right)
	_side_label = _label("", 18, VALUE)
	_side_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	head_right.add_child(_side_label)
	_status_label = _label("", 15, SECTION)
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	head_right.add_child(_status_label)

	# Sections, in the order they first appear in the item list.
	var seen: Array[String] = []
	for it in items:
		if not seen.has(it.section):
			seen.append(it.section)
	for sec in seen:
		col.add_child(_label(sec.to_upper(), 14, SECTION))
		var grid := GridContainer.new()
		grid.columns = COLUMNS
		grid.add_theme_constant_override("h_separation", 8)
		grid.add_theme_constant_override("v_separation", 8)
		col.add_child(grid)
		for i in items.size():
			if items[i].section == sec:
				grid.add_child(_tile(i))


func _tile(i: int) -> PanelContainer:
	var it := items[i]
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _box(TILE_BG, TILE_BORDER, 12, 1))
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)
	var m := MarginContainer.new()
	for side in ["left", "right"]:
		m.add_theme_constant_override("margin_" + side, 6)
	for side in ["top", "bottom"]:
		m.add_theme_constant_override("margin_" + side, 6)
	p.add_child(m)
	m.add_child(v)
	var l := _label(it.label, 20, LABEL)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(l)
	var val := _label("", 17, VALUE)
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(val)
	while _tiles.size() <= i:
		_tiles.append(null)
		_values.append(null)
	_tiles[i] = p
	_values[i] = val
	return p


func _label(text: String, size: int, colour: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", colour)
	return l


func _box(bg: Color, border: Color, radius: int, width: int) -> StyleBoxFlat:
	var b := StyleBoxFlat.new()
	b.bg_color = bg
	b.border_color = border
	b.set_border_width_all(width)
	b.set_corner_radius_all(radius)
	return b


## Prefer an OpenXR quad composition layer. The runtime composites it at the native
## panel resolution, so the menu stays sharp no matter how far DETAIL scales the app's
## eye buffer down, and it costs our render pass nothing. Rendering it as scene geometry
## meant the text was resampled along with the flame, which looked terrible at low
## render scales for no benefit: the flame is what wants the resolution trade, not the UI.
func _build_layer() -> bool:
	var xri := XRServer.find_interface("OpenXR")
	if xri == null or not xri.is_initialized():
		return false
	_layer = OpenXRCompositionLayerQuad.new()
	_layer.quad_size = PANEL_METRES
	_layer.layer_viewport = _vp
	_layer.alpha_blend = true
	_layer.sort_order = 1        # in front of the projection layer
	add_child(_layer)
	return true


func _build_quad() -> void:
	if _build_layer():
		return
	var mesh := QuadMesh.new()
	mesh.size = PANEL_METRES
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_texture = _vp.get_texture()
	mat.no_depth_test = true
	mat.render_priority = 90
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_quad = MeshInstance3D.new()
	_quad.mesh = mesh
	_quad.material_override = mat
	add_child(_quad)


## Returns true while the pointer is on a tile, so the caller can hand the trigger over.
func update(delta: float) -> bool:
	if not _focused:
		visible = false
		_set_live(false)
		_hovered = -1
		_show_pointer(false, 0.0)
		return false
	var facing := _wrist_facing()
	_shown = clampf(_shown + (FADE_SPEED * delta if facing else -FADE_SPEED * delta), 0.0, 1.0)
	visible = _shown > 0.01
	_set_live(visible)
	if _layer != null:
		# Composition layers are not scene geometry, so reveal by growing the quad
		# rather than scaling the node.
		_layer.quad_size = PANEL_METRES * maxf(0.001, _shown)
	else:
		scale = Vector3.ONE * maxf(0.01, _shown)
	if not visible:
		_hovered = -1
		_show_pointer(false, 0.0)
		return false

	var hit := _pointer_pixel()
	_show_pointer(true, _hit_distance)
	var was := _hovered
	_hovered = -1
	if hit.x >= 0.0:
		for i in _tiles.size():
			# A hidden tile keeps its last rect, so it would still swallow the ray.
			if _tiles[i] != null and _tiles[i].visible and _tiles[i].get_global_rect().has_point(hit):
				_hovered = i
				break
	if _hovered != was:
		_restyle()
	_refresh()
	return _hovered >= 0


## A SubViewport is not scene geometry: hiding the parent node does not stop it
## rendering. Folded away, the 760x900 panel was still drawn 72 times a second.
func _set_live(on: bool) -> void:
	var want := SubViewport.UPDATE_ALWAYS if on else SubViewport.UPDATE_DISABLED
	if _vp != null and _vp.render_target_update_mode != want:
		_vp.render_target_update_mode = want


func activate() -> void:
	if _hovered >= 0 and _hovered < items.size():
		items[_hovered].advance.call()
		_refresh()


func _refresh() -> void:
	for i in items.size():
		if _tiles[i] != null and items[i].visible_when.is_valid():
			_tiles[i].visible = bool(items[i].visible_when.call())
		if _values[i] != null and (_tiles[i] == null or _tiles[i].visible):
			_values[i].text = str(items[i].read.call())
	if title.is_valid():
		_title_label.text = str(title.call())
	if status_side.is_valid():
		_side_label.text = str(status_side.call())
	if status_main.is_valid():
		_status_label.text = str(status_main.call())


func _restyle() -> void:
	for i in _tiles.size():
		if _tiles[i] == null:
			continue
		var hot := i == _hovered
		_tiles[i].add_theme_stylebox_override("panel",
			_box(HOT_BG if hot else TILE_BG, HOT_BORDER if hot else TILE_BORDER, 12, 2 if hot else 1))


func _wrist_facing() -> bool:
	if _head == null or not is_inside_tree() or not _head.is_inside_tree():
		return false
	var to_head := (_head.global_transform.origin - global_transform.origin).normalized()
	return global_transform.basis.z.normalized().dot(to_head) > REVEAL_DOT


## Intersect the pointer ray with the panel plane and convert to viewport pixels.
## Returns (-1, -1) when the ray misses.
func _pointer_pixel() -> Vector2:
	if _pointer == null or not is_inside_tree() or not _pointer.is_inside_tree():
		return Vector2(-1, -1)
	var inv := global_transform.affine_inverse()
	var origin := inv * _pointer.global_transform.origin
	var dir := (inv.basis * (-_pointer.global_transform.basis.z)).normalized()
	if absf(dir.z) < 1e-5:
		return Vector2(-1, -1)
	var t := -origin.z / dir.z
	if t < 0.0 or t > 2.0:
		_hit_distance = 0.35
		return Vector2(-1, -1)
	_hit_distance = t
	var hit := origin + dir * t
	var half := (PANEL_METRES * maxf(0.001, _shown)) * 0.5 if _layer != null else PANEL_METRES * 0.5
	var u := (hit.x / half.x + 1.0) * 0.5
	var v := (1.0 - hit.y / half.y) * 0.5
	if u < 0.0 or u > 1.0 or v < 0.0 or v > 1.0:
		_hit_distance = 0.35
		return Vector2(-1, -1)
	return Vector2(u * float(VIEW_SIZE.x), v * float(VIEW_SIZE.y))
