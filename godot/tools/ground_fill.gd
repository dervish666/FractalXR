extends SceneTree

## Does the ground ever draw a texel the fill has not caught up with? Through the real main
## scene: every rect FractalGround queues because its slots stopped holding that level's
## texels (a pan strip, a new level after a zoom step, a rebuild) is overwritten with a
## poison pattern the moment it is queued, before the fill runs. The ground's fragment is
## swapped for a probe that re-fetches the texel blocks the real fragment chose (its own l0,
## l1 and blend k) and paints red where any of them still holds poison:
##
##   red    a pixel built from a slot still waiting for its refill: the artifact
##   green  a pixel built from filled texels
##   blue   fog, where no level was usable
##
## Poison is a value no fill writes (a negative count), and the probe reads the raw bits,
## so neither fast math nor a zero blend weight can hide it. Scenarios: walking at stick
## speed with the fill keeping up (stage 4) and falling behind (ITER 4096, a sixteenth of
## the texels a frame, as deep zoom runs on the Quest), a trigger glide, a stick zoom in
## across the iteration floor's steps at 10 and 13 and back out, and a walk at stage 17.
## The Mac's df32 fill runs ~37x slower than float32 (`precise`), so deep stages never
## finish filling here: the stage 17 walk starts from a partial fill, which still answers
## whether anything unfilled reaches the screen.
##
## The Mac's GPU fills float32 tiles so fast that the budget loop grows to BUDGET_MAX and
## the fill never falls behind. While a scenario runs the budget is pinned at PIN texels a
## frame, the loop's own starting point and the order of what a Quest affords: an emulation
## of the headset's fill rate, not a measurement of it (PIN=0 lets it adapt).
##
##   tools/ground_fill.sh            CONTROL=1 swaps the probe for one that never looks:
##                                   it must report zero red, and the real probe must not.

const SPOT := [-0.743643887037158704752191506114774, 0.131825904205311970493132056385139]
const POISON := "uvec4(0xBEEFu, 0xDEADu, 0xBEEFu, 0xDEADu)"
const STRIDE := 3
var PIN := float(OS.get_environment("PIN")) if OS.get_environment("PIN") != "" else 150000.0

var main
var g: FractalGround
var _rd: RenderingDevice
var _pipe: RID
var _shader: RID
var _set: RID
var _set_tex: RID
var _fails := 0
var _queued := 0


func _init() -> void:
	main = (load("res://main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	for i in 40:
		await process_frame
	main._set_mode("ground")
	main.help.close()
	main.orbit_on = false
	main.orbit.visible = false
	main.xr_camera.position = Vector3(0.0, 1.6, 0.0)
	main.xr_camera.rotation_degrees = Vector3(-35.0, 0.0, 0.0)
	main.left_hand.position = Vector3(-0.3, 1.0, -0.2)
	main.left_hand.rotation_degrees = Vector3(0.0, 0.0, 180.0)
	g = main.ground
	if not _paint():
		quit(1)
		return
	if not _poison_setup():
		quit(1)
		return
	g.on_queue = _poison

	var control := OS.get_environment("CONTROL") != ""
	# Walk at the stick's speed, shallow and deep. Deep is where the fill is slowest: df32
	# and a raised iteration floor both cut the texels a frame.
	await _walk("walk stage 4", 4, 1.4, 216, 0)
	await _walk("walk stage 6 ITER 4096", 6, 1.4, 216, 4096)
	# A trigger glide covers half a metre the first frame.
	await _glide("glide 12 m, stage 4", 4, 12.0, 216)
	# Stick zoom at full deflection, across the floor's steps at stages 10 and 13, then
	# straight back out without waiting for the fill.
	await _zoom("zoom in 4 -> 13", 4, 13, true)
	await _zoom("zoom out 13 -> 4", 13, 4, false)
	await _walk("walk stage 17", 17, 1.4, 216, 0, 1500)
	print("GROUNDFILL %s failures=%d queued=%d%s" % ["PASS" if _fails == 0 else "FAIL", _fails,
		_queued, " (CONTROL: the probe never looks, red must be 0)" if control else ""])
	quit(0 if _fails == 0 else 1)


## Stand over the spot at `stage` and wait for the stack to fill completely, or for `cap`
## frames if that is sooner (and then say how much was left).
func _settle(stage: int, iter: int = 0, cap: int = 20000) -> bool:
	g.set_max_iter(iter if iter > 0 else 256)
	g.home()
	g.zoom(pow(2.0, float(stage)) * 1.05)
	g.set_viewer_fractal(SPOT[0], SPOT[1])
	for i in cap:
		await process_frame
		# Draw every frame: an occluded window skips its draws, and undrawn frames never
		# hand back the fill's timestamps, which leaves the budget loop blind.
		RenderingServer.force_draw(false, 0.0)
		if i % 600 == 0:
			print("  settling stage %d frame %d pending %d budget %.0f" % [stage, i, g.pending_texels(), g._budget])
		if i > 5 and g.pending_texels() == 0:
			for k in 4:
				await process_frame
			return true
	print("  settle stage %d stopped at %d frames, %d texels still queued" % [stage, cap, g.pending_texels()])
	return cap < 20000


func _walk(name: String, stage: int, mps: float, frames: int, iter: int, cap: int = 20000) -> void:
	if not await _settle(stage, iter, cap):
		_fails += 1
		return
	var st := _Stats.new()
	for i in frames:
		g.pan(Vector2(0.0, -mps / 72.0))
		await _frame()
		st.add(_count())
	_report(name, st)


func _glide(name: String, stage: int, dist: float, frames: int) -> void:
	if not await _settle(stage):
		_fails += 1
		return
	var st := _Stats.new()
	g.glide_to(g._head_xz + Vector2(0.0, -dist))
	for i in frames:
		await _frame()
		st.add(_count())
	_report(name, st)


func _zoom(name: String, from: int, to: int, settle: bool) -> void:
	if settle and not await _settle(from):
		_fails += 1
		return
	var st := _Stats.new()
	var dir := 1.0 if to > from else -1.0
	var guard := 0
	while (g._stage < to if dir > 0.0 else g._stage > to) and guard < 4000:
		g.zoom(exp(dir * main.GROUND_ZOOM_PER_S / 72.0))
		await _frame()
		st.add(_count())
		guard += 1
	# And the frames after the stick is released, while the fill catches up.
	for i in 72:
		await _frame()
		st.add(_count())
	_report(name, st)


## One frame of a scenario, with the budget held at PIN: _worked cleared means _flush skips
## its adaptation step and spends exactly _budget.
func _frame() -> void:
	if PIN > 0.0:
		g._budget = PIN
		g._worked = false
	await process_frame


class _Stats:
	var frames := 0
	var red_frames := 0
	var red_max := 0.0
	var red_sum := 0.0
	var fog_max := 0.0
	var fog_base := -1.0

	func add(c: Vector2) -> void:
		if fog_base < 0.0:
			fog_base = c.y
		frames += 1
		if c.x > 0.0:
			red_frames += 1
		red_max = maxf(red_max, c.x)
		red_sum += c.x
		fog_max = maxf(fog_max, c.y)


func _report(name: String, st: _Stats) -> void:
	var ok := st.red_frames == 0
	if not ok:
		_fails += 1
	print("  %-22s %s  red in %d/%d frames, worst %.2f%% of the ground, mean %.3f%%; fog %.1f%% at start, worst %.1f%%" % [
		name, "PASS" if ok else "FAIL", st.red_frames, st.frames, st.red_max * 100.0,
		st.red_sum / float(maxi(1, st.frames)) * 100.0, st.fog_base * 100.0, st.fog_max * 100.0])


## Fraction of ground pixels that are red, and of all pixels that are fog.
func _count() -> Vector2:
	RenderingServer.force_draw(false, 0.0)
	var img := root.get_viewport().get_texture().get_image()
	var red := 0
	var green := 0
	var fog := 0
	var n := 0
	for y in range(0, img.get_height(), STRIDE):
		for x in range(0, img.get_width(), STRIDE):
			var c := img.get_pixel(x, y)
			n += 1
			if c.r > 0.5 and c.g < 0.5:
				red += 1
			elif c.g > 0.5:
				green += 1
			elif c.b > 0.5:
				fog += 1
	return Vector2(float(red) / float(maxi(1, red + green)), float(fog) / float(maxi(1, n)))


## Swap the ground's last line for the probe. Uses the fragment's own level choice.
func _paint() -> bool:
	var code: String = g._material.shader.code
	var probe := """
bool probe_poison(int level, vec2 e0p) {
	ivec2 vt = view_texel0 >> level;
	ivec2 rem = view_texel0 - (vt << level);
	vec2 f = (vec2(rem) + view_frac0 + e0p) / float(1 << level) - 0.5;
	ivec2 base = vt + ivec2(floor(f));
	for (int j = -1; j <= 2; j++) {
		for (int i = -1; i <= 2; i++) {
			ivec2 a = base + ivec2(i, j);
			ivec2 slot = ((a %% tex_size) + tex_size) %% tex_size;
			if (texelFetch(levels, ivec3(slot, layer_of(level)), 0) == %s) return true;
		}
	}
	return false;
}

void fragment() {""" % POISON
	var look := "true" if OS.get_environment("CONTROL") == "" else "false"
	var tail := """bool shown = valid && fog < 0.999;
	bool bad = false;
	if (shown && %s) {
		if (k < 0.999) bad = bad || probe_poison(l0, e0);
		if (k > 0.001 && l1 != l0) bad = bad || probe_poison(l1, e0);
	}
	ALBEDO = bad ? vec3(1.0, 0.0, 0.0) : (shown ? vec3(0.0, 1.0, 0.0) : vec3(0.0, 0.0, 1.0));""" % look
	var painted := code.replace("void fragment() {", probe).replace(
		"ALBEDO = mix(col, fog_colour, fog);", tail)
	if painted == code or not painted.contains("probe_poison(l0"):
		print("GROUNDFILL FAIL: the fragment's anchors moved; update the probe")
		return false
	var sh := Shader.new()
	sh.code = painted
	g._material.shader = sh
	# The sky is the same material; it would only double the count.
	g.set_sky(0.0)
	return true


func _poison_setup() -> bool:
	_rd = RenderingServer.get_rendering_device()
	var src := RDShaderSource.new()
	src.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	src.source_compute = """#version 450
layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;
layout(set = 0, binding = 0, rgba16ui) uniform restrict writeonly uimage2DArray levels;
layout(push_constant, std430) uniform PC { ivec2 origin; ivec2 size; int layer; int n; int p0; int p1; } p;
void main() {
	ivec2 g = ivec2(gl_GlobalInvocationID.xy);
	if (g.x >= p.size.x || g.y >= p.size.y) return;
	ivec2 a = p.origin + g;
	ivec2 slot = ((a %% p.n) + p.n) %% p.n;
	imageStore(levels, ivec3(slot, p.layer), %s);
}
""" % POISON
	var spirv := _rd.shader_compile_spirv_from_source(src)
	if spirv.compile_error_compute != "":
		print("GROUNDFILL FAIL: poison shader: %s" % spirv.compile_error_compute)
		return false
	_shader = _rd.shader_create_from_spirv(spirv)
	_pipe = _rd.compute_pipeline_create(_shader)
	return true


func _poison(level: int, r: Rect2i) -> void:
	if r.size.x <= 0 or r.size.y <= 0:
		return
	if _set_tex != g._tex:
		var u := RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		u.binding = 0
		u.add_id(g._tex)
		_set = _rd.uniform_set_create([u], _shader, 0)
		_set_tex = g._tex
	_queued += 1
	var pc := PackedByteArray()
	pc.resize(32)
	pc.encode_s32(0, r.position.x)
	pc.encode_s32(4, r.position.y)
	pc.encode_s32(8, r.size.x)
	pc.encode_s32(12, r.size.y)
	pc.encode_s32(16, (level + g._rot) % FractalGround.LEVELS)
	pc.encode_s32(20, g.n_tex)
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipe)
	_rd.compute_list_bind_uniform_set(cl, _set, 0)
	_rd.compute_list_set_push_constant(cl, pc, 32)
	_rd.compute_list_dispatch(cl, int(ceil(r.size.x / 16.0)), int(ceil(r.size.y / 16.0)), 1)
	_rd.compute_list_end()
