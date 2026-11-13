extends RemoteTransform3D
class_name WorldQuad

## Godot 4.7.2 updates a composition layer's pose on PARENTED, before tree entry.
## A direct XROrigin3D parent makes that path use the local transform. Mirror the
## panel's world pose here so wrist, float and pin still follow their original host.
var layer: OpenXRCompositionLayerQuad


static func attach(host: Node3D, origin: XROrigin3D, viewport: SubViewport,
		size: Vector2, order: int) -> OpenXRCompositionLayerQuad:
	var follower := WorldQuad.new()
	var quad := OpenXRCompositionLayerQuad.new()
	follower.layer = quad
	quad.quad_size = size
	quad.alpha_blend = true
	quad.sort_order = order
	quad.visible = false
	origin.add_child(quad)
	quad.layer_viewport = viewport
	host.add_child(follower)
	follower.remote_path = quad.get_path()
	follower.force_update_transform()
	host.visibility_changed.connect(follower._sync_visibility)
	follower._sync_visibility()
	return quad


func _sync_visibility() -> void:
	if is_instance_valid(layer):
		layer.visible = is_inside_tree() and is_visible_in_tree()


func _enter_tree() -> void:
	_sync_visibility()


func _exit_tree() -> void:
	if is_instance_valid(layer):
		layer.visible = false


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and is_instance_valid(layer):
		layer.queue_free()
