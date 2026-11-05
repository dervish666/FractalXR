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

		MenuShared.sky(m, vis),
		MenuShared.sky_pick(m, vis),

		MenuShared.detail(m, vis),
		WristMenu.Item.new("look", "JULIA",
			func(): return "from here" if m.ground.julia else "off",
			func():
				if m.ground.julia:
					m.ground.set_julia(false)
				else:
					m.ground.julia_here(),
			false, vis).toggle(func(): return m.ground.julia),
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
				m.ground.set_max_iter(FractalMain.GROUND_ITER[m.ground_iter_idx])),
		WristMenu.Item.new("look", "RELIEF",
			func(): return FractalMain.GROUND_RELIEF[m.ground_relief_idx],
			func():
				m.ground_relief_idx = (m.ground_relief_idx + 1) % FractalMain.GROUND_RELIEF.size()
				m._apply_ground_look(),
			false, vis).stepping(func(d: int):
				m.ground_relief_idx = wrapi(m.ground_relief_idx + d, 0, FractalMain.GROUND_RELIEF.size())
				m._apply_ground_look()),
		WristMenu.Item.new("look", "HEIGHT",
			func():
				var h: float = FractalMain.GROUND_HEIGHT[m.ground_height_idx]
				return "flat" if h == 0.0 else "%.1fx" % h,
			func():
				m.ground_height_idx = (m.ground_height_idx + 1) % FractalMain.GROUND_HEIGHT.size()
				m._apply_ground_look(),
			false, vis).stepping(func(d: int):
				m.ground_height_idx = wrapi(m.ground_height_idx + d, 0, FractalMain.GROUND_HEIGHT.size())
				m._apply_ground_look()),
		WristMenu.Item.new("look", "TEXTURE",
			func(): return "%d%%" % int(FractalMain.GROUND_TEXTURE[m.ground_texture_idx] * 100.0),
			func():
				m.ground_texture_idx = (m.ground_texture_idx + 1) % FractalMain.GROUND_TEXTURE.size()
				m._apply_ground_look(),
			false, vis).stepping(func(d: int):
				m.ground_texture_idx = wrapi(m.ground_texture_idx + d, 0, FractalMain.GROUND_TEXTURE.size())
				m._apply_ground_look()).minor(),
		WristMenu.Item.new("look", "FREQ",
			func(): return "%.1fx" % FractalMain.GROUND_FREQ[m.ground_freq_idx],
			func():
				m.ground_freq_idx = (m.ground_freq_idx + 1) % FractalMain.GROUND_FREQ.size()
				m._apply_ground_look(),
			false, vis).stepping(func(d: int):
				m.ground_freq_idx = wrapi(m.ground_freq_idx + d, 0, FractalMain.GROUND_FREQ.size())
				m._apply_ground_look()).minor(),
		WristMenu.Item.new("look", "HUE",
			func(): return "%.2f" % m.ground_hue,
			func():
				m.ground_hue = fmod(m.ground_hue + 0.125, 1.0)
				m._apply_ground_look(),
			false, vis).stepping(func(d: int):
				m.ground_hue = fposmod(m.ground_hue + 0.125 * d, 1.0)
				m._apply_ground_look()).slider(
			func(): return int(round(m.ground_hue * 8.0)) % 8, 8).minor(),
		WristMenu.Item.new("look", "BUMP",
			func(): return "%.1fx" % FractalMain.GROUND_BUMP[m.ground_bump_idx],
			func():
				m.ground_bump_idx = (m.ground_bump_idx + 1) % FractalMain.GROUND_BUMP.size()
				m._apply_ground_look(),
			false, vis).stepping(func(d: int):
				m.ground_bump_idx = wrapi(m.ground_bump_idx + d, 0, FractalMain.GROUND_BUMP.size())
				m._apply_ground_look()).minor(),
		WristMenu.Item.new("look", "SKY",
			func(): return "off" if FractalMain.GROUND_SKY[m.ground_sky_idx] == 0.0 \
				else "mirror %.0fm" % FractalMain.GROUND_SKY[m.ground_sky_idx],
			func():
				m.ground_sky_idx = (m.ground_sky_idx + 1) % FractalMain.GROUND_SKY.size()
				m._apply_ground_look(),
			false, vis).stepping(func(d: int):
				m.ground_sky_idx = wrapi(m.ground_sky_idx + d, 0, FractalMain.GROUND_SKY.size())
				m._apply_ground_look()).slider(
			func(): return m.ground_sky_idx, FractalMain.GROUND_SKY.size()).minor(),
		WristMenu.Item.new("look", "INSIDE",
			func(): return "room" if m.ground_inside_room and m.passthrough \
				else ("needs room" if m.ground_inside_room else "solid"),
			func():
				m.ground_inside_room = not m.ground_inside_room
				m._apply_ground_look(),
			false, vis).toggle(func(): return m.ground_inside_room).minor(),
		WristMenu.Item.new("look", "HOME",
			func(): return "reset view",
			func(): m.ground.home(),
			false, vis),
		# The orbit of the point under the pointing hand, hung in the air over the map.
		WristMenu.Item.new("look", "ORBIT",
			func(): return "on" if m.orbit_on else "off",
			func():
				m.orbit_on = not m.orbit_on
				m.orbit.visible = false,
			false, vis).toggle(func(): return m.orbit_on),
		# Double the level size and max the iterations: four times the fill for a still
		# that is sharp out to the middle distance. The status line counts it in.
		WristMenu.Item.new("look", "RENDER",
			func(): return "hq 2048 / 4096" if m._render_hq else "normal",
			func(): m._set_render_hq(not m._render_hq),
			false, vis).toggle(func(): return m._render_hq).minor(),
		MenuShared.fovea(m, vis),
		MenuShared.glow(m, vis),

		MenuShared.theme(m, vis),
		MenuShared.cycle(m, vis),
		MenuShared.bands(m, vis),
		MenuShared.exposure(m, vis),
	]
	return out
