extends SceneTree

## Builds every tree shape at its default depth and reports the instance counts, plus a
## control at depth 0 that must produce nothing. Headless: the geometry is CPU-side.
##
##   tools/tree_check.sh

func _init() -> void:
	var tree := FractalTree.new()
	root.add_child(tree)
	var min_b := 1 << 30
	var min_l := 1 << 30
	var shapes := 0
	for s in FractalTree.SHAPE_NAMES:
		tree.shape = s
		tree.depth_delta = 0
		tree.seed_value = 7
		var n := tree.build()
		var mm_b: int = tree.get_node("Branches").multimesh.instance_count
		var mm_l: int = tree.get_node("Leaves").multimesh.instance_count
		print("  %-7s depth=%d branches=%d (multimesh %d) leaves=%d (multimesh %d) height=%.1fm" % [
			s, tree.effective_depth(), n, mm_b, tree.leaf_count, mm_l, tree.height_m])
		if n != mm_b or tree.leaf_count != mm_l:
			print("TREECHECK FAIL multimesh counts disagree for %s" % s)
			quit(1)
			return
		min_b = mini(min_b, n)
		min_l = mini(min_l, tree.leaf_count)
		shapes += 1
	# Determinism: the same seed twice gives the same buffer.
	tree.shape = "oak"
	tree.seed_value = 42
	tree.build()
	var a: PackedFloat32Array = tree.get_node("Branches").multimesh.buffer
	tree.build()
	var b: PackedFloat32Array = tree.get_node("Branches").multimesh.buffer
	var same := a == b
	tree.seed_value = 43
	tree.build()
	var c: PackedFloat32Array = tree.get_node("Branches").multimesh.buffer
	var differs := c != a
	print("  determinism: same seed identical=%s, new seed differs=%s" % [str(same), str(differs)])
	tree.depth_delta = -100
	var ctl := tree.build()
	var ok := shapes == 4 and min_b > 0 and min_l > 0 and ctl == 0 and same and differs
	print("TREECHECK %s shapes=%d min_branches=%d min_leaves=%d control=%d" % [
		"PASS" if ok else "FAIL", shapes, min_b, min_l, ctl])
	quit(0 if ok else 1)
