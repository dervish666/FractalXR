extends SceneTree

## Precomputes, for every bulb in data/presets.json, the shape's true radial extent and
## its best enclosed room, into data/rooms.json. The marcher sizes its starting sphere
## from the extent (a sphere that cuts through solid paints a ball of noise) and ENTER
## stands the viewer in the room. Re-run after changing bulbs, like `npm run bake`.
##
## Room = a point with clearance (the DE) whose surroundings are solid in most
## directions: 14 sphere-traced rays, at least 12 must hit within twice the extent.
## Non-box formulas are solid bodies with no interior, so for those the record is the
## roomiest point beside the surface and enclosure is reported as it is.
##
##   tools/rooms.sh

const SCATTER := 2500
const DIRS := 14
const TRACE_STEPS := 40


func trace(src: BulbSource, o: Vector3, d: Vector3, tmax: float) -> bool:
	var t := 0.0
	for i in TRACE_STEPS:
		var de := src.de(o + d * t)
		if de < 0.003:
			return true
		t += de * 0.9
		if t > tmax:
			return false
	return true


## March inward along 160 directions until the DE says surface. The bulb and quat
## DEs are only distance bounds near the surface (from far out they overshoot the
## whole shape), so the stride is capped at 3% of the bound and the start is close.
func extent(src: BulbSource, rng: RandomNumberGenerator, is_box: bool) -> float:
	var rmax := 0.0
	var b := src.bound()
	for n in 160:
		var dir := Vector3(rng.randfn(), rng.randfn(), rng.randfn()).normalized()
		var r := b * (3.0 if is_box else 1.6)
		for k in 600:
			var de := src.de(dir * r)
			if de < 0.004 * b:
				rmax = maxf(rmax, r)
				break
			r -= clampf(de * 0.9, 0.002 * b, 0.03 * b)
			if r <= 0.0:
				break
	return rmax


func _init() -> void:
	var lib := PresetLibrary.new()
	if not lib.load_all():
		print("ROOMS FAIL %s" % lib.load_error)
		quit(1)
		return
	var dirs: Array[Vector3] = []
	for x in [-1, 1]:
		for y in [-1, 1]:
			for z in [-1, 1]:
				dirs.append(Vector3(x, y, z).normalized())
	for a in [Vector3.RIGHT, Vector3.LEFT, Vector3.UP, Vector3.DOWN, Vector3.BACK, Vector3.FORWARD]:
		dirs.append(a)
	var rng := RandomNumberGenerator.new()
	var out := {}
	var t_start := Time.get_ticks_msec()
	for b in lib.bulbs:
		var src := BulbSource.new(b)
		rng.seed = 5
		var is_box := str(b.get("formula", "")) == "mandelbox"
		var ext := extent(src, rng, is_box)
		if ext <= 0.0:
			print("ROOM WARNING %s: extent search found no surface, using the bound" % str(b.get("name")))
			ext = src.bound()
		var best_d := 0.0
		var best_enc := 0.0
		var best_p := Vector3.ZERO
		var enclosed_points := 0
		for n in SCATTER:
			var dir := Vector3(rng.randfn(), rng.randfn(), rng.randfn()).normalized()
			var p := dir * ext * 0.85 * pow(rng.randf(), 1.0 / 3.0)
			var d := src.de(p)
			if d < 0.006 * ext:
				continue
			var enc := 0.0
			if is_box:
				var hits := 0
				for dd in dirs:
					if trace(src, p, dd, ext * 2.2):
						hits += 1
				enc = float(hits) / float(DIRS)
				if enc < 0.85:
					continue
				enclosed_points += 1
			if d > best_d:
				best_d = d
				best_enc = enc
				best_p = p
		# Refine the winner locally so the stored point sits at the room's centre. Kept
		# inside the extent: for a solid body the clearance grows without limit outward.
		var refine_r := best_d * 1.2
		for n in 400:
			var dir := Vector3(rng.randfn(), rng.randfn(), rng.randfn()).normalized()
			var p := best_p + dir * refine_r * pow(rng.randf(), 1.0 / 3.0)
			if p.length() > ext * 0.85:
				continue
			var d := src.de(p)
			if d > best_d:
				best_d = d
				best_p = p
		out[str(b.get("name"))] = {
			"extent": snappedf(ext, 0.001),
			"inside": [snappedf(best_p.x, 0.0001), snappedf(best_p.y, 0.0001), snappedf(best_p.z, 0.0001)],
			"clearance": snappedf(best_d, 0.0001),
			"enclosed": snappedf(best_enc, 0.01),
		}
		print("ROOM %-11s %-10s extent=%.2f (bound %.1f) rooms=%d clearance=%.3f enclosed=%.2f" % [
			str(b.get("name")), str(b.get("formula")), ext, src.bound(), enclosed_points, best_d, best_enc])
	var f := FileAccess.open("res://data/rooms.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(out, "  ") + "\n")
	f.close()
	print("ROOMS PASS bulbs=%d seconds=%.0f -> data/rooms.json" % [out.size(), (Time.get_ticks_msec() - t_start) / 1000.0])
	quit(0)
