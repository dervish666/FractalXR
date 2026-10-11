// FLOOR's pattern, the one source of it: tree_floor_bake.gdshader bakes it once and
// tree_floor.gdshader reads the bake. A 2D Kaliset: p = |p| / p.p - c, the orbit's step lengths
// summed into glowing lines. `q` is a point of the unit tile; the floor folds its own coordinate
// into that tile by mirroring (abs(mod(p, 2) - 1)), so the tiles meet with no seam.
float kali_floor(vec2 q, vec2 c, float soft) {
	vec2 p = q;
	float acc = 0.0;
	float prev = 0.0;
	for (int i = 0; i < 8; i++) {
		p = abs(p) / max(dot(p, p), 1e-4) - c;
		float l = length(p);
		acc += exp(-soft * abs(l - prev));
		prev = l;
	}
	return acc / 8.0;
}
