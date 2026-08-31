extends RefCounted
class_name WorldGrab

## Two-handed "grab the world" manipulation, ported from src/xr/WorldGrab.ts.
##
##   one grip  translate + rotate the cloud rigidly with the hand
##   two grips translate + rotate + uniform scale (pull your hands apart to grow the
##             cloud around you and fly through it)
##
## Both cases go through one "grip frame" G built from the grabbing controllers. Each
## frame the cloud transform is G * G0.inverse() * M0, where G0 and M0 are the grip
## frame and cloud transform captured when the grab set last changed. Unifying the
## one- and two-hand cases this way is what stops the cloud jumping when the second
## hand joins or leaves.

var _target: Node3D
var _controllers: Array[XRController3D] = []
var _grabbing: Array[XRController3D] = []
var _g0_inv := Transform3D()
var _m0 := Transform3D()
var _active := false

## Below this the two-hand scale is ignored; hands touching would divide by ~0.
const MIN_SPAN := 1e-4
const MIN_SCALE := 0.02
const MAX_SCALE := 60.0


func _init(controllers: Array[XRController3D], target: Node3D) -> void:
	_controllers = controllers
	_target = target


func is_grabbing() -> bool:
	return not _grabbing.is_empty()


func grip_count() -> int:
	return _grabbing.size()


## Poll the grip buttons and recapture whenever the grabbing set changes. Polled
## rather than signal-driven so it cannot get out of step with the tracking data.
func update(_delta: float) -> void:
	var now: Array[XRController3D] = []
	for c in _controllers:
		if c != null and c.get_has_tracking_data() and c.is_button_pressed("grip_click"):
			now.append(c)

	if now.size() != _grabbing.size() or now != _grabbing:
		_grabbing = now
		_recapture()

	if not _active or _grabbing.is_empty():
		return
	var g = _grip_frame()
	if g == null:
		return
	var out: Transform3D = (g as Transform3D) * _g0_inv * _m0

	# Keep the scale uniform and sane. Two-hand scaling is a ratio of hand spans, so
	# a tracking glitch that briefly collapses the span would otherwise send the
	# cloud to infinity or invert it.
	var s := out.basis.get_scale()
	var uniform := clampf((s.x + s.y + s.z) / 3.0, MIN_SCALE, MAX_SCALE)
	var rot := out.basis.orthonormalized()
	_target.global_transform = Transform3D(rot.scaled(Vector3.ONE * uniform), out.origin)


## Build the grip frame from the currently grabbing controllers. Returns a
## Transform3D, or null when nothing is grabbed; hence the untyped return.
func _grip_frame() -> Variant:
	var n := _grabbing.size()
	if n == 0:
		return null

	if n == 1:
		# rigid: hand position and orientation, unit scale
		var t := _grabbing[0].global_transform
		return Transform3D(t.basis.orthonormalized(), t.origin)

	# two hands (more than two: use the first two)
	var p0 := _grabbing[0].global_transform.origin
	var p1 := _grabbing[1].global_transform.origin
	var mid := (p0 + p1) * 0.5
	var span := maxf(MIN_SPAN, p0.distance_to(p1))

	var x_axis := (p1 - p0).normalized()
	# pick an up hint that is not parallel to the hand-to-hand axis
	var up := Vector3.UP
	if absf(x_axis.dot(up)) > 0.95:
		up = Vector3.BACK
	var z_axis := x_axis.cross(up).normalized()
	var y_axis := z_axis.cross(x_axis).normalized()
	return Transform3D(Basis(x_axis, y_axis, z_axis).scaled(Vector3.ONE * span), mid)


func _recapture() -> void:
	var g = _grip_frame()
	if g == null:
		_active = false
		return
	_g0_inv = (g as Transform3D).affine_inverse()
	_m0 = _target.global_transform
	_active = true


## Put the cloud back where it started.
func reset(to: Transform3D) -> void:
	_target.global_transform = to
	_grabbing.clear()
	_active = false
