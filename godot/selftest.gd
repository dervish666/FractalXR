extends SceneTree

## Headless-ish check on the simulation, run before every deploy.
##
## Steps the active FractalSource on this machine's GPU, reads the particle state
## image back, and fails if the cloud is dead, unbounded or NaN-ridden. It cannot
## tell you whether the thing looks good, only whether the maths is alive.
##
##   tools/selftest.sh
##
## Needs a window: a true --headless run gets the Compatibility renderer, which has
## no RenderingDevice at all.

const TEX_SIZE := 1536
const COUNT := 707788      # floor(0.3 * 1536^2), the web build's default draw count
const FRAMES := 90


func _init() -> void:
	var lib := PresetLibrary.new()
	if not lib.load_all():
		_done(false, "presets: %s" % lib.load_error)
		return

	var rd := RenderingServer.get_rendering_device()
	if rd == null:
		_done(false, "no RenderingDevice (Compatibility renderer?)")
		return

	var cloud := ParticleCloud.new()
	if not cloud.setup(TEX_SIZE):
		_done(false, cloud.get_error())
		return
	cloud.set_count(COUNT)

	var failures: Array[String] = []
	# Every preset gets stepped: a bad genome shows up as NaN or an escaping cloud,
	# and that is exactly the kind of thing a hand-transcribed preset table gets wrong.
	for i in lib.count():
		var src := FlameSource.new(lib.at(i))
		if not cloud.set_source(src):
			failures.append("%s: %s" % [lib.name_at(i), cloud.get_error()])
			continue
		for _f in FRAMES:
			cloud.iterate()
		var msg := _check(rd, cloud, lib.name_at(i))
		if msg != "":
			failures.append(msg)

	cloud.cleanup()
	_done(failures.is_empty(), "; ".join(failures))


## Sample the state image and sanity-check the particle distribution.
func _check(rd: RenderingDevice, cloud: ParticleCloud, name: String) -> String:
	var data := rd.texture_get_data(cloud.state_texture_rid(), 0)
	if data.size() < TEX_SIZE * TEX_SIZE * 16:
		return "%s: short readback" % name

	var nan_count := 0
	var far_count := 0
	var n := 0
	var lo := Vector3(1e9, 1e9, 1e9)
	var hi := Vector3(-1e9, -1e9, -1e9)
	# Stride the sample: a full 2.36M-texel walk in GDScript takes minutes.
	var step := 977   # coprime with the row length, so it does not sample one column
	var i := 0
	while i < COUNT:
		var o := i * 16
		var p := Vector3(data.decode_float(o), data.decode_float(o + 4), data.decode_float(o + 8))
		if is_nan(p.x) or is_nan(p.y) or is_nan(p.z):
			nan_count += 1
		elif p.length() > 6.0:
			far_count += 1
		else:
			lo = lo.min(p)
			hi = hi.max(p)
		n += 1
		i += step

	var extent := hi - lo
	if nan_count > n / 100:
		return "%s: %d/%d NaN" % [name, nan_count, n]
	if far_count > n / 10:
		return "%s: %d/%d escaped past r=6" % [name, far_count, n]
	if extent.length() < 0.05:
		return "%s: collapsed to a point (extent %.3f)" % [name, extent.length()]
	# A 3D genome needs a z-injector; without one the flame is a flat sheet.
	if extent.z < 0.02:
		return "%s: flat in z (%.4f) — missing a z-injector?" % [name, extent.z]
	print("  %-10s extent %.2f x %.2f x %.2f   nan=%d far=%d of %d" % [
		name, extent.x, extent.y, extent.z, nan_count, far_count, n])
	return ""


func _done(ok: bool, msg: String) -> void:
	if msg != "":
		print("SELFTEST detail: %s" % msg)
	print("SELFTEST %s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)
