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
var _mode := "flame"


func setup(head: Node3D) -> void:
	_head = head
	visible = false
	_build_viewport()
	_build_quad()


## The physical buttons stay put, but their meaning changes by mode. Keeping this card
## in step with the active mode avoids a perfectly accurate flame diagram becoming a
## misleading tree or ground tutorial.
func set_mode(mode: String) -> void:
	_mode = mode
	if _card != null:
		(_card as ControlsCard).set_mode(mode)


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
	# The card is one static _draw; only its alpha animates. Render every frame while
	# it fades, one last frame at the final alpha, and not at all in between. A
	# SubViewport keeps rendering behind a hidden parent otherwise, closed or not.
	if _vp != null:
		_vp.render_target_update_mode = (SubViewport.UPDATE_ONCE if is_equal_approx(_shown, _target)
			else SubViewport.UPDATE_ALWAYS)
	if _layer != null:
		# A zero-size quad layer is invalid, so shrink it rather than let it reach zero.
		_layer.quad_size = PANEL_METRES * maxf(0.001, _shown)


func _build_viewport() -> void:
	_vp = SubViewport.new()
	_vp.size = Vector2i(ControlsCard.CARD)
	_vp.transparent_bg = true
	_vp.render_target_update_mode = SubViewport.UPDATE_ONCE   # closed: draw the blank once, then sleep
	_vp.disable_3d = true
	add_child(_vp)

	_card = ControlsCard.new()
	(_card as ControlsCard).set_mode(_mode)
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

	# Same ink as the wrist menu, so the two surfaces read as one instrument rather than
	# two apps. WristMenu owns the values; they are named here, not re-invented.
	const BG := Color(0.063, 0.082, 0.122, 0.96)     # WristMenu.PANEL_INK, opened up
	const BORDER := Color(0.224, 0.267, 0.353, 0.6)  # WristMenu._line
	const SHELL := Color(0.106, 0.137, 0.188, 1.0)   # controller body, WristMenu.TILE_INK
	const SHELL_EDGE := Color(0.34, 0.43, 0.58, 1.0)
	const PART := Color(0.16, 0.21, 0.31, 1.0)       # stick, buttons, trigger
	const LABEL := Color("#EDF1F8")                  # WristMenu.LABEL
	const DIM := Color("#B8C3D4")                    # WristMenu.VALUE_INK
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
	var _mode := "flame"
	## Strings that ran past the space they were drawn in. draw_string clips silently, so
	## a line that is one word too long simply loses its tail and the PNG still saves.
	## card_shot.gd reads this after the draw and fails on anything in it.
	var overflow: PackedStringArray = PackedStringArray()

	func set_mode(mode: String) -> void:
		_mode = mode
		queue_redraw()

	## Space Grotesk, the wrist menu's face, so the card is not a different application
	## drawn in the system font. Falls back to the system face if the asset is missing.
	static func _face() -> Font:
		return WristMenu._font(500)

	func _draw() -> void:
		var font := _face()
		overflow.clear()
		_rounded(Rect2(Vector2.ZERO, CARD), 34, BG, BORDER, 3)

		draw_string(font, Vector2(0, 104), "FractalXR", HORIZONTAL_ALIGNMENT_CENTER,
			CARD.x, TITLE_SIZE, LABEL)
		var subtitle := "grab it, pull it open, fly through it"
		if _mode == "tree":
			subtitle = "point at the floor and grow a living forest"
		elif _mode == "ground":
			subtitle = "walk a Mandelbrot landscape in your room"
		elif _mode == "bulb":
			subtitle = "a solid you can pick up and turn over"
		elif _mode == "ifs":
			subtitle = "a mirrored frame sculpture on the table in front of you"
		draw_string(font, Vector2(0, 152), subtitle,
			HORIZONTAL_ALIGNMENT_CENTER, CARD.x, SUB_SIZE, DIM)

		var left := _controller(Vector2(520, 470), -1.0, "X", "Y", "Left")
		var right := _controller(Vector2(1080, 470), 1.0, "A", "B", "Right")

		# Every string below is written against the handler that actually runs. The
		# triggers branch in main.gd `_process`; the grips are read by WorldGrab in every
		# mode but Ground, where they drag the field instead.
		var left_trigger := PackedStringArray(["Previous flame"])
		var left_stick := PackedStringArray(["Grow and shrink"])
		var right_trigger := PackedStringArray(["Next flame"])
		var right_stick := PackedStringArray(["Spin it,", "push it away"])
		var left_grip := PackedStringArray(["Hold to grab", "and move it"])
		var right_grip := PackedStringArray(["Both grips: scale", "and fly through"])
		# A and B are previous and next in every mode. Only the noun changes.
		var face := PackedStringArray(["A · B: previous,", "next flame"])
		var mode_note := "Left wrist up for the menu:  FLAME · BULB · GROUND · TREE · IFS"
		if _mode == "tree":
			left_trigger = PackedStringArray(["Regrow", "every tree"])
			right_trigger = PackedStringArray(["Plant a tree", "at the point"])
			face = PackedStringArray(["A · B: previous,", "next species"])
			right_stick = PackedStringArray(["Turn the grove"])
			# The grips move the whole grove, hero and planted alike: they are one cloud.
			left_grip = PackedStringArray(["Hold to grab", "the whole grove"])
			right_grip = PackedStringArray(["Both grips:", "scale the grove"])
			mode_note = "The first tree is yours to grab. The floor grows the rest; CLEAR removes them."
		elif _mode == "ground":
			left_trigger = PackedStringArray(["Glide to", "the point"])
			right_trigger = PackedStringArray(["Glide to", "the point"])
			left_stick = PackedStringArray(["Walk", "the ground"])
			right_stick = PackedStringArray(["Turn + zoom", "the ground"])
			face = PackedStringArray(["A · B: previous,", "next terrain style"])
			# Ground has no object to hold. The grips drag and scale the field under you.
			left_grip = PackedStringArray(["Hold to drag", "the ground"])
			right_grip = PackedStringArray(["Both grips:", "zoom the ground"])
			mode_note = "PASSTHRU shows your room; INSIDE opens the filled set to it"
		elif _mode == "bulb":
			left_trigger = PackedStringArray(["Previous bulb"])
			right_trigger = PackedStringArray(["Next bulb"])
			face = PackedStringArray(["A · B: previous,", "next bulb"])
			mode_note = "It arrives hand-sized. Both grips make it a room; SURFACE changes how it is drawn."
		elif _mode == "ifs":
			# Written against what IFS-3 wires up. Either trigger picks a handle, and only
			# while EDIT has the guides showing, so the card says both things.
			left_trigger = PackedStringArray(["Hold on a handle", "to sculpt"])
			right_trigger = PackedStringArray(["Hold on a handle", "to sculpt"])
			left_stick = PackedStringArray(["Grow and shrink"])
			right_stick = PackedStringArray(["Turn it,", "push it away"])
			face = PackedStringArray(["A · B: less,", "more detail"])
			left_grip = PackedStringArray(["Hold to move", "the sculpture"])
			right_grip = PackedStringArray(["Both grips:", "scale it"])
			mode_note = "EDIT shows the mirrors and depth handles; UNDO takes back the last edit"
		_callout(left["trigger"], 310.0, true, left_trigger)
		_callout(left["stick"], 450.0, true, left_stick)
		_callout(left["grip"], 660.0, true, left_grip)
		_callout(right["trigger"], 310.0, false, right_trigger)
		_callout(right["stick"], 442.0, false, right_stick)
		_callout(right["face"], 566.0, false, face)
		_callout(right["grip"], 690.0, false, right_grip)

		# The two things nobody discovers on their own, in the order they need them:
		# how to leave this card, then where the rest of the app is hiding.
		draw_string(font, Vector2(0, CARD.y - 108), "Pull either trigger to begin",
			HORIZONTAL_ALIGNMENT_CENTER, CARD.x, LABEL_SIZE, ACCENT)
		_fits(font, mode_note, NOTE_SIZE, CARD.x - 80.0)
		draw_string(font, Vector2(0, CARD.y - 52), mode_note,
			HORIZONTAL_ALIGNMENT_CENTER, CARD.x, NOTE_SIZE, DIM)

	## One controller schematic. `dir` is +1 for the right hand, -1 mirrors it. Returns the
	## anchor point of each feature so the callout lines attach to the art, not to guesses.
	func _controller(o: Vector2, dir: float, btn_a: String, btn_b: String, caption: String) -> Dictionary:
		var font := _face()

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
			"face": o + Vector2(33 * dir, 39),   # between A and B
		}

	func _button(c: Vector2, text: String) -> void:
		var font := _face()
		draw_circle(c, 25, PART)
		draw_arc(c, 25, 0, TAU, 28, SHELL_EDGE, 3.0, true)
		var sz := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, BTN_SIZE)
		draw_string(font, c + Vector2(-sz.x * 0.5, sz.y * 0.32), text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, BTN_SIZE, DIM)

	## A hairline from a feature out to a block of text, so nothing is ambiguous about which
	## button a label belongs to.
	func _callout(from: Vector2, y: float, left_side: bool, lines: PackedStringArray) -> void:
		var font := _face()
		var edge := LEFT_EDGE if left_side else RIGHT_EDGE
		var stub := edge + (20.0 if left_side else -20.0)
		draw_line(from, Vector2(stub, y), HAIR, 2.0, true)
		draw_circle(from, 6, ACCENT)
		var ty := y - (lines.size() - 1) * 0.5 * (LABEL_SIZE + 8) + LABEL_SIZE * 0.35
		for line in lines:
			var x := edge - COLUMN if left_side else edge
			var align := HORIZONTAL_ALIGNMENT_RIGHT if left_side else HORIZONTAL_ALIGNMENT_LEFT
			_fits(font, line, LABEL_SIZE, COLUMN)
			draw_string(font, Vector2(x, ty), line, align, COLUMN, LABEL_SIZE, LABEL)
			ty += LABEL_SIZE + 8

	## Measure before drawing. Everything on this card is positioned by hand against CARD,
	## so the only thing standing between a copy edit and a truncated instruction is this.
	func _fits(font: Font, text: String, size: int, width: float) -> void:
		if font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x > width:
			overflow.append("%s (%dpx > %d)" % [text,
				int(font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x), int(width)])

	## For card_shot.gd's negative control: prove _fits can actually report something.
	func _fits_probe() -> bool:
		var before := overflow.size()
		_fits(_face(), "a string far too long to fit in forty pixels of column", LABEL_SIZE, 40.0)
		var fired := overflow.size() > before
		overflow.clear()
		return fired

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
