extends SceneTree

## Headless checks for the orbit trace. MAPCHECK: FractalGround's world<->fractal
## mappings are inverses after a pan, a turn and a zoom (with a deliberately broken
## control that must fail). ORBITCHECK: the iteration runs an inside point to the full
## chain, an outside point to bailout in a few steps, and a Julia point at all.
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
	quit(0 if map_ok and orbit_ok else 1)
