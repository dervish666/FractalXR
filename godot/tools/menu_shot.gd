extends SceneTree

## Renders the REAL wrist menu, both planes composited, to .spike-out/menu_<mode>_<level>.png
## for every mode and every level (the top cards, each card's submenu, and the submenu with
## MORE open), so the layout, the widgets and the palette-derived theme can be checked
## without a headset. Placement on the forearm, the stereo depth between the planes and the
## feel of a drag are still headset work.
##
## It drives main.tscn, not a fixture, so every mode's real control list is what is drawn.
##
## The check that matters is geometry: a control whose rectangle runs past the viewport is
## invisible in the headset however cleanly the PNG saved. Overflow fails. So does a mode
## rail with fewer than five stations, a top level with fewer than three cards, a bottom bar
## without EXIT, PASSTHRU and HELP at any level, or a control running into that bar.
##
## The galleries are walked by hand, through update() and trigger(): into each mode's picture
## page, every page turned with NEXT, every picture checked for a baked thumbnail, and one
## picture pressed, which must select that fractal. The bar is pressed from inside a card:
## HELP opens the card, PASSTHRU runs its toggle, and one pull on EXIT does not quit.
## The float is checked last: the menu key sends the panel to the lower-right spot off a test
## head pose, it holds still through 300 frames of the head turning and walking, and the key
## brings it home to the wrist.
##
## With ANIM=1 in the environment it also writes a frame sequence to .spike-out/anim/:
## the panel opening, the zoom into a card, and a slider drag.
##
##   tools/menu_shot.sh

const MODES := ["flame", "bulb", "ground", "tree", "ifs"]
const THEMES := [-1, 6]
const LONG_TITLE := "Ouroboros Cascade Nine"
const ANIM_FRAMES := 14


func _init() -> void:
	var scene: PackedScene = load("res://main.tscn")
	if scene == null:
		print("MENUSHOT FAIL: main.tscn would not load")
		quit(1)
		return
	var main := scene.instantiate()
	root.add_child(main)
	for i in 40:
		await process_frame
	if main.menu == null or main.menu._vp == null:
		print("MENUSHOT FAIL: the menu never built a viewport")
		quit(1)
		return
	main.help.close()
	for i in 5:
		await process_frame

	var failures: Array[String] = []
	# The device path. Every shot below goes through debug_level(), which once hid two
	# device bugs: a fresh panel opening with no cards, and a panel left blank after a
	# card. This walk uses only what a hand can do: open the float, aim the right ray at
	# a tile, pull a trigger. Rail to every mode, into every card and back, and the exact
	# sequence Sam hit: into a non-gallery card, then the rail to another mode.
	var walk := await _walk(main, false)
	walk.append_array(await _walk(main, true))
	failures.append_array(walk)
	print("MENUSHOT walk %s (%d problems)" % ["PASS" if walk.is_empty() else "FAIL", walk.size()])
	for w in walk:
		print("MENUSHOT walk_detail %s" % w)
	var gal := await _gallery_walk(main)
	failures.append_array(gal)
	print("MENUSHOT gallery %s (%d problems)" % ["PASS" if gal.is_empty() else "FAIL", gal.size()])
	for w in gal:
		print("MENUSHOT gallery_detail %s" % w)
	var fl := await _float_check(main)
	failures.append_array(fl)
	print("MENUSHOT float %s (%d problems)" % ["PASS" if fl.is_empty() else "FAIL", fl.size()])
	for w in fl:
		print("MENUSHOT float_detail %s" % w)
	main.menu.set_pinned(false, true)
	main.menu._shown = 0.0
	for i in 5:
		await process_frame
	var shots := 0
	var real_title: Callable = main.menu.title
	var anim := OS.get_environment("ANIM") == "1"
	for mode in MODES:
		main._set_mode(mode)
		for i in 10:
			await process_frame
		var menu = main.menu
		for theme in THEMES:
			if theme >= 0 and theme >= main.library.themes.size():
				continue
			main.theme_idx = theme
			main._theme_blend = 1.0
			main._apply_palette()
			var ttag := "preset" if theme < 0 else "theme%d" % theme
			main.menu.title = (func(): return LONG_TITLE) if theme == THEMES[THEMES.size() - 1] else real_title
			# Top level: hover the first card.
			menu.debug_level("")
			await _settle(menu)
			var hover: int = menu.debug_first_tile(menu.Kind.CARD)
			menu.debug_force(1.0, hover)
			await _settle(menu)
			var r := await _shoot(menu, "%s_top_%s" % [mode, ttag], "top")
			shots += 1
			if r != "":
				failures.append(r)
			# Every card's level, with MORE open where there is more. Only the first
			# theme sweeps the levels: the second is for the top's recolour.
			if theme != THEMES[0]:
				continue
			var keys: Array = menu.debug_level_keys()
			for key in keys:
				# Cards only exist at the top, so climb back up before asking about one.
				menu.debug_level("")
				await _settle(menu)
				if not _card_visible(menu, key):
					continue
				var gi := _grid_item(menu, key)
				var lname: String = "gallery" if gi >= 0 else _card_label(menu, key).to_lower()
				menu.debug_level(key)
				await _settle(menu)
				var h2 := _first_control(menu)
				menu.debug_force(1.0, h2)
				await _settle(menu)
				r = await _shoot(menu, "%s_%s" % [mode, lname], key)
				shots += 1
				if r != "":
					failures.append(r)
				# Every further page of a picture gallery.
				if gi >= 0:
					var pages: int = menu._pages_of(menu._count_of(menu.items[gi]))
					var p0: int = int(menu._page.get(gi, 0))
					for k in range(1, pages):
						menu.debug_page(gi, p0 + k)
						await _settle(menu)
						r = await _shoot(menu, "%s_gallery_p%d" % [mode, wrapi(p0 + k, 0, pages) + 1], key)
						shots += 1
						if r != "":
							failures.append(r)
				if _has_more(menu, key):
					menu.debug_more(true)
					await _settle(menu)
					r = await _shoot(menu, "%s_%s_more" % [mode, lname], key)
					shots += 1
					if r != "":
						failures.append(r)
					menu.debug_more(false)
			menu.debug_level("")
			await _settle(menu)
		if mode == "flame":
			var img0: Image = menu.debug_composite()
			img0.save_png("res://.spike-out/menu_flame.png")
			if anim:
				await _animate(menu)

	# The pin: fly off the arm to the float and home again, instantly, and check the panel
	# really changed parent each time. The float's feel is headset work; the reparent is not.
	var pin_ok := true
	main.menu.set_pinned(true, true)
	await process_frame
	pin_ok = pin_ok and main.menu.is_pinned() and main.menu.get_parent() == main.xr_origin
	main.menu.set_pinned(false, true)
	await process_frame
	pin_ok = pin_ok and not main.menu.is_pinned() and main.menu.get_parent() == main.left_hand
	print("MENUSHOT pin %s" % ["PASS" if pin_ok else "FAIL"])
	if not pin_ok:
		failures.append("pin: the panel did not change parent as expected")

	# Negative control. A geometry check that cannot fail is decoration: run the same
	# check against a panel too short to hold the menu and require it to complain.
	main.menu.debug_level("")
	await _settle(main.menu)
	var control := _check_geometry(main.menu, "top", 200.0)
	if control.is_empty():
		failures.append("negative control: a 200 px panel reported no overflow")
	print("MENUSHOT control %s (%d complaints at 200 px)" % [
		"PASS" if not control.is_empty() else "FAIL", control.size()])

	var verdict: bool = failures.is_empty() and shots >= MODES.size() * 3
	if not verdict:
		for f in failures:
			print("MENUSHOT DETAIL %s" % f)
	print("MENUSHOT %s shots=%d failures=%d" % [
		"PASS" if verdict else "FAIL", shots, failures.size()])
	quit(0 if verdict else 1)


func _settle(menu) -> void:
	for i in 4:
		await process_frame
	menu._sync_back()
	for i in 3:
		await process_frame


func _shoot(menu, tag: String, level: String) -> String:
	var geom := _check_geometry(menu, level)
	var img: Image = menu.debug_composite()
	var err: int = img.save_png("res://.spike-out/menu_%s.png" % tag)
	var blank := _is_blank(img)
	var ok: bool = err == OK and geom.is_empty() and not blank
	var why: Array = geom if not geom.is_empty() else (
		["save error %d" % err] if err != OK else (["nothing drawn"] if blank else []))
	print("MENUSHOT %s %s tiles=%d%s" % [tag, "PASS" if ok else "FAIL",
		_visible_count(menu), "" if ok else "  " + ", ".join(why)])
	return "" if ok else "%s: %s" % [tag, ", ".join(why)]


## Frames for the trailer check: the open, the zoom into the first card, a slider drag.
func _animate(menu) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://.spike-out/anim"))
	menu.debug_level("")
	for f in ANIM_FRAMES:
		var t := float(f) / float(ANIM_FRAMES - 1)
		menu.debug_force(t, -1)
		await process_frame
		await process_frame
		menu.debug_composite().save_png("res://.spike-out/anim/open_%02d.png" % f)
	var keys: Array = menu.debug_level_keys()
	var key: String = keys[0]
	for k in keys:
		if _card_visible(menu, k) and str(k).begins_with("item:"):
			key = k
			break
	for f in ANIM_FRAMES:
		var t := float(f) / float(ANIM_FRAMES - 1)
		menu.debug_level(key, false, t)
		await process_frame
		await process_frame
		menu.debug_composite().save_png("res://.spike-out/anim/zoom_%02d.png" % f)
	# A slider: step it detent by detent through its own closure, as a drag does.
	menu.debug_level("look")
	await _settle(menu)
	var sl: int = menu.debug_first_tile(menu.Kind.SLIDER)
	if sl >= 0:
		var it: int = menu.debug_tile_item(sl)
		var n: int = menu._count_of(menu.items[it])
		menu.debug_force(1.0, sl)
		for f in n:
			menu.items[it].step.call(1)
			menu._pulse[sl] = 1.0
			menu._refresh()
			await process_frame
			await process_frame
			menu.debug_composite().save_png("res://.spike-out/anim/slider_%02d.png" % f)
	print("MENUSHOT anim frames written")
	menu.debug_level("")


func _card_label(menu, key: String) -> String:
	for c in menu._cards.size():
		if menu._card_keys[c] == key:
			return menu._cards[c].label
	return key


func _card_visible(menu, key: String) -> bool:
	for c in menu._cards.size():
		if menu._card_keys[c] == key:
			return menu._cards[c].visible
	return false


func _has_more(menu, key: String) -> bool:
	var box: Dictionary = menu._boxes[key]
	return (box["more"] as Control).visible


func _first_control(menu) -> int:
	for kind in [menu.Kind.SLIDER, menu.Kind.TOGGLE, menu.Kind.CAROUSEL, menu.Kind.ACTION, menu.Kind.PICK,
			menu.Kind.HOLD]:
		var i: int = menu.debug_first_tile(kind)
		if i >= 0:
			return i
	return -1


## Every visible control must lie inside the texture; the rail must have five stations;
## the top must have at least three cards; the bar must show its three and nothing on the
## stage may run into it; a picture page must show a baked picture on every button.
func _check_geometry(menu, level: String, height := -1.0) -> Array:
	var out: Array = []
	var w := float(menu.VIEW_SIZE.x)
	var h := height if height > 0.0 else float(menu.VIEW_SIZE.y)
	var lowest := 0.0
	var stations := 0
	var cards := 0
	out.append_array(_check_bar(menu, level))
	var gi := _grid_item(menu, level)
	if gi >= 0:
		out.append_array(_check_page(menu, gi, level))
	for i in menu._tiles.size():
		var t: Control = menu._tiles[i]
		if t == null or not t.visible or not t.is_visible_in_tree():
			continue
		var r: Rect2 = t.get_global_rect()
		lowest = maxf(lowest, r.end.y)
		var kind: int = menu.debug_tile_kind(i)
		var name: String = t.label
		if r.position.x < -0.5 or r.position.y < -0.5 or r.end.x > w + 0.5 or r.end.y > h + 0.5:
			out.append("%s outside (%.0f,%.0f)-(%.0f,%.0f)" % [
				name, r.position.x, r.position.y, r.end.x, r.end.y])
		if kind == menu.Kind.STATION:
			stations += 1
		elif kind == menu.Kind.CARD:
			cards += 1
	if stations != MODES.size():
		out.append("%d stations, expected %d" % [stations, MODES.size()])
	if level == "top" and cards < 3:
		out.append("%d cards at the top, expected at least 3" % cards)
	if lowest > h:
		out.append("content runs %.0f px past the panel" % (lowest - h))
	return out


## The bar: EXIT, PASSTHRU, HELP in that order, opaque, inside the panel and above the
## footer; and no control on the stage (cards or a card's controls) reaching into it.
func _check_bar(menu, tag: String) -> Array:
	var out: Array = []
	var names: Array[String] = []
	var top := INF
	for i in menu._tiles.size():
		var t: Control = menu._tiles[i]
		if t.is_visible_in_tree() and menu._bar.is_ancestor_of(t):
			names.append(t.label)
			top = minf(top, t.get_global_rect().position.y)
			if t.get_global_rect().end.y > menu._foot_label.position.y + 1.0:
				out.append("%s: bar %s overlaps the footer" % [tag, t.label])
	if names != ["EXIT", "PASSTHRU", "HELP"]:
		out.append("%s: bar shows %s, expected EXIT, PASSTHRU, HELP" % [tag, names])
	for i in menu._tiles.size():
		var t: Control = menu._tiles[i]
		if t.is_visible_in_tree() and menu._stage.is_ancestor_of(t) \
				and t.get_global_rect().end.y > top - 2.0:
			out.append("%s: %s runs into the bar (%.0f > %.0f)" % [tag, t.label,
				t.get_global_rect().end.y, top - 2.0])
	return out


## The picture item behind a level key, or -1.
func _grid_item(menu, key: String) -> int:
	if not key.begins_with("item:"):
		return -1
	var gi := int(key.substr(5))
	return gi if menu.items[gi].kind == menu.Kind.GRID else -1


## One page of pictures: the right number of buttons for the page, each with a baked
## thumbnail and a name, and the current fractal framed if it is on this page.
func _check_page(menu, gi: int, tag: String) -> Array:
	var out: Array = []
	var it = menu.items[gi]
	var n: int = menu._count_of(it)
	var per: int = menu._per_page(n)
	var p: int = int(menu._page.get(gi, 0))
	var want := mini(per, n - p * per)
	var shown := 0
	var chosen := 0
	for i in menu._tiles.size():
		if menu._tile_kind[i] != menu.Kind.PICK or menu._tile_item[i] != gi:
			continue
		var t = menu._tiles[i]
		if not t.is_visible_in_tree():
			continue
		shown += 1
		if t.tex == null:
			out.append("%s: %s has no baked thumbnail" % [tag, t.label])
		if t.label == "":
			out.append("%s: a picture button with no name" % tag)
		if t.chosen:
			chosen += 1
	if shown != want:
		out.append("%s: page %d shows %d pictures, expected %d" % [tag, p + 1, shown, want])
	var cur: int = int(it.index.call())
	var on_page := cur / per == p
	if chosen != (1 if on_page else 0):
		out.append("%s: %d pictures marked current on page %d (current %d)" % [tag, chosen, p + 1, cur])
	return out


func _visible_count(menu) -> int:
	var n := 0
	for t in menu._tiles:
		if t != null and t.visible and t.is_visible_in_tree():
			n += 1
	return n


## A transparent SubViewport that never drew reads as a clean save. Require real ink.
func _is_blank(img: Image) -> bool:
	var lit := 0
	var step := maxi(1, img.get_width() / 64)
	for y in range(0, img.get_height(), step):
		for x in range(0, img.get_width(), step):
			if img.get_pixel(x, y).a > 0.05:
				lit += 1
	return lit < 32


# --- the device-path walk ---------------------------------------------------------

var _worn := false
var _main


## Worn: hold the head 40 cm in front of the wrist panel, so the wrist reads as turned up.
func _face(main) -> void:
	var m = main.menu
	var g: Transform3D = m.global_transform
	var eye: Vector3 = g.origin + g.basis.z.normalized() * 0.4
	main.xr_camera.global_transform = Transform3D(Basis(), eye).looking_at(g.origin, Vector3.UP)


## Put the right controller 15 cm off the front plane, its ray through `pixel`.
func _aim(main, pixel: Vector2) -> void:
	var m = main.menu
	if _worn:
		_face(main)
	var half: Vector2 = m.PANEL_METRES * 0.5
	var u := pixel.x / float(m.VIEW_SIZE.x)
	var v := pixel.y / float(m.VIEW_SIZE.y)
	var f: Transform3D = m._front.global_transform
	var p := f * Vector3((u * 2.0 - 1.0) * half.x, (1.0 - 2.0 * v) * half.y, 0.0)
	var n := f.basis.z.normalized()
	var at := p + n * 0.15
	main.right_hand.global_transform = Transform3D(Basis(), at).looking_at(p, f.basis.y.normalized())


## Aim at a tile, let update() hover it, pull the right trigger. False if it never hovered.
func _press(main, tile: int) -> bool:
	var m = main.menu
	var c: Control = m._tiles[tile]
	for k in 30:
		_aim(main, c.get_global_rect().get_center())
		await process_frame
		if m._hovered == tile:
			m.trigger(true)
			return true
	return false


## Frames until the zoom and the open have finished, on the menu's own clock.
func _settle_walk(m) -> void:
	for k in 600:
		if _worn:
			_face(_main)
		await process_frame
		if m._zoom_t >= 1.0 and m._shown >= 1.0:
			break
	for k in 4:
		await process_frame


func _alpha(c: Control, stop: Node) -> float:
	var a := 1.0
	var n: Node = c
	while n != null and n != stop:
		if n is CanvasItem:
			a *= (n as CanvasItem).modulate.a * (n as CanvasItem).self_modulate.a
		n = n.get_parent()
	return a


## The top level: at least three cards, every one drawn and opaque.
func _check_top(m, tag: String) -> Array[String]:
	var bad: Array[String] = []
	if m._level != "":
		bad.append("%s: level '%s', not the top" % [tag, m._level])
	var n := 0
	for c in m._cards:
		if not c.is_visible_in_tree():
			continue
		n += 1
		var a := _alpha(c, m._root)
		if a < 0.9:
			bad.append("%s: card %s alpha %.2f" % [tag, c.label, a])
	bad.append_array(_check_finite(m, tag))
	bad.append_array(_check_bar(m, tag))
	if n < 3:
		bad.append("%s: %d cards showing (top=%s a=%.2f)" % [tag, n, m._top.visible, m._top.modulate.a])
	return bad


## Inside a card: at least one control in its box, every one drawn and opaque.
func _check_sub(m, key: String, tag: String) -> Array[String]:
	var bad: Array[String] = []
	if m._level != key:
		bad.append("%s: level '%s', wanted '%s'" % [tag, m._level, key])
		return bad
	var box: Control = m._boxes[key]["box"]
	var n := 0
	for i in m._tiles.size():
		var t: Control = m._tiles[i]
		if not t.is_visible_in_tree() or not box.is_ancestor_of(t):
			continue
		if m._tile_kind[i] == m.Kind.MORE or m._tile_kind[i] == m.Kind.BACK:
			continue
		n += 1
		var a := _alpha(t, m._root)
		if a < 0.9:
			bad.append("%s: control %d alpha %.2f" % [tag, i, a])
	if n == 0:
		bad.append("%s: no controls showing" % tag)
	bad.append_array(_check_bar(m, tag))
	if OS.get_environment("WALKSHOT") == "1":
		(m.debug_composite() as Image).save_png("res://.spike-out/walk_%s.png" % tag.replace("/", "_").replace(" ", "_"))
		print("WALK %s sub.scale=%s sub.pos=%s sub.a=%.2f top.vis=%s box=%s" % [tag, m._sub.scale, m._sub.global_position, m._sub.modulate.a, m._top.visible, (m._boxes[key]["box"] as Control).get_global_rect()])
	return bad


func _check_finite(m, tag: String) -> Array[String]:
	var bad: Array[String] = []
	for v in [m._zoom_at, m._top.pivot_offset, m._sub.pivot_offset]:
		if not (v as Vector2).is_finite() or absf(v.x) > 1e5 or absf(v.y) > 1e5:
			bad.append("%s: zoom pivot ran away (zoom_at=%s top.pivot=%s sub.pivot=%s)" % [
				tag, m._zoom_at, m._top.pivot_offset, m._sub.pivot_offset])
			break
	return bad


func _station(m, mode: String) -> int:
	for i in m._tiles.size():
		if m._tile_kind[i] == m.Kind.STATION and m.items[m._tile_item[i]].label.to_lower() == mode:
			return i
	return -1


func _card_tile(m, key: String) -> int:
	for i in m._tiles.size():
		if m._tile_kind[i] == m.Kind.CARD and m._tile_key[i] == key:
			return i
	return -1


func _walk(main, pinned: bool) -> Array[String]:
	var bad: Array[String] = []
	var m = main.menu
	_worn = not pinned
	_main = main
	if _worn:
		_face(main)
	m.set_pinned(pinned, true)
	await _settle_walk(m)
	bad.append_array(_check_top(m, "open"))
	for mode in MODES:
		var st := _station(m, mode)
		if st < 0 or not await _press(main, st):
			bad.append("%s: could not press its station" % mode)
			continue
		await _settle_walk(m)
		bad.append_array(_check_top(m, "%s top" % mode))
		var keys: Array[String] = []
		for c in m._cards.size():
			if m._cards[c].is_visible_in_tree():
				keys.append(m._card_keys[c])
		for key in keys:
			var ct := _card_tile(m, key)
			if ct < 0 or not await _press(main, ct):
				bad.append("%s/%s: could not press the card" % [mode, key])
				continue
			await _settle_walk(m)
			bad.append_array(_check_sub(m, key, "%s/%s" % [mode, key]))
			m.trigger(false)   # the other hand's trigger: back up a level
			await _settle_walk(m)
			bad.append_array(_check_top(m, "%s/%s back" % [mode, key]))
	# Sam's sequence: into a card that is not the gallery, then the rail to another mode.
	for pair in [["flame", "bulb"], ["bulb", "flame"], ["tree", "ifs"]]:
		await _press(main, _station(m, pair[0]))
		await _settle_walk(m)
		var key := ""
		for c in m._cards.size():
			var k: String = m._card_keys[c]
			if m._cards[c].is_visible_in_tree() and int(m._boxes[k]["wide_item"]) < 0:
				key = k
				break
		if key == "" or not await _press(main, _card_tile(m, key)):
			bad.append("%s: no non-gallery card to press" % pair[0])
			continue
		await _settle_walk(m)
		bad.append_array(_check_sub(m, key, "%s/%s" % [pair[0], key]))
		# Stay a while, as a hand does. The zoom pivot once fed back on itself every frame
		# the top level sat scaled behind a card, and overflowed to NaN in a few seconds.
		for k in 500:
			if _worn:
				_face(main)
			await process_frame
		bad.append_array(_check_finite(m, "%s/%s after a dwell" % [pair[0], key]))
		if not await _press(main, _station(m, pair[1])):
			bad.append("%s/%s: rail to %s not pressable" % [pair[0], key, pair[1]])
			continue
		await _settle_walk(m)
		bad.append_array(_check_top(m, "%s/%s then rail to %s" % [pair[0], key, pair[1]]))
	return bad


# --- the galleries and the bar, by hand ---------------------------------------------

func _tile_where(m, kind: int, item: int, slot := -999) -> int:
	for i in m._tiles.size():
		if m._tile_kind[i] == kind and m._tile_item[i] == item and m._tiles[i].is_visible_in_tree() \
				and (slot == -999 or m._tile_slot[i] == slot):
			return i
	return -1


func _bar_tile(m, label: String) -> int:
	for i in m._tiles.size():
		if m._bar.is_ancestor_of(m._tiles[i]) and m._tiles[i].label == label:
			return i
	return -1


## Through update() and trigger() only: rail to each mode, into its picture page, turn every
## page with NEXT (checking each), back round to the first, then press a picture that is not
## the current one and require the app to have selected exactly it.
func _gallery_walk(main) -> Array[String]:
	var bad: Array[String] = []
	var m = main.menu
	_worn = false
	_main = main
	m.set_pinned(true, true)
	await _settle_walk(m)
	for mode in MODES:
		if not await _press(main, _station(m, mode)):
			bad.append("%s: station not pressable" % mode)
			continue
		await _settle_walk(m)
		var key := ""
		var gi := -1
		for c in m._cards.size():
			var k: String = m._card_keys[c]
			if m._cards[c].is_visible_in_tree() and _grid_item(m, k) >= 0:
				key = k
				gi = _grid_item(m, k)
		if gi < 0:
			bad.append("%s: no picture gallery card at the top" % mode)
			continue
		if not await _press(main, _card_tile(m, key)):
			bad.append("%s: could not press the gallery card" % mode)
			continue
		await _settle_walk(m)
		var it = m.items[gi]
		var n: int = m._count_of(it)
		var pages: int = m._pages_of(n)
		var start: int = int(m._page.get(gi, -1))
		if start != int(it.index.call()) / m._per_page(n):
			bad.append("%s: opened on page %d, current entry is on page %d" % [mode, start + 1,
				int(it.index.call()) / m._per_page(n) + 1])
		var seen := 0
		for p in pages:
			bad.append_array(_check_page(m, gi, "%s gallery page %d" % [mode, int(m._page[gi]) + 1]))
			seen += 1
			if pages > 1:
				var before: int = int(m._page[gi])
				if not await _press(main, _tile_where(m, m.Kind.PAGE, gi, 1)):
					bad.append("%s: NEXT not pressable" % mode)
					break
				for k in 6:
					await process_frame
				if int(m._page[gi]) != wrapi(before + 1, 0, pages):
					bad.append("%s: NEXT went %d -> %d of %d" % [mode, before + 1, int(m._page[gi]) + 1, pages])
		if pages > 1 and int(m._page[gi]) != start:
			bad.append("%s: %d NEXTs did not come back round to page %d" % [mode, pages, start + 1])
		if pages == 1 and _tile_where(m, m.Kind.PAGE, gi, 1) >= 0:
			bad.append("%s: page arrows showing on a one-page gallery" % mode)
		# Pick the last picture on the page that is not the current one.
		var cur: int = int(it.index.call())
		var pick := -1
		var want := -1
		for i in m._tiles.size():
			if m._tile_kind[i] == m.Kind.PICK and m._tile_item[i] == gi and m._tiles[i].is_visible_in_tree():
				var j: int = int(m._page[gi]) * m._per_page(n) + m._tile_slot[i]
				if j != cur:
					pick = i
					want = j
		if pick < 0 or not await _press(main, pick):
			bad.append("%s: no picture to press" % mode)
		else:
			for k in 12:
				await process_frame
			var got: int = int(it.index.call())
			if got != want:
				bad.append("%s: pressed %s (entry %d), the app is on %d" % [mode, m._tiles[pick].label, want, got])
			elif not m._tiles[pick].chosen:
				bad.append("%s: %s selected but its button is not marked current" % [mode, m._tiles[pick].label])
			else:
				print("MENUSHOT gallery %s picked %s (%d of %d, %d pages, %d checked)" % [
					mode, m._tiles[pick].label, want + 1, n, pages, seen])
			(m.debug_composite() as Image).save_png("res://.spike-out/walk_gallery_%s.png" % mode)
		m.trigger(false)
		await _settle_walk(m)
	# The bar from inside a card: HELP opens the controls card; PASSTHRU runs its own toggle;
	# a single pull on EXIT must not quit (the ring is a hold). The closures are swapped for
	# counters so the presses are measured, not assumed, and nothing actually quits.
	var key2 := ""
	for c in m._cards.size():
		if m._cards[c].is_visible_in_tree() and _grid_item(m, m._card_keys[c]) < 0:
			key2 = m._card_keys[c]
			break
	if key2 != "" and await _press(main, _card_tile(m, key2)):
		await _settle_walk(m)
		bad.append_array(_check_bar(m, "inside %s" % key2))
		var counts := {"PASSTHRU": 0, "EXIT": 0}
		var saved := {}
		for lab in counts:
			var ti := _bar_tile(m, lab)
			var ii: int = m._tile_item[ti]
			saved[lab] = m.items[ii].advance
			m.items[ii].advance = func(): counts[lab] += 1
		if not await _press(main, _bar_tile(m, "HELP")):
			bad.append("bar: HELP not pressable inside %s" % key2)
		else:
			for k in 4:
				await process_frame
			if not main.help.is_open():
				bad.append("bar: HELP pressed, the controls card did not open")
			main.help.close()
		if not await _press(main, _bar_tile(m, "PASSTHRU")) or counts["PASSTHRU"] != 1:
			bad.append("bar: PASSTHRU press ran its toggle %d times" % counts["PASSTHRU"])
		if not await _press(main, _bar_tile(m, "EXIT")) or counts["EXIT"] != 0:
			bad.append("bar: one pull on EXIT ran quit %d times (it must be a hold)" % counts["EXIT"])
		for lab in saved:
			m.items[m._tile_item[_bar_tile(m, lab)]].advance = saved[lab]
		(m.debug_composite() as Image).save_png("res://.spike-out/walk_bar_inside.png")
		m.trigger(false)
		await _settle_walk(m)
	else:
		bad.append("bar: no card to press for the inside-a-card check")
	for k in 30:
		await process_frame
	main.help.close()
	return bad


## The float, by the menu key (main's own input path). From a test head pose the panel must
## land FLOAT_FWD ahead, FLOAT_RIGHT right and FLOAT_DROP down in the head's level frame,
## facing the eyes; hold still through 300 frames of the head turning and walking; and come
## home to the wrist on the next press.
func _float_check(main) -> Array[String]:
	var bad: Array[String] = []
	var m = main.menu
	m.set_pinned(false, true)
	for k in 20:
		await process_frame
	var cam: XRCamera3D = main.xr_camera
	var head := Transform3D(Basis.from_euler(Vector3(deg_to_rad(-12.0), deg_to_rad(30.0), 0.0)),
		Vector3(0.4, 1.55, -0.3))
	cam.global_transform = head
	for k in 3:
		await process_frame
	await _tap_key(KEY_M)
	for k in 200:
		if m._fly_t >= 1.0:
			break
		await process_frame
	if not m.is_pinned() or m.get_parent() != main.xr_origin:
		bad.append("menu key did not float the panel (pinned=%s)" % m.is_pinned())
		return bad
	var fwd := -head.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	var right := fwd.cross(Vector3.UP).normalized()
	var d: Vector3 = m.global_position - head.origin
	var got := Vector3(d.dot(right), d.y, d.dot(fwd))
	var want := Vector3(m.FLOAT_RIGHT, -m.FLOAT_DROP, m.FLOAT_FWD)
	if got.distance_to(want) > 0.005:
		bad.append("float landed at right %.3f, up %.3f, fwd %.3f; wanted %.3f, %.3f, %.3f" % [
			got.x, got.y, got.z, want.x, want.y, want.z])
	var facing: float = m.global_transform.basis.z.normalized().dot((head.origin - m.global_position).normalized())
	if facing < 0.99:
		bad.append("float does not face the head (dot %.3f)" % facing)
	print("MENUSHOT float landed right=%.3f up=%.3f fwd=%.3f facing=%.4f" % [got.x, got.y, got.z, facing])
	var held: Transform3D = m.global_transform
	var drift := 0.0
	for k in 300:
		var a := deg_to_rad(30.0 + 150.0 * sin(float(k) * 0.03))
		cam.global_transform = Transform3D(Basis.from_euler(Vector3(deg_to_rad(-12.0), a, 0.0)),
			head.origin + Vector3(0.8 * sin(float(k) * 0.02), 0.0, 0.6 * cos(float(k) * 0.025) - 0.6))
		await process_frame
		drift = maxf(drift, m.global_position.distance_to(held.origin))
	var turned: float = (m.global_transform.basis.z - held.basis.z).length()
	if drift > 1e-4 or turned > 1e-4:
		bad.append("float moved while the head did: %.4f m, basis %.4f" % [drift, turned])
	print("MENUSHOT float held through 300 frames: drift=%.6f m basis=%.6f" % [drift, turned])
	await _tap_key(KEY_M)
	for k in 200:
		if m._fly_t >= 1.0 and m.get_parent() == main.left_hand:
			break
		await process_frame
	if m.is_pinned() or m.get_parent() != main.left_hand \
			or not m.transform.is_equal_approx(m._worn_local):
		bad.append("menu key did not bring it home (pinned=%s parent=%s)" % [m.is_pinned(),
			m.get_parent().name])
	cam.global_transform = Transform3D(Basis(), Vector3(0.0, 1.6, 0.0))
	return bad


func _tap_key(code: Key) -> void:
	var down := InputEventKey.new()
	down.keycode = code
	down.physical_keycode = code
	down.pressed = true
	Input.parse_input_event(down)
	for i in 3:
		await process_frame
	var up := InputEventKey.new()
	up.keycode = code
	up.physical_keycode = code
	up.pressed = false
	Input.parse_input_event(up)
	for i in 3:
		await process_frame
