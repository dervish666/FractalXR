extends RefCounted
class_name FlameGalaxy

## GALAXY: stand inside the living flame. One press grows the flame around you to a few tens of
## metres, its dense middle a few metres ahead and never at the head, the way the SPEC's north
## star describes it. Two-hand grab could always get there; this is the one-press version with
## defaults that hold up from inside.
##
## Comfort first. A scene that fills the view and turns is the strongest vection trigger there
## is, so the host stops SPIN and DRIFT on the way in (and puts them back on the way out), and a
## spin turned back on inside runs at SPIN_MUL of the usual rate, about Y only. The growth is a
## held ease rather than a cut, at a rate picked by the ambient-motion rule (about four times
## slower than first instinct), and any grip takes over from it at once.
##
## Points stay one pixel at any distance, so a bigger flame costs about the same to draw; the
## same particles spread over more of the view, so it is dimmer per pixel, which BRIGHT_UP pays
## back. Splat mode is not used here: world-sized splats from inside are the expensive case.

## The flame's RMS radius once grown. Most of a flame lies inside twice its RMS radius, so this
## is a flame roughly 24 m across. 8 m was tried first: the outskirts thin as 1/R^2, and looking
## up or aside from inside it was faint dust (desktop sweep of 3.5, 5 and 8 m).
const RMS_M := 6.0
## Where its centre goes: this far ahead of the eyes and a little below them. The densest part
## of most flames is near the centre, so this is what keeps it off the head.
const AHEAD := 3.0
const DROP := 0.4
## The grow, and the shrink back out. First instinct said 2 s.
const TWEEN_S := 8.0
## Points closer than this to the eye fade out (points.gdshader near_fade).
const NEAR_FADE_M := 0.6
## Per-point brightness inside, at least (a higher BRIGHT the user chose stays). It has to be a
## value and not "one step up": ParticleCloud.set_brightness floors at 0.05, so the default
## 0.02 already draws at 0.05 and one step up changed nothing. Chosen from the desktop sweep
## in tools/flame_scale_shot.gd; see the CHANGELOG entry for the numbers.
const BRIGHT := 0.12
## A spin turned back on inside the galaxy runs at this share of AMBIENT_SPIN.
const SPIN_MUL := 0.25

## The galaxy's settings are in force (spin, drift, brightness, near fade).
var active := false
var _t := 1.0
var _from := Transform3D()
var _to := Transform3D()


## Where the flame goes: its centre AHEAD of the head along the level gaze, keeping the
## orientation it has now, at the scale that makes its RMS radius RMS_M. `rms_local` is the
## cloud's RMS radius at scale 1 (ParticleCloud.target_rms * target_fit).
static func target(cam: Transform3D, rot: Basis, rms_local: float) -> Transform3D:
	var fwd := -cam.basis.z
	fwd.y = 0.0
	if fwd.length_squared() < 1e-4:
		fwd = Vector3.FORWARD
	fwd = fwd.normalized()
	var pos := cam.origin + fwd * AHEAD
	pos.y = cam.origin.y - DROP
	var s := clampf(RMS_M / maxf(rms_local, 0.05), 1.0, WorldGrab.MAX_SCALE)
	return Transform3D(rot.orthonormalized().scaled(Vector3.ONE * s), pos)


func begin(from: Transform3D, to: Transform3D) -> void:
	_from = from
	_to = to
	_t = 0.0


func is_moving() -> bool:
	return _t < 1.0


func stop() -> void:
	_t = 1.0


## One frame of the ease. Scale moves in log space, so the growth looks even rather than
## all at the end; position and scale share one smoothstep.
func step(delta: float) -> Transform3D:
	_t = minf(1.0, _t + delta / TWEEN_S)
	var k := smoothstep(0.0, 1.0, _t)
	var s0 := _from.basis.get_scale().x
	var s1 := _to.basis.get_scale().x
	var s := s0 * pow(s1 / maxf(s0, 1e-4), k)
	var rot := _from.basis.orthonormalized().slerp(_to.basis.orthonormalized(), k)
	return Transform3D(rot.scaled(Vector3.ONE * s), _from.origin.lerp(_to.origin, k))
