extends SceneTree

## Renders the first-launch controls card to .spike-out/help_card_<mode>.png so its layout can
## be checked without a headset. It draws the real ControlsCard through a real SubViewport, so
## what lands in the PNG is what the quad shows: only the placement in the room is left to
## on-device eyes.
##
## Every mode gets its own capture. The card swaps its callouts by mode, and a flame-only
## screenshot cannot show whether the bulb, ground or tree wording is right.
##
##   tools/card_shot.sh

const MODES := ["flame", "bulb", "ground", "tree"]


func _init() -> void:
	var hc := load("res://scripts/xr/help_card.gd")
	if hc == null:
		print("CARDSHOT FAIL: help_card.gd would not load")
		quit(1)
		return
	var ok := true
	for mode in MODES:
		var card: Control = hc.ControlsCard.new()
		card.size = hc.ControlsCard.CARD
		card.set_mode(mode)
		var vp := SubViewport.new()
		vp.size = Vector2i(card.size)
		vp.transparent_bg = true
		vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		vp.disable_3d = true
		vp.add_child(card)
		root.add_child(vp)
		await process_frame
		await process_frame
		var img := vp.get_texture().get_image()
		var err := img.save_png("res://.spike-out/help_card_%s.png" % mode)
		# flame keeps the original filename: tools and notes already point at it.
		var err0 := OK
		if mode == "flame":
			err0 = img.save_png("res://.spike-out/help_card.png")
		var blank := _is_blank(img)
		# draw_string clips a too-long line without complaining, so the card reports what
		# it could not fit. A saved PNG is not proof the instructions are all readable.
		var over: PackedStringArray = card.overflow
		var pass_one: bool = err == OK and err0 == OK and not blank and over.is_empty()
		print("CARDSHOT %s %s%s%s" % [mode, "PASS" if pass_one else "FAIL",
			"" if not blank else " (nothing drawn)",
			"" if over.is_empty() else "  clipped: " + ", ".join(over)])
		ok = ok and pass_one
		vp.queue_free()
		await process_frame
	# Negative control: a string nothing could fit must be reported. A clipping check
	# that never fires is decoration.
	var probe: Control = hc.ControlsCard.new()
	probe.size = hc.ControlsCard.CARD
	var vpp := SubViewport.new()
	vpp.size = Vector2i(probe.size)
	vpp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vpp.disable_3d = true
	vpp.add_child(probe)
	root.add_child(vpp)
	await process_frame
	var control_hit: bool = probe._fits_probe()
	print("CARDSHOT control %s" % ["PASS" if control_hit else "FAIL"])
	print("CARDSHOT %s modes=%d" % ["PASS" if ok and control_hit else "FAIL", MODES.size()])
	quit(0 if ok and control_hit else 1)


## A transparent SubViewport that never drew reads as a clean save. Require real ink.
func _is_blank(img: Image) -> bool:
	var lit := 0
	var step := maxi(1, img.get_width() / 64)
	for y in range(0, img.get_height(), step):
		for x in range(0, img.get_width(), step):
			if img.get_pixel(x, y).a > 0.05:
				lit += 1
	return lit < 16
