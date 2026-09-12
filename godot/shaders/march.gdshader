shader_type spatial;
render_mode unshaded, cull_front, depth_draw_always, fog_disabled, shadows_disabled, specular_disabled;

// Raymarched bulb surface. The alternative to splatting a distance-estimate shell: every
// pixel sphere-traces the same DE the compute shader projects particles onto, so the
// surface is crisp at any distance, lit from its true normal, and costs nothing when
// not on screen. The price is per-pixel DE evaluations, which is what SURFACE and DETAIL
// are for measuring.
//
// The mesh is a box in the cloud's local space, drawn back-faces-only so it covers the
// silhouette whether the head is inside it or out. Rays are built from the inverse
// MODELVIEW in the vertex stage: that matrix is per eye under multiview, so the two
// eyes get their own origins with nothing left to guess about CAMERA_POSITION_WORLD.
//
// The DE functions are a straight port of bulb.glsl; keep them in step.

uniform float power = 8.0;
uniform vec3 julia_c = vec3(0.0);
uniform float mandelbulb = 1.0;   // 1 = c is the point, 0 = Julia constant
uniform float formula = 0.0;      // 0 bulb, 1 box, 2 kifs, 3 quat, 4 sierpinski
uniform float scale = 2.0;
uniform float min_r = 0.5;
uniform float fixed_r = 1.0;
uniform float bound = 1.3;
uniform float k_angle_a = 0.0;
uniform float k_angle_b = 0.0;

uniform vec3 cloud_center = vec3(0.0);
uniform float cloud_fit = 1.0;

uniform vec3 pal0 = vec3(0.0);
uniform vec3 pal1 = vec3(0.25, 0.0, 0.3);
uniform vec3 pal2 = vec3(0.9, 0.2, 0.4);
uniform vec3 pal3 = vec3(1.0, 0.6, 0.1);
uniform vec3 pal4 = vec3(1.0, 0.95, 0.65);
uniform float palette_cycles = 1.0;
uniform float gain = 1.0;
uniform int max_steps = 64;

varying mat4 v_inv_mv;

// Metres from the eye the box's vertices are pulled in to. ENTER scales the cloud by
// up to 60x, which puts the box's back faces a kilometre out, past the camera's far
// plane, and a clipped back face draws nothing: a black view from inside. Moving a
// vertex along its own eye ray leaves every fragment's ray unchanged (the fragment's
// view-space position is only ever normalised into a direction) and the depth comes
// from the march, not the mesh, so this is exact.
const float VERTEX_REACH = 90.0;

void vertex() {
	v_inv_mv = inverse(MODELVIEW_MATRIX);
	vec3 eye_l = (v_inv_mv * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec3 to_v = VERTEX - eye_l;
	float d = length((MODELVIEW_MATRIX * vec4(to_v, 0.0)).xyz);
	if (d > VERTEX_REACH) { VERTEX = eye_l + to_v * (VERTEX_REACH / d); }
}

// --- distance estimators, ported from bulb.glsl -------------------------------

vec4 mandelbulbDE(vec3 q, float lod) {
	vec3 z = q;
	vec3 c = (mandelbulb > 0.5) ? q : julia_c;
	float dr = 1.0;
	float r = length(z);
	float trapR = 1e10, trapY = 1e10, esc = 0.0;
	for (int i = 0; i < 8; i++) {
		r = length(z);
		if (r > 2.0) { esc = 1.0; break; }
		float rr = max(r, 1e-9);
		float theta = acos(clamp(z.z / rr, -1.0, 1.0));
		float phi = atan(z.y, z.x);
		dr = pow(rr, power - 1.0) * power * dr + 1.0;
		float zr = pow(rr, power);
		theta *= power; phi *= power;
		z = zr * vec3(sin(theta) * cos(phi), sin(theta) * sin(phi), cos(theta)) + c;
		trapR = min(trapR, length(z));
		trapY = min(trapY, abs(z.y));
		if (lod > 0.0 && i >= 3) { float est = 0.5 * log(max(length(z), 1e-9)) * length(z) / max(dr, 1e-6); if (est > 0.0 && est < lod) { r = length(z); break; } }
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
	for (int i = 0; i < 10; i++) {
		z = clamp(z, -1.0, 1.0) * 2.0 - z;
		float r2 = dot(z, z);
		if (r2 < minR2) { float t = fixedR2 / minR2; z *= t; dr *= t; }
		else if (r2 < fixedR2) { float t = fixedR2 / r2; z *= t; dr *= t; }
		z = scale * z + offset;
		dr = dr * abs(scale) + 1.0;
		// Bailout at |z|=100, not 6: length(z)/dr is only a distance bound once z has
		// escaped far, and at 36 it overestimated at 97% of sampled points (the marcher
		// stepped through walls and painted noise). Ten iterations still reach it.
		if (dot(z, z) > 1e4) { esc = 1.0; break; }
		trapR = min(trapR, length(z));
		trapY = min(trapY, abs(z.y));
		// Detail cutoff: once the estimate is under the pixel footprint the remaining
		// folds only add dust finer than the screen can show, and that dust is what
		// speckled the marched surface at every distance. The fewer-iteration set
		// contains the true set, so its estimate is still a valid lower bound.
		if (lod > 0.0 && i >= 3 && dot(z, z) < lod * lod * dr * dr) { break; }
	}
	return vec4(length(z) / max(abs(dr), 1e-6), trapR, trapY, esc);
}

void kRotX(inout vec3 z, float a) { float s = sin(a), c = cos(a); z.yz = vec2(c * z.y - s * z.z, s * z.y + c * z.z); }
void kRotZ(inout vec3 z, float a) { float s = sin(a), c = cos(a); z.xy = vec2(c * z.x - s * z.y, s * z.x + c * z.y); }

vec4 kifsDE(vec3 q, float lod) {
	vec3 z = q;
	vec3 off = julia_c;
	float s = scale;
	float dr = 1.0;
	float trapR = 1e10, trapY = 1e10;
	bool tetra = formula > 3.5;
	for (int i = 0; i < 12; i++) {
		kRotX(z, k_angle_a);
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
		kRotZ(z, k_angle_b);
		z = z * s - off * (s - 1.0);
		dr *= s;
		trapR = min(trapR, length(z));
		trapY = min(trapY, abs(z.y));
		if (lod > 0.0 && i >= 3) { float est = (length(z) - fixed_r) / abs(dr); if (est > 0.0 && est < lod) { break; } }
	}
	return vec4((length(z) - fixed_r) / abs(dr), trapR, trapY, 0.0);
}

vec4 quatSqr(vec4 q) { return vec4(q.x * q.x - dot(q.yzw, q.yzw), 2.0 * q.x * q.yzw); }

vec4 quatDE(vec3 pos, float lod) {
	vec4 z = vec4(pos, 0.0);
	vec4 c = (mandelbulb > 0.5) ? z : vec4(julia_c, 0.0);
	float md2 = 1.0;
	float m2 = dot(z, z);
	float trapR = 1e10, trapY = 1e10, esc = 0.0;
	for (int i = 0; i < 11; i++) {
		md2 *= 4.0 * m2;
		z = quatSqr(z) + c;
		m2 = dot(z, z);
		trapR = min(trapR, length(z.xyz));
		trapY = min(trapY, abs(z.y));
		if (m2 > 256.0) { esc = 1.0; break; }
		if (lod > 0.0 && i >= 3) { float est = 0.25 * log(m2) * sqrt(m2 / md2); if (est > 0.0 && est < lod) { break; } }
	}
	return vec4(0.25 * log(m2) * sqrt(m2 / md2), trapR, trapY, esc);
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

vec3 palette(float u) {
	u = clamp(u, 0.0, 1.0) * 4.0;
	int i = int(min(floor(u), 3.0));
	float f = u - float(i);
	vec3 a = (i == 0) ? pal0 : (i == 1) ? pal1 : (i == 2) ? pal2 : pal3;
	vec3 b = (i == 0) ? pal1 : (i == 1) ? pal2 : (i == 2) ? pal3 : pal4;
	return mix(a, b, f);
}

void fragment() {
	// Ray in the cloud's local space, then into state (DE) space. State space is a
	// uniform scale and offset of local, so directions carry over unchanged.
	vec3 ro_l = (v_inv_mv * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec3 rd = normalize((v_inv_mv * vec4(normalize(VERTEX), 0.0)).xyz);
	vec3 ro = ro_l / cloud_fit + cloud_center;

	// Start at the bounding sphere, or at the eye when the head is inside it.
	float R = bound * 1.15;
	float b = dot(ro, rd);
	float cc = dot(ro, ro) - R * R;
	float h = b * b - cc;
	if (h < 0.0) { discard; }
	h = sqrt(h);
	float t0 = max(0.0, -b - h);
	float t1 = -b + h;
	if (t1 <= 0.0) { discard; }

	// One pixel's angular size, so the stopping distance grows with range: near
	// surfaces get the fine detail, far ones stop early instead of stalling.
	float pix = 2.0 / (VIEWPORT_SIZE.y * PROJECTION_MATRIX[1][1]);

	float t = t0;
	float eps = 1e-4 * bound;
	vec4 r = vec4(0.0);
	int steps = 0;
	bool hit = false;
	// A head inside the solid (the Mandelbox's origin is in the set, and a grab can push
	// you through any wall) would hit at the first sample and paint the whole view one
	// colour. Instead the ray walks out of the solid in fixed strides and then marches
	// normally, so the far wall of whatever cavity lies ahead is what you see.
	bool clear = false;
	float stride = 0.012 * bound;
	for (int i = 0; i < max_steps; i++) {
		vec3 pos = ro + rd * t;
		eps = max(t * pix * 1.0, 1e-5 * bound);
		r = de(pos, eps * 0.5);
		steps = i;
		if (!clear) {
			if (r.x > 2.0 * eps + 1e-4 * bound || i >= 24) { clear = true; }
			else { t += stride; if (t > t1) { break; } continue; }
		}
		if (r.x < eps) { hit = true; break; }
		t += r.x * 0.85;
		if (t > t1) { break; }
	}
	// Out of steps inside the sphere: the ray is in a dense region, so shade it (the
	// crawl term darkens it) rather than punch a hole. Only rays that left the sphere miss.
	if (!hit && t <= t1) { hit = true; }
	if (!hit) { discard; }

	vec3 pos = ro + rd * t;
	// Sample the normal a few pixels wide: at the stopping distance the DE is noise.
	// The normal comes from the same detail level the hit was found at, so shading
	// does not reintroduce the dust the cutoff removed.
	vec3 n = deGrad(pos, eps * 3.0, eps * 0.5);
	vec3 v = -rd;
	float ndv = max(dot(n, v), 0.0);
	vec3 key = normalize(vec3(0.5, 0.85, 0.3));
	float ndk = max(dot(n, key), 0.0);
	// Two cheap occlusion probes along the normal: crevices darken, ridges stay lit.
	float ao1 = clamp(de(pos + n * (0.02 * bound), eps).x / (0.02 * bound), 0.0, 1.0);
	float ao2 = clamp(de(pos + n * (0.08 * bound), eps).x / (0.08 * bound), 0.0, 1.0);
	float ao_raw = 0.35 * ao1 + 0.65 * ao2;
	float ao = mix(0.35, 1.0, ao_raw);
	// Depth complexity as a second occlusion cue: rays that crawled in took many steps.
	float crawl = 1.0 - 0.5 * float(steps) / float(max_steps);

	// Same orbit-trap coordinate the compute path stores per particle, so a palette
	// bands the surface the way it bands the splats.
	// The trap alone is chaotic at pixel scale on a marched surface (the splats hide
	// that by blending hundreds of them), so it is only the seasoning: the coarse
	// occlusion probes carry the ramp, crevices dark and ridges light.
	float trap = clamp((r.y * 0.7 + r.z * 0.5) * 0.45, 0.0, 1.0);
	float col = clamp(0.65 * ao_raw + 0.35 * trap, 0.0, 1.0);
	vec3 albedo = palette(fract(col * palette_cycles));
	float fres = pow(1.0 - ndv, 3.0);
	vec3 c = albedo * (0.16 + 0.6 * ndv + 0.4 * ndk) * ao * crawl
		+ pal4 * fres * 0.3 * ao;
	ALBEDO = c * gain;

	// Depth from the view-space ray: t is in state units, so scale by fit and by the
	// node's own scale (read off the inverse basis; the cloud only ever scales uniformly).
	float mscale = 1.0 / max(length(v_inv_mv[0].xyz), 1e-9);
	vec3 hit_view = normalize(VERTEX) * (t * cloud_fit * mscale);
	vec4 clip = PROJECTION_MATRIX * vec4(hit_view, 1.0);
	DEPTH = clip.z / clip.w;
}
