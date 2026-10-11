extends SceneTree

## Builds every tree shape at its default depth and reports the instance counts, plus a
## control at depth 0 that must produce nothing. Then builds each species as a forest
## tree at the grove's largest and smallest size and checks the branch cap, the LOD
## ladder and per-seed variety. Headless: the geometry is CPU-side.
##
##   tools/tree_check.sh

const CYL_TRIS := 12   # rings = 0, six sides, no caps
const LEAF_TRIS := 2


func _init() -> void:
	var tree := FractalTree.new()
	root.add_child(tree)
	var min_b := 1 << 30
	var min_l := 1 << 30
	var max_b := 0
	var shapes := 0
	print("  hero (species height, full depth):")
	for s in FractalTree.SHAPE_NAMES:
		tree.shape = s
		tree.depth_delta = 0
		tree.seed_value = 7
		var t0 := Time.get_ticks_usec()
		var n := tree.build()
		var ms := (Time.get_ticks_usec() - t0) / 1000.0
		var mm_b: int = tree.get_node("Branches").multimesh.instance_count
		var mm_l: int = tree.get_node("Leaves").multimesh.instance_count
		print("  %-7s depth=%2d branches=%6d leaves=%6d tris=%7d height=%.1fm build=%.0fms" % [
			s, tree.effective_depth(), n, tree.leaf_count, n * CYL_TRIS + tree.leaf_count * LEAF_TRIS,
			tree.height_m, ms])
		if n != mm_b or tree.leaf_count != mm_l:
			print("TREECHECK FAIL multimesh counts disagree for %s" % s)
			quit(1)
			return
		min_b = mini(min_b, n)
		max_b = maxi(max_b, n)
		min_l = mini(min_l, tree.leaf_count)
		shapes += 1
	var faces: int = tree.get_node("Branches").multimesh.mesh.get_faces().size() / 3
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

	# Forest trees: the grove's inner and rim sizes, as forest.gd builds them.
	print("  forest (inner %.1fm cap %d / rim %.1fm cap %d), LOD 0..3 instance cost:" % [
		Forest.GROVE_H_INNER, Forest.TREE_CAP_MAX, Forest.GROVE_H_OUTER, Forest.TREE_CAP_MIN])
	var forest_ok := true
	var inner_total := 0
	var rim_total := 0
	var worst_ms := 0.0
	for s in FractalTree.SHAPE_NAMES:
		var line := "  %-7s" % s
		for size in [[Forest.GROVE_H_INNER, Forest.TREE_CAP_MAX], [Forest.GROVE_H_OUTER, Forest.TREE_CAP_MIN]]:
			var f := FractalTree.new()
			root.add_child(f)
			f.shape = s
			f.seed_value = 11
			f.variety = 1.0
			f.whole_levels = true
			f.lod_ready = true
			f.target_height = size[0]
			f.branch_cap = size[1]
			var t1 := Time.get_ticks_usec()
			var n := f.build()
			worst_ms = maxf(worst_ms, (Time.get_ticks_usec() - t1) / 1000.0)
			var costs: Array[int] = []
			for k in FractalTree.LOD_MAX + 1:
				costs.append(f.lod_cost(k))
			var ladder := true
			for k in FractalTree.LOD_MAX:
				ladder = ladder and costs[k + 1] <= costs[k]
			forest_ok = forest_ok and n > 0 and n <= size[1] and f.leaf_count > 0 and ladder \
				and absf(f.height_m - size[0]) < 1e-3
			if size[1] == Forest.TREE_CAP_MAX:
				inner_total += costs[0]
			else:
				rim_total += costs[0]
			line += "  %4d br %4d lf lod=%s" % [n, f.leaf_count, str(costs)]
			# Variety: another seed of the same species must differ in shape, not only jitter.
			if size[1] == Forest.TREE_CAP_MAX:
				var g := FractalTree.new()
				root.add_child(g)
				g.shape = s
				g.seed_value = 12
				g.variety = 1.0
				g.whole_levels = true
				g.target_height = size[0]
				g.branch_cap = size[1]
				g.build()
				var ga: PackedFloat32Array = g.get_node("Branches").multimesh.buffer
				var fa: PackedFloat32Array = f.get_node("Branches").multimesh.buffer
				forest_ok = forest_ok and ga != fa
				g.free()
			f.free()
		print(line)
	print("  forest: inner tree avg %d instances, rim tree avg %d, worst build %.1f ms" % [
		inner_total / FractalTree.SHAPE_NAMES.size(), rim_total / FractalTree.SHAPE_NAMES.size(), worst_ms])

	var count_ok := _count_checks()

	var ok := shapes == FractalTree.SHAPE_NAMES.size() and min_b > 0 and min_l > 0 and ctl == 0 \
		and same and differs and faces == CYL_TRIS and forest_ok and count_ok
	print("TREECHECK %s shapes=%d min_branches=%d max_branches=%d min_leaves=%d cyl_tris=%d control=%d forest=%s count=%s" % [
		"PASS" if ok else "FAIL", shapes, min_b, max_b, min_l, faces, ctl, str(forest_ok), str(count_ok)])
	quit(0 if ok else 1)


## COUNT. A shape computed on a worker thread is the shape computed here, byte for byte (the
## forest builds off the main thread and shares one result between trees); and at each step
## with a far batch, every species' far tree keeps its trunk, stays inside the step's caps, and
## costs what the step's budget assumed. The top step's whole library is built on the pool.
func _count_checks() -> bool:
	var ok := true
	var spec := {"shape": "oak", "seed": 1003, "depth_delta": 0, "variety": 1.0,
		"target_height": Forest.AVENUE_H, "branch_cap": Forest.TREE_CAP_MAX, "whole_levels": true,
		"lod_ready": true}
	var here := FractalTree.compute(spec)
	var holder := [null, 0]
	var id := WorkerThreadPool.add_task(FractalTree.compute_into.bind(spec, holder), false, "check")
	WorkerThreadPool.wait_for_task_completion(id)
	var there: Dictionary = holder[0]
	var same: bool = there != null and there["buf"] == here["buf"] and there["lbuf"] == here["lbuf"]
	print("  thread: worker result identical=%s (%d branches, %d leaves, %.1f ms on the worker)" % [
		str(same), here["n_b"], here["n_l"], holder[1] / 1000.0])
	ok = ok and same
	var top: Dictionary = Forest.STEPS[Forest.STEPS.size() - 1]
	var lib: Array = []
	var ids: Array = []
	var t0 := Time.get_ticks_usec()
	for s in FractalTree.SHAPE_NAMES:
		for v in int(top["variants"]):
			var h := [null, 0]
			var rel := clampf(float(FractalTree.SHAPES[s]["height_m"]) / 4.8, 0.7, 1.35)
			var sp := spec.duplicate()
			sp["shape"] = s
			sp["seed"] = Forest.VARIANT_SEED + v
			sp["target_height"] = Forest.AVENUE_H * rel
			ids.append(WorkerThreadPool.add_task(FractalTree.compute_into.bind(sp, h), false, "lib"))
			lib.append([s, h])
	for i in ids:
		WorkerThreadPool.wait_for_task_completion(i)
	var wall := (Time.get_ticks_usec() - t0) / 1000.0
	var worst := 0.0
	var sum := 0.0
	for e in lib:
		worst = maxf(worst, e[1][1] / 1000.0)
		sum += e[1][1] / 1000.0
	print("  library: %d shapes for COUNT %d in %.0f ms wall on the pool (%.1f ms mean, %.1f worst each)" % [
		lib.size(), int(top["n"]), wall, sum / lib.size(), worst])
	for st in Forest.STEPS:
		if int(st["near"]) <= 0:
			continue
		var line := "  far at COUNT %3d (caps %d/%d):" % [int(st["n"]), int(st["far_b"]), int(st["far_l"])]
		var tot := 0
		for e in lib:
			var d: Dictionary = e[1][0]
			var c := FractalTree.far_counts(d, int(st["far_b"]), int(st["far_l"]))
			ok = ok and c.x >= 1 and c.x <= int(st["far_b"]) and c.y >= 1 and c.y <= int(st["far_l"])
			tot += c.x + c.y
		line += " mean %d instances a far tree" % (tot / lib.size())
		print(line)
	return ok
