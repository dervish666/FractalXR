// The bulb's five distance estimates for spatial shaders: the marcher (march.gdshader) and
// SOLID's per-pixel surface (bulb_solid.gdshader, PIXEL). One of the three copies the DEs live
// in, with shaders/bulb.glsl (compute) and BulbSource.de (CPU); tools/de_check.sh renders this
// one against the CPU port. Keep all three in step.

uniform float power = 8.0;
uniform vec3 julia_c = vec3(0.0);
uniform float mandelbulb = 1.0;   // 1 = c is the point, 0 = Julia constant
uniform float formula = 0.0;      // 0 bulb, 1 box, 2 kifs, 3 quat, 4 sierpinski
uniform float scale = 2.0;
uniform float min_r = 0.5;
uniform float fixed_r = 1.0;
uniform float k_angle_a = 0.0;
uniform float k_angle_b = 0.0;


vec4 mandelbulbDE(vec3 q, float lod) {
	vec3 z = q;
	vec3 c = (mandelbulb > 0.5) ? q : julia_c;
	float dr = 1.0;
	float lz = length(z);
	float r = lz;
	float trapR = 1e10, trapY = 1e10, esc = 0.0;
	bool pow8 = abs(power - 8.0) < 1e-4;
	for (int i = 0; i < 8; i++) {
		r = lz;
		if (r > 2.0) { esc = 1.0; break; }
		float rr = max(r, 1e-9);
		float theta = acos(clamp(z.z / rr, -1.0, 1.0));
		float phi = atan(z.y, z.x);
		float r_pm1;
		float zr;
		if (pow8) {
			float r2 = rr * rr;
			float r4 = r2 * r2;
			r_pm1 = r4 * r2 * rr;
			zr = r4 * r4;
		} else {
			r_pm1 = pow(rr, power - 1.0);
			zr = r_pm1 * rr;
		}
		// dc/dp is 1 only when c is the point; a Julia constant adds nothing to the derivative.
		dr = r_pm1 * power * dr + mandelbulb;
		theta *= power; phi *= power;
		float st = sin(theta);
		z = zr * vec3(st * cos(phi), st * sin(phi), cos(theta)) + c;
		lz = length(z);
		trapR = min(trapR, lz);
		trapY = min(trapY, abs(z.y));
		if (lod > 0.0 && i >= 3) {
			float est = 0.5 * log(max(lz, 1e-9)) * lz / max(dr, 1e-6);
			if (est > 0.0 && est < lod) { r = lz; break; }
		}
	}
	return vec4(0.5 * log(max(r, 1e-9)) * r / max(dr, 1e-6), trapR, trapY, esc);
}

vec4 mandelboxDE(vec3 q, float lod) {
	vec3 offset = (mandelbulb > 0.5) ? q : julia_c;
	vec3 z = q;
	float dr = 1.0;
	float trapR = 1e10, trapY = 1e10, esc = 0.0;
	float minR2 = min_r * min_r;
	float fixedR2 = fixed_r * fixed_r;
	float invMinR2 = fixedR2 / minR2;
	float absScale = abs(scale);
	float lod2 = lod * lod;
	float z2 = dot(z, z);
	for (int i = 0; i < 10; i++) {
		z = clamp(z, -1.0, 1.0) * 2.0 - z;
		float r2 = dot(z, z);
		if (r2 < minR2) { z *= invMinR2; dr *= invMinR2; }
		else if (r2 < fixedR2) { float t = fixedR2 / r2; z *= t; dr *= t; }
		z = scale * z + offset;
		dr = dr * absScale + mandelbulb;   // + dc/dp, 0 for a Julia constant
		z2 = dot(z, z);
		// Bailout at |z|=100, not 6: length(z)/dr is only a distance bound once z has
		// escaped far, and at 36 it overestimated at 97% of sampled points (the marcher
		// stepped through walls and painted noise). Ten iterations still reach it.
		if (z2 > 1e4) { esc = 1.0; break; }
		trapR = min(trapR, sqrt(z2));
		trapY = min(trapY, abs(z.y));
		// Detail cutoff: once the estimate is under the pixel footprint the remaining
		// folds only add dust finer than the screen can show, and that dust is what
		// speckled the marched surface at every distance. The fewer-iteration set
		// contains the true set, so its estimate is still a valid lower bound.
		if (lod > 0.0 && i >= 3 && z2 < lod2 * dr * dr) { break; }
	}
	return vec4(sqrt(z2) / max(abs(dr), 1e-6), trapR, trapY, esc);
}

vec4 kifsDE(vec3 q, float lod) {
	vec3 z = q;
	vec3 off = julia_c * (scale - 1.0);
	float s = scale;
	float dr = 1.0;
	float trapR = 1e10, trapY = 1e10;
	bool tetra = formula > 3.5;
	float sa = sin(k_angle_a), ca = cos(k_angle_a);
	float sb = sin(k_angle_b), cb = cos(k_angle_b);
	float lz = 0.0;
	for (int i = 0; i < 12; i++) {
		z.yz = vec2(ca * z.y - sa * z.z, sa * z.y + ca * z.z);
		if (tetra) {
			if (z.x + z.y < 0.0) z.xy = -z.yx;
			if (z.x + z.z < 0.0) z.xz = -z.zx;
			if (z.y + z.z < 0.0) z.yz = -z.zy;
		} else {
			z = abs(z);
			if (z.x - z.y < 0.0) z.xy = z.yx;
			if (z.x - z.z < 0.0) z.xz = z.zx;
			if (z.y - z.z < 0.0) z.yz = z.zy;
		}
		z.xy = vec2(cb * z.x - sb * z.y, sb * z.x + cb * z.y);
		z = z * s - off;
		dr *= s;
		lz = length(z);
		trapR = min(trapR, lz);
		trapY = min(trapY, abs(z.y));
		if (lod > 0.0 && i >= 3) { float est = (lz - fixed_r) / abs(dr); if (est > 0.0 && est < lod) { break; } }
	}
	return vec4((lz - fixed_r) / abs(dr), trapR, trapY, 0.0);
}

vec4 quatSqr(vec4 q) { return vec4(q.x * q.x - dot(q.yzw, q.yzw), 2.0 * q.x * q.yzw); }

vec4 quatDE(vec3 pos, float lod) {
	vec4 z = vec4(pos, 0.0);
	vec4 c = (mandelbulb > 0.5) ? z : vec4(julia_c, 0.0);
	bool is_m = mandelbulb > 0.5;
	float md2 = 1.0;
	float m2 = dot(z, z);
	float trapR = 1e10, trapY = 1e10, esc = 0.0;
	for (int i = 0; i < 11; i++) {
		// |dz'| <= 2|z||dz| + dc/dp; with a Julia constant this is the old 4 m2 md2.
		if (is_m) {
			float t = 2.0 * sqrt(m2 * md2) + mandelbulb;
			md2 = t * t;
		} else {
			md2 = 4.0 * m2 * md2;
		}
		z = quatSqr(z) + c;
		m2 = dot(z, z);
		trapR = min(trapR, length(z.xyz));
		trapY = min(trapY, abs(z.y));
		if (m2 > 256.0) { esc = 1.0; break; }
		if (lod > 0.0 && i >= 3) { float est = 0.25 * log(m2) * sqrt(m2 / md2); if (est > 0.0 && est < lod) { break; } }
	}
	// At the origin a Julia's md2 is 0 (z = 0 is a critical point) and a Mandelbrot's m2
	// stays 0: inf or 0/0. BulbSource.de reads that as 0, inside the set; match it.
	// Self-compare for NaN, because mobile isnan is unreliable.
	float dist = 0.25 * log(m2) * sqrt(m2 / md2);
	if (dist != dist || abs(dist) > 1e30) dist = 0.0;
	return vec4(dist, trapR, trapY, esc);
}

// lod: detail cutoff in state units, 0 for every iteration.
vec4 de(vec3 q, float lod) {
	if (formula > 3.5) return kifsDE(q, lod);
	if (formula > 2.5) return quatDE(q, lod);
	if (formula > 1.5) return kifsDE(q, lod);
	return (formula > 0.5) ? mandelboxDE(q, lod) : mandelbulbDE(q, lod);
}

vec3 deGrad(vec3 q, float e, float lod) {
	vec2 k = vec2(1.0, -1.0);
	return normalize(
		k.xyy * de(q + k.xyy * e, lod).x + k.yyx * de(q + k.yyx * e, lod).x +
		k.yxy * de(q + k.yxy * e, lod).x + k.xxx * de(q + k.xxx * e, lod).x);
}
