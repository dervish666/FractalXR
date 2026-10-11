extends SceneTree

## SOLID spike harness (T-48). For Classic and Citadel at 128, 192 and 256 cells it builds
## the mesh through the real main scene, prints the triangle count and the build cost, and
## shoots the solid and the splats from the Mandelbulber taste-test camera into
## .spike-out/solid/. Then it times one Quest-sized eye (1680 x 1760, 96 degree vertical
## field) with the solid on and off, and the three loads with a warm headset draw time on
## record (bulb splats 13.9 ms, tree 4.5 ms, IFS 5.4 ms; vault fractalxr-scale-ideas), so a
## Mac millisecond can be turned into a Quest estimate by ratio.
##
## GPU timings need timestamps, which Godot 4.7 on Metal reports as zero: run it on
## MoltenVK.
##
##   SOLID_DRIVER=vulkan tools/solid_shot.sh            everything
##   SOLID_DRIVER=vulkan tools/solid_shot.sh -- quick   Classic at 192, shots only
##   SOLID_DRIVER=vulkan tools/solid_shot.sh -- base    the calibration timings only

const OUT := "res://.spike-out/solid/"
const GRIDS := [128, 192, 256]
const BULBS := ["Classic", "Citadel"]
const EYE := Vector2i(1680, 1760)
const EYE_FOV := 96.0
const TIME_FRAMES := 120

var main: Node
var eye_vp: SubViewport
var eye_cam: Camera3D
var rows: Array = []


func _init() -> void:
	var quick := OS.get_cmdline_user_args().has("quick")
	var base_only := OS.get_cmdline_user_args().has("base")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var scene: PackedScene = load("res://main.tscn")
	main = scene.instantiate()
	root.add_child(main)
	for i in 40:
		await process_frame
	main.help.close()
	main.xr_camera.position = Vector3(0.0, 1.6, 0.0)
	main.xr_camera.rotation = Vector3.ZERO
	for i in 3:
		await process_frame
	main._set_mode("bulb")
	main.spin = false
	main._drift = false
	# Breath off and the clock at zero: Classic at exactly power 8, as Mandelbulber drew it.
	main.breath_idx = main.BREATH_STEPS.find(0.0)
	var ok := true
	for bname in ([] if base_only else ["Classic"] if quick else BULBS):
		main._load_bulb(_bulb_index(bname))
		main._bulb.clock = 0.0
		# Long enough for the settle, the measurement and the framing ease: SOLID sizes its
		# re-home from the measured fit, and the mesh is drawn through the eased one.
		for i in 400:
			await process_frame
		for n in ([192] if quick else GRIDS):
			ok = await _build(bname, n) and ok
			_shot("%s_solid_%d.png" % [bname.to_lower(), n])
			if n == 192:
				await _debug_views(bname, n)
			if not quick:
				rows[-1]["eye_ms_msaa4"] = await _time_eye()
				main._set_solid_msaa(false)
				rows[-1]["eye_ms_nomsaa"] = await _time_eye()
				main._set_solid_msaa(true)
		if not quick:
			# The same view with nothing drawn, so the solid's own cost is a difference.
			main.solid.visible = false
			print("SOLIDSHOT %s empty posed eye_ms=%.3f" % [bname, await _time_eye()])
			main.solid.visible = true
		if not quick:
			# The other inside test: the DE's level set alone, no escape gate.
			main.solid.inside_mode = 0.0
			ok = await _build(bname, 192) and ok
			rows[-1]["inside"] = "de_only"
			_shot("%s_solid_192_de_only.png" % bname.to_lower())
			main.solid.inside_mode = 1.0
		# Splats at the same framing, for the side-by-side.
		main.surface_idx = 0
		main._apply_surface()
		for i in 240:
			await process_frame
		_shot("%s_splats.png" % bname.to_lower())
		if not quick:
			print("SOLIDSHOT %s splats posed eye_ms=%.2f baked=%s" % [
				bname, await _time_eye(), str(main.cloud.bake_ready)])
	if not quick:
		await _time_baselines()
	for r in rows:
		print("SOLIDROW %s" % JSON.stringify(r))
	print("SOLIDSHOT %s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)


## The bulb-mode LOOK tile with this label (there are two MOTIONs and two SIZEs; this
## takes the first, which is the bulb's for SURFACE and SOLID).
func _tile(label: String) -> WristMenu.Item:
	for it: WristMenu.Item in main.menu.items:
		if it.label == label:
			return it
	return null


func _tile_visible(label: String) -> bool:
	var it := _tile(label)
	return it != null and (not it.visible_when.is_valid() or bool(it.visible_when.call()))


func _bulb_index(bname: String) -> int:
	for i in main.library.bulbs.size():
		if main.library.bulbs[i].get("name", "") == bname:
			return i
	return 0


func _build(bname: String, n: int) -> bool:
	main.surface_idx = main.SURFACE_SOLID.find(n)
	main._apply_surface()   # re-homes on first entry and starts a build
	await _pose_render_camera()
	# Build again with the key light taken in the posed frame, as the app would have had
	# the bulb been turned to this angle before SOLID was picked. Twice, keeping the
	# cheaper: GPU time from a shared GPU only ever comes out high.
	var s: BulbSolid = main.solid
	var best := {}
	for rep in 2:
		s.clear()
		main._solid_key = "posed%d" % rep
		main._apply_surface()
		var frames := 0
		while not s.is_ready() and frames < 3000:
			await process_frame
			frames += 1
			if frames == 20:
				print("SOLIDSHOT tile while building: SURFACE %s, SOLID shown=%s" % [
					_tile("SURFACE").read.call(), str(_tile_visible("SOLID"))])
			if s.state == BulbSolid.State.IDLE:
				break
		if not s.is_ready():
			print("SOLIDSHOT FAIL %s %d: %s after %d frames" % [bname, n, s.get_error(), frames])
			return false
		for i in 30:
			await process_frame
		if rep == 0:
			print("SOLIDSHOT tile when ready: SURFACE %s" % _tile("SURFACE").read.call())
		if best.is_empty() or s.gpu_ms < best["gpu_ms"]:
			best = {"gpu_ms": s.gpu_ms, "pass_ms": s.pass_ms.duplicate(), "max_slab_ms": s.max_slab_ms,
				"wall_ms": s.wall_ms, "upload_ms": s.upload_ms}
	s.gpu_ms = best["gpu_ms"]
	s.pass_ms = best["pass_ms"]
	s.max_slab_ms = best["max_slab_ms"]
	s.wall_ms = best["wall_ms"]
	s.upload_ms = best["upload_ms"]
	rows.append({"bulb": bname, "grid": n, "verts": s.vert_count, "tris": s.tri_count,
		"overflow": s.overflow, "gpu_ms": snappedf(s.gpu_ms, 0.01),
		"field_ms": snappedf(s.pass_ms["field"], 0.01), "verts_ms": snappedf(s.pass_ms["verts"], 0.01),
		"quads_ms": snappedf(s.pass_ms["quads"], 0.01), "light_ms": snappedf(s.pass_ms["light"], 0.01),
		"slabs": s.slabs, "timed_slabs": s.timed_slabs, "max_slab_ms": snappedf(s.max_slab_ms, 0.01),
		"frames": s.build_frames, "wall_ms": snappedf(s.wall_ms, 1.0),
		"upload_ms": snappedf(s.upload_ms, 0.1), "inside": "escape"})
	print("SOLIDSHOT %s %d tris=%d verts=%d gpu=%.1fms (%d of %d slabs timed, max %.2fms) frames=%d wall=%.0fms upload=%.1fms%s" % [
		bname, n, s.tri_count, s.vert_count, s.gpu_ms, s.timed_slabs, s.slabs, s.max_slab_ms,
		s.build_frames, s.wall_ms, s.upload_ms, " OVERFLOW" if s.overflow else ""])
	return true


## The Mandelbulber camera from gen_fract.py: 0.7 m out, looking 12.4 degrees down at the
## bulb, 30 degrees round it, pole axis up. Mandelbulber is z-up, so state z goes to world
## up here; the solid's re-home already put it 0.7 m ahead and 0.15 m below the eye.
func _pose_render_camera() -> void:
	var c: Node3D = main.cloud
	var basis := Basis(Vector3.UP, deg_to_rad(30.0)) * Basis(Vector3.RIGHT, deg_to_rad(-90.0))
	c.global_transform = Transform3D(basis.scaled(c.global_transform.basis.get_scale()),
		c.global_transform.origin)
	main.xr_camera.look_at(c.global_transform.origin, Vector3.UP)
	main.xr_camera.fov = 40.0
	for i in 10:
		await process_frame


func _debug_views(bname: String, n: int) -> void:
	var m: ShaderMaterial = main.solid.material_override
	for dv in [1, 2, 3]:
		m.set_shader_parameter("debug_view", dv)
		for i in 3:
			await process_frame
		_shot("%s_solid_%d_%s.png" % [bname.to_lower(), n, ["", "ao", "shadow", "ndl"][dv]])
	m.set_shader_parameter("debug_view", 0)


func _shot(file: String) -> void:
	var img := root.get_viewport().get_texture().get_image()
	img.save_png(OUT + file)
	print("SOLIDSHOT shot %s" % file)


## One Quest-sized eye, rendered by a SubViewport sharing the scene, from wherever the
## harness camera stands: mean GPU ms over TIME_FRAMES after a warm-up.
func _time_eye() -> float:
	if eye_vp == null:
		eye_vp = SubViewport.new()
		eye_vp.size = EYE
		eye_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		eye_cam = Camera3D.new()
		eye_cam.fov = EYE_FOV
		eye_vp.add_child(eye_cam)
		root.add_child(eye_vp)
		RenderingServer.viewport_set_measure_render_time(eye_vp.get_viewport_rid(), true)
	eye_vp.msaa_3d = root.get_viewport().msaa_3d
	eye_cam.global_transform = main.xr_camera.global_transform
	for i in 30:
		await process_frame
	# The quietest of four windows: anything else on the GPU (another agent's Godot, the
	# compositor) only ever adds time, so the minimum is the closest to this scene alone.
	var best := INF
	for w in 4:
		var acc := 0.0
		for i in TIME_FRAMES / 4:
			await process_frame
			acc += RenderingServer.viewport_get_measured_render_time_gpu(eye_vp.get_viewport_rid())
		best = minf(best, acc / float(TIME_FRAMES / 4))
	last_prims = eye_vp.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE,
		Viewport.RENDER_INFO_PRIMITIVES_IN_FRAME)
	return snappedf(best, 0.001)


## Primitives the eye drew in the last timed frame, so the calibration loads can be
## compared by geometry as well as by time.
var last_prims := 0


## The loads with a warm headset figure on record, timed the same way from the app's own
## framing: bulb splats as the toy (13.9 ms at 1680), the tree (4.5 ms) and the IFS
## (5.4 ms). Plus the solid at its own home framing, and an empty bulb scene.
func _time_baselines() -> void:
	main.xr_camera.fov = 75.0
	main.xr_camera.position = Vector3(0.0, 1.6, 0.0)
	main.xr_camera.rotation = Vector3.ZERO
	main._load_bulb(_bulb_index("Classic"))
	main._bulb.clock = 0.0
	main.surface_idx = 0
	main._apply_surface()
	main._recenter()
	for i in 240:
		await process_frame
	_shot("classic_splats_toy.png")
	print("SOLIDBASE splats_toy eye_ms=%.3f prims=%d (Quest 13.9 ms)" % [await _time_eye(), last_prims])
	# SOLID from scratch, as the menu does it: re-home, build, swap.
	for n in [192, 256]:
		main.surface_idx = main.SURFACE_SOLID.find(n)
		main._apply_surface()
		while not main.solid.is_ready():
			await process_frame
		for i in 30:
			await process_frame
		_shot("classic_solid_%d_home.png" % n)
		print("SOLIDBASE solid%d_home_msaa4 eye_ms=%.3f prims=%d" % [n, await _time_eye(), last_prims])
		main._set_solid_msaa(false)
		print("SOLIDBASE solid%d_home_nomsaa eye_ms=%.3f prims=%d" % [n, await _time_eye(), last_prims])
		main._set_solid_msaa(true)
	main.solid.visible = false
	print("SOLIDBASE empty_home eye_ms=%.3f prims=%d" % [await _time_eye(), last_prims])
	main.solid.visible = true
	main._set_mode("tree")
	for i in 600:
		await process_frame
	_shot("calib_tree.png")
	print("SOLIDBASE tree eye_ms=%.3f prims=%d (Quest 4.5 ms)" % [await _time_eye(), last_prims])
	main._set_mode("ifs")
	for i in 300:
		await process_frame
	_shot("calib_ifs.png")
	print("SOLIDBASE ifs_echoes eye_ms=%.3f prims=%d echoes=%d (Quest 5.4 ms)" % [
		await _time_eye(), last_prims, main.ifs_echoes.count()])
	main.ifs_echoes.set_step(main.ifs_echoes.STEPS.size() - 1)   # off
	for i in 30:
		await process_frame
	print("SOLIDBASE ifs_no_echoes eye_ms=%.3f prims=%d" % [await _time_eye(), last_prims])
