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
		for f in FRAMES:
			cloud.iterate()
			if f % 30 == 29:
				await process_frame
		var msg := _check(rd, cloud, lib.name_at(i))
		if msg != "":
			failures.append(msg)

	# The bake is three new compute shaders and a prefix sum, which is exactly the shape
	# of thing that silently writes zeros. A visual check cannot tell "no anisotropy"
	# from "the scan is off by a block", so check the numbers here.
	# Readbacks are asynchronous now, so the bake section yields real frames for the
	# RenderingDevice to deliver them; the flame checks above read the state image
	# directly and need none.
	var bake_msg: String = await _check_bake(rd, cloud, lib)
	if bake_msg != "":
		failures.append(bake_msg)

	cloud.cleanup()

	# The ground viewer: its compute fill and clipmap bookkeeping, checked against two
	# points whose fate is not in doubt.
	var ground_msg: String = await _check_ground(rd)
	if ground_msg != "":
		failures.append(ground_msg)

	_done(failures.is_empty(), "; ".join(failures))


## Bake one bulb and read the result back. Passes only if the splats have real, VARYING
## axes: a bake that produces one size everywhere is the bug it exists to prevent.
func _check_bake(rd: RenderingDevice, cloud: ParticleCloud, lib: PresetLibrary) -> String:
	if lib.bulbs.is_empty():
		return "no bulbs to bake"
	var name := str(lib.bulbs[0].get("name", "?"))
	var src := BulbSource.new(lib.bulbs[0])
	if not cloud.set_source(src):
		return "bake %s: %s" % [name, cloud.get_error()]
	cloud.set_splat(true, 0.02)
	# Yield now and then. Ninety bulb steps of 707k particles plus a sort per step in ONE
	# frame sat at the Mac driver's fence timeout, and past it no async readback ever
	# arrives ("timeout waiting for fence", then "measurement never landed").
	for f in FRAMES:
		cloud.iterate()
		if f % 10 == 9:
			await process_frame
	# The bake bins against the measured framing, so wait for the measurement to land.
	var gen := cloud.measure_generation
	cloud.request_measure()
	var waited := 0
	while cloud.measure_generation == gen and waited < 60:
		cloud.iterate()
		await process_frame
		waited += 1
	if cloud.measure_generation == gen:
		return "bake %s: measurement never landed in %d frames" % [name, waited]
	print("  measure landed after %d frames: fit %.2f" % [waited, cloud.target_fit])
	cloud.bake()
	var guard := 0
	while cloud.is_baking() and guard < 400:
		cloud.iterate()
		await process_frame
		guard += 1
	if cloud.is_baking():
		return "bake %s: did not finish in %d frames" % [name, guard]
	if not cloud.bake_ready:
		return "bake %s: produced no usable sizes" % name

	# The depth sort ran on every one of those frames. Its output has to be a permutation
	# of 0..count-1: a hole means a splat drawn twice and another never, which no picture
	# would reveal as anything but "a bit noisy".
	var perm_msg := _check_perm(rd, cloud)
	if perm_msg != "":
		return perm_msg

	var data := rd.texture_get_data(cloud.bake_texture_rid(), 0)
	var stride := 8    # RGBA16F
	var n := 0
	var zero := 0
	var sum := 0.0
	var sum2 := 0.0
	var aniso := 0.0
	var i := 0
	while i < COUNT:
		var o := i * stride
		var s0 := _half(data.decode_u16(o + 4))
		var s1 := _half(data.decode_u16(o + 6))
		if is_nan(s0) or s0 <= 0.0:
			zero += 1
		else:
			sum += s0
			sum2 += s0 * s0
			aniso += s1 / s0
		n += 1
		i += 977
	if n == 0:
		return "bake %s: no samples" % name
	if zero > n / 20:
		return "bake %s: %d/%d splats have no size" % [name, zero, n]
	var live := n - zero
	var mean := sum / float(live)
	var sd := sqrt(maxf(0.0, sum2 / float(live) - mean * mean))
	# The whole point is that sizes DIFFER. A uniform bake is the failure mode that made
	# 147k identical discs read as a foam ball.
	if sd < mean * 0.10:
		return "bake %s: sizes uniform (mean %.5f, sd %.5f)" % [name, mean, sd]
	# And that they have a SHAPE. A mean minor/major of 1.0 means every splat came out
	# circular, which is what happens when the neighbour search finds nothing and each
	# one silently falls back to an isotropic guess.
	var ratio := aniso / float(live)
	if ratio > 0.95:
		return "bake %s: splats circular (minor/major %.2f) — neighbour search found nothing" % [
			name, ratio]
	print("  bake %-10s mean %.5f  sd %.5f (%.0f%%)  minor/major %.2f  empty %d/%d" % [
		name, mean, sd, sd / mean * 100.0, ratio, zero, n])
	return ""


func _check_ground(rd: RenderingDevice) -> String:
	var g := FractalGround.new()
	if not g.setup():
		return "ground: %s" % g.get_error()
	g.centre = Vector2(0.0, 0.0)
	var frames := 0
	while frames < 120:
		g.update(Vector2.ZERO)
		await process_frame
		frames += 1
		if frames > 2 and g.pending_texels() == 0:
			break
	if g.pending_texels() > 0:
		return "ground: %d texels still pending after %d frames" % [g.pending_texels(), frames]
	# Level 0 layer: texel containing the origin (inside the set) and one at (1.5, 1.5)
	# (escapes on the second iteration).
	var t0: float = g._texel0()
	var layer: int = (0 + g._rot) % FractalGround.LEVELS
	var data := rd.texture_get_data(g._tex, layer)
	var n := FractalGround.N
	if data.size() < n * n * 16:
		return "ground: short readback"
	var inside := _ground_texel(data, n, Vector2(0.0, 0.0), t0)
	var outside := _ground_texel(data, n, Vector2(0.001, 0.001), t0)
	if inside.z < 0.5:
		return "ground: origin not inside the set (flag %.2f, iter %.1f)" % [inside.z, inside.x]
	# Level 0 spans only ~1.5m of the ~90m set at stage 0, so a far-outside point is not in
	# its window; check the coarsest level for (1.5, 1.5) instead.
	var tl: float = g._texel(FractalGround.LEVELS - 1)
	var ll: int = (FractalGround.LEVELS - 1 + g._rot) % FractalGround.LEVELS
	var far := _ground_texel(rd.texture_get_data(g._tex, ll), n, Vector2(1.5, 1.5), tl)
	if far.z > 0.5 or far.x > 6.0:
		return "ground: (1.5,1.5) should escape fast (flag %.2f, iter %.1f)" % [far.z, far.x]
	print("  ground: filled in %d frames; origin inside, (1.5,1.5) escapes at %.1f; budget %d" % [
		frames, far.x, int(g._budget)])
	g.cleanup()
	return ""


func _ground_texel(data: PackedByteArray, n: int, c: Vector2, texel: float) -> Vector4:
	var ax := int(floor(c.x / texel))
	var ay := int(floor(c.y / texel))
	var sx := ((ax % n) + n) % n
	var sy := ((ay % n) + n) % n
	var o := (sy * n + sx) * 16
	return Vector4(data.decode_float(o), data.decode_float(o + 4),
		data.decode_float(o + 8), data.decode_float(o + 12))


func _check_perm(rd: RenderingDevice, cloud: ParticleCloud) -> String:
	var data := rd.texture_get_data(cloud.perm_texture_rid(), 0)
	if data.size() < COUNT * 4:
		return "sort: short readback (%d bytes)" % data.size()
	var seen := PackedByteArray()
	seen.resize(COUNT)
	var dup := 0
	var range_bad := 0
	for i in COUNT:
		var v := int(data.decode_float(i * 4) + 0.5)
		if v < 0 or v >= COUNT:
			range_bad += 1
		elif seen[v] != 0:
			dup += 1
		else:
			seen[v] = 1
	if range_bad > 0 or dup > 0:
		return "sort: not a permutation (%d out of range, %d duplicates of %d)" % [range_bad, dup, COUNT]
	print("  sort: permutation of %d complete" % COUNT)
	return ""


## Half-float decode. GDScript reads the raw 16 bits; there is no decode_half.
func _half(bits: int) -> float:
	var sign := 1.0 if (bits & 0x8000) == 0 else -1.0
	var exp := (bits >> 10) & 0x1F
	var man := bits & 0x3FF
	if exp == 0:
		return sign * float(man) * pow(2.0, -24)
	if exp == 31:
		return NAN if man != 0 else sign * INF
	return sign * (1.0 + float(man) / 1024.0) * pow(2.0, float(exp) - 15.0)


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
