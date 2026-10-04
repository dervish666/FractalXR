extends Node3D
class_name WristMenu

## Wrist menu: a real Godot UI rendered to a SubViewport and shown on the left forearm.
##
## The panel is a strand pulled out of the fractal and laid along your arm, not an admin
## slate. A luminous spine runs down its left edge carrying the live palette; sections
## hang off the spine as nodes; tiles are petals (two corners soft, two sharp) that unfold
## out of the spine when the wrist turns up, in a wave that runs top-left to bottom-right.
## The silhouette is a facet, not a rounded rectangle: two corners are cut. Behind the
## title a small chaos-game flame, rendered once at build time, shows through the glass.
##
## Colour has two owners. The PALETTE (set_palette, fed by the same cross-fade that
## recolours the cloud) drives the spine, the accent and the hover. The MODE (set_mode)
## drives the frame: the top edge, the spine halo, the section nodes and the lit segment
## of the mode strip take a signature hue per mode, so GROUND reads teal and FLAME reads
## ember before a single word is read. A mode change sweeps the new hue in over ~0.4 s.
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
##
## Budget. One composition layer (or one quad on the desktop), one SubViewport that only
## renders while the panel is up, ~60 canvas items, no per-frame allocations: every
## animated property is a float or a Color and every string is formatted at REFRESH_S.

# Shaped for a forearm: narrow and long, rather than a square slab sitting across it.
# Pixels per metre are fixed at the original 760px / 0.185m, so a taller viewport is a
# taller panel and nothing else about the menu moves.
const VIEW_SIZE := Vector2i(760, 1072)
const PX_PER_M := 760.0 / 0.185
const PANEL_METRES := Vector2(VIEW_SIZE.x / PX_PER_M, VIEW_SIZE.y / PX_PER_M)
## Tiles per row. Sections wrap instead of squeezing, so a section with six settings
## does not shrink every tile in it past the point of being readable or hittable.
const COLUMNS := 4
const MODE_SECTION := "mode"
const REVEAL_DOT := 0.55
const REVEAL_SPEED := 4.2      # ~240ms to open, so the unfold wave is seen, not implied
const HIDE_SPEED := 7.0
const HOVER_IN := 14.0
const HOVER_OUT := 6.0
const PULSE_DECAY := 7.0
const RIPPLE_S := 0.38
const MODE_SWEEP_S := 0.4
## Stick scrubbing: first step on the flick, then repeat while held.
const STICK_DEAD := 0.6
const STEP_FIRST_S := 0.42
const STEP_REPEAT_S := 0.24

const FONT_PATH := "res://fonts/SpaceGrotesk-VF.ttf"
const WGHT_TAG := 0x77676874   # 'wght' as an OpenType axis tag

## Geometry of the frame. The spine is the vertical bar at the left edge; CUT is the
## chamfer on the two cut corners; the content margin clears the spine.
const SPINE_X0 := 13.0
const SPINE_X1 := 20.0
const CUT := 46.0
const MARGIN_L := 34
const MARGIN_R := 18
const MARGIN_T := 16
const MARGIN_B := 12
## The flame behind the title: a chaos game rendered once into an alpha mask.
const FIELD_SIZE := Vector2i(360, 92)
const FIELD_POINTS := 26000
const FIELD_RECT := Rect2(Vector2(70, 0), Vector2(680, 150))

## Text sizes, chosen for a 0.185 m panel read at forearm length in a headset: the
## previous 18/19 px faces came out at roughly fifteen display pixels of x-height.
const TITLE_PX := 36
const SIDE_PX := 18
const HEAD_PX := 14
const LABEL_PX := 21
const VALUE_PX := 19
const SEGMENT_PX := 19
const FOOT_PX := 15

const LABEL := Color("#EDF1F8")
const DIM := Color(0.62, 0.68, 0.78, 0.8)
## Values at rest. Every value used to be drawn in the palette accent, which meant a
## flame menu showed twenty-odd bright orange strings shouting at the same volume and
## none of them told you where you were. Accent now belongs to the selected mode and to
## whatever the ray is on; everything else reads in neutral ink.
const VALUE_INK := Color("#C3CDDC")
## The panel and tile grounds before the palette gets a say. Near-neutral on purpose:
## a 45% tint of the palette's second stop made the whole panel a slab of saturated
## colour that the fractal behind it then had to compete with.
const PANEL_INK := Color("#10151F")
const TILE_INK := Color("#1B2330")
## How much palette is allowed into those grounds. Enough to tell two themes apart,
## not enough to become the subject.
const PANEL_TINT := 0.08
const TILE_TINT := 0.10

## One signature hue per mode. Ember, violet, teal, leaf, ice: far enough apart that the
## frame alone says which world you are in, and all of them sit next to any palette the
## library ships because they are only ever used at low area (edges, dots, one segment).
const MODE_TINT := {
	"flame": Color("#FF8A3D"),
	"bulb": Color("#B48CFF"),
	"ground": Color("#3DD9C4"),
	"tree": Color("#8BE05C"),
	"ifs": Color("#6FB8FF"),
}

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


## The frame: facet silhouette, hairline edge, mode-tinted top edge, and the spine with
## its halo. One canvas item, redrawn only when a colour or the spine length changes.
class Backdrop extends Control:
	var ink := Color.BLACK
	var line := Color.WHITE
	var tint := Color.WHITE
	var stops := PackedColorArray()
	var spine_t := 1.0
	func _draw() -> void:
		var s := size
		var c := WristMenu.CUT
		var outline := PackedVector2Array([Vector2(0, 0), Vector2(s.x - c, 0), Vector2(s.x, c),
			Vector2(s.x, s.y), Vector2(c, s.y), Vector2(0, s.y - c)])
		draw_colored_polygon(outline, ink)
		var ring := outline.duplicate()
		ring.append(outline[0])
		draw_polyline(ring, line, 1.5, true)
		# The top edge carries the mode: bright at the spine, gone by the cut corner.
		var t0 := tint
		t0.a = 0.95
		var t1 := tint
		t1.a = 0.0
		draw_polyline_colors(PackedVector2Array([Vector2(1, 1.5), Vector2(s.x - c, 1.5)]),
			PackedColorArray([t0, t1]), 3.0, true)
		draw_polyline_colors(PackedVector2Array([Vector2(s.x - c, 1.5), Vector2(s.x - 1.5, c)]),
			PackedColorArray([t1, t0 * Color(1, 1, 1, 0.5)]), 3.0, true)
		# The spine, grown from the top by spine_t. Light at the top, dark at the bottom,
		# so it reads as the palette ribbon stood on end.
		if stops.size() < 2 or spine_t <= 0.0:
			return
		# The spine stops short of the bottom cut, or its foot would stand outside the facet.
		var y0 := 18.0
		var y1 := y0 + (s.y - c - 24.0) * clampf(spine_t, 0.0, 1.0)
		var halo := tint
		halo.a = 0.16
		var halo_out := tint
		halo_out.a = 0.0
		var hx0 := WristMenu.SPINE_X0 - 7.0
		var hx1 := WristMenu.SPINE_X1 + 7.0
		draw_polygon(PackedVector2Array([Vector2(hx0, y0), Vector2(hx1, y0), Vector2(hx1, y1), Vector2(hx0, y1)]),
			PackedColorArray([halo_out, halo_out, halo_out, halo_out]))
		var mid := (WristMenu.SPINE_X0 + WristMenu.SPINE_X1) * 0.5
		draw_polygon(PackedVector2Array([Vector2(hx0, y0), Vector2(mid, y0), Vector2(mid, y1), Vector2(hx0, y1)]),
			PackedColorArray([halo_out, halo, halo, halo_out]))
		draw_polygon(PackedVector2Array([Vector2(mid, y0), Vector2(hx1, y0), Vector2(hx1, y1), Vector2(mid, y1)]),
			PackedColorArray([halo, halo_out, halo_out, halo]))
		var n := stops.size() - 1
		for k in n:
			var ya := y0 + (y1 - y0) * float(k) / float(n)
			var yb := y0 + (y1 - y0) * float(k + 1) / float(n)
			var ca := stops[n - k]
			var cb := stops[n - k - 1]
			draw_polygon(PackedVector2Array([Vector2(WristMenu.SPINE_X0, ya), Vector2(WristMenu.SPINE_X1, ya),
				Vector2(WristMenu.SPINE_X1, yb), Vector2(WristMenu.SPINE_X0, yb)]),
				PackedColorArray([ca, ca, cb, cb]))
		# A bright cap where the spine starts, in the mode hue.
		draw_circle(Vector2(mid, y0), 5.0, tint)


## A section's node on the spine: a dot drawn outside its own rect, over the spine.
class SpineDot extends Control:
	var col := Color.WHITE
	func _draw() -> void:
		var cx := (WristMenu.SPINE_X0 + WristMenu.SPINE_X1) * 0.5 - float(WristMenu.MARGIN_L)
		var p := Vector2(cx, size.y * 0.5)
		var halo := col
		halo.a = 0.25
		draw_circle(p, 9.0, halo)
		draw_circle(p, 5.0, col)


## Press feedback: a ring that leaves the pressed tile and fades as it grows.
class Ripple extends Control:
	var at := Vector2.ZERO
	var t := 0.0          # 1 at the press, 0 when done
	var col := Color.WHITE
	func _draw() -> void:
		if t <= 0.0:
			return
		var k := 1.0 - t
		var c := col
		c.a = t * t
		draw_arc(at, 22.0 + 150.0 * k, 0.0, TAU, 56, c, 3.0 - 2.0 * k, true)
		c.a = t * 0.5
		draw_arc(at, 12.0 + 70.0 * k, 0.0, TAU, 40, c, 1.5, true)


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
var _stops := PackedColorArray()
# --- mode-derived theme ------------------------------------------------------
var _mode := "flame"
var _mode_col: Color = MODE_TINT["flame"]
var _mode_from: Color = MODE_TINT["flame"]
var _mode_to: Color = MODE_TINT["flame"]
var _mode_t := 1.0
var _mode_fill: Color  # the lit segment's ground
var _mode_edge: Color  # the lit segment's border

var _vp: SubViewport
var _theme_dirty := false
var _root: Control
var _backdrop: Backdrop
var _field: TextureRect
var _ripple: Ripple
var _head_row: Control
var _tiles: Array[PanelContainer] = []
var _styles: Array[StyleBoxFlat] = []
var _values: Array[Label] = []
var _labels: Array[Label] = []
var _hover: Array[float] = []
var _pulse: Array[float] = []
var _segment: Array[bool] = []
var _title_label: Label
var _side_label: Label
var _foot_label: Label
var _heads: Array[Label] = []
var _rules: Array[ColorRect] = []
var _dots: Array[SpineDot] = []
var _quad: MeshInstance3D          # desktop preview fallback
var _layer: OpenXRCompositionLayerQuad
var _hovered := -1
var _hit_distance := 0.35
var _shown := 0.0
var _shown_e := 0.0
var _shown_drawn := -1.0
var _pinned := false
var _sections: Dictionary = {}   # section name -> [header Control, GridContainer]
var _head: Node3D
var _pointer: Node3D
var _step_dir := 0
var _step_timer := 0.0
## Values are read from Callables and formatted into Labels; doing that every frame
## was ~150 Callable calls and 50 String allocations per frame with the menu up.
const REFRESH_S := 0.12
var _refresh_accum := REFRESH_S
var _chosen_last: Array[bool] = []
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
static var _field_tex: ImageTexture


func setup(head: Node3D, pointer: Node3D) -> void:
	_head = head
	_pointer = pointer
	_derive_theme()
	_derive_mode()
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
	# Restyling is ~50 tiles of theme overrides, and a morph calls this every frame. A
	# folded panel keeps the palette and restyles once when it next goes live.
	if _vp != null:
		if visible:
			_apply_theme()
		else:
			_theme_dirty = true


## Which world the panel belongs to. The frame takes the mode's hue; if the panel is up
## the new hue sweeps in rather than snapping.
func set_mode(mode: String) -> void:
	if not MODE_TINT.has(mode) or mode == _mode:
		return
	_mode = mode
	_mode_from = _mode_col
	_mode_to = MODE_TINT[mode]
	if _vp != null and visible:
		_mode_t = 0.0
	else:
		_mode_t = 1.0
		_mode_col = _mode_to
		_derive_mode()
		_theme_dirty = true


## The menu button holds the panel open without the wrist held up. Press again to let go.
func toggle_pin() -> void:
	_pinned = not _pinned
	_haptic(0.35, 0.02)


func is_pinned() -> bool:
	return _pinned


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
	_ink = _sink(PANEL_INK.lerp(c1, PANEL_TINT), 0.075)
	_ink.a = 0.97
	_tile_bg = _sink(TILE_INK.lerp(c2, TILE_TINT), 0.11)
	_tile_bg.a = 0.97
	# Resting borders are structure, not decoration: neutral, and only just there.
	_line = Color("#39445A")
	_line.a = 0.55
	_mute = Color("#8C97A8")
	_mute.a = 0.95
	_accent = _lift(c3, 0.66)
	# The hover fill. Tinted enough to read as "this one", dark enough that the label
	# on top of it keeps its contrast.
	_hot = _sink(_tile_bg.lerp(c2, 0.34), 0.20)
	_hot.a = 0.98
	# The spine: the palette stood on end, with its dark end lifted so it never reads
	# as a gap in the bar.
	_stops.resize(5)
	for k in 5:
		_stops[k] = _lift(_c(_pal[k]), 0.10 + 0.08 * k)


func _derive_mode() -> void:
	_mode_fill = _sink(TILE_INK.lerp(_mode_col, 0.42), 0.19)
	_mode_fill.a = 0.98
	_mode_edge = _lift(_mode_col, 0.6)


static func _font(weight: int, tracking := 0) -> Font:
	var key := weight * 100 + tracking
	if _fonts.has(key):
		return _fonts[key]
	if _base_font == null:
		_base_font = load(FONT_PATH)
	var f: Font
	if _base_font == null:
		f = ThemeDB.fallback_font
	else:
		var fv := FontVariation.new()
		fv.base_font = _base_font
		fv.variation_opentype = {WGHT_TAG: weight}
		fv.spacing_glyph = tracking
		# Chevrons and the odd symbol come from the system font, not a tofu box.
		fv.fallbacks = [ThemeDB.fallback_font]
		f = fv
	_fonts[key] = f
	return f


## The flame behind the title. A three-map chaos game (a contracting spiral, a spherical
## fold and a swirl) rendered log-density into an alpha mask, masked so it fades out
## toward the right edge and the mode strip. Built once per process; the texture is
## tinted by modulate, so a theme change costs one Color.
static func _make_field() -> ImageTexture:
	if _field_tex != null:
		return _field_tex
	var w := FIELD_SIZE.x
	var h := FIELD_SIZE.y
	var dens := PackedFloat32Array()
	dens.resize(w * h)
	var rng := RandomNumberGenerator.new()
	rng.seed = 1301
	var x := 0.1
	var y := 0.1
	var ca := cos(0.47)
	var sa := sin(0.47)
	var peak := 0.0
	for i in FIELD_POINTS:
		var r := rng.randf()
		var nx: float
		var ny: float
		if r < 0.44:
			nx = 0.84 * (x * ca - y * sa) + 0.22
			ny = 0.84 * (x * sa + y * ca) - 0.04
		elif r < 0.76:
			var ax := 0.55 * x + 0.48
			var ay := 0.55 * y - 0.22
			var r2 := maxf(1e-3, ax * ax + ay * ay)
			nx = ax / r2 * 0.3
			ny = ay / r2 * 0.3
		else:
			var ax := 0.62 * x - 0.36
			var ay := 0.62 * y + 0.28
			var r2 := ax * ax + ay * ay
			nx = ax * sin(r2) - ay * cos(r2)
			ny = ax * cos(r2) + ay * sin(r2)
		x = clampf(nx, -4.0, 4.0)
		y = clampf(ny, -4.0, 4.0)
		if i < 24:
			continue
		var px := int((x + 1.9) / 3.8 * float(w))
		var py := int((y + 0.95) / 1.9 * float(h))
		if px < 0 or py < 0 or px >= w or py >= h:
			continue
		var idx := py * w + px
		dens[idx] += 1.0
		peak = maxf(peak, dens[idx])
	var img := Image.create(w, h, false, Image.FORMAT_LA8)
	var norm := 1.0 / log(1.0 + maxf(1.0, peak))
	for py in h:
		var fy := float(py) / float(h)
		var my := 1.0 - smoothstep(0.62, 1.0, fy)
		for px in w:
			var fx := float(px) / float(w)
			var mx := 1.0 - smoothstep(0.55, 1.0, fx)
			var a := log(1.0 + dens[py * w + px]) * norm
			img.set_pixel(px, py, Color(1, 1, 1, clampf(a * mx * my, 0.0, 1.0)))
	_field_tex = ImageTexture.create_from_image(img)
	return _field_tex


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
		_pinned = false
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

	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_vp.add_child(_root)

	_backdrop = Backdrop.new()
	_backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	_backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_backdrop)

	_field = TextureRect.new()
	_field.texture = _make_field()
	_field.position = FIELD_RECT.position
	_field.size = FIELD_RECT.size
	_field.stretch_mode = TextureRect.STRETCH_SCALE
	_field.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_field.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_field)

	var pad := MarginContainer.new()
	pad.set_anchors_preset(Control.PRESET_FULL_RECT)
	pad.add_theme_constant_override("margin_left", MARGIN_L)
	pad.add_theme_constant_override("margin_right", MARGIN_R)
	pad.add_theme_constant_override("margin_top", MARGIN_T)
	pad.add_theme_constant_override("margin_bottom", MARGIN_B)
	_root.add_child(pad)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	pad.add_child(col)

	# Header: the flame's name, light and large; the live status on the right.
	_head_row = HBoxContainer.new()
	_head_row.add_theme_constant_override("separation", 12)
	col.add_child(_head_row)
	_title_label = _label("", TITLE_PX, LABEL, 600)
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_head_row.add_child(_title_label)
	_side_label = _label("", SIDE_PX, _accent, 500)
	_side_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_side_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_side_label.size_flags_vertical = Control.SIZE_FILL
	_head_row.add_child(_side_label)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 2)
	col.add_child(gap)

	# Sections, in the order they first appear in the item list. The mode section is a
	# segmented strip: no header, one pill per segment.
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
		grid.add_theme_constant_override("h_separation", 6 if sec == MODE_SECTION else 8)
		grid.add_theme_constant_override("v_separation", 7)
		col.add_child(grid)
		_sections[sec] = [head, grid]
		for i in items.size():
			if items[i].section == sec:
				grid.add_child(_tile(i, sec == MODE_SECTION))

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(spacer)
	_foot_label = _label("", FOOT_PX, DIM, 400)
	_foot_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	col.add_child(_foot_label)

	_ripple = Ripple.new()
	_ripple.set_anchors_preset(Control.PRESET_FULL_RECT)
	_ripple.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_ripple)


## A node on the spine, small caps beside it, a hairline running out to the right edge.
func _section_head(sec: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var dot := SpineDot.new()
	dot.custom_minimum_size = Vector2(2, 14)
	dot.size_flags_vertical = Control.SIZE_FILL
	dot.col = _mode_col
	row.add_child(dot)
	_dots.append(dot)
	var l := _label(sec.to_upper(), HEAD_PX, _mute, 700)
	l.add_theme_font_override("font", _font(700, 2))
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
	var sb := _box(_tile_bg, _line, 1)
	if segment:
		sb.set_corner_radius_all(24)
	else:
		# A petal: soft on one diagonal, sharp on the other.
		sb.corner_radius_top_left = 18
		sb.corner_radius_bottom_right = 18
		sb.corner_radius_top_right = 5
		sb.corner_radius_bottom_left = 5
	p.add_theme_stylebox_override("panel", sb)
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var m := MarginContainer.new()
	for side in ["left", "right"]:
		m.add_theme_constant_override("margin_" + side, 6)
	var vpad := 10 if segment else 7
	for side in ["top", "bottom"]:
		m.add_theme_constant_override("margin_" + side, vpad)
	p.add_child(m)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)
	m.add_child(v)
	var l := _label(it.label, SEGMENT_PX if segment else LABEL_PX, LABEL, 600)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(l)
	var val := _label("", VALUE_PX, VALUE_INK, 450)
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
		_segment.append(false)
	_tiles[i] = p
	_styles[i] = sb
	_values[i] = val
	_labels[i] = l
	_segment[i] = segment
	return p


func _label(text: String, size: int, colour: Color, weight: int) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", _font(weight))
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", colour)
	return l


func _box(bg: Color, border: Color, width: int) -> StyleBoxFlat:
	var b := StyleBoxFlat.new()
	b.bg_color = bg
	b.border_color = border
	b.set_border_width_all(width)
	b.anti_aliasing = true
	return b


## Push the derived palette and mode hue into everything that holds a colour. Called on
## every palette change, which during a theme cross-fade is every frame; all of it is
## property sets plus one backdrop redraw.
func _apply_theme() -> void:
	_backdrop.ink = _ink
	_backdrop.line = _line
	_backdrop.tint = _mode_col
	_backdrop.stops = _stops
	_backdrop.queue_redraw()
	var fc := _accent.lerp(_mode_col, 0.35)
	fc.a = 0.55
	_field.modulate = fc
	_side_label.add_theme_color_override("font_color", _accent)
	for h in _heads:
		h.add_theme_color_override("font_color", _mute)
	for r in _rules:
		r.color = _line
	for d in _dots:
		d.col = _mode_col
		d.queue_redraw()
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


## Returns true while the pointer is on the panel, so the caller hands the trigger over.
func update(delta: float) -> bool:
	_wants_stick = false
	if not _focused:
		visible = false
		_set_live(false)
		_hovered = -1
		_show_pointer(false, 0.0, 0.0)
		return false
	var open := _pinned or _wrist_facing()
	_shown = clampf(_shown + (REVEAL_SPEED * delta if open else -HIDE_SPEED * delta), 0.0, 1.0)
	_shown_e = _shown * _shown * (3.0 - 2.0 * _shown)
	visible = _shown > 0.01
	_set_live(visible)
	# The panel is drawn full size and unfolds inside its own frame; a composition layer
	# of zero size is invalid, so a folded panel keeps a sliver.
	if _layer != null:
		_layer.quad_size = PANEL_METRES if visible else Vector2(0.001, 0.001)
	if not visible:
		_hovered = -1
		_show_pointer(false, 0.0, 0.0)
		if _shown > 0.0:   # still folding away; once settled there is nothing to animate
			_animate(delta)
		return false

	_sweep_mode(delta)
	var hit := _pointer_pixel()
	var was := _hovered
	_hovered = -1
	# The ray on the panel owns the trigger even between tiles: a pull that misses a
	# tile by a few pixels must not fall through and step the gallery behind the panel.
	var on_panel := hit.x >= 0.0
	if on_panel:
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
	_refresh_accum += delta
	if _refresh_accum >= REFRESH_S or was != _hovered:
		_refresh_accum = 0.0
		_refresh()
	return _hovered >= 0 or on_panel


## A mode change recolours the frame over MODE_SWEEP_S rather than in one frame.
func _sweep_mode(delta: float) -> void:
	if _mode_t >= 1.0:
		return
	_mode_t = minf(1.0, _mode_t + delta / MODE_SWEEP_S)
	var k := _mode_t * _mode_t * (3.0 - 2.0 * _mode_t)
	_mode_col = _mode_from.lerp(_mode_to, k)
	_derive_mode()
	_apply_theme()


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
	if on and _theme_dirty:
		_theme_dirty = false
		_apply_theme()
	var want := SubViewport.UPDATE_ALWAYS if on else SubViewport.UPDATE_DISABLED
	if _vp != null and _vp.render_target_update_mode != want:
		_vp.render_target_update_mode = want


func activate() -> void:
	if _hovered >= 0 and _hovered < items.size():
		items[_hovered].advance.call()
		_pulse[_hovered] = 1.0
		var r := _tiles[_hovered].get_global_rect()
		_ripple.at = r.get_center()
		_ripple.col = _mode_col if _segment[_hovered] else _accent
		_ripple.t = 1.0
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
		var foot := str(status_main.call())
		_foot_label.text = ("pinned  ·  " + foot) if _pinned else foot


## Per-frame motion: hover bloom in and out, press pulse and ripple, the spine growing,
## and the unfold wave when the panel opens. Only tiles whose state is moving get restyled.
func _animate(delta: float) -> void:
	if _shown_e != _shown_drawn:
		_shown_drawn = _shown_e
		_backdrop.spine_t = minf(1.0, _shown_e * 1.5)
		_backdrop.modulate.a = minf(1.0, _shown_e * 2.5)
		_backdrop.queue_redraw()
		var ha := clampf((_shown_e - 0.05) / 0.35, 0.0, 1.0)
		_head_row.modulate.a = ha
		_field.modulate.a = 0.55 * ha
		_foot_label.modulate.a = clampf((_shown_e - 0.6) / 0.4, 0.0, 1.0)
		for h in _heads:
			h.modulate.a = ha
		for d in _dots:
			d.modulate.a = ha
		for r in _rules:
			r.modulate.a = ha
	if _ripple.t > 0.0:
		_ripple.t = maxf(0.0, _ripple.t - delta / RIPPLE_S)
		_ripple.queue_redraw()
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
		# Unfold: a wave from the top-left. Tiles lower down and further from the spine
		# arrive later, and each one grows out of its left edge toward the right.
		var r := p.get_global_rect()
		var row_t := clampf(r.position.y / float(VIEW_SIZE.y), 0.0, 1.0)
		var col_t := clampf(r.position.x / float(VIEW_SIZE.x), 0.0, 1.0)
		var start := 0.06 + row_t * 0.46 + col_t * 0.12
		var pour := clampf((_shown_e - start) / 0.36, 0.0, 1.0)
		pour = pour * pour * (3.0 - 2.0 * pour)
		if absf(p.modulate.a - pour) > 0.002:
			p.modulate.a = pour
			moving = true
		# A mode tile restyles when its chosen state flips, not every frame.
		var chosen := items[i].selected.is_valid() and bool(items[i].selected.call())
		if _chosen_last.size() <= i:
			_chosen_last.resize(_tiles.size())
		if chosen != _chosen_last[i]:
			_chosen_last[i] = chosen
			moving = true
		if moving:
			p.pivot_offset = Vector2(0.0, p.size.y * 0.5)
			var press := 1.0 + 0.02 * h - 0.05 * _pulse[i]
			p.scale = Vector2(0.72 + 0.28 * pour, 0.9 + 0.1 * pour) * press
			_style_tile(i)


func _style_tile(i: int) -> void:
	var sb := _styles[i]
	if sb == null:
		return
	var h := _hover[i]
	var chosen := items[i].selected.is_valid() and bool(items[i].selected.call())
	if _segment[i]:
		# The mode strip. The lit segment wears the mode's own hue as a FILL; the rest are
		# glass. Hover is an outline, so pointing at GROUND from FLAME never looks like
		# being in GROUND.
		var rest := _tile_bg
		rest.a = 0.55
		sb.bg_color = (_mode_fill if chosen else rest).lerp(_hot, h * 0.25)
		sb.border_color = (_mode_edge if chosen else _line).lerp(_accent, h)
		sb.set_border_width_all(2 if chosen else 1 + int(round(h)))
		if _labels[i] != null:
			_labels[i].add_theme_color_override("font_color",
				Color.WHITE if chosen else LABEL.darkened(0.12 - 0.12 * h))
		return
	# Selection and hover live on different channels. Selection is a FILL, hover is an
	# OUTLINE. They used to be the same picture (accent border over a lifted fill), so
	# pointing at any tile made it look like the mode you were in, and the mode you were
	# actually in disappeared. Now the current mode stays filled whatever the ray is on.
	var base_bg := _hot if chosen else _tile_bg
	sb.bg_color = base_bg.lerp(_hot, h * 0.22)
	sb.border_color = (_accent if chosen else _line).lerp(_accent, h)
	var w := 3 if chosen else 1 + int(round(h))
	sb.border_width_top = w
	sb.border_width_right = w
	sb.border_width_bottom = w
	# The hovered tile grows a thicker left edge: it points back at the spine it came from.
	sb.border_width_left = w + int(round(3.0 * h))
	# No halo. A 14 px glow behind every hover, and behind the selected mode as well,
	# put a soft bloom across the panel that read as the whole thing lighting up rather
	# than one control being pointed at.
	sb.shadow_size = 0
	sb.shadow_offset = Vector2.ZERO
	if _values[i] != null:
		var ink := _accent if chosen else VALUE_INK.lerp(_accent, h)
		_values[i].add_theme_color_override("font_color", ink.lerp(Color.WHITE, _pulse[i]))
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
	var half := PANEL_METRES * 0.5
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
	_shown_drawn = -1.0
	_hovered = hovered
	if hovered >= 0 and hovered < _hover.size():
		_hover[hovered] = 1.0
	_mode_t = 1.0
	_mode_col = _mode_to
	_derive_mode()
	_refresh()
	_apply_theme()
	_animate(0.0)
	for i in _tiles.size():
		_style_tile(i)
