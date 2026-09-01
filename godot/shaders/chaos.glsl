#[compute]
#version 450

// Chaos-game iterator, ported 1:1 from src/engine/shaders.ts UPDATE_FRAG.
// The web version is a fragment shader ping-ponging two RGBA32F render targets.
// Compute lets each invocation read and write its own texel in place, so this
// needs ONE state image instead of two: half the state memory and no swap.

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba32f) uniform restrict image2D state_img;
layout(set = 0, binding = 1, std430) restrict readonly buffer Genome { float g[]; };

layout(push_constant, std430) uniform Params {
	int num_t;
	int iters;
	int tex_size;
	int frame;
	float reseed_prob;
	int count;
	int do_seed;
	// Temporal stability. Each particle iterates only when idx % update_mod ==
	// update_phase, so with update_mod 4 a quarter of the cloud moves per frame and
	// the rest holds position. The chaos game re-randomises every particle it touches,
	// so at 1px each screen pixel is lit by zero or one particle and flips every frame:
	// that is the flicker. Staggering the updates makes the sample set persist without
	// changing what it converges to, and costs proportionally less GPU.
	int update_mod;
	int update_phase;
	int _pad;
} p;

// Genome layout (floats). Mirrors src/flame/encode.ts EncodedFlame.
#define R0(j, k)  g[(j) * 3 + (k)]
#define R1(j, k)  g[24 + (j) * 3 + (k)]
#define R2(j, k)  g[48 + (j) * 3 + (k)]
#define BT(j, k)  g[72 + (j) * 3 + (k)]
#define CDF(j)    g[96 + (j)]
#define COL(j)    g[104 + (j)]
#define VARW(j, v) g[112 + (j) * 12 + (v)]

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

vec3 vSpherical(vec3 q) { float r2 = dot(q, q) + 1e-9; return q / r2; }
vec3 vSwirl(vec3 q) { float r2 = q.x * q.x + q.y * q.y; float s = sin(r2), c = cos(r2); return vec3(q.x * s - q.y * c, q.x * c + q.y * s, q.z); }
vec3 vSinusoidal(vec3 q) { return sin(q); }
vec3 vBubble(vec3 q) { float r2 = dot(q, q); return q * (4.0 / (r2 + 4.0)); }
vec3 vHorseshoe(vec3 q) { float r = length(q.xy) + 1e-9; return vec3((q.x - q.y) * (q.x + q.y) / r, 2.0 * q.x * q.y / r, q.z); }
vec3 vHandkerchief(vec3 q) { float r = length(q.xy); float th = atan(q.y, q.x); return vec3(r * sin(th + r), r * cos(th - r), q.z); }
vec3 vDisc(vec3 q) { float r = length(q.xy); float th = atan(q.y, q.x); float a = th * 0.31830989; float pr = 3.14159265 * r; return vec3(a * sin(pr), a * cos(pr), q.z); }
vec3 vSpiral(vec3 q) { float r = length(q.xy) + 1e-9; float th = atan(q.y, q.x); return vec3((cos(th) + sin(r)) / r, (sin(th) - cos(r)) / r, q.z); }
vec3 vHyperbolic(vec3 q) { float r = length(q.xy) + 1e-9; float th = atan(q.y, q.x); return vec3(sin(th) / r, r * cos(th), q.z); }
vec3 vCylinder(vec3 q) { return vec3(sin(q.x), q.y, q.z); }
vec3 vEyefish(vec3 q) { float r = length(q); return q * (2.0 / (r + 1.0)); }

// ORDER IS LOAD-BEARING. Must match VARIATION_NAMES in src/flame/types.ts.
vec3 applyVars(int j, vec3 q) {
	vec3 v = vec3(0.0);
	float w;
	w = VARW(j, 0);  if (w != 0.0) v += w * q;
	w = VARW(j, 1);  if (w != 0.0) v += w * vSpherical(q);
	w = VARW(j, 2);  if (w != 0.0) v += w * vSwirl(q);
	w = VARW(j, 3);  if (w != 0.0) v += w * vSinusoidal(q);
	w = VARW(j, 4);  if (w != 0.0) v += w * vBubble(q);
	w = VARW(j, 5);  if (w != 0.0) v += w * vHorseshoe(q);
	w = VARW(j, 6);  if (w != 0.0) v += w * vHandkerchief(q);
	w = VARW(j, 7);  if (w != 0.0) v += w * vDisc(q);
	w = VARW(j, 8);  if (w != 0.0) v += w * vSpiral(q);
	w = VARW(j, 9);  if (w != 0.0) v += w * vHyperbolic(q);
	w = VARW(j, 10); if (w != 0.0) v += w * vCylinder(q);
	w = VARW(j, 11); if (w != 0.0) v += w * vEyefish(q);
	return v;
}

void main() {
	uint idx = gl_GlobalInvocationID.x;
	if (idx >= uint(p.count)) return;
	ivec2 ip = ivec2(int(idx) % p.tex_size, int(idx) / p.tex_size);

	// Same seed expression as the web build: texel index folded with the frame number.
	if (p.do_seed != 0) {
		uint ss = idx * 747796405u + 101u;
		imageStore(state_img, ip, vec4(randBall(ss, 0.5), rnd(ss)));
		return;
	}

	// update_mod 0 freezes the cloud completely. That is a diagnostic, not a feature:
	// if the image still shimmers with every particle nailed in place, the flicker is
	// rasterisation aliasing under head motion, not the chaos game resampling.
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

	for (int it = 0; it < p.iters; it++) {
		// self-compare NaN check: mobile isnan() is unreliable
		bool bad = !(pos.x == pos.x) || !(pos.y == pos.y) || !(pos.z == pos.z) || dot(pos, pos) > 36.0;
		if (bad || rnd(seed) < p.reseed_prob) {
			pos = randBall(seed, 0.5);
			col = rnd(seed);
			continue;
		}
		float t = rnd(seed);
		int j = p.num_t - 1;
		for (int k = 0; k < p.num_t; k++) { if (t < CDF(k)) { j = k; break; } }
		vec3 q = vec3(
			R0(j, 0) * pos.x + R0(j, 1) * pos.y + R0(j, 2) * pos.z + BT(j, 0),
			R1(j, 0) * pos.x + R1(j, 1) * pos.y + R1(j, 2) * pos.z + BT(j, 1),
			R2(j, 0) * pos.x + R2(j, 1) * pos.y + R2(j, 2) * pos.z + BT(j, 2));
		pos = applyVars(j, q);
		col = col * 0.4 + COL(j) * 0.6;
	}
	imageStore(state_img, ip, vec4(pos, col));
}
