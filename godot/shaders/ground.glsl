#[compute]
#version 450

// The ground viewer's fractal fill: escape-time Mandelbrot / Julia into one rectangle of
// one clipmap level. Ported from the web zoomer's escape() (src/zoom/shaders.ts), which
// already returns the four channels the ground shader colours from:
//
//   r  smooth iteration count (max_iter inside the set)
//   g  log2 of the distance estimate to the set (Milnor/Koebe); log so half floats keep it
//   b  inside flag
//   a  texture: triangle-inequality average outside, orbit-trap radius inside
//
// Each level is a torus: absolute texel (i, j) of that level lives at slot (i mod N, j mod N),
// so panning only ever computes the strip that just came into the window. The texel grid is
// anchored at the fractal origin, which is what lets a zoom step re-label levels instead of
// recomputing them. The colouring is all done at sample time (ground.gdshader), so a palette,
// texture or relief change costs nothing here.

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba16f) uniform restrict writeonly image2DArray levels;

layout(push_constant, std430) uniform PC {
	ivec2 rect_origin;    // absolute texel index of the rectangle's first texel, this level
	ivec2 rect_size;
	vec2 julia_c;
	float texel;          // fractal units per texel at this level
	int layer;
	int tex_size;         // N
	int max_iter;
	int julia;            // 0 Mandelbrot (z0 = 0, c = texel), 1 Julia (z0 = texel, c = julia_c)
	float tex_on;
	float stalk;          // 0 = triangle-inequality texture, 1 = Pickover stalks
	float stalk_width;
	int formula;          // index into FORMULA_NAMES (fractal_ground.gd). Append only.
	float _pad1;
} p;

const float ESC2 = 65536.0;        // escape radius squared (256^2): big radius, smooth count
const float LOG_ESC = 5.5451774;   // log(256)

vec2 cmul(vec2 a, vec2 b) { return vec2(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x); }

// The escape-time families, all of them one step of z -> f(z) + c.
//
// Everything past MANDELBROT folds the plane with an abs or a conjugate before squaring.
// Those are not holomorphic, so there is no true derivative and no exact distance
// estimate; the folded value is fed through the quadratic derivative anyway, which is
// what every published Burning Ship DE does. It is right away from the fold lines and
// wrong along them, and it only feeds the `ridges` relief mode. The smooth iteration
// count that drives the colour is exact for every one of them.
//
// ORDER IS LOAD-BEARING: FORMULA_NAMES in fractal_ground.gd indexes this switch.
// Append only.
const int F_MANDELBROT   = 0;
const int F_BURNING_SHIP = 1;
const int F_TRICORN      = 2;
const int F_CELTIC       = 3;
const int F_PERPENDICULAR= 4;
const int F_BUFFALO      = 5;
const int F_CUBIC        = 6;
const int F_QUARTIC      = 7;

// How fast |z| grows per iteration. The smooth count subtracts a log in this base, so
// getting it wrong on the higher powers puts visible steps in the colour bands.
float degree_of(int f) {
	if (f == F_CUBIC) return 3.0;
	if (f == F_QUARTIC) return 4.0;
	return 2.0;
}

// One iteration. `z` and `dz` are updated in place; `addC` is 1 for Mandelbrot-style
// (c varies with the pixel) and 0 for Julia-style (c is fixed, so dc/dpixel is zero).
void iterate(int f, inout vec2 z, inout vec2 dz, vec2 c, vec2 addC) {
	vec2 zf = z;
	if (f == F_BURNING_SHIP) {
		zf = abs(z);
	} else if (f == F_TRICORN) {
		zf = vec2(z.x, -z.y);
	} else if (f == F_PERPENDICULAR) {
		zf = vec2(abs(z.x), z.y);
	}
	if (f == F_CUBIC) {
		dz = 3.0 * cmul(cmul(z, z), dz) + addC;
		z = cmul(cmul(z, z), z) + c;
		return;
	}
	if (f == F_QUARTIC) {
		vec2 z2 = cmul(z, z);
		dz = 4.0 * cmul(cmul(z2, z), dz) + addC;
		z = cmul(z2, z2) + c;
		return;
	}
	dz = 2.0 * cmul(zf, dz) + addC;
	vec2 sq = cmul(zf, zf);
	if (f == F_CELTIC) {
		sq.x = abs(sq.x);
	} else if (f == F_PERPENDICULAR) {
		sq.y = -sq.y;
	} else if (f == F_BUFFALO) {
		sq = vec2(abs(sq.x), -abs(sq.y));
	}
	z = sq + c;
}

vec4 escape(vec2 c, vec2 z0) {
	vec2 z = z0;
	vec2 dz = vec2(1.0, 0.0);
	vec2 addC = (p.julia != 0) ? vec2(0.0) : vec2(1.0, 0.0);
	float ac = length(c);
	float m2 = dot(z, z);
	float sum = 0.0, sumPrev = 0.0, count = 0.0;
	float minR2 = 1e30;
	float minAxis = 1e30;
	int n = 0;
	for (int i = 0; i < p.max_iter; i++) {
		vec2 zp = z;
		iterate(p.formula, z, dz, c, addC);
		m2 = dot(z, z);
		minR2 = min(minR2, m2);
		n = i + 1;
		if (p.tex_on > 0.5 && i > 1) {
			minAxis = min(minAxis, min(abs(z.x), abs(z.y)));
			float azp2 = dot(zp, zp);
			float lo = abs(azp2 - ac);
			float hi = azp2 + ac;
			float t = (sqrt(m2) - lo) / max(1e-12, hi - lo);
			sumPrev = sum;
			sum += clamp(t, 0.0, 1.0);
			count += 1.0;
		}
		if (m2 > ESC2) break;
	}
	float avg1 = count > 0.0 ? sum / count : 0.0;
	float avg0 = count > 1.0 ? sumPrev / (count - 1.0) : avg1;
	if (m2 <= ESC2) return vec4(float(p.max_iter), -40.0, 1.0, clamp(sqrt(minR2), 0.0, 1.0));
	float lm = log(m2) * 0.5;
	// log base d, not base 2: a cubic triples |z| each step, so the same subtraction in
	// base 2 leaves a visible stair in every colour band.
	float s = float(n) - log2(lm / LOG_ESC) / log2(degree_of(p.formula));
	float de = sqrt(m2) * lm / max(1e-20, length(dz));
	float tia = mix(avg0, avg1, clamp(s - floor(s), 0.0, 1.0));
	float st = 1.0 - clamp(minAxis / max(1e-4, p.stalk_width), 0.0, 1.0);
	return vec4(s, log2(max(de, 1e-30)), 0.0, mix(tia, st, p.stalk));
}

void main() {
	ivec2 g = ivec2(gl_GlobalInvocationID.xy);
	if (g.x >= p.rect_size.x || g.y >= p.rect_size.y) return;
	ivec2 a = p.rect_origin + g;
	vec2 pt = (vec2(a) + 0.5) * p.texel;
	vec4 r = (p.julia != 0) ? escape(p.julia_c, pt) : escape(pt, vec2(0.0));
	ivec2 slot = ((a % p.tex_size) + p.tex_size) % p.tex_size;
	imageStore(levels, ivec3(slot, p.layer), r);
}
