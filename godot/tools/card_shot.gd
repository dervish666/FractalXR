extends SceneTree

## Renders the first-launch controls card to .spike-out/help_card.png so its layout can be
## checked without a headset. It draws the real ControlsCard through a real SubViewport, so
## what lands in the PNG is what the quad shows: only the placement in the room is left to
## on-device eyes.
##
##   tools/card_shot.sh

func _init() -> void:
	var hc := load("res://scripts/xr/help_card.gd")
	if hc == null:
		print("CARDSHOT FAIL: help_card.gd would not load")
		quit(1)
		return
	var card: Control = hc.ControlsCard.new()
	card.size = hc.ControlsCard.CARD
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
	var err := img.save_png("res://.spike-out/help_card.png")
	print("CARDSHOT %s" % ("PASS" if err == OK else "FAIL %d" % err))
	quit(0 if err == OK else 1)
