class_name MenuShared
extends RefCounted

## The tiles that show in more than one mode. Each mode's list asks for its own copy, with
## that mode's visibility, so a mode file reads top to bottom as exactly what the mode shows
## and in the order it shows it. A copy hidden in every other mode costs one visibility call
## a refresh and nothing else.


static func drift(m: FractalMain, vis: Callable) -> WristMenu.Item:
	return WristMenu.Item.new("scene", "DRIFT",
		func(): return "on" if m._drift else "off",
		func(): m._drift = not m._drift; m._drift_hold = 0.0,
		false, vis).toggle(func(): return m._drift)


static func spin(m: FractalMain, vis: Callable) -> WristMenu.Item:
	return WristMenu.Item.new("scene", "SPIN",
		func(): return "on" if m.spin else "off", func(): m.spin = not m.spin,
		false, vis).toggle(func(): return m.spin)


static func centre(m: FractalMain, vis: Callable) -> WristMenu.Item:
	return WristMenu.Item.new("scene", "CENTRE",
		func(): return "reset", func(): m._recenter(); m.cloud.request_measure(),
		false, vis)


## SKY hangs or hides the baked sky in every mode (BULB keeps its own switch as well).
static func sky(m: FractalMain, vis: Callable) -> WristMenu.Item:
	return WristMenu.Item.new("scene", "SKY",
		func(): return m._sky_label(),
		func(): m._toggle_sky(), false, vis).toggle(func(): return m._sky_switch())


## Which sky: the live bake of a flame, or one of the skies pre-rendered on the Mac
## (art/skies/), which need no bake and so are there in BULB from the start.
static func sky_pick(m: FractalMain, vis: Callable) -> WristMenu.Item:
	return WristMenu.Item.new("scene", "SKY PICK",
		func(): return m.flame_sky.pick_name(),
		func(): m._step_sky_pick(1),
		false, func(): return vis.call() and not m.flame_sky.presets.is_empty()).stepping(
		func(d: int): m._step_sky_pick(d))


static func splat(m: FractalMain, vis: Callable) -> WristMenu.Item:
	return WristMenu.Item.new("look", "SPLAT",
		func():
			if m.bulb_mode:
				return "%.1fx cover" % FractalMain.BULB_COVERAGE[m.coverage_idx]
			return "%.0fmm" % (FractalMain.SPLAT_STEPS[m.splat_idx] * 1000.0) if m.splat_on else "off",
		func():
			if m.bulb_mode:
				m.coverage_idx = (m.coverage_idx + 1) % FractalMain.BULB_COVERAGE.size()
			elif not m.splat_on:
				m.splat_on = true
			else:
				m.splat_idx = (m.splat_idx + 1) % FractalMain.SPLAT_STEPS.size()
				if m.splat_idx == 0:
					m.splat_on = false
			m._apply_point_look(),
		false, vis).stepping(func(d: int):
			if m.bulb_mode:
				m.coverage_idx = wrapi(m.coverage_idx + d, 0, FractalMain.BULB_COVERAGE.size())
			else:
				# One ladder: off, then every size. Scrubbing left from the first
				# size lands on off, not on the largest splat.
				var cur: int = (m.splat_idx + 1) if m.splat_on else 0
				var nxt := wrapi(cur + d, 0, FractalMain.SPLAT_STEPS.size() + 1)
				m.splat_on = nxt > 0
				m.splat_idx = maxi(0, nxt - 1)
			m._apply_point_look()).minor()


static func adapt(m: FractalMain, vis: Callable) -> WristMenu.Item:
	return WristMenu.Item.new("look", "ADAPT",
		func(): return "%d%%" % int(FractalMain.DENSITY_STEPS[m.density_idx] * 100.0),
		func():
			m.density_idx = (m.density_idx + 1) % FractalMain.DENSITY_STEPS.size()
			m._apply_point_look(),
		false, vis).stepping(func(d: int):
			m.density_idx = wrapi(m.density_idx + d, 0, FractalMain.DENSITY_STEPS.size())
			m._apply_point_look()).minor()


## Splat opacity. Hidden while SURFACE is a solid mesh: it does nothing there, and two
## things called solid on one card would be one too many.
static func solid(m: FractalMain, vis: Callable) -> WristMenu.Item:
	return WristMenu.Item.new("look", "SOLID",
		func(): return "%d%%" % int(FractalMain.OPACITY_STEPS[m.opacity_idx] * 100.0),
		func():
			m.opacity_idx = (m.opacity_idx + 1) % FractalMain.OPACITY_STEPS.size()
			m._apply_point_look(),
		false, func(): return vis.call() and FractalMain.SURFACE_SOLID[m.surface_idx] == 0).stepping(
		func(d: int):
			m.opacity_idx = wrapi(m.opacity_idx + d, 0, FractalMain.OPACITY_STEPS.size())
			m._apply_point_look()).slider(func(): return m.opacity_idx, FractalMain.OPACITY_STEPS.size())


static func motion(m: FractalMain, vis: Callable) -> WristMenu.Item:
	return WristMenu.Item.new("look", "MOTION",
		func():
			var n: int = FractalMain.BULB_STABILITY[m.bulb_stability_idx] if m.bulb_mode \
				else FractalMain.STABILITY[m.stability_idx]
			return "frozen" if n == 0 else "1/%d" % n,
		func():
			if m.bulb_mode:
				m.bulb_stability_idx = (m.bulb_stability_idx + 1) % FractalMain.BULB_STABILITY.size()
				# No settle: a running cloud is already projected. Just refresh the
				# bake so a freeze stops with shapes that describe where things ARE.
				if FractalMain.BULB_STABILITY[m.bulb_stability_idx] == 0:
					m._bake_wait = FractalMain.BAKE_DELAY_FRAMES
			else:
				m.stability_idx = (m.stability_idx + 1) % FractalMain.STABILITY.size(),
		false, vis).stepping(func(d: int):
			if m.bulb_mode:
				m.bulb_stability_idx = wrapi(m.bulb_stability_idx + d, 0, FractalMain.BULB_STABILITY.size())
				if FractalMain.BULB_STABILITY[m.bulb_stability_idx] == 0:
					m._bake_wait = FractalMain.BAKE_DELAY_FRAMES
			else:
				m.stability_idx = wrapi(m.stability_idx + d, 0, FractalMain.STABILITY.size())).slider(
		func(): return m.bulb_stability_idx if m.bulb_mode else m.stability_idx,
		FractalMain.BULB_STABILITY.size())


## The eye buffer's scale. Not in IFS, where a recursion rung has the name.
static func detail(m: FractalMain, vis: Callable) -> WristMenu.Item:
	return WristMenu.Item.new("look", "DETAIL",
		func(): return "%.2fx" % (FractalMain.MARCH_RENDER_SCALE if m.march.is_on()
			else FractalMain.RENDER_STEPS[m.render_idx]),
		func(): m._step_detail(1),
		false, vis).stepping(func(d: int): m._step_detail(d)).slider(
		func(): return m.render_idx, FractalMain.RENDER_STEPS.size())


## Fixed foveated rendering, the largest fragment-cost lever on a Quest. Off by
## default because the cloud showed it at the edges; this dial is the instrument
## for measuring it per mode (ground and tree may take it for free). Applied a
## frame later, on its own: changing it in the same frame as the eye buffer broke
## the framebuffer (2026-09-12 log).
static func fovea(m: FractalMain, vis: Callable) -> WristMenu.Item:
	return WristMenu.Item.new("look", "FOVEA",
		func(): return "off" if m.fovea_idx == 0 else "fixed %d" % FractalMain.FOVEA_STEPS[m.fovea_idx],
		func():
			m.fovea_idx = (m.fovea_idx + 1) % FractalMain.FOVEA_STEPS.size()
			m.call_deferred("_apply_foveation"),
		false, vis).stepping(func(d: int):
			m.fovea_idx = wrapi(m.fovea_idx + d, 0, FractalMain.FOVEA_STEPS.size())
			m.call_deferred("_apply_foveation")).slider(
		func(): return m.fovea_idx, FractalMain.FOVEA_STEPS.size()).minor()


## Glow is a downsample/blur/upsample chain per eye on a tiler, and its cost has
## never been measured. This toggle is the instrument: flip it and read the ms.
static func glow(m: FractalMain, vis: Callable) -> WristMenu.Item:
	return WristMenu.Item.new("look", "GLOW",
		func(): return "on" if m._env().glow_enabled else "off",
		func(): m._env().glow_enabled = not m._env().glow_enabled,
		false, vis).toggle(func(): return m._env().glow_enabled).minor()


static func theme(m: FractalMain, vis: Callable) -> WristMenu.Item:
	return WristMenu.Item.new("colour", "THEME",
		func():
			if m.recolor_on_drift:
				return "auto %d" % (m.theme_idx + 1) if m.theme_idx >= 0 else "auto"
			return "theme %d" % (m.theme_idx + 1) if m.theme_idx >= 0 else "preset",
		func(): m._cycle_theme(), false, vis).stepping(func(d: int): m._cycle_theme(d)).gallery(
		func(): return m.theme_idx + 1, func(): return m.library.themes.size() + 1, m._theme_swatch)


## Every mode's palette scrolling through its ramp. Beside THEME because it is the same
## palette moving, and like THEME it is on this card in every mode.
static func cycle(m: FractalMain, vis: Callable) -> WristMenu.Item:
	return WristMenu.Item.new("colour", "CYCLE",
		func(): return m._cycle_label(),
		func(): m._step_cycle(1), false, vis).stepping(func(d: int): m._step_cycle(d))


static func auto(m: FractalMain, vis: Callable) -> WristMenu.Item:
	return WristMenu.Item.new("colour", "AUTO",
		func(): return "on" if m.recolor_on_drift else "off",
		func(): m.recolor_on_drift = not m.recolor_on_drift,
		false, vis).toggle(func(): return m.recolor_on_drift).minor()


static func bands(m: FractalMain, vis: Callable) -> WristMenu.Item:
	return WristMenu.Item.new("colour", "BANDS",
		func(): return "%dx" % int(FractalMain.COLOUR_CYCLES[m.colour_idx]),
		func():
			m.colour_idx = (m.colour_idx + 1) % FractalMain.COLOUR_CYCLES.size()
			m._apply_point_look(), false, vis).stepping(func(d: int):
			m.colour_idx = wrapi(m.colour_idx + d, 0, FractalMain.COLOUR_CYCLES.size())
			m._apply_point_look()).slider(
		func(): return m.colour_idx, FractalMain.COLOUR_CYCLES.size()).minor()


static func bright(m: FractalMain, vis: Callable) -> WristMenu.Item:
	return WristMenu.Item.new("colour", "BRIGHT",
		func(): return "%.3f" % FractalMain.BRIGHT_STEPS[m.bright_idx],
		func():
			m.bright_idx = (m.bright_idx + 1) % FractalMain.BRIGHT_STEPS.size()
			m._apply_point_look(),
		false, vis).stepping(func(d: int):
			m.bright_idx = wrapi(m.bright_idx + d, 0, FractalMain.BRIGHT_STEPS.size())
			m._apply_point_look()).slider(func(): return m.bright_idx, FractalMain.BRIGHT_STEPS.size())


static func exposure(m: FractalMain, vis: Callable) -> WristMenu.Item:
	return WristMenu.Item.new("colour", "EXPOSURE",
		func(): return "%.0fx" % FractalMain.EXPOSURE_MUL[m.exposure_idx],
		func():
			m.exposure_idx = (m.exposure_idx + 1) % FractalMain.EXPOSURE_MUL.size()
			m._apply_exposure(), false, vis).stepping(func(d: int):
			m.exposure_idx = wrapi(m.exposure_idx + d, 0, FractalMain.EXPOSURE_MUL.size())
			m._apply_exposure()).slider(
		func(): return m.exposure_idx, FractalMain.EXPOSURE_MUL.size())
