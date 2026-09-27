extends SceneTree

## Headless checks for the orbit trace. MAPCHECK: FractalGround's world<->fractal
## mappings are inverses after a pan, a turn and a zoom (with a deliberately broken
## control that must fail). ORBITCHECK: the iteration runs an inside point to the full
## chain, an outside point to bailout in a few steps, and a Julia point at all. DEEPCHECK:
## the viewer's position, walking and the clipmap's texel bookkeeping at the deepest stage.
##
##   tools/orbit_check.sh

func _init() -> void:
	var g := FractalGround.new()
	g.pan(Vector2(1.3, -0.4))
	g.rotate_about_head(0.7)
	g.wpu = g.WPU_BASE * 3.7   # zoom without the GPU stage sync
	var rng := RandomNumberGenerator.new()
	rng.seed = 9
	var max_err := 0.0
	var max_err_ctl := 0.0
	for i in 200:
		var w := Vector2(rng.randf_range(-30, 30), rng.randf_range(-30, 30))
		var back: Vector2 = g.fractal_to_world(g.world_to_fractal(w))
		max_err = maxf(max_err, (back - w).length())
		# Control: the forward map with the rotation dropped is not the inverse.
		var wrong: Vector2 = g.fractal_to_world(g.centre + w / g.wpu)
		max_err_ctl = maxf(max_err_ctl, (wrong - w).length())
	var map_ok := max_err < 1e-4 and max_err_ctl > 1e-2
	print("MAPCHECK %s max_err=%.8f control=%s (%.4f)" % ["PASS" if map_ok else "FAIL", max_err,
		"FAIL" if max_err_ctl > 1e-2 else "PASS", max_err_ctl])

	var inside := OrbitTrace.iterate(Vector2(-0.1, 0.0), false, Vector2.ZERO).size()
	var outside := OrbitTrace.iterate(Vector2(1.0, 1.0), false, Vector2.ZERO).size()
	var julia := OrbitTrace.iterate(Vector2(0.3, 0.2), true, Vector2(-0.8, 0.156)).size()
	# The formula has to reach the orbit: at c = (0.3, -0.5) the second point is
	# (0.14, -0.8) for z^2+c, (0.14, -0.2) for the burning ship and c^3+c for the cubic.
	var c := Vector2(0.3, -0.5)
	var ship: Vector2 = OrbitTrace.iterate(c, false, Vector2.ZERO, 1)[1]
	var mand: Vector2 = OrbitTrace.iterate(c, false, Vector2.ZERO, 0)[1]
	var cube: Vector2 = OrbitTrace.iterate(c, false, Vector2.ZERO, 6)[1]
	var c3 := Vector2(c.x * c.x * c.x - 3.0 * c.x * c.y * c.y, 3.0 * c.x * c.x * c.y - c.y * c.y * c.y) + c
	var formula_ok := ship.distance_to(Vector2(0.14, -0.2)) < 1e-6 \
		and mand.distance_to(Vector2(0.14, -0.8)) < 1e-6 and cube.distance_to(c3) < 1e-6
	var orbit_ok := inside == OrbitTrace.MAX_POINTS and outside < 10 and julia > 0 and formula_ok
	print("ORBITCHECK %s inside=%d outside=%d julia=%d formula=%s" % ["PASS" if orbit_ok else "FAIL",
		inside, outside, julia, "ok" if formula_ok else "WRONG"])
	var deep_ok := _deep_check()
	quit(0 if map_ok and orbit_ok and deep_ok else 1)


## DEEPCHECK: the ground's bookkeeping at STAGE_MAX, where absolute texel indices pass
## int32 and a float32 coordinate is metres out. Walking has to move the viewer, every
## stored window has to stay small, and re-labelling (a zoom step, a re-anchor) must leave
## each stored window on the same fractal point, or the tiles would show the wrong place.
func _deep_check() -> bool:
	var sx := -0.743643887037158704752
	var sy := 0.131825904205311970493
	var g := FractalGround.new()
	g.set_viewer_fractal(sx, sy)
	g.zoom(pow(2.0, float(FractalGround.STAGE_MAX)) * 1.05 / g.zoom_factor())
	var t0: float = g._texel0()
	var fails: Array[String] = []
	# 1. The viewer's coordinate keeps 64 bits; a Vector2 would put it texels away.
	var pos_err := maxf(absf(g.viewer_fx() - sx), absf(g.viewer_fy() - sy)) / t0
	var ctl_err := absf(Vector2(sx, sy).x - sx) / t0
	if not (pos_err < 0.01 and ctl_err > 1.0):
		fails.append("position %.4f texel (float32 control %.1f)" % [pos_err, ctl_err])
	# 2. A metre's walk in centimetre steps moves a metre. Control: the same steps added to
	# a Vector2 go nowhere.
	var v2 := Vector2(sx, sy)
	for i in 100:
		g.pan(Vector2(0.01, 0.0))
		v2 += Vector2(0.01, 0.0) / g.wpu
	var walked := Vector2(g.viewer_fx() - sx, g.viewer_fy() - sy).length() * g.wpu
	var walked_ctl := (v2 - Vector2(sx, sy)).length() * g.wpu
	if not (absf(walked - 1.0) < 1e-3 and absf(walked_ctl - 1.0) > 0.1):
		fails.append("walked %.4f m (float32 control %.2f m)" % [walked, walked_ctl])
	# 3. Windows: small, on the viewer, and each level's slot the same counted from the
	# anchor as counted from the fractal origin.
	var vt0: Vector2i = g.track_windows()
	var big := 0
	for i in FractalGround.LEVELS:
		var w: Vector2i = g._win_lo[i]
		big = maxi(big, maxi(absi(w.x), absi(w.y)))
		var abs_i := int(floor(g.viewer_fx() / g._texel(i)))
		if posmod(vt0.x >> i, g.n_tex) != posmod(abs_i, g.n_tex):
			fails.append("level %d slot %d vs %d" % [i, posmod(vt0.x >> i, g.n_tex), posmod(abs_i, g.n_tex)])
	var c0: Array[float] = g._texel_centre(0, vt0)
	if big > (1 << 29) or absf(c0[0] - g.viewer_fx()) > t0 or absf(c0[1] - g.viewer_fy()) > t0:
		fails.append("windows: largest index %d, viewer texel off by %.2f texel" % [big, absf(c0[0] - g.viewer_fx()) / t0])
	# 4. Re-labelling keeps every stored window on its fractal point, through the whole
	# zoom range out and back. Control: moving the anchor without re-labelling must fail.
	var worst := 0.0
	for step in [-1, 1]:
		for k in FractalGround.STAGE_MAX - FractalGround.STAGE_MIN:
			var before := _windows(g)
			var old_stage: int = g._stage
			g.zoom(0.5 if step < 0 else 2.0)
			if g._stage == old_stage:
				break
			# Read the windows before track_windows(): a mislabelled window is far enough
			# from the viewer that tracking re-centres it, which hides the error as a
			# silent full rebuild.
			var after := _windows(g)
			g.track_windows()
			# Stepping in, level i is the old level i-1; stepping out, the old level i+1.
			for i in FractalGround.LEVELS:
				var j := i - 1 if step > 0 else i + 1
				if j < 0 or j >= FractalGround.LEVELS:
					continue
				var tj: float = g._texel(i)
				worst = maxf(worst, maxf(absf(after[i][0] - before[j][0]), absf(after[i][1] - before[j][1])) / tj)
	var ctl := _windows(g)
	g._ax += FractalGround.ANCHOR_Q
	var moved := absf(_windows(g)[0][0] - ctl[0][0]) / g._texel(0)
	g._ax -= FractalGround.ANCHOR_Q
	if not (worst < 1e-6 and moved > 1.0):
		fails.append("relabel drift %s texel (control %.1f)" % [String.num_scientific(worst), moved])
	var ok := fails.is_empty()
	print("DEEPCHECK %s stage=%d zoom=%s pos=%s texel walk=%.4f m (float32 %.2f m) largest index=%d relabel drift=%s texel control=FAIL (%.0f) %s" % [
		"PASS" if ok else "FAIL", FractalGround.STAGE_MAX, String.num_scientific(snappedf(g.zoom_factor(), 1000.0)), String.num_scientific(pos_err), walked, walked_ctl,
		big, String.num_scientific(worst), moved, "; ".join(fails)])
	g.free()
	return ok


## Every level's stored window, as the fractal coordinate of its first texel.
func _windows(g: FractalGround) -> Array:
	var out := []
	for i in FractalGround.LEVELS:
		out.append(g._texel_centre(i, g._win_lo[i]))
	return out
