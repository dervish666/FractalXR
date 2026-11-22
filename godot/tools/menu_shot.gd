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
## Every tile label means one thing across the modes (the vocabulary check), every closure
## reference in scripts/menu/ exists on main (the refs check), and a rested ray puts the
## tile's hint on its own line under the title, clear of a long title (menu_flame_look_hint.png).
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
## Labels that show in more than one mode with different hints but one meaning. Any other
## label shared across modes must carry the same hint everywhere it shows, which is how the
## vocabulary check tells one meaning from two (a tile built by shared_items.gd always does).
const SAME_MEANING := {
	"ECHOES": "copies of the thing round the room",
	"LEVELS": "recursion depth",
	"SPIN": "turns the thing in front of you; TREE's hint says that is only your tree",
}


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
	# DOCK_ONLY=1 runs just the dock check, for iterating on it.
	var dock_only := OS.get_environment("DOCK_ONLY") == "1"
	if dock_only:
		var dk := await _dock_check(main)
		print("MENUSHOT dock %s (%d problems)" % ["PASS" if dk.is_empty() else "FAIL", dk.size()])
		for w in dk:
			print("MENUSHOT dock_detail %s" % w)
		print("MENUSHOT %s shots=0 failures=%d (dock only)" % ["PASS" if dk.is_empty() else "FAIL", dk.size()])
		quit(0 if dk.is_empty() else 1)
		return
	# STATES_ONLY=1 runs the vocabulary and the per-state tile checks alone.
	if OS.get_environment("STATES_ONLY") == "1":
		var probs := await _check_vocabulary(main)
		print("MENUSHOT vocabulary %s (%d problems)" % ["PASS" if probs.is_empty() else "FAIL", probs.size()])
		for w in probs:
			print("MENUSHOT vocabulary_detail %s" % w)
		var st := await _check_states(main)
		print("MENUSHOT states %s (%d checks, %d problems)" % [
			"PASS" if st.is_empty() else "FAIL", _state_checks, st.size()])
		for w in st:
			print("MENUSHOT states_detail %s" % w)
		probs.append_array(st)
		print("MENUSHOT %s shots=0 failures=%d (states only)" % ["PASS" if probs.is_empty() else "FAIL", probs.size()])
		quit(0 if probs.is_empty() else 1)
		return
	# The device path. Every shot below goes through debug_level(), which once hid two
	# device bugs: a fresh panel opening with no cards, and a panel left blank after a
	# card. This walk uses only what a hand can do: open the float, aim the right ray at
	# a tile, pull a trigger. Rail to every mode, into every card and back, and the exact
	# sequence Sam hit: into a non-gallery card, then the rail to another mode.
	var refs := _check_refs(main)
	failures.append_array(refs)
	print("MENUSHOT refs %s (%d problems)" % ["PASS" if refs.is_empty() else "FAIL", refs.size()])
	for w in refs:
		print("MENUSHOT refs_detail %s" % w)
	var vocab := await _check_vocabulary(main)
	failures.append_array(vocab)
	print("MENUSHOT vocabulary %s (%d problems)" % ["PASS" if vocab.is_empty() else "FAIL", vocab.size()])
	for w in vocab:
		print("MENUSHOT vocabulary_detail %s" % w)
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
	var dk := await _dock_check(main)
	failures.append_array(dk)
	print("MENUSHOT dock %s (%d problems)" % ["PASS" if dk.is_empty() else "FAIL", dk.size()])
	for w in dk:
		print("MENUSHOT dock_detail %s" % w)
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

	# BULB with LINES on: PATTERN and WIDTH only show then, so the sweep above never drew them.
	main._set_mode("bulb")
	main.line_idx = 1
	for i in 10:
		await process_frame
	var lmenu = main.menu
	lmenu.debug_level("")
	await _settle(lmenu)
	var look_key := ""
	for key in lmenu.debug_level_keys():
		if _card_visible(lmenu, key) and _card_label(lmenu, key).to_lower() == "look":
			look_key = key
	var line_tiles := 0
	for i in lmenu.items.size():
		var it = lmenu.items[i]
		if it.section == "look" and it.label in ["PATTERN", "WIDTH"] and lmenu._widgets[i].visible:
			line_tiles += 1
	if look_key == "" or line_tiles != 2:
		failures.append("lines: look card %s, %d of PATTERN and WIDTH showing" % [look_key, line_tiles])
	else:
		lmenu.debug_level(look_key)
		await _settle(lmenu)
		lmenu.debug_force(1.0, _first_control(lmenu))
		await _settle(lmenu)
		var lr := await _shoot(lmenu, "bulb_look_lines", look_key)
		shots += 1
		if lr != "":
			failures.append(lr)
		if _has_more(lmenu, look_key):
			lmenu.debug_more(true)
			await _settle(lmenu)
			lr = await _shoot(lmenu, "bulb_look_lines_more", look_key)
			shots += 1
			if lr != "":
				failures.append(lr)
			lmenu.debug_more(false)
		lmenu.debug_level("")
		await _settle(lmenu)
	print("MENUSHOT lines tiles %s (%d of 2 showing)" % ["PASS" if line_tiles == 2 else "FAIL", line_tiles])
	main.line_idx = 0
	var states := await _check_states(main)
	failures.append_array(states)
	print("MENUSHOT states %s (%d checks, %d problems)" % [
		"PASS" if states.is_empty() else "FAIL", _state_checks, states.size()])
	for w in states:
		print("MENUSHOT states_detail %s" % w)

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
	var hr := await _hint_shot(main)
	shots += 1
	if hr != "":
		failures.append(hr)
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


var _state_checks := 0


## A tile shows only in the states where it does something, and its value says what is built.
## Main's own variables are set between frames and put back; visible_when and read are the
## closures the menu itself calls on a refresh. After the sweep, so no shot sees these states.
func _check_states(main) -> Array[String]:
	var bad: Array[String] = []
	var m = main.menu
	var dev := OS.is_debug_build()
	_state_checks = 0
	for mode in MODES:
		main._set_mode(mode)
		for i in 4:
			await process_frame
		# SKY took SKY PICK's list; the frame-time dials wait behind MORE wherever they show.
		_want(bad, m, mode, {"SKY": true, "SKY PICK": false})
		for it in m.items:
			if it.label in ["DETAIL", "FOVEA", "GLOW"] and _vis(it):
				_state_checks += 1
				if it.primary:
					bad.append("%s: %s is on the first page, wanted under MORE" % [mode, it.label])

	# FLAME: points have SIZE and AA, splats have OPACITY, and ADAPT never shows.
	main._set_mode("flame")
	for i in 4:
		await process_frame
	var splat0: bool = main.splat_on
	main.splat_on = false
	_want(bad, m, "flame points", {"SIZE": true, "AA": dev, "OPACITY": false, "ADAPT": false})
	main.splat_on = true
	_want(bad, m, "flame splats", {"SIZE": false, "AA": false, "OPACITY": true, "ADAPT": false})
	main.splat_on = splat0

	# BULB: the splat tiles only over particles, BREATHE only once STEADY lets them move,
	# ADAPT only on plain splats with FIT SPLATS off, DRIFT everywhere but FLY.
	main._set_mode("bulb")
	for i in 4:
		await process_frame
	var keep := [main.surface_idx, main.line_idx, main.auto_bake, main.bulb_stability_idx]
	var cloud_tiles := ["COVER", "OPACITY", "STEADY", "FIT SPLATS"]
	var all_on := func(on: bool, extra: Dictionary) -> Dictionary:
		var d := {}
		for l in cloud_tiles:
			d[l] = on
		d.merge(extra, true)
		return d
	main.surface_idx = 0
	main.line_idx = 0
	main.auto_bake = false
	main.bulb_stability_idx = 0
	_want(bad, m, "bulb splats frozen", all_on.call(true, {"ADAPT": dev, "BREATHE": false,
		"DRIFT": true, "SPLAT": false}))
	main.auto_bake = true
	_want(bad, m, "bulb splats fitted", {"ADAPT": false})
	main.auto_bake = false
	main.bulb_stability_idx = 1
	_want(bad, m, "bulb splats moving", {"BREATHE": true, "ADAPT": dev})
	main.line_idx = 1
	_want(bad, m, "bulb lines moving", all_on.call(true, {"BREATHE": true, "ADAPT": false}))
	main.line_idx = 0
	for st in [["solid", 4], ["fly", FractalMain.SURFACE_FLY_IDX]]:
		main.surface_idx = st[1]
		_want(bad, m, "bulb %s moving" % st[0], all_on.call(false, {"BREATHE": false,
			"ADAPT": false, "DRIFT": st[0] != "fly"}))
	# Marched through the real path, so DETAIL reads the pinned eye buffer.
	main.surface_idx = 1
	main._apply_surface()
	for i in 2:
		await process_frame
	_want(bad, m, "bulb marched moving", all_on.call(false, {"BREATHE": false, "ADAPT": false,
		"DRIFT": true}))
	_read(bad, m, "bulb marched", "DETAIL", "%.2fx locked" % FractalMain.MARCH_RENDER_SCALE)
	main.surface_idx = 0
	main._apply_surface()
	for i in 2:
		await process_frame
	_read(bad, m, "bulb splats", "DETAIL", "%.2fx" % FractalMain.RENDER_STEPS[main.render_idx])
	main.line_idx = keep[1]
	main.auto_bake = keep[2]
	main.bulb_stability_idx = keep[3]
	if main.surface_idx != keep[0]:
		main.surface_idx = keep[0]
		main._apply_surface()

	# SKY, one list: off, live, the presets. BULB, whose cloud holds no flame to bake.
	var pick0: int = main.flame_sky.pick
	if main._sky_switch():
		main._toggle_sky()
	main.flame_sky.set_pick(0)
	_read(bad, m, "bulb sky", "SKY", "off")
	# With a flame baked in FLAME, one step from off is that live sky. No frame runs before
	# ready goes back, so nothing draws from the borrowed flag.
	var ready0: bool = main.flame_sky.ready
	main.flame_sky.ready = true
	main._step_sky(1)
	var live := _reads(m, "SKY")
	_state_checks += 1
	if not main._sky_switch() or main.flame_sky.pick != 0 or live != "live":
		bad.append("bulb sky baked: one step from off reads '%s', switch %s, pick %d (wanted live, on, 0)" % [
			live, main._sky_switch(), main.flame_sky.pick])
	if main._sky_switch():
		main._toggle_sky()
	main.flame_sky.ready = false
	if main.flame_sky.presets.is_empty():
		bad.append("bulb sky: no preset skies to step onto")
	else:
		# With none, the live rung would read "no flame" over an empty sky: the step goes past it.
		main._step_sky(1)
		_read(bad, m, "bulb sky unbaked", "SKY", str(main.flame_sky.presets[0]["name"]))
		main._step_sky(-1)
		_state_checks += 1
		if main._sky_switch() or main.flame_sky.pick != 1:
			bad.append("bulb sky unbaked: one step back from the first preset left switch %s, pick %d (wanted off, 1)" % [
				main._sky_switch(), main.flame_sky.pick])
		_read(bad, m, "bulb sky unbaked", "SKY", "off")
	main.flame_sky.ready = ready0
	main.flame_sky.set_pick(pick0)

	# IFS: at the top rung with MOTION breathing, LEVELS says what is built.
	main._set_mode("ifs")
	for i in 4:
		await process_frame
	var lv0: int = main.ifs_detail_idx
	var amb0: bool = main.ifs.ambient
	var top: int = FractalMain.IFS_DETAIL.size() - 1
	main._step_ifs_detail(top - main.ifs_detail_idx)
	if not main.ifs.ambient:
		main._toggle_ifs_motion()
	for i in 6:
		await process_frame
	var want_top: int = FractalMain.IFS_DETAIL[top]
	var built: int = main.ifs.levels_built
	_state_checks += 1
	if built >= want_top:
		bad.append("ifs: breathing built %d levels at the top rung; the cap this reads cannot be tested" % built)
	else:
		_read(bad, m, "ifs breathing", "LEVELS", "%d · breathing" % built)
		# Drawn, and measured. A slider's value shares its row with the label, and
		# Widget._draw_slider clips it to the right 55% less the pad.
		m.debug_level("make")
		await _settle(m)
		m.debug_force(1.0, _first_control(m))
		await _settle(m)
		var r := await _shoot(m, "ifs_make_breathing", "make")
		if r != "":
			bad.append(r)
		for i in m.items.size():
			if m.items[i].label == "LEVELS" and _vis(m.items[i]) and m._widgets[i] != null:
				var w = m._widgets[i]
				var room: float = w.size.x * 0.55 - 18.0
				var need: float = w._f500.get_string_size(w.value, HORIZONTAL_ALIGNMENT_LEFT, -1, 21).x
				_state_checks += 1
				if need > room:
					bad.append("ifs breathing: LEVELS '%s' needs %.0f px, the row holds %.0f" % [w.value, need, room])
				print("MENUSHOT states LEVELS '%s' %.0f of %.0f px" % [w.value, need, room])
		m.debug_level("")
		await _settle(m)
	main._toggle_ifs_motion()
	for i in 2:
		await process_frame
	_read(bad, m, "ifs still", "LEVELS", "%d · %d copies" % [want_top, main.ifs.instance_count])
	if main.ifs.ambient != amb0:
		main._toggle_ifs_motion()
	main._step_ifs_detail(lv0 - main.ifs_detail_idx)

	# TREE: WALK reads on or off, like every other switch.
	main._set_mode("tree")
	for i in 4:
		await process_frame
	var walking0: bool = main.forest.walking()
	if walking0:
		main._toggle_walk()
	_read(bad, m, "tree", "WALK", "off")
	main._toggle_walk()
	_read(bad, m, "tree walking", "WALK", "on")
	if main.forest.walking() != walking0:
		main._toggle_walk()
	return bad


func _vis(it) -> bool:
	return not it.visible_when.is_valid() or bool(it.visible_when.call())


func _shows(menu, label: String) -> bool:
	for it in menu.items:
		if it.label == label and _vis(it):
			return true
	return false


func _reads(menu, label: String) -> String:
	for it in menu.items:
		if it.label == label and _vis(it):
			return str(it.read.call())
	return "<hidden>"


func _want(bad: Array[String], menu, state: String, shown: Dictionary) -> void:
	for label in shown:
		_state_checks += 1
		var got := _shows(menu, label)
		if got != bool(shown[label]):
			bad.append("%s: %s %s, wanted it %s" % [state, label, "shows" if got else "is hidden",
				"shown" if shown[label] else "hidden"])


func _read(bad: Array[String], menu, state: String, label: String, want: String) -> void:
	_state_checks += 1
	var got := _reads(menu, label)
	if got != want:
		bad.append("%s: %s reads '%s', wanted '%s'" % [state, label, got, want])


## Every m.<name> and FractalMain.<NAME> in scripts/menu/ must exist on main. GDScript looks
## a member up on a typed object at run time, and --check-only passes a misspelt one, so a
## renamed main.gd member would otherwise surface only when someone pressed that tile.
func _check_refs(main) -> Array[String]:
	var bad: Array[String] = []
	var consts: Dictionary = main.get_script().get_script_constant_map()
	var props := {}
	for p in main.get_property_list():
		props[p["name"]] = true
	var has := func(n: String) -> bool: return props.has(n) or main.has_method(n) or consts.has(n)
	# The control: a name main does not have must be refused, or the check proves nothing.
	if has.call("zzz_not_on_main"):
		bad.append("control: an invented name passed the reference check")
	var re_m := RegEx.create_from_string("\\bm\\.([A-Za-z_][A-Za-z0-9_]*)")
	var re_c := RegEx.create_from_string("\\bFractalMain\\.([A-Za-z_][A-Za-z0-9_]*)")
	var dir := "res://scripts/menu/"
	var seen := 0
	for f in DirAccess.get_files_at(dir):
		if not f.ends_with(".gd"):
			continue
		var src := FileAccess.get_file_as_string(dir + f)
		for re: RegEx in [re_m, re_c]:
			for r in re.search_all(src):
				seen += 1
				if not has.call(r.get_string(1)):
					bad.append("%s: %s is not on main" % [f, r.get_string(0)])
	if seen < 100:
		bad.append("only %d references found in %s; the scan is not reading the menu" % [seen, dir])
	print("MENUSHOT refs checked %d" % seen)
	return bad


## One word, one meaning: in every mode, collect the visible tiles' labels and hints. A label
## shown twice in one mode fails; so does a label whose hint differs between modes, unless
## SAME_MEANING lists it; so does a label in two modes with no hint to compare.
func _check_vocabulary(main) -> Array[String]:
	var shown := {}
	for mode in MODES:
		main._set_mode(mode)
		for i in 5:
			await process_frame
		var tiles: Array = []
		for it in main.menu.items:
			if it.section == "mode" or (it.visible_when.is_valid() and not bool(it.visible_when.call())):
				continue
			tiles.append([it.label, it.hint])
		shown[mode] = tiles
	main._set_mode("flame")
	for i in 5:
		await process_frame
	var bad := _vocabulary_problems(shown)
	# The control: one label meaning two things in two modes must be caught.
	var control := _vocabulary_problems({"a": [["ZZ", "one thing"]], "b": [["ZZ", "another"]]})
	if control.is_empty():
		bad.append("control: a label with two meanings passed")
	return bad


func _vocabulary_problems(shown: Dictionary) -> Array[String]:
	var bad: Array[String] = []
	var hints := {}   # label -> {hint: [modes]}
	for mode in shown:
		var here := {}
		for t in shown[mode]:
			var label: String = t[0]
			if here.has(label):
				bad.append("%s shows %s twice" % [mode, label])
			here[label] = true
			if not hints.has(label):
				hints[label] = {}
			if not hints[label].has(t[1]):
				hints[label][t[1]] = []
			hints[label][t[1]].append(mode)
	for label in hints:
		var by_hint: Dictionary = hints[label]
		var modes := 0
		for h in by_hint:
			modes += by_hint[h].size()
		if modes < 2 or SAME_MEANING.has(label):
			continue
		if by_hint.size() > 1:
			bad.append("%s means different things: %s" % [label, str(by_hint)])
		elif by_hint.has(""):
			bad.append("%s shows in %d modes with no hint to tell its meanings apart" % [label, modes])
	return bad


## A hint showing: the first control of FLAME's LOOK card, rested on. The hint line must carry
## exactly that tile's hint, on one line, clear of the title and the status reading.
func _hint_shot(main) -> String:
	var menu = main.menu
	main._set_mode("flame")
	for i in 5:
		await process_frame
	menu.debug_level("look")
	await _settle(menu)
	var tile := _first_control(menu)
	menu.debug_hint(tile)
	await _settle(menu)
	var it: int = menu.debug_tile_item(tile)
	var want: String = menu.items[it].hint if it >= 0 else ""
	var r := await _shoot(menu, "flame_look_hint", "look")
	var hl: Label = menu._hint_label
	var got: String = hl.text
	var hr: Rect2 = hl.get_global_rect()
	var clash := hr.intersects(menu._title_label.get_global_rect()) \
		or hr.intersects(menu._side_label.get_global_rect())
	# The line trims with an ellipsis rather than wrap, so measure every hint in every mode
	# against its width: one that would be trimmed fails here instead of in the headset.
	var font: Font = hl.get_theme_font("font")
	var px: int = hl.get_theme_font_size("font_size")
	var long := []
	for item in menu.items:
		if item.hint != "" and font.get_string_size(item.hint, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x > hr.size.x:
			long.append(item.hint)
	var ok := want != "" and got == want and not clash and long.is_empty()
	print("MENUSHOT hint %s ('%s' on the hint line, tile %s%s%s)" % [
		"PASS" if ok else "FAIL", got, menu.items[it].label if it >= 0 else "?",
		(", overlaps the title %s or status %s at %s" % [menu._title_label.get_global_rect(),
			menu._side_label.get_global_rect(), hr]) if clash else "",
		"" if long.is_empty() else ", too long: %s" % str(long)])
	menu.debug_level("")
	await _settle(menu)
	if not ok:
		return "hint: line '%s' (clash %s, too long %s), tile hint '%s'" % [got, clash, str(long), want]
	return r


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


# --- dock and undock, by hand -------------------------------------------------

## The right ray through a pixel of any front plane: the main panel's or a dock's.
func _aim_plane(main, plane: Node3D, pixel: Vector2) -> void:
	var m = main.menu
	var half: Vector2 = m.PANEL_METRES * 0.5
	var u := pixel.x / float(m.VIEW_SIZE.x)
	var v := pixel.y / float(m.VIEW_SIZE.y)
	var f: Transform3D = plane.global_transform
	var p := f * Vector3((u * 2.0 - 1.0) * half.x, (1.0 - 2.0 * v) * half.y, 0.0)
	var n := f.basis.z.normalized()
	main.right_hand.global_transform = Transform3D(Basis(), p + n * 0.15).looking_at(p, f.basis.y.normalized())


## As _press, but on whichever panel holds the tile.
func _press_any(main, tile: int) -> bool:
	var m = main.menu
	if tile < 0:
		return false
	var c: Control = m._tiles[tile]
	for k in 30:
		var d = m._dock_of_tile(tile)
		_aim_plane(main, m._front if d == null else d.front, c.get_global_rect().get_center())
		await process_frame
		if m._hovered == tile:
			m.trigger(true)
			return true
	return false


## Point the right ray at the ceiling, off every panel.
func _aim_away(main) -> void:
	main.right_hand.global_transform = Transform3D(Basis.from_euler(Vector3(deg_to_rad(80.0), 0.0, 0.0)),
		Vector3(0.6, 1.2, 0.3))


func _kind_tile(m, kind: int, side: int) -> int:
	for i in m._tiles.size():
		if m._tile_kind[i] == kind and m._tile_slot[i] == side:
			return i
	return -1


func _label_tile(m, label: String, box: Control) -> int:
	for i in m._tiles.size():
		var ii: int = m._tile_item[i]
		if ii >= 0 and m.items[ii].label == label and box.is_ancestor_of(m._tiles[i]) \
				and m._tiles[i].is_visible_in_tree():
			return i
	return -1


func _counts_str(c: Dictionary) -> String:
	return "layers=%d meshes=%d viewports=%d" % [c["layers"], c["meshes"], c["viewports"]]


## Planes (quad layers on a headset, meshes on the desktop) and viewports over the baseline.
func _counts_over(m, base: Dictionary) -> Vector2i:
	var c: Dictionary = m.debug_counts()
	return Vector2i(int(c["layers"]) + int(c["meshes"]) - int(base["layers"]) - int(base["meshes"]),
		int(c["viewports"]) - int(base["viewports"]))


## The labels showing on a docked panel, each checked against its own visibility closure.
func _dock_labels(m, side: int, bad: Array[String], tag: String) -> Array[String]:
	var out: Array[String] = []
	var d = m.debug_dock(side)
	if d == null:
		bad.append("%s: nothing docked on side %d" % [tag, side])
		return out
	for i in m._tiles.size():
		var ii: int = m._tile_item[i]
		if ii < 0 or not d.box.is_ancestor_of(m._tiles[i]) or not m._tiles[i].is_visible_in_tree():
			continue
		var it = m.items[ii]
		if it.visible_when.is_valid() and not bool(it.visible_when.call()):
			bad.append("%s: %s shows on the dock but is hidden in this mode" % [tag, it.label])
		out.append(it.label)
	if out.is_empty():
		bad.append("%s: the docked %s shows no controls" % [tag, d.key])
	return out


## The 3D scene alone: every menu plane hidden for the frame grab.
func _scene_grab(main) -> Image:
	var hidden: Array[MeshInstance3D] = []
	var nodes: Array[Node] = [main.menu]
	var k := 0
	while k < nodes.size():
		var n := nodes[k]
		k += 1
		nodes.append_array(n.get_children())
		if n is MeshInstance3D and (n as MeshInstance3D).visible:
			(n as MeshInstance3D).visible = false
			hidden.append(n)
	for i in 3:
		await process_frame
	var img := root.get_texture().get_image()
	for mi in hidden:
		mi.visible = true
	return img


func _frame_diff(a: Image, b: Image) -> float:
	var x := a.duplicate() as Image
	var y := b.duplicate() as Image
	for im in [x, y]:
		(im as Image).convert(Image.FORMAT_RGB8)
		(im as Image).resize(160, 100, Image.INTERPOLATE_BILINEAR)
	var s := 0.0
	for j in 100:
		for i in 160:
			var p := x.get_pixel(i, j)
			var q := y.get_pixel(i, j)
			s += absf(p.r - q.r) + absf(p.g - q.g) + absf(p.b - q.b)
	return s / (160.0 * 100.0 * 3.0)


func _same(a: Dictionary, b: Dictionary) -> bool:
	if a.size() != b.size():
		return false
	for k in a:
		if not b.has(k) or b[k] != a[k]:
			return false
	return true


func _gallery_key(m) -> String:
	for c in m._cards.size():
		var k: String = m._card_keys[c]
		if m._cards[c].is_visible_in_tree() and _grid_item(m, k) >= 0:
			return k
	return ""


## Dock and undock through the hand's own path, pinned: a card, its DOCK button, a control on
## the docked panel driving the scene, the rail with things docked, a gallery and a section
## the next mode lacks, wearing the menu and pinning it again, and UNDOCK. The plane and
## viewport counts must come back to the main panel's own when nothing is docked.
func _dock_check(main) -> Array[String]:
	var bad: Array[String] = []
	var m = main.menu
	_worn = false
	_main = main
	main.help.close()
	var cam: XRCamera3D = main.xr_camera
	cam.global_transform = Transform3D(Basis(), Vector3(0.0, 1.6, 0.0))
	m.set_pinned(true, true)
	await _settle_walk(m)
	if not await _press(main, _station(m, "flame")):
		bad.append("flame station not pressable")
		return bad
	await _settle_walk(m)
	var base: Dictionary = m.debug_counts()
	print("MENUSHOT dock base %s" % _counts_str(base))

	# 1. LOOK to the left, through the DOCK button inside its card.
	if not await _press(main, _card_tile(m, "look")):
		bad.append("flame look card not pressable")
		return bad
	await _settle_walk(m)
	var dl := _kind_tile(m, m.Kind.DOCK, -1)
	if dl < 0 or not m._tiles[dl].is_visible_in_tree():
		bad.append("inside look, pinned: no DOCK button showing")
		return bad
	if not await _press(main, dl):
		bad.append("DOCK left not pressable")
		return bad
	await _settle_walk(m)
	if not _same(m.docked(), {-1: "look"}):
		bad.append("after DOCK left: docked=%s" % m.docked())
		return bad
	if m._level != "":
		bad.append("after DOCK the main panel stayed on '%s', not its cards" % m._level)
	var over := _counts_over(m, base)
	if over != Vector2i(2, 2):
		bad.append("one dock: %d planes and %d viewports over the main panel's, wanted 2 and 2" % [over.x, over.y])
	print("MENUSHOT dock one docked: +%d planes +%d viewports (%s)" % [over.x, over.y, _counts_str(m.debug_counts())])
	var d = m.debug_dock(-1)
	if not d.holder.is_ancestor_of(m._boxes["look"]["box"]):
		bad.append("the look box is not on the dock")
	# Its card on the main panel says where it went; pressing it flashes the dock, no zoom.
	var ct := _card_tile(m, "look")
	if not ("docked on the left" in m._tiles[ct].lines):
		bad.append("look card reads %s, not 'docked on the left'" % [m._tiles[ct].lines])
	d.ripple.t = 0.0
	if not await _press(main, ct):
		bad.append("docked look card not pressable")
	for k in 3:
		await process_frame
	if m._level != "" or d.ripple.t <= 0.0:
		bad.append("pressing the docked card: level '%s', dock flash %.2f" % [m._level, d.ripple.t])

	# 2. Idle, the ray elsewhere: the dock's viewports stay off.
	_aim_away(main)
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 1500:
		await process_frame
	var r0: int = d.renders
	for k in 90:
		await process_frame
	var idle: int = d.renders - r0
	if idle != 0 or d.vp.render_target_update_mode != SubViewport.UPDATE_DISABLED:
		bad.append("idle dock rendered %d of 90 frames (mode %d)" % [idle, d.vp.render_target_update_mode])
	print("MENUSHOT dock idle: %d renders in 90 frames, mode=%d" % [idle, d.vp.render_target_update_mode])

	# 3. A control on the docked panel drives the scene: SPLAT, pressed on the dock.
	# SPLAT sits under the section's MORE, which opens on the dock itself.
	var st := _label_tile(m, "SPLAT", d.box)
	if st < 0:
		var mt: int = m._tiles.find(m._boxes["look"]["more"])
		if not await _press_any(main, mt):
			bad.append("MORE on the docked look panel not pressable")
		for k in 4:
			await process_frame
		st = _label_tile(m, "SPLAT", d.box)
	var splat_item = null
	var splat_was := ""
	if st < 0:
		bad.append("no SPLAT on the docked look panel")
	else:
		var it = m.items[m._tile_item[st]]
		var v0 := str(it.read.call())
		splat_item = it
		splat_was = v0
		var img_a := await _scene_grab(main)
		var r1: int = d.renders
		if not await _press_any(main, st):
			bad.append("SPLAT on the dock not pressable")
		for k in 60:
			await process_frame
		var v1 := str(it.read.call())
		var img_b := await _scene_grab(main)
		var diff := _frame_diff(img_a, img_b)
		img_b.save_png("res://.spike-out/menu_dock_scene.png")
		if v1 == v0:
			bad.append("SPLAT pressed on the dock: still reads '%s'" % v0)
		if diff < 0.01:
			bad.append("SPLAT pressed on the dock: the scene moved %.4f (wanted >= 0.01)" % diff)
		if d.renders <= r1:
			bad.append("the dock never redrew after its own control changed")
		print("MENUSHOT dock control: SPLAT '%s' -> '%s', scene diff %.4f, dock renders +%d" % [
			v0, v1, diff, d.renders - r1])

	# 3b. A change from elsewhere (the app, not this panel) wakes an idle dock, and the new
	# value is on its rendered face: POINTS stepped directly, the ray off every panel.
	var pt := _label_tile(m, "POINTS", d.box)
	if pt < 0:
		bad.append("no POINTS on the docked look panel")
	else:
		var pit = m.items[m._tile_item[pt]]
		_aim_away(main)
		var t1 := Time.get_ticks_msec()
		while Time.get_ticks_msec() - t1 < 1500:
			await process_frame
		var rect: Rect2i = Rect2i((m._tiles[pt] as Control).get_global_rect())
		var f0: Image = m.debug_dock_composite(-1).get_region(rect)
		var r2: int = d.renders
		var p0 := str(pit.read.call())
		pit.step.call(1)
		t1 = Time.get_ticks_msec()
		while Time.get_ticks_msec() - t1 < 1500:
			await process_frame
		var f1: Image = m.debug_dock_composite(-1).get_region(rect)
		var fd := _frame_diff(f0, f1)
		if d.renders <= r2 or fd < 0.002:
			bad.append("POINTS changed elsewhere ('%s' -> '%s'): dock renders +%d, its face moved %.4f" % [
				p0, str(pit.read.call()), d.renders - r2, fd])
		print("MENUSHOT dock outside change: POINTS '%s' -> '%s', dock renders +%d, face diff %.4f" % [
			p0, str(pit.read.call()), d.renders - r2, fd])
		pit.step.call(-1)

	# 4. COLOUR to the right. Then the pictures.
	if not await _press(main, _card_tile(m, "colour")):
		bad.append("flame colour card not pressable")
	await _settle_walk(m)
	if not await _press(main, _kind_tile(m, m.Kind.DOCK, 1)):
		bad.append("DOCK right not pressable")
	await _settle_walk(m)
	over = _counts_over(m, base)
	if not _same(m.docked(), {-1: "look", 1: "colour"}) or over != Vector2i(4, 4):
		bad.append("two docks: docked=%s, +%d planes +%d viewports" % [m.docked(), over.x, over.y])
	print("MENUSHOT dock two docked: +%d planes +%d viewports" % [over.x, over.y])
	_aim_away(main)
	for k in 8:
		await process_frame
	var flame_look := _dock_labels(m, -1, bad, "flame look dock")
	await _dock_pictures(main)

	# 5. The rail with both docked: they stay and show BULB's own tiles.
	if not await _press(main, _station(m, "bulb")):
		bad.append("bulb station not pressable")
	await _settle_walk(m)
	for k in 6:
		await process_frame
	if not _same(m.docked(), {-1: "look", 1: "colour"}):
		bad.append("rail to bulb with look and colour docked: docked=%s" % m.docked())
	var bulb_look := _dock_labels(m, -1, bad, "bulb look dock")
	_dock_labels(m, 1, bad, "bulb colour dock")
	if bulb_look == flame_look:
		bad.append("the docked look shows the same tiles in bulb as in flame: %s" % [bulb_look])
	print("MENUSHOT dock rail: flame look %s -> bulb look %s" % [flame_look, bulb_look])

	# 6. A docked gallery becomes the next mode's gallery.
	if not await _press_any(main, _kind_tile(m, m.Kind.UNDOCK, 1)):
		bad.append("UNDOCK on the right dock not pressable")
	await _settle_walk(m)
	var gk := _gallery_key(m)
	if gk == "" or not await _press(main, _card_tile(m, gk)):
		bad.append("bulb gallery card not pressable")
	await _settle_walk(m)
	if not await _press(main, _kind_tile(m, m.Kind.DOCK, 1)):
		bad.append("DOCK right from the gallery not pressable")
	await _settle_walk(m)
	if not await _press(main, _station(m, "flame")):
		bad.append("flame station not pressable")
	await _settle_walk(m)
	var gk2 := _gallery_key(m)
	var right_key: String = m.docked().get(1, "")
	if right_key != gk2 or gk2 == gk or _grid_item(m, right_key) < 0:
		bad.append("gallery %s docked, rail to flame: docked %s, flame's gallery is %s" % [gk, right_key, gk2])
	print("MENUSHOT dock gallery: bulb %s -> flame %s" % [gk, right_key])

	# 7. A section the next mode lacks goes home: TREE's make, then the rail to BULB.
	if not await _press(main, _station(m, "tree")):
		bad.append("tree station not pressable")
	await _settle_walk(m)
	if not await _press(main, _card_tile(m, "make")):
		bad.append("tree make card not pressable")
	await _settle_walk(m)
	if not await _press(main, _kind_tile(m, m.Kind.DOCK, -1)):
		bad.append("DOCK left from make not pressable")
	await _settle_walk(m)
	var tree_docked: Dictionary = m.docked()
	if not await _press(main, _station(m, "bulb")):
		bad.append("bulb station not pressable")
	await _settle_walk(m)
	for k in 3:
		await process_frame
	var make_box: Control = m._boxes["make"]["box"]
	if m.docked().has(-1) or make_box.get_parent() != m._sub or make_box.visible:
		bad.append("make docked in tree, rail to bulb: docked=%s, make box under %s, visible %s" % [
			m.docked(), make_box.get_parent().name, make_box.visible])
	over = _counts_over(m, base)
	if over != Vector2i(2, 2):
		bad.append("after make went home: +%d planes +%d viewports, wanted 2 and 2" % [over.x, over.y])
	print("MENUSHOT dock section the mode lacks: tree %s -> bulb %s" % [tree_docked, m.docked()])

	# 8. Worn, the docks are put away and remembered; pinned again, they come back.
	var before: Dictionary = m.docked()
	m.set_pinned(false, true)
	for k in 4:
		await process_frame
	var worn_over := _counts_over(m, base)
	if not m.docked().is_empty() or worn_over != Vector2i.ZERO:
		bad.append("worn: docked=%s, +%d planes +%d viewports" % [m.docked(), worn_over.x, worn_over.y])
	m.set_pinned(true, true)
	await _settle_walk(m)
	if not _same(m.docked(), before):
		bad.append("pinned again: docked=%s, wanted %s" % [m.docked(), before])
	print("MENUSHOT dock worn: docked=%s +%d/+%d, pinned again: %s" % [{}, worn_over.x, worn_over.y, m.docked()])

	# 9. UNDOCK by its own button: back to the main panel's own planes and viewports.
	if not await _press_any(main, _kind_tile(m, m.Kind.UNDOCK, 1)):
		bad.append("UNDOCK not pressable")
	for k in 4:
		await process_frame
	over = _counts_over(m, base)
	if not m.docked().is_empty() or over != Vector2i.ZERO:
		bad.append("after the last UNDOCK: docked=%s, +%d planes +%d viewports" % [m.docked(), over.x, over.y])
	print("MENUSHOT dock undocked: %s" % _counts_str(m.debug_counts()))
	# Put SPLAT back where it was.
	if splat_item != null and str(splat_item.read.call()) != splat_was:
		splat_item.advance.call()
	_aim_away(main)
	m.set_pinned(false, true)
	return bad


## The pictures: a flat triptych of all three panels and the camera's view of them.
func _dock_pictures(main) -> void:
	var m = main.menu
	var gap := 24
	var w: int = m.VIEW_SIZE.x
	var h: int = m.VIEW_SIZE.y
	var out := Image.create(w * 3 + gap * 2, h, false, Image.FORMAT_RGBA8)
	out.fill(Color(0.04, 0.04, 0.05, 1.0))
	var parts: Array = [m.debug_dock_composite(-1), m.debug_composite(), m.debug_dock_composite(1)]
	for k in 3:
		var img: Image = parts[k]
		if img == null:
			continue
		img.convert(Image.FORMAT_RGBA8)
		out.blend_rect(img, Rect2i(Vector2i.ZERO, img.get_size()), Vector2i(k * (w + gap), 0))
	out.save_png("res://.spike-out/menu_dock_triptych.png")
	var cam: XRCamera3D = main.xr_camera
	var held := cam.global_transform
	var at: Vector3 = m.global_position
	cam.global_transform = Transform3D(Basis(), at + m.global_transform.basis.z.normalized() * 0.42
		+ Vector3(0, 0.04, 0)).looking_at(at, Vector3.UP)
	for k in 4:
		await process_frame
	root.get_texture().get_image().save_png("res://.spike-out/menu_dock_3d.png")
	cam.global_transform = held
	for k in 2:
		await process_frame


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
