class_name MenuItems
extends RefCounted

## The wrist menu's spec: the mode rail, each mode's tiles (one file per mode), the bottom
## bar, and the title and status lines. Adding a setting is one entry in its mode's file and
## nothing else; the menu knows nothing about particle counts or exposures.

const FlameItems := preload("res://scripts/menu/flame_items.gd")
const BulbItems := preload("res://scripts/menu/bulb_items.gd")
const GroundItems := preload("res://scripts/menu/ground_items.gd")
const TreeItems := preload("res://scripts/menu/tree_items.gd")
const IfsItems := preload("res://scripts/menu/ifs_items.gd")


static func install(m: FractalMain, menu: WristMenu) -> void:
	var items: Array[WristMenu.Item] = [
		# The mode strip: five segments under the title, always in the same place.
		WristMenu.Item.new("mode", "FLAME", func(): return "",
			func(): m._set_mode("flame")).chosen_when(func():
				return not m.bulb_mode and not m.ground_mode and not m.tree_mode and not m.ifs_mode),
		WristMenu.Item.new("mode", "BULB", func(): return "",
			func(): m._set_mode("bulb")).chosen_when(func(): return m.bulb_mode),
		WristMenu.Item.new("mode", "GROUND", func(): return "",
			func(): m._set_mode("ground")).chosen_when(func(): return m.ground_mode),
		WristMenu.Item.new("mode", "TREE", func(): return "",
			func(): m._set_mode("tree")).chosen_when(func(): return m.tree_mode),
		WristMenu.Item.new("mode", "IFS", func(): return "",
			func(): m._set_mode("ifs")).chosen_when(func(): return m.ifs_mode),
	]
	# Each mode's own list. The cards come out in the order sections first appear, so every
	# mode file keeps the same section order: pick, make, scene, look, colour.
	items.append_array(FlameItems.build(m))
	items.append_array(BulbItems.build(m))
	items.append_array(GroundItems.build(m))
	items.append_array(TreeItems.build(m))
	items.append_array(IfsItems.build(m))
	# The bottom bar, at every level, in the order Sam asked for. EXIT is a hold: the menu
	# is driven by a ray and a trigger, and a single stray pull should not end the
	# session; the ring fills for a second before this runs.
	items.append_array([
		WristMenu.Item.new("app", "EXIT",
			func(): return "hold to quit",
			func(): m.get_tree().quit()).hold().in_bar(),
		WristMenu.Item.new("app", "PASSTHRU",
			func(): return m.passthru_label,
			func(): m._set_passthrough(not m.passthrough)).toggle(func(): return m.passthrough).in_bar(),
		WristMenu.Item.new("app", "HELP",
			func(): return "controls", func(): m.help.open()).in_bar(),
	])
	menu.items = items
	menu.title = func(): return title(m)
	menu.status_side = func(): return status_side(m)
	menu.status_main = func(): return status_main(m)


static func title(m: FractalMain) -> String:
	if m.ifs_mode:
		return "%s  ·  detail %d" % [FractalIFS.preset_name(m.ifs_preset_idx).capitalize(),
			FractalMain.IFS_DETAIL[m.ifs_detail_idx]]
	if m.tree_mode:
		return "%s forest  ·  %d trees" % [FractalTree.SHAPE_NAMES[m.tree_shape_idx].capitalize(),
			m._forest_tree_count()]
	if m.ground_mode:
		var z: float = m.ground.zoom_factor()
		var fam: String = m.ground.formula_name().capitalize()
		return "%s  ·  zoom %s" % [(fam + " julia") if m.ground.julia else fam, m._zoom_text(z)]
	return str(m.library.bulbs[m.bulb_idx].get("name", "?")) if m.bulb_mode else m.library.name_at(m.preset_idx)


static func status_side(m: FractalMain) -> String:
	if m.ifs_mode:
		# Which handle has the trigger, while it has it. Nothing else on this line matters
		# as much mid-drag as knowing what your hand is holding.
		if m.ifs_edit.is_editing():
			return m.ifs_edit.status()
		if m.ifs_dive.in_step():
			return "diving %d%%" % int(m.ifs_dive.progress() * 100.0)
		if m.ifs.is_morphing():
			return "morphing %d%%" % int(m.ifs.morph_t * 100.0)
		# A capped build is the one thing here worth interrupting for: it means the rung
		# on the tile is not the rung on the screen.
		if m.ifs.cap_note != "":
			return "capped at level %d" % m.ifs.levels_built
		# Breathing and a morph rebuild on every frame, so they run at the rung a drag runs
		# at. Naming it keeps the frame count below from reading as the wrong number for
		# the rung on the DETAIL tile.
		# Instance and triangle counts are instruments: debug builds only, so they stay
		# out of a release build's menu shots.
		var dbg := OS.is_debug_build()
		if m.ifs.levels_built < FractalMain.IFS_DETAIL[m.ifs_detail_idx]:
			return ("moving at level %d · %d frames" % [m.ifs.levels_built, m.ifs.instance_count]) \
					if dbg else "moving at level %d" % m.ifs.levels_built
		return ("%d frames · %s tri" % [m.ifs.instance_count, m._fmt_count(m.ifs.triangle_count)]) \
				if dbg else ""
	if m.tree_mode:
		if m.forest.walking():
			return "walking" if m.forest.walk_speed > 0.0 else "hold trigger to walk"
		# At capacity the trigger stops doing anything and the marker goes away, so
		# say why here rather than leaving the floor silently dead.
		if not m.forest.can_plant():
			return "forest full · CLEAR to replant"
		var gp: float = m.tree.grow_progress()
		return ("growing %d%%" % int(gp * 100.0)) if gp < 1.0 else "grown"
	if m.ground_mode:
		var pr: float = m.ground.progress()
		return ("rendering %d%%" % int(pr * 100.0)) if pr < 1.0 else "sharp"
	if m._perf_scale < 0.999:
		# Name the intervention, or a guarded 42mm splat looks like a broken setting.
		return "guard %d%%" % int(m._perf_scale * 100.0)
	if m.cloud.is_baking():
		return "baking %d%%" % int(m.cloud.bake_progress * 100.0)
	if m._inside:
		return "inside · %.1fx eye" % FractalMain.RENDER_STEPS[m.render_idx]
	if m._inside_bailed_until > m._uptime:
		return "inside bailed: %.0f ms" % m._inside_bailed_ms
	if m._march_bailed_until > m._uptime:
		return "march bailed: %.0f ms" % m._march_bailed_ms
	if m.bulb_mode and m._bulb_settle > 0:
		return "settling"
	if m._morph_t < 1.0:
		return "morphing"
	return "drifting" if m._drift else ""


static func status_main(m: FractalMain) -> String:
	# The footer is a perf readout. A release build shows nothing there.
	if not OS.is_debug_build():
		return ""
	if m.ifs_mode:
		# Build time, not draw time: the sculpture is static, so what a rung costs to
		# generate is the number that decides whether a drag can rebuild every frame.
		return "%.0f fps  ·  detail %d  ·  build %.2f ms" % [
			Engine.get_frames_per_second(), FractalMain.IFS_DETAIL[m.ifs_detail_idx], m.ifs.build_ms]
	return "%.0f fps  ·  %d flames  ·  %.1f ms" % [
		Engine.get_frames_per_second(), m.library.count(),
		RenderingServer.viewport_get_measured_render_time_gpu(m.get_viewport().get_viewport_rid())
			+ (m.ground.ground_us if m.ground_mode else (0.0 if m.tree_mode else m.cloud.iterate_us)) / 1000.0]
