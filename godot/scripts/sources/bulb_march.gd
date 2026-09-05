extends MeshInstance3D
class_name BulbMarch

## Raymarched bulb surface: a box in the cloud's local space whose fragment shader
## sphere-traces the bulb's distance estimate. The alternative to splatting the shell,
## switchable from the SURFACE tile so the two can be compared on the headset with the
## same genome, framing and palette.
##
## Sits as a child of the ParticleCloud, so grabs, spins and the auto-framing apply
## unchanged; cloud_center / cloud_fit are the same state-to-local mapping the splat
## shader uses. Breath parameters come from the BulbSource each frame, so the marched
## surface breathes in step with the projected particles.

var _mat: ShaderMaterial
var _steps := 0


func _init() -> void:
	name = "March"
	mesh = BoxMesh.new()
	_mat = ShaderMaterial.new()
	_mat.shader = load("res://shaders/march.gdshader")
	material_override = _mat
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	visible = false


## Size the box for a genome. Back faces only, so it has to cover the silhouette from
## outside: twice the DE's bound in state units, and auto-framing never lifts fit past 1.
func configure(src: BulbSource) -> void:
	(mesh as BoxMesh).size = Vector3.ONE * (4.0 * src.bound())


func set_steps(n: int) -> void:
	_steps = n
	visible = n > 0
	_mat.set_shader_parameter("max_steps", maxi(1, n))


func is_on() -> bool:
	return _steps > 0


func set_palette(pal: Array) -> void:
	for i in mini(5, pal.size()):
		_mat.set_shader_parameter("pal%d" % i, pal[i])


func set_gain(g: float) -> void:
	_mat.set_shader_parameter("gain", g)


func set_palette_cycles(c: float) -> void:
	_mat.set_shader_parameter("palette_cycles", c)


## Per frame while on: the breathing formula parameters and the cloud's current framing.
func tick(src: BulbSource, center: Vector3, fit: float) -> void:
	var mp := src.march_params()
	for k in mp:
		_mat.set_shader_parameter(k, mp[k])
	_mat.set_shader_parameter("cloud_center", center)
	_mat.set_shader_parameter("cloud_fit", fit)
