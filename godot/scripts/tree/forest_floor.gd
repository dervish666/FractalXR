extends MeshInstance3D
class_name ForestFloor

## FLOOR's fractal ground (forest.gd): one plane under the trees carrying a faint Kaliset filigree
## in the theme's colours (shaders/tree_floor.gdshader), added to the void, so the dark between the
## lines stays the black it was. A child of the avenue's root, so it slides with the trees on a walk
## and grabs and scales with them; it re-centres on you every frame, and the pattern is worked out
## in the avenue's frame, so the re-centring never moves a line.
##
## The pattern is baked once, the first time the ground is shown: one draw of
## tree_floor_bake.gdshader into a BAKE-square SubViewport, read back, mipmapped on the CPU and
## kept as a two-channel texture (2.8 MB with its mips). Measured on the M1 Pro, the live per-pixel
## version cost 0.37 ms a frame of floor; this costs one texture read a pixel. The bake waits a
## frame for the draw, so the ground appears a frame or two after the switch.
##
## Cost: one draw, two triangles, one mipmapped read per floor pixel.

const SIZE := 64.0              # metres square; the shader fades it out well inside
const AVENUE_RADIUS := 26.0     # metres from you where the avenue's floor has faded out
const GROVE_PAD := 1.4          # metres past the grove's rim
const BAKE := 1024              # texels across the tile: 4 mm a texel on the 4 m tile

var baked := false
var bake_ms := 0.0              # the readback, mipmaps and upload (the harness reads it)
var _baking := false
var _mat := ShaderMaterial.new()
var _at := Vector2.INF
var _radius := -1.0


func _init() -> void:
	name = "Floor"
	_mat.shader = load("res://shaders/tree_floor.gdshader")
	material_override = _mat
	var pm := PlaneMesh.new()
	pm.size = Vector2(SIZE, SIZE)
	mesh = pm
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# A millimetre up, so the floor never fights the trunks' bases for depth.
	position.y = 0.001
	visible = false


## Show or hide; the first show bakes the pattern.
func set_on(on: bool) -> void:
	visible = on
	if on and not baked and not _baking and is_inside_tree():
		_bake()


func _bake() -> void:
	_baking = true
	var vp := SubViewport.new()
	vp.size = Vector2i(BAKE, BAKE)
	vp.disable_3d = true
	vp.transparent_bg = false
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	var rect := ColorRect.new()
	rect.size = Vector2(BAKE, BAKE)
	var m := ShaderMaterial.new()
	m.shader = load("res://shaders/tree_floor_bake.gdshader")
	rect.material = m
	vp.add_child(rect)
	add_child(vp)
	await RenderingServer.frame_post_draw
	var t0 := Time.get_ticks_usec()
	var img := vp.get_texture().get_image()
	vp.queue_free()
	if img == null or img.is_empty():
		push_error("[floor] the pattern bake read back nothing; the ground stays dark")
		_baking = false
		return
	img.convert(Image.FORMAT_RG8)
	img.generate_mipmaps()
	_mat.set_shader_parameter(&"pattern", ImageTexture.create_from_image(img))
	bake_ms = float(Time.get_ticks_usec() - t0) / 1000.0
	baked = true
	_baking = false
	print("[floor] pattern baked: %dx%d, readback + mipmaps + upload %.1f ms" % [BAKE, BAKE, bake_ms])


## Centre on `p` (metres, in the parent's floor plane) and fade out by `radius`. Writes only what moved.
func follow(p: Vector2, radius: float) -> void:
	if p != _at:
		_at = p
		position = Vector3(p.x, 0.001, p.y)
		_mat.set_shader_parameter(&"offset", p)
	if radius != _radius:
		_radius = radius
		_mat.set_shader_parameter(&"radius", radius)


func set_palette(pal: Array) -> void:
	var names: Array[StringName] = [&"pal1", &"pal2", &"pal3"]
	for i in names.size():
		if pal.size() > i + 1:
			_mat.set_shader_parameter(names[i], pal[i + 1])
