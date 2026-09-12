extends SceneTree

## Cross-checks BulbSource's CPU distance estimates against the march shader's own
## code. The shader's DE section is cut out of march.gdshader verbatim and compiled as
## a canvas shader that writes de(p) for 64 points into a 64x1 viewport, 24 bits per
## value; the CPU side evaluates the same points and the difference is reported per
## formula. A control with a deliberately wrong parameter must FAIL, and pixel 63
## carries a known constant so the encoding is proven before any comparison counts.
## Then find_hollow() is checked on the two Mandelbox presets: the clearance it finds
## must beat the origin's, or ENTER would stand you in a wall.
##
##   tools/de_check.sh

const N := 64
const TOL := 2e-3
const CONTROL_VALUE := 3.25

var _lib := PresetLibrary.new()
var _vp: SubViewport
var _rect: ColorRect
var _mat: ShaderMaterial


func _init() -> void:
	if not _lib.load_all():
		print("DECHECK FAIL presets: %s" % _lib.load_error)
		quit(1)
		return
	var src := FileAccess.get_file_as_string("res://shaders/march.gdshader")
	var u0 := src.find("uniform float power")
	var u1 := src.find("varying mat4")
	var d0 := src.find("// --- distance estimators")
	var d1 := src.find("vec3 deGrad")
	if u0 < 0 or u1 < 0 or d0 < 0 or d1 < 0:
		print("DECHECK FAIL could not cut the DE section out of march.gdshader")
		quit(1)
		return
	var code := "shader_type canvas_item;\n" + src.substr(u0, u1 - u0) + "\n" \
		+ src.substr(d0, d1 - d0) + """
uniform vec3 pts[64];
void fragment() {
	int i = int(UV.x * 64.0);
	float d = (i == 63) ? %f : de(pts[i], 0.0).x;
	float v = clamp((d + 1.0) / 16.0, 0.0, 1.0);
	vec3 enc = fract(v * vec3(1.0, 255.0, 65025.0));
	enc -= enc.yzz * vec3(1.0 / 255.0, 1.0 / 255.0, 0.0);
	COLOR = vec4(enc, 1.0);
}
""" % CONTROL_VALUE
	var sh := Shader.new()
	sh.code = code
	_mat = ShaderMaterial.new()
	_mat.shader = sh
	_vp = SubViewport.new()
	_vp.size = Vector2i(N, 1)
	_vp.disable_3d = true
	_vp.transparent_bg = false
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_rect = ColorRect.new()
	_rect.size = Vector2(N, 1)
	_rect.material = _mat
	_vp.add_child(_rect)
	root.add_child(_vp)

	# One preset per formula, the first of each.
	var by_formula := {}
	for b in _lib.bulbs:
		var f: String = str(b.get("formula", "mandelbulb"))
		if not by_formula.has(f):
			by_formula[f] = b
	var max_err := 0.0
	var formulas := 0
	var control_fail := false
	var enc_ok := true
	for f in by_formula:
		var b: Dictionary = by_formula[f]
		var srcb := BulbSource.new(b)
		srcb.clock = 1.3   # mid-breath, so breath terms are exercised
		var mp := srcb.march_params()
		for k in mp:
			_mat.set_shader_parameter(k, mp[k])
		var pts := _points(srcb.bound(), f.hash())
		_mat.set_shader_parameter("pts", pts)
		await process_frame
		await process_frame
		var img := _vp.get_texture().get_image()
		var err := 0.0
		var err_ctl := 0.0
		var mp_wrong := mp.duplicate()
		mp_wrong["scale"] = float(mp["scale"]) * 1.05
		mp_wrong["power"] = float(mp["power"]) + 0.3
		mp_wrong["julia_c"] = (mp["julia_c"] as Vector3) + Vector3(0.05, 0.0, 0.0)
		for i in N - 1:
			var gpu := _decode(img.get_pixel(i, 0))
			var cpu := srcb.de_with(pts[i], mp)
			var wrong := srcb.de_with(pts[i], mp_wrong)
			# Compare in the encoded domain: values are clamped to [-1, 15] there.
			var c1 := clampf(cpu, -1.0, 15.0)
			var w1 := clampf(wrong, -1.0, 15.0)
			err = maxf(err, absf(gpu - c1))
			err_ctl = maxf(err_ctl, absf(gpu - w1))
		var enc := _decode(img.get_pixel(N - 1, 0))
		if absf(enc - CONTROL_VALUE) > 1e-4:
			enc_ok = false
			print("DECHECK encoding broken: pixel 63 decoded %.6f, wanted %.2f" % [enc, CONTROL_VALUE])
		print("  %-11s bound=%.2f max_err=%.6f control_err=%.6f" % [f, srcb.bound(), err, err_ctl])
		max_err = maxf(max_err, err)
		if err_ctl > TOL:
			control_fail = true
		formulas += 1
	var ok := enc_ok and formulas == 5 and max_err <= TOL and control_fail
	print("DECHECK %s formulas=%d max_err=%.6f control=%s" % [
		"PASS" if ok else "FAIL", formulas, max_err, "FAIL" if control_fail else "PASS"])

	# Rooms: data/rooms.json must cover every bulb, and for each box preset the
	# runtime find_hollow() (seeded from the record, refined for the breath) must keep
	# at least 60% of the recorded clearance and beat the origin.
	var hollow_ok := true
	var rooms_f := FileAccess.open("res://data/rooms.json", FileAccess.READ)
	var rooms: Dictionary = {}
	if rooms_f != null:
		var parsed = JSON.parse_string(rooms_f.get_as_text())
		if typeof(parsed) == TYPE_DICTIONARY:
			rooms = parsed
	var covered := 0
	for b in _lib.bulbs:
		if rooms.has(str(b.get("name"))):
			covered += 1
	print("  rooms.json covers %d of %d bulbs" % [covered, _lib.bulbs.size()])
	hollow_ok = covered == _lib.bulbs.size()
	for b in _lib.bulbs:
		if str(b.get("formula", "")) != "mandelbox":
			continue
		var srcb := BulbSource.new(b)
		var origin_d := srcb.de(Vector3.ZERO)
		var p := srcb.find_hollow()
		var d := srcb.de(p)
		var rec: Dictionary = rooms.get(str(b.get("name")), {})
		var stored := float(rec.get("clearance", 0.0))
		var pass_one := d > origin_d and d >= 0.6 * stored and stored > 0.0
		hollow_ok = hollow_ok and pass_one
		print("  hollow %s origin=%.4f found=%.4f stored=%.4f enclosed=%.2f march_bound=%.2f at %s %s" % [
			str(b.get("name")), origin_d, d, stored, float(rec.get("enclosed", 0.0)),
			srcb.march_bound(), str(p), "ok" if pass_one else "NO"])
	print("HOLLOW %s" % ("PASS" if hollow_ok else "FAIL"))
	quit(0 if ok and hollow_ok else 1)


func _points(bound: float, seed: int) -> PackedVector3Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var pts := PackedVector3Array()
	pts.resize(N)
	for i in N:
		# A spread of radii, including some well inside and a few near the surface.
		var r := bound * 0.95 * pow(rng.randf(), 0.6)
		var dir := Vector3(rng.randfn(), rng.randfn(), rng.randfn()).normalized()
		pts[i] = dir * r
	pts[0] = Vector3(1e-3, 5e-4, 0.0)   # near the origin; the exact origin is 0/0 for quat
	return pts


func _decode(c: Color) -> float:
	var v := c.r + c.g / 255.0 + c.b / 65025.0
	return v * 16.0 - 1.0
