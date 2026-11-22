extends SceneTree

## Presses every wrist-menu tile in every mode, in the states that change which tiles show,
## and records what each press changed. It is the evidence behind the tile inventory: a tile
## either moved some state on main (or on one of the mode objects), or changed the picture,
## or did neither.
##
## A press goes through WristMenu.activate() with the tile hovered, the same dispatch a
## trigger pull takes (toggle and button run advance(), a carousel steps on, HOLD waits for its
## ring). A slider is stepped once through its own step(), which is what a drag does detent by
## detent. A picture page picks the next entry through choose(). Then the press is undone where
## it can be (a toggle pressed again, a carousel or slider stepped back) and the next tile runs.
##
## Each press first measures its own idle baseline: the picture and the state over the same
## wait with nothing pressed. Variables that tick by themselves (clocks, timers) are dropped
## from that press's diff, and the row carries the idle picture change beside the pressed one.
##
## Light by design: a 640x400 window, the picture compared at 160x100, and no timings.
##
##   tools/menu_audit.sh             all modes
##   AUDIT_MODES=ground,ifs tools/menu_audit.sh

const W := 320
const H := 200
const PIX_EPS := 0.035      # a channel must move this much for a pixel to count as changed
const WAIT := 30            # frames after a press before the picture is read
## Tiles whose effect takes longer than WAIT frames to show (a bake, a mesh, a fill).
const SLOW := {"TO SKY": 900, "SURFACE": 360, "QUALITY": 360, "WORLD": 360, "SKY RES": 120,
	"FIT SPLATS": 240, "LEVELS": 120, "SHARPEST": 240, "ITER": 120, "REGROW": 240, "SOW": 240,
	"AVENUE": 240, "WALK": 120, "COUNT": 240, "SEED": 120, "SPECIES": 240, "BULBS": 360,
	"FLAMES": 420, "SHAPES": 240, "FAMILIES": 240, "RANDOM": 420, "MUTATE": 420, "BREED": 420,
	"GALAXY": 240, "ECHOES": 120, "THEME": 420, "SPHERE": 120, "JULIA": 120, "RESET": 240, "STRETCH": 120}
## Tiles whose effect is a slow fade or a clock: read the picture no sooner than this, in seconds
## (a sky fades in over 2 s, a theme blends over a 6 s morph, the tour dwells 6 s first).
const MIN_S := {"SKY": 3.0, "TO SKY": 3.0, "THEME": 7.0, "CYCLE": 4.0, "TOUR": 9.0,
	"SUN": 5.0, "BY RULE": 4.0, "SOW": 7.0, "AVENUE": 7.0, "REGROW": 7.0, "SEED": 3.0,
	"SPECIES": 7.0, "COUNT": 7.0, "DRIFT": 10.0, "BEACONS": 2.0, "ORBIT": 1.0, "ECHOES": 2.0}
## Perf instruments and counters that move on their own whatever is pressed.
const IGNORE_PREFIX := ["m._guard", "m._proc_us", "m._perf_scale", "m._fps", "m._menu_pal",
	"m._hud", "m._uptime", "cloud.measure_generation", "cloud.iterate_us", "forest.build_us",
	"forest.flush_us", "forest.adopt", "forest.drawn_", "forest.visible_cost", "forest.budget",
	"ground._proc", "m._snap_armed"]
## Pressing these is not safe or not meaningful in a harness.
const SKIP := {"EXIT": "a hold that quits the app; menu_shot.sh checks one pull does not quit"}

var main
var menu
var rows: Array = []


func _init() -> void:
	var scene: PackedScene = load("res://main.tscn")
	main = scene.instantiate()
	root.add_child(main)
	for i in 40:
		await process_frame
	main.help.close()
	menu = main.menu
	# The panel is worn on the left hand. Put the hand far below the view so the panel stays
	# shut and out of every picture; the right hand points at the floor ahead (ORBIT, JULIA).
	main.left_hand.position = Vector3(0.0, -50.0, 0.0)
	main.right_hand.position = Vector3(0.2, 1.3, -0.2)
	main.right_hand.rotation_degrees = Vector3(-35.0, 0.0, 0.0)
	main.xr_camera.position = Vector3(0.0, 1.6, 0.0)
	# The worn panel opens when the wrist faces the head; turn the hand until it does not, or
	# the open panel hides ORBIT (_tick_orbit) and takes the trigger.
	for a in [0.0, 90.0, 180.0, -90.0]:
		main.left_hand.rotation_degrees = Vector3(a, 0.0, 0.0)
		for i in 20:
			await process_frame
		if not menu.visible:
			break
	print("AUDIT menu hidden=%s" % (not menu.visible))
	var want := OS.get_environment("AUDIT_MODES")
	var modes := ["flame", "bulb", "ground", "tree", "ifs"] if want == "" else Array(want.split(","))
	for mode in modes:
		await _mode(mode)
	print("AUDIT DONE rows=%d" % rows.size())
	quit(0)


func _mode(mode: String) -> void:
	main._set_mode(mode)
	main.xr_camera.rotation_degrees = Vector3({"flame": 0.0, "bulb": -6.0, "ground": -22.0,
		"tree": -8.0, "ifs": -19.0}[mode], 0.0, 0.0)
	for i in 60:
		await process_frame
	main._recenter()
	match mode:
		"flame":
			await _state(mode, "points", func(): pass)
			await _state(mode, "splats", func():
				main.splat_on = true
				main._apply_point_look())
			main.splat_on = false
			main._apply_point_look()
		"bulb":
			await _state(mode, "splats", func(): pass)
			await _state(mode, "lines", func():
				main.line_idx = 1
				main._reload_lines())
			await _state(mode, "solid", func():
				main.line_idx = 0
				main._reload_lines()
				main.surface_idx = 4
				main._apply_surface())
			await _state(mode, "marched", func():
				main.surface_idx = 1
				main._apply_surface())
			await _state(mode, "fly", func():
				main.surface_idx = FractalMain.SURFACE_FLY_IDX
				main._apply_surface())
			main.surface_idx = 0
			main._apply_surface()
		"ground":
			await _state(mode, "flat", func(): pass)
			await _state(mode, "sphere bowl", func():
				main.ground_sphere_idx = 0
				main._step_ground_sphere(1))
			main.ground_sphere_idx = 1
			main._step_ground_sphere(-1)
			await _state(mode, "mandel sky", func():
				for k in 12:
					if main.flame_sky.is_mandel():
						break
					main._step_sky_pick(1)
				if not main._sky_switch():
					main._toggle_sky())
		"tree":
			await _state(mode, "grove", func(): pass)
			await _state(mode, "walking", func():
				if not main.forest.walking():
					main._toggle_walk())
			if main.forest.walking():
				main._toggle_walk()
		"ifs":
			await _state(mode, "table", func(): pass)
			await _state(mode, "room", func(): main._set_ifs_room(true))
			main._set_ifs_room(false)


## One state of one mode: set it up, measure the idle noise, then press every tile showing.
func _state(mode: String, state: String, setup: Callable) -> void:
	setup.call()
	# Ambient motion off, so the idle picture is still and a tile's change stands out.
	main.spin = false
	main._drift = false
	main._drift_hold = 0.0
	for i in 90:
		await process_frame
	await _settle(900)
	main._recenter()
	await _settle(240)
	var s0 := _snapshot()
	var i0 := await _grab()
	for i in WAIT:
		await process_frame
	var s1 := _snapshot()
	var i1 := await _grab()
	var ticking := {}
	for k in s0:
		if s1.get(k) != s0[k]:
			ticking[k] = true
	var noise := _diff(i0, i1)
	print("AUDIT STATE %s|%s|noise=%.4f|ticking=%d" % [mode, state, noise, ticking.size()])
	var order: Array[int] = []
	var actions: Array[int] = []
	for i in menu.items.size():
		var it = menu.items[i]
		if it.section == "mode":
			continue
		if it.visible_when.is_valid() and not bool(it.visible_when.call()):
			continue
		# Buttons that start something new (a morph, a sow) go last, so their aftermath does
		# not sit under every other tile's picture.
		if (menu._kind_of(it) == menu.Kind.ACTION or menu._kind_of(it) == menu.Kind.GRID) and not it.bar:
			actions.append(i)
		else:
			order.append(i)
	# UNDO only has something to take back once RESET (or an edit) has run.
	var undo_at := -1
	for k in actions.size():
		if menu.items[actions[k]].label == "UNDO":
			undo_at = k
	if undo_at >= 0:
		actions.append(actions[undo_at])
		actions.remove_at(undo_at)
	order.append_array(actions)
	for i in order:
		var it = menu.items[i]
		if it.visible_when.is_valid() and not bool(it.visible_when.call()):
			print("AUDIT ROW %s|%s|%s|%s|hidden-by-earlier-press|||||" % [mode, state, it.section, it.label])
			continue
		await _press_tile(mode, state, i, ticking, noise)


func _press_tile(mode: String, state: String, i: int, ticking: Dictionary, noise: float) -> void:
	var it = menu.items[i]
	var kind: int = menu._kind_of(it)
	var kname: String = menu.Kind.keys()[kind]
	if SKIP.has(it.label):
		_row(mode, state, it, kname, "", "", [], 0.0, noise, "skipped: " + SKIP[it.label])
		return
	# HOME and RESET only show what they do once something has moved.
	if it.label == "HOME" or it.label == "RESET":
		if main.ground_mode:
			main.ground.pan(Vector2(2.0, 1.0))
		else:
			main.cloud.global_translate(Vector3(0.35, 0.1, 0.0))
		for k in 10:
			await process_frame
	# This tile's own idle baseline: what drifts by itself over the same wait, picture and state.
	var sa := _snapshot()
	var ia := await _grab()
	for k in WAIT:
		await process_frame
	var s0 := _snapshot()
	var i0 := await _grab()
	var tick := ticking.duplicate()
	for k in s0:
		for pre in IGNORE_PREFIX:
			if k.begins_with(pre):
				tick[k] = true
	for k in s0:
		if sa.get(k) != s0[k]:
			tick[k] = true
	var idle := _diff(ia, i0)
	var r0 := str(it.read.call())
	var how := ""
	var tile: int = menu._tiles.find(menu._widgets[i]) if i < menu._widgets.size() else -1
	match kind:
		menu.Kind.GRID:
			var n: int = menu._count_of(it)
			var cur: int = int(it.index.call())
			it.choose.call((cur + 1) % n)
			how = "choose %d" % ((cur + 1) % n)
		menu.Kind.SLIDER:
			it.step.call(1)
			how = "step +1"
		_:
			if tile < 0:
				it.advance.call()
				how = "advance (no tile)"
			else:
				menu._hovered = tile
				menu.activate()
				how = "activate"
	var wait: int = SLOW.get(it.label, WAIT)
	var t0 := Time.get_ticks_msec()
	for k in WAIT:
		await process_frame
	var f := WAIT
	while f < wait and _busy():
		await process_frame
		f += 1
	while Time.get_ticks_msec() - t0 < int(1000.0 * float(MIN_S.get(it.label, 0.0))):
		await process_frame
	if wait > WAIT:
		await _settle(maxi(24, wait - f))
	var r1 := str(it.read.call())
	var s1 := _snapshot()
	var i1 := await _grab()
	var changed: Array = []
	for k in s1:
		if not tick.has(k) and s0.get(k) != s1[k]:
			changed.append(k)
	for k in s0:
		if not s1.has(k) and not tick.has(k):
			changed.append(k + "(gone)")
	var pix := _diff(i0, i1)
	var help_open: bool = main.help.is_open()
	# Undo what can be undone, so the next tile starts where this one did.
	var undo := ""
	match kind:
		menu.Kind.TOGGLE:
			menu._hovered = tile
			menu.activate()
			undo = "pressed again"
		menu.Kind.CAROUSEL, menu.Kind.SLIDER:
			if it.step.is_valid():
				it.step.call(-1)
				undo = "stepped back"
		_:
			undo = "none"
	if help_open:
		main.help.close()
		undo = "help closed"
	var g := 0
	while g < 600 and _busy():
		await process_frame
		g += 1
	await _settle(maxi(60, wait / 2))
	var back := _snapshot()
	var restored := true
	for k in s0:
		if not tick.has(k) and back.get(k) != s0[k]:
			restored = false
	_row(mode, state, it, kname, r0, r1, changed, pix, idle,
		"%s; undo %s%s%s" % [how, undo, "" if restored or undo == "none" else " (not restored)",
			"; help card opened" if help_open else ""])


func _row(mode: String, state: String, it, kname: String, r0: String, r1: String, changed: Array,
		pix: float, noise: float, note: String) -> void:
	var c := changed.duplicate()
	c.sort()
	var shown := c.slice(0, 8)
	var vars := ",".join(shown) + (" +%d" % (c.size() - 8) if c.size() > 8 else "")
	var line := "%s|%s|%s|%s|%s|%s|%s|%s|%d|%s|%.4f|%.4f|%s" % [mode, state, it.section, it.label,
		kname, it.hint, r0.replace("|", "/"), r1.replace("|", "/"), c.size(), vars, pix, noise, note]
	rows.append(line)
	print("AUDIT ROW " + line)


## Every plain script variable on main and on the objects the tiles drive, as one flat dict.
func _snapshot() -> Dictionary:
	var out := {}
	var objs := {"m": main, "ground": main.ground, "guide": main.guide, "orbit": main.orbit,
		"forest": main.forest, "tree": main.tree, "ifs": main.ifs, "ifs_edit": main.ifs_edit,
		"ifs_dive": main.ifs_dive, "ifs_echoes": main.ifs_echoes, "flame_echoes": main.flame_echoes,
		"galaxy": main.galaxy, "flame_sky": main.flame_sky, "cloud": main.cloud,
		"solid": main.solid, "march": main.march, "fly": main.fly, "help": main.help}
	if main.flame_sky.get("mandel") != null:
		objs["mandel"] = main.flame_sky.mandel
	for tag in objs:
		var o: Object = objs[tag]
		if o == null:
			continue
		for p in o.get_property_list():
			if not (int(p["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE):
				continue
			var t: int = int(p["type"])
			if t in [TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING, TYPE_STRING_NAME, TYPE_VECTOR2,
					TYPE_VECTOR2I, TYPE_VECTOR3, TYPE_COLOR]:
				var v = o.get(p["name"])
				if t == TYPE_FLOAT:
					v = snappedf(v, 1e-5)
				out["%s.%s" % [tag, p["name"]]] = v
	for tag in ["cloud", "tree", "ifs"]:
		var n: Node3D = main.get(tag)
		if n != null and n.is_inside_tree():
			out["%s.xform" % tag] = str(n.global_transform.origin.snapped(Vector3.ONE * 0.001)) + str(
				n.global_transform.basis.get_scale().snapped(Vector3.ONE * 0.001))
			out["%s.visible" % tag] = n.is_visible_in_tree()
	out["guide.beacons"] = main.guide.beacons.size()
	out["forest.trees"] = main._forest_tree_count()
	var env: Environment = main._env()
	if env != null:
		out["env.glow"] = env.glow_enabled
		out["env.bg"] = env.background_mode
		out["env.fog"] = env.fog_enabled
	out["vp.scale3d"] = snappedf(root.get_viewport().scaling_3d_scale, 1e-4)
	return out


## Something the last press started is still arriving: a morph, a bake, a mesh, a fill, a grow.
func _busy() -> bool:
	if main.galaxy._t < 1.0 or main.flame_sky.baking or main.cloud.is_baking():
		return true
	if not main.ground_mode and not main.tree_mode and not main.ifs_mode and main._morph_t < 1.0:
		return true
	if main.bulb_mode and main.solid.is_building():
		return true
	if main.ground_mode and main.ground.progress() < 1.0:
		return true
	if main.tree_mode and main.tree.grow_progress() < 1.0:
		return true
	if main.ifs_mode and main.ifs.is_morphing():
		return true
	return false


func _grab() -> Image:
	await RenderingServer.frame_post_draw
	var img: Image = root.get_viewport().get_texture().get_image()
	img.convert(Image.FORMAT_RGBA8)
	img.resize(W, H, Image.INTERPOLATE_BILINEAR)
	return img


## Fraction of the downsampled picture that moved by more than PIX_EPS in any channel.
func _diff(a: Image, b: Image) -> float:
	var n := 0
	for y in H:
		for x in W:
			var p := a.get_pixel(x, y)
			var q := b.get_pixel(x, y)
			if absf(p.r - q.r) > PIX_EPS or absf(p.g - q.g) > PIX_EPS or absf(p.b - q.b) > PIX_EPS:
				n += 1
	return float(n) / float(W * H)


## Wait until two pictures twelve frames apart barely differ, or `limit` frames pass.
func _settle(limit: int) -> void:
	var prev := await _grab()
	var f := 0
	while f < limit:
		for k in 12:
			await process_frame
		f += 12
		var cur := await _grab()
		if _diff(prev, cur) < 0.003:
			return
		prev = cur
