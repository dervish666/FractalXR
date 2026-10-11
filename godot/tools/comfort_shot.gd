extends SceneTree

## The walk's comfort tunnel, measured (T-55). One camera with roughly a Quest 3 eye's field (96
## degrees tall, about 94 wide here; the real eye is wider on its temple side), a flat grey world
## behind it, and the ComfortVignette in front. For the DIVE and WALK profiles, at a few motions,
## it reads how dark the view is at its edges and corners (1 - luminance / the grey) and where the
## darkening reaches half, and saves the frames, so the rest frame's lattice can be seen as well.
##
##   tools/comfort_shot.sh    (.spike-out/comfort_*.png)

const GREY := 0.5


func _init() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(GREY, GREY, GREY)
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var we := WorldEnvironment.new()
	we.environment = env
	root.add_child(we)
	var cam := Camera3D.new()
	cam.fov = 96.0
	cam.current = true
	root.add_child(cam)
	# Turned and tilted a little, so the lattice's lines are not all straight across the frame.
	cam.rotation_degrees = Vector3(-12.0, 25.0, 0.0)
	var vig := ComfortVignette.new()
	cam.add_child(vig)
	vig.set_rest_tint(Vector3(0.55, 0.35, 0.7))
	for i in 5:
		await process_frame
	var bad: Array[String] = []
	var rows := {}
	for prof in [["dive", ComfortVignette.DIVE], ["walk", ComfortVignette.WALK]]:
		vig.set_profile(prof[1])
		for m in [0.2, 0.4, 1.0]:
			vig.set_motion(m)
			for i in 4:
				await process_frame
			var img := root.get_viewport().get_texture().get_image()
			var r := _read(img)
			rows["%s%.1f" % [prof[0], m]] = r
			if m == 1.0:
				img.save_png("res://.spike-out/comfort_%s.png" % prof[0])
			print("COMFORTSHOT %-4s motion %.1f -> strength %.2f: dark at top/bottom edge %.2f, side edge %.2f, corner %.2f, centre %.2f; half-dark from %s off centre" % [
				prof[0], m, vig.motion, r["edge_v"], r["edge_h"], r["corner"], r["centre"], r["half"]])
	vig.set_motion(0.0)
	for i in 3:
		await process_frame
	var clear := _read(root.get_viewport().get_texture().get_image())
	print("COMFORTSHOT still: dark at the edges %.2f, shown %s" % [maxf(clear["edge_v"], clear["edge_h"]), str(vig.visible)])
	# The walk shuts harder and sooner than the dive, the centre stays clear, and still is clear.
	if rows["walk1.0"]["edge_v"] < rows["dive1.0"]["edge_v"] + 0.2:
		bad.append("WALK's top and bottom edges are not darker than DIVE's (%.2f vs %.2f)" % [
			rows["walk1.0"]["edge_v"], rows["dive1.0"]["edge_v"]])
	if rows["walk0.4"]["edge_v"] < 0.5 or rows["walk0.2"]["corner"] < 0.1:
		bad.append("WALK is not closing early (corner %.2f at 20%% of the pace, top/bottom %.2f at 40%%)" % [rows["walk0.2"]["corner"], rows["walk0.4"]["edge_v"]])
	if rows["walk1.0"]["centre"] > 0.02:
		bad.append("WALK darkens the centre (%.2f)" % rows["walk1.0"]["centre"])
	if clear["edge_v"] > 0.01 or vig.visible:
		bad.append("the tunnel is up while still")
	for b in bad:
		print("COMFORTSHOT problem: ", b)
	print("COMFORTSHOT %s" % ("PASS" if bad.is_empty() else "FAIL"))
	quit(0 if bad.is_empty() else 1)


## Darkness (the share of the grey's light taken away; the lattice reads as a little less dark) at
## the middle of the top and bottom edges, the side edges, the corners and the centre, each a 9x9
## median; and the angle off centre, along the vertical, where it first passes half.
func _read(img: Image) -> Dictionary:
	var w := img.get_width()
	var h := img.get_height()
	var grey_lin := Color(GREY, GREY, GREY).srgb_to_linear().get_luminance()
	var d := func(x: int, y: int) -> float:
		var vals: Array[float] = []
		for j in range(-4, 5):
			for i in range(-4, 5):
				var c := img.get_pixel(clampi(x + i, 0, w - 1), clampi(y + j, 0, h - 1))
				# Light taken away, in linear terms: the frame is sRGB-encoded, and the grey
				# background is 0.5 there, 0.214 in light.
				vals.append(1.0 - c.srgb_to_linear().get_luminance() / grey_lin)
		vals.sort()
		return vals[40]
	var half := "nowhere"
	var tan_half := tan(deg_to_rad(48.0))
	for y in range(h / 2, 0, -1):
		if d.call(w / 2, y) > 0.5:
			var t := float(h / 2 - y) / float(h / 2) * tan_half
			half = "%.0f deg" % rad_to_deg(atan(t))
			break
	return {"edge_v": (d.call(w / 2, 4) + d.call(w / 2, h - 5)) * 0.5,
		"edge_h": (d.call(4, h / 2) + d.call(w - 5, h / 2)) * 0.5,
		"corner": d.call(4, 4), "centre": d.call(w / 2, h / 2), "half": half}
