// FLY's formulas for the spatial shaders (bulb_solid.gdshader), named for the push-constant
// slots bulb.glsl reads them from: fp_scale, fp_min_r, fp_fixed_r. Set by bulb_fly.gd.
uniform float fp_scale = 0.5;
uniform float fp_min_r = 0.05;
uniform float fp_fixed_r = 1.0;
// Which colour key pixel_trap computes: 1 = SPIRES's honeycomb, 2 = the Mandelbox (VAULT).
uniform int trap_family = 1;

// SPIRES's distance estimate: the third copy, beside spiresDE in bulb.glsl (compute, which
// meshes it) and BulbSource._de_spires (CPU, which steers by it). Keep all three in step;
// bulb.glsl's says what the shape is. fp_scale = R2, fp_min_r = edge thickness per unit
// height, fp_fixed_r = spire thickness relative to the arches. Returns DE in state units.
float spires_de(vec3 q) {
	vec3 z = q;
	float dr = 1.0;
	for (int i = 0; i < 14; i++) {
		z.xz = abs(fract(z.xz + 0.5) - 0.5);
		if (z.x < z.z) z.xz = z.zx;
		float r2 = max(dot(z, z), 1e-12);
		if (r2 >= fp_scale) break;
		float k = fp_scale / r2;
		z *= k;
		dr *= k;
	}
	float h = abs(z.y);
	float spire = length(z.xz - vec2(0.5)) - fp_min_r * fp_fixed_r * h;
	float arch = length(vec2(z.x - 0.5, length(z.yz) - sqrt(max(fp_scale - 0.25, 0.0)))) - fp_min_r * h;
	return 0.6 * min(spire, arch) / dr;
}

// The colour key bulb.glsl's mesh passes store per vertex, (trapR * 0.7 + trapY * 0.5) *
// 0.45, here at one point. Both families' keys jump at their folds, which is their
// panelling, and sampled per vertex that came out as a staircase along triangle edges.
float spires_trap(vec3 q) {
	vec3 z = q;
	float trap = 1e9;
	float depth = 0.0;
	for (int i = 0; i < 14; i++) {
		z.xz = abs(fract(z.xz + 0.5) - 0.5);
		if (z.x < z.z) z.xz = z.zx;
		float r2 = max(dot(z, z), 1e-12);
		if (r2 >= fp_scale) break;
		z *= fp_scale / r2;
		trap = min(trap, r2);
		depth += 1.0;
	}
	return clamp((sqrt(min(trap, fp_scale)) * 0.7 + fract(depth * 0.37) * 0.5) * 0.45, 0.0, 1.0);
}

// bulb.glsl's mandelboxDE orbit, Mandelbrot mode (the offset is the point), traps only.
float box_trap(vec3 q) {
	vec3 z = q;
	float trap_r = 1e10, trap_y = 1e10;
	float min_r2 = fp_min_r * fp_min_r;
	float fixed_r2 = fp_fixed_r * fp_fixed_r;
	for (int i = 0; i < 10; i++) {
		z = clamp(z, -1.0, 1.0) * 2.0 - z;
		float r2 = dot(z, z);
		if (r2 < min_r2) z *= fixed_r2 / min_r2;
		else if (r2 < fixed_r2) z *= fixed_r2 / r2;
		z = fp_scale * z + q;
		if (dot(z, z) > 1e4) break;
		trap_r = min(trap_r, length(z));
		trap_y = min(trap_y, abs(z.y));
	}
	return clamp((trap_r * 0.7 + trap_y * 0.5) * 0.45, 0.0, 1.0);
}

float fly_trap(vec3 q) {
	return (trap_family == 2) ? box_trap(q) : spires_trap(q);
}
