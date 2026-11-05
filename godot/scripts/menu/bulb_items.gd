extends RefCounted

## BULB's tiles, in the order BULB shows them.

enum {SPLATS, LINES, SOLID, MARCHED}
const STYLE_NAMES := ["splats", "lines", "solid", "marched"]
const QUALITY_WORDS := ["fast", "balanced", "best"]


static func build(m: FractalMain) -> Array[WristMenu.Item]:
	var vis := func(): return m.bulb_mode
	# The fineness each surface last had, so SURFACE comes back to it.
	var mem := {LINES: 1, SOLID: 4, MARCHED: 1}
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
		MenuShared.home(m, vis),
		MenuShared.sky(m, vis),
		MenuShared.sky_pick(m, vis),

		# How the bulb is drawn, first on the card because it changes everything below it.
		# Splats and lines are the particle cloud (lines snap it onto parallel planes);
		# solid is a mesh built on the device; marched is a raymarched surface.
		WristMenu.Item.new("look", "SURFACE",
			func():
				var st := style(m)
				if st == SOLID:
					if m.solid.is_building():
						return "solid · growing %d%%" % int(m.solid.progress() * 100.0)
					if m.solid.get_error() != "":
						return "solid failed"
				return STYLE_NAMES[st],
			func(): set_style(m, mem, wrapi(style(m) + 1, 0, STYLE_NAMES.size())),
			false, vis).stepping(func(d: int):
				set_style(m, mem, wrapi(style(m) + d, 0, STYLE_NAMES.size()))).slider(
			func(): return style(m), STYLE_NAMES.size()).hinted("How the bulb is drawn"),
		# How fine the chosen surface is: planes for lines, trace steps for marched, grid cells
		# for solid. A detail, not a look, so it waits behind MORE.
		WristMenu.Item.new("look", "QUALITY",
			func(): return quality_name(m),
			func(): step_quality(m, mem, 1),
			false, func(): return vis.call() and style(m) != SPLATS).stepping(
			func(d: int): step_quality(m, mem, d)).minor().hinted(
			"Finer surface, more frame time"),
		MenuShared.splat(m, vis),
		MenuShared.adapt(m, vis),
		MenuShared.opacity(m, vis),
		MenuShared.steady(m, vis),
		# The per-splat fit: each splat turned to lie along the surface round it. Named for what
		# ON does; it waits for the cloud to settle before it can fit.
		WristMenu.Item.new("look", "FIT SPLATS",
			func():
				if m.cloud.is_baking():
					return "fitting %d%%" % int(m.cloud.bake_progress * 100.0)
				if not m.auto_bake:
					return "off"
				return "on" if m.cloud.bake_ready else "after settle",
			func():
				m.auto_bake = not m.auto_bake
				if m.auto_bake:
					RenderingServer.call_on_render_thread(m.cloud.bake)
				else:
					m.cloud.clear_bake(),
			false, vis).toggle(func(): return m.auto_bake).minor().hinted(
			"Turns each splat to lie along the surface"),
		# Only while LINES is on: with it off there are no lines to pattern or thin.
		WristMenu.Item.new("look", "PATTERN",
			func(): return FractalMain.LINE_PATTERNS[m.line_pattern_idx],
			func(): m._step_line_pattern(1),
			false, func(): return m.bulb_mode and m._line_slices() > 0).stepping(
			func(d: int): m._step_line_pattern(d)).hinted("Rings, a grid or lines on all three axes"),
		WristMenu.Item.new("look", "WIDTH",
			func(): return FractalMain.LINE_WIDTH_NAMES[m.line_width_idx],
			func(): m._step_line_width(1),
			false, func(): return m.bulb_mode and m._line_slices() > 0).stepping(
			func(d: int): m._step_line_width(d)).slider(
			func(): return m.line_width_idx, FractalMain.LINE_WIDTHS.size()).minor().hinted(
			"How thick the lines are"),
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
				m.breath_idx = wrapi(m.breath_idx + d, 0, FractalMain.BREATH_STEPS.size())).hinted(
			"How fast the surface slowly reshapes"),
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


## Which SURFACE is showing, read from the three settings it folds together.
static func style(m: FractalMain) -> int:
	if FractalMain.SURFACE_SOLID[m.surface_idx] > 0:
		return SOLID
	if FractalMain.SURFACE_STEPS[m.surface_idx] > 0:
		return MARCHED
	return LINES if m._line_slices() > 0 else SPLATS


## Lines are particles snapped to planes, so leaving or entering them reloads the bulb
## (_reload_lines, which also puts the surface back to splats). Solid and marched need the
## plain shell under them, so lines go off first.
static func set_style(m: FractalMain, mem: Dictionary, st: int) -> void:
	var cur := style(m)
	if cur != SPLATS and cur != st:
		mem[cur] = m.line_idx if cur == LINES else m.surface_idx
	if st == LINES:
		m.line_idx = mem[LINES]
		m._reload_lines()
		return
	if m.line_idx != 0:
		m.line_idx = 0
		m._reload_lines()
	m.surface_idx = 0 if st == SPLATS else int(mem[st])
	m._apply_surface()


static func quality_name(m: FractalMain) -> String:
	match style(m):
		LINES:
			return "%d lines" % m._line_slices()
		MARCHED:
			return "%s · %d" % [QUALITY_WORDS[m.surface_idx - 1], FractalMain.SURFACE_STEPS[m.surface_idx]]
		SOLID:
			return "%s · %d" % [QUALITY_WORDS[m.surface_idx - 4], FractalMain.SURFACE_SOLID[m.surface_idx]]
	return ""


## One rung finer or coarser within the surface showing, wrapping. Lines skip the rungs the
## pattern caps (grid and cross close only at 24 planes), and never step to 0, which is off.
static func step_quality(m: FractalMain, mem: Dictionary, d: int) -> void:
	match style(m):
		LINES:
			var rungs: Array[int] = []
			for i in range(1, FractalMain.LINE_SLICES.size()):
				if FractalMain.LINE_SLICES[i] <= FractalMain.LINE_MAX_SLICES[m.line_pattern_idx]:
					rungs.append(i)
			var at := maxi(0, rungs.find(m.line_idx))
			m.line_idx = rungs[wrapi(at + d, 0, rungs.size())]
			mem[LINES] = m.line_idx
			m._reload_lines()
		MARCHED:
			m.surface_idx = 1 + wrapi(m.surface_idx - 1 + d, 0, 3)
			mem[MARCHED] = m.surface_idx
			m._apply_surface()
		SOLID:
			m.surface_idx = 4 + wrapi(m.surface_idx - 4 + d, 0, 3)
			mem[SOLID] = m.surface_idx
			m._apply_surface()
