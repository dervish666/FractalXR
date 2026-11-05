class_name MenuShared
extends RefCounted

## The tiles that show in more than one mode. Each mode's list asks for its own copy, with
## that mode's visibility, so a mode file reads top to bottom as exactly what the mode shows
## and in the order it shows it. A copy hidden in every other mode costs one visibility call
## a refresh and nothing else.


## presets.json carries the theme palettes without their names; these are src/flame/palettes.ts
## THEMES in the same order. A count mismatch falls back to numbers rather than wrong names.
const THEME_NAMES := ["Ember", "Ice", "Inferno", "Neon", "Spectrum", "Nebula", "Sunset", "Aurora",
	"Toxic", "Ocean", "Rose", "Violet", "FireIce", "Candy", "Rainbow", "Prism", "Vaporwave", "Acid",
	"Iridescent", "Autumn", "Lagoon", "Sakura", "Patina", "Peacock", "Jungle", "Abyss"]
## One word per BRIGHT_STEPS rung. The default rung (0.05) is the one called normal.
const BRIGHT_NAMES := ["faint", "dim", "normal", "bright", "vivid", "blazing", "max"]


## ADAPT, AA, FOVEA and GLOW are measurement instruments, not settings: debug builds only,
## like the fps footer, so a release menu never offers them.
static func dev_only(vis: Callable) -> Callable:
	return func(): return OS.is_debug_build() and vis.call()


static func drift(m: FractalMain, vis: Callable) -> WristMenu.Item:
	return WristMenu.Item.new("scene", "DRIFT",
		func(): return "on" if m._drift else "off",
		func(): m._drift = not m._drift; m._drift_hold = 0.0,
		false, vis).toggle(func(): return m._drift).hinted("Moves on to the next one by itself")


static func spin(m: FractalMain, vis: Callable) -> WristMenu.Item:
	return WristMenu.Item.new("scene", "SPIN",
		func(): return "on" if m.spin else "off", func(): m.spin = not m.spin,
		false, vis).toggle(func(): return m.spin).hinted("Turns it slowly")


## HOME is the pose word everywhere, as on the X button; RESET is kept for the IFS shape.
static func home(m: FractalMain, vis: Callable) -> WristMenu.Item:
	return WristMenu.Item.new("scene", "HOME",
		func(): return "in front of you", func(): m._recenter(); m.cloud.request_measure(),
		false, vis).hinted("Brings it back in front of you")


## SKY hangs or hides the baked sky in every mode (BULB keeps its own switch as well).
static func sky(m: FractalMain, vis: Callable) -> WristMenu.Item:
	return WristMenu.Item.new("scene", "SKY",
		func(): return m._sky_label(),
		func(): m._toggle_sky(), false, vis).toggle(func(): return m._sky_switch()).hinted(
		"Shows or hides the sky round you")


## Which sky: the live bake of a flame, or one of the skies pre-rendered on the Mac
## (art/skies/), which need no bake and so are there in BULB from the start.
static func sky_pick(m: FractalMain, vis: Callable) -> WristMenu.Item:
	return WristMenu.Item.new("scene", "SKY PICK",
		func(): return m.flame_sky.pick_name(),
		func(): m._step_sky_pick(1),
		false, func(): return vis.call() and not m.flame_sky.presets.is_empty()).stepping(
		func(d: int): m._step_sky_pick(d)).hinted("Which sky hangs round you")


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
			m._apply_point_look()).minor().hinted("Size of each soft point")


static func adapt(m: FractalMain, vis: Callable) -> WristMenu.Item:
	return WristMenu.Item.new("look", "ADAPT",
		func(): return "%d%%" % int(FractalMain.DENSITY_STEPS[m.density_idx] * 100.0),
		func():
			m.density_idx = (m.density_idx + 1) % FractalMain.DENSITY_STEPS.size()
			m._apply_point_look(),
		false, dev_only(vis)).stepping(func(d: int):
			m.density_idx = wrapi(m.density_idx + d, 0, FractalMain.DENSITY_STEPS.size())
			m._apply_point_look()).minor().hinted("Thins points where they pile up")


## Splat opacity. Hidden while SURFACE is a solid mesh, where it does nothing.
static func opacity(m: FractalMain, vis: Callable) -> WristMenu.Item:
	return WristMenu.Item.new("look", "OPACITY",
		func(): return "%d%%" % int(FractalMain.OPACITY_STEPS[m.opacity_idx] * 100.0),
		func():
			m.opacity_idx = (m.opacity_idx + 1) % FractalMain.OPACITY_STEPS.size()
			m._apply_point_look(),
		false, func(): return vis.call() and FractalMain.SURFACE_SOLID[m.surface_idx] == 0).stepping(
		func(d: int):
			m.opacity_idx = wrapi(m.opacity_idx + d, 0, FractalMain.OPACITY_STEPS.size())
			m._apply_point_look()).slider(func(): return m.opacity_idx, FractalMain.OPACITY_STEPS.size()).hinted(
		"How see-through each point is")


## How much of the cloud re-settles each frame: none (frozen), all of it, or one point in n.
## A calmer cloud shimmers less. IFS has its own MOTION, which is breathing.
static func steady(m: FractalMain, vis: Callable) -> WristMenu.Item:
	return WristMenu.Item.new("look", "STEADY",
		func():
			var n: int = FractalMain.BULB_STABILITY[m.bulb_stability_idx] if m.bulb_mode \
				else FractalMain.STABILITY[m.stability_idx]
			if n == 0:
				return "frozen"
			return "all moving" if n == 1 else "1 in %d moving" % n,
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
		FractalMain.BULB_STABILITY.size()).hinted("Fewer points moving, less shimmer")


## The eye buffer's scale. Not on IFS's menu, which left it off while its recursion tile was
## also called DETAIL; that tile is LEVELS now, so putting it back is one line in
## ifs_items.gd. Nothing on the controller steps it in any mode (the right menu button is the Quest system button and
## never reaches the app); on the desktop KEY_6 does.
static func detail(m: FractalMain, vis: Callable) -> WristMenu.Item:
	return WristMenu.Item.new("look", "DETAIL",
		func(): return "%.2fx" % (FractalMain.MARCH_RENDER_SCALE if m.march.is_on()
			else FractalMain.RENDER_STEPS[m.render_idx]),
		func(): m._step_detail(1),
		false, vis).stepping(func(d: int): m._step_detail(d)).slider(
		func(): return m.render_idx, FractalMain.RENDER_STEPS.size()).hinted(
		"Sharper picture, more frame time")


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
		false, dev_only(vis)).stepping(func(d: int):
			m.fovea_idx = wrapi(m.fovea_idx + d, 0, FractalMain.FOVEA_STEPS.size())
			m.call_deferred("_apply_foveation")).slider(
		func(): return m.fovea_idx, FractalMain.FOVEA_STEPS.size()).minor().hinted(
		"Less detail at the edges of view")


## Glow is a downsample/blur/upsample chain per eye on a tiler, and its cost has
## never been measured. This toggle is the instrument: flip it and read the ms.
static func glow(m: FractalMain, vis: Callable) -> WristMenu.Item:
	return WristMenu.Item.new("look", "GLOW",
		func(): return "on" if m._env().glow_enabled else "off",
		func(): m._env().glow_enabled = not m._env().glow_enabled,
		false, dev_only(vis)).toggle(func(): return m._env().glow_enabled).minor().hinted(
		"Soft glow round bright parts")


static func theme(m: FractalMain, vis: Callable) -> WristMenu.Item:
	return WristMenu.Item.new("colour", "THEME",
		func():
			var nm := theme_name(m)
			if m.recolor_on_drift:
				return "auto · %s" % nm if m.theme_idx >= 0 else "auto"
			return nm,
		func(): m._cycle_theme(), false, vis).stepping(func(d: int): m._cycle_theme(d)).gallery(
		func(): return m.theme_idx + 1, func(): return m.library.themes.size() + 1, m._theme_swatch
		).hinted("The colours")


static func theme_name(m: FractalMain) -> String:
	if m.theme_idx < 0:
		return "original"
	if m.library.themes.size() == THEME_NAMES.size():
		return THEME_NAMES[m.theme_idx]
	return "theme %d" % (m.theme_idx + 1)


## Every mode's palette scrolling through its ramp. Beside THEME because it is the same
## palette moving, and like THEME it is on this card in every mode.
static func cycle(m: FractalMain, vis: Callable) -> WristMenu.Item:
	return WristMenu.Item.new("colour", "CYCLE",
		func(): return m._cycle_label(),
		func(): m._step_cycle(1), false, vis).stepping(func(d: int): m._step_cycle(d)).hinted(
		"Scrolls the colours along the shape")


static func auto(m: FractalMain, vis: Callable) -> WristMenu.Item:
	return WristMenu.Item.new("colour", "AUTO",
		func(): return "on" if m.recolor_on_drift else "off",
		func(): m.recolor_on_drift = not m.recolor_on_drift,
		false, vis).toggle(func(): return m.recolor_on_drift).minor().hinted(
		"A new theme with each new shape")


static func bands(m: FractalMain, vis: Callable) -> WristMenu.Item:
	return WristMenu.Item.new("colour", "BANDS",
		func(): return "%dx" % int(FractalMain.COLOUR_CYCLES[m.colour_idx]),
		func():
			m.colour_idx = (m.colour_idx + 1) % FractalMain.COLOUR_CYCLES.size()
			m._apply_point_look(), false, vis).stepping(func(d: int):
			m.colour_idx = wrapi(m.colour_idx + d, 0, FractalMain.COLOUR_CYCLES.size())
			m._apply_point_look()).slider(
		func(): return m.colour_idx, FractalMain.COLOUR_CYCLES.size()).minor().hinted(
		"How many times the colours repeat")


static func bright(m: FractalMain, vis: Callable) -> WristMenu.Item:
	return WristMenu.Item.new("colour", "BRIGHT",
		func(): return BRIGHT_NAMES[m.bright_idx] if BRIGHT_NAMES.size() == FractalMain.BRIGHT_STEPS.size() \
			else "%.3f" % FractalMain.BRIGHT_STEPS[m.bright_idx],
		func():
			m.bright_idx = (m.bright_idx + 1) % FractalMain.BRIGHT_STEPS.size()
			m._apply_point_look(),
		false, vis).stepping(func(d: int):
			m.bright_idx = wrapi(m.bright_idx + d, 0, FractalMain.BRIGHT_STEPS.size())
			m._apply_point_look()).slider(func(): return m.bright_idx, FractalMain.BRIGHT_STEPS.size()).hinted(
		"How bright each point is")


static func exposure(m: FractalMain, vis: Callable) -> WristMenu.Item:
	return WristMenu.Item.new("colour", "EXPOSURE",
		func(): return "%.0fx" % FractalMain.EXPOSURE_MUL[m.exposure_idx],
		func():
			m.exposure_idx = (m.exposure_idx + 1) % FractalMain.EXPOSURE_MUL.size()
			m._apply_exposure(), false, vis).stepping(func(d: int):
			m.exposure_idx = wrapi(m.exposure_idx + d, 0, FractalMain.EXPOSURE_MUL.size())
			m._apply_exposure()).slider(
		func(): return m.exposure_idx, FractalMain.EXPOSURE_MUL.size()).hinted("Overall brightness")
