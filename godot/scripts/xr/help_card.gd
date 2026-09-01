extends Node3D
class_name HelpCard

## First-launch controls card: a schematic of both controllers with what each button does,
## floating in front of you until you pull a trigger.
##
## Why a drawn schematic and not the runtime's controller render models: those arrive
## asynchronously, are absent in the desktop preview, and come pre-lit in a way that fights a
## black void. A flat diagram reads instantly at 1.3m and renders identically everywhere.
##
## Same display path as the wrist menu: an OpenXR quad composition layer when there is a
## session (composited at the panel's native resolution, so the text stays sharp whatever
## DETAIL does to the eye buffer), a plain unshaded quad on the desktop.

const PANEL_METRES := Vector2(1.15, 0.647)
const SHOW_DISTANCE := 1.35
const EYE_DROP := 0.06        # a touch below the eye line: reading down is more comfortable
const FADE_SPEED := 5.0

var _vp: SubViewport
var _card: Control
var _layer: OpenXRCompositionLayerQuad
var _quad: MeshInstance3D
var _head: Node3D
var _shown := 0.0
var _target := 0.0


func setup(head: Node3D) -> void:
	_head = head
	visible = false
	_build_viewport()
	_build_quad()


func is_open() -> bool:
	return _target > 0.0 or _shown > 0.01


## Place it in front of wherever you are actually looking, then fade in. World-locked once
## placed: a card welded to your head is the fastest way to make someone take a headset off.
func open() -> void:
	if _head != null:
		var head_t := _head.global_transform
		var fwd := -head_t.basis.z
		fwd.y = 0.0
		if fwd.length_squared() < 1e-6:
			fwd = Vector3.FORWARD
		fwd = fwd.normalized()
		var pos := head_t.origin + fwd * SHOW_DISTANCE + Vector3(0.0, -EYE_DROP, 0.0)
		# A QuadMesh and an OpenXR quad layer both face +Z, so -Z points away from the viewer.
		global_transform = Transform3D(Basis.looking_at(fwd, Vector3.UP), pos)
	_target = 1.0
	visible = true


func close() -> void:
	_target = 0.0


func update(delta: float) -> void:
	if is_equal_approx(_shown, _target):
		if _shown <= 0.001 and visible:
			visible = false
		return
	_shown = move_toward(_shown, _target, delta * FADE_SPEED)
	if _card != null:
		_card.modulate.a = _shown
	visible = _shown > 0.01
	if _layer != null:
		# A zero-size quad layer is invalid, so shrink it rather than let it reach zero.
		_layer.quad_size = PANEL_METRES * maxf(0.001, _shown)


func _build_viewport() -> void:
	_vp = SubViewport.new()
	_vp.size = Vector2i(ControlsCard.CARD)
	_vp.transparent_bg = true
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.disable_3d = true
	add_child(_vp)

	_card = ControlsCard.new()
	_card.size = Vector2(ControlsCard.CARD)
	_card.modulate.a = 0.0
	_vp.add_child(_card)


func _build_layer() -> bool:
	var xri := XRServer.find_interface("OpenXR")
	if xri == null or not xri.is_initialized():
		return false
	_layer = OpenXRCompositionLayerQuad.new()
	_layer.quad_size = PANEL_METRES
	_layer.layer_viewport = _vp
	_layer.alpha_blend = true
	_layer.sort_order = 2        # above the wrist menu, which sits at 1
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
	mat.render_priority = 96
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_quad = MeshInstance3D.new()
	_quad.mesh = mesh
	_quad.material_override = mat
	add_child(_quad)


## The card itself: one _draw, no layout containers. Everything is positioned against CARD,
## so moving a label is changing a number here and nothing else.
class ControlsCard extends Control:

	const CARD := Vector2(1600, 900)

	const BG := Color(0.055, 0.075, 0.115, 0.96)
	const BORDER := Color(0.30, 0.38, 0.50, 0.6)
	const SHELL := Color(0.105, 0.135, 0.195, 1.0)   # controller body
	const SHELL_EDGE := Color(0.34, 0.43, 0.58, 1.0)
	const PART := Color(0.16, 0.21, 0.31, 1.0)       # stick, buttons, trigger
	const LABEL := Color(0.90, 0.93, 0.98)
	const DIM := Color(0.62, 0.70, 0.80)
	const ACCENT := Color(0.98, 0.62, 0.80)
	const HAIR := Color(0.45, 0.55, 0.72, 0.8)       # callout lines

	const TITLE_SIZE := 62
	const SUB_SIZE := 32
	const LABEL_SIZE := 38
	const NOTE_SIZE := 32
	const BTN_SIZE := 26
	const LEFT_EDGE := 380.0     # right edge of the left-hand label column
	const RIGHT_EDGE := 1220.0   # left edge of the right-hand label column
	const COLUMN := 360.0

	func _draw() -> void:
		var font := ThemeDB.fallback_font
		_rounded(Rect2(Vector2.ZERO, CARD), 34, BG, BORDER, 3)

		draw_string(font, Vector2(0, 104), "FractalXR", HORIZONTAL_ALIGNMENT_CENTER,
			CARD.x, TITLE_SIZE, LABEL)
		draw_string(font, Vector2(0, 152), "grab it, pull it open, fly through it",
			HORIZONTAL_ALIGNMENT_CENTER, CARD.x, SUB_SIZE, DIM)

		var left := _controller(Vector2(520, 470), -1.0, "X", "Y", "Left")
		var right := _controller(Vector2(1080, 470), 1.0, "A", "B", "Right")

		_callout(left["trigger"], 320.0, true, ["Previous flame"])
		_callout(left["stick"], 470.0, true, ["Grow and shrink"])
		_callout(left["grip"], 650.0, true, ["Hold to grab", "and move it"])
		_callout(right["trigger"], 320.0, false, ["Next flame"])
		_callout(right["stick"], 470.0, false, ["Spin it,", "push it away"])
		_callout(right["grip"], 650.0, false, ["Both grips: scale", "and fly through"])

		# The one thing nobody discovers on their own.
		draw_string(font, Vector2(0, CARD.y - 112),
			"Turn your left wrist toward your face for the menu",
			HORIZONTAL_ALIGNMENT_CENTER, CARD.x, NOTE_SIZE, DIM)
		draw_string(font, Vector2(0, CARD.y - 52), "Pull either trigger to begin",
			HORIZONTAL_ALIGNMENT_CENTER, CARD.x, LABEL_SIZE, ACCENT)

	## One controller schematic. `dir` is +1 for the right hand, -1 mirrors it. Returns the
	## anchor point of each feature so the callout lines attach to the art, not to guesses.
	func _controller(o: Vector2, dir: float, btn_a: String, btn_b: String, caption: String) -> Dictionary:
		var font := ThemeDB.fallback_font

		# Handle first, so the face plate overlaps its top.
		_rounded(Rect2(o + Vector2(-52, 30), Vector2(104, 210)), 52, SHELL, SHELL_EDGE, 3)

		# Trigger: the index-finger side, drawn above the plate.
		var trig := Rect2(o + Vector2(-34, -168), Vector2(68, 52))
		_rounded(trig, 20, PART, SHELL_EDGE, 3)

		# Grip: the inside face of the handle, where your middle finger wraps around.
		var gx := -70.0 if dir > 0.0 else 36.0
		var grip := Rect2(o + Vector2(gx, 96), Vector2(34, 92))
		_rounded(grip, 14, PART, SHELL_EDGE, 3)

		var plate := _ellipse(o, 128, 108)
		draw_colored_polygon(plate, SHELL)
		draw_polyline(plate, SHELL_EDGE, 3.0, true)

		var stick := o + Vector2(-40 * dir, -26)
		draw_circle(stick, 42, PART)
		draw_arc(stick, 42, 0, TAU, 40, SHELL_EDGE, 3.0, true)
		draw_circle(stick, 27, Color(SHELL_EDGE, 0.45))

		_button(o + Vector2(52 * dir, 12), btn_a)
		_button(o + Vector2(14 * dir, 66), btn_b)

		draw_string(font, Vector2(o.x - 150, 258), caption, HORIZONTAL_ALIGNMENT_CENTER,
			300, NOTE_SIZE, DIM)

		return {
			"trigger": trig.get_center() + Vector2(0, -8),
			"grip": grip.get_center(),
			"stick": stick,
		}

	func _button(c: Vector2, text: String) -> void:
		var font := ThemeDB.fallback_font
		draw_circle(c, 25, PART)
		draw_arc(c, 25, 0, TAU, 28, SHELL_EDGE, 3.0, true)
		var sz := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, BTN_SIZE)
		draw_string(font, c + Vector2(-sz.x * 0.5, sz.y * 0.32), text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, BTN_SIZE, DIM)

	## A hairline from a feature out to a block of text, so nothing is ambiguous about which
	## button a label belongs to.
	func _callout(from: Vector2, y: float, left_side: bool, lines: PackedStringArray) -> void:
		var font := ThemeDB.fallback_font
		var edge := LEFT_EDGE if left_side else RIGHT_EDGE
		var stub := edge + (20.0 if left_side else -20.0)
		draw_line(from, Vector2(stub, y), HAIR, 2.0, true)
		draw_circle(from, 6, ACCENT)
		var ty := y - (lines.size() - 1) * 0.5 * (LABEL_SIZE + 8) + LABEL_SIZE * 0.35
		for line in lines:
			var x := edge - COLUMN if left_side else edge
			var align := HORIZONTAL_ALIGNMENT_RIGHT if left_side else HORIZONTAL_ALIGNMENT_LEFT
			draw_string(font, Vector2(x, ty), line, align, COLUMN, LABEL_SIZE, LABEL)
			ty += LABEL_SIZE + 8

	func _rounded(r: Rect2, radius: int, bg: Color, edge: Color, width: int) -> void:
		var b := StyleBoxFlat.new()
		b.bg_color = bg
		b.border_color = edge
		b.set_border_width_all(width)
		b.set_corner_radius_all(radius)
		draw_style_box(b, r)

	func _ellipse(c: Vector2, rx: float, ry: float, steps := 48) -> PackedVector2Array:
		var pts := PackedVector2Array()
		for i in steps + 1:
			var a := TAU * float(i) / float(steps)
			pts.append(c + Vector2(cos(a) * rx, sin(a) * ry))
		return pts
