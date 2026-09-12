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
# Bulb mode sizes splats by coverage instead: sigma as a multiple of each splat's own
# baked neighbourhood axis. 0.9 is bulbSplat.ts's A_SCALE, the WebXR look. Fill cost
# rises with the square, so the ladder climbs gently and wraps to the cheap end.
const BULB_COVERAGE := [0.9, 1.1, 1.3, 0.5, 0.7]
var coverage_idx := 0
const COLOUR_CYCLES := [1.0, 2.0, 3.0, 4.0]
# Ascending, so SOLID cycles from ghost to wall instead of jumping about. Unsorted
# "over" compositing reads thinner than the WebXR build's sorted version at the same
# alpha, so the top of this ladder is how a bulb gets back to looking solid.
const OPACITY_STEPS := [0.12, 0.22, 0.35, 0.6, 0.9]
const DENSITY_STEPS := [1.0, 0.5, 0.0]
# Per-point brightness is really "how many particles may overlap before the buffer
# clips". At 0.7 that number is 1.4, which is why dense cores came out as flat white
# with no hue. Forward Mobile's colour buffer is 10-bit fixed point, so the only way to
# get density range out of it is to make each point contribute a small fraction and let
# the tonemapper expand it again. 0.02 gives roughly 50 clean overlaps.
# 1.0 is there for the premultiplied splat path: "over" compositing converges to the
# source colour rather than summing it, so a splat surface wants its palette at full
# strength where an additive point cloud wants slivers.
const BRIGHT_STEPS := [0.01, 0.02, 0.05, 0.12, 0.3, 0.7, 1.0]
# Wider range, because low per-point brightness has to be paid back here.
const EXPOSURE_MUL := [1.0, 2.0, 4.0, 8.0, 16.0, 32.0]
# Forward+ buys the HDR buffer that flam3 needs, but it is far more expensive per
# pixel than Forward Mobile: 2800x2800 costs ~80ms of draw. Resolution is now the
# primary budget lever rather than a free win, so the default sits low and climbs
# only if the measurement says there is room.
const RENDER_STEPS := [0.6, 0.75, 1.0, 1.25]     # eye buffer multiplier
const FOVEA_STEPS := [0, 1, 2, 3]                # fixed foveation level; 0 = off
var fovea_idx := 0
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
var help := HelpCard.new()

var xr: OpenXRInterface = null
var cloud := ParticleCloud.new()
## Raymarched bulb surface, the alternative to splatting the shell. Child of the cloud
## so it shares grabs and framing; SURFACE picks splats or a step budget.
var march := BulbMarch.new()
const SURFACE_STEPS := [0, 48, 96, 160]
const SURFACE_NAMES := ["splats", "march 48", "march 96", "march 160"]
## ENTER scales the shape so the roomiest hollow has this much clearance around the
## head. A scale-2 Mandelbox is a solid cube whose pores are 2% of its bound, so it
## comes out at ~27x; a negative-scale box has rooms and stays near the floor of the
## range. Either way you stand in fractal walls a stride away.
const INSIDE_CLEARANCE_M := 2.5
const INSIDE_SCALE_MIN := 4.0
const INSIDE_SCALE_MAX := 60.0
## Inside, every pixel of both eyes marches, where from outside only the silhouette did.
## At 96 steps full-res the Quest's GPU faulted (kgsl page faults, the app died), so
## ENTER caps the steps and drops the eye buffer to the smallest DETAIL step through the
## same path the RENDER tile uses (changing foveation in the same frame broke the
## framebuffer: "all textures in a framebuffer should be the same size", every draw).
## And it bails: past INSIDE_BAIL_MS for INSIDE_BAIL_FRAMES frames it goes back to
## splats by itself and says what it measured, so the headset is never left choking.
const INSIDE_STEPS_IDX := 1        # SURFACE_STEPS[1] = 48
const INSIDE_RENDER_IDX := 0       # RENDER_STEPS[0] = 0.6
const INSIDE_BAIL_MS := 45.0
const INSIDE_BAIL_FRAMES := 8
var _inside := false
var _inside_render_saved := 0
var _inside_slow := 0
var _inside_bailed_ms := 0.0
var _inside_bailed_until := 0.0
## The marcher shades a lit surface in [0,1]; the splat brightness ladder tops out at 1.0
## for "over" blending, so this is the scale that puts the two on the same exposure.
const MARCH_GAIN := 1.2
var surface_idx := 0
## The third mode: stand on a Mandelbrot or Julia set that runs to the horizon.
var ground := FractalGround.new()
var ground_mode := false
## The orbit of the point under the pointing hand, drawn above the ground.
var orbit := OrbitTrace.new()
var orbit_on := true
## The fourth: a fractal tree as real geometry, grown in front of you. Child of the cloud
## so grab, scale and spin apply; the cloud's own draw is hidden underneath it.
var tree := FractalTree.new()
var tree_mode := false
const TREE_DISTANCE := 2.2        # metres in front of the head, on the floor; it towers
const TREE_WIND := [0.3, 0.0, 0.7, 1.4]
const TREE_WIND_NAMES := ["light", "off", "breeze", "gusty"]
const TREE_DEPTH_DELTA := [0, 1, 2, -1, -2]
var tree_shape_idx := 0
var tree_wind_idx := 0
var tree_depth_idx := 0
const GROUND_ITER := [256, 512, 1024, 2048, 4096, 128]
var ground_iter_idx := 0
const GROUND_RELIEF := ["terrain", "terraces", "ridges", "flat"]
## Vertical exaggeration of the displaced terrain. 0 keeps the lit relief but leaves the
## mesh flat: the shading is anchored to the world by construction, the displacement
## re-levels under the viewer and bobs as you walk, so flat is the default.
const GROUND_HEIGHT := [0.0, 1.0, 2.0, 4.0, 0.5]
var ground_relief_idx := 0
var ground_height_idx := 0
const GROUND_TEXTURE := [0.6, 1.0, 0.0, 0.3]
var ground_texture_idx := 0
const GROUND_FREQ := [1.0, 2.0, 4.0, 0.5]
var ground_freq_idx := 0
var ground_hue := 0.0
const GROUND_BUMP := [1.0, 2.0, 0.0, 0.5]
var ground_bump_idx := 0
const GROUND_SKY := [0.0, 3.0, 8.0, 30.0]   # mirrored ceiling height, metres; 0 = off
var ground_sky_idx := 0
## Ground mode draws in ~6ms, so it runs the full eye buffer; the flame's DETAIL is put
## back on the way out.
const GROUND_RENDER_IDX := 2       # RENDER_STEPS[2] = 1.0
var _render_idx_saved := 0
const GROUND_PAN_MPS := 1.4       # metres per second at full stick
const GROUND_ZOOM_PER_S := 0.9    # e-folds per second at full stick
const GROUND_TURN_RAD_S := 1.2    # radians per second at full stick
## RENDER: 2048 levels and 4096 iterations, for a still worth the wait.
var _render_hq := false
var _render_iter_saved := 0
# Ground grab state: which hands hold grip, and where they were last frame.
var _gg_hands: Array[int] = []
var _gg_pos: Array[Vector2] = []
var _gg_yaw := 0.0
var library := PresetLibrary.new()
var grab: WorldGrab = null
var tonemap := Flam3Tonemap.new()

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
## Shown once, ever, on the first launch after install. HELP in the wrist menu brings it back.
var _help_pending := false
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
## MOTION in bulb mode. It used to read BULB_UPDATE_MOD and cycle stability_idx, which
## only ever reached the flame source: the button was live and did nothing.
# Frozen by default now that the cloud is baked. A bake describes the positions it read,
# so a moving cloud wears it out; and freeze already won every on-device comparison. The
# life comes from SPIN, which is a rigid rotation and leaves every neighbourhood intact.
var bulb_stability_idx := 0
var _bulb_settle := 0
## Frames between the settle finishing and the bake starting, so the framing measurement
## (dispatch one frame, read the next) has landed first.
const BAKE_DELAY_FRAMES := 4
var _bake_wait := 0
## Per-splat kNN covariance, computed once per bulb. This is what the WebXR viewer spends
## its loading pause on, and the only way to get splats that lie along a filament rather
## than straddling it.
var auto_bake := true

# --- frame-rate guard --------------------------------------------------------
# The splat renderer's cost is fill rate, and fill rate scales with the SQUARE of splat
# size, so the settings ladder has a cliff in it: 42mm with the bake's spread measured
# 2fps and needed a hard quit. The guard shrinks splats the moment the frame rate dives
# and recovers slowly once it is comfortably back, so no setting can take the headset
# below a usable floor no matter what it multiplies out to.
const GUARD_CUT_FPS := 24.0      # act well above the 15fps floor: reaction takes frames
const GUARD_RECOVER_FPS := 66.0
const GUARD_HOLD_S := 3.0        # after a cut, no recovery for this long
const GUARD_FLOOR := 0.1
## Frames under the cut line in a row before the guard acts. One slow frame is a hitch
## (a mesh rebuild, a pipeline compile, a readback), and shrinking splats, a fill-rate
## lever, does nothing for a CPU stall. Six in a row is a GPU that cannot keep up.
const GUARD_SLOW_FRAMES := 6
## Anything longer than this is a stall, not a frame rate; it is dropped from the EMA too.
const GUARD_HITCH_S := 0.1
var _perf_scale := 1.0
var _fps_ema := 72.0
var _guard_hold := 0.0
var _guard_slow := 0
## False while the system dash covers the app (OpenXR session visible, not focused).
var _xr_focused := true
## EXIT is armed for this long after its first press.
const EXIT_ARM_S := 4.0
var _exit_armed_until := -1.0

## Passthrough (mixed reality): the fractal floating in the actual room. The WebXR build
## does this with a premultiplied tone-map over the camera feed; here the compositor does
## the same job when the blend mode is alpha and the background stops painting.
var passthrough := false
## What the PASSTHRU tile shows. "n/a" when the runtime refuses, so a failed toggle is
## visible in the headset instead of only in logcat.
var passthru_label := "void"
## The breath is the bulb's skin animation: the surface parameter that defines its shape
## drifts continuously, so the shell is always reshaping. Off holds the form still while
## the particles keep refilling it, which is the closest this gets to the static cloud
## the WebXR viewer renders.
##
## A rate rather than a toggle, because at the authored speeds one breath cycle takes
## around seventy seconds. Turning that off for a few seconds looks exactly like leaving
## it on, so an on/off switch reads as a dead button even though it works. 3x makes the
## reshaping plain enough to judge.
const BREATH_STEPS := [1.0, 3.0, 0.0]
var breath_idx := 0
var splat_on := false
var splat_idx := 1
var colour_idx := 0
var opacity_idx := 2       # 0.35
var density_idx := 0
## -1 means "whatever palette the genome came with". Anything else indexes library.themes,
## which includes the genuinely multi-hue ones (Spectrum, Prism, Iridescent, FireIce);
## most preset palettes are a single-hue ramp, so no amount of equalisation makes them
## read as more than one colour.
var theme_idx := -1
## Pick a fresh theme with every drift transition.
var recolor_on_drift := true
## Themes cross-fade rather than snap. A palette change is as much a part of a transition
## as the shape change, and cutting to the new colours undoes the work the morph is doing.
var _theme_from: Array = []
var _theme_blend := 1.0
var _flame_bright_idx := 1
var _flame_exposure_idx := 0
var _flame_opacity_idx := 2
## Inside the cloud rather than looking at it from outside. A distance-estimate surface
## surrounds you, and Sam's read from the WebXR splat was that it looks dramatically
## better from within, so bulbs are placed to enclose the viewer by default.
# Enclosing but not cavernous. At 3.4 you are so deep inside a sparse shell that it
# reads as scattered dust rather than a surface.
## Bulb entry: a toy, not a room. Auto-framing normalises the cloud to a unit radius,
## so this is metres of radius; it sits BULB_HOME_DISTANCE ahead, a little below the
## eyes. Sam, 2026-09-12: "looks a lot better when it's smaller and in front of the
## user, like something to be played with rather than looked at." Grab scales it up.
const BULB_TOY_SCALE := 0.55
const BULB_HOME_DISTANCE := 1.1
const BULB_HOME_DROP := 0.3
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
# The WebXR splat build defaults to SIXTY THOUSAND splats and looks better than 294K of
# ours did, because each one is sized to its neighbourhood. Count was never the lever.
const BULB_PARTICLES := 0.035     # ~147K, with the budget spent on size instead
const BULB_UPDATE_MOD := 6
# MOTION for bulbs, same shape as STABILITY: index 0 is frozen, then every-frame and
# progressively calmer. Frozen matters more here than it does for flames. The WebXR
# splat viewer generates its cloud ONCE and then never touches it, and a static cloud is
# the reason each splat sits exactly where it belongs. Ours re-jitters every particle
# tangentially on every update, which is life, but it is also a permanent shimmer that
# no amount of splat sizing can sharpen.
const BULB_STABILITY := [0, 1, 3, 6, 12, 24]
# A freeze cannot take effect on the spot: a particle only reaches the surface on an
# update, so anything that had not stepped yet would freeze mid-flight in the seed ball.
# Run one full pass at mod 1 first, and every particle is projected before the stop.
# Long enough for the shell to actually FILL before it is measured and baked, not just
# for every particle to have been projected once. Coverage comes from the reseed churn
# (2% a frame) re-landing points in the gaps, so this is a fill time, not a settle time.
# ~1.2s at 72Hz, which is also roughly what the WebXR viewer pauses for.
const BULB_SETTLE_FRAMES := 90
# Bulbs cut rather than morph, so they get a longer hold than the flames' 8s. A hard
# change every eight seconds reads as a slideshow; the flames get away with it because
# the transition IS the show.
const BULB_DRIFT_HOLD := 20.0
# Bulbs need a completely different look from flames, and using the flame's settings is
# why the first attempt came out as scattered specks. A flame stacks dozens of points on
# a pixel, so each contributes a sliver (0.02) and the tone curve builds the image out of
# accumulated density. A bulb is a thin SHELL: about one point per pixel, nothing to
# accumulate, so each point has to carry its own weight.
const BULB_BRIGHT_IDX := 6        # 1.0: "over" blending converges to this, not to a sum
const BULB_EXPOSURE_IDX := 0      # points are already bright, so do not push the curve


func _ready() -> void:
	add_child(cloud)
	cloud.add_child(march)
	cloud.add_child(tree)
	add_child(ground)
	add_child(orbit)

	if not library.load_all():
		_fail("presets: %s" % library.load_error)
		return

	# flam3 can only run on an HDR colour buffer with the STORAGE bit, which Forward
	# Mobile does not have (README, phase 3), so on the Quest the effect self-disables
	# and the Environment's own ACES curve plus glow (main.tscn) is the look that ships.
	# The Compositor is only installed where the pass can actually run.
	if RenderingServer.get_current_rendering_method() != "mobile":
		var comp := Compositor.new()
		comp.compositor_effects = [tonemap]
		$WorldEnvironment.compositor = comp

	_init_xr()
	_eye_res = _current_eye_res()
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)

	var hands: Array[XRController3D] = [left_hand, right_hand]
	grab = WorldGrab.new(hands, cloud)
	_build_menu()
	xr_origin.add_child(help)
	help.setup(xr_camera)
	_help_pending = not _help_seen()

	RenderingServer.call_on_render_thread(_setup_gpu)


func _setup_gpu() -> void:
	var ok := cloud.setup(TEX_SIZE)
	if ok and not ground.setup():
		push_error("[ground] %s" % ground.get_error())
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
	call_deferred("_apply_palette")
	return true


## Menu spec: section, label, read, advance. Adding a setting is one entry and nothing
## else; the menu knows nothing about particle counts or exposures.
func _build_menu() -> void:
	# Which modes an item belongs to. Everything else hides, and the wrist menu drops a
	# section whose tiles are all hidden, so each mode gets only its own controls.
	var _vis_flame := func(): return not bulb_mode and not ground_mode and not tree_mode
	var _vis_cloud := func(): return not ground_mode and not tree_mode
	var _vis_grab := func(): return not ground_mode    # the tree is grabbed and spun too
	var _vis_tree := func(): return tree_mode
	menu.items = [
		# The mode strip: four segments under the title, always in the same place.
		WristMenu.Item.new("mode", "FLAME", func(): return "",
			func(): _set_mode("flame")).chosen_when(func(): return not bulb_mode and not ground_mode and not tree_mode),
		WristMenu.Item.new("mode", "BULB", func(): return "",
			func(): _set_mode("bulb")).chosen_when(func(): return bulb_mode),
		WristMenu.Item.new("mode", "GROUND", func(): return "",
			func(): _set_mode("ground")).chosen_when(func(): return ground_mode),
		WristMenu.Item.new("mode", "TREE", func(): return "",
			func(): _set_mode("tree")).chosen_when(func(): return tree_mode),

		WristMenu.Item.new("make", "SHAPE",
			func(): return FractalTree.SHAPE_NAMES[tree_shape_idx],
			func():
				tree_shape_idx = (tree_shape_idx + 1) % FractalTree.SHAPE_NAMES.size()
				tree.set_shape(FractalTree.SHAPE_NAMES[tree_shape_idx]),
			false, _vis_tree).stepping(func(d: int):
				tree_shape_idx = wrapi(tree_shape_idx + d, 0, FractalTree.SHAPE_NAMES.size())
				tree.set_shape(FractalTree.SHAPE_NAMES[tree_shape_idx])),
		WristMenu.Item.new("make", "SEED",
			func(): return "#%d" % tree.seed_value,
			func(): tree.reseed(),
			false, _vis_tree),
		WristMenu.Item.new("make", "REGROW",
			func(): return "from seed",
			func(): tree.regrow(),
			false, _vis_tree),

		WristMenu.Item.new("make", "RANDOM",
			func(): return "new flame", func(): _morph_to_new(Breed.random_genome(
				library.next_serial(), library.themes)),
			false, _vis_flame),
		WristMenu.Item.new("make", "MUTATE",
			func(): return "vary this", func(): _morph_to_new(Breed.mutate(
				library.at(preset_idx), library.next_serial())),
			false, _vis_flame),
		WristMenu.Item.new("make", "BREED",
			func(): return "mix two", func(): _morph_to_new(Breed.crossover(
				library.at(preset_idx), library.at(preset_idx + 1 + randi() % maxi(1, library.count() - 1)),
				library.next_serial())),
			false, _vis_flame),

		WristMenu.Item.new("scene", "FLAME",
			func(): return library.bulbs[bulb_idx].get("name", "?") if bulb_mode else "next",
			func():
				if bulb_mode:
					_load_bulb(bulb_idx + 1)
				else:
					_morph_to_preset(preset_idx + 1),
			false, _vis_cloud).stepping(func(d: int):
				if bulb_mode:
					_load_bulb(bulb_idx + d)
				else:
					_morph_to_preset(preset_idx + d)),
		WristMenu.Item.new("scene", "DRIFT",
			func(): return "on" if _drift else "off",
			func(): _drift = not _drift; _drift_hold = 0.0,
			false, _vis_cloud),
		WristMenu.Item.new("scene", "PASSTHRU",
			func(): return passthru_label,
			func(): _set_passthrough(not passthrough)),
		WristMenu.Item.new("scene", "SPIN",
			func(): return "on" if spin else "off", func(): spin = not spin,
			false, _vis_grab),
		WristMenu.Item.new("scene", "SPEED",
			func(): return "%ds" % int(MORPH_STEPS[morph_idx]),
			func(): morph_idx = (morph_idx + 1) % MORPH_STEPS.size(),
			false, _vis_flame).stepping(func(d: int):
				morph_idx = wrapi(morph_idx + d, 0, MORPH_STEPS.size())),
		WristMenu.Item.new("scene", "CENTRE",
			func(): return "reset", func(): _recenter(); cloud.request_measure(),
			false, _vis_grab),
		WristMenu.Item.new("scene", "HELP",
			func(): return "controls", func(): help.open()),

		WristMenu.Item.new("look", "POINTS",
			func(): return _fmt_count(cloud.get_count()),
			func():
				particle_idx = (particle_idx + 1) % PARTICLE_STEPS.size()
				cloud.set_count(int(TEX_SIZE * TEX_SIZE * PARTICLE_STEPS[particle_idx]))
				cloud.request_measure(),
			false, _vis_flame).stepping(func(d: int):
				particle_idx = wrapi(particle_idx + d, 0, PARTICLE_STEPS.size())
				cloud.set_count(int(TEX_SIZE * TEX_SIZE * PARTICLE_STEPS[particle_idx]))
				cloud.request_measure()),
		WristMenu.Item.new("look", "SPLAT",
			func():
				if bulb_mode:
					return "%.1fx cover" % BULB_COVERAGE[coverage_idx]
				return "%.0fmm" % (SPLAT_STEPS[splat_idx] * 1000.0) if splat_on else "off",
			func():
				if bulb_mode:
					coverage_idx = (coverage_idx + 1) % BULB_COVERAGE.size()
				elif not splat_on:
					splat_on = true
				else:
					splat_idx = (splat_idx + 1) % SPLAT_STEPS.size()
					if splat_idx == 0:
						splat_on = false
				_apply_point_look(),
			false, _vis_cloud).stepping(func(d: int):
				if bulb_mode:
					coverage_idx = wrapi(coverage_idx + d, 0, BULB_COVERAGE.size())
				else:
					# One ladder: off, then every size. Scrubbing left from the first
					# size lands on off, not on the largest splat.
					var cur := (splat_idx + 1) if splat_on else 0
					var nxt := wrapi(cur + d, 0, SPLAT_STEPS.size() + 1)
					splat_on = nxt > 0
					splat_idx = maxi(0, nxt - 1)
				_apply_point_look()),
		WristMenu.Item.new("look", "ADAPT",
			func(): return "%d%%" % int(DENSITY_STEPS[density_idx] * 100.0),
			func():
				density_idx = (density_idx + 1) % DENSITY_STEPS.size()
				_apply_point_look(),
			false, _vis_cloud).stepping(func(d: int):
				density_idx = wrapi(density_idx + d, 0, DENSITY_STEPS.size())
				_apply_point_look()),
		WristMenu.Item.new("look", "SOLID",
			func(): return "%d%%" % int(OPACITY_STEPS[opacity_idx] * 100.0),
			func():
				opacity_idx = (opacity_idx + 1) % OPACITY_STEPS.size()
				_apply_point_look(),
			false, _vis_cloud).stepping(func(d: int):
				opacity_idx = wrapi(opacity_idx + d, 0, OPACITY_STEPS.size())
				_apply_point_look()),
		WristMenu.Item.new("look", "SIZE",
			func(): return "%.2f" % POINT_STEPS[point_idx],
			func(): point_idx = (point_idx + 1) % POINT_STEPS.size(); _apply_point_look(),
			false, _vis_flame).stepping(func(d: int):
				point_idx = wrapi(point_idx + d, 0, POINT_STEPS.size())
				_apply_point_look()),
		WristMenu.Item.new("colour", "THEME",
			func():
				if recolor_on_drift:
					return "auto %d" % (theme_idx + 1) if theme_idx >= 0 else "auto"
				return "theme %d" % (theme_idx + 1) if theme_idx >= 0 else "preset",
			func(): _cycle_theme()).stepping(func(d: int): _cycle_theme(d)),
		WristMenu.Item.new("colour", "AUTO",
			func(): return "on" if recolor_on_drift else "off",
			func(): recolor_on_drift = not recolor_on_drift,
			false, _vis_cloud),
		WristMenu.Item.new("colour", "BANDS",
			func(): return "%dx" % int(COLOUR_CYCLES[colour_idx]),
			func():
				colour_idx = (colour_idx + 1) % COLOUR_CYCLES.size()
				_apply_point_look()).stepping(func(d: int):
				colour_idx = wrapi(colour_idx + d, 0, COLOUR_CYCLES.size())
				_apply_point_look()),
		WristMenu.Item.new("colour", "BRIGHT",
			func(): return "%.3f" % BRIGHT_STEPS[bright_idx],
			func(): bright_idx = (bright_idx + 1) % BRIGHT_STEPS.size(); _apply_point_look(),
			false, _vis_cloud).stepping(func(d: int):
				bright_idx = wrapi(bright_idx + d, 0, BRIGHT_STEPS.size())
				_apply_point_look()),

		WristMenu.Item.new("colour", "EXPOSURE",
			func(): return "%.0fx" % EXPOSURE_MUL[exposure_idx],
			func(): exposure_idx = (exposure_idx + 1) % EXPOSURE_MUL.size(); _apply_exposure()).stepping(
			func(d: int): exposure_idx = wrapi(exposure_idx + d, 0, EXPOSURE_MUL.size()); _apply_exposure()),
		WristMenu.Item.new("look", "MOTION",
			func():
				var m: int = BULB_STABILITY[bulb_stability_idx] if bulb_mode else STABILITY[stability_idx]
				return "frozen" if m == 0 else "1/%d" % m,
			func():
				if bulb_mode:
					bulb_stability_idx = (bulb_stability_idx + 1) % BULB_STABILITY.size()
					# No settle: a running cloud is already projected. Just refresh the
					# bake so a freeze stops with shapes that describe where things ARE.
					if BULB_STABILITY[bulb_stability_idx] == 0:
						_bake_wait = BAKE_DELAY_FRAMES
				else:
					stability_idx = (stability_idx + 1) % STABILITY.size(),
			false, _vis_cloud).stepping(func(d: int):
				if bulb_mode:
					bulb_stability_idx = wrapi(bulb_stability_idx + d, 0, BULB_STABILITY.size())
					if BULB_STABILITY[bulb_stability_idx] == 0:
						_bake_wait = BAKE_DELAY_FRAMES
				else:
					stability_idx = wrapi(stability_idx + d, 0, STABILITY.size())),
		WristMenu.Item.new("look", "BAKE",
			func():
				if cloud.is_baking():
					return "%d%%" % int(cloud.bake_progress * 100.0)
				if not auto_bake:
					return "off"
				return "on" if cloud.bake_ready else "wait",
			func():
				auto_bake = not auto_bake
				if auto_bake:
					RenderingServer.call_on_render_thread(cloud.bake)
				else:
					cloud.clear_bake(),
			false, func(): return bulb_mode),
		WristMenu.Item.new("look", "BREATHE",
			func():
				# A frozen cloud cannot show a moving surface, so say so rather than
				# reporting a rate that nothing is acting on.
				if BULB_STABILITY[bulb_stability_idx] == 0:
					return "held"
				return "off" if BREATH_STEPS[breath_idx] == 0.0 else "%.0fx" % BREATH_STEPS[breath_idx],
			func(): breath_idx = (breath_idx + 1) % BREATH_STEPS.size(),
			false, func(): return bulb_mode).stepping(func(d: int):
				breath_idx = wrapi(breath_idx + d, 0, BREATH_STEPS.size())),
		# Splats or a raymarched surface. The ms readout in the footer is the verdict.
		WristMenu.Item.new("look", "SURFACE",
			func(): return SURFACE_NAMES[surface_idx],
			func(): surface_idx = (surface_idx + 1) % SURFACE_STEPS.size(); _apply_surface(),
			false, func(): return bulb_mode).stepping(func(d: int):
				surface_idx = wrapi(surface_idx + d, 0, SURFACE_STEPS.size())
				_apply_surface()),
		# ENTER (stand inside the shape at its roomiest hollow) is not on the headset menu.
		# Measured 2026-09-12: 85-103 ms GPU at 48 steps on a 0.6x eye buffer, every pixel
		# of both eyes marching, and the bail-out left the renderer in a broken pipeline
		# state that the GPU then faulted on. _enter_inside() stays for the desktop shot
		# harness and for the day the interior gets a quarter-res pass with reprojection.
		WristMenu.Item.new("look", "DETAIL",
			func(): return "%.2fx" % RENDER_STEPS[render_idx],
			func(): _step_detail(1)).stepping(func(d: int): _step_detail(d)),
		WristMenu.Item.new("look", "SET",
			func(): return "julia" if ground.julia else "mandelbrot",
			func(): ground.set_julia(not ground.julia),
			false, func(): return ground_mode),
		WristMenu.Item.new("look", "JULIA",
			func(): return "from here",
			func(): ground.julia_here(),
			false, func(): return ground_mode),
		WristMenu.Item.new("look", "ITER",
			func(): return str(GROUND_ITER[ground_iter_idx]),
			func():
				ground_iter_idx = (ground_iter_idx + 1) % GROUND_ITER.size()
				ground.set_max_iter(GROUND_ITER[ground_iter_idx]),
			false, func(): return ground_mode).stepping(func(d: int):
				ground_iter_idx = wrapi(ground_iter_idx + d, 0, GROUND_ITER.size())
				ground.set_max_iter(GROUND_ITER[ground_iter_idx])),
		WristMenu.Item.new("look", "RELIEF",
			func(): return GROUND_RELIEF[ground_relief_idx],
			func():
				ground_relief_idx = (ground_relief_idx + 1) % GROUND_RELIEF.size()
				_apply_ground_look(),
			false, func(): return ground_mode).stepping(func(d: int):
				ground_relief_idx = wrapi(ground_relief_idx + d, 0, GROUND_RELIEF.size())
				_apply_ground_look()),
		WristMenu.Item.new("look", "HEIGHT",
			func():
				var h: float = GROUND_HEIGHT[ground_height_idx]
				return "flat" if h == 0.0 else "%.1fx" % h,
			func():
				ground_height_idx = (ground_height_idx + 1) % GROUND_HEIGHT.size()
				_apply_ground_look(),
			false, func(): return ground_mode).stepping(func(d: int):
				ground_height_idx = wrapi(ground_height_idx + d, 0, GROUND_HEIGHT.size())
				_apply_ground_look()),
		WristMenu.Item.new("look", "TEXTURE",
			func(): return "%d%%" % int(GROUND_TEXTURE[ground_texture_idx] * 100.0),
			func():
				ground_texture_idx = (ground_texture_idx + 1) % GROUND_TEXTURE.size()
				_apply_ground_look(),
			false, func(): return ground_mode).stepping(func(d: int):
				ground_texture_idx = wrapi(ground_texture_idx + d, 0, GROUND_TEXTURE.size())
				_apply_ground_look()),
		WristMenu.Item.new("look", "FREQ",
			func(): return "%.1fx" % GROUND_FREQ[ground_freq_idx],
			func():
				ground_freq_idx = (ground_freq_idx + 1) % GROUND_FREQ.size()
				_apply_ground_look(),
			false, func(): return ground_mode).stepping(func(d: int):
				ground_freq_idx = wrapi(ground_freq_idx + d, 0, GROUND_FREQ.size())
				_apply_ground_look()),
		WristMenu.Item.new("look", "HUE",
			func(): return "%.2f" % ground_hue,
			func():
				ground_hue = fmod(ground_hue + 0.125, 1.0)
				_apply_ground_look(),
			false, func(): return ground_mode).stepping(func(d: int):
				ground_hue = fposmod(ground_hue + 0.125 * d, 1.0)
				_apply_ground_look()),
		WristMenu.Item.new("look", "BUMP",
			func(): return "%.1fx" % GROUND_BUMP[ground_bump_idx],
			func():
				ground_bump_idx = (ground_bump_idx + 1) % GROUND_BUMP.size()
				_apply_ground_look(),
			false, func(): return ground_mode).stepping(func(d: int):
				ground_bump_idx = wrapi(ground_bump_idx + d, 0, GROUND_BUMP.size())
				_apply_ground_look()),
		WristMenu.Item.new("look", "SKY",
			func(): return "off" if GROUND_SKY[ground_sky_idx] == 0.0 else "mirror %.0fm" % GROUND_SKY[ground_sky_idx],
			func():
				ground_sky_idx = (ground_sky_idx + 1) % GROUND_SKY.size()
				_apply_ground_look(),
			false, func(): return ground_mode).stepping(func(d: int):
				ground_sky_idx = wrapi(ground_sky_idx + d, 0, GROUND_SKY.size())
				_apply_ground_look()),
		WristMenu.Item.new("look", "HOME",
			func(): return "reset view",
			func(): ground.home(),
			false, func(): return ground_mode),
		# The orbit of the point under the pointing hand, hung in the air over the map.
		WristMenu.Item.new("look", "ORBIT",
			func(): return "on" if orbit_on else "off",
			func():
				orbit_on = not orbit_on
				orbit.visible = false,
			false, func(): return ground_mode),
		WristMenu.Item.new("look", "DEPTH",
			func(): return "%d · %s" % [tree.effective_depth(), _fmt_count(tree.branch_count)],
			func():
				tree_depth_idx = (tree_depth_idx + 1) % TREE_DEPTH_DELTA.size()
				tree.depth_delta = TREE_DEPTH_DELTA[tree_depth_idx]
				tree.build(),
			false, _vis_tree).stepping(func(d: int):
				tree_depth_idx = wrapi(tree_depth_idx + d, 0, TREE_DEPTH_DELTA.size())
				tree.depth_delta = TREE_DEPTH_DELTA[tree_depth_idx]
				tree.build()),
		WristMenu.Item.new("look", "WIND",
			func(): return TREE_WIND_NAMES[tree_wind_idx],
			func():
				tree_wind_idx = (tree_wind_idx + 1) % TREE_WIND.size()
				tree.set_wind(TREE_WIND[tree_wind_idx]),
			false, _vis_tree).stepping(func(d: int):
				tree_wind_idx = wrapi(tree_wind_idx + d, 0, TREE_WIND.size())
				tree.set_wind(TREE_WIND[tree_wind_idx])),
		WristMenu.Item.new("look", "LEAVES",
			func(): return "on" if tree.leaves_on else "off",
			func(): tree.set_leaves(not tree.leaves_on),
			false, _vis_tree),
		# Double the level size and max the iterations: four times the fill for a still
		# that is sharp out to the middle distance. The status line counts it in.
		WristMenu.Item.new("look", "RENDER",
			func(): return "hq 2048 / 4096" if _render_hq else "normal",
			func(): _set_render_hq(not _render_hq),
			false, func(): return ground_mode),
		# Fixed foveated rendering, the largest fragment-cost lever on a Quest. Off by
		# default because the cloud showed it at the edges; this dial is the instrument
		# for measuring it per mode (ground and tree may take it for free). Applied a
		# frame later, on its own: changing it in the same frame as the eye buffer broke
		# the framebuffer (2026-09-12 log).
		WristMenu.Item.new("look", "FOVEA",
			func(): return "off" if fovea_idx == 0 else "fixed %d" % FOVEA_STEPS[fovea_idx],
			func():
				fovea_idx = (fovea_idx + 1) % FOVEA_STEPS.size()
				call_deferred("_apply_foveation"),
			false).stepping(func(d: int):
				fovea_idx = wrapi(fovea_idx + d, 0, FOVEA_STEPS.size())
				call_deferred("_apply_foveation")),
		# Glow is a downsample/blur/upsample chain per eye on a tiler, and its cost has
		# never been measured. This toggle is the instrument: flip it and read the ms.
		WristMenu.Item.new("look", "GLOW",
			func(): return "on" if _env().glow_enabled else "off",
			func(): _env().glow_enabled = not _env().glow_enabled),
		# Two presses. The menu is driven by a ray and a trigger, and a single stray pull
		# should not end the session; the first press arms it and says so on the tile.
		WristMenu.Item.new("app", "EXIT",
			func(): return "sure? press again" if _exit_armed_until > _uptime else "quit",
			func():
				if _exit_armed_until > _uptime:
					get_tree().quit()
				else:
					_exit_armed_until = _uptime + EXIT_ARM_S),
	]
	menu.title = func():
		if tree_mode:
			return "%s  ·  %s branches" % [tree.shape.capitalize(), _fmt_count(tree.branch_count)]
		if ground_mode:
			var z := ground.zoom_factor()
			return "%s  ·  zoom %s" % ["Julia" if ground.julia else "Mandelbrot",
				("%.0fx" % z) if z < 1000.0 else ("%.1ex" % z)]
		return str(library.bulbs[bulb_idx].get("name", "?")) if bulb_mode else library.name_at(preset_idx)
	menu.status_side = func():
		if tree_mode:
			var gp := tree.grow_progress()
			return ("growing %d%%" % int(gp * 100.0)) if gp < 1.0 else "grown"
		if ground_mode:
			var pr := ground.progress()
			return ("rendering %d%%" % int(pr * 100.0)) if pr < 1.0 else "sharp"
		if _perf_scale < 0.999:
			# Name the intervention, or a guarded 42mm splat looks like a broken setting.
			return "guard %d%%" % int(_perf_scale * 100.0)
		if cloud.is_baking():
			return "baking %d%%" % int(cloud.bake_progress * 100.0)
		if _inside:
			return "inside · %.1fx eye" % RENDER_STEPS[render_idx]
		if _inside_bailed_until > _uptime:
			return "inside bailed: %.0f ms" % _inside_bailed_ms
		if bulb_mode and _bulb_settle > 0:
			return "settling"
		if _morph_t < 1.0:
			return "morphing"
		return "drifting" if _drift else ""

	menu.status_main = func():
		return "%.0f fps  ·  %d flames  ·  %.1f ms" % [
			Engine.get_frames_per_second(), library.count(),
			RenderingServer.viewport_get_measured_render_time_gpu(get_viewport().get_viewport_rid())
				+ (ground.ground_us if ground_mode else (0.0 if tree_mode else cloud.iterate_us)) / 1000.0]
	# Worn like a watch: inside of the left forearm, tilted up toward the face.
	# Along the forearm, angled up toward the face like a watch worn high on the wrist.
	menu.transform = Transform3D(Basis(), Vector3(0.0, 0.06, 0.10))
	menu.rotation_degrees = Vector3(-62.0, 0.0, 0.0)
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
## flame -> bulb -> ground -> flame.
func _step_detail(d: int) -> void:
	render_idx = wrapi(render_idx + d, 0, RENDER_STEPS.size())
	if xr != null:
		xr.render_target_size_multiplier = RENDER_STEPS[render_idx]




## Jump straight to a mode from the strip. Leaving a mode undoes its entry side effects
## before the next one applies its own, in the same order the cycle always did.
func _set_mode(kind: String) -> void:
	var want_bulb := kind == "bulb"
	var want_ground := kind == "ground"
	var want_tree := kind == "tree"
	if bulb_mode == want_bulb and ground_mode == want_ground and tree_mode == want_tree:
		return
	if ground_mode and not want_ground:
		_set_ground_mode(false)
	if tree_mode and not want_tree:
		_set_tree_mode(false)
	if bulb_mode and not want_bulb:
		_set_bulb_mode(false)
	if want_bulb and not bulb_mode:
		_set_bulb_mode(true)
	if want_ground and not ground_mode:
		_set_ground_mode(true)
	if want_tree and not tree_mode:
		_set_tree_mode(true)


## The tree stands on the floor in front of you and grows. The cloud underneath keeps
## its source but is hidden and not iterated, so the tree has the frame to itself.
func _set_tree_mode(on: bool) -> void:
	tree_mode = on
	tree.visible = on
	cloud.set_visible_cloud(not on)
	if on:
		if tree.branch_count == 0:
			tree.set_shape(FractalTree.SHAPE_NAMES[tree_shape_idx])
		tree.set_wind(TREE_WIND[tree_wind_idx])
		tree.regrow()
		_recenter()
		_apply_palette()
	else:
		_recenter()
		cloud.request_measure()


func _set_ground_mode(on: bool) -> void:
	ground_mode = on
	ground.visible = on
	orbit.visible = false
	cloud.set_visible_cloud(not on)
	if on:
		_render_idx_saved = render_idx
		render_idx = GROUND_RENDER_IDX
		ground.home()
		_apply_ground_look()
		_apply_palette()
	else:
		# Restore the flame's DETAIL only if it was not changed here; a value picked on
		# the ground is a choice, not the mode's default.
		if render_idx == GROUND_RENDER_IDX:
			render_idx = _render_idx_saved
	if xr != null:
		xr.render_target_size_multiplier = RENDER_STEPS[render_idx]


## Point at the ground and pull: glide until that spot is under you.
func _ground_teleport(hand: XRController3D) -> void:
	var hit = _hand_floor_hit(hand)
	if hit != null:
		ground.glide_to(hit)


## Where the hand's ray meets the floor, as world xz, or null when there is no tracked
## hand or it points at the sky. On the desktop (no XR) the controller node's own
## transform stands in, which is what the shot harness poses.
func _hand_floor_hit(hand: XRController3D) -> Variant:
	if hand == null or (xr != null and not hand.get_has_tracking_data()):
		return null
	var o := hand.global_transform.origin
	var d := -hand.global_transform.basis.z
	if d.y > -0.05:
		return null
	var t := -o.y / d.y
	var hit := o + d * t
	return Vector2(hit.x, hit.z)


## The orbit trace follows the right hand's spot on the floor, except while the wrist
## menu is showing (its ray is the menu's then, and the chain read as stray lines).
func _tick_orbit() -> void:
	if not orbit_on or _menu_active or menu.visible:
		orbit.visible = false
		return
	var hit = _hand_floor_hit(right_hand)
	if hit == null:
		orbit.visible = false
		return
	orbit.visible = true
	orbit.update(ground.world_to_fractal(hit), ground.julia, ground.julia_c,
		ground.fractal_dir_to_world, hit)


## Grip drags the world with the hand and twists it with the wrist; two hands also zoom
## by their spread. Returns true while any grip is held, so the sticks stay quiet.
func _ground_grab() -> bool:
	var hands: Array[int] = []
	var pos: Array[Vector2] = []
	var yaw := 0.0
	var idx := 0
	for c in [left_hand, right_hand]:
		if c != null and c.get_has_tracking_data() and c.is_button_pressed("grip_click"):
			hands.append(idx)
			var xf: Transform3D = c.global_transform
			pos.append(Vector2(xf.origin.x, xf.origin.z))
			yaw = atan2(-xf.basis.z.x, -xf.basis.z.z)
		idx += 1
	if hands.is_empty():
		_gg_hands = []
		return false
	if hands == _gg_hands:
		# Signs settled on the headset: the ground follows the hand with these.
		if hands.size() == 1:
			ground.pan(pos[0] - _gg_pos[0])
			ground.rotate_about_head(-wrapf(yaw - _gg_yaw, -PI, PI))
		else:
			var mid := (pos[0] + pos[1]) * 0.5
			var pmid := (_gg_pos[0] + _gg_pos[1]) * 0.5
			ground.pan(mid - pmid)
			var d0 := _gg_pos[1] - _gg_pos[0]
			var d1 := pos[1] - pos[0]
			if d0.length() > 0.05 and d1.length() > 0.05:
				ground.zoom(clampf(d1.length() / d0.length(), 0.5, 2.0))
				ground.rotate_about_head(-wrapf(d1.angle() - d0.angle(), -PI, PI))
	_gg_hands = hands
	_gg_pos = pos
	_gg_yaw = yaw
	return true


func _set_render_hq(on: bool) -> void:
	_render_hq = on
	if on:
		_render_iter_saved = ground_iter_idx
		ground_iter_idx = GROUND_ITER.find(4096)
		ground.set_max_iter(4096)
		RenderingServer.call_on_render_thread(ground.set_quality.bind(2048))
	else:
		ground_iter_idx = _render_iter_saved
		ground.set_max_iter(GROUND_ITER[ground_iter_idx])
		RenderingServer.call_on_render_thread(ground.set_quality.bind(1024))


func _apply_ground_look() -> void:
	ground.set_look(&"relief_mode", [3, 1, 2, 0][ground_relief_idx])
	var h: float = GROUND_HEIGHT[ground_height_idx]
	ground.set_look(&"displace", 1.0 if h > 0.0 else 0.0)
	ground.set_look(&"relief_scale", h if h > 0.0 else 1.0)
	ground.set_look(&"texture_strength", GROUND_TEXTURE[ground_texture_idx])
	ground.set_look(&"colour_freq", GROUND_FREQ[ground_freq_idx])
	ground.set_look(&"colour_offset", ground_hue)
	ground.set_look(&"bump_strength", GROUND_BUMP[ground_bump_idx])
	ground.set_sky(GROUND_SKY[ground_sky_idx])
	# The texture channel feeds both the colour modulation and the bump, so it is only
	# skipped in compute when neither wants it.
	ground.set_texture_on(GROUND_TEXTURE[ground_texture_idx] > 0.0 or GROUND_BUMP[ground_bump_idx] > 0.0)
	ground.set_palette_cycles(COLOUR_CYCLES[colour_idx])


func _set_bulb_mode(on: bool) -> void:
	if on and library.bulbs.is_empty():
		push_error("[bulb] presets.json has no bulbs; staying in flame mode")
		return
	bulb_mode = on
	if on:
		_flame_bright_idx = bright_idx
		_flame_exposure_idx = exposure_idx
		bright_idx = BULB_BRIGHT_IDX
		exposure_idx = BULB_EXPOSURE_IDX
		# A distance-estimate shell is a surface: splat it. This is the whole reason the
		# WebXR splat build reads better than a point cloud from the inside.
		splat_on = true
		splat_idx = 0     # only the pre-bake frames use this; the bake switches to coverage
		coverage_idx = 0
		_flame_opacity_idx = opacity_idx
		opacity_idx = 1   # 0.22, the WebXR build's ALPHA
		colour_idx = 1
		_apply_point_look()
		_apply_exposure()
		# Hand-sized, in front. Once only, on entry: later bulb switches keep the grab.
		cloud.scale = Vector3.ONE * BULB_TOY_SCALE
		_load_bulb(bulb_idx)
		_apply_surface()
	else:
		_leave_inside()
		surface_idx = 0
		_apply_surface()
		bright_idx = _flame_bright_idx
		exposure_idx = _flame_exposure_idx
		opacity_idx = _flame_opacity_idx
		splat_on = false
		colour_idx = 0
		_apply_point_look()
		_apply_exposure()
		_bulb = null
		cloud.scale = Vector3.ONE
		cloud.set_count(int(TEX_SIZE * TEX_SIZE * PARTICLE_STEPS[particle_idx]))
		_load_preset(preset_idx)
	_recenter()


## Put the head in the shape's roomiest hollow, scaled so that hollow is
## INSIDE_CLEARANCE_M across. Switches to the marcher if the splats were showing, and
## stops the ambient spin: a world turning about a point behind a wall is the one
## motion no one wants from inside.
func _enter_inside() -> void:
	if _bulb == null or not bulb_mode:
		return
	if SURFACE_STEPS[surface_idx] == 0 or surface_idx > INSIDE_STEPS_IDX:
		surface_idx = INSIDE_STEPS_IDX
		_apply_surface()
	spin = false
	if not _inside:
		_inside_render_saved = render_idx
	_inside = true
	_inside_slow = 0
	render_idx = INSIDE_RENDER_IDX
	if xr != null:
		xr.render_target_size_multiplier = RENDER_STEPS[render_idx]
	var p := _bulb.find_hollow()
	var d := maxf(_bulb.de(p), 1e-4)
	var local := (p - cloud.center) * cloud.fit
	# Clearance is in state units; local units are state * fit; world is local * scale.
	var s := clampf(INSIDE_CLEARANCE_M / (d * cloud.fit), INSIDE_SCALE_MIN, INSIDE_SCALE_MAX)
	# Turn the shape so its nearest wall is straight ahead: the roomiest spot in a solid
	# body is beside its surface, and arriving with the surface behind you reads as
	# nothing happening. The wall lies down the DE gradient.
	var h := d * 0.05
	var g := Vector3(
		_bulb.de(p + Vector3(h, 0, 0)) - _bulb.de(p - Vector3(h, 0, 0)),
		_bulb.de(p + Vector3(0, h, 0)) - _bulb.de(p - Vector3(0, h, 0)),
		_bulb.de(p + Vector3(0, 0, h)) - _bulb.de(p - Vector3(0, 0, h)))
	var basis := Basis()
	if g.length_squared() > 1e-12:
		var wall_local := (-g).normalized()
		var wall_world := (cloud.global_transform.basis * wall_local).normalized()
		var fwd := -xr_camera.global_transform.basis.z
		fwd.y = 0.0
		if fwd.length_squared() > 1e-6 and wall_world.length_squared() > 1e-6:
			fwd = fwd.normalized()
			var axis := wall_world.cross(fwd)
			if axis.length_squared() > 1e-8:
				basis = Basis(axis.normalized(), wall_world.angle_to(fwd)) * cloud.global_transform.basis.orthonormalized()
			else:
				basis = cloud.global_transform.basis.orthonormalized()
	else:
		basis = cloud.global_transform.basis.orthonormalized()
	var head := xr_camera.global_transform.origin
	cloud.global_transform = Transform3D(basis.scaled(Vector3.ONE * s), Vector3.ZERO)
	cloud.global_position = head - cloud.global_transform.basis * local
	print("[bulb] inside %s at state %s clearance %.4f scale %.1f" % [
		library.bulbs[bulb_idx].get("name", "?"), str(p), d, s])


## Back to the normal eye buffer and foveation. Called when the marcher goes away, the
## bulb changes under you, or bulb mode ends.
func _leave_inside() -> void:
	if not _inside:
		return
	_inside = false
	render_idx = _inside_render_saved
	if xr != null:
		xr.render_target_size_multiplier = RENDER_STEPS[render_idx]


func _apply_foveation() -> void:
	if xr == null or not xr.is_foveation_supported():
		return
	xr.set_foveation_level(FOVEA_STEPS[fovea_idx])
	xr.set_foveation_dynamic(false)
	print("[fractal] foveation level=%d dynamic=false" % FOVEA_STEPS[fovea_idx])


## The interior's safety valve, run every frame while inside.
func _guard_inside() -> void:
	var gpu_ms := RenderingServer.viewport_get_measured_render_time_gpu(get_viewport().get_viewport_rid())
	if gpu_ms > INSIDE_BAIL_MS:
		_inside_slow += 1
	else:
		_inside_slow = 0
	if _inside_slow >= INSIDE_BAIL_FRAMES:
		_inside_bailed_ms = gpu_ms
		_inside_bailed_until = _uptime + 8.0
		print("[bulb] inside bailed: %.0f ms gpu at %s steps, %.2fx eye" % [
			gpu_ms, str(SURFACE_STEPS[surface_idx]), RENDER_STEPS[render_idx]])
		surface_idx = 0
		_apply_surface()   # not marching any more, so this also leaves the interior


func _load_bulb(i: int) -> void:
	if library.bulbs.is_empty():
		return
	_leave_inside()
	bulb_idx = wrapi(i, 0, library.bulbs.size())
	# A fresh bulb is a ball of unprojected seeds, so it always gets its settle pass,
	# whether or not MOTION is asking for a freeze.
	_bulb_settle = BULB_SETTLE_FRAMES
	_bake_wait = 0
	cloud.set_count(int(TEX_SIZE * TEX_SIZE * BULB_PARTICLES))
	if _bulb != null and cloud.source == _bulb:
		# Same shader, same buffers: swap the genome in place rather than building a new
		# source, which recompiled the compute pipeline on every switch in bulb drift.
		_bulb.set_genome(library.bulbs[bulb_idx])
		RenderingServer.call_on_render_thread(cloud.reload_source)
	else:
		_bulb = BulbSource.new(library.bulbs[bulb_idx])
		_bulb.update_mod = BULB_UPDATE_MOD
		RenderingServer.call_on_render_thread(cloud.set_source.bind(_bulb))
	march.configure(_bulb)
	# The node transform is deliberately left alone: switching bulbs used to reset the
	# scale here, which threw away wherever the user had grabbed and sized the cloud to.
	# Only entering bulb mode (see _set_bulb_mode) puts you inside the surface.
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
	if bulb_mode:
		if _bulb == null:
			return
		var want: int = BULB_STABILITY[bulb_stability_idx]
		if _bulb_settle > 0:
			# Fill the shell first. Everything after this measures or bakes the cloud as
			# it stands, so it had better be finished standing.
			_bulb_settle -= 1
			_bulb.update_mod = 1
			if _bulb_settle == 0:
				cloud.request_measure()
				_bake_wait = BAKE_DELAY_FRAMES
		elif _bake_wait > 0:
			# Let the measurement land: the bake bins particles into a grid sized from
			# the framing, and binning against a stale extent drops the outliers.
			_bake_wait -= 1
			_bulb.update_mod = 1
			if _bake_wait == 0 and auto_bake:
				RenderingServer.call_on_render_thread(cloud.bake)
		elif cloud.is_baking():
			# Hold the cloud still while it is being baked. The bake describes the
			# positions it read, so moving them underneath it invalidates the answer.
			_bulb.update_mod = 0
		else:
			_bulb.update_mod = want
		return
	var src := cloud.source as FlameSource
	if src == null:
		return
	# A frozen cloud that is morphing would keep the old attractor's points while the
	# genome moved out from under them, so a morph always forces iteration.
	if _morph_t < 1.0:
		src.update_mod = MORPH_UPDATE_MOD
	elif _converge > 0:
		src.update_mod = 1
	else:
		src.update_mod = STABILITY[stability_idx]


func _tick_morph(delta: float) -> void:
	if bulb_mode:
		# Bulbs cannot morph (there is no meaningful path between a Mandelbox scale and a
		# KIFS fold angle), but DRIFT still promises a tour of the gallery, so honour it
		# by cutting to the next one on the same timer rather than leaving the button dead.
		if _drift and _xr_focused:
			_drift_hold += delta
			if _drift_hold >= BULB_DRIFT_HOLD:
				_drift_hold = 0.0
				if recolor_on_drift and not library.themes.is_empty():
					_begin_theme_blend()
					theme_idx = randi() % library.themes.size()
				_load_bulb(bulb_idx + 1)
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
		if _drift and _xr_focused:
			_drift_hold += delta
			if _drift_hold >= DRIFT_HOLD:
				_drift_hold = 0.0
				if recolor_on_drift and not library.themes.is_empty():
					_begin_theme_blend()
					theme_idx = randi() % library.themes.size()
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
		_apply_palette()
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
	# The refresh-rate list is usually empty until the session has begun, so ask now and
	# again on session_begun; whichever call finds the rate wins.
	_request_refresh_rate()
	xr.session_begun.connect(_request_refresh_rate)
	# A system recenter moves the origin; the cloud should follow the viewer, not the
	# spot the old origin was.
	xr.pose_recentered.connect(_recenter)
	# session_visible is "visible but not focused": the Quest dash is up. Drift, spin
	# and the guard all measure or animate against frames the runtime is throttling.
	xr.session_visible.connect(func(): _xr_focused = false)
	xr.session_focussed.connect(func(): _xr_focused = true)
	# Phase 2 measured the point rendering as vertex-bound, not fill-bound: cutting the
	# eye buffer 2.8x saved only 1ms. 0.75 lands near the Quest 3's native ~2064x2208
	# and costs nothing visually, so take the free ~1ms and move on.
	xr.render_target_size_multiplier = RENDER_STEPS[render_idx]
	print("[fractal] OpenXR up. refresh=%.1f target=%s views=%d" % [
		xr.get_display_refresh_rate(), str(xr.get_render_target_size()), xr.get_view_count()])


func _env() -> Environment:
	return $WorldEnvironment.environment


func _request_refresh_rate() -> void:
	if xr == null:
		return
	var rates := xr.get_available_display_refresh_rates()
	if rates.has(TARGET_HZ) and not is_equal_approx(xr.get_display_refresh_rate(), TARGET_HZ):
		xr.set_display_refresh_rate(TARGET_HZ)
		print("[fractal] refresh rate set to %.0f" % TARGET_HZ)


## Directly in front of the viewer, at their eye height, using only the yaw of their
## head so the cloud never inherits a pitch or roll.
func _home_transform() -> Transform3D:
	var cam := xr_camera.global_transform
	var fwd := -cam.basis.z
	fwd.y = 0.0
	if fwd.length_squared() < 1e-4:
		fwd = Vector3.FORWARD
	fwd = fwd.normalized()
	var dist := BULB_HOME_DISTANCE if bulb_mode else HOME_DISTANCE
	var drop := BULB_HOME_DROP if bulb_mode else HOME_DROP
	var pos := cam.origin + fwd * dist
	pos.y = cam.origin.y - drop
	return Transform3D(Basis(), pos)


## Keep the frame rate off the floor whatever the settings multiply out to. Cuts are
## immediate and proportional (the further over budget, the harder the cut); recovery
## waits for a hold, then creeps, so it cannot oscillate against the cliff it fell off.
func _run_guard(delta: float) -> void:
	_guard_hold = maxf(0.0, _guard_hold - delta)
	if delta > GUARD_HITCH_S:
		return   # a stall, not a measurement
	var fps := 1.0 / maxf(delta, 1e-4)
	_fps_ema = lerpf(_fps_ema, fps, 0.08)
	if not splat_on:
		if _perf_scale < 1.0:
			_perf_scale = 1.0
			cloud.set_perf_scale(1.0)
		return
	_guard_slow = _guard_slow + 1 if fps < GUARD_CUT_FPS else 0
	if _guard_slow >= GUARD_SLOW_FRAMES:
		_guard_slow = 0
		_perf_scale = maxf(GUARD_FLOOR, _perf_scale * clampf(sqrt(_fps_ema / GUARD_CUT_FPS), 0.5, 0.95))
		cloud.set_perf_scale(_perf_scale)
		_guard_hold = GUARD_HOLD_S
	elif _perf_scale < 1.0 and _guard_hold <= 0.0 and _fps_ema > GUARD_RECOVER_FPS:
		_perf_scale = minf(1.0, _perf_scale * 1.01)
		cloud.set_perf_scale(_perf_scale)


func _set_passthrough(on: bool) -> void:
	if xr == null:
		return
	var env: Environment = $WorldEnvironment.environment
	if on:
		# Two doors to the same room. Newer Godot reports Meta passthrough as the alpha
		# environment blend mode; older vendor-plugin combinations only answer to
		# start_passthrough(). Try the blessed one first, fall back, and say which
		# worked, because "it says void" from inside a headset is not a bug report
		# anyone can act on.
		var modes := xr.get_supported_environment_blend_modes()
		if XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND in modes:
			xr.environment_blend_mode = XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND
			print("[xr] passthrough on via blend mode")
		elif xr.is_passthrough_supported():
			if not xr.start_passthrough():
				passthru_label = "n/a"
				print("[xr] passthrough: start_passthrough() refused")
				return
			print("[xr] passthrough on via start_passthrough")
		else:
			passthru_label = "n/a"
			print("[xr] passthrough: unsupported (modes=%s)" % str(modes))
			return
		get_viewport().transparent_bg = true
		if env != null:
			env.background_color = Color(0, 0, 0, 0)
		passthrough = true
		passthru_label = "room"
	else:
		if xr.environment_blend_mode != XRInterface.XR_ENV_BLEND_MODE_OPAQUE:
			xr.environment_blend_mode = XRInterface.XR_ENV_BLEND_MODE_OPAQUE
		xr.stop_passthrough()
		get_viewport().transparent_bg = false
		if env != null:
			env.background_color = Color(0, 0, 0, 1)
		passthrough = false
		passthru_label = "void"


func _recenter() -> void:
	var t := _home_transform()
	if tree_mode:
		# Trunk base on the floor, a few strides ahead, unit scale.
		var cam := xr_camera.global_transform
		var fwd := -cam.basis.z
		fwd.y = 0.0
		if fwd.length_squared() < 1e-4:
			fwd = Vector3.FORWARD
		fwd = fwd.normalized()
		t = Transform3D(Basis(), Vector3(cam.origin.x, 0.0, cam.origin.z) + fwd * TREE_DISTANCE)
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
	if _theme_blend < 1.0:
		# Match the shape transition, so colour and form arrive together.
		_theme_blend = minf(1.0, _theme_blend + delta / MORPH_STEPS[morph_idx])
		_apply_palette()
	if not _placed and _setup_done and xr_camera.global_transform.origin.length_squared() > 1e-6:
		_placed = true
		_recenter()
		if _help_pending:
			_help_pending = false
			_mark_help_seen()
			help.open()
	help.update(delta)
	_menu_active = menu.update(delta)
	if _xr_focused:
		_run_guard(delta)
	if _bulb != null:
		# The breath is the animation: each genome slowly reshapes whichever parameter
		# defines its form, so the surface is never static.
		_bulb.clock += delta * BREATH_STEPS[breath_idx]
		if march.is_on():
			march.tick(_bulb, cloud.center, cloud.fit)
		if _inside:
			_guard_inside()
	if not ground_mode and not tree_mode:
		_tick_morph(delta)   # the flame and its drift wait while you are on the ground
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
	if spin and _xr_focused and not ground_mode and (grab == null or not grab.is_grabbing()):
		cloud.rotate_y(AMBIENT_SPIN * delta)
		if not tree_mode:   # a tree turns; it does not tip over
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
	if ground_mode:
		var hp := xr_camera.global_transform.origin
		ground.update(Vector2(hp.x, hp.z), delta)
		_tick_orbit()
		return
	if tree_mode:
		tree.tick(delta)
		return
	# The depth sort is for the head; both eyes share one order, as Spark does.
	cloud.set_view(xr_camera.global_transform)
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
	# While the card is up the triggers only dismiss it. Both are read every frame rather
	# than short-circuited, or _pressed's edge state for the unread hand goes stale.
	if help.is_open():
		var r_trig := _pressed(right_hand, "trigger_click")
		var l_trig := _pressed(left_hand, "trigger_click")
		var key := _key(KEY_SPACE)
		if r_trig or l_trig or key:
			help.close()
		return

	var rs := Vector2.ZERO
	var ls := Vector2.ZERO
	if right_hand != null and right_hand.get_has_tracking_data():
		rs = right_hand.get_vector2("primary")
	if left_hand != null and left_hand.get_has_tracking_data():
		ls = left_hand.get_vector2("primary")
	if xr == null:
		rs = Vector2(Input.get_axis("ui_left", "ui_right"), Input.get_axis("ui_down", "ui_up"))

	if ground_mode:
		# Left stick walks the fractal under you, in the direction you face; right stick
		# Y zooms about the ground under your feet.
		var basis := xr_camera.global_transform.basis
		var fwd := Vector2(-basis.z.x, -basis.z.z)
		var right := Vector2(basis.x.x, basis.x.z)
		if fwd.length_squared() > 1e-6:
			fwd = fwd.normalized()
		if right.length_squared() > 1e-6:
			right = right.normalized()
		var grabbing := _ground_grab()
		if not grabbing:
			if ls.length() > 0.15:
				ground.pan((right * ls.x + fwd * ls.y) * GROUND_PAN_MPS * delta)
			if absf(rs.y) > 0.15:
				ground.zoom(exp(rs.y * GROUND_ZOOM_PER_S * delta))
			if absf(rs.x) > 0.15:
				ground.rotate_about_head(-rs.x * GROUND_TURN_RAD_S * delta)
	# Stick nudges are disabled while grabbing: fighting the hand for control of the
	# same transform makes the cloud feel like it is slipping.
	elif grab == null or not grab.is_grabbing():
		if absf(rs.x) > 0.15 and not menu.wants_stick():
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
		elif ground_mode:
			_ground_teleport(right_hand)
		elif tree_mode:
			tree.reseed()
		else:
			_morph_to_preset(preset_idx + 1)
	if _pressed(left_hand, "trigger_click") or _key(KEY_LEFT):
		if ground_mode:
			_ground_teleport(left_hand)
		elif tree_mode:
			tree.regrow()
		else:
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
## Recolour the live cloud from the theme list, without touching its genome.
func _cycle_theme(dir: int = 1) -> void:
	if library.themes.is_empty():
		return
	_begin_theme_blend()
	# -1 is "the genome's own palette", one slot before the first theme.
	theme_idx = wrapi(theme_idx + 1 + dir, 0, library.themes.size() + 1) - 1
	_apply_palette()


## The genome's own palette, or the chosen theme on top of it. Called anywhere the
## palette could be reset, so a theme survives morphs, preset changes and mode switches.
func _apply_palette() -> void:
	if cloud.source == null:
		return
	var target := _theme_palette()
	if _theme_blend < 1.0 and _theme_from.size() == target.size():
		var mixed: Array = []
		for i in target.size():
			mixed.append((_theme_from[i] as Vector3).lerp(target[i] as Vector3,
				Morph.smoothstep_t(_theme_blend)))
		cloud.override_palette(mixed)
		ground.set_palette(mixed)
		menu.set_palette(mixed)
		march.set_palette(mixed)
		tree.set_palette(mixed)
		orbit.set_palette(mixed)
	else:
		cloud.override_palette(target)
		ground.set_palette(target)
		menu.set_palette(target)
		march.set_palette(target)
		tree.set_palette(target)
		orbit.set_palette(target)


var _theme_cache: Dictionary = {}   # theme index -> Array[Vector3], parsed once


func _theme_palette() -> Array:
	if theme_idx < 0 or library.themes.is_empty():
		return cloud.source.palette() if cloud.source != null else []
	var ti := wrapi(theme_idx, 0, library.themes.size())
	if not _theme_cache.has(ti):
		var pal: Array = []
		for c in library.themes[ti]:
			pal.append(Vector3(float(c[0]), float(c[1]), float(c[2])))
		_theme_cache[ti] = pal
	return _theme_cache[ti]


## Start a cross-fade from the palette currently showing to whatever theme_idx now names.
func _begin_theme_blend() -> void:
	_theme_from = _theme_palette()
	_theme_blend = 0.0


func _apply_point_look() -> void:
	cloud.set_palette_cycles(COLOUR_CYCLES[colour_idx])
	ground.set_palette_cycles(COLOUR_CYCLES[colour_idx])
	cloud.set_opacity(OPACITY_STEPS[opacity_idx])
	cloud.set_density_strength(DENSITY_STEPS[density_idx])
	cloud.set_splat(splat_on, SPLAT_STEPS[splat_idx])
	cloud.set_coverage(BULB_COVERAGE[coverage_idx] if bulb_mode else 0.0)
	cloud.set_point_size(POINT_STEPS[point_idx])
	cloud.set_sharpness(SHARPNESS[point_idx])
	cloud.set_brightness(BRIGHT_STEPS[bright_idx])
	march.set_palette_cycles(COLOUR_CYCLES[colour_idx])
	march.set_gain(BRIGHT_STEPS[bright_idx] * MARCH_GAIN)


## Show either the splatted cloud or the marched surface, never both. Ground mode owns
## the cloud's visibility itself, so this only speaks when the cloud is the scene.
func _apply_surface() -> void:
	var marching: bool = bulb_mode and SURFACE_STEPS[surface_idx] > 0
	if not marching:
		_leave_inside()
	march.set_steps(SURFACE_STEPS[surface_idx] if bulb_mode else 0)
	if not ground_mode:
		cloud.set_visible_cloud(not marching)


## On Forward Mobile the flam3 pass cannot run (fixed-point colour buffer, no storage
## bit), so the compressive curve is the Environment's own tonemapper and this dial
## drives its exposure. The preset's flam3 exposure is still the starting point, scaled
## up because that value was tuned against an HDR accumulation buffer, not a 10-bit one.
func _apply_exposure() -> void:
	tonemap.exposure = _base_exposure * EXPOSURE_MUL[exposure_idx]
	var env: Environment = $WorldEnvironment.environment
	if env != null:
		# Runs every morph frame through _apply_tone; only touch the resource when the
		# value has actually moved, or every frame invalidates the environment.
		var want := clampf(_base_exposure * 3.0 * EXPOSURE_MUL[exposure_idx], 0.05, 60.0)
		if not is_equal_approx(env.tonemap_exposure, want):
			env.tonemap_exposure = want


func _pressed(c: XRController3D, action: String) -> bool:
	if c == null:
		return false
	# An untracked hand reads every button as released; the frame tracking returns
	# would then register a rising edge on a button held the whole time.
	if xr != null and not c.get_has_tracking_data():
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
	var sim := (ground.ground_us if ground_mode else cloud.iterate_us) / 1000.0
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
	if hud.visible:   # retired to the wrist; the perf print below is what this is for now
		hud.text = "\n".join(lines)

	# Log the levers that could be quietly reducing image quality over time, so the
	# degradation can be attributed instead of guessed at. Debug builds only: it is
	# fifteen formatted fields four times a second, and logcat writes can block.
	if not OS.is_debug_build():
		return
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


## First-run state lives in user://, which survives an update but not an uninstall. One key,
## one file: anything more would be a settings system nobody asked for.
const STATE_PATH := "user://state.cfg"


func _help_seen() -> bool:
	var cfg := ConfigFile.new()
	if cfg.load(STATE_PATH) != OK:
		return false
	return bool(cfg.get_value("ui", "seen_help", false))


func _mark_help_seen() -> void:
	var cfg := ConfigFile.new()
	cfg.load(STATE_PATH)  # keep whatever else is in there
	cfg.set_value("ui", "seen_help", true)
	cfg.save(STATE_PATH)


func _exit_tree() -> void:
	RenderingServer.call_on_render_thread(cloud.cleanup)
	RenderingServer.call_on_render_thread(ground.cleanup)
