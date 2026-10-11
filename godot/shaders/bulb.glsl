#[versions]

particles = "";
mesh_field = "#define MESH_FIELD";
mesh_verts = "#define MESH_VERTS";
mesh_quads = "#define MESH_QUADS";
mesh_light = "#define MESH_LIGHT";

#[compute]
#version 450

// The #[versions] defines land here. `particles` is the cloud below; the four mesh_*
// variants are SOLID's mesh build (BulbSolid, scripts/sources/bulb_solid.gd). They live in
// this file so the five distance estimates exist once for compute, not twice.
VERSION_DEFINES

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

#if defined(MESH_FIELD) || defined(MESH_VERTS) || defined(MESH_QUADS) || defined(MESH_LIGHT)
#define MESH
#endif

#ifndef MESH
layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba32f) uniform restrict image2D state_img;
layout(set = 0, binding = 1, std430) restrict readonly buffer Params { float g[]; };
// The surface normal is already computed here for the Newton projection, so handing it
// to the renderer is free. It is what lets a splat lie IN the surface rather than face
// the camera: a disc across a filament blurs it, a disc along it keeps the filigree.
// w is a hide flag, used only by LINES: 1 means "not on a ring (yet)", and splat.gdshader
// culls it. Splats write 0 everywhere, so their look is unchanged.
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
	// LINES: x = spacing between slice planes in state units (0 = off, plain splats),
	// y = how many planes span the shape, z = the axis they are stacked along (0, 1, 2),
	// w = the level the rings are cut at, DE = w (state units; see shellEps below).
	vec4 slice;
} p;
#else
// --- SOLID mesh build: bindings and push constant ------------------------------------
//
// Surface nets over a grid of DE samples, then per-vertex light, all written straight in
// the byte layout Godot's mesh storage wants so the host uploads the readback untouched.
// The field and the cell map are scratch; verts, attrs and indices become the mesh.
//
//   field     (N+1)^3 corners, one byte each, packed four to a uint along x:
//             (DE - iso) / h quantised at 48 steps a voxel, 128 = on the surface
//   cellmap   N^3 cells, vertex index + 1, 0 for a cell the surface does not cross
//   verts     3 floats a vertex, ARRAY_VERTEX
//   attrs     3 uints a vertex: CUSTOM0 as RGBA half (normal xyz, orbit trap) and
//             CUSTOM1 as RGBA8 unorm (AO, key-light shadow, unused, 1)
//   indices   3 uints a triangle
//   counters  [0] vertices, [1] triangles, [2..65] a 64-bin histogram of the trap
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

#if defined(MESH_FIELD) || defined(MESH_VERTS) || defined(MESH_QUADS)
layout(set = 0, binding = 0, std430) restrict buffer Field { uint field[]; };
#endif
#if defined(MESH_VERTS) || defined(MESH_QUADS)
layout(set = 0, binding = 1, std430) restrict buffer CellMap { uint cellmap[]; };
#endif
#if defined(MESH_VERTS) || defined(MESH_QUADS) || defined(MESH_LIGHT)
layout(set = 0, binding = 2, std430) restrict buffer Verts { float verts[]; };
#endif
#if defined(MESH_VERTS) || defined(MESH_LIGHT)
layout(set = 0, binding = 3, std430) restrict buffer Attrs { uint attrs[]; };
#endif
#if defined(MESH_QUADS)
layout(set = 0, binding = 4, std430) restrict buffer Indices { uint indices[]; };
#endif
#if defined(MESH_VERTS) || defined(MESH_QUADS) || defined(MESH_LIGHT)
layout(set = 0, binding = 5, std430) restrict buffer Counters { uint counters[]; };
#endif

// The DE functions below read p.power, p.julia_c and the rest by name, so the formula
// fields keep the particle block's names; only their offsets differ.
layout(push_constant, std430) uniform PC {
	int grid;          // cells per axis, N
	int first;         // first layer (field, verts, quads) or first vertex (light)
	int count;         // layers or vertices in this dispatch
	int cap;           // vertex capacity (verts, light) or triangle capacity (quads)
	vec4 origin;       // xyz = the grid's minimum corner, w = h, the voxel size
	float iso;         // the extracted level set, DE = iso, in state units
	float power;
	float mandelbulb;
	float formula;
	vec4 julia_c;
	float scale;
	float min_r;
	float fixed_r;
	float k_angle_a;
	float k_angle_b;
	float inside_mode; // 0 = DE level set alone, 1 = a point that never escaped is solid
	float ao_radius;   // state units
	float shadow_k;    // penumbra sharpness, Quilez's k
	vec4 light;        // xyz = key light direction in state space, w = shadow reach
} p;
#endif

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
		// dc/dp is 1 only when c is the point; a Julia constant adds nothing to the derivative.
		dr = pow(rr, p.power - 1.0) * p.power * dr + p.mandelbulb;
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
		dr = dr * abs(p.scale) + p.mandelbulb;   // + dc/dp, 0 for a Julia constant
		// The distance needs the far bailout (see march.gdshader: 36 is not a bound), but
		// the escape flag feeds the interior reseed below and must keep the old threshold:
		// flagged at 1e4, shell points rarely escaped in ten folds and 74-90% of the cloud
		// was reseeded to ball noise every update.
		if (dot(z, z) > 36.0) esc = 1.0;
		if (dot(z, z) > 1e4) break;
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
		// |dz'| <= 2|z||dz| + dc/dp. The +1 matters when c is the point; with a Julia constant
		// this is the old 4 m2 md2 exactly.
		md2 = pow(2.0 * sqrt(m2 * md2) + p.mandelbulb, 2.0);
		z = quatSqr(z) + c;
		m2 = dot(z, z);
		trapR = min(trapR, length(z.xyz));
		trapY = min(trapY, abs(z.y));
		if (m2 > 256.0) { esc = 1.0; break; }
	}
	// At the origin a Julia's md2 is 0 (z = 0 is a critical point) and a Mandelbrot's m2
	// stays 0: inf or 0/0. BulbSource.de reads that as 0, inside the set; match it.
	// Self-compare for NaN, because mobile isnan is unreliable.
	float dist = 0.25 * log(m2) * sqrt(m2 / md2);
	if (dist != dist || abs(dist) > 1e30) dist = 0.0;
	return vec4(dist, trapR, trapY, esc);
}

vec4 de(vec3 q) {
	if (p.formula > 3.5) return kifsDE(q);   // 4 = Sierpinski (tetra fold)
	if (p.formula > 2.5) return quatDE(q);
	if (p.formula > 1.5) return kifsDE(q);   // 2 = cubic lattice
	return (p.formula > 0.5) ? mandelboxDE(q) : mandelbulbDE(q);
}

// The four tetrahedral taps give the gradient AND, averaged, the estimate at q itself
// (the offsets sum to zero, so the mean is de(q) + O(e^2)). A projection step used to call
// de(q) separately on top of the four taps: five evaluations where four do.
vec3 deGradMean(vec3 q, float e, out vec4 mean) {
	vec2 k = vec2(1.0, -1.0);
	vec4 a = de(q + k.xyy * e);
	vec4 b = de(q + k.yyx * e);
	vec4 c = de(q + k.yxy * e);
	vec4 d = de(q + k.xxx * e);
	mean = 0.25 * (a + b + c + d);
	return normalize(k.xyy * a.x + k.yyx * b.x + k.yxy * c.x + k.xxx * d.x);
}

vec3 deGrad(vec3 q, float e) {
	vec2 k = vec2(1.0, -1.0);
	return normalize(
		k.xyy * de(q + k.xyy * e).x + k.yyx * de(q + k.yyx * e).x +
		k.yxy * de(q + k.yxy * e).x + k.xxx * de(q + k.xxx * e).x);
}

#ifndef MESH
void main() {
	uint idx = gl_GlobalInvocationID.x;
	if (idx >= uint(p.count)) return;
	ivec2 ip = ivec2(int(idx) % p.tex_size, int(idx) / p.tex_size);
	if (p.do_seed != 0) {
		uint ss = idx * 747796405u + 101u;
		imageStore(state_img, ip, vec4(randBall(ss, p.bound), rnd(ss)));
		// A seed is not on a ring, so LINES hides it until it lands on one: the rings
		// draw themselves in instead of a ball of noise collapsing.
		imageStore(normal_img, ip, vec4(0.0, 0.0, 1.0, p.slice.x > 0.0 ? 1.0 : 0.0));
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
		// The dispatch rounds up to whole workgroups; lanes past the slab belong to the
		// next phase's particles and would update them twice.
		if (idx >= slab) return;
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
	// LINES churns a quarter as hard. A reseed lands wherever its in-plane Newton basin
	// sends it, which clumps on the inside of every crinkle; fewer of them, and the walk
	// along the ring below has time to spread the clumps out evenly.
	float reseed = (p.slice.x > 0.0) ? 0.25 * p.reseed_prob : p.reseed_prob;
	if (bad || rnd(seed) < reseed) pos = randBall(seed, p.bound);

	// For the box, aim a thin shell OUTSIDE the surface: that repels the spurious
	// interior zeros (the core blob) instead of collapsing onto them.
	float shellEps = (abs(p.formula - 1.0) < 0.5) ? 0.012 * p.bound : 0.0;

	// LINES: slice rings by constrained projection. Snap onto the nearest of a stack of
	// parallel planes, then Newton-project WITHIN that plane: the step is the gradient
	// with its axis component removed, so the particle never leaves the plane and settles
	// where the isosurface crosses it. Same number of DE evaluations as the shell.
	bool slicing = p.slice.x > 0.0;
	int ax = int(p.slice.z + 0.5);
	// Cut the rings from a slightly inflated bulb, DE = w rather than DE = 0. Contours of
	// the true surface trace every crinkle smaller than the ring spacing, which no stack of
	// rings can show and which reads as worms from any angle but side-on; the offset
	// surface rounds those off and keeps the form.
	if (slicing) shellEps = max(shellEps, p.slice.w);
	float plane = 0.0;
	if (slicing) {
		plane = (floor(pos[ax] / p.slice.x) + 0.5) * p.slice.x;
		pos[ax] = plane;
	}
	float resid = 0.0;   // in-plane distance to the ring at the last evaluation
	vec4 d;
	vec3 n = vec3(0.0, 0.0, 1.0);
	for (int i = 0; i < 6; i++) {
		if (float(i) >= p.proj_steps) break;
		n = deGradMean(pos, e, d);
		float f = d.x - shellEps;
		if (slicing) {
			vec3 nt = n;
			nt[ax] = 0.0;
			float l2 = dot(nt, nt);
			// Where the plane is nearly tangent to the surface (the top of a lobe) the
			// in-plane gradient vanishes and a full Newton step would fling the point.
			// The floor turns it into a damped step there; those points rarely converge
			// and are hidden below rather than drawn as a blob.
			pos -= nt * (f / max(l2, 0.25));
			resid = abs(f) / sqrt(max(l2, 1e-4));
		} else {
			pos -= n * f;
		}
	}
	// With no projection steps nothing above ran, so evaluate once here. (Doing this
	// unconditionally before the loop cost a full DE per particle that the first
	// iteration then recomputed and overwrote.)
	if (p.proj_steps < 0.5) { d = de(pos); n = deGrad(pos, e); resid = abs(d.x - shellEps); }

	if (slicing) {
		// Wander ALONG the ring only, so the jitter that fills the shell fills the curve
		// instead of smearing it into a band. Three times the shell's step: a random walk
		// on a closed curve evens out, and even spacing is what makes a line read as a
		// line. None in the reseed-free tail before a freeze (reseed_prob 0), so frozen
		// points sit exactly on the ring rather than one stray tangent step off it.
		vec3 axv = vec3(0.0);
		axv[ax] = 1.0;
		vec3 tr = cross(n, axv);
		float tl = length(tr);
		float walk = (p.reseed_prob > 0.0) ? 3.0 * p.jitter * p.bound : 0.0;
		if (tl > 1e-3) pos += (tr / tl) * ((rnd(seed) * 2.0 - 1.0) * walk);
	} else {
		// Wander tangentially so the shell fills and stays alive. Reuses n from the last
		// projection step rather than a fresh 4-tap gradient: the point barely moved on that
		// step, so it is the same normal, saving four DE evaluations per particle.
		vec3 t1 = normalize(cross(n, vec3(0.0, 0.0, 1.0) + vec3(1e-3)));
		vec3 t2 = cross(n, t1);
		pos += (t1 * (rnd(seed) * 2.0 - 1.0) + t2 * (rnd(seed) * 2.0 - 1.0)) * p.jitter * p.bound;
	}

	// Orbit-trap colour, RAW. This used to be squashed through smoothstep(0.15, 0.9, ..)
	// as a hand-tuned stand-in for a CDF, which saturated: nearly every particle came out
	// at 1.0, the cloud rendered cream whatever palette it was given, and repeating the
	// palette could not help because there was no variation left to band. The renderer
	// now measures a real histogram and equalises against it, so the right thing to emit
	// here is the unsquashed value with the range merely bounded.
	col = clamp((d.y * 0.7 + d.z * 0.5) * 0.45, 0.0, 1.0);

	bool hide = false;
	if (slicing) {
		// Colour by height: every ring one colour, bottom to top through the palette, with
		// a little of the trap so neighbouring rings are not flat bands. The trap alone
		// changes colour point to point along a ring, which reads as dotted. Mapped into
		// [0.125, 0.875] because the splat shader stretches the coordinate by 4/3.
		float ht = clamp(0.5 + plane / (p.slice.x * p.slice.y), 0.0, 1.0);
		col = 0.125 + 0.75 * mix(ht, col, 0.2);
		// Not on a ring yet: the plane misses the shape, the point is still travelling,
		// or it is stuck where the plane grazes the surface. Hide it, and while the host
		// allows reseeding send it somewhere else to try again.
		hide = resid > 0.06 * p.slice.x;
		if (hide && rnd(seed) < 25.0 * p.reseed_prob) pos = randBall(seed, p.bound);
	}

	// A Mandelbox point that did not escape sits on a spurious interior zero. It is stored
	// as a raw seed and projected from there next frame, like any reseed; the host's
	// reseed-free tail (main.gd _sync_iteration) is what keeps these out of a freeze.
	if (abs(p.formula - 1.0) < 0.5 && d.w < 0.5) { pos = randBall(seed, p.bound); hide = true; }
	if (dot(pos, pos) > bsq) { pos = randBall(seed, p.bound); hide = true; }
	imageStore(state_img, ip, vec4(pos, col));
	imageStore(normal_img, ip, vec4(n, (slicing && hide) ? 1.0 : 0.0));
}
#else
// --- SOLID mesh build: the four passes -----------------------------------------------

// The distance the mesh is extracted from. KIFS and Sierpinski DEs are signed, so they go
// through as they are. The escape-time families are loose inside (a point that never
// escaped can read a large distance), so with inside_mode on, a point that never escaped
// counts as solid whatever its DE says: the escape test, not the sign.
float deSolid(vec3 q, out vec4 r) {
	r = de(q);
	bool signed_de = (p.formula > 1.5 && p.formula < 2.5) || p.formula > 3.5;
	if (signed_de || p.inside_mode < 0.5) return r.x;
	return (r.w > 0.5) ? r.x : 0.0;
}

float deSolid(vec3 q) { vec4 r; return deSolid(q, r); }

#if defined(MESH_VERTS) || defined(MESH_QUADS) || defined(MESH_FIELD)
int C() { return p.grid + 1; }
int XW() { return (p.grid + 4) / 4; }   // ceil((N + 1) / 4) uints per row of corners

uint fieldByte(int i, int j, int k) {
	uint w = field[(k * C() + j) * XW() + (i >> 2)];
	return (w >> (8u * uint(i & 3))) & 255u;
}
// In voxels: negative is solid.
float fieldAt(int i, int j, int k) { return (float(fieldByte(i, j, k)) - 128.0) / 48.0; }
#endif

#ifdef MESH_FIELD
void main() {
	int row = XW();
	int plane = row * C();
	int idx = int(gl_GlobalInvocationID.x);
	if (idx >= p.count * plane) return;
	int k = p.first + idx / plane;
	int rem = idx % plane;
	int j = rem / row;
	int i0 = (rem % row) * 4;
	float h = p.origin.w;
	uint w = 0u;
	for (int b = 0; b < 4; b++) {
		int i = i0 + b;
		uint q = 255u;
		if (i < C()) {
			vec3 pos = p.origin.xyz + vec3(float(i), float(j), float(k)) * h;
			float f = (deSolid(pos) - p.iso) / h;
			q = uint(clamp(floor(f * 48.0 + 0.5) + 128.0, 0.0, 255.0));
		}
		w |= q << (8u * uint(b));
	}
	field[k * plane + rem] = w;
}
#endif

#ifdef MESH_VERTS
// Gradient of deSolid and, averaged over the four taps, the trap at the vertex: the
// same trick as deGradMean, so the colour is a small neighbourhood's, not one point's.
vec3 solidGrad(vec3 q, float e, out vec4 mean) {
	vec2 k = vec2(1.0, -1.0);
	vec4 ra, rb, rc, rd;
	float a = deSolid(q + k.xyy * e, ra);
	float b = deSolid(q + k.yyx * e, rb);
	float c = deSolid(q + k.yxy * e, rc);
	float d = deSolid(q + k.xxx * e, rd);
	mean = 0.25 * (ra + rb + rc + rd);
	return k.xyy * a + k.yyx * b + k.yxy * c + k.xxx * d;
}

void main() {
	int N = p.grid;
	int idx = int(gl_GlobalInvocationID.x);
	if (idx >= p.count * N * N) return;
	int k = p.first + idx / (N * N);
	int rem = idx % (N * N);
	int j = rem / N;
	int i = rem % N;
	uint cell = uint((k * N + j) * N + i);

	float f[8];
	uint mask = 0u;
	for (int c = 0; c < 8; c++) {
		f[c] = fieldAt(i + (c & 1), j + ((c >> 1) & 1), k + ((c >> 2) & 1));
		if (f[c] < 0.0) mask |= 1u << uint(c);
	}
	if (mask == 0u || mask == 255u) { cellmap[cell] = 0u; return; }

	// Surface nets: the vertex is the mean of the crossings on the cell's twelve edges.
	const ivec2 EDGES[12] = ivec2[12](
		ivec2(0, 1), ivec2(2, 3), ivec2(4, 5), ivec2(6, 7),
		ivec2(0, 2), ivec2(1, 3), ivec2(4, 6), ivec2(5, 7),
		ivec2(0, 4), ivec2(1, 5), ivec2(2, 6), ivec2(3, 7));
	vec3 sum = vec3(0.0);
	float n_cross = 0.0;
	for (int e = 0; e < 12; e++) {
		int a = EDGES[e].x, b = EDGES[e].y;
		if (((mask >> uint(a)) & 1u) == ((mask >> uint(b)) & 1u)) continue;
		float t = clamp(f[a] / (f[a] - f[b]), 0.0, 1.0);
		vec3 pa = vec3(float(a & 1), float((a >> 1) & 1), float((a >> 2) & 1));
		vec3 pb = vec3(float(b & 1), float((b >> 1) & 1), float((b >> 2) & 1));
		sum += mix(pa, pb, t);
		n_cross += 1.0;
	}
	vec3 v = sum / n_cross;
	// The field's own gradient, outward. Coarse but never noise, which the DE's can be.
	vec3 g = vec3(
		(f[1] - f[0]) + (f[3] - f[2]) + (f[5] - f[4]) + (f[7] - f[6]),
		(f[2] - f[0]) + (f[3] - f[1]) + (f[6] - f[4]) + (f[7] - f[5]),
		(f[4] - f[0]) + (f[5] - f[1]) + (f[6] - f[2]) + (f[7] - f[3]));
	vec3 nf = dot(g, g) > 1e-12 ? normalize(g) : vec3(0.0, 0.0, 1.0);

	float h = p.origin.w;
	vec3 lo = p.origin.xyz + vec3(float(i), float(j), float(k)) * h;
	vec3 pos = lo + v * h;
	// Newton snap onto DE = iso along the field normal, held inside the cell so the mesh
	// cannot fold over itself. The grid only knew the surface to a voxel.
	for (int s = 0; s < 3; s++) {
		float d = deSolid(pos) - p.iso;
		pos -= nf * clamp(d, -0.5 * h, 0.5 * h);
		pos = clamp(pos, lo, lo + vec3(h));
	}
	vec4 mean;
	vec3 gd = solidGrad(pos, 0.5 * h, mean);
	// The DE's normal carries detail finer than the cell. Where it is degenerate (every tap
	// solid) or points into the shape it is noise, and the field's normal stands in.
	vec3 n = nf;
	if (dot(gd, gd) > 1e-20) {
		vec3 nd = normalize(gd);
		if (dot(nd, nf) > 0.0) n = normalize(nd + 0.35 * nf);
	}
	float col = clamp((mean.y * 0.7 + mean.z * 0.5) * 0.45, 0.0, 1.0);

	uint vi = atomicAdd(counters[0], 1u);
	if (vi >= uint(p.cap)) { cellmap[cell] = 0u; return; }
	cellmap[cell] = vi + 1u;
	verts[vi * 3u + 0u] = pos.x;
	verts[vi * 3u + 1u] = pos.y;
	verts[vi * 3u + 2u] = pos.z;
	attrs[vi * 3u + 0u] = packHalf2x16(n.xy);
	attrs[vi * 3u + 1u] = packHalf2x16(vec2(n.z, col));
	attrs[vi * 3u + 2u] = packUnorm4x8(vec4(1.0, 1.0, 0.0, 1.0));
}
#endif

#ifdef MESH_QUADS
vec3 vpos(uint v) { return vec3(verts[v * 3u], verts[v * 3u + 1u], verts[v * 3u + 2u]); }

// a, b, c, d run counter-clockwise seen from outside. Godot's front face is clockwise, so
// each triangle is written reversed. Split along the shorter diagonal: the longer one
// folds a ridge across the quad, the shorter one follows it.
void emitQuad(uint a, uint b, uint c, uint d, bool outward) {
	if (a == 0u || b == 0u || c == 0u || d == 0u) return;
	a -= 1u; b -= 1u; c -= 1u; d -= 1u;
	if (!outward) { uint t = b; b = d; d = t; }
	uint t0 = atomicAdd(counters[1], 2u);
	if (t0 + 1u >= uint(p.cap)) return;
	uint o = t0 * 3u;
	if (distance(vpos(a), vpos(c)) <= distance(vpos(b), vpos(d))) {
		indices[o + 0u] = a; indices[o + 1u] = c; indices[o + 2u] = b;
		indices[o + 3u] = a; indices[o + 4u] = d; indices[o + 5u] = c;
	} else {
		indices[o + 0u] = a; indices[o + 1u] = d; indices[o + 2u] = b;
		indices[o + 3u] = b; indices[o + 4u] = d; indices[o + 5u] = c;
	}
}

uint cellAt(int i, int j, int k) { return cellmap[(k * p.grid + j) * p.grid + i]; }

void main() {
	int N = p.grid;
	int Cn = N + 1;
	int idx = int(gl_GlobalInvocationID.x);
	if (idx >= p.count * Cn * Cn) return;
	int k = p.first + idx / (Cn * Cn);
	int rem = idx % (Cn * Cn);
	int j = rem / Cn;
	int i = rem % Cn;
	bool s0 = fieldAt(i, j, k) < 0.0;
	// One quad per crossed grid edge, joining the four cells round it. A corner owns the
	// three edges that leave it in +x, +y and +z.
	if (i < N && j >= 1 && j < N && k >= 1 && k < N && s0 != (fieldAt(i + 1, j, k) < 0.0))
		emitQuad(cellAt(i, j - 1, k - 1), cellAt(i, j, k - 1), cellAt(i, j, k), cellAt(i, j - 1, k), s0);
	if (j < N && i >= 1 && i < N && k >= 1 && k < N && s0 != (fieldAt(i, j + 1, k) < 0.0))
		emitQuad(cellAt(i - 1, j, k - 1), cellAt(i - 1, j, k), cellAt(i, j, k), cellAt(i, j, k - 1), s0);
	if (k < N && i >= 1 && i < N && j >= 1 && j < N && s0 != (fieldAt(i, j, k + 1) < 0.0))
		emitQuad(cellAt(i - 1, j - 1, k), cellAt(i, j - 1, k), cellAt(i, j, k), cellAt(i - 1, j, k), s0);
}
#endif

#ifdef MESH_LIGHT
// Cone-traced visibility along one direction (Quilez's soft shadow): the narrowest the
// cone ever got, as a fraction of its width k. A wide k is AO, a narrow one a penumbra.
float coneVis(vec3 o, vec3 d, float t0, float tmax, float k, int steps) {
	float vis = 1.0;
	float t = t0;
	float h = p.origin.w;
	for (int s = 0; s < steps; s++) {
		float dd = deSolid(o + d * t) - p.iso;
		vis = min(vis, k * dd / t);
		if (vis < 0.01) return 0.0;
		t += clamp(dd, 0.35 * h, 0.25 * tmax);
		if (t > tmax) break;
	}
	return clamp(vis, 0.0, 1.0);
}

// One AO ray: how far it got before it hit something, as a share of the AO reach. The
// cone form above read the DE's underestimate as occlusion (these DEs report about half the
// true distance near the surface), which greyed every open face. A hit test does not care
// how far short the DE falls, only whether the ray ever touches the surface.
// trap gets the orbit trap at the ray's first step, a voxel off the surface: six of them
// round a vertex are the wider neighbourhood its colour is averaged over, for free.
float aoRay(vec3 o, vec3 d, float tmax, out float trap) {
	float h = p.origin.w;
	float t = h;
	trap = -1.0;
	for (int s = 0; s < 9; s++) {
		vec4 r;
		float dd = deSolid(o + d * t, r) - p.iso;
		if (s == 0) trap = clamp((r.y * 0.7 + r.z * 0.5) * 0.45, 0.0, 1.0);
		if (dd < 0.2 * h) return clamp(t / tmax, 0.0, 1.0);
		t += max(dd, 0.4 * h);
		if (t > tmax) return 1.0;
	}
	return 1.0;
}

void main() {
	uint vi = uint(p.first) + gl_GlobalInvocationID.x;
	uint nv = min(counters[0], uint(p.cap));
	if (gl_GlobalInvocationID.x >= uint(p.count) || vi >= nv) return;
	vec3 pos = vec3(verts[vi * 3u], verts[vi * 3u + 1u], verts[vi * 3u + 2u]);
	vec2 nxy = unpackHalf2x16(attrs[vi * 3u + 0u]);
	vec2 nzc = unpackHalf2x16(attrs[vi * 3u + 1u]);
	vec3 n = normalize(vec3(nxy, nzc.x));
	float h = p.origin.w;

	// Multi-ray AO: the normal and five rays 55 degrees off it, cosine weighted. Fixed
	// directions, not a per-vertex random rotation: noise per vertex is speckle in stereo.
	vec3 t1 = normalize(cross(n, abs(n.y) < 0.9 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0)));
	vec3 t2 = cross(n, t1);
	float ao = 0.0, wsum = 0.0;
	// The vertex's own trap (a half-voxel neighbourhood, from VERTS) and the six first steps.
	// On the box families' flat faces the trap changes at the finest fold, and one voxel's
	// worth of it read as a mosaic.
	float col = nzc.y, ncol = 1.0;
	for (int r = 0; r < 6; r++) {
		vec3 d = n;
		float w = 1.0;
		if (r > 0) {
			float a = float(r) * 1.2566371;   // 2 pi / 5
			d = normalize(n * 0.574 + (t1 * cos(a) + t2 * sin(a)) * 0.819);
			w = 0.574;
		}
		float tr;
		ao += w * aoRay(pos + n * 0.5 * h, d, p.ao_radius, tr);
		wsum += w;
		if (tr >= 0.0) { col += tr; ncol += 1.0; }
	}
	ao /= wsum;
	col /= ncol;

	// One key light, fixed to the shape, with a marched penumbra. Faces turned away are in
	// their own shadow and the shader's N.L darkens them anyway, so they skip the march.
	float sh = 0.0;
	if (dot(n, p.light.xyz) > -0.1)
		sh = coneVis(pos + n * 0.5 * h, p.light.xyz, 2.0 * h, p.light.w, p.shadow_k, 40);

	attrs[vi * 3u + 1u] = packHalf2x16(vec2(nzc.x, col));
	attrs[vi * 3u + 2u] = packUnorm4x8(vec4(ao, sh, 0.0, 1.0));
	uint bin = uint(clamp(col, 0.0, 1.0) * 63.999);
	atomicAdd(counters[2u + bin], 1u);
}
#endif
#endif
