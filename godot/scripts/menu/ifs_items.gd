extends RefCounted

## IFS's tiles, in the order IFS shows them. The sculpture is grabbed but never spun (a
## shape you are about to edit has to hold still), so SPIN and CENTRE are not here.


static func build(m: FractalMain) -> Array[WristMenu.Item]:
	var vis := func(): return m.ifs_mode
	var out: Array[WristMenu.Item] = [
		# A different rule and a different seed frame, so a shape lands like a new sculpture
		# rather than like a changed setting.
		WristMenu.Item.new("pick", "SHAPES",
			func(): return FractalIFS.preset_name(m.ifs_preset_idx),
			func(): m._cycle_ifs_preset(1),
			false, vis).pictures("ifs",
			func(): return m.ifs_preset_idx, func(): return FractalIFS.PRESETS.size(),
			func(i: int): return FractalIFS.preset_name(i),
			func(i: int): m._cycle_ifs_preset(i - m.ifs_preset_idx)).as_card(),

		# DEPTH and DETAIL are deliberately separate: one stretches the shape front to back,
		# the other adds a generation. Both rebuild; the palette does not.
		WristMenu.Item.new("make", "DETAIL",
			func(): return "%d · %d" % [FractalMain.IFS_DETAIL[m.ifs_detail_idx], m.ifs.instance_count],
			func(): m._step_ifs_detail(1),
			false, vis).stepping(func(d: int): m._step_ifs_detail(d)).slider(
			func(): return m.ifs_detail_idx, FractalMain.IFS_DETAIL.size()),
		WristMenu.Item.new("make", "DEPTH",
			func(): return "%.2fx" % FractalMain.IFS_DEPTH[m.ifs_depth_idx],
			func(): m._step_ifs_depth(1),
			false, vis).stepping(func(d: int): m._step_ifs_depth(d)),
		# EDIT puts the handles up; the trigger only picks one while they are showing. UNDO is a
		# single step back to the parameters the last completed edit started from, and RESET is
		# the other direction, which is why it clears the undo.
		WristMenu.Item.new("make", "EDIT",
			func(): return "handles on" if m.ifs_edit.guides_on else "handles off",
			func():
				# The handles and the dive both want the trigger; the one turned on last has it.
				if not m.ifs_edit.guides_on and m.ifs_dive.on:
					m._set_ifs_dive(false)
				m.ifs_edit.set_guides(not m.ifs_edit.guides_on),
			false, vis).toggle(func(): return m.ifs_edit.guides_on),
		WristMenu.Item.new("make", "DIVE",
			func(): return ("hold trigger · %d" % m.ifs_dive.steps) if m.ifs_dive.on else "off",
			func(): m._set_ifs_dive(not m.ifs_dive.on),
			false, vis).toggle(func(): return m.ifs_dive.on),
		WristMenu.Item.new("make", "UNDO",
			func(): return "last edit" if m.ifs_edit.has_undo() else "nothing yet",
			func(): m.ifs_edit.undo(),
			false, vis),
		WristMenu.Item.new("make", "RESET",
			func(): return "shape + pose",
			func(): m._reset_ifs(),
			false, vis),

		MenuShared.sky(m, vis),
		MenuShared.sky_pick(m, vis),

		# The sculpture's own MOTION: breathing. The cloud's MOTION never shows here.
		WristMenu.Item.new("look", "MOTION",
			func(): return "breathing" if m.ifs.ambient else "off",
			func(): m._toggle_ifs_motion(),
			false, vis).toggle(func(): return m.ifs.ambient),
		# Copies of the sculpture through the room. The count is what the tile prints, because
		# the count is what the GPU pays for; the headset's frame time decides whether MANY stays.
		WristMenu.Item.new("look", "ECHOES",
			func():
				return "off" if m.ifs_echoes.count() == 0 else "%s · %d" % [
					m.ifs_echoes.step_name(), m.ifs_echoes.count()],
			func(): m.ifs_echoes.set_step(m.ifs_echoes.step + 1),
			false, vis).stepping(func(d: int): m.ifs_echoes.set_step(m.ifs_echoes.step + d)),
		# Where the echoes stand: the seeded scatter, or where the sculpture's own maps put its
		# relatives, so the room is the next generations out.
		WristMenu.Item.new("look", "LAYOUT",
			func(): return m.ifs_echoes.layout_name(),
			func(): m.ifs_echoes.set_family(not m.ifs_echoes.family),
			false, vis).toggle(func(): return m.ifs_echoes.family),
		WristMenu.Item.new("look", "SIZE",
			func(): return "room" if m.ifs_room else "table",
			func(): m._set_ifs_room(not m.ifs_room),
			false, vis).toggle(func(): return m.ifs_room),
		MenuShared.fovea(m, vis),
		MenuShared.glow(m, vis),

		MenuShared.theme(m, vis),
		MenuShared.cycle(m, vis),
		MenuShared.bands(m, vis),
		MenuShared.exposure(m, vis),
	]
	return out
