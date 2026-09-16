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
	_place(case.get("view", "outside"))
	for i in 4:
		await process_frame
	var img := root.get_viewport().get_texture().get_image()
	var err := img.save_png("%s/%s.png" % [OUT, name])
	var lit := _lit(img)
	_ink[name] = float(lit)
	if case.get("keep", false):
		_keep[name] = img
	var ok: bool = err == OK and lit > 500
	if not ok:
		_fails += 1
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


func _defaults() -> void:
	_ifs.set_preset(0)
	_ifs.plane1_normal = FractalIFS.DEFAULT_N1
	_ifs.plane2_normal = FractalIFS.DEFAULT_N2
	_ifs.plane1_offset = 0.0
	_ifs.plane2_offset = 0.0
	_ifs.depth = 1.0
	_ifs.detail = 3
