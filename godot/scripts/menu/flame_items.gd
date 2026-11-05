extends RefCounted

## FLAME's tiles, in the order FLAME shows them.


static func build(m: FractalMain) -> Array[WristMenu.Item]:
	var vis := func(): return not m.bulb_mode and not m.ground_mode and not m.tree_mode and not m.ifs_mode
	var out: Array[WristMenu.Item] = [
		WristMenu.Item.new("pick", "FLAMES",
			func(): return m.library.name_at(m.preset_idx),
			func(): m._morph_to_preset(m.preset_idx + 1),
			false, vis).pictures("flame",
			func(): return m.preset_idx, func(): return m.library.count(),
			func(i: int): return m.library.name_at(i),
			func(i: int): m._morph_to_preset(i)).as_card(),

		WristMenu.Item.new("make", "RANDOM",
			func(): return "new flame", func(): m._morph_to_new(Breed.random_genome(
				m.library.next_serial(), m.library.themes)),
			false, vis).hinted("A new flame from scratch"),
		WristMenu.Item.new("make", "MUTATE",
			func(): return "vary this", func(): m._morph_to_new(Breed.mutate(
				m.library.at(m.preset_idx), m.library.next_serial())),
			false, vis).hinted("A variation on this flame"),
		WristMenu.Item.new("make", "BREED",
			func(): return "mix two", func(): m._morph_to_new(Breed.crossover(
				m.library.at(m.preset_idx),
				m.library.at(m.preset_idx + 1 + randi() % maxi(1, m.library.count() - 1)),
				m.library.next_serial())),
			false, vis).hinted("A flame from this one and another"),

		MenuShared.drift(m, vis),
		MenuShared.spin(m, vis),
		WristMenu.Item.new("scene", "SPEED",
			func(): return "%ds" % int(FractalMain.MORPH_STEPS[m.morph_idx]),
			func(): m.morph_idx = (m.morph_idx + 1) % FractalMain.MORPH_STEPS.size(),
			false, vis).stepping(func(d: int):
				m.morph_idx = wrapi(m.morph_idx + d, 0, FractalMain.MORPH_STEPS.size())).hinted(
			"How long one flame takes to become the next"),
		MenuShared.home(m, vis),
		# The flame at scale. GALAXY grows it round you, ECHOES hangs copies of it round the
		# room, TO SKY bakes it into the sky every mode can wear, and SKY hangs or hides it.
		# Not in the bottom bar: a fourth item there cut PASSTHRU to PASS and EXIT's "hold to
		# quit" to "hold to q".
		WristMenu.Item.new("scene", "GALAXY",
			func(): return "inside" if m.galaxy.active else "off",
			func(): m._toggle_galaxy(),
			false, vis).toggle(func(): return m.galaxy.active).hinted("Grows the flame round you"),
		WristMenu.Item.new("scene", "ECHOES",
			func(): return "off" if m.flame_echoes.count() == 0 else "%s · %s" % [
				m.flame_echoes.step_name(), m._fmt_count(m.flame_echoes.point_total())],
			func(): m._step_flame_echoes(1),
			false, vis).stepping(func(d: int): m._step_flame_echoes(d)).hinted(
			"Copies of the flame round the room"),
		WristMenu.Item.new("scene", "TO SKY",
			func():
				if m.flame_sky.baking:
					return "baking %d%%" % int(m.flame_sky.progress * 100.0)
				return "baked" if m.flame_sky.ready else "this flame",
			func(): m._bake_sky(),
			false, vis).hinted("Paints this flame onto the sky"),
		MenuShared.sky(m, vis),
		MenuShared.sky_pick(m, vis),
		# The live bake's resolution. Each step re-bakes the flame on show; a bake is a frame
		# count, 2.8 s, 6.9 s and 15.4 s at 72 Hz (tools/sky_bake.sh measure).
		WristMenu.Item.new("scene", "SKY RES",
			func(): return FlameSky.RES_NAMES[m.sky_res_idx],
			func(): m._step_sky_res(1),
			false, vis).stepping(func(d: int): m._step_sky_res(d)).slider(
			func(): return m.sky_res_idx, FlameSky.RES_STEPS.size()).minor().hinted(
			"Sharper baked sky, longer bake"),

		WristMenu.Item.new("look", "POINTS",
			func(): return m._fmt_count(m.cloud.get_count()),
			func():
				m.particle_idx = (m.particle_idx + 1) % FractalMain.PARTICLE_STEPS.size()
				m.cloud.set_count(int(FractalMain.TEX_SIZE * FractalMain.TEX_SIZE
					* FractalMain.PARTICLE_STEPS[m.particle_idx]))
				m.cloud.request_measure(),
			false, vis).stepping(func(d: int):
				m.particle_idx = wrapi(m.particle_idx + d, 0, FractalMain.PARTICLE_STEPS.size())
				m.cloud.set_count(int(FractalMain.TEX_SIZE * FractalMain.TEX_SIZE
					* FractalMain.PARTICLE_STEPS[m.particle_idx]))
				m.cloud.request_measure()).hinted("More points, finer flame, more frame time"),
		MenuShared.splat(m, vis),
		MenuShared.adapt(m, vis),
		MenuShared.opacity(m, vis),
		WristMenu.Item.new("look", "SIZE",
			func(): return "%.2f" % FractalMain.POINT_STEPS[m.point_idx],
			func():
				m.point_idx = (m.point_idx + 1) % FractalMain.POINT_STEPS.size()
				m._apply_point_look(),
			false, vis).stepping(func(d: int):
				m.point_idx = wrapi(m.point_idx + d, 0, FractalMain.POINT_STEPS.size())
				m._apply_point_look()).slider(func(): return m.point_idx, FractalMain.POINT_STEPS.size()).hinted(
			"Bigger, softer points"),
		WristMenu.Item.new("look", "AA",
			func(): return "old" if FractalMain.AA_STEPS[m.aa_idx] < 0.0 else "%.1f px" % FractalMain.AA_STEPS[m.aa_idx],
			func():
				m.aa_idx = (m.aa_idx + 1) % FractalMain.AA_STEPS.size()
				m._apply_point_look(),
			false, vis).stepping(func(d: int):
				m.aa_idx = wrapi(m.aa_idx + d, 0, FractalMain.AA_STEPS.size())
				m._apply_point_look()).minor().hinted("Smooths each point's edge"),
		MenuShared.steady(m, vis),
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
