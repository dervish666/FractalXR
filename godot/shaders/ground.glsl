#[versions]

f32 = "";
df = "#define DEEP";
pert = "#define PERT";

#[compute]
#version 450

// The #[versions] defines land here: DEEP for the df variant, PERT for the perturbation one,
// nothing for f32.
VERSION_DEFINES

// The ground viewer's fractal fill: escape-time Mandelbrot / Julia into one rectangle of
// one clipmap level. Ported from the web zoomer's escape() (src/zoom/shaders.ts), which
// already returns the four values the ground shader colours from:
//
//   r  smooth iteration count (max_iter inside the set)
//   g  log2 of the distance estimate to the set (Milnor/Koebe); log so a half float keeps it
//   b  inside flag
//   a  texture: triangle-inequality average outside, orbit-trap radius inside
//
// Stored packed in four 16-bit uints (encode() below): the count as a whole float32, the
// distance as a half, the texture as 15 bits and the flag as one. The count used to be a
// half float too, and above 2048 a half is two counts apart: ITER 4096 lost every
// fraction, and with it the terraces, contours and grain that read fract(count). Same 8
// bytes a texel as before, so the stack costs no more memory.
//
// Each level is a torus: absolute texel (i, j) of that level lives at slot (i mod N, j mod N),
// so panning only ever computes the strip that just came into the window. The texel grid is
// anchored at the fractal origin, which is what lets a zoom step re-label levels instead of
// recomputing them. The colouring is all done at sample time (ground.gdshader), so a palette,
// texture or relief change costs nothing here.

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba16ui) uniform restrict writeonly uimage2DArray levels;

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
	float texel_lo;       // texel = texel + texel_lo, as a two-float (df) pair
	// Fractal coordinate of the rect's first texel centre as two-float pairs (x hi, x lo,
	// y hi, y lo), worked out in GDScript's 64-bit floats. rect_origin only picks the torus
	// slot now; the coordinate never passes through a float32 texel index, which is where
	// the old vec2(a) * texel lost neighbouring texels past about 1000x.
	vec4 origin;
	vec2 julia_c_lo;
	// PERT only: the reference orbit holds Z_0 .. Z_ref_len, and origin is the rect's first
	// texel centre less the reference point C, so it is a small delta and float32 holds it.
	int ref_len;
	int _pad3;
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

// Periodicity checking (Brent): z is saved at steps 1, 2, 4, 8 ... and an orbit that comes
// back to the saved point has settled on an attracting cycle, so the point is inside and
// the rest of max_iter would only confirm it. Inside a deep minibrot that is most of the
// fill's work: GroundGuide raises the count to tens of thousands there, and 40% of the view
// is interior. The tolerance sits far above the orbit's own rounding (float32 here, df32 in
// escape_df) and far below how near an outside point that escapes can shadow the cycle.
const float CYCLE_EPS2 = 1e-10;
const float CYCLE_EPS2_DF = 1e-16;

// The cycle check compares each z with the point nearest 0 that the orbit reached in the
// previous power-of-two window, not with z at the window's start as escape() does. Near a
// deep minibrot the orbit spends most of a period out at |z| ~ 1, where float32 resolves
// 1e-7 and neighbouring texels differ by less; near 0 it resolves the same digits at a
// fraction of the size. The tolerance follows the texel: a return closer than CYCLE_K of
// the gap between neighbouring texels' orbits (texel * |dz/dc|) is as inside as this fill
// can tell, and the old fixed 1e-5 would have swallowed whole decorations round a minibrot
// smaller than that.
const float CYCLE_K = 0.01;

vec4 escape(vec2 c, vec2 z0) {
	vec2 z = z0;
	vec2 zs = z0;
	int check = 1;
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
			// Triangle inequality on z = f(zp) + c: | |f(zp)| - |c| | <= |z| <= |f(zp)| + |c|.
			// |f(zp)| is |zp|^degree (the folds keep |zp|). Avoid pow() inside the hot loop.
			float zp2 = dot(zp, zp);
			float azp2 = p.formula == F_CUBIC ? zp2 * sqrt(zp2) : (p.formula == F_QUARTIC ? zp2 * zp2 : zp2);
			float lo = abs(azp2 - ac);
			float hi = azp2 + ac;
			float t = (sqrt(m2) - lo) / max(1e-12, hi - lo);
			sumPrev = sum;
			sum += clamp(t, 0.0, 1.0);
			count += 1.0;
		}
		if (m2 > ESC2) break;
		vec2 dd = z - zs;
		if (dot(dd, dd) < CYCLE_EPS2) break;
		if (n == check) {
			zs = z;
			check *= 2;
		}
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

#ifdef DEEP
// Two-float (df) arithmetic: a value is hi + lo, two float32s, about 46 bits of mantissa
// against float32's 24. The coordinate AND the orbit have to carry it: rounding c to
// float32 collapses neighbouring texels, and a float32 orbit adds an error the size of a
// float32 ulp at |z| ~ 1 every step, which is just as fatal once a texel is smaller than
// that. docs/deep-zoom/README.md has the measurements.
//
// Veltkamp-Dekker splitting, not fma: Vulkan only promises that fma is as exact as a
// separate multiply and add, so an fma-based product may silently lose the error term on
// some driver. The split needs nothing but correctly rounded add and multiply, which Vulkan
// does promise, and `precise` forbids the compiler contracting or reassociating any of
// it. That failure would read as noise rather than blocks; tools/ground_check.gd compares
// this path with a 64-bit CPU port for exactly that reason.
//
// Measured on the desktop: without `precise`, Metal's fast math folds every error term to
// zero and this variant returns exactly the float32 blocks (0/1024 texels right at stage
// 17). With it the answers are right but the fill runs ~37x slower than float32, where
// the arithmetic alone measures 1.5-1.7x (MoltenVK, fast math off). So on a Mac a deep
// fill sharpens slowly; the Quest runs SPIR-V natively and its cost is a headset number.

vec2 two_sum(float a, float b) {
	precise float s = a + b;
	precise float bb = s - a;
	precise float e = (a - (s - bb)) + (b - bb);
	return vec2(s, e);
}

vec2 quick_two_sum(float a, float b) {
	precise float s = a + b;
	precise float e = b - (s - a);
	return vec2(s, e);
}

vec2 split(float a) {
	precise float t = 4097.0 * a;   // 2^12 + 1 halves a 24-bit mantissa
	precise float hi = t - (t - a);
	precise float lo = a - hi;
	return vec2(hi, lo);
}

vec2 two_prod(float a, float b) {
	precise float pr = a * b;
	vec2 as = split(a);
	vec2 bs = split(b);
	precise float e = ((as.x * bs.x - pr) + as.x * bs.y + as.y * bs.x) + as.y * bs.y;
	return vec2(pr, e);
}

vec2 two_sqr(float a) {
	precise float pr = a * a;
	vec2 as = split(a);
	precise float e = ((as.x * as.x - pr) + 2.0 * as.x * as.y) + as.y * as.y;
	return vec2(pr, e);
}

vec2 df_add(vec2 a, vec2 b) {
	vec2 s = two_sum(a.x, b.x);
	precise float e = s.y + (a.y + b.y);
	return two_sum(s.x, e);
}

vec2 df_neg(vec2 a) { return -a; }

vec2 df_abs(vec2 a) { return a.x < 0.0 ? -a : a; }

vec2 df_mul(vec2 a, vec2 b) {
	vec2 pr = two_prod(a.x, b.x);
	precise float e = pr.y + (a.x * b.y + a.y * b.x);
	return quick_two_sum(pr.x, e);
}

vec2 df_sqr(vec2 a) {
	vec2 pr = two_sqr(a.x);
	precise float e = pr.y + 2.0 * a.x * a.y;
	return quick_two_sum(pr.x, e);
}

vec2 df_mul_f(vec2 a, float b) {
	vec2 pr = two_prod(a.x, b);
	precise float e = pr.y + a.y * b;
	return quick_two_sum(pr.x, e);
}

// iterate() in two-float. The orbit (x, y) and c are df; the derivative stays float32 from
// the hi parts, because it only feeds the distance estimate's log and never needs to tell
// two neighbouring texels apart. Every family is the same fold-then-power as iterate().
void iterate_df(int f, inout vec2 x, inout vec2 y, inout vec2 dz, vec2 cx, vec2 cy, vec2 addC) {
	if (f == F_CUBIC) {
		vec2 zh = vec2(x.x, y.x);
		dz = 3.0 * cmul(cmul(zh, zh), dz) + addC;
		vec2 x2 = df_sqr(x);
		vec2 y2 = df_sqr(y);
		// z^3 = (x^3 - 3xy^2) + i(3x^2 y - y^3)
		vec2 re = df_mul(x, df_add(x2, df_mul_f(y2, -3.0)));
		vec2 im = df_mul(y, df_add(df_mul_f(x2, 3.0), -y2));
		x = df_add(re, cx);
		y = df_add(im, cy);
		return;
	}
	if (f == F_QUARTIC) {
		vec2 zh = vec2(x.x, y.x);
		vec2 z2h = cmul(zh, zh);
		dz = 4.0 * cmul(cmul(z2h, zh), dz) + addC;
		vec2 a = df_add(df_sqr(x), -df_sqr(y));
		vec2 b = 2.0 * df_mul(x, y);   // times two is exact on both halves
		x = df_add(df_add(df_sqr(a), -df_sqr(b)), cx);
		y = df_add(2.0 * df_mul(a, b), cy);
		return;
	}
	vec2 fx = x;
	vec2 fy = y;
	if (f == F_BURNING_SHIP) {
		fx = df_abs(x);
		fy = df_abs(y);
	} else if (f == F_TRICORN) {
		fy = -y;
	} else if (f == F_PERPENDICULAR) {
		fx = df_abs(x);
	}
	dz = 2.0 * cmul(vec2(fx.x, fy.x), dz) + addC;
	vec2 sx = df_add(df_sqr(fx), -df_sqr(fy));
	vec2 sy = 2.0 * df_mul(fx, fy);
	if (f == F_CELTIC) {
		sx = df_abs(sx);
	} else if (f == F_PERPENDICULAR) {
		sy = -sy;
	} else if (f == F_BUFFALO) {
		sx = df_abs(sx);
		sy = -df_abs(sy);
	}
	x = df_add(sx, cx);
	y = df_add(sy, cy);
}

// escape() with a df orbit. Everything after the iteration (the smooth count, distance,
// texture) reads the hi parts: those are magnitudes and averages, where float32 is plenty.
vec4 escape_df(vec2 cx, vec2 cy, vec2 x0, vec2 y0) {
	vec2 x = x0;
	vec2 y = y0;
	vec2 xs = x0;
	vec2 ys = y0;
	int check = 1;
	float tk2 = CYCLE_K * CYCLE_K * p.texel * p.texel;
	vec2 dz = vec2(1.0, 0.0);
	vec2 addC = (p.julia != 0) ? vec2(0.0) : vec2(1.0, 0.0);
	float ac = length(vec2(cx.x, cy.x));
	float m2 = x.x * x.x + y.x * y.x;
	float sum = 0.0, sumPrev = 0.0, count = 0.0;
	float minR2 = 1e30;
	float minAxis = 1e30;
	int n = 0;
	for (int i = 0; i < p.max_iter; i++) {
		vec2 zp = vec2(x.x, y.x);
		iterate_df(p.formula, x, y, dz, cx, cy, addC);
		m2 = x.x * x.x + y.x * y.x;
		minR2 = min(minR2, m2);
		n = i + 1;
		if (p.tex_on > 0.5 && i > 1) {
			minAxis = min(minAxis, min(abs(x.x), abs(y.x)));
			float zp2 = dot(zp, zp);
			float azp2 = p.formula == F_CUBIC ? zp2 * sqrt(zp2) : (p.formula == F_QUARTIC ? zp2 * zp2 : zp2);
			float lo = abs(azp2 - ac);
			float hi = azp2 + ac;
			float t = (sqrt(m2) - lo) / max(1e-12, hi - lo);
			sumPrev = sum;
			sum += clamp(t, 0.0, 1.0);
			count += 1.0;
		}
		if (m2 > ESC2) break;
		// The difference in df, so its hi part carries the bits float32 z would have lost.
		float ddx = df_add(x, -xs).x;
		float ddy = df_add(y, -ys).x;
		// Scaled to the texel as in escape_pert: a fixed 1e-16 called 291 of 1024 outside
		// texels inside round a stage-19 minibrot (tools/ground_check.sh, minibrot case).
		if (ddx * ddx + ddy * ddy < min(CYCLE_EPS2_DF, tk2 * dot(dz, dz))) break;
		if (n == check) {
			xs = x;
			ys = y;
			check *= 2;
		}
	}
	float avg1 = count > 0.0 ? sum / count : 0.0;
	float avg0 = count > 1.0 ? sumPrev / (count - 1.0) : avg1;
	if (m2 <= ESC2) return vec4(float(p.max_iter), -40.0, 1.0, clamp(sqrt(minR2), 0.0, 1.0));
	float lm = log(m2) * 0.5;
	float s = float(n) - log2(lm / LOG_ESC) / log2(degree_of(p.formula));
	float de = sqrt(m2) * lm / max(1e-20, length(dz));
	float tia = mix(avg0, avg1, clamp(s - floor(s), 0.0, 1.0));
	float st = 1.0 - clamp(minAxis / max(1e-4, p.stalk_width), 0.0, 1.0);
	return vec4(s, log2(max(de, 1e-30)), 0.0, mix(tia, st, p.stalk));
}
#endif

#ifdef PERT
// Perturbation, Mandelbrot only: one reference orbit Z_n of a point C, iterated in 64-bit
// on the CPU, and each texel iterates only its difference d_n = z_n - Z_n from it, with
// dc = c - C:
//
//   d' = 2 Z d + d^2 + dc = (2Z + d) d + dc
//
// No term in it is large, so every texel is plain float32 work and a deep fill costs what a
// shallow one does, against df32's 40x on the M1. Every other family stays on df32. The
// folded ones are not holomorphic, and the cubic and quartic were measured
// (tools/ground_check.sh, and a C replay of this loop): float32 deltas matched the 64-bit
// count on 88-93% of a boundary patch with the reference only 250 texels away, where the
// Mandelbrot holds 98-99.5% out to 4000.
//
// Rebasing (Zhuoran's): when |z| drops below |d|, or the stored orbit runs out, the texel
// carries on from the start of the reference with d = z. That is the whole glitch fix, no
// second pass and no second reference, and it lets any reference serve: an orbit that
// escapes after a few hundred steps still fills a texel needing thousands. The best
// reference is a minibrot's nucleus (GroundGuide hands it over), whose orbit returns to 0
// every period and never escapes.
//
// Each entry is Z_n as a two-float, (hi.x, hi.y, lo.x, lo.y). The step itself only multiplies
// by Z, where hi's 24 bits are plenty, but z = Z + d is a sum, and with Z rounded to float32
// a texel that rebases early takes that rounding (|Z| * 6e-8, a hundred texels at stage 17)
// into its orbit. A reference 24000 texels off the patch matched the 64-bit count on 73-96%
// of texels that way, against 99.9% for its own; hi + (lo + d) keeps the digits.
layout(set = 0, binding = 1, std430) restrict readonly buffer Ref { vec4 ref_z[]; };


vec4 escape_pert(vec2 dc) {
	vec2 d = vec2(0.0);
	vec2 z = vec2(0.0);
	int k = 0;
	vec2 dz = vec2(1.0, 0.0);
	float ac = length(ref_z[1].xy + dc);   // Z_1 = C
	float m2 = 0.0;
	float sum = 0.0, sumPrev = 0.0, count = 0.0;
	float minR2 = 1e30;
	float minAxis = 1e30;
	vec2 zs = vec2(1e30);    // nearest-0 point of the last closed window
	vec2 zw = vec2(0.0);     // nearest-0 point of the open window
	float zw2 = 1e30;
	int check = 1;
	float tk2 = CYCLE_K * CYCLE_K * p.texel * p.texel;
	int n = 0;
	for (int i = 0; i < p.max_iter; i++) {
		vec2 zp = z;
		dz = 2.0 * cmul(z, dz) + vec2(1.0, 0.0);
		d = cmul(2.0 * ref_z[k].xy + d, d) + dc;
		k++;
		vec4 Z = ref_z[k];
		z = Z.xy + (Z.zw + d);
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
		if (k >= p.ref_len || m2 < dot(d, d)) {
			d = z;
			k = 0;
		}
		vec2 dd = z - zs;
		if (dot(dd, dd) < min(CYCLE_EPS2, tk2 * dot(dz, dz))) break;
		if (m2 < zw2) {
			zw = z;
			zw2 = m2;
		}
		if (n == check) {
			zs = zw;
			zw2 = 1e30;
			check *= 2;
		}
	}
	float avg1 = count > 0.0 ? sum / count : 0.0;
	float avg0 = count > 1.0 ? sumPrev / (count - 1.0) : avg1;
	if (m2 <= ESC2) return vec4(float(p.max_iter), -40.0, 1.0, clamp(sqrt(minR2), 0.0, 1.0));
	float lm = log(m2) * 0.5;
	float s = float(n) - log2(lm / LOG_ESC);
	float de = sqrt(m2) * lm / max(1e-20, length(dz));
	float tia = mix(avg0, avg1, clamp(s - floor(s), 0.0, 1.0));
	float st = 1.0 - clamp(minAxis / max(1e-4, p.stalk_width), 0.0, 1.0);
	return vec4(s, log2(max(de, 1e-30)), 0.0, mix(tia, st, p.stalk));
}
#endif

// The packing ground.gdshader's fetch() undoes. Keep the two in step.
uvec4 encode(vec4 r) {
	uint c = floatBitsToUint(r.x);
	uint de = packHalf2x16(vec2(r.y, 0.0)) & 0xFFFFu;
	uint tf = (uint(clamp(r.w, 0.0, 1.0) * 32767.0 + 0.5) << 1) | (r.z > 0.5 ? 1u : 0u);
	return uvec4(c & 0xFFFFu, c >> 16, de, tf);
}

void main() {
	ivec2 g = ivec2(gl_GlobalInvocationID.xy);
	if (g.x >= p.rect_size.x || g.y >= p.rect_size.y) return;
	ivec2 a = p.rect_origin + g;
#ifdef PERT
	// origin is already relative to the reference point, a few thousand texels at most.
	vec2 dc = vec2(p.origin.x + p.origin.y, p.origin.z + p.origin.w) + vec2(g) * p.texel;
	vec4 r = escape_pert(dc);
#elif defined(DEEP)
	vec2 px = df_add(p.origin.xy, df_mul_f(vec2(p.texel, p.texel_lo), float(g.x)));
	vec2 py = df_add(p.origin.zw, df_mul_f(vec2(p.texel, p.texel_lo), float(g.y)));
	vec4 r = (p.julia != 0)
		? escape_df(vec2(p.julia_c.x, p.julia_c_lo.x), vec2(p.julia_c.y, p.julia_c_lo.y), px, py)
		: escape_df(px, py, vec2(0.0), vec2(0.0));
#else
	// g is at most a few thousand texels, so g * texel rounds by about 1e-4 of a texel and
	// the real rounding is the origin's, the same half-ulp the old absolute-index product
	// paid. Past DF_RATIO (fractal_ground.gd) that is no longer enough and the DEEP
	// variant runs instead.
	vec2 pt = p.origin.xz + vec2(g) * p.texel;
	vec4 r = (p.julia != 0) ? escape(p.julia_c, pt) : escape(pt, vec2(0.0));
#endif
	ivec2 slot = ((a % p.tex_size) + p.tex_size) % p.tex_size;
	imageStore(levels, ivec3(slot, p.layer), encode(r));
}
