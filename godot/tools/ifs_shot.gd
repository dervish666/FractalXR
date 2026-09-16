extends SceneTree

## Standalone captures of FractalIFS: no main scene, no XR, one fixed camera and one fixed
## construction scale, so the frames differ only by the parameter under test. Enough of the
## parameter space to answer the IFS-1 question, which is whether the default rule reads as a
## sculpture or as boxes stuffed into corners, plus an outside and an inside view of every
## preset in the gallery at the rung that preset opens at.
##
## The camera is the same for every preset on purpose. A per-preset framing would flatter each
## one in turn and make the set impossible to compare.
##
## The ambient work added in IFS-4 is captured here too: the palette drift at three clock
## values, the grow-in part way through, and a morph stopped at its midpoint. Every one of
## them is driven by handing FractalIFS.tick the delta this file chooses, never by waiting
## on the wall clock, so a capture is the same picture on a fast machine and a slow one.
##
##   tools/ifs_shot.sh

const OUT := "res://.spike-out/ifs-2026-09-16"
const CAM_OUT := Vector3(3.4, 2.5, 4.3)
const CAM_FOV := 50.0
const CENTRE_FOV := 90.0
const BG := Color(0.035, 0.04, 0.055)
## A fixed five-stop ramp so palette changes are visible and every capture is comparable.
const PALETTE := [Color(0.95, 0.93, 0.80), Color(0.95, 0.66, 0.32), Color(0.85, 0.30, 0.38),
	Color(0.36, 0.34, 0.72), Color(0.16, 0.52, 0.66)]

var _cam: Camera3D
var _ifs: FractalIFS
var _ink: Dictionary = {}
var _keep: Dictionary = {}
var _box: Dictionary = {}
var _fails := 0


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = BG
	env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	var we := WorldEnvironment.new()
	we.environment = env
	root.add_child(we)

	_cam = Camera3D.new()
	_cam.near = 0.01
	_cam.far = 100.0
	_cam.current = true
	root.add_child(_cam)

	_ifs = FractalIFS.new()
	_ifs.visible = true
	root.add_child(_ifs)
	# The first frames after a scene is built render into an unsettled target. Without this
	# the opening capture came back at a third of the ink of an identical later one.
	for i in 20:
		await process_frame

	for case in _cases():
		await _shoot(case)

	# Identical parameters must give an identical capture, or the frame budget per case is
	# too small and every number above is describing a half-drawn target.
	var settled: bool = _ink.get("default", -1.0) == _ink.get("detail-3", -2.0)
	if not settled:
		_fails += 1
	print("IFSSHOT %s settle: default lit=%d detail-3 lit=%d (same parameters)" % [
		"PASS" if settled else "FAIL", int(_ink.get("default", 0.0)), int(_ink.get("detail-3", 0.0))])

	# Does cull_mode = CULL_DISABLED actually change anything? Pixel counts alone cannot
	# answer that: a zero from a probe that never moves is not a measurement. The palette
	# probe is the control, an edit through the same material that must change the image.
	var cull_diff := _diff("cull-disabled-d2", "cull-back-d2")
	var ctl_diff := _diff("cull-disabled-d2", "palette-probe-d2")
	var live: bool = ctl_diff > 0.02
	if not live:
		_fails += 1
	print("IFSSHOT %s cull: disabled vs back mean pixel diff=%.5f, palette control diff=%.5f" % [
		"PASS" if live else "FAIL", cull_diff, ctl_diff])
	# The palette drifts and the shape does not. Both halves matter: a diff on its own could
	# be geometry moving, and an unchanged ink count on its own could be nothing happening.
	var d20 := _diff("colour-t00", "colour-t20")
	var d40 := _diff("colour-t00", "colour-t40")
	var i0: float = _ink.get("colour-t00", 0.0)
	var i20: float = _ink.get("colour-t20", 0.0)
	var i40: float = _ink.get("colour-t40", 0.0)
	var still: bool = i0 > 0.0 and absf(i20 - i0) < i0 * 0.15 and absf(i40 - i0) < i0 * 0.15
	# All three pairs, not just each against the first. Two captures can both differ from t0
	# by the same amount and still be the same picture as each other, which would mean the
	# drift had stalled rather than carried on.
	var d2040 := _diff("colour-t20", "colour-t40")
	var drift: bool = d20 > 0.01 and d40 > 0.01 and d2040 > 0.01
	if not (still and drift):
		_fails += 1
	print("IFSSHOT %s colour: diff t0-t20=%.5f t0-t40=%.5f t20-t40=%.5f, lit %d/%d/%d (shape held=%s)" % [
		"PASS" if still and drift else "FAIL", d20, d40, d2040, int(i0), int(i20), int(i40),
		str(still)])

	# The grow-in goes one way: less drawn early, more later, most when it is over.
	var g10: float = _ink.get("grow-010", -1.0)
	var g60: float = _ink.get("grow-060", -1.0)
	var gfull: float = _ink.get("default", -1.0)
	var rising: bool = g10 > 0.0 and g10 < g60 and g60 < gfull
	if not rising:
		_fails += 1
	print("IFSSHOT %s grow: lit at 0.1 s=%d, 0.6 s=%d, finished=%d" % [
		"PASS" if rising else "FAIL", int(g10), int(g60), int(gfull)])

	var mid: float = _box.get("grow-d1-mid", -1.0)
	var whole: float = _box.get("grow-d1-full", -1.0)
	var gathered: bool = whole > 0.0 and mid > 0.0 and mid < whole * 0.75
	if not gathered:
		_fails += 1
	print("IFSSHOT %s grow origin: lit box part way=%.4f of frame, finished=%.4f, ratio=%.3f" % [
		"PASS" if gathered else "FAIL", mid, whole, mid / maxf(whole, 1e-6)])

	print("IFSSHOT %s failures=%d dir=%s" % ["PASS" if _fails == 0 else "FAIL", _fails, OUT])
	quit(0 if _fails == 0 else 1)


## Mean absolute channel difference between two kept captures, 0 for identical images.
func _diff(a: String, b: String) -> float:
	var ia: Image = _keep.get(a)
	var ib: Image = _keep.get(b)
	if ia == null or ib == null:
		return -1.0
	var total := 0.0
	var n := 0
	for y in range(0, ia.get_height(), 2):
		for x in range(0, ia.get_width(), 2):
			var ca := ia.get_pixel(x, y)
			var cb := ib.get_pixel(x, y)
			total += absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)
			n += 3
	return total / float(maxi(n, 1))


func _shoot(case: Dictionary) -> void:
	var name: String = case["name"]
	_defaults()
	if case.has("preset"):
		# The preset brings its own rung with it, the way a preset change does in the app.
		_ifs.set_preset(int(case["preset"]))
		_ifs.detail = _ifs.preset_detail()
	for k in case.get("params", {}):
		_ifs.set(k, case["params"][k])
	_ifs.set_cull_disabled(case.get("cull", true))
	# Three builds: the first pays for allocation growth, so quoting it alone would be
	# pessimistic and quoting only the best would be a press release.
	var ms: Array[float] = []
	for i in 3:
		_ifs.build()
		ms.append(_ifs.build_ms)
	_ifs.set_palette(case.get("palette", PALETTE))
	if case.has("morph"):
		var m: Array = case["morph"]
		_ifs.set_preset(int(m[0]))
		_ifs.build(false)
		_ifs.begin_morph(int(m[1]))
		_ifs.tick(FractalIFS.MORPH_S * float(m[2]))
	# Four rendered frames is not 0.6 s, so every capture that is not about the grow-in skips
	# to the end of it rather than coming back a third built.
	if case.has("grow"):
		_ifs.tick(float(case["grow"]))
	else:
		_ifs.finish_grow()
		_ifs.anim_t = float(case.get("time", 0.0))
		_ifs.tick(0.0)
	_place(case.get("view", "outside"))
	for i in 4:
		await process_frame
	var img := root.get_viewport().get_texture().get_image()
	var err := img.save_png("%s/%s.png" % [OUT, name])
	var lit := _lit(img)
	_ink[name] = float(lit)
	if case.get("keep", false):
		_keep[name] = img
	# A part-grown frame is meant to be small, so those cases carry their own floor and the
	# assertion that matters for them is the ordering below, not a pixel count.
	var ok: bool = err == OK and lit > int(case.get("floor", 500))
	if not ok:
		_fails += 1
	_box[name] = _bbox_area(img)
	print("IFSSHOT %-22s %s shape=%-6s detail=%d instances=%-5d triangles=%-7d build=%.2f..%.2fms lit=%d %s" % [
		name, "PASS" if ok else "FAIL", FractalIFS.preset_name(_ifs.preset), _ifs.detail,
		_ifs.instance_count, _ifs.triangle_count, ms.min(), ms.max(), lit, _ifs.cap_note])


func _place(view: String) -> void:
	if view == "centre":
		_cam.fov = CENTRE_FOV
		_cam.position = Vector3.ZERO
		# Look into a corner: the default rule puts its opening on the body diagonal.
		_cam.look_at(Vector3(1.0, 1.0, 1.0), Vector3.UP)
	else:
		_cam.fov = CAM_FOV
		_cam.position = CAM_OUT
		_cam.look_at(Vector3.ZERO, Vector3.UP)


## Lit pixels against the flat background. A PNG that saved is not a PNG that drew anything.
func _lit(img: Image) -> int:
	var n := 0
	var step := 2
	for y in range(0, img.get_height(), step):
		for x in range(0, img.get_width(), step):
			var c := img.get_pixel(x, y)
			if maxf(c.r, maxf(c.g, c.b)) > 0.12:
				n += 1
	return n


func _cases() -> Array:
	var rot30 := Vector3(1, 0, 0).rotated(Vector3(0, 0, 1), deg_to_rad(30.0))
	var out: Array = [
		{"name": "default"},
		{"name": "default-centre", "view": "centre"},
		{"name": "depth-min", "params": {"depth": FractalIFS.DEPTH_MIN}},
		{"name": "depth-max", "params": {"depth": FractalIFS.DEPTH_MAX}},
		{"name": "plane1-offset", "params": {"plane1_offset": 0.3}},
		{"name": "plane1-offset-centre", "params": {"plane1_offset": 0.3}, "view": "centre"},
		{"name": "plane1-rot30", "params": {"plane1_normal": rot30}},
		{"name": "detail-1", "params": {"detail": 1}},
		{"name": "detail-2", "params": {"detail": 2}},
		{"name": "detail-3", "params": {"detail": 3}},
		{"name": "detail-4", "params": {"detail": 4}},
		# Alternatives for the readability call, kept from IFS-1: these are the rules FRAMES was
		# chosen over. Written as `base` overrides now that the rule lives in the preset table,
		# so a harness can still try a rule that never made it into the gallery.
		{"name": "alt-c045-o050", "params": {"base": _corners(0.45, 0.5)}},
		{"name": "alt-c045-o050-centre", "params": {"base": _corners(0.45, 0.5)}, "view": "centre"},
		{"name": "alt-c033-o066", "params": {"base": _corners(0.33, 0.66)}},
		{"name": "alt-c033-o066-centre", "params": {"base": _corners(0.33, 0.66)}, "view": "centre"},
		{"name": "alt-c050-o045", "params": {"base": _corners(0.5, 0.45)}},
		# Culling pair at the rung where a missing frame is still countable by eye, plus a
		# recolour through the same material to prove the comparison can see a change at all.
		{"name": "cull-disabled-d2", "params": {"detail": 2}, "keep": true},
		{"name": "cull-back-d2", "params": {"detail": 2}, "cull": false, "keep": true},
		{"name": "palette-probe-d2", "params": {"detail": 2}, "keep": true,
			"palette": [Color(0.06, 0.06, 0.09)]},
		# The palette drift, three clock values apart. Same geometry every time, so anything
		# that changes between these three is the ramp scrolling and nothing else.
		{"name": "colour-t00", "time": 0.0, "keep": true},
		{"name": "colour-t20", "time": 20.0, "keep": true},
		{"name": "colour-t40", "time": 40.0, "keep": true},
		# The grow-in part way through. Small on purpose, hence the floor.
		{"name": "grow-010", "grow": 0.1, "floor": 1},
		{"name": "grow-060", "grow": 0.6, "floor": 1},
		# Does a generation really scale up out of its PARENT'S origin, or merely out of its
		# own centre? At detail 1 the eight children all have the root for a parent, so part
		# way through they are gathered at the middle and the lit area is far smaller than the
		# finished shape's. Growing in place, or from a mis-read origin, would not shrink it.
		{"name": "grow-d1-mid", "params": {"detail": 1}, "grow": 0.37, "floor": 1},
		{"name": "grow-d1-full", "params": {"detail": 1}},
		# A morph stopped at its midpoint, where the seed frame has just changed under it.
		{"name": "morph-frames-tetra", "morph": [0, 1, 0.5]},
	]
	# The gallery, outside and from the middle, each at the rung its own entry opens at. FRAMES
	# is in here as well as being "default" above: the same rule captured through the preset
	# path is what proves the preset path produces it.
	for i in FractalIFS.PRESETS.size():
		var slug := FractalIFS.preset_name(i).to_lower()
		out.append({"name": "preset-%s" % slug, "preset": i})
		out.append({"name": "preset-%s-centre" % slug, "preset": i, "view": "centre"})
	return out


## A corner-pair base map list, the shape every alternative from IFS-1 had: contract by c and
## push into the eight corners at +-o.
static func _corners(c: float, o: float) -> Array:
	return [[c, Vector3(o, o, o)], [c, Vector3(o, o, -o)]]


## The area of the lit pixels' bounding box, as a fraction of the frame. Where the ink count
## says how much is drawn, this says how far out it reaches.
func _bbox_area(img: Image) -> float:
	var x0 := img.get_width()
	var y0 := img.get_height()
	var x1 := -1
	var y1 := -1
	for y in range(0, img.get_height(), 2):
		for x in range(0, img.get_width(), 2):
			var c := img.get_pixel(x, y)
			if maxf(c.r, maxf(c.g, c.b)) > 0.12:
				x0 = mini(x0, x); y0 = mini(y0, y)
				x1 = maxi(x1, x); y1 = maxi(y1, y)
	if x1 < x0 or y1 < y0:
		return 0.0
	return float((x1 - x0 + 1) * (y1 - y0 + 1)) / float(img.get_width() * img.get_height())


func _defaults() -> void:
	_ifs.set_preset(0)
	# One clock for every case, or the palette drift would make two captures of the same
	# parameters differ and the settle check would be measuring the clock instead.
	_ifs.ambient = false
	_ifs.anim_t = 0.0
	_ifs.plane1_normal = FractalIFS.DEFAULT_N1
	_ifs.plane2_normal = FractalIFS.DEFAULT_N2
	_ifs.plane1_offset = 0.0
	_ifs.plane2_offset = 0.0
	_ifs.depth = 1.0
	_ifs.detail = 3
