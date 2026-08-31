extends Node3D

## FractalXR native. Chaos game in compute, splat through the rasteriser.
##
## That split is the result of the phase-1 measurement, not a guess: replacing the
## rasteriser with imageAtomicAdd cost 90-131ms a frame on Adreno against 14.35ms
## for rasterised points, because a tiler does additive blend in tile memory while
## global atomics serialise on contention. See README.
##
## ADDING A FRACTAL TYPE: write a compute shader plus a FractalSource subclass, then
## put it in SOURCES below. The cloud, renderer, grab, controls and HUD are all
## type-agnostic and need no changes.

const TEX_SIZE := 2048                              # 4,194,304 particles available
# Ordered so the default sits where the headset measured 8.2ms app GPU and zero stale
# frames. Above that the compositor starts reprojecting dropped frames, and reprojection
# ghosts anything in motion: that is the "resolution decays as soon as it moves" smear,
# not a resolution setting at all. Frame budget is a sharpness setting here.
# 3.36M and 4.19M are gone: measured at 21-24fps, which puts the compositor into
# reprojection and smears everything in motion. 2.52M is the last usable step and even
# that runs at 33-47fps, so it is really a stills setting.
const PARTICLE_STEPS := [0.25, 0.35, 0.45, 0.6, 0.15]
# 1.0 is the floor: a rasterised point cannot be smaller than one pixel. Below that,
# "finer" means more pixels (RENDER_STEPS) or less energy per point (BRIGHT_STEPS).
# 1.0 first: every on-device comparison has preferred the smallest point. Larger sizes
# read as blur, not as glow, because the cloud is already dense enough to cover.
const POINT_STEPS := [1.0, 1.25, 1.5, 2.0]
# Softer, not tighter. A point that fades across its whole sprite changes weight
# smoothly as sub-pixel position drifts; a hard-edged one flips on and off.
const SHARPNESS := [3.0, 3.0, 3.5, 4.0]
# Splat radius in metres, before the cloud's own scale. Bulbs want the larger end: a
# distance-estimate shell is a surface, and a surface wants overlapping discs.
const SPLAT_STEPS := [0.006, 0.010, 0.016, 0.026, 0.042, 0.003]
const COLOUR_CYCLES := [1.0, 2.0, 3.0, 4.0]
# Per-point brightness is really "how many particles may overlap before the buffer
# clips". At 0.7 that number is 1.4, which is why dense cores came out as flat white
# with no hue. Forward Mobile's colour buffer is 10-bit fixed point, so the only way to
# get density range out of it is to make each point contribute a small fraction and let
# the tonemapper expand it again. 0.02 gives roughly 50 clean overlaps.
const BRIGHT_STEPS := [0.01, 0.02, 0.05, 0.12, 0.3, 0.7]
# Wider range, because low per-point brightness has to be paid back here.
const EXPOSURE_MUL := [1.0, 2.0, 4.0, 8.0, 16.0, 32.0]
# Forward+ buys the HDR buffer that flam3 needs, but it is far more expensive per
# pixel than Forward Mobile: 2800x2800 costs ~80ms of draw. Resolution is now the
# primary budget lever rather than a free win, so the default sits low and climbs
# only if the measurement says there is room.
const RENDER_STEPS := [0.6, 0.75, 1.0, 1.25]     # eye buffer multiplier
const ITER_STEPS := [1, 2, 4, 6, 8]
const STABILITY := [0, 1, 2, 4, 8, 16]   # 1/n of the cloud per frame; 0 = frozen
# A morph iterates the cloud the whole way through, so by the time it finishes the
# particles are already on the final attractor. Only a fresh load needs a long settle.
const CONVERGE_FRAMES := 150             # ~2s at 72Hz, for a cold start
const SETTLE_FRAMES := 30                # after a morph, which has already converged it
const MEASURE_EVERY := 12                # frames between framing updates while moving
# A sixth of the cloud per frame during a transition. This is NOT a performance trade:
# the cost is the same either way. It is sampling. Every particle the chaos game touches
# teleports elsewhere on the attractor, so the more of them that move per frame, the more
# of the image is uncorrelated frame to frame, which reads as a loss of detail. Over a
# six-second morph a sixth still gives each particle around fifty updates, far more than
# enough to track a genome changing that slowly.
const MORPH_UPDATE_MOD := 6
# Ambient tumble. Rigid rotation is temporally coherent, so it adds life without the
# per-pixel churn that iterating the chaos game causes. Two near-coprime rates on
# different axes read as a slow swirl rather than a turntable.
const AMBIENT_SPIN := 0.075              # rad/s about Y: a full turn in ~84s
const AMBIENT_TILT := 0.011              # rad/s about X, for the swirl
const MORPH_STEPS := [6.0, 10.0, 16.0, 28.0, 45.0, 3.0]   # seconds per transition
const DRIFT_HOLD := 8.0               # seconds settled on a preset before drifting on
const TARGET_HZ := 72.0
# Distance and height at which the cloud is placed in front of the viewer. Not a world
# position: the play-space origin is wherever the guardian happens to have been set up,
# so a fixed point put the cloud off to one side for anyone not standing on it.
const HOME_DISTANCE := 2.6
const HOME_DROP := 0.15

@onready var xr_origin: XROrigin3D = $XROrigin3D
@onready var xr_camera: XRCamera3D = $XROrigin3D/XRCamera3D
@onready var left_hand: XRController3D = $XROrigin3D/LeftHand
@onready var right_hand: XRController3D = $XROrigin3D/RightHand
@onready var hud: Label3D = $XROrigin3D/XRCamera3D/Hud
var menu := WristMenu.new()

var xr: OpenXRInterface = null
var cloud := ParticleCloud.new()
var library := PresetLibrary.new()
var grab: WorldGrab = null
var tonemap := Flam3Tonemap.new()
var tone_on := true

var preset_idx := 0
var particle_idx := 0      # 1.05M: 8.2ms app GPU, zero stale frames, no reprojection
var point_idx := 0         # 1.0px
var bright_idx := 1        # 0.02
var render_idx := 2        # full recommended eye buffer; sharpness matters more than the ~1ms
var stability_idx := 0     # frozen: a settled cloud is dramatically cleaner
var _converge := CONVERGE_FRAMES
var spin := true
var exposure_idx := 0      # measured on-device as the best-looking end of the range
var iter_idx := 2          # 4 iterations

var _setup_done := false
var _status := ""
var _hud_accum := 0.0
var _uptime := 0.0
var _eye_res := Vector2i.ZERO
var _prev := {}
var _placed := false
var _morph_from_idx := 0
var _pending_cache := -1
var _cache_gen := 0
var _menu_active := false
var _measure_countdown := 0
## Framing per preset, measured once then reused. With both endpoints known a morph can
## interpolate the framing on the same curve as the shape, so it moves WITH the flame
## instead of trailing it by the easing time constant.
var _framing: Dictionary = {}
var _base_exposure := 0.32

# Transitions. The flame never cuts between presets: it morphs, because watching one
# genome become another is the thing worth putting a headset on for.
var _morph_from: Dictionary = {}
var _morph_to: Dictionary = {}
var _morph_t := 1.0
var _drift := true
var _drift_hold := 0.0
var morph_idx := 0
## Flames and bulbs are two FractalSource families sharing one renderer.
var bulb_mode := false
var bulb_idx := 0
var _bulb: BulbSource = null
var splat_on := false
var splat_idx := 1
var colour_idx := 0
var _flame_bright_idx := 1
var _flame_exposure_idx := 0
## Inside the cloud rather than looking at it from outside. A distance-estimate surface
## surrounds you, and Sam's read from the WebXR splat was that it looks dramatically
## better from within, so bulbs are placed to enclose the viewer by default.
# Enclosing but not cavernous. At 3.4 you are so deep inside a sparse shell that it
# reads as scattered dust rather than a surface.
const BULB_INSIDE_SCALE := 2.1
# The distance estimate costs roughly fifteen DE evaluations per particle per step,
# against a handful of multiply-adds for the chaos game: measured at 37.8ms for 1.05M
# particles, against 2.8ms for the same count of flame. src/engine/Simulation.ts hits
# the same wall and answers it with activeTexels. Two levers here: fewer particles, and
# only a quarter of them stepping per frame. The surface only breathes, so a particle
# that updates every fourth frame tracks it perfectly well.
# Splats cost six vertices per particle against one for a point, plus real fill where
# points had almost none. Measured at 57.5ms for 1.05M splats: four times over budget.
# A splat covers far more screen area than a pixel, so it does not need the same count
# to read as solid, which is why fewer-and-bigger is the right trade here.
const BULB_PARTICLES := 0.07      # of the 2048^2 grid, so ~294K
const BULB_UPDATE_MOD := 6
# Bulbs need a completely different look from flames, and using the flame's settings is
# why the first attempt came out as scattered specks. A flame stacks dozens of points on
# a pixel, so each contributes a sliver (0.02) and the tone curve builds the image out of
# accumulated density. A bulb is a thin SHELL: about one point per pixel, nothing to
# accumulate, so each point has to carry its own weight.
const BULB_BRIGHT_IDX := 4        # 0.3, against 0.02 for flames
const BULB_EXPOSURE_IDX := 0      # points are already bright, so do not push the curve


func _ready() -> void:
	add_child(cloud)

	if not library.load_all():
		_fail("presets: %s" % library.load_error)
		return

	# flam3 replaces Godot's tonemapper rather than stacking on it; main.tscn sets the
	# environment to LINEAR so only one curve applies.
	var comp := Compositor.new()
	comp.compositor_effects = [tonemap]
	$WorldEnvironment.compositor = comp

	_init_xr()
	_eye_res = _current_eye_res()
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)

	var hands: Array[XRController3D] = [left_hand, right_hand]
	grab = WorldGrab.new(hands, cloud)
	_build_menu()

	RenderingServer.call_on_render_thread(_setup_gpu)


func _setup_gpu() -> void:
	var ok := cloud.setup(TEX_SIZE)
	call_deferred("_on_gpu_ready", ok)


func _on_gpu_ready(ok: bool) -> void:
	if not ok:
		_fail(cloud.get_error())
		return
	cloud.set_count(int(TEX_SIZE * TEX_SIZE * PARTICLE_STEPS[particle_idx]))
	_apply_point_look()
	if not _load_preset(0):
		return
	_setup_done = true
	print("[fractal] ready: %d presets, %d particles" % [library.count(), cloud.get_count()])


func _load_preset(i: int) -> bool:
	preset_idx = wrapi(i, 0, library.count())
	var preset := library.at(preset_idx)
	_morph_from = preset
	_morph_to = preset
	_morph_t = 1.0
	var src := FlameSource.new(preset)
	src.iterations = ITER_STEPS[iter_idx]
	src.update_mod = STABILITY[stability_idx]
	_apply_tone(preset)
	# set_source touches the RenderingDevice, so it has to happen on the render thread.
	# Failures surface through cloud.get_error() on a later frame rather than here.
	RenderingServer.call_on_render_thread(cloud.set_source.bind(src))
	return true


## Menu spec: section, label, read, advance. Adding a setting is one entry and nothing
## else; the menu knows nothing about particle counts or exposures.
func _build_menu() -> void:
	menu.items = [
		WristMenu.Item.new("create", "RANDOM",
			func(): return "new flame", func(): _morph_to_new(Breed.random_genome(
				library.next_serial(), library.themes))),
		WristMenu.Item.new("create", "MUTATE",
			func(): return "vary this", func(): _morph_to_new(Breed.mutate(
				library.at(preset_idx), library.next_serial()))),
		WristMenu.Item.new("create", "BREED",
			func(): return "mix two", func(): _morph_to_new(Breed.crossover(
				library.at(preset_idx), library.at(preset_idx + 1 + randi() % maxi(1, library.count() - 1)),
				library.next_serial()))),

		WristMenu.Item.new("explore", "MODE",
			func(): return "bulb" if bulb_mode else "flame",
			func(): _set_bulb_mode(not bulb_mode)),
		WristMenu.Item.new("explore", "FLAME",
			func(): return library.bulbs[bulb_idx].get("name", "?") if bulb_mode else "next",
			func():
				if bulb_mode:
					_load_bulb(bulb_idx + 1)
				else:
					_morph_to_preset(preset_idx + 1)),
		WristMenu.Item.new("explore", "DRIFT",
			func(): return "on" if _drift else "off",
			func(): _drift = not _drift; _drift_hold = 0.0),
		WristMenu.Item.new("explore", "SPIN",
			func(): return "on" if spin else "off", func(): spin = not spin),
		WristMenu.Item.new("explore", "SPEED",
			func(): return "%ds" % int(MORPH_STEPS[morph_idx]),
			func(): morph_idx = (morph_idx + 1) % MORPH_STEPS.size()),
		WristMenu.Item.new("explore", "CENTRE",
			func(): return "reset", func(): _recenter(); cloud.request_measure()),

		WristMenu.Item.new("tune", "POINTS",
			func(): return _fmt_count(cloud.get_count()),
			func():
				particle_idx = (particle_idx + 1) % PARTICLE_STEPS.size()
				cloud.set_count(int(TEX_SIZE * TEX_SIZE * PARTICLE_STEPS[particle_idx]))
				cloud.request_measure()),
		WristMenu.Item.new("tune", "SPLAT",
			func(): return "%.0fmm" % (SPLAT_STEPS[splat_idx] * 1000.0) if splat_on else "off",
			func():
				if not splat_on:
					splat_on = true
				else:
					splat_idx = (splat_idx + 1) % SPLAT_STEPS.size()
					if splat_idx == 0:
						splat_on = false
				_apply_point_look()),
		WristMenu.Item.new("tune", "SIZE",
			func(): return "%.2f" % POINT_STEPS[point_idx],
			func(): point_idx = (point_idx + 1) % POINT_STEPS.size(); _apply_point_look()),
		WristMenu.Item.new("tune", "COLOUR",
			func(): return "%dx" % int(COLOUR_CYCLES[colour_idx]),
			func():
				colour_idx = (colour_idx + 1) % COLOUR_CYCLES.size()
				_apply_point_look()),
		WristMenu.Item.new("tune", "BRIGHT",
			func(): return "%.3f" % BRIGHT_STEPS[bright_idx],
			func(): bright_idx = (bright_idx + 1) % BRIGHT_STEPS.size(); _apply_point_look()),

		WristMenu.Item.new("render", "EXPOSURE",
			func(): return "%.0fx" % EXPOSURE_MUL[exposure_idx],
			func(): exposure_idx = (exposure_idx + 1) % EXPOSURE_MUL.size(); _apply_exposure()),
		WristMenu.Item.new("render", "MOTION",
			func():
				if bulb_mode:
					return "1/%d" % BULB_UPDATE_MOD
				return "frozen" if STABILITY[stability_idx] == 0 else "1/%d" % STABILITY[stability_idx],
			func(): stability_idx = (stability_idx + 1) % STABILITY.size()),
		WristMenu.Item.new("render", "DETAIL",
			func(): return "%.2fx" % RENDER_STEPS[render_idx],
			func():
				render_idx = (render_idx + 1) % RENDER_STEPS.size()
				if xr != null:
					xr.render_target_size_multiplier = RENDER_STEPS[render_idx]),
	]
	menu.title = func():
		return str(library.bulbs[bulb_idx].get("name", "?")) if bulb_mode else library.name_at(preset_idx)
	menu.status_side = func():
		if _morph_t < 1.0:
			return "morphing"
		return "drifting" if _drift else ""

	menu.status_main = func():
		return "%.0f fps  ·  %d flames  ·  %.1f ms" % [
			Engine.get_frames_per_second(), library.count(),
			RenderingServer.viewport_get_measured_render_time_gpu(get_viewport().get_viewport_rid())
				+ cloud.iterate_us / 1000.0]
	# Worn like a watch: inside of the left forearm, tilted up toward the face.
	menu.transform = Transform3D(Basis(), Vector3(0.0, 0.05, 0.03))
	menu.rotation_degrees = Vector3(-55.0, 0.0, 0.0)
	left_hand.add_child(menu)
	menu.setup(xr_camera, right_hand)
	# The floating readout is retired: it was a debug tool that sat in the view whether
	# or not it was wanted. Status now lives on the wrist with everything else.
	hud.visible = false


func _apply_tone(preset: Dictionary) -> void:
	var tone := PresetLibrary.tone_of(preset)
	tonemap.set_tone(tone)
	_base_exposure = float(tone["exposure"])
	_apply_exposure()


## Begin a transition to another preset. The current genome is the start point even if
## it is itself mid-morph, so interrupting a transition bends it rather than snapping.
func _morph_to_preset(i: int) -> void:
	if not _setup_done or cloud.source == null:
		return
	var _from_idx := preset_idx
	preset_idx = wrapi(i, 0, library.count())
	_morph_from = _current_genome()
	_morph_from_idx = _from_idx
	_morph_to = library.at(preset_idx)
	_morph_t = 0.0
	_converge = CONVERGE_FRAMES


## Generate a flame, add it to the gallery, and morph to it. Generated flames are
## first-class: drift wanders through them and they can be mutated again, so a lineage
## builds up over a session.
## Switch between the flame gallery and the bulb gallery. Both are FractalSources over
## the same particle cloud, so everything else is untouched.
func _set_bulb_mode(on: bool) -> void:
	bulb_mode = on
	if on:
		_flame_bright_idx = bright_idx
		_flame_exposure_idx = exposure_idx
		bright_idx = BULB_BRIGHT_IDX
		exposure_idx = BULB_EXPOSURE_IDX
		# A distance-estimate shell is a surface: splat it. This is the whole reason the
		# WebXR splat build reads better than a point cloud from the inside.
		splat_on = true
		splat_idx = 1
		colour_idx = 1
		_apply_point_look()
		_apply_exposure()
		_load_bulb(bulb_idx)
	else:
		bright_idx = _flame_bright_idx
		exposure_idx = _flame_exposure_idx
		splat_on = false
		colour_idx = 0
		_apply_point_look()
		_apply_exposure()
		_bulb = null
		cloud.scale = Vector3.ONE
		cloud.set_count(int(TEX_SIZE * TEX_SIZE * PARTICLE_STEPS[particle_idx]))
		_load_preset(preset_idx)
	_recenter()


func _load_bulb(i: int) -> void:
	if library.bulbs.is_empty():
		return
	bulb_idx = wrapi(i, 0, library.bulbs.size())
	_bulb = BulbSource.new(library.bulbs[bulb_idx])
	_bulb.update_mod = BULB_UPDATE_MOD
	cloud.set_count(int(TEX_SIZE * TEX_SIZE * BULB_PARTICLES))
	RenderingServer.call_on_render_thread(cloud.set_source.bind(_bulb))
	# Blow it up around the viewer. Auto-framing normalises the cloud to a unit radius,
	# so this scale is what puts you inside the surface rather than in front of it.
	cloud.scale = Vector3.ONE * BULB_INSIDE_SCALE
	_converge = CONVERGE_FRAMES
	cloud.request_measure()


func _morph_to_new(g: Dictionary) -> void:
	_morph_to_preset(library.add(g))


func _current_genome() -> Dictionary:
	if _morph_t >= 1.0:
		return _morph_to
	return Morph.interpolate(_morph_from, _morph_to, Morph.smoothstep_t(_morph_t))


## True while the cloud still needs to move: settling onto a new genome, or following
## one that is currently changing under it.
func _should_iterate() -> bool:
	return _converge > 0 or _morph_t < 1.0


func _sync_iteration() -> void:
	var src := cloud.source as FlameSource
	if src == null:
		return
	# A frozen cloud that is morphing would keep the old attractor's points while the
	# genome moved out from under them, so a morph always forces iteration.
	if bulb_mode:
		return
	if _morph_t < 1.0:
		src.update_mod = MORPH_UPDATE_MOD
	elif _converge > 0:
		src.update_mod = 1
	else:
		src.update_mod = STABILITY[stability_idx]


func _tick_morph(delta: float) -> void:
	if bulb_mode:
		return
	# With both endpoints known, drive the framing along the morph curve directly. Only
	# fall back to measuring when a preset has not been seen yet.
	var a_known: bool = _framing.has(_morph_from_idx)
	var b_known: bool = _framing.has(preset_idx)
	if _morph_t < 1.0 and a_known and b_known:
		var fa: Dictionary = _framing[_morph_from_idx]
		var fb: Dictionary = _framing[preset_idx]
		var k := Morph.smoothstep_t(_morph_t)
		cloud.set_framing(
			(fa["center"] as Vector3).lerp(fb["center"] as Vector3, k),
			lerpf(fa["fit"], fb["fit"], k))
	elif _should_iterate():
		_measure_countdown -= 1
		if _measure_countdown <= 0:
			_measure_countdown = MEASURE_EVERY
			cloud.request_measure()
	if _morph_t >= 1.0:
		if _drift:
			_drift_hold += delta
			if _drift_hold >= DRIFT_HOLD:
				_drift_hold = 0.0
				# Step by a coprime stride so a drift session tours the whole gallery
				# instead of ping-ponging between neighbours.
				_morph_to_preset(preset_idx + 5)
		return

	var was := _morph_t
	_morph_t = minf(1.0, _morph_t + delta / MORPH_STEPS[morph_idx])
	if was < 1.0 and _morph_t >= 1.0:
		# The morph already iterated it onto the final genome; a brief settle is enough.
		# The old two-second convergence meant two seconds of every particle re-rolling
		# after each transition, which read as a churn before it went still.
		_converge = SETTLE_FRAMES
	var g := Morph.interpolate(_morph_from, _morph_to, Morph.smoothstep_t(_morph_t))
	_apply_tone(g)
	var src := cloud.source as FlameSource
	if src != null:
		src.set_preset(g)
		cloud.apply_look()
		RenderingServer.call_on_render_thread(src.update_params)


func _fail(msg: String) -> void:
	_status = "FAILED: %s" % msg
	push_error(_status)
	print("[fractal] %s" % _status)


func _init_xr() -> void:
	xr = XRServer.find_interface("OpenXR") as OpenXRInterface
	if xr == null or not xr.is_initialized():
		_status = "OpenXR unavailable. Running flat, no stereo."
		xr = null
		return
	get_viewport().use_xr = true
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	if xr.is_foveation_supported():
		# Dynamic foveation ramps peripheral resolution DOWN under load, which reads as
		# the image looking sharp for a few seconds after any change and then quietly
		# degrading. For a cloud that fills the view it is the wrong trade.
		xr.set_foveation_level(0)
		xr.set_foveation_dynamic(false)
	xr.foveation_with_subsampled_images = false
	# Whatever is degrading the image over a few seconds resets whenever the session
	# reconfigures, so log the things that can do that and watch which one moves.
	print("[fractal] foveation level=%d dynamic=%s subsampled=%s vrs=%d" % [
		xr.foveation_level, str(xr.foveation_dynamic),
		str(xr.foveation_with_subsampled_images),
		ProjectSettings.get_setting("rendering/vrs/mode", 0)])
	var rates := xr.get_available_display_refresh_rates()
	if rates.has(TARGET_HZ):
		xr.set_display_refresh_rate(TARGET_HZ)
	# Phase 2 measured the point rendering as vertex-bound, not fill-bound: cutting the
	# eye buffer 2.8x saved only 1ms. 0.75 lands near the Quest 3's native ~2064x2208
	# and costs nothing visually, so take the free ~1ms and move on.
	xr.render_target_size_multiplier = RENDER_STEPS[render_idx]
	print("[fractal] OpenXR up. refresh=%.1f target=%s views=%d" % [
		xr.get_display_refresh_rate(), str(xr.get_render_target_size()), xr.get_view_count()])


## Directly in front of the viewer, at their eye height, using only the yaw of their
## head so the cloud never inherits a pitch or roll.
func _home_transform() -> Transform3D:
	var cam := xr_camera.global_transform
	var fwd := -cam.basis.z
	fwd.y = 0.0
	if fwd.length_squared() < 1e-4:
		fwd = Vector3.FORWARD
	fwd = fwd.normalized()
	var pos := cam.origin + fwd * HOME_DISTANCE
	pos.y = cam.origin.y - HOME_DROP
	return Transform3D(Basis(), pos)


func _recenter() -> void:
	var t := _home_transform()
	if grab != null:
		grab.reset(t)
	else:
		cloud.global_transform = t


func _current_eye_res() -> Vector2i:
	if xr != null:
		return Vector2i(xr.get_render_target_size())
	return get_viewport().get_visible_rect().size


func _process(delta: float) -> void:
	_uptime += delta
	cloud.ease_framing(delta)
	if not _placed and _setup_done and xr_camera.global_transform.origin.length_squared() > 1e-6:
		_placed = true
		_recenter()
	_menu_active = menu.update(delta)
	if _bulb != null:
		# The breath is the animation: each genome slowly reshapes whichever parameter
		# defines its form, so the surface is never static.
		_bulb.clock += delta
	_tick_morph(delta)
	if _converge > 0:
		_converge -= 1
		if _converge == 0 and _morph_t >= 1.0:
			# Settled: record this preset's framing so future morphs to or from it can
			# interpolate rather than chase.
			_cache_gen = cloud.measure_generation
			cloud.request_measure()
			_pending_cache = preset_idx
	# Wait for the measurement to actually land. A dispatch takes a frame and the
	# readback another, so reading immediately captured the previous preset's framing.
	if _pending_cache >= 0 and cloud.measure_generation != _cache_gen:
		var m := cloud.measured()
		if m["fit"] > 0.0:
			_framing[_pending_cache] = m
			print("[cloud] cached framing for %s" % library.name_at(_pending_cache))
		_pending_cache = -1
	_sync_iteration()
	if spin and (grab == null or not grab.is_grabbing()):
		cloud.rotate_y(AMBIENT_SPIN * delta)
		cloud.rotate_object_local(Vector3.RIGHT, AMBIENT_TILT * delta)
	if grab != null:
		grab.update(delta)
	_handle_input(delta)
	_update_hud(delta)
	if not _setup_done:
		return
	_eye_res = _current_eye_res()
	if _status == "" and cloud.get_error() != "":
		_fail(cloud.get_error())
	RenderingServer.call_on_render_thread(cloud.iterate)


# --- controls ---------------------------------------------------------------
#
# Grip (either or both)  grab the cloud: one hand moves and rotates it, two hands
#                        also scale it, so you can pull it open and fly through
# Right stick X / Y      yaw the cloud / push it away and pull it back
# Left stick Y           scale
# Right trigger          next preset          Left trigger   previous preset
# A (right)              particle count       B (right)      point size
# X (left)               reset position       Y (left)       reseed

func _handle_input(delta: float) -> void:
	var rs := Vector2.ZERO
	var ls := Vector2.ZERO
	if right_hand != null and right_hand.get_has_tracking_data():
		rs = right_hand.get_vector2("primary")
	if left_hand != null and left_hand.get_has_tracking_data():
		ls = left_hand.get_vector2("primary")
	if xr == null:
		rs = Vector2(Input.get_axis("ui_left", "ui_right"), Input.get_axis("ui_down", "ui_up"))

	# Stick nudges are disabled while grabbing: fighting the hand for control of the
	# same transform makes the cloud feel like it is slipping.
	if grab == null or not grab.is_grabbing():
		if absf(rs.x) > 0.15:
			cloud.rotate_y(rs.x * 1.2 * delta)
		if absf(rs.y) > 0.15:
			var fwd := -xr_camera.global_transform.basis.z
			cloud.global_translate(fwd * rs.y * 1.5 * delta)
		if absf(ls.y) > 0.15:
			var s := clampf(cloud.scale.x * (1.0 + ls.y * delta), 0.05, 40.0)
			cloud.scale = Vector3.ONE * s

	if _pressed(right_hand, "trigger_click") or _key(KEY_RIGHT):
		if _menu_active:
			menu.activate()
		else:
			_morph_to_preset(preset_idx + 1)
	if _pressed(left_hand, "trigger_click") or _key(KEY_LEFT):
		_morph_to_preset(preset_idx - 1)
	if _pressed(left_hand, "menu_button") or _key(KEY_D):
		_drift = not _drift
		_drift_hold = 0.0
	if _pressed(right_hand, "ax_button") or _key(KEY_1):
		particle_idx = (particle_idx + 1) % PARTICLE_STEPS.size()
		cloud.set_count(int(TEX_SIZE * TEX_SIZE * PARTICLE_STEPS[particle_idx]))
		cloud.request_measure()
	if _pressed(right_hand, "by_button") or _key(KEY_2):
		point_idx = (point_idx + 1) % POINT_STEPS.size()
		_apply_point_look()
	if _pressed(right_hand, "primary_click") or _key(KEY_3):
		bright_idx = (bright_idx + 1) % BRIGHT_STEPS.size()
		_apply_point_look()
	if _pressed(left_hand, "primary_click") or _key(KEY_4):
		stability_idx = (stability_idx + 1) % STABILITY.size()
	if _key(KEY_W):
		spin = not spin
	if _pressed(left_hand, "ax_button") or _key(KEY_R):
		_recenter()
		cloud.request_measure()
	if _pressed(left_hand, "by_button") or _key(KEY_5):
		exposure_idx = (exposure_idx + 1) % EXPOSURE_MUL.size()
		_apply_exposure()
	if _key(KEY_S):
		cloud.request_seed()
		_converge = CONVERGE_FRAMES
	if _pressed(right_hand, "menu_button") or _key(KEY_6):
		render_idx = (render_idx + 1) % RENDER_STEPS.size()
		if xr != null:
			xr.render_target_size_multiplier = RENDER_STEPS[render_idx]


## Point size, falloff tightness and brightness move together: they are three ways of
## saying the same thing about how fine a particle reads, and splitting them across
## three buttons would just mean hunting for a combination that already pairs up.
func _apply_point_look() -> void:
	cloud.set_palette_cycles(COLOUR_CYCLES[colour_idx])
	cloud.set_splat(splat_on, SPLAT_STEPS[splat_idx])
	cloud.set_point_size(POINT_STEPS[point_idx])
	cloud.set_sharpness(SHARPNESS[point_idx])
	cloud.set_brightness(BRIGHT_STEPS[bright_idx])


## On Forward Mobile the flam3 pass cannot run (fixed-point colour buffer, no storage
## bit), so the compressive curve is the Environment's own tonemapper and this dial
## drives its exposure. The preset's flam3 exposure is still the starting point, scaled
## up because that value was tuned against an HDR accumulation buffer, not a 10-bit one.
func _apply_exposure() -> void:
	tonemap.exposure = _base_exposure * EXPOSURE_MUL[exposure_idx]
	var env: Environment = $WorldEnvironment.environment
	if env != null:
		env.tonemap_exposure = clampf(_base_exposure * 3.0 * EXPOSURE_MUL[exposure_idx], 0.05, 60.0)


func _pressed(c: XRController3D, action: String) -> bool:
	if c == null:
		return false
	var now := c.is_button_pressed(action)
	var key := "%s/%s" % [c.name, action]
	var was: bool = _prev.get(key, false)
	_prev[key] = now
	return now and not was


func _key(code: Key) -> bool:
	var key := "k%d" % code
	var now := Input.is_key_pressed(code)
	var was: bool = _prev.get(key, false)
	_prev[key] = now
	return now and not was


# --- HUD --------------------------------------------------------------------

func _update_hud(delta: float) -> void:
	_hud_accum += delta
	if _hud_accum < 0.25:
		return
	_hud_accum = 0.0

	var vp := get_viewport().get_viewport_rid()
	var gpu := RenderingServer.viewport_get_measured_render_time_gpu(vp)
	var sim := cloud.iterate_us / 1000.0
	var fps := Engine.get_frames_per_second()
	var grabbing := 0 if grab == null else grab.grip_count()

	var lines := [
		"%s  (%d/%d)%s" % [library.name_at(preset_idx), preset_idx + 1, library.count(),
			("   morph %d%%" % int(_morph_t * 100.0)) if _morph_t < 1.0
			else ("   DRIFT" if _drift else "")],
		"%.0f fps   draw %.1f ms   sim %.1f ms" % [fps, gpu, sim],
		"%s pts   %.2fpx   bright %.3f   x%.2f   %s%s" % [
			_fmt_count(cloud.get_count()), POINT_STEPS[point_idx], BRIGHT_STEPS[bright_idx],
			RENDER_STEPS[render_idx],
			("settling" if _should_iterate() else
				("frozen" if STABILITY[stability_idx] == 0 else "1/%d" % STABILITY[stability_idx])),
			"   GRAB x%d" % grabbing if grabbing > 0 else ""],
		"eye %dx%d   exp %.2fx   tone %s   %s" % [
			_eye_res.x, _eye_res.y, EXPOSURE_MUL[exposure_idx],
			"ON" if tonemap.enabled else "off", _fmt_time(_uptime)],
	]
	if _status != "":
		lines.append(_status)
	hud.text = "\n".join(lines)

	# Log the levers that could be quietly reducing image quality over time, so the
	# degradation can be attributed instead of guessed at.
	var vp_size := get_viewport().get_visible_rect().size
	print("[perf] t=%.1f fps=%.1f draw_ms=%.3f sim_ms=%.3f fov=%d dyn=%s rt=%s vp=%dx%d scale3d=%.2f preset=%s count=%d point=%.1f iters=%d eye=%dx%d" % [
		_uptime, fps, gpu, sim,
		(xr.foveation_level if xr != null else -1),
		str(xr.foveation_dynamic) if xr != null else "n/a",
		str(xr.get_render_target_size()) if xr != null else "n/a",
		int(vp_size.x), int(vp_size.y), get_viewport().scaling_3d_scale,
		(str(library.bulbs[bulb_idx].get("name", "?")) + "/bulb") if bulb_mode
			else library.name_at(preset_idx),
		cloud.get_count(), POINT_STEPS[point_idx], ITER_STEPS[iter_idx],
		_eye_res.x, _eye_res.y])


func _fmt_count(n: int) -> String:
	return "%.2fM" % (n / 1000000.0) if n >= 1000000 else "%dK" % (n / 1000)


func _fmt_time(s: float) -> String:
	return "%d:%02d" % [int(s) / 60, int(s) % 60]


func _exit_tree() -> void:
	RenderingServer.call_on_render_thread(cloud.cleanup)
