extends MeshInstance3D
class_name ComfortVignette

## A tunnel vignette for whenever the world moves past you: the edges of the view darken as
## motion builds and clear when it stops. Peripheral optic flow is what sells vection, and
## vection with a still body is what makes people sick, so this trims the periphery only
## while something is actually moving you.
##
## Reuse: parent one to the XRCamera3D and call set_motion() every frame with 0 (still) to
## 1 (full speed), after set_profile() (DIVE or WALK, below). Ease the input yourself (the
## avenue walk eases over 0.4 s); the vignette follows it exactly, times the profile's gain, so it
## can never lag behind the motion it is hiding. Hidden at 0, it costs no draw.
##
## Cost: one alpha-blended ring per eye. The ring's inner edge tracks the clear window
## (vignette.gdshader), so at low strength it is a thin band past the edge of the view, and
## at full strength it covers the periphery outside about 35 degrees. Guess: well under a
## millisecond on Quest 3; not measured on the headset.

const DIST := 0.5       # metres ahead of the head; the shader's `dist` must match
const SEGMENTS := 48

## How hard the tunnel closes, per caller. clear: the clear window's half-angle at full strength
## (radians). open: its half-angle as strength leaves 0. feather: radians from clear to darkest.
## alpha: the darkest it gets. gain: strength is motion times this, capped at 1, so above 1 the
## tunnel is shut before the motion peaks and stays shut until it has nearly stopped. rest: the
## rest frame's brightness (vignette.gdshader), 0 for none.
##
## DIVE is the original tunnel: clear to 36 degrees off centre, darkest past 59. A Quest 3 eye sees
## to roughly 48 degrees above and below centre; on a 96-degree field (tools/comfort_shot.sh) it
## took 50% of the light at the top and bottom edges and 43% at the sides, and the walk at 1 m/s
## under it made Sam mildly sick (2026-10-11). WALK clears to 29 degrees and is at its darkest by
## 49: 95% and 92% there, half dark from 39 degrees out. It starts closing at the field's edge the
## moment you move and is shut by half the pace. Dynamic field-of-view restriction (Fernandes and
## Feiner, IEEE 3DUI 2016) cut sickness without most users noticing it, and Meta's locomotion
## guidance is vignettes during movement.
const DIVE := {"clear": 0.62, "open": 1.65, "feather": 0.4, "alpha": 0.9, "gain": 1.0, "rest": 0.0}
const WALK := {"clear": 0.5, "open": 0.95, "feather": 0.35, "alpha": 0.95, "gain": 2.0, "rest": 0.15}

var motion := 0.0
var profile: Dictionary = DIVE
var _gain := 1.0
var _mat := ShaderMaterial.new()


func _init() -> void:
	name = "ComfortVignette"
	_mat.shader = load("res://shaders/vignette.gdshader")
	_mat.render_priority = Material.RENDER_PRIORITY_MAX
	_mat.set_shader_parameter(&"dist", DIST)
	material_override = _mat
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	extra_cull_margin = 1.0   # the shader moves the rings; never cull a head-locked layer
	mesh = _ring()
	visible = false


## DIVE or WALK (above). Writes nothing when it is already the one in use.
func set_profile(p: Dictionary) -> void:
	if p == profile:
		return
	profile = p
	_gain = float(p["gain"])
	_mat.set_shader_parameter(&"clear_full", float(p["clear"]))
	_mat.set_shader_parameter(&"clear_open", float(p["open"]))
	_mat.set_shader_parameter(&"feather", float(p["feather"]))
	_mat.set_shader_parameter(&"max_alpha", float(p["alpha"]))
	_mat.set_shader_parameter(&"rest", float(p["rest"]))


## The rest frame's colour: the theme's, so the lattice in the dark is the scene's own hue.
func set_rest_tint(c: Vector3) -> void:
	_mat.set_shader_parameter(&"rest_tint", c)


## 0 still, 1 full speed. Writes nothing when the value has not moved.
func set_motion(m: float) -> void:
	m = clampf(m * _gain, 0.0, 1.0)
	if m == motion:
		return
	motion = m
	visible = m > 0.001
	_mat.set_shader_parameter(&"strength", m)


## A flat annulus facing the head. Only its topology matters: the shader places both rings
## (UV.x 0 inner, 1 outer) by angle every frame.
static func _ring() -> ArrayMesh:
	var v := PackedVector3Array()
	var uv := PackedVector2Array()
	for i in SEGMENTS:
		var a0 := TAU * float(i) / SEGMENTS
		var a1 := TAU * float(i + 1) / SEGMENTS
		var i0 := Vector3(cos(a0), sin(a0), -1.0) * 0.3
		var i1 := Vector3(cos(a1), sin(a1), -1.0) * 0.3
		var o0 := Vector3(cos(a0) * 3.0, sin(a0) * 3.0, -0.3)
		var o1 := Vector3(cos(a1) * 3.0, sin(a1) * 3.0, -0.3)
		v.append_array([i0, o0, o1, i0, o1, i1])
		uv.append_array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 0),
			Vector2(0, 0), Vector2(1, 0), Vector2(0, 0)])
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = v
	arr[Mesh.ARRAY_TEX_UV] = uv
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return m
