extends SceneTree

## ground.glsl against a 64-bit CPU port, read back from the GPU. The df32 path exists to
## be right where float32 is wrong, and the way it goes wrong on a bad driver (a compiler
## contracting or reassociating the Dekker arithmetic) is noise, not blocks: it would pass
## any look at a screenshot. So this compares numbers.
##
## For each escape-time family and a Julia set it walks a CPU zoom down onto the boundary
## to a deep stage, fills a 32x32 rect there through FractalGround's real push constant,
## once with each variant, and compares the stored smooth count with GDScript doubles.
## GROUNDCHECK lines: df must PASS; the f32 control at the same spot must FAIL, which is
## what proves the check can see the block collapse at all. A SWEEP line per stage shows
## where float32 gives out (DF_RATIO's evidence), and BENCH lines time 1024x1024 fills.
##
##   tools/ground_check.sh [stage]      (default 17, about 1.3e5x)
##
## No shared code with the shader, deliberately: the CPU side is written from the maths.

const N := 32
const TEX := 64
const ITER := 1024
const ESC2 := 65536.0
const LOG_ESC := 5.5451774
## How far (in texels) a patch's truth is moved to test its conditioning. df32 places a
## coordinate to about 2^-47 of its magnitude, 2e-5 of a texel at stage 17.
const JITTER := 1e-5

var rd: RenderingDevice
var shaders := {}
var pipes := {}
var tex: RID
var uset: RID
var tex_base: RID     # the pre-df32 fill writes RGBA16F, so it gets a texture of its own
var uset_base: RID
var ground: FractalGround
var _slot0 := Vector2i.ZERO    # where the last dispatch's first texel landed in the texture
var _iter := ITER               # the cap the CPU truth runs to; the fraction case raises it


func _init() -> void:
	var stage := 17
	for a in OS.get_cmdline_user_args():
		if a.is_valid_int():
			stage = int(a)
	rd = RenderingServer.create_local_rendering_device()
	if rd == null:
		print("GROUNDCHECK FAIL no local RenderingDevice (run windowed, not --headless)")
		quit(1)
		return
	var file: RDShaderFile = load("res://shaders/ground.glsl")
	for v: String in ["f32", "df"]:
		var sp := file.get_spirv(StringName(v))
		if sp == null or sp.compile_error_compute != "":
			print("GROUNDCHECK FAIL %s variant: %s" % [v, "missing" if sp == null else sp.compile_error_compute])
			quit(1)
			return
		shaders[v] = rd.shader_create_from_spirv(sp)
		pipes[v] = rd.compute_pipeline_create(shaders[v])
	# The float32-only fill as it was before df32, for the shallow comparison and the bench:
	# ground_check.sh writes it from git. Its 64-byte push constant is the first 64 bytes of
	# today's, with the absolute texel index it used to multiply out.
	var base_src := FileAccess.get_file_as_string("res://.spike-out/ground_base.glsl")
	if base_src != "":
		var src := RDShaderSource.new()
		src.source_compute = base_src.replace("#[compute]", "")
		var sp := rd.shader_compile_spirv_from_source(src)
		if sp.compile_error_compute == "":
			shaders["base"] = rd.shader_create_from_spirv(sp)
			pipes["base"] = rd.compute_pipeline_create(shaders["base"])
			var fb := FractalGround.level_format(TEX, 1)
			fb.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
			tex_base = rd.texture_create(fb, RDTextureView.new(), [])
			var ub := RDUniform.new()
			ub.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
			ub.binding = 0
			ub.add_id(tex_base)
			uset_base = rd.uniform_set_create([ub], shaders["base"], 0)
		else:
			print("GROUNDCHECK note: base shader did not compile: %s" % sp.compile_error_compute)
	tex = rd.texture_create(FractalGround.level_format(TEX, 1), RDTextureView.new(), [])
	var img := RDUniform.new()
	img.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	img.binding = 0
	img.add_id(tex)
	uset = rd.uniform_set_create([img], shaders["f32"], 0)
	ground = FractalGround.new()
	ground.n_tex = TEX
	ground.max_iter = ITER

	var ok := true
	var rng := RandomNumberGenerator.new()
	# Every family at the deep stage, then a Julia set.
	for f in FractalGround.FORMULA_NAMES.size():
		ok = _case(f, false, Vector2.ZERO, stage, rng) and ok
	ok = _case(0, true, Vector2(-0.8, 0.156), stage, rng) and ok
	# Shallow sanity: at stage 3 both variants must match the CPU. If the f32 variant
	# fails here the new origin arithmetic broke the common case.
	ok = _case(0, false, Vector2.ZERO, 3, rng, true) and ok
	ok = _fraction_case(rng) and ok
	_sweep(rng)
	_bench(rng)
	print("GROUNDCHECK %s stage=%d" % ["PASS" if ok else "FAIL", stage])
	ground.free()
	rd.free_rid(tex)
	if tex_base.is_valid():
		rd.free_rid(tex_base)
	for v: String in shaders:
		rd.free_rid(shaders[v])
	rd.free()
	quit(0 if ok else 1)


func _texel(stage: int) -> float:
	return FractalGround.TEXEL_M / FractalGround.WPU_BASE / pow(2.0, float(stage))


# --- CPU reference ------------------------------------------------------------------

## escape()'s smooth count in 64-bit floats, written from the formulas, not the shader.
static func cpu_count(f: int, cx: float, cy: float, zx: float, zy: float, iters: int) -> float:
	var m2 := zx * zx + zy * zy
	var n := 0
	var deg := 3.0 if f == 6 else (4.0 if f == 7 else 2.0)
	for i in iters:
		var nx: float
		var ny: float
		if f == 6:
			nx = zx * zx * zx - 3.0 * zx * zy * zy
			ny = 3.0 * zx * zx * zy - zy * zy * zy
		elif f == 7:
			var a := zx * zx - zy * zy
			var b := 2.0 * zx * zy
			nx = a * a - b * b
			ny = 2.0 * a * b
		else:
			var fx := zx
			var fy := zy
			if f == 1:
				fx = absf(zx)
				fy = absf(zy)
			elif f == 2:
				fy = -zy
			elif f == 4:
				fx = absf(zx)
			nx = fx * fx - fy * fy
			ny = 2.0 * fx * fy
			if f == 3:
				nx = absf(nx)
			elif f == 4:
				ny = -ny
			elif f == 5:
				nx = absf(nx)
				ny = -absf(ny)
		zx = nx + cx
		zy = ny + cy
		m2 = zx * zx + zy * zy
		n = i + 1
		if m2 > ESC2:
			break
	if m2 <= ESC2:
		return float(iters)
	var lm := log(m2) * 0.5
	return float(n) - log(lm / LOG_ESC) / log(2.0) / (log(deg) / log(2.0))


static func _cpu_at(f: int, julia: bool, jc: Vector2, x: float, y: float, iters: int) -> float:
	if julia:
		return cpu_count(f, jc.x, jc.y, x, y, iters)
	return cpu_count(f, x, y, 0.0, 0.0, iters)


## Walk a CPU zoom down onto the boundary: a grid over the window, recentre on one of the
## higher counts that still escapes well under the cap, shrink, repeat. Returns the
## fractal coordinate of the rect's first texel centre, or [] if every try ended inside.
##
## The patch also has to be well conditioned. Right on the boundary a count can depend on
## c past the 17th digit, where even the doubles are guessing: a burning ship patch whose
## truth, moved 1e-5 of a texel, agreed with itself on 12% of texels. Comparing df32 there
## tests nothing, so the finder takes the first patch that agrees with itself so moved on
## 97% of texels, or failing that the best of 24, and df is held to that patch's own bar.
func _find_spot(f: int, julia: bool, jc: Vector2, texel: float, rng: RandomNumberGenerator) -> Array:
	var why := {}
	var bestspot: Array = []
	for attempt in 24:
		var cx := -0.4 if not julia else 0.0
		var cy := 0.0
		var r := 2.0
		var iters := 128
		var dead := false
		while r > float(N) * texel:
			var best: Array = []
			var g := 9
			for j in g:
				for i in g:
					var x := cx + r * (2.0 * (float(i) + rng.randf()) / float(g) - 1.0)
					var y := cy + r * (2.0 * (float(j) + rng.randf()) / float(g) - 1.0)
					var s := _cpu_at(f, julia, jc, x, y, iters)
					if s < float(iters) * 0.4:
						best.append([s, x, y])
			if best.is_empty():
				dead = true
				break
			best.sort_custom(func(a, b): return a[0] > b[0])
			var pick: Array = best[rng.randi_range(0, mini(5, best.size() - 1))]
			cx = pick[1]
			cy = pick[2]
			r *= 0.25
			iters = mini(ITER, iters + 64)
		if dead:
			why["inside"] = why.get("inside", 0) + 1
			continue
		# On the texel grid the app uses: centres at (a + 0.5) * texel.
		var ox := (roundf((cx - float(N) * 0.5 * texel) / texel) + 0.5) * texel
		var oy := (roundf((cy - float(N) * 0.5 * texel) / texel) + 0.5) * texel
		# Keep it only if the patch has real structure: many distinct counts, mostly outside.
		var t := _truth(f, julia, jc, ox, oy, texel)
		if _distinct(t) < 40 or _inside(t) >= 0.5:
			why["flat"] = why.get("flat", 0) + 1
			continue
		var cond := _match(_truth(f, julia, jc, ox + JITTER * texel, oy, texel), t)
		if cond >= 0.97:
			return [ox, oy, t, cond]
		if bestspot.is_empty() or cond > float(bestspot[3]):
			bestspot = [ox, oy, t, cond]
	if bestspot.is_empty():
		print("  no spot: %s" % str(why))
	return bestspot


func _truth(f: int, julia: bool, jc: Vector2, ox: float, oy: float, texel: float, raw := false) -> PackedFloat32Array:
	var t := PackedFloat32Array()
	t.resize(N * N)
	for j in N:
		for i in N:
			var v := _cpu_at(f, julia, jc, ox + float(i) * texel, oy + float(j) * texel, _iter)
			t[j * N + i] = v if raw else _stored(v)
	return t


# --- GPU ----------------------------------------------------------------------------

## Fill the rect at slot (0, 0) with one variant and read the counts back.
func _gpu(variant: String, f: int, julia: bool, jc: Vector2, stage: int, ox: float, oy: float) -> PackedFloat32Array:
	_dispatch(variant, f, julia, jc, stage, ox, oy, N)
	var base := variant == "base"
	var data := rd.texture_get_data(tex_base if base else tex, 0)
	var out := PackedFloat32Array()
	out.resize(N * N)
	for j in N:
		for i in N:
			var k := posmod(_slot0.y + j, TEX) * TEX + posmod(_slot0.x + i, TEX)
			out[j * N + i] = data.decode_half(k * 8) if base else count_at(data, k)
	return out


func _dispatch(variant: String, f: int, julia: bool, jc: Vector2, stage: int, ox: float, oy: float,
		size: int) -> void:
	ground.formula = f
	ground.julia = julia
	ground.julia_c = jc
	ground._stage = stage
	ground._rot = 0
	_slot0 = Vector2i.ZERO
	if variant == "base":
		var t := ground._texel(0)
		_slot0 = Vector2i(int(round(ox / t - 0.5)), int(round(oy / t - 0.5)))
	var pc := ground.push_constant_at(0, Rect2i(_slot0, Vector2i(size, size)), ox, oy)
	if variant == "base":
		pc = pc.slice(0, 64)
	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, pipes[variant])
	rd.compute_list_bind_uniform_set(cl, uset_base if variant == "base" else uset, 0)
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	rd.compute_list_dispatch(cl, int(ceil(float(size) / 16.0)), int(ceil(float(size) / 16.0)), 1)
	rd.compute_list_end()
	rd.submit()
	rd.sync()


## The smooth count of texel k in the level texture's bytes. Follows level_format().
static func count_at(data: PackedByteArray, k: int) -> float:
	# The first two uint16s are the count's float32 bits, low half first, which is the
	# float's own little-endian layout.
	return data.decode_float(k * 8)


## What storing a CPU count in the level texture would leave of it. Follows level_format().
static func _stored(v: float) -> float:
	return v   # float32; the PackedFloat32Array it lands in does the rounding


## A value through a half float, the old storage.
static func _half(v: float) -> float:
	var b := PackedByteArray()
	b.resize(2)
	b.encode_half(0, v)
	return b.decode_half(0)


# --- comparison ---------------------------------------------------------------------

## One storage step at the value's magnitude: a CPU/GPU pair that rounds to neighbouring
## stored values from a last-bit difference is a match, anything further is not.
static func _ulp(v: float) -> float:
	return pow(2.0, floor(log(maxf(absf(v), 1e-3)) / log(2.0)) - 10.0)


static func _distinct(t: PackedFloat32Array) -> int:
	var seen := {}
	for v in t:
		seen[v] = true
	return seen.size()


func _inside(t: PackedFloat32Array) -> float:
	var n := 0
	for v in t:
		if v >= float(_iter):
			n += 1
	return float(n) / float(t.size())


static func _match(a: PackedFloat32Array, t: PackedFloat32Array) -> float:
	var n := 0
	for k in t.size():
		if absf(a[k] - t[k]) <= _ulp(t[k]) * 1.01:
			n += 1
	return float(n) / float(t.size())


## Fraction within a quarter count: what the eye could ever see through the palette.
static func _near(a: PackedFloat32Array, t: PackedFloat32Array) -> float:
	var n := 0
	for k in t.size():
		if absf(a[k] - t[k]) <= 0.25:
			n += 1
	return float(n) / float(t.size())


## Mean count error against the mean texel-to-texel change of the truth, each difference
## capped at 16 counts so a texel flipping inside/outside cannot swamp it. It reads as the
## fill's error in texels of position: 0.01 is a hundredth of a texel out, 1 is as wrong
## as sampling the neighbour, which is what the float32 blocks are.
static func _err_texels(a: PackedFloat32Array, t: PackedFloat32Array) -> float:
	var e := 0.0
	var g := 0.0
	for j in N:
		for i in N - 1:
			var k := j * N + i
			e += minf(16.0, absf(a[k] - t[k]))
			g += minf(16.0, absf(t[k + 1] - t[k]))
	return e / maxf(1e-6, g)


## Fraction of horizontal neighbours holding the identical value: the blocks, measured.
static func _same_pairs(a: PackedFloat32Array) -> float:
	var n := 0
	for j in N:
		for i in N - 1:
			if a[j * N + i] == a[j * N + i + 1]:
				n += 1
	return float(n) / float(N * (N - 1))


func _case(f: int, julia: bool, jc: Vector2, stage: int, rng: RandomNumberGenerator,
		shallow := false) -> bool:
	rng.seed = 1000 + f * 17 + (7 if julia else 0) + stage
	var texel := _texel(stage)
	var name: String = ("julia" if julia else FractalGround.FORMULA_NAMES[f].replace(" ", "_"))
	var spot := _find_spot(f, julia, jc, texel, rng)
	if spot.is_empty():
		print("GROUNDCHECK %s stage=%d FAIL no boundary spot found" % [name, stage])
		return false
	var ox: float = spot[0]
	var oy: float = spot[1]
	var t: PackedFloat32Array = spot[2]
	var cond: float = spot[3]
	var d := _gpu("df", f, julia, jc, stage, ox, oy)
	var s := _gpu("f32", f, julia, jc, stage, ox, oy)
	var md := _match(d, t)
	var ms := _match(s, t)
	var dd := _distinct(d)
	var ds := _distinct(s)
	var dt := _distinct(t)
	# df has to be as right as the patch lets anything be (its own conditioning, less a
	# margin for the ~2e-5 texel df32 itself moves a coordinate) and never blocky.
	var df_ok := md >= minf(0.95, cond - 0.05) and md >= 0.85 and dd >= int(0.8 * float(dt))
	# Deep: the f32 control has to fail, or this spot never tested anything. Shallow: it
	# must stay within a quarter count of the truth, which is all the old fill ever was.
	var f32_ok := _near(s, t) >= 0.95 and ds >= int(0.8 * float(dt))
	if shallow and pipes.has("base"):
		# The same patch through the pre-df32 fill: the new f32 variant must be at least as
		# close to the truth as it was, since that is the one every shallow frame runs.
		var b := _gpu("base", f, julia, jc, stage, ox, oy)
		var nb := _near(b, t)
		f32_ok = _near(s, t) >= nb - 0.02
		print("GROUNDCHECK base f32 fill at stage %d: near=%.3f match=%.3f, new f32 near=%.3f, new vs base near=%.3f" % [
			stage, nb, _match(b, t), _near(s, t), _near(s, b)])
	var ok := df_ok and (f32_ok if shallow else not f32_ok)
	# The patch's own sensitivity at df32's resolution: the truth moved by one df32 step
	# of the coordinate (2^-47 of its magnitude). Past the depth where this drops, no
	# two-float fill can be exact there, and the numbers say so.
	var eps := pow(2.0, -47.0) * maxf(1.0, Vector2(ox, oy).length()) / texel
	var self_df := _match(_truth(f, julia, jc, ox + eps * texel, oy, texel), t)
	print("GROUNDCHECK %s stage=%d zoom=%sx %s  df err=%.4f f32 err=%.3f  df match=%.3f distinct=%d  f32 match=%.3f near=%.3f distinct=%d %s  truth distinct=%d self=%.3f self@df(%s texel)=%.3f same-pairs truth/df/f32=%.2f/%.2f/%.2f at (%.15f, %.15f)" % [
		name, stage, String.num_scientific(pow(2.0, float(stage))), "PASS" if ok else "FAIL",
		_err_texels(d, t), _err_texels(s, t), md, dd, ms, _near(s, t), ds, ("PASS" if f32_ok else "FAIL(control)") if not shallow else ("PASS" if f32_ok else "FAIL"),
		dt, cond, String.num_scientific(snappedf(eps, 1e-6)), self_df, _same_pairs(t), _same_pairs(d), _same_pairs(s), ox, oy])
	if not ok:
		# The first row, so a failure shows whether it is blocks, noise or an offset.
		var row := func(a: PackedFloat32Array) -> String:
			var out := ""
			for i in 10:
				out += " %7.2f" % a[i]
			return out
		print("  truth" + row.call(t))
		print("  df   " + row.call(d))
		print("  f32  " + row.call(s))
		var tj := _truth(f, julia, jc, ox + JITTER * texel, oy, texel)
		print("  truth vs itself moved JITTER: match=%.3f" % _match(tj, t))
	return ok


## Where float32 gives out: Mandelbrot f32 match rate per stage, next to the ratio the
## gate would see there. Report only; the gate's number comes from reading this.
func _sweep(rng: RandomNumberGenerator) -> void:
	for stage in range(4, 14):
		rng.seed = 77 + stage
		var texel := _texel(stage)
		var spot := _find_spot(0, false, Vector2.ZERO, texel, rng)
		if spot.is_empty():
			print("SWEEP stage=%d no spot" % stage)
			continue
		var ox: float = spot[0]
		var oy: float = spot[1]
		var t: PackedFloat32Array = spot[2]
		var s := _gpu("f32", 0, false, Vector2.ZERO, stage, ox, oy)
		var d := _gpu("df", 0, false, Vector2.ZERO, stage, ox, oy)
		var m := maxf(1.0, Vector2(ox, oy).length())
		print("SWEEP stage=%d ratio=%s gate=%s f32 match=%.3f near=%.3f df match=%.3f same-pairs truth/f32=%.2f/%.2f" % [
			stage, String.num_scientific(snappedf(m / texel, 1000.0)), "df" if m / texel > FractalGround.DF_RATIO else "f32",
			_match(s, t), _near(s, t), _match(d, t), _same_pairs(t), _same_pairs(s)])


## ITER 4096: the stored count must keep its fraction above 2048, where half floats are
## two counts apart and the terraces, contours and grain that read fract(count) die. A
## patch where a quarter of the texels count between 2048 and 4096, filled with df32 (it
## is right there, see above), compared with the unrounded 64-bit count. The control is
## the same truth pushed through a half float, which must fail the same bar.
func _fraction_case(rng: RandomNumberGenerator) -> bool:
	var stage := 12
	var texel := _texel(stage)
	_iter = 4096
	ground.max_iter = 4096
	rng.seed = 4096
	var spot: Array = []
	for attempt in 16:
		var cx := -0.4
		var cy := 0.0
		var r := 2.0
		var iters := 256
		while r > float(N) * texel:
			var best: Array = []
			for j in 7:
				for i in 7:
					var x := cx + r * (2.0 * (float(i) + rng.randf()) / 7.0 - 1.0)
					var y := cy + r * (2.0 * (float(j) + rng.randf()) / 7.0 - 1.0)
					var sc := cpu_count(0, x, y, 0.0, 0.0, iters)
					if sc < float(iters) * 0.97:
						best.append([sc, x, y])
			if best.is_empty():
				break
			best.sort_custom(func(a, b): return a[0] > b[0])
			var pick: Array = best[rng.randi_range(0, mini(1, best.size() - 1))]
			cx = pick[1]
			cy = pick[2]
			r *= 0.25
			iters = mini(4096, iters + 384)
		var ox := (roundf((cx - float(N) * 0.5 * texel) / texel) + 0.5) * texel
		var oy := (roundf((cy - float(N) * 0.5 * texel) / texel) + 0.5) * texel
		var t := _truth(0, false, Vector2.ZERO, ox, oy, texel, true)
		var high := 0
		for v in t:
			if v > 2048.0 and v < 4096.0:
				high += 1
		if float(high) / float(t.size()) >= 0.25:
			spot = [ox, oy, t, high]
			break
	if spot.is_empty():
		print("GROUNDCHECK fraction FAIL no patch counting past 2048 found")
		_iter = ITER
		ground.max_iter = ITER
		return false
	var t: PackedFloat32Array = spot[2]
	var d := _gpu("df", 0, false, Vector2.ZERO, stage, spot[0], spot[1])
	# Only texels whose count HAS a definite fraction: counts past 2048 sit right on the
	# boundary, and there a third of them change by more than 0.05 when the point moves by
	# one df32 step (5e-7 of a texel here). Nothing can store a fraction the maths does not
	# pin down, so those are left out and counted.
	var tj := _truth(0, false, Vector2.ZERO, spot[0] + pow(2.0, -47.0) * 0.8, spot[1], texel, true)
	var n := 0
	var loose := 0
	var good := 0
	var good_half := 0
	for k in t.size():
		if t[k] <= 2048.0 or t[k] >= 4096.0:
			continue
		if absf(tj[k] - t[k]) > 0.01:
			loose += 1
			continue
		n += 1
		if absf(d[k] - t[k]) <= 0.05:
			good += 1
		if absf(_half(t[k]) - t[k]) <= 0.05:
			good_half += 1
	var fg := float(good) / float(maxi(1, n))
	var fh := float(good_half) / float(maxi(1, n))
	var ok := n >= 50 and fg >= 0.9 and fh < 0.5
	print("  fraction patch at (%.17f, %.17f)" % [spot[0], spot[1]])
	print("GROUNDCHECK fraction %s iter=4096 stage=%d texels 2048..4096: %d well-conditioned (%d left out), within 0.05 of the 64-bit count: stored %.3f, half-float control %.3f %s" % [
		"PASS" if ok else "FAIL", stage, n, loose, fg, fh, "FAIL(control)" if fh < 0.5 else "PASS(control, so the check is blind)"])
	_iter = ITER
	ground.max_iter = ITER
	return ok


## Wall time of a 1024x1024 fill (slots wrap in the small texture, which only costs
## overwrites), best of three, per variant at a shallow and a deep boundary spot.
func _bench(rng: RandomNumberGenerator) -> void:
	for stage: int in [3, 13]:
		rng.seed = 5 + stage
		var texel := _texel(stage)
		var spot := _find_spot(0, false, Vector2.ZERO, texel * 32.0, rng)
		if spot.is_empty():
			continue
		for it: int in [256, 1024]:
			ground.max_iter = it
			var line := "BENCH stage=%d iter=%d" % [stage, it]
			for v: String in ["base", "f32", "df"]:
				if not pipes.has(v):
					continue
				var best := 1e30
				for rep in 3:
					var t0 := Time.get_ticks_usec()
					_dispatch(v, 0, false, Vector2.ZERO, stage, spot[0], spot[1], 1024)
					best = minf(best, float(Time.get_ticks_usec() - t0))
				line += " %s=%.2fms" % [v, best / 1000.0]
			print(line)
	ground.max_iter = ITER
