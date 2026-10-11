extends Node3D
class_name FarForest

## The far tier of a big avenue: every avenue tree past the nearest few, drawn by species in
## one pair of MultiMeshes (branches, leaves) instead of two draws of its own. At COUNT 500 that
## is about 450 trees in at most 26 draws, where a draw per tree would be 900.
##
## What a far tree keeps. Its trunk and the whole levels above it that fit `block_b` branches,
## and its first `block_l` leaves (a fair sample: forest trees shuffle their leaves at build),
## drawn larger so the crown keeps the glow of LOD 3's quarter of the leaves. No wind: at
## 25 m and more the sway is a few millimetres of a tree a few pixels across.
##
## How it stays one draw. Each instance is the tree's own branch or leaf, composed into the
## avenue's frame on the CPU once, when the tree is put here. What the shaders took per tree as
## a uniform rides in the instance instead (tree.gdshader's `batch`): the birth on one shared
## clock, so a far tree still grows in the wave; its height, for the colour by height; its
## palette phase and its bark and leaf hue. This node sits at identity under the avenue's root,
## so the walk slides it and a grab carries it without touching a buffer.
##
## Slots. A species keeps a fixed block of instances per tree, so a slot is an index and
## putting or dropping a tree rewrites one block. Freed slots are reused lowest first, and only
## up to the highest slot in use is drawn.

const STRIDE := 20
const LEAF_BOOST_MAX := 2.2
const UPLOADS_PER_FRAME := 3

var block_b := 24
var block_l := 40
## Instances the GPU walks for the far tier (the drawn range of every batch, padding included),
## and the real branches and leaves among them. forest.gd counts the first against its budget.
var drawn := 0
var branches := 0
var leaves := 0
var puts := 0
var put_us_max := 0


class Batch:
	var b: MultiMeshInstance3D
	var l: MultiMeshInstance3D
	var mat_b: ShaderMaterial
	var mat_l: ShaderMaterial
	var buf_b := PackedFloat32Array()
	var buf_l := PackedFloat32Array()
	## Branches per slot: the species' own whole-level prefix (from its first tree, with room
	## for a sibling seed's extra twigs), so a batch is not mostly padding.
	var block_b := 0
	var cap := 0
	var urgent := false   # a visible change, or a resize that cleared the GPU buffer
	var free: Array[int] = []
	var used: Dictionary = {}   # slot -> true
	var dirty := false


var _batches := {}      # species -> Batch
var _slots := {}        # FractalTree -> [species, slot, branches, leaves]
var _palette: Array = []
var _leaves_on := true
var _grown_at := 0.0    # the shared clock past which every far instance is fully out
var _clock_fed_past := true
var _fed_root := Transform3D()
var _root_fed := false
var _aabb := AABB()
var _flush_from := 0


func _init() -> void:
	name = "FarForest"


func configure(b: int, l: int) -> void:
	clear()
	block_b = maxi(1, b)
	block_l = maxi(1, l)


func clear() -> void:
	for sp in _batches:
		var bt: Batch = _batches[sp]
		bt.b.queue_free()
		bt.l.queue_free()
	_batches.clear()
	_slots.clear()
	drawn = 0
	branches = 0
	leaves = 0
	_aabb = AABB()
	_root_fed = false


func has(t: FractalTree) -> bool:
	return _slots.has(t)


func tree_total() -> int:
	return _slots.size()


func batch_count() -> int:
	return _batches.size()


## Draw `t` here from now on, born at `sprout` on the forest's clock. Its transform is read now:
## a tree that moves within the avenue (a walk recycle) is dropped and put again.
func put(t: FractalTree, sprout: float) -> void:
	var t0 := Time.get_ticks_usec()
	if _slots.has(t):
		drop(t)
	var d := t.shape_data
	var bt := _batch(t.shape, d)
	var slot := _alloc(bt)
	var c := FractalTree.far_counts(d, bt.block_b, block_l)
	var xf := t.transform
	var bas := xf.basis
	var s := bas.get_scale().y
	var gs: float = d["grow_s"]
	var phase := t.palette_phase
	# Branches.
	var src: PackedFloat32Array = d["buf"]
	var h := float(d["height_m"]) * s
	var bark_hue: float = d["bark_hue"]
	var dst := bt.buf_b
	var o0 := slot * bt.block_b * STRIDE
	for i in c.x:
		var o := i * STRIDE
		var w := o0 + o
		var cb := bas * Basis(Vector3(src[o], src[o + 4], src[o + 8]),
			Vector3(src[o + 1], src[o + 5], src[o + 9]), Vector3(src[o + 2], src[o + 6], src[o + 10]))
		var p := xf * Vector3(src[o + 3], src[o + 7], src[o + 11])
		dst[w] = cb.x.x; dst[w + 1] = cb.y.x; dst[w + 2] = cb.z.x; dst[w + 3] = p.x
		dst[w + 4] = cb.x.y; dst[w + 5] = cb.y.y; dst[w + 6] = cb.z.y; dst[w + 7] = p.y
		dst[w + 8] = cb.x.z; dst[w + 9] = cb.y.z; dst[w + 10] = cb.z.z; dst[w + 11] = p.z
		dst[w + 12] = src[o + 12]; dst[w + 13] = bark_hue; dst[w + 14] = 0.0; dst[w + 15] = 1.0
		dst[w + 16] = sprout + src[o + 16] * gs; dst[w + 17] = src[o + 17]
		dst[w + 18] = h; dst[w + 19] = phase
	dst = _zeroed(dst, o0 + c.x * STRIDE, (bt.block_b - c.x) * STRIDE)
	bt.buf_b = dst
	# Leaves, larger for the ones left out: the area of LOD 3's quarter of the canopy.
	src = d["lbuf"]
	var n_l: int = d["n_l"]
	var boost := clampf(sqrt(0.25 * float(n_l) / maxf(1.0, float(c.y))), 1.0, LEAF_BOOST_MAX) * s
	var leaf_hue: float = d["leaf_hue"]
	dst = bt.buf_l
	o0 = slot * block_l * STRIDE
	for i in c.y:
		var o := i * STRIDE
		var w := o0 + o
		var sz := src[o] * boost
		var cx := bas.x.normalized() * sz
		var cy := bas.y.normalized() * sz
		var cz := bas.z.normalized() * sz
		var p := xf * Vector3(src[o + 3], src[o + 7], src[o + 11])
		dst[w] = cx.x; dst[w + 1] = cy.x; dst[w + 2] = cz.x; dst[w + 3] = p.x
		dst[w + 4] = cx.y; dst[w + 5] = cy.y; dst[w + 6] = cz.y; dst[w + 7] = p.y
		dst[w + 8] = cx.z; dst[w + 9] = cy.z; dst[w + 10] = cz.z; dst[w + 11] = p.z
		dst[w + 12] = src[o + 12]; dst[w + 13] = 0.0; dst[w + 14] = 0.0; dst[w + 15] = 1.0
		dst[w + 16] = sprout + src[o + 16] * gs; dst[w + 17] = phase
		dst[w + 18] = leaf_hue; dst[w + 19] = src[o + 19]
	dst = _zeroed(dst, o0 + c.y * STRIDE, (block_l - c.y) * STRIDE)
	bt.buf_l = dst
	bt.dirty = true
	# Already showing (a tree crossing from near): it must not blink out while it waits.
	bt.urgent = bt.urgent or t.grow_t > 0.0
	_slots[t] = [t.shape, slot, c.x, c.y]
	branches += c.x
	leaves += c.y
	_grown_at = maxf(_grown_at, sprout + gs + 2.0)
	_clock_fed_past = false
	var reach := maxf(h, 1.0) * 1.5
	var box := AABB(xf.origin - Vector3(reach, 0.5, reach), Vector3(reach * 2.0, h + 1.0, reach * 2.0))
	_aabb = box if _aabb.size == Vector3.ZERO else _aabb.merge(box)
	puts += 1
	put_us_max = maxi(put_us_max, Time.get_ticks_usec() - t0)


func drop(t: FractalTree) -> void:
	var e: Variant = _slots.get(t)
	if e == null:
		return
	var bt: Batch = _batches[e[0]]
	var slot: int = e[1]
	bt.buf_b = _zeroed(bt.buf_b, slot * bt.block_b * STRIDE, bt.block_b * STRIDE)
	bt.buf_l = _zeroed(bt.buf_l, slot * block_l * STRIDE, block_l * STRIDE)
	bt.used.erase(slot)
	bt.free.append(slot)
	bt.free.sort()
	bt.free.reverse()      # pop_back hands out the lowest
	bt.dirty = true
	bt.urgent = true       # its own nodes are already drawing it: no doubled frames
	branches -= int(e[2])
	leaves -= int(e[3])
	_slots.erase(t)


## Once a frame, after the puts and drops: upload what changed, draw up to the highest slot in
## use, and feed the shared clock while anything is still growing. A batch is uploaded whole,
## so at most UPLOADS_PER_FRAME of them go up in one frame (a sowing touches every species at
## once, all with trees not yet born); the rest wait a frame. A change you could see goes up at
## once whatever the count.
func flush(clock: float) -> void:
	var count := 0
	var uploads := 0
	var all: Array = _batches.values()
	_flush_from += 1
	for k in all.size():
		var bt: Batch = all[(_flush_from + k) % all.size()]
		if bt.dirty and (uploads < UPLOADS_PER_FRAME or bt.urgent):
			uploads += 1
			bt.dirty = false
			bt.urgent = false
			bt.b.multimesh.buffer = bt.buf_b
			bt.l.multimesh.buffer = bt.buf_l
			var hi := 0
			for slot in bt.used:
				hi = maxi(hi, int(slot) + 1)
			bt.b.multimesh.visible_instance_count = hi * bt.block_b
			bt.l.multimesh.visible_instance_count = hi * block_l
			bt.b.custom_aabb = _aabb
			bt.l.custom_aabb = _aabb
		count += bt.b.multimesh.visible_instance_count \
			+ (bt.l.multimesh.visible_instance_count if _leaves_on else 0)
	drawn = count
	if not _clock_fed_past:
		_clock_fed_past = clock > _grown_at
		for sp in _batches:
			var bt: Batch = _batches[sp]
			bt.mat_b.set_shader_parameter(&"grow_t", clock)
			bt.mat_l.set_shader_parameter(&"grow_t", clock)
	# Colour by height measures from the avenue's floor; the walk slides it every frame.
	var rxf := global_transform
	if not _root_fed or rxf != _fed_root:
		_root_fed = true
		_fed_root = rxf
		for sp in _batches:
			_feed_root(_batches[sp])


func set_palette(pal: Array) -> void:
	_palette = pal
	for sp in _batches:
		_feed_palette(_batches[sp])


func set_leaves(on: bool) -> void:
	_leaves_on = on
	for sp in _batches:
		(_batches[sp] as Batch).l.visible = on


func _batch(species: String, d: Dictionary) -> Batch:
	if _batches.has(species):
		return _batches[species]
	var bt := Batch.new()
	bt.block_b = mini(block_b, ceili(FractalTree.far_counts(d, block_b, block_l).x * 1.3) + 2)
	var meshes := FractalTree.unit_meshes()
	var p := FractalTree.params_for(species, 1, 0.0)
	bt.mat_b = ShaderMaterial.new()
	bt.mat_b.shader = load("res://shaders/tree.gdshader")
	bt.mat_l = ShaderMaterial.new()
	bt.mat_l.shader = load("res://shaders/tree_leaf.gdshader")
	for m in [bt.mat_b, bt.mat_l]:
		m.set_shader_parameter(&"batch", true)
		m.set_shader_parameter(&"grow_s", 1.0)
		m.set_shader_parameter(&"wind", 0.0)
		m.set_shader_parameter(&"sway_gain", 0.0)
		m.set_shader_parameter(&"grow_t", 0.0)
	bt.mat_b.set_shader_parameter(&"bark_tint", Vector3(p["bark_tint"].r, p["bark_tint"].g, p["bark_tint"].b))
	bt.mat_b.set_shader_parameter(&"bark_mix", float(p["bark_mix"]))
	bt.mat_l.set_shader_parameter(&"leaf_tint", Vector3(p["leaf_tint"].r, p["leaf_tint"].g, p["leaf_tint"].b))
	for key in ["leaf_mix", "leaf_shape", "leaf_gain"]:
		bt.mat_l.set_shader_parameter(key, float(p[key]))
	bt.b = _instance("Far " + species, meshes[0], bt.mat_b)
	bt.l = _instance("Far leaves " + species, meshes[1], bt.mat_l)
	bt.l.visible = _leaves_on
	_feed_palette(bt)
	_feed_root(bt)
	_clock_fed_past = false
	_batches[species] = bt
	return bt


func _instance(n: String, mesh: Mesh, mat: ShaderMaterial) -> MultiMeshInstance3D:
	var mi := MultiMeshInstance3D.new()
	mi.name = n
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = mesh
	mi.multimesh = mm
	add_child(mi)
	return mi


## A free slot, growing the batch by half again (at least 8 trees) when there is none.
func _alloc(bt: Batch) -> int:
	if bt.free.is_empty():
		var grow := maxi(8, bt.cap / 2)
		var tail := PackedFloat32Array()
		tail.resize(grow * bt.block_b * STRIDE)
		tail.fill(0.0)
		var nb := bt.buf_b
		nb.append_array(tail)
		bt.buf_b = nb
		tail.resize(grow * block_l * STRIDE)
		tail.fill(0.0)
		var nl := bt.buf_l
		nl.append_array(tail)
		bt.buf_l = nl
		for i in range(bt.cap + grow - 1, bt.cap - 1, -1):
			bt.free.append(i)
		bt.cap += grow
		bt.b.multimesh.instance_count = bt.cap * bt.block_b
		bt.l.multimesh.instance_count = bt.cap * block_l
		bt.dirty = true
		bt.urgent = true
	var slot: int = bt.free.pop_back()
	bt.used[slot] = true
	return slot


## Returns the array it wrote, so the caller holds the written one whether packed arrays reach
## a function shared or copied.
static func _zeroed(buf: PackedFloat32Array, from: int, n: int) -> PackedFloat32Array:
	for i in range(from, from + n):
		buf[i] = 0.0
	return buf


func _feed_palette(bt: Batch) -> void:
	for i in mini(5, _palette.size()):
		var key := "pal%d" % i
		bt.mat_b.set_shader_parameter(key, _palette[i])
		bt.mat_l.set_shader_parameter(key, _palette[i])


func _feed_root(bt: Batch) -> void:
	var rxf := global_transform if is_inside_tree() else Transform3D()
	for m in [bt.mat_b, bt.mat_l]:
		m.set_shader_parameter(&"tree_origin", rxf.origin)
		m.set_shader_parameter(&"tree_up", rxf.basis.y.normalized())
		m.set_shader_parameter(&"tree_scale", rxf.basis.get_scale().y)
