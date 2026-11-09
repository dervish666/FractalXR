extends RefCounted

## TREE's tiles, in the order TREE shows them.


static func build(m: FractalMain) -> Array[WristMenu.Item]:
	var vis := func(): return m.tree_mode
	var out: Array[WristMenu.Item] = [
		WristMenu.Item.new("pick", "SPECIES",
			func(): return FractalTree.SHAPE_NAMES[m.tree_shape_idx],
			func(): m._cycle_tree_shape(1),
			false, vis).pictures("tree",
			func(): return m.tree_shape_idx, func(): return FractalTree.SHAPE_NAMES.size(),
			func(i: int): return FractalTree.SHAPE_NAMES[i],
			func(i: int): m._cycle_tree_shape(i - m.tree_shape_idx)).as_card(),

		WristMenu.Item.new("make", "SEED",
			func(): return "#%d" % m.tree.seed_value,
			func(): m.tree.reseed(),
			false, vis).minor().hinted("A new shape for your tree"),
		WristMenu.Item.new("make", "REGROW",
			func(): return "all trees",
			func(): m._regrow_forest(),
			false, vis).hinted("Grows every tree again from a seedling"),
		# The forest's own actions: a mixed grove, what a pull plants, and the slow turnover.
		WristMenu.Item.new("make", "SOW",
			func(): return "mixed grove",
			func(): m._sow_grove(),
			false, vis).hinted("Plants a mixed grove round you"),
		# The avenue: two rows from your feet to 50 m, growing away from you. WALK is the same
		# rows, endless, gliding toward you while a trigger is held. MIX picks their species.
		WristMenu.Item.new("make", "AVENUE",
			func(): return "mixed rows" if m.forest.plant_mix \
				else "%s rows" % FractalTree.SHAPE_NAMES[m.tree_shape_idx],
			func(): m._sow_avenue(false),
			false, vis).hinted("Two rows of trees ahead of you"),
		WristMenu.Item.new("make", "WALK",
			func(): return "hold trigger" if m.forest.walking() else "endless avenue",
			func(): m._toggle_walk(),
			false, vis).toggle(func(): return m.forest.walking()).hinted(
			"Hold trigger to glide down an endless avenue"),
		WristMenu.Item.new("make", "MIX",
			func(): return "species" if m.forest.plant_mix else "one kind",
			func(): m._toggle_plant_mix(),
			false, vis).toggle(func(): return m.forest.plant_mix).minor().hinted(
			"Plant mixed species, not just this one"),
		# Succession, under a word short enough for a minor tile.
		WristMenu.Item.new("make", "RENEW",
			func(): return "on" if m.forest.succession else "off",
			func(): m._toggle_succession(),
			false, vis).toggle(func(): return m.forest.succession).minor().hinted(
			"Old trees wither and new ones grow"),
		# The title carries the one tree count; CLEAR says what it does instead of a second.
		WristMenu.Item.new("make", "CLEAR",
			func(): return "remove all",
			func(): m._clear_forest(),
			false, vis).hinted("Removes every tree but yours"),
		# How many trees AVENUE, WALK and SOW grow (scripts/tree/forest.gd STEPS). A step sows
		# the current layout again at the new size.
		WristMenu.Item.new("make", "COUNT",
			func(): return "sow %d" % int(m.forest.step()["n"]),
			func(): m._step_tree_count(1),
			false, vis).stepping(func(d: int): m._step_tree_count(d)).slider(
			func(): return m.forest.count_idx, Forest.STEPS.size()).hinted(
			"How many trees AVENUE, WALK and SOW plant"),
		# How fast WALK glides (scripts/tree/forest.gd WALK_PACES): 0.75 m/s unless you pick.
		WristMenu.Item.new("make", "PACE",
			func(): return "%.2f m/s" % m.forest.walk_pace(),
			func(): m.forest.set_pace(wrapi(m.forest.pace_idx + 1, 0, Forest.WALK_PACES.size())),
			false, vis).stepping(func(d: int): m.forest.set_pace(m.forest.pace_idx + d)).slider(
			func(): return m.forest.pace_idx, Forest.WALK_PACES.size()).minor().hinted(
			"How fast WALK glides"),

		MenuShared.spin(m, vis),
		MenuShared.home(m, vis),
		MenuShared.sky(m, vis),
		MenuShared.sky_pick(m, vis),

		WristMenu.Item.new("look", "LEVELS",
			func(): return "%d levels · %s branches" % [m.tree.effective_depth(),
				m._fmt_count(m._forest_branch_count())],
			func():
				m.tree_depth_idx = (m.tree_depth_idx + 1) % FractalMain.TREE_DEPTH_DELTA.size()
				m.tree.depth_delta = FractalMain.TREE_DEPTH_DELTA[m.tree_depth_idx]
				m.tree.build(),
			false, vis).stepping(func(d: int):
				m.tree_depth_idx = wrapi(m.tree_depth_idx + d, 0, FractalMain.TREE_DEPTH_DELTA.size())
				m.tree.depth_delta = FractalMain.TREE_DEPTH_DELTA[m.tree_depth_idx]
				m.tree.build()).hinted("More branch levels, more detail"),
		WristMenu.Item.new("look", "WIND",
			func(): return FractalMain.TREE_WIND_NAMES[m.tree_wind_idx],
			func():
				m.tree_wind_idx = (m.tree_wind_idx + 1) % FractalMain.TREE_WIND.size()
				m._set_forest_wind(FractalMain.TREE_WIND[m.tree_wind_idx]),
			false, vis).stepping(func(d: int):
				m.tree_wind_idx = wrapi(m.tree_wind_idx + d, 0, FractalMain.TREE_WIND.size())
				m._set_forest_wind(FractalMain.TREE_WIND[m.tree_wind_idx])).hinted(
			"How hard the wind blows"),
		WristMenu.Item.new("look", "LEAVES",
			func(): return "on" if m.tree.leaves_on else "off",
			func(): m._set_forest_leaves(not m.tree.leaves_on),
			false, vis).toggle(func(): return m.tree.leaves_on),
		# Something under the trees, in theme: a faint fractal ground, fallen leaves round every
		# trunk, or both (forest_floor.gd, tree_litter.gd). Off by default.
		WristMenu.Item.new("look", "FLOOR",
			func(): return FractalMain.FLOOR_LABELS[m.forest.floor_idx],
			func(): m._set_tree_floor(wrapi(m.forest.floor_idx + 1, 0, Forest.FLOOR_STEPS.size())),
			false, vis).stepping(func(d: int):
				m._set_tree_floor(wrapi(m.forest.floor_idx + d, 0, Forest.FLOOR_STEPS.size()))).hinted(
			"What lies on the ground under the trees"),
		# A fractal grown into the wood (tree.gdshader BARK). Plain by default; far trees stay plain.
		WristMenu.Item.new("look", "BARK",
			func(): return FractalMain.BARK_LABELS[m.forest.bark_style],
			func(): m._set_tree_bark(wrapi(m.forest.bark_style + 1, 0, Forest.BARK_STEPS.size())),
			false, vis).stepping(func(d: int):
				m._set_tree_bark(wrapi(m.forest.bark_style + d, 0, Forest.BARK_STEPS.size()))).hinted(
			"A fractal pattern grown into the bark"),
		# The frame-time dial goes after what the trees look like, not ahead of them.
		MenuShared.detail(m, vis),
		MenuShared.fovea(m, vis),
		MenuShared.glow(m, vis),

		MenuShared.theme(m, vis),
		MenuShared.cycle(m, vis),
		MenuShared.bands(m, vis),
		MenuShared.exposure(m, vis),
	]
	return out
