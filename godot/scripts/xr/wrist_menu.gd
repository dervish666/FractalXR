extends Node3D
class_name WristMenu

## Wrist menu: a zoomable panel of real controls, worn on the left forearm or floated in
## front of you.
##
## FORM. Two OpenXR quad composition layers 12 mm apart. The BACK plane carries the facet
## silhouette, the palette spine, the title, the breadcrumb, the footer and a soft shadow
## under every control. The FRONT plane carries everything you can point at: the mode
## rail, the cards, the widgets, the back button. Because the compositor projects each
## plane per eye, the controls sit proud of the glass with real parallax and cast real
## shadows on it; a painted bevel would go flat in stereo, two planes do not. One extra
## SubViewport that renders only when something on it changes.
##
## DEPTH. The top level is a handful of big cards, one per section, each showing its live
## state (values, or the palette as a bar). Press a card and the level zooms INTO it: the
## cards scale up around the pressed one and fade, the front plane comes 6 mm toward you,
## and the card's own controls unfold where it was, the way a fractal reveals detail
## where you look closer. Back is the reverse: the edge button, or the OTHER hand's
## trigger while the ray is on the panel.
##
## CONTROLS. Each item declares its kind and the menu draws the matching widget: a switch
## that flips, a slider you drag with the trigger held (the right stick as fine adjust),
## a carousel with chevrons and the actual palettes as swatches, a button with a press,
## a hold-to-confirm ring. The fractal updates live under a drag because every step runs
## the item's own closure the moment it happens.
##
## WEAR OR PIN. The menu button flies the panel off the forearm to a lazy-follow float
## 0.5 m out and a little below the eye line. It stays put while you look around and
## eases back in front of you over half a second once your heading drifts past 38
## degrees. Grip on it to move it; that becomes the new resting spot. Press again and
## it flies home to the arm. Pinned, either hand's ray drives it.
##
## Hit testing does NOT synthesise mouse events. The controller ray is intersected with
## the front plane, converted to viewport pixels, and tested against each control's
## rect. Fewer moving parts than faking input, and it cannot get out of step with
## Godot's focus handling.
##
## ADDING A SETTING is one entry in the spec passed to build(): a section, a label, a
## closure that reads the current value, a closure that advances it, then chains for the
## kind: .toggle(is_on), .slider(index, count), .gallery(index, count, swatch_of),
## .hold(), .minor() (behind MORE), .as_card(companion_section) (its own top card).
## An item with .stepping() and no kind is a carousel; one with neither is a button.
##
## Budget: two layers, ~45 canvas items, a redraw only on the widget whose state moved,
## and no per-frame allocations (strings at REFRESH_S, everything else floats).

const VIEW_SIZE := Vector2i(760, 1072)
const PX_PER_M := 760.0 / 0.185
const PANEL_METRES := Vector2(VIEW_SIZE.x / PX_PER_M, VIEW_SIZE.y / PX_PER_M)
## How far the control plane floats in front of the glass, and how much further it comes
## during a zoom.
const TILE_Z := 0.012
const ZOOM_Z := 0.006
const MODE_SECTION := "mode"
const REVEAL_DOT := 0.55
const REVEAL_SPEED := 4.2
const HIDE_SPEED := 7.0
const HOVER_IN := 14.0
const HOVER_OUT := 6.0
const PULSE_DECAY := 7.0
const RIPPLE_S := 0.38
const MODE_SWEEP_S := 0.4
const ZOOM_S := 0.34
const HOLD_S := 1.1
const STICK_DEAD := 0.6
const STEP_FIRST_S := 0.42
const STEP_REPEAT_S := 0.24
## The float: where it rests, when it gives chase, how long the chase and the flights take.
const FLOAT_OUT := 0.52
const FLOAT_DROP := 0.10
const FOLLOW_DEG := 38.0
const FOLLOW_DIST := 0.45
const FOLLOW_S := 0.5
const FLY_S := 0.4

const FONT_PATH := "res://fonts/SpaceGrotesk-VF.ttf"
const WGHT_TAG := 0x77676874

const SPINE_X0 := 13.0
const SPINE_X1 := 20.0
const CUT := 46.0
const MARGIN_L := 34
const MARGIN_R := 18
const MARGIN_T := 16
const MARGIN_B := 12
const FIELD_SIZE := Vector2i(360, 92)
const FIELD_POINTS := 26000
const FIELD_RECT := Rect2(Vector2(70, 0), Vector2(680, 150))
const HEADER_H := 74.0

const LABEL := Color("#EDF1F8")
const DIM := Color(0.62, 0.68, 0.78, 0.8)
const VALUE_INK := Color("#C3CDDC")
const PANEL_INK := Color("#10151F")
const TILE_INK := Color("#1B2330")
const PANEL_TINT := 0.08
const TILE_TINT := 0.10

const MODE_TINT := {
	"flame": Color("#FF8A3D"),
	"bulb": Color("#B48CFF"),
	"ground": Color("#3DD9C4"),
	"tree": Color("#8BE05C"),
	"ifs": Color("#6FB8FF"),
}

enum Kind { ACTION, TOGGLE, SLIDER, CAROUSEL, HOLD, CARD, STATION, BACK, MORE }

signal pin_changed(pinned: bool)


class Item:
	var section: String
	var label: String
	var read: Callable
	var advance: Callable
	var wide := false
	var visible_when: Callable
	var step: Callable
	var selected: Callable
	var kind := -1
	var is_on: Callable
	var index: Callable
	var count_n := 0
	var count_fn: Callable
	var swatch: Callable
	var primary := true
	var card_of := ""      # non-empty: this item is its own top card, with that section inside
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
	## A switch. is_on() tells the widget which way it sits; advance() still flips it.
	func toggle(on: Callable) -> Item:
		kind = Kind.TOGGLE
		is_on = on
		return self
	## A slider over count detents. index() is the current detent; dragging calls step()
	## until the index under the ray is reached, so the host's own closure applies it.
	func slider(idx: Callable, count: int) -> Item:
		kind = Kind.SLIDER
		index = idx
		count_n = count
		return self
	## A carousel with swatches: swatch_of(i) returns five colours as Vector3 for entry i.
	func gallery(idx: Callable, count: Callable, swatch_of: Callable) -> Item:
		kind = Kind.CAROUSEL
		index = idx
		count_fn = count
		swatch = swatch_of
		return self
	func hold() -> Item:
		kind = Kind.HOLD
		return self
	func minor() -> Item:
		primary = false
		return self
	func as_card(companion := "") -> Item:
		card_of = companion if companion != "" else label.to_lower()
		return self


## One control. Draws itself from a handful of floats and strings the menu keeps fresh.
class Widget extends Control:
	var kind := Kind.ACTION
	var label := ""
	var value := ""
	var sub := ""
	var lines: PackedStringArray = PackedStringArray()
	var hue := Color.WHITE
	var accent := Color.WHITE
	var line := Color.WHITE
	var ink := Color.BLACK
	var hot := Color.BLACK
	var hover := 0.0
	var pulse := 0.0
	var on_t := 0.0
	var fill_t := 0.0
	var hold_t := 0.0
	var ticks := 0
	var chosen := false
	var big := false
	var swatches: Array = []     # Array[PackedColorArray]
	var swatch_cur := -1
	var _sb := StyleBoxFlat.new()
	static var _f600: Font
	static var _f500: Font
	static var _f700: Font

	func _init() -> void:
		_sb.anti_aliasing = true
		if _f600 == null:
			_f600 = WristMenu._font(600)
			_f500 = WristMenu._font(500)
			_f700 = WristMenu._font(700, 2)

	## The slider's track, in local pixels. The drag maps the ray onto this.
	func track() -> Rect2:
		return Rect2(Vector2(20.0, size.y - 30.0), Vector2(size.x - 40.0, 10.0))

	func _body(radius_soft: int, radius_sharp: int) -> void:
		_sb.corner_radius_top_left = radius_soft
		_sb.corner_radius_bottom_right = radius_soft
		_sb.corner_radius_top_right = radius_sharp
		_sb.corner_radius_bottom_left = radius_sharp
		var h := hover
		_sb.bg_color = ink.lerp(hot, h * 0.3 + (0.5 if chosen else 0.0))
		_sb.border_color = line.lerp(accent, h)
		var w := 1 + int(round(h))
		_sb.border_width_top = w
		_sb.border_width_right = w
		_sb.border_width_bottom = w
		_sb.border_width_left = w + int(round(3.0 * h))
		draw_style_box(_sb, Rect2(Vector2.ZERO, size))
		# The mode's hue along the top edge, brighter the closer the ray is.
		var t := hue
		t.a = 0.55 + 0.45 * h
		draw_line(Vector2(radius_soft, 1.0), Vector2(size.x - radius_sharp, 1.0), t, 2.0, true)

	func _draw() -> void:
		match kind:
			Kind.STATION:
				_draw_station()
			Kind.CARD:
				_draw_card()
			Kind.TOGGLE:
				_draw_toggle()
			Kind.SLIDER:
				_draw_slider()
			Kind.CAROUSEL:
				_draw_carousel()
			Kind.HOLD:
				_draw_hold()
			Kind.BACK:
				_draw_back()
			Kind.MORE:
				_draw_more()
			_:
				_draw_action()

	func _draw_station() -> void:
		# A rail runs through every station; the chosen one is where the marker sits.
		var y := size.y - 14.0
		var rail := line
		rail.a = 0.9
		draw_line(Vector2(0, y), Vector2(size.x, y), rail, 2.0, true)
		var cx := size.x * 0.5
		var h := hover
		if chosen:
			var glow := hue
			glow.a = 0.28
			draw_circle(Vector2(cx, y), 13.0, glow)
			draw_circle(Vector2(cx, y), 6.0, hue)
			draw_string(_f600, Vector2(0, size.y - 32.0), label, HORIZONTAL_ALIGNMENT_CENTER,
				size.x, 21, Color.WHITE)
			var u := hue
			u.a = 0.9
			draw_line(Vector2(cx - 26.0, size.y - 25.0), Vector2(cx + 26.0, size.y - 25.0), u, 2.0, true)
		else:
			draw_circle(Vector2(cx, y), 4.0 + 2.0 * h, line.lerp(accent, h))
			draw_string(_f500, Vector2(0, size.y - 32.0), label, HORIZONTAL_ALIGNMENT_CENTER,
				size.x, 17, DIM.lerp(LABEL, h))

	func _draw_card() -> void:
		_body(22, 6)
		var pad := 20.0
		draw_string(_f600, Vector2(pad, 40.0), label, HORIZONTAL_ALIGNMENT_LEFT, size.x - 2 * pad,
			27, LABEL)
		var y := 70.0
		for l in lines:
			draw_string(_f500, Vector2(pad, y), l, HORIZONTAL_ALIGNMENT_LEFT, size.x - 2 * pad - 30.0,
				17, VALUE_INK)
			y += 23.0
		if swatch_cur >= 0 and swatch_cur < swatches.size():
			_bar(Rect2(Vector2(pad, size.y - 24.0), Vector2(size.x - 2 * pad - 36.0, 10.0)),
				swatches[swatch_cur], 1.0)
		# The way in: a chevron in the mode's hue, in the corner the zoom grows from.
		var c := hue
		c.a = 0.6 + 0.4 * hover
		var cx := size.x - 26.0
		var cy := size.y - 24.0
		draw_polyline(PackedVector2Array([Vector2(cx - 6, cy - 9), Vector2(cx + 3, cy), Vector2(cx - 6, cy + 9)]),
			c, 3.0, true)

	func _draw_action() -> void:
		_body(18, 5)
		var fs := 26 if big else 21
		var cy := size.y * 0.5
		if sub == "":
			draw_string(_f600, Vector2(0, cy + fs * 0.36), label, HORIZONTAL_ALIGNMENT_CENTER, size.x, fs,
				LABEL.lerp(Color.WHITE, pulse))
		else:
			draw_string(_f600, Vector2(0, cy - 4.0), label, HORIZONTAL_ALIGNMENT_CENTER, size.x, fs, LABEL)
			draw_string(_f500, Vector2(0, cy + 20.0), sub, HORIZONTAL_ALIGNMENT_CENTER, size.x, 17,
				VALUE_INK.lerp(Color.WHITE, pulse))

	func _draw_toggle() -> void:
		_body(18, 5)
		var pad := 18.0
		var cy := size.y * 0.5
		if sub == "":
			draw_string(_f600, Vector2(pad, cy + 8.0), label, HORIZONTAL_ALIGNMENT_LEFT, size.x - 110.0, 21, LABEL)
		else:
			draw_string(_f600, Vector2(pad, cy - 2.0), label, HORIZONTAL_ALIGNMENT_LEFT, size.x - 110.0, 21, LABEL)
			draw_string(_f500, Vector2(pad, cy + 20.0), sub, HORIZONTAL_ALIGNMENT_LEFT, size.x - 110.0, 16, VALUE_INK)
		# The switch. Track takes the hue as it comes on; the knob slides and brightens.
		var tw := 66.0
		var th := 32.0
		var tx := size.x - pad - tw
		var ty := cy - th * 0.5
		var off_c := TILE_INK.lerp(line, 0.6)
		var on_c := hue
		_sb_rect(Rect2(Vector2(tx, ty), Vector2(tw, th)), off_c.lerp(on_c, on_t), 16)
		var kx := tx + 16.0 + (tw - 32.0) * on_t
		draw_circle(Vector2(kx, cy), 12.0 + 1.5 * hover, Color(0.55, 0.6, 0.7).lerp(Color.WHITE, on_t))
		if on_t > 0.5:
			var g := hue
			g.a = (on_t - 0.5) * 0.5
			draw_circle(Vector2(kx, cy), 18.0, g)

	func _draw_slider() -> void:
		_body(18, 5)
		var pad := 18.0
		draw_string(_f600, Vector2(pad, 32.0), label, HORIZONTAL_ALIGNMENT_LEFT, size.x * 0.55, 21, LABEL)
		draw_string(_f500, Vector2(size.x * 0.45, 32.0), value, HORIZONTAL_ALIGNMENT_RIGHT, size.x * 0.55 - pad,
			21, accent.lerp(Color.WHITE, pulse))
		var tr := track()
		var cy := tr.position.y + tr.size.y * 0.5
		_sb_rect(tr, TILE_INK.lerp(line, 0.5), 5)
		var fw := tr.size.x * fill_t
		if fw > 2.0:
			_sb_rect(Rect2(tr.position, Vector2(fw, tr.size.y)), accent, 5)
		# Detents: one tick per step, so the ray has something to land on.
		if ticks > 1 and ticks <= 24:
			var tc := line
			tc.a = 0.9
			for k in ticks:
				var x := tr.position.x + tr.size.x * float(k) / float(ticks - 1)
				draw_line(Vector2(x, cy + 10.0), Vector2(x, cy + 15.0), tc, 1.5, true)
		var kx := tr.position.x + fw
		draw_circle(Vector2(kx, cy), 12.0 + 3.0 * hover, Color.WHITE.lerp(accent, 0.2))
		var g := accent
		g.a = 0.25 + 0.3 * hover
		draw_circle(Vector2(kx, cy), 18.0 + 4.0 * hover, g)

	func _draw_carousel() -> void:
		_body(18, 5)
		var pad := 18.0
		var has_sw := not swatches.is_empty()
		draw_string(_f700, Vector2(pad, 28.0), label, HORIZONTAL_ALIGNMENT_LEFT, size.x - 2 * pad, 14, DIM)
		var fs := 26 if big else 22
		var vy := (size.y * 0.5 - 2.0 if big else 58.0) if has_sw else size.y * 0.5 + 10.0
		draw_string(_f600, Vector2(44.0, vy), value, HORIZONTAL_ALIGNMENT_CENTER, size.x - 88.0, fs,
			LABEL.lerp(Color.WHITE, pulse))
		# Chevrons, each a hit zone: left third steps back, the rest steps on.
		var cc := DIM.lerp(accent, hover)
		var cy := vy - fs * 0.36
		draw_polyline(PackedVector2Array([Vector2(28, cy - 9), Vector2(19, cy), Vector2(28, cy + 9)]), cc, 3.0, true)
		draw_polyline(PackedVector2Array([Vector2(size.x - 28, cy - 9), Vector2(size.x - 19, cy),
			Vector2(size.x - 28, cy + 9)]), cc, 3.0, true)
		if not has_sw:
			return
		# The swatch strip: neighbours either side of the current, which stands taller.
		var n := swatches.size()
		var slot := (size.x - 2 * pad - 4 * 6.0) / 5.0
		var by := size.y - 26.0
		for k in 5:
			var i := swatch_cur - 2 + k
			if i < 0 or i >= n:
				continue
			var x := pad + k * (slot + 6.0)
			var cur := k == 2
			var r := Rect2(Vector2(x, by - (5.0 if cur else 0.0)), Vector2(slot, 19.0 if cur else 14.0))
			_bar(r, swatches[i], 1.0 if cur else 0.55)
			if cur:
				var e := hue
				e.a = 0.9
				draw_rect(r.grow(2.0), e, false, 2.0, true)

	func _draw_hold() -> void:
		_body(18, 5)
		var pad := 18.0
		var cy := size.y * 0.5
		draw_string(_f600, Vector2(pad, cy - 2.0), label, HORIZONTAL_ALIGNMENT_LEFT, size.x - 90.0, 21, LABEL)
		draw_string(_f500, Vector2(pad, cy + 20.0), sub, HORIZONTAL_ALIGNMENT_LEFT, size.x - 90.0, 16, VALUE_INK)
		var c := Vector2(size.x - pad - 24.0, cy)
		var ring := line
		ring.a = 0.9
		draw_arc(c, 20.0, 0.0, TAU, 40, ring, 3.0, true)
		if hold_t > 0.0:
			draw_arc(c, 20.0, -PI * 0.5, -PI * 0.5 + TAU * hold_t, 40, hue, 5.0, true)
		var dot := hue
		dot.a = 0.5 + 0.5 * hover
		draw_circle(c, 5.0 + 3.0 * hold_t, dot)

	func _draw_back() -> void:
		_body(16, 16)
		var cy := size.y * 0.5
		var c := hue.lerp(Color.WHITE, hover)
		draw_polyline(PackedVector2Array([Vector2(26, cy - 8), Vector2(18, cy), Vector2(26, cy + 8)]), c, 3.0, true)
		draw_string(_f600, Vector2(36.0, cy + 6.0), label, HORIZONTAL_ALIGNMENT_LEFT, size.x - 40.0, 17, c)

	func _draw_more() -> void:
		var cy := size.y * 0.5
		var c := DIM.lerp(LABEL, hover)
		draw_string(_f700, Vector2(0, cy + 5.0), label, HORIZONTAL_ALIGNMENT_CENTER, size.x, 14, c)
		var l := line
		l.a = 0.8
		var tw := _f700.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
		draw_line(Vector2(0, cy), Vector2(size.x * 0.5 - tw * 0.5 - 16.0, cy), l, 1.0, true)
		draw_line(Vector2(size.x * 0.5 + tw * 0.5 + 16.0, cy), Vector2(size.x, cy), l, 1.0, true)

	func _sb_rect(r: Rect2, c: Color, radius: int) -> void:
		_sb.bg_color = c
		_sb.set_border_width_all(0)
		_sb.set_corner_radius_all(radius)
		draw_style_box(_sb, r)

	## Five stops as a bar, dark to light, left to right.
	func _bar(r: Rect2, cols: PackedColorArray, alpha: float) -> void:
		var n := cols.size()
		if n < 2:
			return
		var seg := r.size.x / float(n - 1)
		for k in n - 1:
			var a := cols[k]
			var b := cols[k + 1]
			a.a = alpha
			b.a = alpha
			var x0 := r.position.x + seg * k
			draw_polygon(PackedVector2Array([Vector2(x0, r.position.y), Vector2(x0 + seg, r.position.y),
				Vector2(x0 + seg, r.end.y), Vector2(x0, r.end.y)]), PackedColorArray([a, b, b, a]))


## The glass: facet silhouette, hairline edge, mode-tinted top edge, the spine and its
## halo. One canvas item on the back plane, redrawn only when a colour or length changes.
class Backdrop extends Control:
	var ink := Color.BLACK
	var line := Color.WHITE
	var tint := Color.WHITE
	var stops := PackedColorArray()
	var spine_t := 1.0
	var nodes := PackedFloat32Array()
	func _draw() -> void:
		var s := size
		var c := WristMenu.CUT
		var outline := PackedVector2Array([Vector2(0, 0), Vector2(s.x - c, 0), Vector2(s.x, c),
			Vector2(s.x, s.y), Vector2(c, s.y), Vector2(0, s.y - c)])
		draw_colored_polygon(outline, ink)
		var ring := outline.duplicate()
		ring.append(outline[0])
		draw_polyline(ring, line, 1.5, true)
		var t0 := tint
		t0.a = 0.95
		var t1 := tint
		t1.a = 0.0
		draw_polyline_colors(PackedVector2Array([Vector2(1, 1.5), Vector2(s.x - c, 1.5)]),
			PackedColorArray([t0, t1]), 3.0, true)
		draw_polyline_colors(PackedVector2Array([Vector2(s.x - c, 1.5), Vector2(s.x - 1.5, c)]),
			PackedColorArray([t1, t0 * Color(1, 1, 1, 0.5)]), 3.0, true)
		if stops.size() < 2 or spine_t <= 0.0:
			return
		var y0 := 18.0
		var y1 := y0 + (s.y - c - 24.0) * clampf(spine_t, 0.0, 1.0)
		var halo := tint
		halo.a = 0.16
		var halo_out := tint
		halo_out.a = 0.0
		var hx0 := WristMenu.SPINE_X0 - 7.0
		var hx1 := WristMenu.SPINE_X1 + 7.0
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
		draw_circle(Vector2(mid, y0), 5.0, tint)
		# A node on the spine for every row of controls on the plane in front.
		for ny in nodes:
			if ny > y1:
				continue
			var g := tint
			g.a = 0.25
			draw_circle(Vector2(mid, ny), 9.0, g)
			draw_circle(Vector2(mid, ny), 4.5, tint)


## Shadows the front plane casts on the glass: one soft rounded rect under each control,
## offset down and right, which is where a light above the eyes would put it.
class Shadows extends Control:
	var rects: Array[Rect2] = []
	var _sb := StyleBoxFlat.new()
	func _init() -> void:
		_sb.bg_color = Color(0, 0, 0, 0)
		_sb.shadow_color = Color(0, 0, 0, 0.55)
		_sb.shadow_size = 16
		_sb.shadow_offset = Vector2(4, 7)
		_sb.set_corner_radius_all(16)
	func _draw() -> void:
		for r in rects:
			draw_style_box(_sb, r)


## Press feedback: a ring that leaves the pressed control and fades as it grows.
class Ripple extends Control:
	var at := Vector2.ZERO
	var t := 0.0
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

# --- theme -------------------------------------------------------------------
var _pal: Array = [Vector3(0, 0, 0), Vector3(0.25, 0, 0.3), Vector3(0.9, 0.2, 0.4),
	Vector3(1, 0.6, 0.1), Vector3(1, 0.95, 0.65)]
var _ink: Color
var _tile_bg: Color
var _line: Color
var _mute: Color
var _accent: Color
var _hot: Color
var _stops := PackedColorArray()
var _mode := "flame"
var _mode_col: Color = MODE_TINT["flame"]
var _mode_from: Color = MODE_TINT["flame"]
var _mode_to: Color = MODE_TINT["flame"]
var _mode_t := 1.0

# --- scene -------------------------------------------------------------------
var _vp: SubViewport           # front plane
var _bvp: SubViewport          # back plane
var _theme_dirty := false
var _root: Control
var _broot: Control
var _backdrop: Backdrop
var _shadows: Shadows
var _field: TextureRect
var _ripple: Ripple
var _title_label: Label
var _side_label: Label
var _foot_label: Label
var _crumb_label: Label
var _rail: HBoxContainer
var _stage: Control
var _top: GridContainer
var _sub: VBoxContainer
var _back_btn: Widget
var _boxes: Dictionary = {}    # level key -> {box, wide, grid_a, more, grid_b, section}
var _cards: Array[Widget] = []
var _card_keys: Array[String] = []
var _widgets: Array[Widget] = []   # one per item, index-aligned
var _tiles: Array[Control] = []    # the hit targets: every widget, card, station, button
var _tile_item: Array[int] = []    # item index for each tile, or -1
var _tile_kind: Array[int] = []
var _tile_key: Array[String] = []  # card level key for cards
var _hover: Array[float] = []
var _pulse: Array[float] = []
var _quad: MeshInstance3D
var _bquad: MeshInstance3D
var _layer: OpenXRCompositionLayerQuad
var _blayer: OpenXRCompositionLayerQuad
var _front: Node3D             # the front plane's parent, offset along +z

# --- state -------------------------------------------------------------------
var _hovered := -1
var _hit_distance := 0.35
var _shown := 0.0
var _shown_e := 0.0
var _shown_drawn := -1.0
var _level := ""               # "" = top
var _more := false
var _zoom_t := 1.0
# Must start false: at the top level a settled zoom with _zoom_in true reads as "fully
# zoomed into a card", which hides the cards, and _go_level("") early-outs on a settled
# top level so nothing ever corrects it. The shot tool masked this via debug_level("").
var _zoom_in := false
var _zoom_at := Vector2(VIEW_SIZE) * 0.5
var _drag := -1
var _hold_i := -1
var _hold_t := 0.0
var _hold_tick := 0
var _head: Node3D
var _right: XRController3D
var _left: XRController3D
var _origin: Node3D
var _ptr: XRController3D       # the hand whose ray drives the panel this frame
var _rays: Dictionary = {}     # controller -> [ray, dot]
var _ray_mat: StandardMaterial3D
var _dot_mat: StandardMaterial3D
var _step_dir := 0
var _step_timer := 0.0
const REFRESH_S := 0.12
var _refresh_accum := REFRESH_S
var _wants_stick := false
var _focused := true
var _back_dirty := true
var _back_until := 0           # process frame the back plane may stop rendering at
var _debug_hold := false

# --- wear or pin -------------------------------------------------------------
var _pinned := false
var _worn_local := Transform3D()
var _fly_t := 1.0
var _fly_from := Transform3D()
var _fly_home := false
var _float_local := Transform3D()
var _follow_t := 1.0
var _follow_from := Transform3D()
var _hold_hand: XRController3D
var _hold_off := Transform3D()

static var _base_font: Font
static var _fonts: Dictionary = {}
static var _field_tex: ImageTexture


func setup(head: Node3D, right: XRController3D, left: XRController3D = null,
		origin: Node3D = null) -> void:
	_head = head
	_right = right
	_left = left
	_origin = origin
	_ptr = right
	_worn_local = transform
	_float_local = Transform3D(Basis(Vector3.RIGHT, deg_to_rad(10.0)),
		Vector3(0.0, -FLOAT_DROP, -FLOAT_OUT))
	_derive_theme()
	_build_viewports()
	_build_quads()
	_build_pointer(_right)
	if _left != null:
		_build_pointer(_left)
	_apply_theme()
	var xri := XRServer.find_interface("OpenXR") as OpenXRInterface
	if xri != null:
		xri.session_visible.connect(func(): _set_focus(false))
		xri.session_focussed.connect(func(): _set_focus(true))
		xri.session_stopping.connect(func(): _set_focus(false))


func set_palette(pal: Array) -> void:
	if pal.size() < 5:
		return
	_pal = pal
	_derive_theme()
	if _vp != null:
		if visible:
			_apply_theme()
		else:
			_theme_dirty = true


## Which world the panel belongs to. If the panel is up the new hue sweeps in.
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
		_theme_dirty = true
	# A new world opens at its top level: the cards you had open belong to the old one.
	if _vp != null:
		_go_level("", Vector2(VIEW_SIZE) * 0.5, false)
		if OS.is_debug_build() and visible:
			_log_layers.call_deferred("mode")


## The menu button: fly off the arm to a float in front of you, or fly home.
func toggle_pin() -> void:
	set_pinned(not _pinned, false)


func set_pinned(on: bool, instant: bool) -> void:
	if on == _pinned or _origin == null or _left == null:
		return
	_pinned = on
	_haptic(0.35, 0.02)
	if on:
		var g := global_transform
		_reparent(_origin)
		global_transform = g
		_fly_from = g
		_fly_home = false
		_fly_t = 1.0 if instant else 0.0
		_follow_t = 1.0
		if instant:
			global_transform = _float_target()
	else:
		_hold_hand = null
		_fly_from = global_transform
		_fly_home = true
		_fly_t = 1.0 if instant else 0.0
		if instant:
			_land_home()
	pin_changed.emit(on)


func is_pinned() -> bool:
	return _pinned


## True while a grip is moving the floating panel, so the host leaves the cloud alone.
func is_holding() -> bool:
	return _hold_hand != null


func _reparent(to: Node) -> void:
	var p := get_parent()
	if p == to:
		return
	if p != null:
		p.remove_child(self)
	to.add_child(self)


func _land_home() -> void:
	_reparent(_left)
	transform = _worn_local


## Where the float rests: the stored offset hung off a yaw-only frame at the head, so it
## never tilts with a nod and is always a little below the eyes.
func _float_target() -> Transform3D:
	var h := _head.global_transform
	var fwd := -h.basis.z
	fwd.y = 0.0
	if fwd.length_squared() < 1e-6:
		fwd = Vector3.FORWARD
	var yaw := Basis.looking_at(fwd.normalized(), Vector3.UP)
	return Transform3D(yaw, h.origin) * _float_local


func _yaw_frame() -> Transform3D:
	var h := _head.global_transform
	var fwd := -h.basis.z
	fwd.y = 0.0
	if fwd.length_squared() < 1e-6:
		fwd = Vector3.FORWARD
	return Transform3D(Basis.looking_at(fwd.normalized(), Vector3.UP), h.origin)


## Flights, the lazy follow and the grip hold. Runs every frame while pinned or in flight.
func _tick_float(delta: float) -> void:
	if _fly_t < 1.0:
		_fly_t = minf(1.0, _fly_t + delta / FLY_S)
		var k := _fly_t * _fly_t * (3.0 - 2.0 * _fly_t)
		var to := (_left.global_transform * _worn_local) if _fly_home else _float_target()
		global_transform = _fly_from.interpolate_with(to, k)
		if _fly_t >= 1.0 and _fly_home:
			_land_home()
		return
	if not _pinned:
		return
	# A grip on the panel takes it along; letting go leaves it there and remembers.
	var held := _hold_hand
	if held != null and not (_tracked(held) and held.is_button_pressed("grip_click")):
		_float_local = _yaw_frame().affine_inverse() * global_transform
		_hold_hand = null
		held = null
	if held == null:
		for c in [_right, _left]:
			if c != null and _tracked(c) and c.is_button_pressed("grip_click") and _hits_panel(c):
				_hold_hand = c
				_hold_off = c.global_transform.affine_inverse() * global_transform
				_haptic_on(c, 0.3, 0.02)
				held = c
				break
	if held != null:
		global_transform = held.global_transform * _hold_off
		_follow_t = 1.0
		return
	# The chase: only once you have turned well away, and then in one smooth half second.
	var want := _float_target()
	if _follow_t >= 1.0:
		var h := _head.global_transform
		var to_panel := global_transform.origin - h.origin
		var fwd := -h.basis.z
		to_panel.y = 0.0
		fwd.y = 0.0
		var ang := 0.0
		if to_panel.length_squared() > 1e-6 and fwd.length_squared() > 1e-6:
			ang = rad_to_deg(to_panel.normalized().angle_to(fwd.normalized()))
		if ang > FOLLOW_DEG or global_transform.origin.distance_to(want.origin) > FOLLOW_DIST:
			_follow_t = 0.0
			_follow_from = global_transform
	if _follow_t < 1.0:
		_follow_t = minf(1.0, _follow_t + delta / FOLLOW_S)
		var k := _follow_t * _follow_t * (3.0 - 2.0 * _follow_t)
		global_transform = _follow_from.interpolate_with(want, k)


static func _lum(c: Color) -> float:
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b


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
	_tile_bg.a = 0.985
	_line = Color("#39445A")
	_line.a = 0.55
	_mute = Color("#8C97A8")
	_mute.a = 0.95
	_accent = _lift(c3, 0.66)
	_hot = _sink(_tile_bg.lerp(c2, 0.34), 0.20)
	_hot.a = 0.98
	_stops.resize(5)
	for k in 5:
		_stops[k] = _lift(_c(_pal[k]), 0.10 + 0.08 * k)


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
		fv.fallbacks = [ThemeDB.fallback_font]
		f = fv
	_fonts[key] = f
	return f


## The flame behind the title: a three-map chaos game rendered once into an alpha mask.
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


# --- pointer -----------------------------------------------------------------

func _build_pointer(c: XRController3D) -> void:
	if c == null:
		return
	var beam := CylinderMesh.new()
	beam.top_radius = 0.0012
	beam.bottom_radius = 0.0022
	beam.height = 1.0
	beam.radial_segments = 6
	beam.rings = 0
	if _ray_mat == null:
		_ray_mat = _emissive(Color(0.55, 0.8, 1.0, 0.45))
		_dot_mat = _emissive(Color(1.0, 0.72, 0.85, 0.95))
	var ray := MeshInstance3D.new()
	ray.mesh = beam
	ray.material_override = _ray_mat
	ray.rotation_degrees = Vector3(-90, 0, 0)
	ray.visible = false
	c.add_child(ray)
	var tip := SphereMesh.new()
	tip.radius = 0.005
	tip.height = 0.010
	tip.radial_segments = 10
	tip.rings = 6
	var dot := MeshInstance3D.new()
	dot.mesh = tip
	dot.material_override = _dot_mat
	dot.visible = false
	c.add_child(dot)
	_rays[c] = [ray, dot]


func _emissive(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = c
	m.no_depth_test = true
	m.render_priority = 95
	return m


func _show_pointer(c: XRController3D, on: bool, distance: float, hovering: float) -> void:
	if c == null or not _rays.has(c):
		return
	var pair: Array = _rays[c]
	var ray: MeshInstance3D = pair[0]
	var dot: MeshInstance3D = pair[1]
	ray.visible = on
	dot.visible = on
	if not on:
		return
	ray.scale = Vector3(1.0, distance, 1.0)
	ray.position = Vector3(0, 0, -distance * 0.5)
	dot.position = Vector3(0, 0, -distance)
	dot.scale = Vector3.ONE * (1.0 + 0.7 * hovering)


func _hide_pointers() -> void:
	for c in _rays:
		_show_pointer(c, false, 0.0, 0.0)


func _haptic(amplitude: float, seconds: float) -> void:
	_haptic_on(_ptr, amplitude, seconds)


func _haptic_on(c: XRController3D, amplitude: float, seconds: float) -> void:
	if c != null:
		c.trigger_haptic_pulse("haptic", 0.0, amplitude, seconds, 0.0)


func _tracked(c: XRController3D) -> bool:
	return c != null and c.is_inside_tree() and (XRServer.primary_interface == null or c.get_has_tracking_data())


func _set_focus(f: bool) -> void:
	_focused = f
	if not f:
		_shown = 0.0
		_shown_e = 0.0
		visible = false
		_hold_hand = null
		_drag = -1
		if _layer != null:
			_layer.quad_size = Vector2(0.001, 0.001)
			_blayer.quad_size = Vector2(0.001, 0.001)
		_hide_pointers()


# --- build -------------------------------------------------------------------

func _build_viewports() -> void:
	# Back plane: the glass.
	_bvp = SubViewport.new()
	_bvp.size = VIEW_SIZE
	_bvp.transparent_bg = true
	_bvp.render_target_update_mode = SubViewport.UPDATE_DISABLED   # _animate drives it
	_bvp.disable_3d = true
	add_child(_bvp)
	_broot = Control.new()
	_broot.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bvp.add_child(_broot)
	_backdrop = Backdrop.new()
	_backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	_broot.add_child(_backdrop)
	_field = TextureRect.new()
	_field.texture = _make_field()
	_field.position = FIELD_RECT.position
	_field.size = FIELD_RECT.size
	_field.stretch_mode = TextureRect.STRETCH_SCALE
	_field.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_broot.add_child(_field)
	_shadows = Shadows.new()
	_shadows.set_anchors_preset(Control.PRESET_FULL_RECT)
	_broot.add_child(_shadows)
	_title_label = _label("", 36, LABEL, 600)
	_title_label.position = Vector2(MARGIN_L, MARGIN_T - 2)
	_title_label.size = Vector2(VIEW_SIZE.x - MARGIN_L - MARGIN_R - 170, 46)
	_title_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_broot.add_child(_title_label)
	_side_label = _label("", 18, _accent, 500)
	_side_label.position = Vector2(VIEW_SIZE.x - MARGIN_R - 260, MARGIN_T + 20)
	_side_label.size = Vector2(260, 26)
	_side_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_broot.add_child(_side_label)
	_crumb_label = _label("", 14, _mute, 700)
	_crumb_label.add_theme_font_override("font", _font(700, 2))
	_crumb_label.position = Vector2(MARGIN_L + 150, MARGIN_T + HEADER_H + 56)
	_crumb_label.size = Vector2(VIEW_SIZE.x - MARGIN_L - MARGIN_R - 150, 22)
	_crumb_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_broot.add_child(_crumb_label)
	_foot_label = _label("", 15, DIM, 400)
	_foot_label.position = Vector2(MARGIN_L, VIEW_SIZE.y - MARGIN_B - 22)
	_foot_label.size = Vector2(VIEW_SIZE.x - MARGIN_L - MARGIN_R, 22)
	_foot_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_broot.add_child(_foot_label)

	# Front plane: everything with a hit rect.
	_vp = SubViewport.new()
	_vp.size = VIEW_SIZE
	_vp.transparent_bg = true
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.disable_3d = true
	add_child(_vp)
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_vp.add_child(_root)
	var pad := MarginContainer.new()
	pad.set_anchors_preset(Control.PRESET_FULL_RECT)
	pad.add_theme_constant_override("margin_left", MARGIN_L)
	pad.add_theme_constant_override("margin_right", MARGIN_R)
	pad.add_theme_constant_override("margin_top", MARGIN_T + int(HEADER_H))
	pad.add_theme_constant_override("margin_bottom", MARGIN_B + 26)
	_root.add_child(pad)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 14)
	pad.add_child(col)

	# The rail: one station per mode.
	_rail = HBoxContainer.new()
	_rail.add_theme_constant_override("separation", 0)
	col.add_child(_rail)
	for i in items.size():
		if items[i].section == MODE_SECTION:
			var st := _widget(i, Kind.STATION)
			st.custom_minimum_size = Vector2(0, 58)
			st.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			_rail.add_child(st)

	_stage = Control.new()
	_stage.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(_stage)

	# Top level: the cards. One per section with controls, plus any item promoted to a
	# card of its own (a gallery), which takes its companion section's controls inside.
	_top = GridContainer.new()
	_top.columns = 2
	_top.add_theme_constant_override("h_separation", 12)
	_top.add_theme_constant_override("v_separation", 12)
	_top.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_stage.add_child(_top)
	var absorbed: Array[String] = []
	for i in items.size():
		if items[i].card_of != "" and not absorbed.has(items[i].card_of):
			absorbed.append(items[i].card_of)
	var order: Array[String] = []
	for i in items.size():
		var it := items[i]
		if it.section == MODE_SECTION:
			continue
		var key := "item:%d" % i if it.card_of != "" else it.section
		if it.card_of == "" and absorbed.has(it.section):
			continue
		if not order.has(key):
			order.append(key)
	for key in order:
		var card := _widget(-1, Kind.CARD)
		card.custom_minimum_size = Vector2(0, 150)
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_tile_key[_tiles.size() - 1] = key
		_top.add_child(card)
		_cards.append(card)
		_card_keys.append(key)

	# Below the top: one box per level, only one visible at a time.
	_sub = VBoxContainer.new()
	_sub.add_theme_constant_override("separation", 12)
	_sub.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_sub.visible = false
	_stage.add_child(_sub)
	_back_btn = _widget(-1, Kind.BACK)
	_back_btn.label = "BACK"
	_back_btn.custom_minimum_size = Vector2(130, 42)
	_back_btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_sub.add_child(_back_btn)
	for key in order:
		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", 12)
		box.visible = false
		_sub.add_child(box)
		var wide := VBoxContainer.new()
		box.add_child(wide)
		var ga := GridContainer.new()
		ga.columns = 2
		ga.add_theme_constant_override("h_separation", 12)
		ga.add_theme_constant_override("v_separation", 12)
		box.add_child(ga)
		var more := _widget(-1, Kind.MORE)
		more.label = "MORE"
		more.custom_minimum_size = Vector2(0, 34)
		more.visible = false
		box.add_child(more)
		var gb := GridContainer.new()
		gb.columns = 3
		gb.add_theme_constant_override("h_separation", 10)
		gb.add_theme_constant_override("v_separation", 10)
		gb.visible = false
		box.add_child(gb)
		var sec := key
		var wide_item := -1
		if key.begins_with("item:"):
			wide_item = int(key.substr(5))
			sec = items[wide_item].card_of
		_boxes[key] = {"box": box, "wide": wide, "grid_a": ga, "more": more, "grid_b": gb,
			"section": sec, "wide_item": wide_item}
		if wide_item >= 0:
			var w := _widget(wide_item, _kind_of(items[wide_item]))
			w.big = true
			w.custom_minimum_size = Vector2(0, 140)
			wide.add_child(w)
		for i in items.size():
			var it := items[i]
			if it.section != sec or it.section == MODE_SECTION or i == wide_item or it.card_of != "":
				continue
			var w := _widget(i, _kind_of(it))
			if it.primary:
				w.custom_minimum_size = Vector2(0, 100)
				w.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				ga.add_child(w)
			else:
				w.custom_minimum_size = Vector2(0, 86)
				w.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				gb.add_child(w)

	_ripple = Ripple.new()
	_ripple.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(_ripple)


func _kind_of(it: Item) -> int:
	if it.kind >= 0:
		return it.kind
	return Kind.CAROUSEL if it.step.is_valid() else Kind.ACTION


func _widget(item: int, kind: int) -> Widget:
	var w := Widget.new()
	w.kind = kind
	if item >= 0:
		w.label = items[item].label
		while _widgets.size() <= item:
			_widgets.append(null)
		_widgets[item] = w
	_tiles.append(w)
	_tile_item.append(item)
	_tile_kind.append(kind)
	_tile_key.append("")
	_hover.append(0.0)
	_pulse.append(0.0)
	return w


func _label(text: String, size: int, colour: Color, weight: int) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", _font(weight))
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", colour)
	return l


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
	_crumb_label.add_theme_color_override("font_color", _mode_col)
	for i in _tiles.size():
		var w := _tiles[i] as Widget
		w.hue = _mode_col
		w.accent = _accent
		w.line = _line
		w.ink = _tile_bg
		w.hot = _hot
		w.queue_redraw()
	if _ray_mat != null:
		var rc := _accent
		rc.a = 0.42
		_ray_mat.albedo_color = rc
		_dot_mat.albedo_color = _accent
	_back_dirty = true


func _build_layers() -> bool:
	var xri := XRServer.find_interface("OpenXR")
	if xri == null or not xri.is_initialized():
		return false
	_blayer = OpenXRCompositionLayerQuad.new()
	_blayer.quad_size = PANEL_METRES
	_blayer.layer_viewport = _bvp
	_blayer.alpha_blend = true
	_blayer.sort_order = 1
	add_child(_blayer)
	_layer = OpenXRCompositionLayerQuad.new()
	_layer.quad_size = PANEL_METRES
	_layer.layer_viewport = _vp
	_layer.alpha_blend = true
	_layer.sort_order = 2
	_front.add_child(_layer)
	return true


func _build_quads() -> void:
	_front = Node3D.new()
	_front.position = Vector3(0, 0, TILE_Z)
	add_child(_front)
	if _build_layers():
		return
	_bquad = _plane_mesh(_bvp, 90)
	add_child(_bquad)
	_quad = _plane_mesh(_vp, 91)
	_front.add_child(_quad)


func _plane_mesh(vp: SubViewport, prio: int) -> MeshInstance3D:
	var mesh := QuadMesh.new()
	mesh.size = PANEL_METRES
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_texture = vp.get_texture()
	mat.no_depth_test = true
	mat.render_priority = prio
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	return mi


# --- per frame ---------------------------------------------------------------

## Returns true while a ray is on the panel, so the caller hands that hand's trigger over.
func update(delta: float) -> bool:
	_wants_stick = false
	if not _focused:
		visible = false
		_set_live(false)
		_hovered = -1
		_hide_pointers()
		return false
	if _left != null and _origin != null:
		_tick_float(delta)
	var open := _pinned or _wrist_facing()
	if not _debug_hold:   # the shot tool parks _shown where it wants a frame
		_shown = clampf(_shown + (REVEAL_SPEED * delta if open else -HIDE_SPEED * delta), 0.0, 1.0)
	_shown_e = _shown * _shown * (3.0 - 2.0 * _shown)
	var was_visible := visible
	visible = _shown > 0.01
	_set_live(visible)
	if _layer != null:
		_layer.quad_size = PANEL_METRES if visible else Vector2(0.001, 0.001)
		_blayer.quad_size = _layer.quad_size
	if visible and not was_visible and OS.is_debug_build():
		_log_layers()
	if not visible:
		_hovered = -1
		_drag = -1
		_hide_pointers()
		if _shown > 0.0:
			_animate(delta)
		return false

	_sweep_mode(delta)
	# Which hand points. Worn, only the free hand can; pinned, whichever ray is on it,
	# sticky to the last one that was.
	var hit := Vector2(-1, -1)
	if _ptr != null and _tracked(_ptr):
		hit = _pointer_pixel(_ptr)
	if hit.x < 0.0 and _pinned:
		for c in [_right, _left]:
			if c != null and c != _ptr and _tracked(c):
				var h := _pointer_pixel(c)
				if h.x >= 0.0:
					_show_pointer(_ptr, false, 0.0, 0.0)
					_ptr = c
					hit = h
					break
	if not _pinned and _ptr != _right:
		_show_pointer(_ptr, false, 0.0, 0.0)
		_ptr = _right
	var was := _hovered
	_hovered = -1
	var on_panel := hit.x >= 0.0
	if on_panel and _drag < 0:
		for i in _tiles.size():
			var t := _tiles[i]
			if t.visible and t.is_visible_in_tree() and t.get_global_rect().has_point(hit):
				_hovered = i
				break
	if _drag >= 0:
		_hovered = _drag
	if _hovered != was:
		_step_dir = 0
		_step_timer = 0.0
		if _hovered >= 0:
			_haptic(0.18, 0.010)
	_tick_drag(hit, delta)
	_tick_hold(delta)
	_scrub(delta)
	_show_pointer(_ptr, true, _hit_distance, _hover[_hovered] if _hovered >= 0 else 0.0)
	_animate(delta)
	_refresh_accum += delta
	if _refresh_accum >= REFRESH_S or was != _hovered:
		_refresh_accum = 0.0
		_refresh()
	return on_panel


## One line per open in debug builds, so a device log proves what the compositor was given.
func _log_layers(why := "open") -> void:
	var lo := 9.0
	var shown := 0
	var host: Control = _top if _level == "" else _boxes[_level]["box"]
	for t in _tiles:
		if t.is_visible_in_tree() and host.is_ancestor_of(t):
			shown += 1
			var a := 1.0
			var n: Node = t
			while n != null and n != _root:
				a *= (n as CanvasItem).modulate.a if n is CanvasItem else 1.0
				n = n.get_parent()
			lo = minf(lo, a)
	var s := "[menu] %s mode=%s level='%s' zoom=%.2f/%s top=%s/%.2f/%.2f sub=%s/%.2f/%.2f tiles=%d min_a=%.2f pinned=%s front_z=%.3f" % [
		why, _mode, _level, _zoom_t, _zoom_in, _top.visible, _top.modulate.a, _top.scale.x,
		_sub.visible, _sub.modulate.a, _sub.scale.x, shown, lo, _pinned, _front.position.z]
	for pair in [["back", _blayer, _bvp], ["front", _layer, _vp]]:
		var l := pair[1] as OpenXRCompositionLayerQuad
		var v := pair[2] as SubViewport
		if l == null:
			s += " %s=mesh vp=%s mode=%d" % [pair[0], v.size, v.render_target_update_mode]
		else:
			s += " %s: vis=%s quad=%s sort=%d vp=%s mode=%d at=%s" % [pair[0],
				l.is_visible_in_tree(), l.quad_size, l.sort_order, v.size,
				v.render_target_update_mode, l.global_position.snapped(Vector3.ONE * 0.001)]
	print(s)


func _hits_panel(c: XRController3D) -> bool:
	return _pointer_pixel(c).x >= 0.0


func _trigger_held() -> bool:
	return _ptr != null and _tracked(_ptr) and _ptr.is_button_pressed("trigger_click")


## A slider follows the ray while the trigger is held, detent by detent, through the
## item's own step closure so the fractal moves as the knob does.
func _tick_drag(hit: Vector2, _delta: float) -> void:
	if _drag < 0:
		return
	if not _trigger_held():
		_drag = -1
		return
	var i := _tile_item[_drag]
	if i < 0 or hit.x < 0.0:
		return
	var w := _widgets[i]
	var it := items[i]
	var tr := w.track()
	var gx := w.get_global_rect().position.x + tr.position.x
	var u := clampf((hit.x - gx) / maxf(1.0, tr.size.x), 0.0, 1.0)
	var n := _count_of(it)
	var want := int(round(u * float(n - 1)))
	var cur := int(it.index.call())
	var guard := n
	while cur != want and guard > 0 and it.step.is_valid():
		it.step.call(1 if want > cur else -1)
		cur = int(it.index.call())
		guard -= 1
		_haptic(0.3, 0.012)
		_pulse[_drag] = 1.0
	w.fill_t = float(cur) / maxf(1.0, float(n - 1))
	w.queue_redraw()


## Hold-to-confirm: the ring fills while the trigger is held on the control.
func _tick_hold(delta: float) -> void:
	var i := _hovered
	if i >= 0 and _tile_kind[i] == Kind.HOLD and _trigger_held():
		if _hold_i != i:
			_hold_i = i
			_hold_t = 0.0
			_hold_tick = 0
		_hold_t = minf(1.0, _hold_t + delta / HOLD_S)
		var tick := int(_hold_t * 4.0)
		if tick != _hold_tick:
			_hold_tick = tick
			_haptic(0.25 + 0.15 * tick, 0.015)
		if _hold_t >= 1.0:
			var it := _tile_item[i]
			_hold_t = 0.0
			_hold_i = -1
			_haptic(0.8, 0.05)
			if it >= 0:
				items[it].advance.call()
	else:
		_hold_i = -1
		_hold_t = 0.0
	for k in _tiles.size():
		if _tile_kind[k] == Kind.HOLD:
			var w := _tiles[k] as Widget
			var want := _hold_t if k == _hold_i else 0.0
			if w.hold_t != want:
				w.hold_t = want
				w.queue_redraw()


func _sweep_mode(delta: float) -> void:
	if _mode_t >= 1.0:
		return
	_mode_t = minf(1.0, _mode_t + delta / MODE_SWEEP_S)
	var k := _mode_t * _mode_t * (3.0 - 2.0 * _mode_t)
	_mode_col = _mode_from.lerp(_mode_to, k)
	_apply_theme()


func _scrub(delta: float) -> void:
	if _hovered < 0:
		return
	var i := _tile_item[_hovered]
	if i < 0 or not items[i].step.is_valid():
		return
	_wants_stick = true
	var x := 0.0
	if _ptr != null and _tracked(_ptr):
		x = _ptr.get_vector2("primary").x
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
	items[i].step.call(dir)
	_pulse[_hovered] = 1.0
	_haptic(0.3, 0.012)
	_refresh()


func wants_stick() -> bool:
	return _wants_stick


func pointer_is_right() -> bool:
	return _ptr == _right


func _set_live(on: bool) -> void:
	if on and _theme_dirty:
		_theme_dirty = false
		_apply_theme()
	var want := SubViewport.UPDATE_ALWAYS if on else SubViewport.UPDATE_DISABLED
	if _vp != null and _vp.render_target_update_mode != want:
		_vp.render_target_update_mode = want
	if not on and _bvp != null:
		_bvp.render_target_update_mode = SubViewport.UPDATE_DISABLED


## A trigger pulled with a ray on the panel. The pointing hand's trigger acts; the other
## hand's goes back up a level.
func trigger(right_hand: bool) -> void:
	if right_hand == pointer_is_right():
		activate()
	else:
		back()


func activate() -> void:
	if _hovered < 0 or _hovered >= _tiles.size():
		return
	var k := _tile_kind[_hovered]
	var i := _tile_item[_hovered]
	var w := _tiles[_hovered] as Widget
	var centre := w.get_global_rect().get_center()
	match k:
		Kind.CARD:
			_go_level(_tile_key[_hovered], centre, true)
		Kind.BACK:
			back()
			return
		Kind.MORE:
			_more = not _more
			_refresh()
		Kind.STATION:
			items[i].advance.call()
		Kind.SLIDER:
			_drag = _hovered
			_tick_drag(_pointer_pixel(_ptr), 0.0)
		Kind.HOLD:
			return   # the ring does it
		Kind.CAROUSEL:
			if items[i].step.is_valid():
				var r := w.get_global_rect()
				var hit := _pointer_pixel(_ptr)
				var dir := -1 if hit.x >= 0.0 and hit.x < r.position.x + r.size.x * 0.35 else 1
				items[i].step.call(dir)
			else:
				items[i].advance.call()
		_:
			items[i].advance.call()
	_pulse[_hovered] = 1.0
	_ripple.at = centre
	_ripple.col = _mode_col if (k == Kind.CARD or k == Kind.STATION) else _accent
	_ripple.t = 1.0
	_haptic(0.55, 0.025)
	_refresh()


func back() -> void:
	if _level == "":
		return
	var from := _zoom_at
	_go_level("", from, false)
	_haptic(0.4, 0.02)


## Move between levels. The zoom pivots on `at`: into a card, the cards grow around it
## and the box unfolds where the card was; back, the reverse.
func _go_level(key: String, at: Vector2, zoom_in: bool) -> void:
	if key == _level and _zoom_t >= 1.0 and _zoom_in == (key != ""):
		return
	_level = key
	_more = false
	_drag = -1
	_zoom_in = zoom_in
	_zoom_at = at
	_zoom_t = 0.0 if _vp != null and visible else 1.0
	for k in _boxes:
		(_boxes[k]["box"] as Control).visible = k == key
	_sub.visible = key != ""
	_top.visible = true
	_refresh()
	_animate(0.0)


func _refresh() -> void:
	for i in items.size():
		var it := items[i]
		var vis := not it.visible_when.is_valid() or bool(it.visible_when.call())
		if _widgets.size() > i and _widgets[i] != null and _widgets[i].kind != Kind.STATION:
			_widgets[i].visible = vis
	# Cards: a section with nothing showing has no card. Each card's face is its live state.
	for c in _cards.size():
		var key := _card_keys[c]
		var box: Dictionary = _boxes[key]
		var sec: String = box["section"]
		var wide_item: int = box["wide_item"]
		var card := _cards[c]
		var any := false
		card.lines.clear()
		card.swatch_cur = -1
		# A gallery card wears the gallery's name while the gallery shows; in a mode that
		# hides it (the tree has no flame to leaf through) it is the plain section card.
		card.label = sec.to_upper()
		if wide_item >= 0 and _widgets[wide_item].visible:
			var it := items[wide_item]
			any = true
			card.label = str(it.read.call())
			card.lines.append("%d of %d" % [int(it.index.call()) + 1, _count_of(it)]
				if it.index.is_valid() else it.label.capitalize())
			_feed_swatches(card, it)
		for i in items.size():
			var it := items[i]
			if it.section != sec or i == wide_item or it.card_of != "" or not _widgets[i].visible:
				continue
			any = true
			if card.lines.size() < 3:
				var v := str(it.read.call())
				card.lines.append(("%s  %s" % [it.label.capitalize(), v]) if v != "" else it.label.capitalize())
			if card.swatch_cur < 0 and it.swatch.is_valid():
				_feed_swatches(card, it)
		card.visible = any and _zoom_t < 1.0 or any and _level == ""
		card.queue_redraw()
		# Inside the box: MORE only when there is more.
		var gb: GridContainer = box["grid_b"]
		var minors := 0
		for ch in gb.get_children():
			if (ch as Control).visible:
				minors += 1
		(box["more"] as Widget).visible = minors > 0
		(box["more"] as Widget).label = "LESS" if _more else "MORE"
		gb.visible = minors > 0 and _more
	# Widget faces.
	for i in items.size():
		var w := _widgets[i]
		if w == null or not w.visible:
			continue
		var it := items[i]
		var v := str(it.read.call())
		match w.kind:
			Kind.TOGGLE:
				w.sub = v if (v != "on" and v != "off") else ""
			Kind.SLIDER:
				w.value = v
				w.ticks = _count_of(it)
				if _drag < 0 or _tile_item[_drag] != i:
					w.fill_t = float(it.index.call()) / maxf(1.0, float(w.ticks - 1))
			Kind.CAROUSEL:
				w.value = v
				_feed_swatches(w, it)
			Kind.HOLD:
				w.sub = v
			Kind.STATION:
				pass
			_:
				w.sub = v
		w.chosen = it.selected.is_valid() and bool(it.selected.call())
		w.queue_redraw()
	if title.is_valid():
		_title_label.text = str(title.call())
	if status_side.is_valid():
		_side_label.text = str(status_side.call())
	if status_main.is_valid():
		var foot := str(status_main.call())
		_foot_label.text = ("pinned  ·  " + foot) if _pinned else foot
	if _level == "":
		_crumb_label.text = _mode.to_upper()
	else:
		var box: Dictionary = _boxes[_level]
		var sec: String = box["section"]
		var name: String = items[box["wide_item"]].label if box["wide_item"] >= 0 else sec
		_crumb_label.text = "%s  ›  %s" % [_mode.to_upper(), name.to_upper()]
	_layout_dirty()


func _count_of(it: Item) -> int:
	if it.count_fn.is_valid():
		return maxi(1, int(it.count_fn.call()))
	return maxi(1, it.count_n)


## Fill a widget's swatch strip from the item's swatch_of(i), around the current index.
func _feed_swatches(w: Widget, it: Item) -> void:
	if not it.swatch.is_valid() or not it.index.is_valid():
		return
	var n := _count_of(it)
	var cur := int(it.index.call())
	w.swatches.clear()
	var lo := maxi(0, cur - 2)
	var hi := mini(n - 1, cur + 2)
	for i in range(lo, hi + 1):
		var pal: Array = it.swatch.call(i)
		var cols := PackedColorArray()
		for v in pal:
			cols.append(_c(v))
		w.swatches.append(cols)
	w.swatch_cur = cur - lo


## The back plane's shadows and spine nodes follow the front plane's layout, which only
## changes on a refresh or a level change. Deferred a frame so the containers have laid out.
func _layout_dirty() -> void:
	call_deferred("_sync_back")


func _sync_back() -> void:
	if _shadows == null:
		return
	_shadows.rects.clear()
	var nodes := PackedFloat32Array()
	var last_y := -1000.0
	for i in _tiles.size():
		var t := _tiles[i]
		if not t.visible or not t.is_visible_in_tree():
			continue
		var k := _tile_kind[i]
		if k == Kind.STATION or k == Kind.MORE:
			continue
		# Mid-zoom both levels are on screen; the shadows belong to the one arriving.
		if k == Kind.CARD and _level != "":
			continue
		var r := t.get_global_rect()
		if r.size.y <= 0.0:
			continue
		_shadows.rects.append(r)
		if absf(r.position.y - last_y) > 20.0:
			last_y = r.position.y
			nodes.append(r.position.y + minf(r.size.y * 0.5, 40.0))
	_shadows.queue_redraw()
	_backdrop.nodes = nodes
	_backdrop.queue_redraw()
	_back_dirty = true


func _animate(delta: float) -> void:
	if _shown_e != _shown_drawn:
		_shown_drawn = _shown_e
		_backdrop.spine_t = minf(1.0, _shown_e * 1.5)
		_broot.modulate.a = minf(1.0, _shown_e * 2.5)
		_backdrop.queue_redraw()
		_back_dirty = true
	if _ripple.t > 0.0:
		_ripple.t = maxf(0.0, _ripple.t - delta / RIPPLE_S)
		_ripple.queue_redraw()
	# The zoom. Into a card: the cards swell around the pressed one and fade, the box
	# grows up out of that point. Back: the box shrinks to the point and the cards return.
	if _zoom_t < 1.0:
		_zoom_t = minf(1.0, _zoom_t + (delta / ZOOM_S if delta > 0.0 else 0.0))
		if _zoom_t >= 1.0:
			_layout_dirty()   # the shadows of what just faded out go with it
			if OS.is_debug_build() and _vp != null:
				_log_layers.call_deferred("settled")
	var z := _zoom_t * _zoom_t * (3.0 - 2.0 * _zoom_t)
	var zin := z if _zoom_in else 1.0 - z
	var top_s := 1.0 + 1.3 * zin
	_top.pivot_offset = _zoom_at - _top.global_position + _stage.global_position * 0.0
	_top.scale = Vector2.ONE * top_s
	_top.modulate.a = 1.0 - minf(1.0, zin * 1.8)
	_top.visible = _top.modulate.a > 0.01
	if _sub.visible or zin > 0.0:
		_sub.pivot_offset = _zoom_at - _sub.global_position
		_sub.scale = Vector2.ONE * (0.42 + 0.58 * zin)
		_sub.modulate.a = zin
		_sub.visible = zin > 0.01
	if _zoom_t >= 1.0 and not _zoom_in and _level == "":
		_sub.visible = false
	# The front plane comes toward you mid-zoom and settles 12 mm proud again.
	var bump := sin(PI * minf(1.0, _zoom_t)) * ZOOM_Z
	_front.position = Vector3(0.0, 0.0, TILE_Z + bump)

	for i in _tiles.size():
		var w := _tiles[i] as Widget
		if not w.visible:
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
		# A switch slides to where it should be.
		if w.kind == Kind.TOGGLE:
			var it := _tile_item[i]
			var want := 1.0 if (it >= 0 and items[it].is_on.is_valid() and bool(items[it].is_on.call())) else 0.0
			if absf(w.on_t - want) > 0.002:
				w.on_t = lerpf(w.on_t, want, minf(1.0, 12.0 * delta))
				if absf(w.on_t - want) < 0.01:
					w.on_t = want
				moving = true
		# Unfold: a wave from the top-left as the panel opens.
		var r := w.get_global_rect()
		var row_t := clampf(r.position.y / float(VIEW_SIZE.y), 0.0, 1.0)
		var col_t := clampf(r.position.x / float(VIEW_SIZE.x), 0.0, 1.0)
		var start := 0.06 + row_t * 0.46 + col_t * 0.12
		var pour := clampf((_shown_e - start) / 0.36, 0.0, 1.0)
		pour = pour * pour * (3.0 - 2.0 * pour)
		if absf(w.modulate.a - pour) > 0.002:
			w.modulate.a = pour
			moving = true
		if moving or _zoom_t < 1.0:
			w.hover = h
			w.pulse = _pulse[i]
			w.pivot_offset = w.size * 0.5
			var lift := 1.0 + (0.03 if w.kind == Kind.CARD else 0.02) * h - 0.05 * _pulse[i]
			w.scale = Vector2(0.72 + 0.28 * pour, 0.9 + 0.1 * pour) * lift
			w.queue_redraw()
	# The back plane renders for a couple of frames when something on it moved, then
	# stops. Not UPDATE_ONCE: Godot's composition layer gives every UPDATE_ONCE a fresh
	# STATIC_IMAGE swapchain (openxr_composition_layer_extension.cpp), and the back is
	# dirtied every frame of the open and every refresh, so that was a swapchain created
	# and destroyed several times a second. ALWAYS-then-DISABLED reuses one swapchain and
	# the compositor keeps showing its last released image while nothing renders.
	if _bvp != null:
		var now := Engine.get_process_frames()
		if _back_dirty:
			_back_dirty = false
			_back_until = now + 2
			if _bvp.render_target_update_mode != SubViewport.UPDATE_ALWAYS:
				_bvp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		elif now >= _back_until and not _debug_hold \
				and _bvp.render_target_update_mode == SubViewport.UPDATE_ALWAYS:
			_bvp.render_target_update_mode = SubViewport.UPDATE_DISABLED


func _wrist_facing() -> bool:
	if _head == null or not is_inside_tree() or not _head.is_inside_tree():
		return false
	var to_head := (_head.global_transform.origin - global_transform.origin).normalized()
	return global_transform.basis.z.normalized().dot(to_head) > REVEAL_DOT


## Intersect a hand's ray with the front plane and convert to viewport pixels.
## Returns (-1, -1) when the ray misses.
func _pointer_pixel(c: Node3D) -> Vector2:
	if c == null or not is_inside_tree() or not c.is_inside_tree():
		return Vector2(-1, -1)
	var inv := _front.global_transform.affine_inverse()
	var origin := inv * c.global_transform.origin
	var dir := (inv.basis * (-c.global_transform.basis.z)).normalized()
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


# --- harness hooks -----------------------------------------------------------

## For the headless shot tool only: an open panel with one tile hovered.
func debug_force(shown: float, hovered: int) -> void:
	_debug_hold = true
	_shown = shown
	_shown_e = shown * shown * (3.0 - 2.0 * shown)
	_shown_drawn = -1.0
	_hovered = hovered
	if hovered >= 0 and hovered < _hover.size():
		_hover[hovered] = 1.0
	_mode_t = 1.0
	_mode_col = _mode_to
	_refresh()
	_apply_theme()
	_sync_back()
	_animate(0.0)
	_bvp.render_target_update_mode = SubViewport.UPDATE_ALWAYS


## For the shot tool: open a level by key ("" for the top, a section, or "item:N"),
## with the zoom either finished (settled=true) or started at t.
func debug_level(key: String, settled := true, t := 1.0) -> void:
	var at := Vector2(VIEW_SIZE) * 0.5
	for c in _cards.size():
		if _card_keys[c] == key:
			at = _cards[c].get_global_rect().get_center()
	_level = key
	_more = false
	_zoom_in = key != ""
	_zoom_at = at
	for k in _boxes:
		(_boxes[k]["box"] as Control).visible = k == key
	_sub.visible = key != ""
	_top.visible = true
	_zoom_t = 1.0 if settled else t
	_refresh()
	_sync_back()
	_animate(0.0)


func debug_more(on: bool) -> void:
	_more = on
	_refresh()
	_sync_back()
	_animate(0.0)


func debug_level_keys() -> Array[String]:
	return _card_keys


func debug_tile_item(tile: int) -> int:
	return _tile_item[tile] if tile >= 0 and tile < _tile_item.size() else -1


func debug_tile_kind(tile: int) -> int:
	return _tile_kind[tile] if tile >= 0 and tile < _tile_kind.size() else -1


func debug_first_tile(kind: int) -> int:
	for i in _tiles.size():
		if _tile_kind[i] == kind and _tiles[i].visible and _tiles[i].is_visible_in_tree():
			return i
	return -1


## One composited frame: the glass, then the controls over it.
func debug_composite() -> Image:
	var back := _bvp.get_texture().get_image()
	var front := _vp.get_texture().get_image()
	back.blend_rect(front, Rect2i(Vector2i.ZERO, VIEW_SIZE), Vector2i.ZERO)
	return back
