extends SceneTree

## Renders the wrist menu to .spike-out/menu_<n>.png in a few palettes, open, with one
## tile hovered, so the layout and the palette-derived theme can be checked without a
## headset. Placement on the forearm and the feel of the hover are still headset work.
##
##   tools/menu_shot.sh

const HOVER_TILE := 8


func _init() -> void:
	var lib := PresetLibrary.new()
	if not lib.load_all():
		print("MENUSHOT FAIL: presets: %s" % lib.load_error)
		quit(1)
		return
	var palettes: Array = [
		["flame", PresetLibrary.palette_of(lib.presets[0]) if lib.presets.size() > 0 else []],
	]
	for ti in [0, mini(6, lib.themes.size() - 1), mini(12, lib.themes.size() - 1)]:
		if ti >= 0 and ti < lib.themes.size():
			var pal: Array = []
			for c in lib.themes[ti]:
				pal.append(Vector3(float(c[0]), float(c[1]), float(c[2])))
			palettes.append(["theme%d" % ti, pal])
	var ok := true
	var n := 0
	for entry in palettes:
		var pal: Array = entry[1]
		if pal.size() < 5:
			continue
		var menu := WristMenu.new()
		menu.items = _spec()
		menu.title = func(): return "Nebula Drift"
		menu.status_side = func(): return "morphing"
		menu.status_main = func(): return "72 fps  ·  14 flames  ·  8.1 ms"
		var head := Node3D.new()
		var hand := Node3D.new()
		root.add_child(head)
		root.add_child(hand)
		root.add_child(menu)
		menu.setup(head, hand)
		menu.set_palette(pal)
		await process_frame
		menu.debug_force(1.0, HOVER_TILE)
		await process_frame
		await process_frame
		menu.debug_force(1.0, HOVER_TILE)
		await process_frame
		await process_frame
		var img := menu._vp.get_texture().get_image()
		var path := "res://.spike-out/menu_%s.png" % entry[0]
		var err := img.save_png(path)
		print("MENUSHOT %s %s" % [entry[0], "PASS" if err == OK else "FAIL %d" % err])
		ok = ok and err == OK
		menu.queue_free()
		head.queue_free()
		hand.queue_free()
		await process_frame
		n += 1
	quit(0 if ok and n > 0 else 1)


## A flame-mode spec shaped like the real one: same sections, same tile count.
func _spec() -> Array[WristMenu.Item]:
	var mode := 0
	var idx := {"a": 2, "b": 1}
	var out: Array[WristMenu.Item] = []
	out.append(WristMenu.Item.new("mode", "FLAME", func(): return "", func(): mode = 0
		).chosen_when(func(): return mode == 0))
	out.append(WristMenu.Item.new("mode", "BULB", func(): return "", func(): mode = 1
		).chosen_when(func(): return mode == 1))
	out.append(WristMenu.Item.new("mode", "GROUND", func(): return "", func(): mode = 2
		).chosen_when(func(): return mode == 2))
	for t in [["make", "RANDOM", "new flame"], ["make", "MUTATE", "vary this"], ["make", "BREED", "mix two"],
			["scene", "FLAME", "next"], ["scene", "DRIFT", "on"], ["scene", "PASSTHRU", "void"],
			["scene", "SPIN", "on"], ["scene", "SPEED", "6s"], ["scene", "CENTRE", "reset"],
			["scene", "HELP", "controls"],
			["look", "POINTS", "2.52M"], ["look", "SPLAT", "off"], ["look", "ADAPT", "100%"],
			["look", "SOLID", "35%"], ["look", "SIZE", "1.00"], ["look", "MOTION", "frozen"],
			["look", "DETAIL", "1.25x"], ["look", "GLOW", "on"],
			["colour", "THEME", "auto 7"], ["colour", "AUTO", "on"], ["colour", "BANDS", "3x"],
			["colour", "BRIGHT", "0.300"], ["colour", "EXPOSURE", "1x"],
			["app", "EXIT", "quit"]]:
		var v: String = t[2]
		var it := WristMenu.Item.new(t[0], t[1], func(): return v, func(): pass)
		if t[1] in ["POINTS", "SIZE", "SPEED", "DETAIL", "BRIGHT", "EXPOSURE", "BANDS", "THEME", "ADAPT", "SOLID", "MOTION", "FLAME"]:
			it.stepping(func(d: int): idx["a"] += d)
		out.append(it)
	return out
