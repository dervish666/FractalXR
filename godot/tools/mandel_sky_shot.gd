extends SceneTree

## MANDEL on SKY PICK over GROUND, to .spike-out/mandel_sky/: the Mandelbrot overview looking
## up and looking ahead, a zoom into seahorse valley driven through zoom_toward() (the trigger's
## path), the you-are-here marker, GROUND's SPHERE floor (bowl and globe, each looking ahead,
## straight down, at the horizon and straight up, plus the globe 45 and 70 degrees up and COAST
## displaced on the bowl), and every family's dome. Checks the sky is drawn (the upper half has colour and structure where SKY off is the
## plain background: the control), that a zoom moved it, and the SPHERE checks listed at
## _sphere_shots(). Light: the fill is a few dozen 3k row slices, the zoom stops at 30x.
##
##   tools/mandel_sky_shot.sh

const OUT := "res://.spike-out/mandel_sky"

var main: Node


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var scene: PackedScene = load("res://main.tscn")
	main = scene.instantiate()
	root.add_child(main)
	for i in 40:
		await process_frame
	main.help.close()
	main.xr_camera.position = Vector3(0.0, 1.6, 0.0)
	main.xr_camera.fov = 100.0
	main._set_mode("ground")
	var fs: FlameSky = main.flame_sky
	var ok := true

	_look(70.0)
	for i in 120:
		await process_frame
	var off := _shot("sky_off_up")

	main.sky_on = true
	fs.set_pick(fs.presets.size() + 1)
	var waited := 0
	while not fs.is_shown() and waited < 600:
		await process_frame
		waited += 1
	# The fade, then a settled frame.
	for i in 160:
		await process_frame
	print("MSKYSHOT shown after %d frames, label '%s'" % [waited, main._sky_label()])
	var up := _shot("mandel_up")
	var s_off := _stats(off)
	var s_up := _stats(up)
	var drawn := s_up.x > s_off.x + 0.02 and s_up.y > 0.02
	ok = ok and drawn
	print("MSKYSHOT drawn %s mean %.3f->%.3f spread %.3f->%.3f" % ["PASS" if drawn else "FAIL",
		s_off.x, s_up.x, s_off.y, s_up.y])

	_look(25.0)
	for i in 10:
		await process_frame
	_shot("mandel_ahead")

	# Seahorse valley, -0.745 + 0.11i: its direction under the home view, zoomed at the
	# trigger's rate for a few seconds of frames.
	var ms: MandelSky = fs.mandel
	var c := Vector2(-0.745, 0.11)
	var u := (c - Vector2(-0.75, 0.0)) / 2.0
	var r2 := u.length_squared()
	var dir := Vector3(2.0 * u.x, 1.0 - r2, 2.0 * u.y) / (1.0 + r2)
	_look_at(dir)
	for i in 10:
		await process_frame
	_shot("seahorse_before")
	while ms.zoom < 30.0:
		ms.zoom_toward(dir, MandelSky.ZOOM_RATE, 1.0 / 30.0, main.ground._m)
		await process_frame
	_shot("seahorse_mid_zoom")
	for i in 90:
		await process_frame
	var zoomed := _shot("seahorse_30x")
	print("MSKYSHOT zoom %.1fx label '%s'" % [ms.zoom, main._sky_label()])

	# You are here: the marker over the fractal point under your feet, dead centre when you
	# look along its direction.
	main._go_home()
	for i in 10:
		await process_frame
	main.xr_camera.fov = 40.0
	_look_at(ms._mat.get_shader_parameter(&"here_dir"))
	for i in 10:
		await process_frame
	var here := _shot("here")
	var cc := here.get_pixel(here.get_width() / 2, here.get_height() / 2)
	var marked := cc.r > 0.4 and cc.g > 0.4 and cc.b > 0.4
	ok = ok and marked
	print("MSKYSHOT here %s centre %s" % ["PASS" if marked else "FAIL", cc])

	ok = await _sphere_shots() and ok

	# Every family's home, straight up through a wide lens: the whole dome in one frame.
	main.xr_camera.fov = 150.0
	for f in FractalGround.FORMULA_NAMES.size():
		main.ground.set_formula(f)
		main._go_home()
		_look(90.0)
		for i in 60:
			await process_frame
		_shot("dome_%s" % str(FractalGround.FORMULA_NAMES[f]).replace(" ", "_"))

	var moved := _stats(zoomed).y > 0.02
	ok = ok and moved
	print("MSKYSHOT %s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)


func _look(pitch_deg: float) -> void:
	main.xr_camera.rotation_degrees = Vector3(pitch_deg, 0.0, 0.0)


func _look_at(dir: Vector3) -> void:
	var cam: Camera3D = main.xr_camera
	cam.look_at(cam.global_position + dir, Vector3.FORWARD if absf(dir.y) > 0.99 else Vector3.UP)


func _shot(name: String) -> Image:
	var img: Image = root.get_viewport().get_texture().get_image()
	img.save_png("%s/%s.png" % [OUT, name])
	return img


## Over the upper half: x mean luma, y its standard deviation.
func _stats(a: Image) -> Vector2:
	return _band_stats(a, 0, a.get_height() / 2)


## Over rows [y0, y1): x mean luma, y its standard deviation.
func _band_stats(a: Image, y0: int, y1: int) -> Vector2:
	var n := 0
	var sum := 0.0
	var sq := 0.0
	var step := maxi(1, a.get_width() / 160)
	for y in range(y0, y1, step):
		for x in range(0, a.get_width(), step):
			var c := a.get_pixel(x, y)
			var l := 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
			sum += l
			sq += l * l
			n += 1
	var m := sum / float(maxi(n, 1))
	return Vector2(m, sqrt(maxf(0.0, sq / float(maxi(n, 1)) - m * m)))


## Mean absolute RGB difference between two images over rows [y0, y1).
func _band_diff(a: Image, b: Image, y0: int, y1: int) -> float:
	var n := 0
	var sum := 0.0
	var step := maxi(1, a.get_width() / 160)
	for y in range(y0, y1, step):
		for x in range(0, a.get_width(), step):
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			sum += absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)
			n += 1
	return sum / (3.0 * float(maxi(n, 1)))


## Mean absolute RGB difference between two rows of one image.
func _row_pair_diff(img: Image, ya: int, yb: int) -> float:
	var n := 0
	var sum := 0.0
	var step := maxi(1, img.get_width() / 160)
	for x in range(0, img.get_width(), step):
		var ca := img.get_pixel(x, ya)
		var cb := img.get_pixel(x, yb)
		sum += absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)
		n += 1
	return sum / (3.0 * float(maxi(n, 1)))


## Luma of every pixel in rows [y0, y1) step `ys`, row-major, `w` wide.
func _luma_rows(img: Image, y0: int, y1: int, ys: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for y in range(y0, y1, ys):
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			out.append(0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b)
	return out


## The horizontal shift dx (pixels, within [lo, hi]) for which b(x + dx) best matches a(x)
## over columns [cx - half, cx + half] of rows taken by _luma_rows, searched every 3 px and
## then every pixel round the best. A camera moved right by d sees a surface at distance D shift
## left by f d / D, so dx comes out near -f d / D.
func _best_shift(a: PackedFloat32Array, b: PackedFloat32Array, w: int, cx: int, half: int,
		lo: int, hi: int) -> int:
	var rows := a.size() / w
	var best := 0
	var best_e := INF
	for pass_i in 2:
		var from := lo if pass_i == 0 else best - 3
		var to := hi if pass_i == 0 else best + 3
		var st := 3 if pass_i == 0 else 1
		for dx in range(from, to + 1, st):
			var e := 0.0
			for r in rows:
				var o := r * w
				for x in range(cx - half, cx + half, 2):
					e += absf(a[o + x] - b[o + x + dx])
			if e < best_e:
				best_e = e
				best = dx
	return best


## The analytic hit of ray (o, dir) on sphere (c, r), worked another way from ray_to_plane():
## the quadratic in its textbook form, then the plane radius as hr tan(phi / 2) of the angle
## phi from the nadir, along the hit's azimuth. The bowl takes the lower half only and clamps at
## the equator; the globe takes every hit.
func _analytic_sphere_hit(o: Vector3, dir: Vector3, c: Vector3, r: float, hr: float,
		globe := false) -> Variant:
	var d := dir.normalized()
	var oc := o - c
	var bb := 2.0 * oc.dot(d)
	var cc := oc.dot(oc) - r * r
	var disc := bb * bb - 4.0 * cc
	if disc < 0.0:
		return null
	var t := (-bb + sqrt(disc)) * 0.5
	if t <= 0.0:
		return null
	var s := (o + d * t - c) / r
	if s.y > 0.0 and not globe:
		return null
	var phi := acos(clampf(-s.y, -1.0, 1.0))
	var rp := hr * tan(0.5 * phi)
	if not globe:
		rp = minf(rp, hr)
	var az := Vector2(s.x, s.z)
	if az.length() < 1e-9:
		return Vector2(c.x, c.z)
	return Vector2(c.x, c.z) + az.normalized() * rp


## Every uniform of a material, by name, for a before-and-after comparison.
func _params(m: ShaderMaterial) -> Dictionary:
	var out := {}
	for u in m.shader.get_shader_uniform_list():
		out[u["name"]] = m.get_shader_parameter(u["name"])
	return out


## Share of sampled pixels where `img` matches `ctrl` to within 0.004 a channel: with `ctrl`
## the same view with the ground's layers cleared, the pixels that show the background.
func _hole_share(img: Image, ctrl: Image) -> float:
	var n := 0
	var hole := 0
	var step := maxi(1, img.get_width() / 200)
	for y in range(0, img.get_height(), step):
		for x in range(0, img.get_width(), step):
			var a := img.get_pixel(x, y)
			var b := ctrl.get_pixel(x, y)
			if absf(a.r - b.r) < 0.004 and absf(a.g - b.g) < 0.004 and absf(a.b - b.b) < 0.004:
				hole += 1
			n += 1
	return float(hole) / float(maxi(n, 1))


## Mean RGB of 1-pixel rings round the image centre, radius r0 to r1, 720 samples a ring.
func _ring_means(img: Image, r0: int, r1: int) -> Array[Color]:
	var out: Array[Color] = []
	var cx := 0.5 * float(img.get_width())
	var cy := 0.5 * float(img.get_height())
	for rr in range(r0, r1 + 1):
		var acc := Color(0, 0, 0, 0)
		for k in 720:
			var a := TAU * float(k) / 720.0
			var c := img.get_pixel(int(cx + float(rr) * cos(a)), int(cy + float(rr) * sin(a)))
			acc.r += c.r
			acc.g += c.g
			acc.b += c.b
		out.append(Color(acc.r / 720.0, acc.g / 720.0, acc.b / 720.0))
	return out


## Mean RGB of each row in [y0, y1), as luma-free channel sums over the row.
func _row_means(img: Image, y0: int, y1: int) -> Array[Color]:
	var out: Array[Color] = []
	var step := maxi(1, img.get_width() / 400)
	for y in range(y0, y1):
		var acc := Color(0, 0, 0, 0)
		var n := 0
		for x in range(0, img.get_width(), step):
			var c := img.get_pixel(x, y)
			acc.r += c.r
			acc.g += c.g
			acc.b += c.b
			n += 1
		out.append(Color(acc.r / n, acc.g / n, acc.b / n))
	return out


## The largest mean-RGB step between neighbouring rings, and the radius it sits at.
func _ring_step(rings: Array[Color], r0: int) -> Vector2:
	var worst := 0.0
	var at := r0
	for i in range(1, rings.size()):
		var a: Color = rings[i - 1]
		var b: Color = rings[i]
		var d := (absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b)) / 3.0
		if d > worst:
			worst = d
			at = r0 + i
	return Vector2(worst, at)


## The ground's mesh and the stand cleared from the view for one frame's grab, then put back:
## what shows is the background (FractalGround.update() writes visibility every frame, so the
## layers go instead).
func _without_ground() -> Image:
	var g: FractalGround = main.ground
	var ml: int = g._mesh_instance.layers
	var sl: int = g._stand.layers
	g._mesh_instance.layers = 0
	g._stand.layers = 0
	for i in 4:
		await process_frame
	var img := root.get_viewport().get_texture().get_image()
	g._mesh_instance.layers = ml
	g._stand.layers = sl
	for i in 2:
		await process_frame
	return img


## The same view with the globe's far fill forced over every pixel, for one frame's grab:
## globe_cap set to 0 to 1 mm in each frame's pre-draw, after FractalGround.update() wrote it.
func _far_fill_only() -> Image:
	var mat: ShaderMaterial = main.ground._material
	var force := func(): mat.set_shader_parameter("globe_cap", Vector2(0.0, 0.001))
	RenderingServer.frame_pre_draw.connect(force)
	for i in 4:
		await process_frame
	var img := root.get_viewport().get_texture().get_image()
	RenderingServer.frame_pre_draw.disconnect(force)
	for i in 2:
		await process_frame
	return img


## Per ring, the mean-RGB difference between two ring profiles: x the largest, y its radius.
func _ring_diff(a: Array[Color], b: Array[Color], r0: int) -> Vector2:
	var worst := 0.0
	var at := r0
	for i in a.size():
		var d := (absf(a[i].r - b[i].r) + absf(a[i].g - b[i].g) + absf(a[i].b - b[i].b)) / 3.0
		if d > worst:
			worst = d
			at = r0 + i
	return Vector2(worst, at)


## Waits for the clipmap to fill, on the globe for the cap to reach GLOBE_CAP_M, and for a sky
## the globe hid to fade back in (FlameSky.FADE_S). Frames.
func _settle_sphere() -> int:
	var g: FractalGround = main.ground
	var fs: FlameSky = main.flame_sky
	var waited := 0
	while waited < 1200 and (g.pending_texels() > 0 \
			or (g.sphere_globe and g._globe_cap_m < FractalGround.GLOBE_CAP_M * 0.995) \
			or (fs.is_shown() and fs._fade < 1.0) or waited < 12):
		await process_frame
		waited += 1
	return waited


## SPHERE under MANDEL SKY: bowl (the lower half, under the sky) and globe (the whole sphere,
## no sky), both R 2 m and H 45 m, each from the same views (ahead, straight down at the feet,
## the horizon, straight up), named in pairs so Sam can set them side by side. From the centre R
## drops out of every pixel, so the checks that are about R move the camera off the centre.
##   tiles     SPHERE stepped through _step_ground_sphere(): MIRROR, BEACONS, TOUR, ORBIT and
##             NEAR hide, the mirrored ceiling goes, NEAR is forced to 0 in the material, the
##             stand shows, the right stick click leaves ORBIT alone; stepped off, all come back.
##   sky       the sky shows on the flat floor and in the bowl, hides on the globe with its SKY
##             and SKY GLOW tiles, and comes back with them when SPHERE goes back to off.
##   uniform   the material's radius, plane horizon, centre height, globe flag and relief unit,
##             the clipmap's stage bias, and the pan and flow scales, for each option.
##   stand     the glass disc changes the down view (its layers cleared is the control).
##   seam      no step across the horizon rows and no band darker than both halves there. On
##             the globe, the band above the equator also carries at least 0.4 of the detail
##             (luma deviation) of the band below: the plane runs on with no rim fog.
##   hole      globe: looking up at 45, 70 and 90 degrees no pixel shows the background (the
##             same view with the ground's layers cleared is the control, all hole).
##   cap_seam  globe: looking straight up, 1-pixel rings round the zenith from 1.7 to 28
##             degrees, across the fade from the data into the far fill, match the same view with
##             the far fill forced everywhere. Where the two agree the crossfade cannot step; the
##             far exterior's contour rings sit in both, so they cancel.
##   ray       ray_to_plane() from a hand-like origin against the analytic hit. Bowl: a ray up at
##             its wall hits it and does not zoom the sky, one higher misses. Globe: down, 8.5,
##             31 and 70 degrees up all hit, the trigger 70 degrees up starts a glide that way,
##             and no ray zooms the hidden sky.
##   anchor    the centre holds while the head moves 0.2 m across and 0.1 m down, and catches
##             up after a 1 m step and a 0.6 m crouch.
##   parallax  a 0.2 m sidestep shifts the picture by f d / R, about 104 px at R = 2. A centre
##             that follows the head shifts nothing.
##   flat_roundtrip  the flat floor is back to within 0.003 after bowl, globe and off. Reported
##             beside it: the same floor after a two-stage clipmap trip and after a refill in
##             place, since a refill alone moves texels on the set's edge.
##   bowl_roundtrip  the bowl, after the globe and off, is back to within 0.003 of its first shot,
##             with the globe's flag, stage bias and relief unit cleared and the sky back.
##   coast     COAST relief displaced inward on the bowl, seen from off the centre, moves
##             pixels, the right way, less near the rim, and never above the horizon.
##   stand_clear  steep relief never rises through the disc (painted height, straight down).
##   cost      GPU ms a frame for flat, bowl and globe, level and 60 degrees up (a report).
##   no_leak   in FLAME, entered with the globe on in GROUND, the MANDEL sky shows and its
##             uniforms are the same as with SPHERE off.
func _sphere_shots() -> bool:
	var ok := true
	var ms: MandelSky = main.flame_sky.mandel
	var fs: FlameSky = main.flame_sky
	main._go_home()
	main.xr_camera.position = Vector3(0.0, 1.6, 0.0)
	# Turn the left wrist away from the camera so the menu stays closed and out of the down view.
	main.left_hand.position = Vector3(-0.3, 1.0, -0.2)
	main.left_hand.rotation_degrees = Vector3(0.0, 0.0, 180.0)
	main.orbit_on = false
	main.orbit.visible = false
	var saved_beacons: bool = main.guide.enabled
	var saved_sky_idx: int = main.ground_sky_idx
	var saved_near: int = main.ground.near_iter
	main.guide.enabled = false
	main.ground_sphere_idx = 0
	main._apply_ground_look()
	for i in 60:
		await process_frame

	# Flat-floor controls, before SPHERE has ever been on: ahead and down for the round trip,
	# level for the sky comparison.
	main.xr_camera.fov = 95.0
	_look(-18.0)
	for i in 12:
		await process_frame
	var flat_before := _shot("sphere_flat_before")
	# The round trip's controls, reports both. The clipmap alone taken GLOBE_STAGE_BIAS stages
	# coarser and back on the flat floor (what zooming out four times and in again does), and
	# then every level refilled in place with nothing changed. The fill is not bit-repeatable on
	# the set's edge, so any texel computed twice there can tip the other way: refilled, the
	# same floor moves by 0.0005 to 0.001 on its own, and that is all the globe leaves behind.
	var gc: FractalGround = main.ground
	gc._stage_bias = FractalGround.GLOBE_STAGE_BIAS
	gc._sync_stage()
	await _settle_sphere()
	gc._stage_bias = 0
	gc._sync_stage()
	await _settle_sphere()
	for i in 12:
		await process_frame
	var flat_stagetrip := _shot("sphere_flat_stagetrip")
	gc.invalidate()
	await _settle_sphere()
	for i in 12:
		await process_frame
	var refill_diff := _band_diff(flat_stagetrip, root.get_viewport().get_texture().get_image(), 0, flat_stagetrip.get_height())
	main.xr_camera.fov = 85.0
	_look(0.0)
	for i in 12:
		await process_frame
	var flat_hor := root.get_viewport().get_texture().get_image()

	var hide_labels := ["MIRROR", "BEACONS", "TOUR", "ORBIT", "NEAR"]
	var sky_labels := ["SKY", "SKY GLOW"]
	var tiles := {}
	for it in main.menu.items:
		if it.section == "look" and it.label in hide_labels:
			tiles[it.label] = it
		elif it.section == "scene" and it.label in sky_labels and bool(it.visible_when.call()):
			tiles[it.label] = it
	main.ground_sky_idx = 1
	main.ground.near_iter = 256
	main._apply_ground_look()
	for i in 4:
		await process_frame
	var flat_tiles_ok: bool = tiles.size() == hide_labels.size() + sky_labels.size() \
		and main.ground._sky.visible \
		and int(main.ground._material.get_shader_parameter(&"near_iter")) == 256 \
		and not main.ground._stand.visible
	for lbl in hide_labels + sky_labels:
		if not tiles.has(lbl) or not bool(tiles[lbl].visible_when.call()):
			flat_tiles_ok = false
	var sky_flat: bool = fs.is_shown()
	var step_hide_ok := true
	var rclick_ok := true
	var sky_steps := []
	for expect_idx in [1, 2]:
		main._step_ground_sphere(1)
		for i in 4:
			await process_frame
		if main.ground_sphere_idx != expect_idx or main.ground._sky.visible \
				or int(main.ground._material.get_shader_parameter(&"near_iter")) != 0 \
				or not main.ground._stand.visible:
			step_hide_ok = false
		for lbl in hide_labels:
			if tiles.has(lbl) and bool(tiles[lbl].visible_when.call()):
				step_hide_ok = false
		# The bowl keeps the sky and its tiles; the globe hides all three.
		var globe: bool = expect_idx == FractalMain.GROUND_GLOBE
		for lbl in sky_labels:
			if tiles.has(lbl) and bool(tiles[lbl].visible_when.call()) == globe:
				step_hide_ok = false
		sky_steps.append(fs.is_shown())
		var orb0: bool = main.orbit_on
		main._toggle_motion()
		if main.orbit_on != orb0:
			rclick_ok = false
	main._step_ground_sphere(1)   # wraps 2 -> 0 (off)
	for i in 4:
		await process_frame
	var sky_back: bool = fs.is_shown()
	var restore_ok: bool = main.ground_sphere_idx == 0 and main.ground._sky.visible \
		and int(main.ground._material.get_shader_parameter(&"near_iter")) == 256 \
		and not main.ground._stand.visible
	for lbl in hide_labels + sky_labels:
		if not tiles.has(lbl) or not bool(tiles[lbl].visible_when.call()):
			restore_ok = false
	var tiles_ok := flat_tiles_ok and step_hide_ok and restore_ok and rclick_ok
	ok = ok and tiles_ok
	print("MSKYSHOT sphere tiles %s flat=%s hidden=%s restored=%s rclick=%s" % [
		"PASS" if tiles_ok else "FAIL", flat_tiles_ok, step_hide_ok, restore_ok, rclick_ok])
	var sky_ok: bool = sky_flat and sky_steps == [true, false] and sky_back
	ok = ok and sky_ok
	print("MSKYSHOT sphere sky %s shown flat=%s bowl=%s globe=%s back_off=%s" % [
		"PASS" if sky_ok else "FAIL", sky_flat, sky_steps[0], sky_steps[1], sky_back])
	main.ground_sky_idx = saved_sky_idx
	main.ground.near_iter = saved_near
	main._apply_ground_look()
	for i in 8:
		await process_frame

	var h := flat_hor.get_height()
	var wd := flat_hor.get_width()
	var y_mid := h / 2
	# Rows above 0.34 h are more than 13 degrees up at fov 85: sky only, with or without the bowl.
	var upper_end := int(h * 0.34)
	var lower_start := int(h * 0.54)

	var imgs := {}
	var o_hand := Vector3(0.3, 1.0, -0.3)
	var d_down := Vector3(0.0, -0.5, -1.0).normalized()
	var d_wall := Vector3(0.0, 0.15, -1.0).normalized()
	var d_sky := Vector3(0.0, 0.6, -1.0).normalized()
	var d_up := Vector3(0.0, 2.75, -1.0).normalized()
	var saved_rhand_xf: Transform3D = main.right_hand.global_transform
	var exp_r := 2.0
	var exp_hr := 45.0

	for idx in [1, 2]:
		var tag: String = FractalMain.GROUND_SPHERE[idx]
		var globe: bool = idx == FractalMain.GROUND_GLOBE
		main._step_ground_sphere(1)
		main.xr_camera.position = Vector3(0.0, 1.6, 0.0)
		var settled := await _settle_sphere()
		print("MSKYSHOT sphere %s settled after %d frames, cap %.1f m, stage %d" % [
			tag, settled, main.ground._globe_cap_m, main.ground._stage])

		var mat_r: float = float(main.ground._material.get_shader_parameter(&"sphere_radius"))
		var mat_hr: float = float(main.ground._material.get_shader_parameter(&"sphere_horizon_r"))
		var mat_cy: float = float(main.ground._material.get_shader_parameter(&"sphere_centre_y"))
		var mat_gl: float = float(main.ground._material.get_shader_parameter(&"sphere_globe"))
		var mat_ru: float = float(main.ground._material.get_shader_parameter(&"relief_unit"))
		var bias: int = main.ground._stage_bias
		var pan_sc: float = main.ground.sphere_pan_scale()
		var flow_sc: float = main.ground.sphere_flow_scale()
		var exp_bias := FractalGround.GLOBE_STAGE_BIAS if globe else 0
		var uni_ok: bool = is_equal_approx(mat_r, exp_r) and is_equal_approx(mat_hr, exp_hr) \
			and absf(mat_cy - 1.6) < 1e-4 \
			and is_equal_approx(mat_gl, 1.0 if globe else 0.0) and bias == exp_bias \
			and is_equal_approx(mat_ru, 1.0 / float(1 << exp_bias)) \
			and is_equal_approx(pan_sc, exp_hr / (2.0 * exp_r)) \
			and is_equal_approx(flow_sc, minf(1.0, 1.6 / exp_r))
		ok = ok and uni_ok
		print("MSKYSHOT sphere uniform %s %s r=%.2f hr=%.1f cy=%.3f globe=%.0f bias=%d relief_unit=%.3f pan=%.3f flow=%.3f" % [
			tag, "PASS" if uni_ok else "FAIL", mat_r, mat_hr, mat_cy, mat_gl, bias, mat_ru, pan_sc, flow_sc])

		# Ahead: the floor, the horizon and above it the sky (bowl) or the vault (globe).
		main.xr_camera.fov = 95.0
		_look(-18.0)
		for i in 12:
			await process_frame
		imgs["ahead_" + tag] = _shot("sphere_ahead_" + tag)

		# Straight down at the feet, through the standing disc to the nadir.
		main.xr_camera.fov = 100.0
		_look(-88.0)
		for i in 12:
			await process_frame
		imgs["down_" + tag] = _shot("sphere_down_" + tag)

		# FractalGround.update() writes _stand.visible every frame, so the control clears the
		# disc's render layers instead.
		var stand_vis: bool = main.ground._stand.visible
		var stand_layers: int = main.ground._stand.layers
		main.ground._stand.layers = 0
		for i in 4:
			await process_frame
		var down_nostand := root.get_viewport().get_texture().get_image()
		main.ground._stand.layers = stand_layers
		var stand_diff := _band_diff(imgs["down_" + tag], down_nostand, 0, h)
		var stand_ok := stand_vis and stand_diff > 0.0015
		ok = ok and stand_ok
		print("MSKYSHOT sphere stand %s %s vis=%s diff=%.4f" % [
			tag, "PASS" if stand_ok else "FAIL", stand_vis, stand_diff])

		# Straight up: the sky in the bowl, the zenith cap on the globe.
		main.xr_camera.fov = 100.0
		_look(90.0)
		for i in 12:
			await process_frame
		imgs["up_" + tag] = _shot("sphere_up_" + tag)

		# The seam, dead level: the equator is on row h/2 from the centre.
		main.xr_camera.fov = 85.0
		_look(0.0)
		for i in 12:
			await process_frame
		imgs["horizon_" + tag] = _shot("sphere_horizon_" + tag)
		var hor_img: Image = imgs["horizon_" + tag]
		# Step: the rows either side of the horizon. Band: the mean luma of the 6 rows at the
		# horizon against bands 0.04 h to 0.08 h above and below (about 2.7 to 5.4 degrees); a
		# fog colour that neither half shares shows as a dip below both.
		var seam_step := _row_pair_diff(hor_img, y_mid - 3, y_mid + 2)
		var l_seam := 0.0
		for ry in range(y_mid - 3, y_mid + 3):
			l_seam += _band_stats(hor_img, ry, ry + 1).x / 6.0
		var l_up := _band_stats(hor_img, y_mid - int(h * 0.08), y_mid - int(h * 0.04)).x
		var l_dn := _band_stats(hor_img, y_mid + int(h * 0.04), y_mid + int(h * 0.08)).x
		var dip := minf(l_up, l_dn) - l_seam
		var seam_ok := seam_step < 0.03 and dip < 0.04
		var seam_txt := ""
		if globe:
			# The globe's equator is the plane at 45 m, with its own bands and contour lines
			# running through it, so a 5-row step there is content. A seam is a jump in the row
			# means (where oblique content averages out) at the equator against the largest one
			# 12 to 120 rows away on either side.
			var rm := _row_means(hor_img, y_mid - 120, y_mid + 120)
			var near_step := 0.0
			var far_step := 0.0
			for i in range(1, rm.size()):
				var a: Color = rm[i - 1]
				var b: Color = rm[i]
				var d := (absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b)) / 3.0
				if absf(float(i - 120)) <= 8.0:
					near_step = maxf(near_step, d)
				elif absf(float(i - 120)) >= 12.0:
					far_step = maxf(far_step, d)
			# And the plane runs on over the equator: the band above it carries as much detail as
			# the band below. A rim fog left on fades smoothly, so it never steps, but it leaves
			# the band above one flat colour.
			var sd_up := _band_stats(hor_img, y_mid - int(h * 0.08), y_mid - int(h * 0.01)).y
			var sd_dn := _band_stats(hor_img, y_mid + int(h * 0.01), y_mid + int(h * 0.08)).y
			seam_ok = near_step < 1.5 * far_step + 0.004 and dip < 0.04 and sd_up > 0.4 * sd_dn
			seam_txt = " row_step=%.4f elsewhere=%.4f detail up=%.4f down=%.4f" % [
				near_step, far_step, sd_up, sd_dn]
		ok = ok and seam_ok
		print("MSKYSHOT sphere seam %s %s step=%.4f dip=%.4f luma up=%.3f seam=%.3f down=%.3f%s" % [
			tag, "PASS" if seam_ok else "FAIL", seam_step, dip, l_up, l_seam, l_dn, seam_txt])

		if globe:
			# No hole: 45, 70 and 90 degrees up, each against the same view with the ground's
			# layers cleared (the control: that one is all background, every pixel a hole).
			main.xr_camera.fov = 100.0
			var worst := 0.0
			var ctrl_share := 1.0
			for pitch in [45.0, 70.0, 90.0]:
				_look(pitch)
				for i in 8:
					await process_frame
				var img := _shot("sphere_up%d_globe" % int(pitch))
				var ctrl: Image = await _without_ground()
				worst = maxf(worst, _hole_share(img, ctrl))
				ctrl_share = minf(ctrl_share, _hole_share(ctrl, ctrl))
			var hole_ok := worst < 0.0005 and ctrl_share > 0.999
			ok = ok and hole_ok
			print("MSKYSHOT sphere hole %s %s worst=%.5f control=%.3f" % [
				tag, "PASS" if hole_ok else "FAIL", worst, ctrl_share])

			# Cap seam: rings round the zenith from 1.7 to 28 degrees (f tan), across the fade
			# into the far fill (8.6 to 14 degrees at H = 45, about 100 to 170 px here), against
			# the far fill alone. Still looking straight up at 100 degrees from the hole loop.
			var up_img := root.get_viewport().get_texture().get_image()
			var far_img: Image = await _far_fill_only()
			var f_up := 0.5 * float(h) / tan(deg_to_rad(50.0))
			var r0 := int(f_up * tan(deg_to_rad(1.7)))
			var r1 := int(f_up * tan(deg_to_rad(28.0)))
			var rings := _ring_means(up_img, r0, r1)
			var cs := _ring_diff(rings, _ring_means(far_img, r0, r1), r0)
			var own_step := _ring_step(rings, r0)
			var cap_px := Vector2(f_up * tan(2.0 * atan(exp_hr / main.ground._globe_cap_m)),
				f_up * tan(2.0 * atan(exp_hr / (FractalGround.GLOBE_CAP_FADE * main.ground._globe_cap_m))))
			var cap_ok := cs.x < 0.012
			ok = ok and cap_ok
			print("MSKYSHOT sphere cap_seam %s %s diff=%.4f at %d px (fade %.0f to %.0f px) own_step=%.4f at %d px" % [
				tag, "PASS" if cap_ok else "FAIL", cs.x, int(cs.y), cap_px.x, cap_px.y,
				own_step.x, int(own_step.y)])

		# Rays from a hand-like origin against the analytic hits.
		var c_sp := Vector3(0.0, 1.6, 0.0)
		var dirs := {"down": d_down, "wall": d_wall, "sky": d_sky, "up": d_up}
		var ray_ok := true
		var ray_txt := ""
		for k: String in dirs:
			var hit = main.ground.ray_to_plane(o_hand, dirs[k])
			var want = _analytic_sphere_hit(o_hand, dirs[k], c_sp, exp_r, exp_hr, globe)
			var good: bool
			if hit == null or want == null:
				good = hit == null and want == null
			else:
				var tol := maxf(0.05, 1e-4 * (want as Vector2).length())
				good = (hit as Vector2).distance_to(want as Vector2) < tol
			# The bowl's wall is hit, its sky above it is not; the globe hits every one.
			var must_hit: bool = globe or k == "down" or k == "wall"
			if (hit != null) != must_hit:
				good = false
			ray_ok = ray_ok and good
			ray_txt += " %s=%s(%s)" % [k, str(hit), str(want)]
		var sky_zoom_ok := true
		var glide_ok := true
		var glide_txt := ""
		var r0z: float = ms._r
		main._trig_held = [false, true]
		main.right_hand.global_transform = Transform3D(Basis.looking_at(d_wall, Vector3.UP), o_hand)
		main._sky_zoom(0.25)
		var r_wall: float = ms._r
		main.right_hand.global_transform = Transform3D(Basis.looking_at(d_sky, Vector3.UP), o_hand)
		main._sky_zoom(0.25)
		var r_sky: float = ms._r
		main._trig_held = [false, false]
		# The bowl's wall never zooms the sky and the sky above it does; on the globe no ray
		# does, since the sky is hidden.
		sky_zoom_ok = is_equal_approx(r_wall, r0z) \
			and (is_equal_approx(r_sky, r0z) if globe else r_sky < r0z / 1.15)
		ms.home()
		if globe:
			# The trigger 70 degrees up glides toward that hit, as far as glide_to() allows.
			main.ground.stop_glide()
			main.right_hand.global_transform = Transform3D(Basis.looking_at(d_up, Vector3.UP), o_hand)
			main._ground_teleport(main.right_hand)
			var g: Vector2 = main.ground._glide
			var want_up = _analytic_sphere_hit(o_hand, d_up, c_sp, exp_r, exp_hr, true)
			var to_hit: Vector2 = (want_up as Vector2) - main.ground._stand_xz
			var cap_len: float = FractalGround.GLIDE_MAX_M * main.ground.sphere_pan_scale()
			glide_ok = g.length() > 1.0 and g.normalized().dot(to_hit.normalized()) > 0.999 \
				and absf(g.length() - minf(to_hit.length(), cap_len)) < 0.05
			glide_txt = " glide=%s toward=%s" % [str(g), str(to_hit)]
			main.ground.stop_glide()
		main.right_hand.global_transform = saved_rhand_xf
		ray_ok = ray_ok and sky_zoom_ok and glide_ok
		ok = ok and ray_ok
		print("MSKYSHOT sphere ray %s %s%s sky_zoom=%s%s" % [
			tag, "PASS" if ray_ok else "FAIL", ray_txt, sky_zoom_ok, glide_txt])

		# Parallax: the camera steps 0.2 m right; every point on the sphere was R away, so the
		# picture near the middle shifts left by f * 0.2 / R. A centre that rode on the head
		# would leave it where it was.
		main.xr_camera.fov = 75.0
		_look(-22.0)
		main.xr_camera.position = Vector3(0.0, 1.6, 0.0)
		for i in 10:
			await process_frame
		var par0 := root.get_viewport().get_texture().get_image()
		main.xr_camera.position = Vector3(0.2, 1.6, 0.0)
		for i in 10:
			await process_frame
		var par1 := root.get_viewport().get_texture().get_image()
		var f_px := 0.5 * float(h) / tan(deg_to_rad(0.5 * main.xr_camera.fov))
		var exp_shift := -f_px * 0.2 / exp_r
		var la := _luma_rows(par0, y_mid - 120, y_mid + 120, 6)
		var lb := _luma_rows(par1, y_mid - 120, y_mid + 120, 6)
		var got_shift := _best_shift(la, lb, wd, wd / 2, 240, -160, 20)
		var par_ok := absf(float(got_shift) - exp_shift) <= maxf(2.0, absf(exp_shift) * 0.12)
		ok = ok and par_ok
		print("MSKYSHOT sphere parallax %s %s shift=%d px expect=%.1f px" % [
			tag, "PASS" if par_ok else "FAIL", got_shift, exp_shift])

		# Anchor: still 0.2 m across; then 0.1 m down. Then a 1 m step and a 0.6 m crouch,
		# which it follows until it settles. Then back to the centre, re-centred at once.
		var held_xz: bool = main.ground._stand_xz.length() < 0.001
		main.xr_camera.position = Vector3(0.2, 1.5, 0.0)
		for i in 6:
			await process_frame
		var held_y: bool = absf(main.ground._sphere_cy - 1.6) < 0.001 \
			and absf(float(main.ground._material.get_shader_parameter(&"sphere_centre_y")) - 1.6) < 0.001
		main.xr_camera.position = Vector3(1.0, 1.0, 0.0)
		var waited := 0
		while waited < 900 and (main.ground._stand_chasing or main.ground._cy_chasing or waited < 4):
			await process_frame
			waited += 1
		var caught: bool = (main.ground._stand_xz - Vector2(1.0, 0.0)).length() < 0.06 \
			and absf(main.ground._sphere_cy - 1.0) < 0.04
		main.xr_camera.position = Vector3(0.0, 1.6, 0.0)
		main.ground._stand_set = false
		for i in 6:
			await process_frame
		var anchor_ok: bool = held_xz and held_y and caught
		ok = ok and anchor_ok
		print("MSKYSHOT sphere anchor %s %s held_xz=%s held_y=%s caught=%s after %d frames" % [
			tag, "PASS" if anchor_ok else "FAIL", held_xz, held_y, caught, waited])

		if globe:
			# The vault with structure in it: 64x into seahorse valley, ahead, 45 degrees up and
			# straight up. A float32 fill at 512 iterations, light.
			main.ground.set_viewer_fractal(-0.7453, 0.1127)
			main.ground.zoom(64.0 * FractalGround.WPU_BASE / main.ground.wpu)
			await _settle_sphere()
			main.xr_camera.fov = 95.0
			for v in [[-18.0, "ahead"], [45.0, "up45"], [90.0, "up"]]:
				_look(v[0])
				for i in 10:
					await process_frame
				_shot("sphere_%s_globe_64x" % v[1])
			# A report: deep in, the data and the far fill part where the fill's 32 iterations
			# cannot settle the set's edge. This also shows the forcing hook takes.
			var deep := root.get_viewport().get_texture().get_image()
			var deep_far: Image = await _far_fill_only()
			deep_far.save_png("%s/sphere_up_globe_64x_far.png" % OUT)
			var f64 := 0.5 * float(h) / tan(deg_to_rad(47.5))
			var d0 := int(f64 * tan(deg_to_rad(1.7)))
			var d1 := int(f64 * tan(deg_to_rad(28.0)))
			var dd := _ring_diff(_ring_means(deep, d0, d1), _ring_means(deep_far, d0, d1), d0)
			print("MSKYSHOT sphere cap_seam 64x report diff=%.4f at %d px" % [dd.x, int(dd.y)])
			main._go_home()
			await _settle_sphere()

		var down_img: Image = imgs["down_" + tag]
		var ahead_img: Image = imgs["ahead_" + tag]
		var diff_low := _band_diff(flat_hor, hor_img, lower_start, h)
		var diff_up := _band_diff(flat_hor, hor_img, 0, upper_end)
		var st_down := _band_stats(down_img, 0, h)
		var st_ahead := _band_stats(ahead_img, lower_start, h)
		var st_hor := _band_stats(hor_img, lower_start, h)
		var curved := diff_low > 0.04
		# Above 13 degrees the bowl leaves the sky as it was on the flat floor; the globe
		# covers it.
		var top_ok := diff_up > 0.02 if globe else diff_up < 0.015
		var drew := st_down.y > 0.02 and st_down.x > 0.02 and st_ahead.y > 0.02 and st_hor.y > 0.02
		ok = ok and curved and top_ok and drew
		print("MSKYSHOT sphere %s %s diff_low=%.3f diff_up=%.4f down=(%.3f,%.3f) ahead=(%.3f,%.3f) hor=(%.3f,%.3f)" % [
			tag, "PASS" if (curved and top_ok and drew) else "FAIL",
			diff_low, diff_up, st_down.x, st_down.y, st_ahead.x, st_ahead.y, st_hor.x, st_hor.y])

	# Back to flat through the tile, then the same view as before the sphere.
	main._step_ground_sphere(1)   # wraps 2 -> 0
	main.xr_camera.position = Vector3(0.0, 1.6, 0.0)
	await _settle_sphere()
	main.xr_camera.fov = 95.0
	_look(-18.0)
	for i in 12:
		await process_frame
	var flat_after := _shot("sphere_flat_after")
	var rt_diff := _band_diff(flat_before, flat_after, 0, h)
	var trip_diff := _band_diff(flat_stagetrip, flat_after, 0, h)
	var stage_diff := _band_diff(flat_before, flat_stagetrip, 0, h)
	var rt_ok := rt_diff < 0.003
	ok = ok and rt_ok
	print("MSKYSHOT sphere flat_roundtrip %s diff=%.5f vs_stage_trip=%.5f (stage trip alone %.5f, refill in place %.5f)" % [
		"PASS" if rt_ok else "FAIL", rt_diff, trip_diff, stage_diff, refill_diff])

	# The bowl again after the globe and off, against its first shot: nothing the globe set
	# (its flag, the stage bias, the relief unit, the cap, the hidden sky) may stay behind.
	main._step_ground_sphere(1)   # 0 -> 1 (bowl), centred where the camera is now
	main.xr_camera.position = Vector3(0.0, 1.6, 0.0)
	await _settle_sphere()
	# The sky fades back in over FlameSky.FADE_S.
	for i in 90:
		await process_frame
	main.xr_camera.fov = 95.0
	_look(-18.0)
	for i in 12:
		await process_frame
	var bowl_again := _shot("sphere_ahead_bowl_again")
	var brt := _band_diff(imgs["ahead_bowl"], bowl_again, 0, h)
	# The picture cannot see a stage bias left behind from the centre (6 mm texels are finer
	# than the nadir's pixel), so the state the globe sets is read back as well.
	var g2: FractalGround = main.ground
	var left_gl: float = float(g2._material.get_shader_parameter(&"sphere_globe"))
	var left_ru: float = float(g2._material.get_shader_parameter(&"relief_unit"))
	var left_sky: bool = main.flame_sky.is_shown()
	var brt_ok := brt < 0.003 and not g2.sphere_globe and left_gl == 0.0 \
		and g2._stage_bias == 0 and is_equal_approx(left_ru, 1.0) and left_sky
	ok = ok and brt_ok
	print("MSKYSHOT sphere bowl_roundtrip %s diff=%.5f globe=%s/%.0f bias=%d relief_unit=%.3f sky=%s" % [
		"PASS" if brt_ok else "FAIL", brt, g2.sphere_globe, left_gl, g2._stage_bias, left_ru, left_sky])

	# COAST displaced on the bowl, from 0.45 m right of the centre (inside the hold, so the
	# centre stays put), looking level. Only `displace` changes between the frames, so the
	# fragment shading is the same and only the vertices move. COAST's height is 0 on the sea
	# (the set) and climbs with the distance to it, measured from the height under the viewer;
	# standing over the main cardioid puts that at sea level, so every height in view is 0 or
	# more and the relief can only move inward. Inward is nearer this camera, so the picture
	# shifts left. The rim fog starts at 0.99 here so the rows near the rim show the surface
	# rather than the sky's colour, where the taper keeps them nearly still. Nothing reaches
	# the sky.
	var saved_relief: int = main.ground_relief_idx
	var saved_height: int = main.ground_height_idx
	main.ground_relief_idx = FractalMain.GROUND_RELIEF.find("coast")
	main.ground_height_idx = FractalMain.GROUND_HEIGHT.find(1.0)
	main._apply_ground_look()
	# Steep enough that most of the view reaches the 0.25 R clamp: a shift of tens of pixels.
	main.ground.set_look(&"relief_scale", 20.0)
	main.ground._material.set_shader_parameter(&"sphere_fog_start", 0.99)
	main.xr_camera.position = Vector3(0.45, 1.6, 0.0)
	main.xr_camera.fov = 85.0
	_look(0.0)
	for i in 2:
		await process_frame
	main.ground.set_viewer_fractal(-0.2, 0.0)
	for i in 90:
		await process_frame
	var coast_disp := root.get_viewport().get_texture().get_image()
	_shot("sphere_coast_bowl")
	main.ground.set_look(&"displace", 0.0)
	for i in 4:
		await process_frame
	var coast_flat0 := _shot("sphere_coast_bowl_undisplaced")
	for i in 2:
		await process_frame
	var coast_flat1 := root.get_viewport().get_texture().get_image()
	var disp_ctrl := _band_diff(coast_flat0, coast_flat1, lower_start, h)
	var disp_diff := _band_diff(coast_flat0, coast_disp, lower_start, h)
	var rim_diff := _band_diff(coast_flat0, coast_disp, y_mid + 2, y_mid + int(h * 0.04))
	var mid_diff := _band_diff(coast_flat0, coast_disp, y_mid + int(h * 0.12), y_mid + int(h * 0.3))
	var coast_top := _band_diff(coast_flat0, coast_disp, 0, upper_end)
	var coast_held: bool = main.ground._stand_xz.length() < 0.001
	var ca := _luma_rows(coast_flat0, y_mid + int(h * 0.12), y_mid + int(h * 0.3), 4)
	var cb := _luma_rows(coast_disp, y_mid + int(h * 0.12), y_mid + int(h * 0.3), 4)
	var coast_shift := _best_shift(ca, cb, wd, wd / 2, 600, -60, 60)
	var coast_ok := coast_held and disp_diff > maxf(0.006, disp_ctrl * 4.0) and coast_shift <= -3 \
		and rim_diff < mid_diff * 0.15 and coast_top < 0.002
	ok = ok and coast_ok
	print("MSKYSHOT sphere coast %s held=%s diff=%.4f ctrl=%.4f shift=%d px rim=%.4f mid=%.4f top=%.5f" % [
		"PASS" if coast_ok else "FAIL", coast_held, disp_diff, disp_ctrl, coast_shift, rim_diff, mid_diff, coast_top])
	# Relief under the disc: back home (land near the feet), relief steep enough that any rise
	# reaches the 0.25 R clamp, and the fragment painted red wherever the displaced surface is
	# above y = -0.01. Looking straight down, no red may show inside the disc's footprint
	# (25 degrees off the axis from 1.6 m); outside it, the wall above 1.2 m out is red anyway.
	main.xr_camera.position = Vector3(0.0, 1.6, 0.0)
	main.ground._stand_set = false
	main.ground.home()
	main.ground.set_look(&"displace", 1.0)
	main.ground.set_look(&"relief_scale", 400.0)
	var gsh: Shader = main.ground._material.shader
	var painted := gsh.code.replace("ALBEDO = mix(col, fog_colour, fog);",
		"ALBEDO = v_world.y > -0.01 ? vec3(1.0, 0.0, 0.0) : vec3(0.0);")
	var psh := Shader.new()
	psh.code = painted
	main.ground._material.shader = psh
	main.xr_camera.fov = 100.0
	_look(-90.0)
	for i in 40:
		await process_frame
	var clear_img := _shot("sphere_stand_clearance_bowl")
	var foot_px := 0.5 * float(h) / tan(deg_to_rad(50.0)) * tan(deg_to_rad(25.0))
	var red_in := 0
	var red_out := 0
	for y in range(0, h, 4):
		for x in range(0, wd, 4):
			var c := clear_img.get_pixel(x, y)
			if c.r > 0.5 and c.g < 0.3:
				if Vector2(x - wd / 2, y - h / 2).length() < foot_px:
					red_in += 1
				else:
					red_out += 1
	main.ground._material.shader = gsh
	var clear_ok := painted != gsh.code and red_in == 0 and red_out > 0
	ok = ok and clear_ok
	print("MSKYSHOT sphere stand_clear %s red_in=%d red_out=%d" % [
		"PASS" if clear_ok else "FAIL", red_in, red_out])

	main.ground_relief_idx = saved_relief
	main.ground_height_idx = saved_height
	main._apply_ground_look()
	# A frame for the head to be back at the centre before HOME reads it.
	for i in 2:
		await process_frame
	main._go_home()

	await _sphere_cost()

	# No leak: GROUND left with the globe on (no sky there), FLAME under the MANDEL sky, then
	# the same with SPHERE off. The sky must show in FLAME both times, uniforms unchanged.
	main._step_ground_sphere(FractalMain.GROUND_GLOBE - main.ground_sphere_idx)
	for i in 6:
		await process_frame
	var hidden_in_ground: bool = not fs.is_shown()
	main._set_mode("flame")
	for i in 8:
		await process_frame
	var shown_on: bool = fs.is_shown()
	var p_on := _params(ms._mat)
	main._set_mode("ground")
	main._step_ground_sphere(-main.ground_sphere_idx)   # -> 0 (off)
	for i in 6:
		await process_frame
	main._set_mode("flame")
	for i in 8:
		await process_frame
	var shown_off: bool = fs.is_shown()
	var p_off := _params(ms._mat)
	var leaked := []
	for k in p_on:
		if str(p_on[k]) != str(p_off.get(k)):
			leaked.append(k)
	var leak_ok := leaked.is_empty() and p_on.size() > 10 and hidden_in_ground and shown_on and shown_off
	ok = ok and leak_ok
	print("MSKYSHOT sphere no_leak %s uniforms=%d differ=%s hidden_in_ground=%s shown_on=%s shown_off=%s" % [
		"PASS" if leak_ok else "FAIL", p_on.size(), str(leaked), hidden_in_ground, shown_on, shown_off])
	main._set_mode("ground")

	main.guide.enabled = saved_beacons
	for i in 6:
		await process_frame
	return ok


## GPU ms a frame (viewport_get_measured_render_time_gpu) for SPHERE off, bowl and globe under
## the MANDEL sky with the default look, looking level and 60 degrees up, alternated over three
## rounds so the Mac's clock drift lands on all three; each mode's fill settles before it is
## timed. The Mac reports no GPU timestamps, so the frame time at twice the 3D resolution stands
## in (a CPU-bound frame reads the same for all three: the 1x run read 3.7 ms each). Medians,
## and the ratios to flat. A report for Sam to set beside the Quest's numbers:
## the Mac's GPU is not the Quest's, so only the ratios carry over, and loosely.
func _sphere_cost() -> void:
	var vp := root.get_viewport().get_viewport_rid()
	# As undergrowth_shot: no vsync and no frame cap, or the GPU time reads 0 on the Mac.
	var vs := DisplayServer.window_get_vsync_mode()
	var max_fps := Engine.max_fps
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	RenderingServer.viewport_set_measure_render_time(vp, true)
	# At 1600 square the Mac draws the frame faster than the script runs it, so the frame time
	# measures the CPU. Twice the 3D resolution (3200 square, 10 Mpx) makes the GPU the wall.
	var scale3d: float = root.scaling_3d_scale
	root.scaling_3d_scale = 2.0
	main.xr_camera.position = Vector3(0.0, 1.6, 0.0)
	main.xr_camera.fov = 90.0
	var res := {}
	for view in [0.0, 60.0]:
		for idx in [0, 1, 2]:
			res["%d_%d" % [int(view), idx]] = []
			res["w%d_%d" % [int(view), idx]] = []
	for r in 3:
		for idx in [0, 1, 2]:
			main._step_ground_sphere(idx - main.ground_sphere_idx)
			await _settle_sphere()
			for i in 30:
				await process_frame
			for view in [0.0, 60.0]:
				_look(view)
				for i in 15:
					await process_frame
				var g := 0.0
				var w0 := Time.get_ticks_usec()
				for i in 60:
					await process_frame
					g += RenderingServer.viewport_get_measured_render_time_gpu(vp)
				var wall := float(Time.get_ticks_usec() - w0) / 1000.0 / 60.0
				(res["%d_%d" % [int(view), idx]] as Array).append(g / 60.0)
				(res["w%d_%d" % [int(view), idx]] as Array).append(wall)
	for view in [0.0, 60.0]:
		for kind in ["", "w"]:
			var med := []
			for idx in [0, 1, 2]:
				var a: Array = res["%s%d_%d" % [kind, int(view), idx]]
				a.sort()
				med.append(a[1])
			var what := "gpu" if kind == "" else "frame"
			if med[0] <= 0.0:
				print("MSKYSHOT sphere cost view %d deg %s: unavailable" % [int(view), what])
				continue
			print("MSKYSHOT sphere cost view %d deg %s: flat %.3f ms, bowl %.3f ms (%.2fx), globe %.3f ms (%.2fx)" % [
				int(view), what, med[0], med[1], med[1] / med[0], med[2], med[2] / med[0]])
	main._step_ground_sphere(-main.ground_sphere_idx)
	await _settle_sphere()
	DisplayServer.window_set_vsync_mode(vs)
	Engine.max_fps = max_fps
	root.scaling_3d_scale = scale3d
