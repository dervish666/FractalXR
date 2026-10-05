extends SceneTree

## Bakes the wrist menu's gallery pictures: every flame preset, bulb, ground family, tree
## species and IFS shape, rendered through the REAL main scene (the same _set_mode, preset,
## bulb, formula, species and shape calls the menu makes) into one atlas,
##
##   art/thumbs/thumbs.png    TILE x TILE tiles, COLS across, grouped by mode
##   art/thumbs/thumbs.json   {"tile", "groups": {mode: {name_lowercase: [x, y, w, h]}}}
##
## which WristMenu.thumb() cuts with AtlasTexture regions. Nothing renders at runtime.
##
## Framing: the particle, tree and IFS modes are drawn against the void, so each frame is
## cropped to the square around its light (the box holding 98% of the luminance, plus a
## margin) and the fractal fills its tile. The ground is a floor, not an object: it is shot
## from overhead, zoomed out to the whole set, and taken as it lands.
##
## Re-run after changing presets, bulbs, ground families, tree species or IFS shapes: a
## missing entry reads "not baked" on its button, a stale one shows the old fractal.
##
##   tools/thumb_bake.sh

const TILE := 160
const COLS := 8
const OUT_PNG := "res://art/thumbs/thumbs.png"
const OUT_JSON := "res://art/thumbs/thumbs.json"
const RAW_DIR := "res://.spike-out/thumbs"

## Overhead framing per ground family: the fractal point under the camera. The default
## home is the Mandelbrot's; the others centre on their own bodies.
const GROUND_CENTRE := {
	"mandelbrot": Vector2(-0.6, 0.0),
	"burning ship": Vector2(-0.45, -0.5),
	"tricorn": Vector2(-0.25, 0.0),
	"celtic": Vector2(-0.6, 0.0),
	"perpendicular": Vector2(-0.6, 0.0),
	"buffalo": Vector2(-0.5, -0.4),
	"cubic": Vector2(0.0, 0.0),
	"quartic": Vector2(0.0, 0.0),
}

var _tiles: Array = []   # [group, name, Image]
var _fails: Array[String] = []
var _main


func _init() -> void:
	var scene: PackedScene = load("res://main.tscn")
	if scene == null:
		print("THUMBBAKE FAIL: main.tscn would not load")
		quit(1)
		return
	_main = scene.instantiate()
	root.add_child(_main)
	for i in 40:
		await process_frame
	var m = _main
	m.help.close()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(RAW_DIR))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://art/thumbs"))
	# A standing eye, placed BEFORE any mode change: the first frame the camera leaves the
	# origin fires the one-time placement recenter, which would move whatever was framed.
	m.xr_camera.position = Vector3(0.0, 1.6, 0.0)
	m.xr_camera.rotation_degrees = Vector3.ZERO
	# The wrist turned away, so the menu stays hidden and out of every frame.
	m.left_hand.position = Vector3(-0.3, 1.0, -0.2)
	m.left_hand.rotation_degrees = Vector3(0.0, 0.0, 180.0)
	m.right_hand.position = Vector3(0.3, -5.0, 0.0)
	# Still pictures of the preset's own colours: no spin, no drift onward, no auto theme.
	m.spin = false
	m._drift = false
	m.recolor_on_drift = false
	m.theme_idx = -1
	for i in 10:
		await process_frame

	await _flames(m)
	await _bulbs(m)
	await _ifs(m)
	await _trees(m)
	await _ground(m)

	var ok := _write_atlas()
	for f in _fails:
		print("THUMBBAKE DETAIL %s" % f)
	print("THUMBBAKE %s tiles=%d failures=%d" % ["PASS" if ok and _fails.is_empty() else "FAIL",
		_tiles.size(), _fails.size()])
	quit(0 if ok and _fails.is_empty() else 1)


func _flames(m) -> void:
	m._set_mode("flame")
	for i in m.library.count():
		m._load_preset(i)
		_stand_back(m, 2.4)
		await _frames(m.CONVERGE_FRAMES + 30)
		_take("flame", m.library.name_at(i), true)


func _bulbs(m) -> void:
	m._set_mode("bulb")
	m.spin = false
	# The raymarched SURFACE, the bulb's own lit shape: at tile size the splat shell reads as a
	# white blob, the marched surface as the fractal it is.
	m.surface_idx = 1
	m._apply_surface()
	for i in m.library.bulbs.size():
		m._load_bulb(i)
		_stand_back(m, 0.5)
		await _frames(m.BULB_SETTLE_FRAMES + 30)
		var name := str(m.library.bulbs[i].get("name", "?"))
		if _lit_fraction(_frame()) < 0.005:
			# The marcher drew nothing for this one (Snowflake, 2026-10-05). Say so, and take
			# the splat shell instead: a picture of the bulb beats a black button.
			print("THUMBBAKE note: bulb/%s marches blank on this machine, baking its splats" % name)
			m.surface_idx = 0
			m._apply_surface()
			await _frames(m.BULB_SETTLE_FRAMES + 20)
			for k in 600:
				if not m.cloud.is_baking() and (m.cloud.bake_ready or not m.auto_bake):
					break
				await process_frame
			await _frames(20)
			_take("bulb", name, true)
			m.surface_idx = 1
			m._apply_surface()
			continue
		_take("bulb", name, true)
	m.surface_idx = 0
	m._apply_surface()


func _ifs(m) -> void:
	m._set_mode("ifs")
	m.ifs.ambient = false
	# The hero alone: the echoes are copies of it scattered through the room.
	m.ifs_echoes.set_step(0)
	for i in FractalIFS.PRESETS.size():
		if i != m.ifs_preset_idx:
			m._cycle_ifs_preset(i - m.ifs_preset_idx)
		for k in 600:
			if not m.ifs.is_morphing():
				break
			await process_frame
		m.ifs.finish_grow()
		_stand_back(m, 0.3)
		await _frames(8)
		_take("ifs", FractalIFS.preset_name(i), true)


func _trees(m) -> void:
	m._set_mode("tree")
	m.forest.succession = false
	m.forest.clear()
	# species_shot's framing: step back and look at the hero's middle.
	m.xr_camera.position = Vector3(0.0, 2.8, 5.2)
	m.xr_camera.look_at(Vector3(0.0, 2.5, -2.2))
	for i in FractalTree.SHAPE_NAMES.size():
		m._cycle_tree_shape(i - m.tree_shape_idx)
		m.tree.seed_value = 7
		m.tree.build()
		m.tree.grow_t = m.tree.grow_s + 2.0
		await _frames(8)
		_take("tree", FractalTree.SHAPE_NAMES[i], true)
	m.xr_camera.position = Vector3(0.0, 1.6, 0.0)
	m.xr_camera.rotation_degrees = Vector3.ZERO


func _ground(m) -> void:
	m._set_mode("ground")
	m.orbit_on = false
	m.orbit.visible = false
	# Overhead, zoomed all the way out: the whole set is a few metres across under the eye.
	m.xr_camera.position = Vector3(0.0, 3.6, 0.0)
	m.xr_camera.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	for f in FractalGround.FORMULA_NAMES.size():
		var name: String = FractalGround.FORMULA_NAMES[f]
		m.ground.set_formula(f)
		m.ground.home()
		m.ground.zoom(0.0001)
		var c: Vector2 = GROUND_CENTRE.get(name, Vector2(-0.6, 0.0))
		m.ground.set_viewer_fractal(c.x, c.y)
		await _frames(30)
		for k in 600:
			if m.ground.progress() > 0.999:
				break
			await process_frame
		await _frames(10)
		_take("ground", name, false)


## Recentre the mode's object in front of a standing eye, then step the eye back by `back`
## metres and look at the object, so all of it is in frame for the crop.
func _stand_back(m, back: float) -> void:
	m.xr_camera.position = Vector3(0.0, 1.6, 0.0)
	m.xr_camera.rotation_degrees = Vector3.ZERO
	m._recenter()
	var at: Vector3 = (m.ifs if m.ifs_mode else m.cloud).global_position
	m.xr_camera.position = Vector3(0.0, 1.6, back)
	m.xr_camera.look_at(at)


func _frames(n: int) -> void:
	for i in n:
		await process_frame


## Grab the frame, frame it, shrink it to a tile, and refuse a blank one.
func _frame() -> Image:
	var img: Image = root.get_viewport().get_texture().get_image()
	img.convert(Image.FORMAT_RGB8)
	return img


func _take(group: String, name: String, crop: bool) -> void:
	var img := _frame()
	img.save_png("%s/%s_%s.png" % [RAW_DIR, group, name.replace(" ", "_")])
	var sq := _crop_light(img) if crop else _centre_square(img)
	sq.resize(TILE, TILE, Image.INTERPOLATE_LANCZOS)
	var lit := _lit_fraction(sq)
	print("THUMBBAKE %s/%s lit=%.3f" % [group, name, lit])
	if lit < 0.02:
		_fails.append("%s/%s drew nothing (lit %.3f)" % [group, name, lit])
	_tiles.append([group, name.to_lower(), sq])


func _lum(c: Color) -> float:
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b


## The square around the light: rows and columns are trimmed until 0.5% of the total
## luminance is cut from each side, then the box is squared about its centre with a 12% margin. Off
## the edge of the frame is padded black, which is what the void is anyway.
func _crop_light(img: Image) -> Image:
	var w := img.get_width()
	var h := img.get_height()
	var cols := PackedFloat32Array()
	cols.resize(w)
	var rows := PackedFloat32Array()
	rows.resize(h)
	var total := 0.0
	for y in range(0, h, 2):
		for x in range(0, w, 2):
			var l := _lum(img.get_pixel(x, y))
			if l < 0.02:
				continue
			cols[x] += l
			rows[y] += l
			total += l
	if total <= 0.0:
		return _centre_square(img)
	var x0 := _cut(cols, total * 0.005, false)
	var x1 := _cut(cols, total * 0.005, true)
	var y0 := _cut(rows, total * 0.005, false)
	var y1 := _cut(rows, total * 0.005, true)
	var side := int(maxf(x1 - x0, y1 - y0) * 1.12) + 4
	var cx := (x0 + x1) / 2
	var cy := (y0 + y1) / 2
	var out := Image.create(side, side, false, Image.FORMAT_RGB8)
	out.fill(Color.BLACK)
	var src := Rect2i(cx - side / 2, cy - side / 2, side, side)
	var clip := src.intersection(Rect2i(0, 0, w, h))
	out.blit_rect(img, clip, clip.position - src.position)
	return out


func _cut(a: PackedFloat32Array, budget: float, from_end: bool) -> int:
	var acc := 0.0
	var n := a.size()
	for k in n:
		var i := n - 1 - k if from_end else k
		acc += a[i]
		if acc > budget:
			return i
	return n - 1 if not from_end else 0


func _centre_square(img: Image) -> Image:
	var s := mini(img.get_width(), img.get_height())
	return img.get_region(Rect2i((img.get_width() - s) / 2, (img.get_height() - s) / 2, s, s))


func _lit_fraction(img: Image) -> float:
	var lit := 0
	var n := 0
	for y in range(0, img.get_height(), 2):
		for x in range(0, img.get_width(), 2):
			n += 1
			if _lum(img.get_pixel(x, y)) > 0.06:
				lit += 1
	return float(lit) / float(maxi(1, n))


func _write_atlas() -> bool:
	var rows := ceili(float(_tiles.size()) / float(COLS))
	var atlas := Image.create(COLS * TILE, rows * TILE, false, Image.FORMAT_RGB8)
	atlas.fill(Color.BLACK)
	var groups := {}
	for k in _tiles.size():
		var t: Array = _tiles[k]
		var at := Vector2i((k % COLS) * TILE, (k / COLS) * TILE)
		atlas.blit_rect(t[2], Rect2i(0, 0, TILE, TILE), at)
		if not groups.has(t[0]):
			groups[t[0]] = {}
		groups[t[0]][t[1]] = [at.x, at.y, TILE, TILE]
	var err := atlas.save_png(OUT_PNG)
	var f := FileAccess.open(OUT_JSON, FileAccess.WRITE)
	if f == null or err != OK:
		print("THUMBBAKE FAIL: could not write the atlas (%d)" % err)
		return false
	f.store_string(JSON.stringify({"tile": TILE, "cols": COLS,
		"source": "godot/tools/thumb_bake.sh, the real main scene, mobile renderer",
		"groups": groups}, "\t", false) + "\n")
	f.close()
	var counts := []
	for g in groups:
		counts.append("%s=%d" % [g, groups[g].size()])
	print("THUMBBAKE atlas %dx%d %s" % [atlas.get_width(), atlas.get_height(), " ".join(counts)])
	return true
