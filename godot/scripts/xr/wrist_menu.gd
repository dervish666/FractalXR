extends Node3D
class_name WristMenu

## Wrist menu: a real Godot UI rendered to a SubViewport and shown on the left forearm.
##
## The panel is a piece of the flame, not an admin slate. It takes its colours from the
## live palette (set_palette, fed by the same cross-fade that recolours the cloud), so a
## theme change recolours the menu at the same pace as the particles. Tiles bloom on
## hover, pulse when pressed, and tick in the pointing hand; the whole thing pours in
## row by row when the wrist turns up. A fixed mode strip sits under the title so MODE
## is never hunted for.
##
## Hit testing does NOT synthesise mouse events. The controller ray is intersected with
## the panel plane, converted to viewport pixels, and tested against each tile's rect.
## That is fewer moving parts than faking input, and it cannot get out of step with
## Godot's focus handling.
##
## ADDING A SETTING is one entry in the spec passed to build(): a section, a label, a
## closure that reads the current value, and a closure that advances it. Nothing in here
## knows what a particle count is. Chain .stepping(func(d)) to let the right stick scrub
## the value both ways while the tile is hovered; .chosen_when(pred) marks a tile in the
## "mode" section as the lit segment.

# Shaped for a forearm: narrow and long, rather than a square slab sitting across it.
# Pixels per metre are fixed at the original 760px / 0.185m, so a taller viewport is a
# taller panel and nothing else about the menu moves.
const VIEW_SIZE := Vector2i(760, 980)
const PX_PER_M := 760.0 / 0.185
const PANEL_METRES := Vector2(VIEW_SIZE.x / PX_PER_M, VIEW_SIZE.y / PX_PER_M)
## Tiles per row. Sections wrap instead of squeezing, so a section with six settings
## does not shrink every tile in it past the point of being readable or hittable.
const COLUMNS := 4
const MODE_SECTION := "mode"
const REVEAL_DOT := 0.55
const REVEAL_SPEED := 5.5      # ~180ms to open
const HIDE_SPEED := 8.0
const HOVER_IN := 14.0
const HOVER_OUT := 6.0
const PULSE_DECAY := 7.0
## Stick scrubbing: first step on the flick, then repeat while held.
const STICK_DEAD := 0.6
const STEP_FIRST_S := 0.42
const STEP_REPEAT_S := 0.24

const FONT_PATH := "res://fonts/SpaceGrotesk-VF.ttf"
const WGHT_TAG := 0x77676874   # 'wght' as an OpenType axis tag

const LABEL := Color(0.93, 0.95, 0.99)
const DIM := Color(0.62, 0.68, 0.78, 0.8)

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
	## Optional step(dir: int). While this tile is hovered the right stick scrubs the
	## value both ways instead of yawing the cloud, so one press back does not mean
	## seven presses round.
	var step: Callable
	## Optional predicate for the mode strip: the tile draws as the chosen segment.
	var selected: Callable
	func _init(sec: String, l: String, r: Callable, a: Callable, w := false,
			vis := Callable()) -> void:
		section = sec
		label = l
		read = r
		advance = a
		wide = w
		visible_when = vis
	func stepping(s: Callable) -> Item:
		step = s
		return self
	func chosen_when(p: Callable) -> Item:
		selected = p
		return self

var items: Array[Item] = []
var status_main: Callable = Callable()
var status_side: Callable = Callable()
var title: Callable = Callable()

# --- palette-derived theme ---------------------------------------------------
var _pal: Array = [Vector3(0, 0, 0), Vector3(0.25, 0, 0.3), Vector3(0.9, 0.2, 0.4),
	Vector3(1, 0.6, 0.1), Vector3(1, 0.95, 0.65)]
var _ink: Color        # panel ground
var _tile_bg: Color
var _line: Color       # borders, hairlines
var _mute: Color       # section headers
var _accent: Color     # values, hover border
var _hot: Color        # hover fill
var _glow: Color       # hover shadow

var _vp: SubViewport
var _root: PanelContainer
var _tiles: Array[PanelContainer] = []
var _styles: Array[StyleBoxFlat] = []
var _values: Array[Label] = []
var _labels: Array[Label] = []
var _hover: Array[float] = []
var _pulse: Array[float] = []
var _title_label: Label
var _side_label: Label
var _foot_label: Label
var _ribbon: TextureRect
var _ribbon_grad: Gradient
var _heads: Array[Label] = []
var _rules: Array[ColorRect] = []
var _quad: MeshInstance3D          # desktop preview fallback
var _layer: OpenXRCompositionLayerQuad
var _hovered := -1
var _hit_distance := 0.35
var _shown := 0.0
var _shown_e := 0.0
var _sections: Dictionary = {}   # section name -> [header Control, GridContainer]
var _head: Node3D
var _pointer: Node3D
var _step_dir := 0
var _step_timer := 0.0
var _wants_stick := false
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
var _ray_mat: StandardMaterial3D
var _dot_mat: StandardMaterial3D

static var _base_font: Font
static var _fonts: Dictionary = {}   # weight -> FontVariation


func setup(head: Node3D, pointer: Node3D) -> void:
	_head = head
	_pointer = pointer
	_derive_theme()
	_build_viewport()
	_build_quad()
	_build_pointer()
	_apply_theme()
	var xri := XRServer.find_interface("OpenXR") as OpenXRInterface
	if xri != null:
		# session_visible means visible but NOT focused: the system menu is up.
		xri.session_visible.connect(func(): _set_focus(false))
		xri.session_focussed.connect(func(): _set_focus(true))
		xri.session_stopping.connect(func(): _set_focus(false))


## Five control colours, dark to light, as Vector3 0..1. Call it whenever the cloud's
## palette changes; the blend is the caller's, so a theme cross-fade recolours the menu
## frame by frame in step with the particles.
func set_palette(pal: Array) -> void:
	if pal.size() < 5:
		return
	_pal = pal
	_derive_theme()
	if _vp != null:
		_apply_theme()


static func _lum(c: Color) -> float:
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b


## Lift a colour toward white until it clears a luminance floor. A theme's bright stop
## can still be a deep blue; value text has to read against near-black regardless.
static func _lift(c: Color, floor_lum: float) -> Color:
	var l := _lum(c)
	if l >= floor_lum:
		return c
	var t := (floor_lum - l) / maxf(1e-3, 1.0 - l)
	return c.lerp(Color.WHITE, clampf(t, 0.0, 1.0))


static func _sink(c: Color, ceil_lum: float) -> Color:
	var l := _lum(c)
	if l <= ceil_lum:
		return c
	return c * (ceil_lum / l)


static func _c(v: Vector3) -> Color:
	return Color(clampf(v.x, 0.0, 1.0), clampf(v.y, 0.0, 1.0), clampf(v.z, 0.0, 1.0))


func _derive_theme() -> void:
	var c1 := _c(_pal[1])
	var c2 := _c(_pal[2])
	var c3 := _c(_pal[3])
	_ink = _sink(Color.BLACK.lerp(c1, 0.45), 0.055)
	_ink.a = 0.93
	_tile_bg = _sink(_ink.lerp(c2, 0.12), 0.09)
	_tile_bg.a = 0.97
	_line = _lift(c2, 0.32)
	_line.a = 0.42
	_mute = _lift(c2, 0.48)
	_mute.a = 0.85
	_accent = _lift(c3, 0.66)
	_hot = _sink(_ink.lerp(c2, 0.5), 0.22)
	_hot.a = 0.98
	_glow = _lift(c2, 0.4)
	_glow.a = 0.0


static func _font(weight: int) -> Font:
	if _fonts.has(weight):
		return _fonts[weight]
	if _base_font == null:
		_base_font = load(FONT_PATH)
	var f: Font
	if _base_font == null:
		f = ThemeDB.fallback_font
	else:
		var fv := FontVariation.new()
		fv.base_font = _base_font
		fv.variation_opentype = {WGHT_TAG: weight}
		# Chevrons and the odd symbol come from the system font, not a tofu box.
		fv.fallbacks = [ThemeDB.fallback_font]
		f = fv
	_fonts[weight] = f
	return f


func _build_pointer() -> void:
	if _pointer == null:
		return
	var beam := CylinderMesh.new()
	beam.top_radius = 0.0012
	beam.bottom_radius = 0.0022
	beam.height = 1.0
	beam.radial_segments = 6
	beam.rings = 0
	_ray_mat = _emissive(Color(0.55, 0.8, 1.0, 0.45))
	_ray = MeshInstance3D.new()
	_ray.mesh = beam
	_ray.material_override = _ray_mat
	# The cylinder runs along Y, the controller points down -Z.
	_ray.rotation_degrees = Vector3(-90, 0, 0)
	_ray.visible = false
	_pointer.add_child(_ray)

	var tip := SphereMesh.new()
	tip.radius = 0.005
	tip.height = 0.010
	tip.radial_segments = 10
	tip.rings = 6
	_dot_mat = _emissive(Color(1.0, 0.72, 0.85, 0.95))
	_dot = MeshInstance3D.new()
	_dot.mesh = tip
	_dot.material_override = _dot_mat
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


func _show_pointer(on: bool, distance: float, hovering: float) -> void:
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
	_dot.scale = Vector3.ONE * (1.0 + 0.7 * hovering)


func _haptic(amplitude: float, seconds: float) -> void:
	var c := _pointer as XRController3D
	if c != null:
		c.trigger_haptic_pulse("haptic", 0.0, amplitude, seconds, 0.0)


func _set_focus(f: bool) -> void:
	_focused = f
	if not f:
		_shown = 0.0
		_shown_e = 0.0
		visible = false
		if _layer != null:
			_layer.quad_size = Vector2(0.001, 0.001)
		_show_pointer(false, 0.0, 0.0)


func _build_viewport() -> void:
	_vp = SubViewport.new()
	_vp.size = VIEW_SIZE
	_vp.transparent_bg = true
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.disable_3d = true
	add_child(_vp)

	_root = PanelContainer.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_theme_stylebox_override("panel", _box(_ink, _line, 26, 1))
	_vp.add_child(_root)

	var pad := MarginContainer.new()
	for side in ["left", "right", "top"]:
		pad.add_theme_constant_override("margin_" + side, 18)
	pad.add_theme_constant_override("margin_bottom", 12)
	_root.add_child(pad)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 9)
	pad.add_child(col)

	# Header: the flame's name, light and large; the live status on the right.
	var head_row := HBoxContainer.new()
	head_row.add_theme_constant_override("separation", 12)
	col.add_child(head_row)
	_title_label = _label("", 34, LABEL, 300)
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	head_row.add_child(_title_label)
	_side_label = _label("", 16, _accent, 500)
	_side_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_side_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_side_label.size_flags_vertical = Control.SIZE_FILL
	head_row.add_child(_side_label)

	# The ribbon: the palette itself, dark to light, as a thin bar under the title.
	_ribbon_grad = Gradient.new()
	var gt := GradientTexture1D.new()
	gt.gradient = _ribbon_grad
	gt.width = 256
	_ribbon = TextureRect.new()
	_ribbon.texture = gt
	_ribbon.stretch_mode = TextureRect.STRETCH_SCALE
	_ribbon.custom_minimum_size = Vector2(0, 3)
	_ribbon.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(_ribbon)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 2)
	col.add_child(gap)

	# Sections, in the order they first appear in the item list. The mode section is a
	# segmented strip: no header, one column per segment.
	var seen: Array[String] = []
	for it in items:
		if not seen.has(it.section):
			seen.append(it.section)
	for sec in seen:
		var count := 0
		for it in items:
			if it.section == sec:
				count += 1
		var head: Control
		if sec == MODE_SECTION:
			head = Control.new()
			head.custom_minimum_size = Vector2(0, 0)
		else:
			head = _section_head(sec)
		col.add_child(head)
		var grid := GridContainer.new()
		grid.columns = count if sec == MODE_SECTION else COLUMNS
		grid.add_theme_constant_override("h_separation", 8)
		grid.add_theme_constant_override("v_separation", 8)
		col.add_child(grid)
		_sections[sec] = [head, grid]
		for i in items.size():
			if items[i].section == sec:
				grid.add_child(_tile(i, sec == MODE_SECTION))

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(spacer)
	_foot_label = _label("", 13, DIM, 400)
	_foot_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	col.add_child(_foot_label)


## Small caps on the left, a hairline running out to the right edge.
func _section_head(sec: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var l := _label(sec.to_upper(), 12, _mute, 600)
	l.add_theme_constant_override("outline_size", 0)
	row.add_child(l)
	_heads.append(l)
	var rule := ColorRect.new()
	rule.color = _line
	rule.custom_minimum_size = Vector2(0, 1)
	rule.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rule.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(rule)
	_rules.append(rule)
	return row


func _tile(i: int, segment: bool) -> PanelContainer:
	var it := items[i]
	var p := PanelContainer.new()
	var sb := _box(_tile_bg, _line, 14, 1)
	p.add_theme_stylebox_override("panel", sb)
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var m := MarginContainer.new()
	for side in ["left", "right"]:
		m.add_theme_constant_override("margin_" + side, 6)
	var vpad := 9 if segment else 7
	for side in ["top", "bottom"]:
		m.add_theme_constant_override("margin_" + side, vpad)
	p.add_child(m)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 1)
	m.add_child(v)
	var l := _label(it.label, 18 if segment else 19, LABEL, 500)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(l)
	var val := _label("", 16, _accent, 400)
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	val.visible = not segment
	v.add_child(val)
	while _tiles.size() <= i:
		_tiles.append(null)
		_styles.append(null)
		_values.append(null)
		_labels.append(null)
		_hover.append(0.0)
		_pulse.append(0.0)
	_tiles[i] = p
	_styles[i] = sb
	_values[i] = val
	_labels[i] = l
	return p


func _label(text: String, size: int, colour: Color, weight: int) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", _font(weight))
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", colour)
	return l


func _box(bg: Color, border: Color, radius: int, width: int) -> StyleBoxFlat:
	var b := StyleBoxFlat.new()
	b.bg_color = bg
	b.border_color = border
	b.set_border_width_all(width)
	b.set_corner_radius_all(radius)
	b.anti_aliasing = true
	return b


## Push the derived palette into everything that holds a colour. Called on every palette
## change, which during a theme cross-fade is every frame; all of it is property sets.
func _apply_theme() -> void:
	var rs := _root.get_theme_stylebox("panel") as StyleBoxFlat
	if rs != null:
		rs.bg_color = _ink
		rs.border_color = _line
	var offs := PackedFloat32Array([0.0, 0.25, 0.5, 0.75, 1.0])
	var cols := PackedColorArray()
	for k in 5:
		cols.append(_c(_pal[k]))
	_ribbon_grad.offsets = offs
	_ribbon_grad.colors = cols
	_side_label.add_theme_color_override("font_color", _accent)
	for h in _heads:
		h.add_theme_color_override("font_color", _mute)
	for r in _rules:
		r.color = _line
	for i in _tiles.size():
		_style_tile(i)
	if _ray_mat != null:
		var rc := _accent
		rc.a = 0.42
		_ray_mat.albedo_color = rc
		_dot_mat.albedo_color = _accent


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
	_wants_stick = false
	if not _focused:
		visible = false
		_set_live(false)
		_hovered = -1
		_show_pointer(false, 0.0, 0.0)
		return false
	var facing := _wrist_facing()
	_shown = clampf(_shown + (REVEAL_SPEED * delta if facing else -HIDE_SPEED * delta), 0.0, 1.0)
	_shown_e = _shown * _shown * (3.0 - 2.0 * _shown)
	visible = _shown > 0.01
	_set_live(visible)
	if _layer != null:
		# Composition layers are not scene geometry, so reveal by growing the quad
		# rather than scaling the node.
		_layer.quad_size = PANEL_METRES * maxf(0.001, _shown_e)
	else:
		scale = Vector3.ONE * maxf(0.01, _shown_e)
	if not visible:
		_hovered = -1
		_show_pointer(false, 0.0, 0.0)
		_animate(delta)
		return false

	var hit := _pointer_pixel()
	var was := _hovered
	_hovered = -1
	if hit.x >= 0.0:
		for i in _tiles.size():
			# A hidden tile keeps its last rect, so it would still swallow the ray.
			if _tiles[i] != null and _tiles[i].visible and _tiles[i].get_global_rect().has_point(hit):
				_hovered = i
				break
	if _hovered != was:
		_step_dir = 0
		_step_timer = 0.0
		if _hovered >= 0:
			_haptic(0.18, 0.010)
	_scrub(delta)
	_show_pointer(true, _hit_distance, _hover[_hovered] if _hovered >= 0 else 0.0)
	_animate(delta)
	_refresh()
	return _hovered >= 0


## The right stick scrubs a hovered dial. Flick for one step; hold for a slow repeat.
func _scrub(delta: float) -> void:
	if _hovered < 0 or not items[_hovered].step.is_valid():
		return
	_wants_stick = true
	var c := _pointer as XRController3D
	var x := 0.0
	if c != null and c.get_has_tracking_data():
		x = c.get_vector2("primary").x
	if absf(x) < STICK_DEAD:
		_step_dir = 0
		_step_timer = 0.0
		return
	var dir := 1 if x > 0.0 else -1
	_step_timer -= delta
	if dir != _step_dir:
		_step_dir = dir
		_step_timer = STEP_FIRST_S
	elif _step_timer > 0.0:
		return
	else:
		_step_timer = STEP_REPEAT_S
	items[_hovered].step.call(dir)
	_pulse[_hovered] = 1.0
	_haptic(0.3, 0.012)


## True while a hovered tile owns the right stick, so the host leaves the cloud alone.
func wants_stick() -> bool:
	return _wants_stick


## A SubViewport is not scene geometry: hiding the parent node does not stop it
## rendering. Folded away, the panel was still drawn 72 times a second.
func _set_live(on: bool) -> void:
	var want := SubViewport.UPDATE_ALWAYS if on else SubViewport.UPDATE_DISABLED
	if _vp != null and _vp.render_target_update_mode != want:
		_vp.render_target_update_mode = want


func activate() -> void:
	if _hovered >= 0 and _hovered < items.size():
		items[_hovered].advance.call()
		_pulse[_hovered] = 1.0
		_haptic(0.55, 0.025)
		_refresh()


func _refresh() -> void:
	for i in items.size():
		if _tiles[i] != null and items[i].visible_when.is_valid():
			_tiles[i].visible = bool(items[i].visible_when.call())
	# A section with nothing showing takes no room: header and grid go together.
	for sec in _sections:
		var pair: Array = _sections[sec]
		var any := false
		for i in items.size():
			if items[i].section == sec and _tiles[i] != null and _tiles[i].visible:
				any = true
				break
		(pair[0] as Control).visible = any
		(pair[1] as Control).visible = any
	for i in items.size():
		if _values[i] != null and _values[i].visible and (_tiles[i] == null or _tiles[i].visible):
			var v := str(items[i].read.call())
			if i == _hovered and items[i].step.is_valid():
				v = "‹  %s  ›" % v
			_values[i].text = v
	if title.is_valid():
		_title_label.text = str(title.call())
	if status_side.is_valid():
		_side_label.text = str(status_side.call())
	if status_main.is_valid():
		_foot_label.text = str(status_main.call())


## Per-frame motion: hover bloom in and out, press pulse, and the row-by-row pour when
## the panel opens. Only tiles whose state is moving get restyled.
func _animate(delta: float) -> void:
	for i in _tiles.size():
		var p := _tiles[i]
		if p == null:
			continue
		var target := 1.0 if i == _hovered else 0.0
		var h := _hover[i]
		var moving := false
		if absf(h - target) > 0.001:
			var k := HOVER_IN if target > h else HOVER_OUT
			h = lerpf(h, target, minf(1.0, k * delta))
			if absf(h - target) < 0.004:
				h = target
			_hover[i] = h
			moving = true
		if _pulse[i] > 0.0:
			_pulse[i] = maxf(0.0, _pulse[i] - PULSE_DECAY * delta)
			moving = true
		# Pour in: tiles further down the panel arrive later.
		var row_t := clampf(p.get_global_rect().position.y / float(VIEW_SIZE.y), 0.0, 1.0)
		var pour := clampf((_shown_e - row_t * 0.45) / 0.55, 0.0, 1.0)
		pour = pour * pour * (3.0 - 2.0 * pour)
		var alpha := pour
		if absf(p.modulate.a - alpha) > 0.002:
			p.modulate.a = alpha
			moving = true
		if moving or (items[i].selected.is_valid()):
			p.pivot_offset = p.size * 0.5
			var s := (0.92 + 0.08 * pour) * (1.0 + 0.02 * h - 0.05 * _pulse[i])
			p.scale = Vector2.ONE * s
			_style_tile(i)


func _style_tile(i: int) -> void:
	var sb := _styles[i]
	if sb == null:
		return
	var h := _hover[i]
	var chosen := items[i].selected.is_valid() and bool(items[i].selected.call())
	var base_bg := _hot if chosen else _tile_bg
	var base_border := _accent if chosen else _line
	var lit := clampf(h + (0.35 if chosen else 0.0), 0.0, 1.0)
	sb.bg_color = base_bg.lerp(_hot, h)
	sb.border_color = base_border.lerp(_accent, h)
	sb.set_border_width_all(1 + int(round(h * 1.2)))
	sb.shadow_size = int(round(lit * 14.0))
	var g := _glow
	g.a = 0.55 * lit
	sb.shadow_color = g
	sb.shadow_offset = Vector2.ZERO
	if _values[i] != null:
		_values[i].add_theme_color_override("font_color", _accent.lerp(Color.WHITE, _pulse[i]))
	if _labels[i] != null:
		_labels[i].add_theme_color_override("font_color",
			LABEL if (chosen or h > 0.0) else LABEL.darkened(0.08))


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
	var half := (PANEL_METRES * maxf(0.001, _shown_e)) * 0.5 if _layer != null else PANEL_METRES * 0.5
	var u := (hit.x / half.x + 1.0) * 0.5
	var v := (1.0 - hit.y / half.y) * 0.5
	if u < 0.0 or u > 1.0 or v < 0.0 or v > 1.0:
		_hit_distance = 0.35
		return Vector2(-1, -1)
	return Vector2(u * float(VIEW_SIZE.x), v * float(VIEW_SIZE.y))


## For the headless shot tool only: force an open panel with one tile hovered, so the
## layout can be checked in a PNG without a headset.
func debug_force(shown: float, hovered: int) -> void:
	_shown = shown
	_shown_e = shown * shown * (3.0 - 2.0 * shown)
	_hovered = hovered
	if hovered >= 0 and hovered < _hover.size():
		_hover[hovered] = 1.0
	_refresh()
	_animate(0.0)
	for i in _tiles.size():
		_style_tile(i)
