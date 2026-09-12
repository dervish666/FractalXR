#[compute]
#version 450

// Distance-estimate fractals as a particle cloud: Mandelbulb, Mandelbox, KIFS,
// quaternion Julia, Sierpinski. Ported from BULB_UPDATE_FRAG in src/engine/shaders.ts.
//
// Same state layout as the flame iterator (xyz = position, w = palette coordinate), so
// this renders, grabs, morphs and framed itself through exactly the same path with no
// changes anywhere else. That was the point of FractalSource.
//
// Each particle Newton-projects onto the DE=0 isosurface (the Green-function distance
// estimate never overshoots), then wanders tangentially so the shell fills and shimmers
// instead of freezing.

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba32f) uniform restrict image2D state_img;
layout(set = 0, binding = 1, std430) restrict readonly buffer Params { float g[]; };
// The surface normal is already computed here for the Newton projection, so handing it
// to the renderer is free. It is what lets a splat lie IN the surface rather than face
// the camera: a disc across a filament blurs it, a disc along it keeps the filigree.
layout(set = 0, binding = 2, rgba32f) uniform restrict writeonly image2D normal_img;

layout(push_constant, std430) uniform PC {
	int tex_size;
	int frame;
	int count;
	int do_seed;
	int update_mod;
	int update_phase;
	float reseed_prob;
	float power;
	vec4 julia_c;      // 16-byte aligned; w unused
	float mandelbulb;  // 1 = c = p, 0 = Julia
	float formula;     // 0 bulb, 1 box, 2 kifs, 3 quat, 4 sierpinski
	float scale;
	float min_r;
	float fixed_r;
	float bound;
	float proj_steps;
	float jitter;
	float k_angle_a;
	float k_angle_b;
	float _pad0;
	float _pad1;
} p;

#define PAL(i, k) g[(i) * 3 + (k)]

uint hash(inout uint s) {
	s = s * 747796405u + 2891336453u;
	uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
	return (w >> 22u) ^ w;
}
float rnd(inout uint s) { return float(hash(s)) * (1.0 / 4294967296.0); }

vec3 randBall(inout uint s, float R) {
	float u = rnd(s) * 2.0 - 1.0;
	float phi = rnd(s) * 6.2831853;
	float r = pow(rnd(s), 0.3333333) * R;
	float st = sqrt(max(0.0, 1.0 - u * u));
	return r * vec3(st * cos(phi), st * sin(phi), u);
}

vec4 mandelbulbDE(vec3 q) {
	vec3 z = q;
	vec3 c = (p.mandelbulb > 0.5) ? q : p.julia_c.xyz;
	float dr = 1.0;
	float r = length(z);
	float trapR = 1e10, trapY = 1e10, esc = 0.0;
	for (int i = 0; i < 8; i++) {
		r = length(z);
		if (r > 2.0) { esc = 1.0; break; }
		float rr = max(r, 1e-9);
		float theta = acos(clamp(z.z / rr, -1.0, 1.0));
		float phi = atan(z.y, z.x);
		dr = pow(rr, p.power - 1.0) * p.power * dr + 1.0;
		float zr = pow(rr, p.power);
		theta *= p.power; phi *= p.power;
		z = zr * vec3(sin(theta) * cos(phi), sin(theta) * sin(phi), cos(theta)) + c;
		trapR = min(trapR, length(z));
		trapY = min(trapY, abs(z.y));
	}
	return vec4(0.5 * log(max(r, 1e-9)) * r / max(dr, 1e-6), trapR, trapY, esc);
}

vec4 mandelboxDE(vec3 q) {
	vec3 offset = (p.mandelbulb > 0.5) ? q : p.julia_c.xyz;
	vec3 z = q;
	float dr = 1.0;
	float trapR = 1e10, trapY = 1e10, esc = 0.0;
	float minR2 = p.min_r * p.min_r;
	float fixedR2 = p.fixed_r * p.fixed_r;
	for (int i = 0; i < 10; i++) {
		z = clamp(z, -1.0, 1.0) * 2.0 - z;                                  // box fold
		float r2 = dot(z, z);
		if (r2 < minR2) { float t = fixedR2 / minR2; z *= t; dr *= t; }     // sphere fold, inner
		else if (r2 < fixedR2) { float t = fixedR2 / r2; z *= t; dr *= t; } // sphere fold, shell
		z = p.scale * z + offset;
		dr = dr * abs(p.scale) + 1.0;
		if (dot(z, z) > 1e4) { esc = 1.0; break; }   // see march.gdshader: 36 is not a bound
		trapR = min(trapR, length(z));
		trapY = min(trapY, abs(z.y));
	}
	return vec4(length(z) / max(abs(dr), 1e-6), trapR, trapY, esc);
}

void kRotX(inout vec3 z, float a) { float s = sin(a), c = cos(a); z.yz = vec2(c * z.y - s * z.z, s * z.y + c * z.z); }
void kRotZ(inout vec3 z, float a) { float s = sin(a), c = cos(a); z.xy = vec2(c * z.x - s * z.y, s * z.x + c * z.y); }

vec4 kifsDE(vec3 q) {
	vec3 z = q;
	vec3 off = p.julia_c.xyz;
	float s = p.scale;
	float dr = 1.0;
	float trapR = 1e10, trapY = 1e10;
	bool tetra = p.formula > 3.5;
	for (int i = 0; i < 12; i++) {
		kRotX(z, p.k_angle_a);
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
		kRotZ(z, p.k_angle_b);
		z = z * s - off * (s - 1.0);
		dr *= s;
		trapR = min(trapR, length(z));
		trapY = min(trapY, abs(z.y));
	}
	return vec4((length(z) - p.fixed_r) / abs(dr), trapR, trapY, 0.0);
}

vec4 quatSqr(vec4 q) { return vec4(q.x * q.x - dot(q.yzw, q.yzw), 2.0 * q.x * q.yzw); }

vec4 quatDE(vec3 pos) {
	vec4 z = vec4(pos, 0.0);
	vec4 c = (p.mandelbulb > 0.5) ? z : vec4(p.julia_c.xyz, 0.0);
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
	}
	return vec4(0.25 * log(m2) * sqrt(m2 / md2), trapR, trapY, esc);
}

vec4 de(vec3 q) {
	if (p.formula > 3.5) return kifsDE(q);   // 4 = Sierpinski (tetra fold)
	if (p.formula > 2.5) return quatDE(q);
	if (p.formula > 1.5) return kifsDE(q);   // 2 = cubic lattice
	return (p.formula > 0.5) ? mandelboxDE(q) : mandelbulbDE(q);
}

vec3 deGrad(vec3 q, float e) {
	vec2 k = vec2(1.0, -1.0);
	return normalize(
		k.xyy * de(q + k.xyy * e).x + k.yyx * de(q + k.yyx * e).x +
		k.yxy * de(q + k.yxy * e).x + k.xxx * de(q + k.xxx * e).x);
}

void main() {
	uint idx = gl_GlobalInvocationID.x;
	if (idx >= uint(p.count)) return;
	ivec2 ip = ivec2(int(idx) % p.tex_size, int(idx) / p.tex_size);
	if (p.do_seed != 0) {
		uint ss = idx * 747796405u + 101u;
		imageStore(state_img, ip, vec4(randBall(ss, p.bound), rnd(ss)));
		imageStore(normal_img, ip, vec4(0.0, 0.0, 1.0, 0.0));
		return;
	}
	if (p.update_mod <= 0) return;
	if (p.update_mod > 1) {
		// Contiguous slabs, not idx % mod. The interleaved version left five of every
		// six lanes idle while the sixth ran the whole loop, so on a SIMD it cost the
		// same as updating everything (measured: 1/6 of the cloud took 3ms against
		// 4.4ms for all of it). The host dispatches one slab's worth of workgroups and
		// this maps them onto the slab for this frame's phase.
		uint slab = (uint(p.count) + uint(p.update_mod) - 1u) / uint(p.update_mod);
		idx = uint(p.update_phase) * slab + idx;
		if (idx >= uint(p.count)) return;
		ip = ivec2(int(idx) % p.tex_size, int(idx) / p.tex_size);
	}
	uint seed = idx * 747796405u + uint(p.frame) * 2654435761u + 1u;

	vec4 s = imageLoad(state_img, ip);
	vec3 pos = s.xyz;
	float col = s.w;

	float bsq = p.bound * p.bound * 4.0;
	float e = 0.0012 * p.bound;

	bool bad = !(pos.x == pos.x) || !(pos.y == pos.y) || !(pos.z == pos.z) || dot(pos, pos) > bsq;
	if (bad || rnd(seed) < p.reseed_prob) pos = randBall(seed, p.bound);

	// For the box, aim a thin shell OUTSIDE the surface: that repels the spurious
	// interior zeros (the core blob) instead of collapsing onto them.
	float shellEps = (abs(p.formula - 1.0) < 0.5) ? 0.012 * p.bound : 0.0;
	vec4 d;
	vec3 n = vec3(0.0, 0.0, 1.0);
	for (int i = 0; i < 6; i++) {
		if (float(i) >= p.proj_steps) break;
		d = de(pos);
		n = deGrad(pos, e);
		pos -= n * (d.x - shellEps);
	}
	// With no projection steps nothing above ran, so evaluate once here. (Doing this
	// unconditionally before the loop cost a full DE per particle that the first
	// iteration then recomputed and overwrote.)
	if (p.proj_steps < 0.5) { d = de(pos); n = deGrad(pos, e); }

	// Wander tangentially so the shell fills and stays alive. Reuses n from the last
	// projection step rather than a fresh 4-tap gradient: the point barely moved on that
	// step, so it is the same normal, saving four DE evaluations per particle.
	vec3 t1 = normalize(cross(n, vec3(0.0, 0.0, 1.0) + vec3(1e-3)));
	vec3 t2 = cross(n, t1);
	pos += (t1 * (rnd(seed) * 2.0 - 1.0) + t2 * (rnd(seed) * 2.0 - 1.0)) * p.jitter * p.bound;

	// Orbit-trap colour, RAW. This used to be squashed through smoothstep(0.15, 0.9, ..)
	// as a hand-tuned stand-in for a CDF, which saturated: nearly every particle came out
	// at 1.0, the cloud rendered cream whatever palette it was given, and repeating the
	// palette could not help because there was no variation left to band. The renderer
	// now measures a real histogram and equalises against it, so the right thing to emit
	// here is the unsquashed value with the range merely bounded.
	col = clamp((d.y * 0.7 + d.z * 0.5) * 0.45, 0.0, 1.0);

	if (abs(p.formula - 1.0) < 0.5 && d.w < 0.5) pos = randBall(seed, p.bound);
	if (dot(pos, pos) > bsq) pos = randBall(seed, p.bound);
	imageStore(state_img, ip, vec4(pos, col));
	imageStore(normal_img, ip, vec4(n, 0.0));
}
