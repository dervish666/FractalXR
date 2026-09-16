extends Node3D
class_name IfsEditor

## The sculpting handles for FractalIFS: two mirror-plane guides and a pair of depth handles,
## picked with the controller ray or the hand itself and dragged with the trigger held.
##
## A child of the FractalIFS node, so this node's local space IS the construction space the
## parameters live in. Every conversion is one affine_inverse of the IFS's global transform,
## which means a grabbed, rotated, scaled sculpture needs no special case: the parameters do
## not know the cloud transform exists. Guide sizes are construction units too, so they scale
## with the sculpture without a per-frame rescale.
##
## Ownership is main's to resolve. This class is told once per frame whether it may capture
## and reports whether it took the trigger; see main._ifs_edit_pass for the priority order.

## The guide square reaches just past the seed frame, so its border is readable against empty
## space rather than lost among the beams. Not further: a plane that is not edge-on to the eye
## shows its near edge, and at 1.35 that edge came within a hand's width of the face and filled
## the view the moment a plane was moved off centre.
const GUIDE_HALF := 1.15
const LINE_W := 0.022
const KNOB_R := 0.13
## Where each plane's grab target sits inside its guide. The two land on different world axes
## (plane A on +Y, plane B on -X) and the depth plates on +-Z, so no two handles are ever
## within a pick radius of each other at any allowed parameter value.
const KNOB_OUT := 1.05
## Generous, because a 0.6 m sculpture makes every target small: 0.42 construction units is
## about 11 cm at the tabletop scale. Near and far picking share it.
const PICK_RADIUS := 0.42
## How far the depth plates float beyond the published z extent.
const DEPTH_MARGIN := 0.22
const MAX_OFFSET := 0.3
const MAX_TILT_DEG := 30.0
## Detail 4 measured about 4 ms to rebuild on desktop (IFS-1), too long to spend on every
## frame of a drag, so a drag previews down to the ceiling the preset publishes and the release
## rebuilds at the real rung. The ceiling lives in FractalIFS.PRESETS because it depends on the
## preset's branching factor, not on the editor.
const DASHES := 3

const COL_A := Color(0.55, 0.85, 1.0)
const COL_B := Color(1.0, 0.72, 0.45)
const COL_DEPTH := Color(0.72, 0.95, 0.62)
const COL_HOVER := Color(1.0, 1.0, 1.0)
const COL_HELD := Color(1.0, 0.45, 0.72)

enum { NONE = -1, PLANE_A = 0, PLANE_B = 1, DEPTH_FRONT = 2, DEPTH_BACK = 3 }
const HANDLE_NAMES := ["PLANE A", "PLANE B", "DEPTH", "DEPTH"]

var guides_on := false

var _ifs: FractalIFS = null
var _roots: Array[Node3D] = []
var _knobs: Array[MeshInstance3D] = []
var _knob_mats: Array[StandardMaterial3D] = []

var _held := NONE
var _hover := NONE
var _hand: XRController3D = null
## Per hand: a trigger that must be released before it can capture again. Set by cancel, so a
## button held through tracking loss, a menu takeover or a mode change cannot become a fresh
## press the instant the editor is allowed to look again.
var _rearm: Array = [false, false]

var _grab_off := Vector3.ZERO
var _start := Vector3.ZERO
var _n0 := Vector3.ZERO
var _d0 := 0.0
var _b0_inv := Basis()
var _z_per_depth := 1.0
var _full_detail := 3
var _snap := {}
var _undo_snap := {}
var _has_undo := false


func setup(ifs: FractalIFS) -> void:
	_ifs = ifs
	name = "Editor"
	visible = false
	_build_plane(PLANE_A, COL_A, "PLANE A", false)
	_build_plane(PLANE_B, COL_B, "PLANE B", true)
	_build_depth(DEPTH_FRONT)
	_build_depth(DEPTH_BACK)
	refresh()


# --- state ------------------------------------------------------------------

func set_guides(on: bool) -> void:
	guides_on = on
	visible = on
	if on:
		refresh()
	else:
		cancel()


func is_editing() -> bool:
	return _held != NONE


func held_handle() -> int:
	return _held


func hovered_handle() -> int:
	return _hover


func handle_label() -> String:
	if _held == NONE:
		return ""
	return HANDLE_NAMES[_held]


## The wrist panel's line while a handle is captured.
func status() -> String:
	if _held == NONE:
		return ""
	return "editing %s" % HANDLE_NAMES[_held]


func has_undo() -> bool:
	return _has_undo


## RESET is the other direction from UNDO, so it clears this: one step back must never land
## on a shape from before the reset.
func clear_undo() -> void:
	_has_undo = false
	_undo_snap = {}


## The rung a drag returns to on release. Stepping DETAIL mid-drag would otherwise be undone
## by the next drag frame, which rebuilds at the preview rung.
func set_detail(d: int) -> void:
	_full_detail = d
	if _held != NONE and _ifs != null:
		_ifs.detail = _drag_detail()


## One step back to the parameters as they were when the last completed edit was captured.
func undo() -> bool:
	if not _has_undo or _ifs == null:
		return false
	_apply(_undo_snap)
	_has_undo = false
	_undo_snap = {}
	_ifs.build()
	refresh()
	return true


## Abandon an unfinished edit: parameters back to the capture snapshot, ownership ended, and
## both triggers must be released before anything can be captured again. Safe when idle.
func cancel() -> void:
	if _held == NONE:
		return
	_apply(_snap)
	_end()
	_rearm = [true, true]
	_ifs.detail = _full_detail
	_ifs.build()
	refresh()


# --- the per-frame pass -----------------------------------------------------

## Called once per frame from main, before WorldGrab.update. `hands` are the controllers;
## `edge[i]`, `held[i]` and `tracked[i]` describe hand i's trigger and tracking, read by the
## caller so one poll serves both this pass and _handle_input. `allow` is false when something
## above the editor in the priority order owns the input. Returns true while the editor owns
## the trigger, so nothing below it acts on the same press.
func update(hands: Array[XRController3D], edge: Array, held: Array, tracked: Array,
		allow: bool) -> bool:
	for i in hands.size():
		if i < held.size() and not held[i]:
			_rearm[i] = false
	if _ifs == null:
		return false
	if not guides_on or not allow:
		# Everything above the editor is a reason to CANCEL rather than merely to skip: an
		# unfinished edit left half applied is worse than no edit.
		cancel()
		_set_hover(NONE)
		return false

	if _held != NONE:
		var i := hands.find(_hand)
		if i < 0 or i >= tracked.size() or not tracked[i]:
			cancel()          # tracking went away mid-drag
		elif i >= held.size() or not held[i]:
			_commit()
		else:
			_drag(_hand)
		return true

	# Nothing captured. Hover is the closest eligible handle over both hands, but the hand
	# that actually pulls decides what it captures: a hand with a handle under it must not be
	# blocked because the other hand happens to be nearer a different one.
	var picks: Array = []
	for i in hands.size():
		var ok: bool = i < tracked.size() and tracked[i] and hands[i] != null
		picks.append(_nearest(hands[i]) if ok else [NONE, INF])
	var best := NONE
	var best_d := INF
	for p in picks:
		if int(p[0]) != NONE and float(p[1]) < best_d:
			best = int(p[0])
			best_d = float(p[1])
	_set_hover(best)
	for i in hands.size():
		if i < edge.size() and edge[i] and not _rearm[i] and int(picks[i][0]) != NONE:
			_capture(int(picks[i][0]), hands[i])
			return true
	return false


## Nearest eligible handle to one hand, as [handle, distance] in construction units.
func _nearest(hand: XRController3D) -> Array:
	if hand == null:
		return [NONE, INF]
	var inv := _ifs.global_transform.affine_inverse()
	var o: Vector3 = inv * hand.global_transform.origin
	var dir: Vector3 = inv.basis * (-hand.global_transform.basis.z)
	if dir.length() < 1e-6:
		return [NONE, INF]
	dir = dir.normalized()
	var best := NONE
	var best_d := INF
	for i in _roots.size():
		var p := _handle_pos(i)
		# Near and far picking from one number. The ray is clamped at the hand, so pointing
		# away from a handle never picks it however close the infinite line passes.
		var t := maxf(0.0, (p - o).dot(dir))
		var d := minf(o.distance_to(p), (o + dir * t).distance_to(p))
		if d < PICK_RADIUS and d < best_d:
			best = i
			best_d = d
	return [best, best_d]


func _capture(which: int, hand: XRController3D) -> void:
	_held = which
	_hand = hand
	_snap = _params()
	_full_detail = _ifs.detail
	var inv := _ifs.global_transform.affine_inverse()
	var hand_c: Vector3 = inv * hand.global_transform.origin
	_start = _handle_pos(which)
	# Hold the handle where it was grabbed rather than snapping it onto the hand: a far pick
	# would otherwise yank the plane the whole way to the controller as the trigger closed.
	_grab_off = _start - hand_c
	_b0_inv = hand.global_transform.basis.orthonormalized().inverse()
	if which == PLANE_A:
		_n0 = _unit(_ifs.plane1_normal, FractalIFS.DEFAULT_N1)
		_d0 = _ifs.plane1_offset
	elif which == PLANE_B:
		_n0 = _unit(_ifs.plane2_normal, FractalIFS.DEFAULT_N2)
		_d0 = _ifs.plane2_offset
	else:
		# The depth stretch is the first factor of every published transform, so the z extent
		# is exactly proportional to depth. One division at capture fixes the handle-to-depth
		# mapping for the whole drag, and inverting it is what keeps the centre fixed.
		_z_per_depth = maxf(_half_z() / maxf(_ifs.depth, 1e-3), 1e-3)
	_set_hover(NONE)
	_style()
	hand.trigger_haptic_pulse("haptic", 0.0, 0.45, 0.03, 0.0)


## One edit committed. The capture snapshot becomes the one UNDO restores, and only now: an
## edit that was cancelled never happened, so it must not be what UNDO goes back to.
func _commit() -> void:
	_undo_snap = _snap
	_has_undo = true
	if _hand != null:
		_hand.trigger_haptic_pulse("haptic", 0.0, 0.3, 0.02, 0.0)
	_end()
	_ifs.detail = _full_detail
	_ifs.build()
	refresh()


func _end() -> void:
	_held = NONE
	_hand = null
	_style()


func _drag(hand: XRController3D) -> void:
	var inv := _ifs.global_transform.affine_inverse()
	var target: Vector3 = (inv * hand.global_transform.origin) + _grab_off
	if _held == PLANE_A or _held == PLANE_B:
		# Rotation comes from the controller's own orientation delta, carried into construction
		# space so a rotated or scaled sculpture turns with the wrist rather than with the room.
		var bc := _ifs.global_transform.basis.orthonormalized()
		var rel := bc.inverse() * (hand.global_transform.basis.orthonormalized() * _b0_inv) * bc
		var n := _cone(rel * _n0, FractalIFS.DEFAULT_N1 if _held == PLANE_A else FractalIFS.DEFAULT_N2)
		# Translation is the hand's displacement projected onto the normal the plane had at
		# capture. Against the LIVE normal the same hand motion would mean different things as
		# the plane turned, and returning the hand to where it started would not undo the move.
		var d := clampf(_d0 + _n0.dot(target - _start), -MAX_OFFSET, MAX_OFFSET)
		if _held == PLANE_A:
			_ifs.plane1_normal = n
			_ifs.plane1_offset = d
		else:
			_ifs.plane2_normal = n
			_ifs.plane2_offset = d
	else:
		var sgn := 1.0 if _held == DEPTH_FRONT else -1.0
		_ifs.depth = clampf((sgn * target.z - DEPTH_MARGIN) / _z_per_depth,
			FractalIFS.DEPTH_MIN, FractalIFS.DEPTH_MAX)
	_ifs.detail = _drag_detail()
	_ifs.build()
	# Guides are placed from the parameters, not from the last published buffer, so a handle
	# keeps up with the hand at whatever rung the rebuild is running.
	refresh()


func _drag_detail() -> int:
	return mini(_full_detail, _ifs.drag_detail())


# --- guides -----------------------------------------------------------------

## Put every guide where its parameters say it is. Cheap enough to call after any change.
func refresh() -> void:
	if _ifs == null or _roots.size() < 4:
		return
	_place_plane(PLANE_A, _unit(_ifs.plane1_normal, FractalIFS.DEFAULT_N1), _ifs.plane1_offset)
	_place_plane(PLANE_B, _unit(_ifs.plane2_normal, FractalIFS.DEFAULT_N2), _ifs.plane2_offset)
	var z := _half_z() + DEPTH_MARGIN
	_roots[DEPTH_FRONT].transform = Transform3D(Basis(), Vector3(0.0, 0.0, z))
	_roots[DEPTH_BACK].transform = Transform3D(Basis(), Vector3(0.0, 0.0, -z))


## A frame whose z axis is the plane normal, so the guide's own xy plane IS the mirror plane
## and moving the plane is one transform assignment.
func _place_plane(which: int, n: Vector3, d: float) -> void:
	var up := Vector3.UP if absf(n.dot(Vector3.UP)) < 0.9 else Vector3.BACK
	var x := up.cross(n).normalized()
	var y := n.cross(x).normalized()
	_roots[which].transform = Transform3D(Basis(x, y, n), n * d)


func _half_z() -> float:
	var b := _ifs.bounds
	return maxf(b.position.z + b.size.z, 0.1)


## Construction-space position of a handle's grab target. The editor node itself is never
## transformed, so a root's own transform is the whole conversion.
func _handle_pos(i: int) -> Vector3:
	return _roots[i].transform * _knobs[i].position


func _set_hover(h: int) -> void:
	if h == _hover:
		return
	_hover = h
	_style()


func _style() -> void:
	for i in _knob_mats.size():
		var c: Color = COL_A if i == PLANE_A else (COL_B if i == PLANE_B else COL_DEPTH)
		if i == _held:
			c = COL_HELD
		elif i == _hover:
			c = COL_HOVER
		_knob_mats[i].albedo_color = Color(c, 0.95)


# --- parameters -------------------------------------------------------------

func _params() -> Dictionary:
	return {
		"plane1_normal": _ifs.plane1_normal,
		"plane1_offset": _ifs.plane1_offset,
		"plane2_normal": _ifs.plane2_normal,
		"plane2_offset": _ifs.plane2_offset,
		"depth": _ifs.depth,
	}


func _apply(p: Dictionary) -> void:
	if p.is_empty() or _ifs == null:
		return
	for k in p:
		_ifs.set(k, p[k])


static func _unit(n: Vector3, fallback: Vector3) -> Vector3:
	return n.normalized() if n.is_finite() and n.length() > 1e-4 else fallback


## Hold a normal inside MAX_TILT_DEG of the plane's default. Past the limit it is pinned to
## the cone boundary in the plane the two normals span, so the handle stops rather than jumps.
static func _cone(n: Vector3, base: Vector3) -> Vector3:
	if not n.is_finite() or n.length() < 1e-4:
		return base
	n = n.normalized()
	var a := acos(clampf(n.dot(base), -1.0, 1.0))
	var lim := deg_to_rad(MAX_TILT_DEG)
	if a <= lim:
		return n
	var axis := base.cross(n)
	if axis.length() < 1e-6:
		return base   # exactly opposed: no unique plane to rotate in
	return base.rotated(axis.normalized(), lim).normalized()


# --- construction -----------------------------------------------------------

func _build_plane(which: int, col: Color, text: String, dashed: bool) -> void:
	var root := Node3D.new()
	root.name = "PlaneA" if which == PLANE_A else "PlaneB"
	add_child(root)
	var line_mat := _flat(col, 0.8)
	# The two planes are tellable apart without colour: A has a continuous border, B a dashed
	# one, and each carries its own label.
	for seg in (_dashed_border() if dashed else _solid_border()):
		_beam(root, line_mat, seg[0], seg[1])
	var knob := MeshInstance3D.new()
	knob.name = "Knob"
	var sphere := SphereMesh.new()
	sphere.radius = KNOB_R
	sphere.height = KNOB_R * 2.0
	sphere.radial_segments = 16
	sphere.rings = 8
	knob.mesh = sphere
	var km := _flat(col, 0.95)
	knob.material_override = km
	knob.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Different in-plane directions for the two, so the grab targets never coincide when both
	# planes sit at the origin, which is exactly where they start.
	knob.position = Vector3(0.0, KNOB_OUT, 0.0) if which == PLANE_A else Vector3(KNOB_OUT, 0.0, 0.0)
	root.add_child(knob)
	knob.add_child(_label(text, col))
	_roots.append(root)
	_knobs.append(knob)
	_knob_mats.append(km)


func _build_depth(which: int) -> void:
	var root := Node3D.new()
	root.name = "DepthFront" if which == DEPTH_FRONT else "DepthBack"
	add_child(root)
	var ring := MeshInstance3D.new()
	ring.name = "Knob"
	var torus := TorusMesh.new()
	# A ring, not a ball or a plate. Both depth handles sit on the z axis and so land on the
	# middle of the view from straight ahead; a solid one covered the shape it was stretching.
	torus.inner_radius = KNOB_R * 0.8
	torus.outer_radius = KNOB_R * 1.2
	torus.rings = 24
	torus.ring_segments = 6
	ring.mesh = torus
	# TorusMesh lies in the xz plane. Stand it up so it faces along z, the axis it stretches.
	ring.rotation = Vector3(deg_to_rad(90.0), 0.0, 0.0)
	var km := _flat(COL_DEPTH, 0.95)
	ring.material_override = km
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(ring)
	ring.add_child(_label("DEPTH", COL_DEPTH))
	_roots.append(root)
	_knobs.append(ring)
	_knob_mats.append(km)


## [centre, size] for the four sides of the guide square, in the plane's own frame.
static func _solid_border() -> Array:
	var long := Vector3(GUIDE_HALF * 2.0 + LINE_W, LINE_W, LINE_W)
	var tall := Vector3(LINE_W, GUIDE_HALF * 2.0 + LINE_W, LINE_W)
	return [
		[Vector3(0.0, GUIDE_HALF, 0.0), long],
		[Vector3(0.0, -GUIDE_HALF, 0.0), long],
		[Vector3(-GUIDE_HALF, 0.0, 0.0), tall],
		[Vector3(GUIDE_HALF, 0.0, 0.0), tall],
	]


## The same square as dashes and gaps of equal length, DASHES per side.
static func _dashed_border() -> Array:
	var span := GUIDE_HALF * 2.0
	var l := span / float(DASHES * 2 - 1)
	var out: Array = []
	for k in DASHES:
		var c := -GUIDE_HALF + l * 0.5 + float(k) * l * 2.0
		out.append([Vector3(c, GUIDE_HALF, 0.0), Vector3(l, LINE_W, LINE_W)])
		out.append([Vector3(c, -GUIDE_HALF, 0.0), Vector3(l, LINE_W, LINE_W)])
		out.append([Vector3(-GUIDE_HALF, c, 0.0), Vector3(LINE_W, l, LINE_W)])
		out.append([Vector3(GUIDE_HALF, c, 0.0), Vector3(LINE_W, l, LINE_W)])
	return out


func _beam(parent: Node3D, mat: StandardMaterial3D, c: Vector3, s: Vector3) -> void:
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = s
	mi.mesh = box
	mi.material_override = mat
	mi.position = c
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)


## The wrist menu's face, so the handles are labelled in the same hand as the rest of the app.
func _label(text: String, col: Color) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.font = WristMenu._font(500)
	l.font_size = 40
	# 0.088 construction units tall, about 24 mm at the tabletop scale and scaling with it. At
	# twice this the four labels wrote over each other and over the sculpture.
	l.pixel_size = 0.0022
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.double_sided = true
	l.modulate = col
	l.outline_modulate = Color(0.0, 0.0, 0.0, 0.85)
	l.outline_size = 6
	l.position = Vector3(0.0, KNOB_R * 2.4, 0.0)
	return l


static func _flat(col: Color, a: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.disable_receive_shadows = true
	m.albedo_color = Color(col, a)
	return m
