extends RefCounted

## GROUND's tiles, in the order GROUND shows them.


static func build(m: FractalMain) -> Array[WristMenu.Item]:
	var vis := func(): return m.ground_mode
	var out: Array[WristMenu.Item] = [
		WristMenu.Item.new("pick", "FAMILIES",
			func(): return m.ground.formula_name(),
			func(): m.ground.set_formula(m.ground.formula + 1),
			false, vis).pictures("ground",
			func(): return m.ground.formula, func(): return FractalGround.FORMULA_NAMES.size(),
			func(i: int): return FractalGround.FORMULA_NAMES[i],
			func(i: int): m.ground.set_formula(i)).as_card(),

		WristMenu.Item.new("scene", "HOME",
			func(): return "start view",
			func(): m.guide.set_tour(false); m.ground.home(),
			false, vis).hinted("Back to where this family opened"),
		MenuShared.sky(m, vis),
		MenuShared.sky_pick(m, vis),
		# MANDEL (mandel_sky.gd): how bright it stands against the floor. Only while it is picked.
		WristMenu.Item.new("scene", "SKY GLOW",
			func(): return m.flame_sky.mandel.gain_name(),
			func(): m.flame_sky.mandel.step_gain(1),
			false, func(): return vis.call() and m.flame_sky.is_mandel()).stepping(
			func(d: int): m.flame_sky.mandel.step_gain(d)).minor().hinted(
			"How bright the Mandelbrot sky shines"),
		MenuShared.turn(m, vis),
		MenuShared.vignette(m, vis),
		WristMenu.Item.new("scene", "SUN",
			func(): return "orbiting" if m.ground.sun_orbit else "fixed",
			func(): m.ground.set_sun_orbit(not m.ground.sun_orbit),
			false, func(): return vis.call() and m._ground_sun_lights()).toggle(
			func(): return m.ground.sun_orbit).minor().hinted(
			"Slowly sweeps the sun across the ridges"),
		MenuShared.lantern(m, vis, "scene"),

		WristMenu.Item.new("look", "JULIA",
			func(): return "from here" if m.ground.julia else "off",
			func():
				if m.ground.julia:
					m.ground.set_julia(false)
				else:
					m.ground.julia_here(),
			false, vis).toggle(func(): return m.ground.julia).hinted(
			"The Julia set of the point you stand on"),
		WristMenu.Item.new("look", "ITER",
			# Past stage 10 the ground raises the count itself (FractalGround.iter_floor);
			# say so, or the tile names a number the fill is not using.
			func(): return str(FractalMain.GROUND_ITER[m.ground_iter_idx]) \
				if m.ground.iter_floor() <= FractalMain.GROUND_ITER[m.ground_iter_idx] \
				else "%d deep" % m.ground.effective_iter(),
			func():
				m.ground_iter_idx = (m.ground_iter_idx + 1) % FractalMain.GROUND_ITER.size()
				m.ground.set_max_iter(FractalMain.GROUND_ITER[m.ground_iter_idx]),
			false, vis).stepping(func(d: int):
				m.ground_iter_idx = wrapi(m.ground_iter_idx + d, 0, FractalMain.GROUND_ITER.size())
				m.ground.set_max_iter(FractalMain.GROUND_ITER[m.ground_iter_idx])).hinted(
			"Detail at deep zoom, slower to fill"),
		WristMenu.Item.new("look", "RELIEF",
			func(): return FractalMain.GROUND_RELIEF[m.ground_relief_idx],
			func(): m._step_ground_relief(1),
			false, vis).stepping(func(d: int): m._step_ground_relief(d)).hinted("How the height is shaped"),
		WristMenu.Item.new("look", "HEIGHT",
			func():
				var h: float = FractalMain.GROUND_HEIGHT[m.ground_height_idx]
				return "flat" if h == 0.0 else "%.1fx" % h,
			func():
				m.ground_height_idx = (m.ground_height_idx + 1) % FractalMain.GROUND_HEIGHT.size()
				m._apply_ground_look(),
			false, vis).stepping(func(d: int):
				m.ground_height_idx = wrapi(m.ground_height_idx + d, 0, FractalMain.GROUND_HEIGHT.size())
				m._apply_ground_look()).hinted("How tall the land stands"),
		WristMenu.Item.new("look", "TEXTURE",
			func(): return "%d%%" % int(FractalMain.GROUND_TEXTURE[m.ground_texture_idx] * 100.0),
			func():
				m.ground_texture_idx = (m.ground_texture_idx + 1) % FractalMain.GROUND_TEXTURE.size()
				m._apply_ground_look(),
			false, vis).stepping(func(d: int):
				m.ground_texture_idx = wrapi(m.ground_texture_idx + d, 0, FractalMain.GROUND_TEXTURE.size())
				m._apply_ground_look()).minor().hinted("Strength of the fine surface pattern"),
		WristMenu.Item.new("look", "FREQ",
			func(): return "%.1fx" % FractalMain.GROUND_FREQ[m.ground_freq_idx],
			func():
				m.ground_freq_idx = (m.ground_freq_idx + 1) % FractalMain.GROUND_FREQ.size()
				m._apply_ground_look(),
			false, vis).stepping(func(d: int):
				m.ground_freq_idx = wrapi(m.ground_freq_idx + d, 0, FractalMain.GROUND_FREQ.size())
				m._apply_ground_look()).minor().hinted("Size of the fine surface pattern"),
		WristMenu.Item.new("look", "HUE",
			func(): return "%.2f" % m.ground_hue,
			func():
				m.ground_hue = fmod(m.ground_hue + 0.125, 1.0)
				m._apply_ground_look(),
			false, vis).stepping(func(d: int):
				m.ground_hue = fposmod(m.ground_hue + 0.125 * d, 1.0)
				m._apply_ground_look()).slider(
			func(): return int(round(m.ground_hue * 8.0)) % 8, 8).minor().hinted("Shifts the colours round"),
		WristMenu.Item.new("look", "BUMP",
			func(): return "%.1fx" % FractalMain.GROUND_BUMP[m.ground_bump_idx],
			func():
				m.ground_bump_idx = (m.ground_bump_idx + 1) % FractalMain.GROUND_BUMP.size()
				m._apply_ground_look(),
			false, vis).stepping(func(d: int):
				m.ground_bump_idx = wrapi(m.ground_bump_idx + d, 0, FractalMain.GROUND_BUMP.size())
				m._apply_ground_look()).minor().hinted("How bumpy the surface looks"),
		# The ground mirrored overhead as a ceiling. SKY is the baked sky, in every mode.
		WristMenu.Item.new("look", "MIRROR",
			func(): return "off" if FractalMain.GROUND_SKY[m.ground_sky_idx] == 0.0 \
				else "%.0f m up" % FractalMain.GROUND_SKY[m.ground_sky_idx],
			func():
				m.ground_sky_idx = (m.ground_sky_idx + 1) % FractalMain.GROUND_SKY.size()
				m._apply_ground_look(),
			false, vis).stepping(func(d: int):
				m.ground_sky_idx = wrapi(m.ground_sky_idx + d, 0, FractalMain.GROUND_SKY.size())
				m._apply_ground_look()).slider(
			func(): return m.ground_sky_idx, FractalMain.GROUND_SKY.size()).minor().hinted(
			"The ground mirrored overhead as a ceiling"),
		# The set's filled inside: drawn solid, or hollow, open onto the room through passthrough.
		WristMenu.Item.new("look", "HOLLOW",
			func(): return "needs PASSTHRU" if m.ground_inside_room and not m.passthrough \
				else ("on" if m.ground_inside_room else "off"),
			func():
				m.ground_inside_room = not m.ground_inside_room
				m._apply_ground_look(),
			false, vis).toggle(func(): return m.ground_inside_room).minor().hinted(
			"The black inside shows your room"),
		# Light pillars on the small copies of the set near you; the trigger on one flies you
		# there. Mandelbrot only: the other families have no Newton to find them by.
		WristMenu.Item.new("look", "BEACONS",
			func(): return "on" if m.guide.enabled else "off",
			func(): m.guide.enabled = not m.guide.enabled,
			false, func(): return vis.call() and m.guide.applies()).toggle(
			func(): return m.guide.enabled).hinted("Lights the small copies of the set near you"),
		WristMenu.Item.new("look", "TOUR",
			func(): return "on" if m.guide.tour else "off",
			func(): m.guide.set_tour(not m.guide.tour),
			false, func(): return vis.call() and m.guide.applies()).toggle(
			func(): return m.guide.tour).hinted("Flies you from one copy to the next by itself"),
		# The orbit of the point under the pointing hand, hung in the air over the map.
		WristMenu.Item.new("look", "ORBIT",
			func(): return "on" if m.orbit_on else "off",
			func():
				m.orbit_on = not m.orbit_on
				m.orbit.visible = false,
			false, vis).toggle(func(): return m.orbit_on).hinted(
			"Draws the path of the point you aim at"),
		# Double the level size and max the iterations: four times the fill for a still
		# that is sharp out to the middle distance. The status line counts it in.
		WristMenu.Item.new("look", "SHARPEST",
			func(): return "on" if m._render_hq else "off",
			func(): m._set_render_hq(not m._render_hq),
			false, vis).toggle(func(): return m._render_hq).minor().hinted(
			"Sharp far detail for stills, slow to fill"),
		# NEAR: the escape count worked per pixel where a texel spans several pixels near the
		# set (fractal_ground.gd NEAR_STEPS). The budget is iterations a pixel.
		WristMenu.Item.new("look", "NEAR",
			func(): return "off" if m.ground.near_iter == 0 else "%d" % m.ground.near_iter,
			func(): m.ground.near_iter = FractalGround.NEAR_STEPS[
				(FractalGround.NEAR_STEPS.find(m.ground.near_iter) + 1) % FractalGround.NEAR_STEPS.size()],
			false, vis).stepping(func(d: int): m.ground.near_iter = FractalGround.NEAR_STEPS[
				wrapi(FractalGround.NEAR_STEPS.find(m.ground.near_iter) + d, 0, FractalGround.NEAR_STEPS.size())]).hinted(
			"Pixel-sharp detail close to you, costs frame time"),
		# The frame-time dial goes after what the ground looks like, not ahead of it.
		MenuShared.detail(m, vis),
		MenuShared.fovea(m, vis),
		MenuShared.glow(m, vis),

		MenuShared.art(m, vis),
		MenuShared.theme(m, vis),
		MenuShared.cycle(m, vis),
		MenuShared.bands(m, vis),
		MenuShared.exposure(m, vis),
	]
	return out
