extends RefCounted
class_name IfsDive

## DIVE: hold the trigger and fly slowly into one copy of the sculpture, for ever.
##
## The IFS is exactly self-similar: every child is the whole under one map. So a step of the
## dive scales the sculpture up about a fixed point until the chosen child is the size and in
## the place the hero was, then re-roots: the child becomes the hero and the step starts again
## inside it. The pivot is the one point that the map from child to hero leaves where it is,
## which makes the motion a pure radial expansion out of a still point near where you look,
## the optic flow of flying forward, with nothing turning.
##
## A step never rebuilds. The motion is the grab target's transform, written once a frame; the
## frames outside the chosen child are flagged once in the hero's buffer when the step starts
## and dissolved by a shader uniform (FractalIFS.set_dive_target); and the re-root is a
## transform swap. The child's subtree is the whole tree one generation short, so after the
## swap the same buffer draws it as the hero and only the deepest generation is new, which
## grows in out of its parents the way a DETAIL step adds one. Whatever turn or mirror the map
## carried goes onto the IFS node's own transform, under the grab, so the grab's transform
## stays a plain rotation and scale.
##
## Comfort, from the vault's comfort kit: hold to move, eased in and out over half a second,
## constant rate, no roll, and the echoes stay put as the fixed reference. The rate follows the
## ambient-motion rule, about four times slower than first instinct: a FRAMES step (2.9x) takes
## about thirteen seconds.

## Zoom rate at full hold, in octaves (doublings of size) per second.
const OCT_S := 0.12
## Seconds from rest to full speed, and from full speed back to rest.
const EASE_S := 0.5
## Fraction of a step (in log scale) by which the frames being left behind have dissolved.
const FADE_END := 0.4
## From here to the end of a step the copy's frames glide from their colours as a child to
## their colours as the hero, so the re-root changes no colour.
const MIX_FROM := 0.3
## Tabletop only: the frames still showing must keep this far from the eyes for a child to be
## chosen. Room size has the eyes inside the sculpture and leans on the clip sphere instead.
const HEAD_MARGIN := 0.2
const SAMPLES := 8

var on := false
## Re-roots since the mode opened or recentred, for the status line and the harness.
var steps := 0
var _ifs: FractalIFS
## The node the grab moves, with the IFS hanging under it.
var _root: Node3D
## Eased hold, 0 at rest and 1 at full speed.
var _v := 0.0
## Progress through the current step, 0 to 1 in log scale.
var _t := 0.0
var _target := -1
var _map := Transform3D()
## The step's zoom factor: 1 / the chosen map's contraction.
var _k := 1.0
var _pivot := Vector3.ZERO
## The grab target's transform when the step began, and what this wrote to it last.
var _base := Transform3D()
var _last := Transform3D()
var _serial := -1


func setup(ifs: FractalIFS, root: Node3D) -> void:
	_ifs = ifs
	_root = root


func in_step() -> bool:
	return _target >= 0


func target() -> int:
	return _target


func progress() -> float:
	return _t


## 0 at rest, 1 at full speed: the eased hold while a step is moving, what a comfort
## vignette should follow. 0 between steps, where nothing moves however the trigger sits.
func motion() -> float:
	if not on or _target < 0:
		return 0.0
	return _v * _v * (3.0 - 2.0 * _v)


func set_on(v: bool) -> void:
	if not v:
		cancel()
		_v = 0.0
	on = v


## One frame. `held` is the trigger, already gated on focus, menu and help; `head` the camera.
func tick(delta: float, held: bool, head: Transform3D) -> void:
	if not on or _ifs == null:
		return
	_v = move_toward(_v, 1.0 if held else 0.0, delta / EASE_S)
	# Anything that rebuilt the shape (a SHAPE, DETAIL, UNDO, MOTION press) left the maps this
	# step was computed from behind. Go back to where the step began, on the new shape.
	if _target >= 0 and _ifs.build_serial != _serial:
		cancel()
	if _target < 0:
		if not held or not begin(head):
			return
	_rebase()
	var e := motion()
	if e <= 0.0:
		return
	_t += delta * e * OCT_S * log(2.0) / log(_k)
	if _t >= 1.0:
		finish()
		if held:
			begin(head)
		return
	apply()


## Something other than the dive moved the sculpture since the last frame: a grab, the stick,
## a two-hand scale. Carry the step with it rather than fight it: the move is a similarity G,
## and G composed with a homothety about P is the homothety about G(P) composed with G.
func _rebase() -> void:
	var now := _root.global_transform
	if now.is_equal_approx(_last):
		return
	var g := now * _last.affine_inverse()
	_base = g * _base
	_pivot = g * _pivot
	_last = now


## Choose a child and start a step. Public so a harness can start one without a trigger.
## Refuses mid-morph and away from DEPTH 1, where the shape is not a copy of its children.
func begin(head: Transform3D) -> bool:
	if _ifs.is_morphing() or absf(_ifs.depth - 1.0) > 1e-6 or _ifs.instance_count < 2:
		return false
	var maps := _ifs.child_maps_now(true)
	var hero := _root.global_transform * _ifs.transform
	var inv := hero.affine_inverse()
	var eye := head.origin
	var gaze := -head.basis.z
	var inside := _ifs.bounds.has_point(inv * eye)
	var best := -1
	var best_ang := INF
	var fall := -1
	var fall_clear := -INF
	for j in maps.size():
		var m := maps[j]
		var c := pow(absf(m.basis.determinant()), 1.0 / 3.0)
		if c <= 1e-3 or c >= 0.999:
			continue
		var k := 1.0 / c
		var tc := hero * m.origin
		var pivot := (tc * k - hero.origin) / (k - 1.0)
		var ang := gaze.angle_to(tc - eye) if (tc - eye).length() > 1e-4 else 0.0
		var clear := INF if inside else min_clear(hero, m, k, pivot, eye)
		if clear >= HEAD_MARGIN and ang < best_ang:
			best = j
			best_ang = ang
		if clear > fall_clear:
			fall = j
			fall_clear = clear
	if best < 0:
		best = fall
	if best < 0:
		return false
	_target = best
	_map = maps[best]
	_k = 1.0 / pow(absf(_map.basis.determinant()), 1.0 / 3.0)
	_pivot = (hero * _map.origin * _k - hero.origin) / (_k - 1.0)
	_base = _root.global_transform
	_last = _base
	_t = 0.0
	_ifs.set_dive_target(best)
	_serial = _ifs.build_serial
	return true


## Write the transform, the dissolve and the colour glide for the current progress. Four
## uniforms and one transform: nothing allocates.
func apply() -> void:
	var k := pow(_k, _t)
	_root.global_transform = Transform3D(_base.basis * k, _pivot + (_base.origin - _pivot) * k)
	_last = _root.global_transform
	_ifs.set_dive_fade(smoothstep(0.0, FADE_END, _t))
	var hero := _last * _ifs.transform
	var s := pow(absf(hero.basis.determinant()), 1.0 / 3.0)
	_ifs.set_dive_colour(hero * _map.origin, _ifs.radius_norm() * _k / maxf(s, 1e-6),
		smoothstep(MIX_FROM, 1.0, _t))


## Land the step: the chosen child becomes the hero. hero * map is the child; split it into
## the grab target (scale back down by the map's contraction, shifted by the map's offset) and
## the IFS node (the map's turn and mirror), so the product is exactly the child.
func finish() -> void:
	if _target < 0:
		return
	var top := Transform3D(_base.basis * _k, _pivot + (_base.origin - _pivot) * _k)
	var q := _ifs.transform.basis
	var c := 1.0 / _k
	_root.global_transform = top * Transform3D(Basis.from_scale(Vector3.ONE * c), q * _map.origin)
	_ifs.transform = Transform3D((q * (_map.basis * _k)).orthonormalized(), Vector3.ZERO)
	_last = _root.global_transform
	_ifs.set_dive_target(-1)
	_ifs.grow_deepest()
	_target = -1
	_t = 0.0
	steps += 1


## Back to where the current step began, wherever a grab has since carried it. The tile turned
## off, or the shape was rebuilt under the step.
func cancel() -> void:
	if _target < 0:
		return
	_rebase()
	_root.global_transform = _base
	_last = _base
	_ifs.set_dive_target(-1)
	_target = -1
	_t = 0.0


## Forget every step: a recentre or leaving the mode puts the pose back itself, so this only
## drops the state and the IFS node's accumulated turn.
func reset() -> void:
	if _ifs == null:
		return
	if _ifs.dive_target >= 0:
		_ifs.set_dive_target(-1)
	_target = -1
	_t = 0.0
	_v = 0.0
	steps = 0
	_ifs.transform = Transform3D.IDENTITY


## Nearest approach, in metres, of what is drawn during a step to the eyes: the hero's box
## while its outer frames are still showing, and the chosen child's box all the way. Boxes, so
## conservative; worked in the hero's own construction space, where the step is the same
## homothety about the pivot because the hero's transform is a similarity.
func min_clear(hero: Transform3D, m: Transform3D, k: float, pivot: Vector3, eye: Vector3) -> float:
	var inv := hero.affine_inverse()
	var e := inv * eye
	var p := inv * pivot
	var s := pow(absf(hero.basis.determinant()), 1.0 / 3.0)
	var outer: AABB = _ifs.bounds
	var inner: AABB = m * _ifs.bounds
	var best := INF
	for i in SAMPLES + 1:
		var t := float(i) / float(SAMPLES)
		var kk := pow(k, t)
		best = minf(best, _box_dist(e, p, inner, kk))
		if t <= FADE_END * 0.8:
			best = minf(best, _box_dist(e, p, outer, kk))
	return best * s


static func _box_dist(e: Vector3, p: Vector3, box: AABB, kk: float) -> float:
	var lo := p + (box.position - p) * kk
	var hi := lo + box.size * kk
	var dx := maxf(maxf(lo.x - e.x, e.x - hi.x), 0.0)
	var dy := maxf(maxf(lo.y - e.y, e.y - hi.y), 0.0)
	var dz := maxf(maxf(lo.z - e.z, e.z - hi.z), 0.0)
	return sqrt(dx * dx + dy * dy + dz * dz)
