extends MeshInstance3D
class_name ComfortVignette

## A tunnel vignette for whenever the world moves past you: the edges of the view darken as
## motion builds and clear when it stops. Peripheral optic flow is what sells vection, and
## vection with a still body is what makes people sick, so this trims the periphery only
## while something is actually moving you.
##
## Reuse: parent one to the XRCamera3D and call set_motion() every frame with 0 (still) to
## 1 (full speed). Ease the input yourself (the avenue walk eases over half a second); the
## vignette follows it exactly, so it can never lag behind the motion it is hiding. Nothing
## else to wire: hidden at 0, it costs no draw.
##
## Cost: one alpha-blended ring per eye. The ring's inner edge tracks the clear window
## (vignette.gdshader), so at low strength it is a thin band past the edge of the view, and
## at full strength it covers the periphery outside about 35 degrees. Guess: well under a
## millisecond on Quest 3; not measured on the headset.

const DIST := 0.5       # metres ahead of the head; the shader's `dist` must match
const SEGMENTS := 48

var motion := 0.0
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


## 0 still, 1 full speed. Writes nothing when the value has not moved.
func set_motion(m: float) -> void:
	m = clampf(m, 0.0, 1.0)
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
