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
## rail with fewer than five stations, a top level with fewer than three cards, or an APP
## level without PASSTHRU, HELP and EXIT.
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
				var lname: String = _card_label(menu, key).to_lower()
				menu.debug_level(key)
				await _settle(menu)
				var h2 := _first_control(menu)
				menu.debug_force(1.0, h2)
				await _settle(menu)
				r = await _shoot(menu, "%s_%s" % [mode, lname], key)
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
	for kind in [menu.Kind.SLIDER, menu.Kind.TOGGLE, menu.Kind.CAROUSEL, menu.Kind.ACTION, menu.Kind.HOLD]:
		var i: int = menu.debug_first_tile(kind)
		if i >= 0:
			return i
	return -1


## Every visible control must lie inside the texture; the rail must have five stations;
## the top must have at least three cards; APP must show its three.
func _check_geometry(menu, level: String, height := -1.0) -> Array:
	var out: Array = []
	var w := float(menu.VIEW_SIZE.x)
	var h := height if height > 0.0 else float(menu.VIEW_SIZE.y)
	var lowest := 0.0
	var stations := 0
	var cards := 0
	var app_seen := 0
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
		var item: int = menu.debug_tile_item(i)
		if item >= 0 and menu.items[item].section == "app" and kind != menu.Kind.CARD:
			app_seen += 1
	if stations != MODES.size():
		out.append("%d stations, expected %d" % [stations, MODES.size()])
	if level == "top" and cards < 3:
		out.append("%d cards at the top, expected at least 3" % cards)
	if level == "app" and app_seen < 3:
		out.append("%d app controls, expected PASSTHRU/HELP/EXIT" % app_seen)
	if lowest > h:
		out.append("content runs %.0f px past the panel" % (lowest - h))
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
