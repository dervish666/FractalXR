extends SceneTree

## Renders the REAL wrist menu to .spike-out/menu_<mode>_<theme>.png, open, with one tile
## hovered, so the layout and the palette-derived theme can be checked without a headset.
## Placement on the forearm and the feel of the hover are still headset work.
##
## It drives main.tscn, not a fixture. The previous version rebuilt a flame-shaped control
## list by hand: it had three mode segments where the app has five, a tree-only CLEAR tile
## in the flame layout, and no way at all to see the bulb, ground or tree menus. Every
## judgement made against those images was a judgement about the fixture.
##
## The check that matters is geometry: a tile whose rectangle runs past the 760x980
## viewport is invisible in the headset however cleanly the PNG saved. Overflow fails.
##
##   tools/menu_shot.sh

const MODES := ["flame", "bulb", "ground", "tree", "ifs"]
## Themes to sweep. -1 is the genome's own palette; the rest are library themes.
const THEMES := [-1, 6, 12]
## Long strings, to prove the header and a value cell survive the worst real content.
const LONG_TITLE := "Ouroboros Cascade Nine"


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
	for mode in MODES:
		main._set_mode(mode)
		for i in 10:
			await process_frame
		# EXIT armed, so the confirm wording is measured and not guessed at.
		main._exit_armed_until = main._uptime + main.EXIT_ARM_S
		for theme in THEMES:
			if theme >= 0 and theme >= main.library.themes.size():
				continue
			main.theme_idx = theme
			main._theme_blend = 1.0
			main._apply_palette()
			# The last sweep of each mode runs the worst-case header: a name long enough
			# to want the ellipsis. A short preset name proves nothing about the trim.
			main.menu.title = (func(): return LONG_TITLE) if theme == THEMES[THEMES.size() - 1] else real_title
			# Hover a tile that this mode actually shows, so the hover state is captured
			# somewhere visible rather than on a hidden tile in another mode's section.
			var hover := _first_visible_in(main.menu, "look")
			main.menu.debug_force(1.0, hover)
			for i in 4:
				await process_frame
			main.menu.debug_force(1.0, hover)
			for i in 3:
				await process_frame

			var tag := "%s_%s" % [mode, "preset" if theme < 0 else "theme%d" % theme]
			var geom := _check_geometry(main.menu)
			var img: Image = main.menu._vp.get_texture().get_image()
			var err: int = img.save_png("res://.spike-out/menu_%s.png" % tag)
			var blank := _is_blank(img)
			var ok: bool = err == OK and geom.is_empty() and not blank
			if not ok:
				var why := geom if not geom.is_empty() else (
					["save error %d" % err] if err != OK else ["nothing drawn"])
				failures.append("%s: %s" % [tag, ", ".join(why)])
			print("MENUSHOT %s %s tiles=%d%s" % [tag, "PASS" if ok else "FAIL",
				_visible_count(main.menu), "" if ok else "  " + ", ".join(
					geom if not geom.is_empty() else ["save/blank"])])
			shots += 1
		# The flame menu keeps the original filename; notes and tools point at it.
		if mode == "flame":
			var img0: Image = main.menu._vp.get_texture().get_image()
			img0.save_png("res://.spike-out/menu_flame.png")

	# Negative control. A geometry check that cannot fail is decoration: run the same
	# check against a panel too short to hold the menu and require it to complain.
	var control := _check_geometry(main.menu, 200.0)
	if control.is_empty():
		failures.append("negative control: a 200 px panel reported no overflow")
	print("MENUSHOT control %s (%d complaints at 200 px)" % [
		"PASS" if not control.is_empty() else "FAIL", control.size()])

	var verdict: bool = failures.is_empty() and shots >= MODES.size()
	if not verdict:
		for f in failures:
			print("MENUSHOT DETAIL %s" % f)
	print("MENUSHOT %s shots=%d failures=%d" % [
		"PASS" if verdict else "FAIL", shots, failures.size()])
	quit(0 if verdict else 1)


## The first visible tile in a section, so the forced hover lands on something on screen.
func _first_visible_in(menu, section: String) -> int:
	for i in menu.items.size():
		if menu.items[i].section != section:
			continue
		if menu._tiles[i] != null and menu._tiles[i].visible:
			return i
	for i in menu.items.size():
		if menu._tiles[i] != null and menu._tiles[i].visible:
			return i
	return 0


func _visible_count(menu) -> int:
	var n := 0
	for t in menu._tiles:
		if t != null and t.visible:
			n += 1
	return n


## Every visible tile, and the panel's own footer, must lie inside the texture. A tile
## pushed past the bottom edge still saves a clean PNG and is simply not there in VR.
func _check_geometry(menu, height := -1.0) -> Array:
	var out: Array = []
	var w := float(menu.VIEW_SIZE.x)
	var h := height if height > 0.0 else float(menu.VIEW_SIZE.y)
	var lowest := 0.0
	var modes_seen := 0
	var app_seen := 0
	for i in menu.items.size():
		var t: Control = menu._tiles[i]
		if t == null or not t.visible:
			continue
		var r: Rect2 = t.get_global_rect()
		lowest = maxf(lowest, r.end.y)
		if r.position.x < -0.5 or r.position.y < -0.5 or r.end.x > w + 0.5 or r.end.y > h + 0.5:
			out.append("%s outside (%.0f,%.0f)-(%.0f,%.0f)" % [
				menu.items[i].label, r.position.x, r.position.y, r.end.x, r.end.y])
		if menu.items[i].section == menu.MODE_SECTION:
			modes_seen += 1
		elif menu.items[i].section == "app":
			app_seen += 1
	if modes_seen != MODES.size():
		out.append("%d mode segments, expected %d" % [modes_seen, MODES.size()])
	if app_seen < 3:
		out.append("%d app controls, expected PASSTHRU/HELP/EXIT" % app_seen)
	if lowest > h:
		out.append("content runs %.0f px past the panel" % (lowest - h))
	return out


## A transparent SubViewport that never drew reads as a clean save. Require real ink.
func _is_blank(img: Image) -> bool:
	var lit := 0
	var step := maxi(1, img.get_width() / 64)
	for y in range(0, img.get_height(), step):
		for x in range(0, img.get_width(), step):
			if img.get_pixel(x, y).a > 0.05:
				lit += 1
	return lit < 32
