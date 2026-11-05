extends RefCounted

## BULB's tiles, in the order BULB shows them.


static func build(m: FractalMain) -> Array[WristMenu.Item]:
	var vis := func(): return m.bulb_mode
	var out: Array[WristMenu.Item] = [
		WristMenu.Item.new("pick", "BULBS",
			func(): return str(m.library.bulbs[m.bulb_idx].get("name", "?")),
			func(): m._load_bulb(m.bulb_idx + 1),
			false, vis).pictures("bulb",
			func(): return m.bulb_idx, func(): return m.library.bulbs.size(),
			func(i: int): return str(m.library.bulbs[i].get("name", "?")),
			func(i: int): m._load_bulb(i)).as_card(),

		MenuShared.drift(m, vis),
		MenuShared.spin(m, vis),
		MenuShared.centre(m, vis),
		MenuShared.sky(m, vis),
		MenuShared.sky_pick(m, vis),

		MenuShared.splat(m, vis),
		MenuShared.adapt(m, vis),
		MenuShared.solid(m, vis),
		MenuShared.motion(m, vis),
		WristMenu.Item.new("look", "BAKE",
			func():
				if m.cloud.is_baking():
					return "%d%%" % int(m.cloud.bake_progress * 100.0)
				if not m.auto_bake:
					return "off"
				return "on" if m.cloud.bake_ready else "wait",
			func():
				m.auto_bake = not m.auto_bake
				if m.auto_bake:
					RenderingServer.call_on_render_thread(m.cloud.bake)
				else:
					m.cloud.clear_bake(),
			false, vis).toggle(func(): return m.auto_bake).minor(),
		WristMenu.Item.new("look", "LINES",
			func(): return "off" if m._line_slices() == 0 else "%d %s" % [m._line_slices(),
				FractalMain.LINE_PATTERNS[m.line_pattern_idx]],
			func(): m._step_lines(1),
			false, vis).stepping(func(d: int): m._step_lines(d)),
		# Only while LINES is on: with it off there are no lines to pattern or thin.
		WristMenu.Item.new("look", "PATTERN",
			func(): return FractalMain.LINE_PATTERNS[m.line_pattern_idx],
			func(): m._step_line_pattern(1),
			false, func(): return m.bulb_mode and m._line_slices() > 0).stepping(
			func(d: int): m._step_line_pattern(d)),
		WristMenu.Item.new("look", "WIDTH",
			func(): return FractalMain.LINE_WIDTH_NAMES[m.line_width_idx],
			func(): m._step_line_width(1),
			false, func(): return m.bulb_mode and m._line_slices() > 0).stepping(
			func(d: int): m._step_line_width(d)).slider(
			func(): return m.line_width_idx, FractalMain.LINE_WIDTHS.size()).minor(),
		WristMenu.Item.new("look", "BREATHE",
			func():
				# A frozen cloud cannot show a moving surface, so say so rather than
				# reporting a rate that nothing is acting on.
				if FractalMain.BULB_STABILITY[m.bulb_stability_idx] == 0:
					return "held"
				return "off" if FractalMain.BREATH_STEPS[m.breath_idx] == 0.0 \
					else "%.0fx" % FractalMain.BREATH_STEPS[m.breath_idx],
			func(): m.breath_idx = (m.breath_idx + 1) % FractalMain.BREATH_STEPS.size(),
			false, vis).stepping(func(d: int):
				m.breath_idx = wrapi(m.breath_idx + d, 0, FractalMain.BREATH_STEPS.size())),
		# Splats or a raymarched surface. The ms readout in the footer is the verdict.
		WristMenu.Item.new("look", "SURFACE",
			func():
				if FractalMain.SURFACE_SOLID[m.surface_idx] > 0:
					if m.solid.is_building():
						return "growing %d%%" % int(m.solid.progress() * 100.0)
					if m.solid.is_ready():
						return "solid %dk" % int(m.solid.tri_count / 1000)
					if m.solid.get_error() != "":
						return "solid failed"
				return FractalMain.SURFACE_NAMES[m.surface_idx],
			func():
				m.surface_idx = (m.surface_idx + 1) % FractalMain.SURFACE_STEPS.size()
				m._apply_surface(),
			false, vis).stepping(func(d: int):
				m.surface_idx = wrapi(m.surface_idx + d, 0, FractalMain.SURFACE_STEPS.size())
				m._apply_surface()).slider(func(): return m.surface_idx, FractalMain.SURFACE_STEPS.size()),
		# ENTER (stand inside the shape at its roomiest hollow) is not on the headset menu.
		# Measured 2026-09-12: 85-103 ms GPU at 48 steps on a 0.6x eye buffer, every pixel
		# of both eyes marching, and the bail-out left the renderer in a broken pipeline
		# state that the GPU then faulted on. _enter_inside() stays for the desktop shot
		# harness and for the day the interior gets a quarter-res pass with reprojection.
		MenuShared.detail(m, vis),
		MenuShared.fovea(m, vis),
		MenuShared.glow(m, vis),

		MenuShared.theme(m, vis),
		MenuShared.cycle(m, vis),
		MenuShared.auto(m, vis),
		MenuShared.bands(m, vis),
		MenuShared.bright(m, vis),
		MenuShared.exposure(m, vis),
	]
	return out
