// SPIRES's distance estimate for the spatial shaders: the third copy, beside spiresDE in
// bulb.glsl (compute, which meshes it) and BulbSource._de_spires (CPU, which steers by it).
// Keep all three in step; bulb.glsl's says what the shape is. Returns DE in state units.
uniform float de_r2 = 0.5;
uniform float de_thick = 0.05;
uniform float de_spire = 1.0;

float spires_de(vec3 q) {
	vec3 z = q;
	float dr = 1.0;
	for (int i = 0; i < 14; i++) {
		z.xz = abs(fract(z.xz + 0.5) - 0.5);
		if (z.x < z.z) z.xz = z.zx;
		float r2 = max(dot(z, z), 1e-12);
		if (r2 >= de_r2) break;
		float k = de_r2 / r2;
		z *= k;
		dr *= k;
	}
	float h = abs(z.y);
	float spire = length(z.xz - vec2(0.5)) - de_thick * de_spire * h;
	float arch = length(vec2(z.x - 0.5, length(z.yz) - sqrt(max(de_r2 - 0.25, 0.0)))) - de_thick * h;
	return 0.6 * min(spire, arch) / dr;
}

// The colour key bulb.glsl's mesh passes store per vertex, at one point: the smallest
// radius the orbit reached and how many inversions it took. The second jumps a whole
// band at every fold, which is the honeycomb's panelling, and sampled per vertex it
// came out as a staircase along every triangle edge.
float spires_trap(vec3 q) {
	vec3 z = q;
	float trap = 1e9;
	float depth = 0.0;
	for (int i = 0; i < 14; i++) {
		z.xz = abs(fract(z.xz + 0.5) - 0.5);
		if (z.x < z.z) z.xz = z.zx;
		float r2 = max(dot(z, z), 1e-12);
		if (r2 >= de_r2) break;
		z *= de_r2 / r2;
		trap = min(trap, r2);
		depth += 1.0;
	}
	return clamp((sqrt(min(trap, de_r2)) * 0.7 + fract(depth * 0.37) * 0.5) * 0.45, 0.0, 1.0);
}
