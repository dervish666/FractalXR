#[compute]
#version 450

// MANDEL SKY (scripts/core/mandel_sky.gd): GROUND's escape-time family over the whole sky.
//
// The sky is the complex plane on the Riemann sphere: a direction d goes to the plane by
// stereographic projection from the nadir, w = d.xz / (1 + d.y), so the zenith is w = 0, the
// horizon the unit circle and the point at infinity under your feet. c = centre + r * M w,
// with M the ground's own map rotation. This fill does not see d or M at all: it renders the
// square |q.x|, |q.y| <= half_w of c = centre + r * q, a plain flat picture of the plane, and
// mandel_sky.gdshader maps each direction into it. A square over the w plane is the whole sky
// down to the horizon (and to 19.5 degrees below it in the corners). Stereographic is
// conformal, so the picture keeps its shapes; a texel spans twice the angle at the zenith that
// it does at the horizon.
//
// The four channels are ground.glsl's, so the sky colours by the same rules as the floor:
//   r  log2(1 + smooth count) (the ground colours by exactly that, and a half float holds it)
//   g  log2 of the distance estimate, fractal units
//   b  inside flag
//   a  texture: triangle-inequality average outside, orbit-trap radius inside
//
// iterate() is a copy of ground.glsl's (and ground.gdshader's n_iterate): keep the family
// order in step with FractalGround.FORMULA_NAMES. Float32 only: the host stops zooming
// before a texel gets near float32's grid (MandelSky.R_MIN).

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba16f) uniform restrict writeonly image2D sky_data;

layout(push_constant, std430) uniform PC {
	vec2 centre;
	vec2 julia_c;
	float r;           // fractal units per stereographic unit
	float half_w;      // the square's half width, stereographic units
	int n;             // texels across
	int row0;          // first row of this slice
	int max_iter;
	int formula;
	int julia;         // 0: z0 = 0, c = point; 1: z0 = point, c = julia_c
	float tex_on;
} p;

const float ESC2 = 65536.0;
const float LOG_ESC = 5.5451774;   // log(256)
const float CYCLE_EPS2 = 1e-10;

vec2 cmul(vec2 a, vec2 b) { return vec2(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x); }

float degree_of(int f) { return f == 6 ? 3.0 : (f == 7 ? 4.0 : 2.0); }

void iterate(int f, inout vec2 z, inout vec2 dz, vec2 c, vec2 addC) {
	vec2 zf = z;
	if (f == 1) zf = abs(z);
	else if (f == 2) zf = vec2(z.x, -z.y);
	else if (f == 4) zf = vec2(abs(z.x), z.y);
	if (f == 6) {
		dz = 3.0 * cmul(cmul(z, z), dz) + addC;
		z = cmul(cmul(z, z), z) + c;
		return;
	}
	if (f == 7) {
		vec2 z2 = cmul(z, z);
		dz = 4.0 * cmul(cmul(z2, z), dz) + addC;
		z = cmul(z2, z2) + c;
		return;
	}
	dz = 2.0 * cmul(zf, dz) + addC;
	vec2 sq = cmul(zf, zf);
	if (f == 3) sq.x = abs(sq.x);
	else if (f == 4) sq.y = -sq.y;
	else if (f == 5) sq = vec2(abs(sq.x), -abs(sq.y));
	z = sq + c;
}

vec4 escape(vec2 c, vec2 z0) {
	vec2 z = z0;
	vec2 zs = z0;
	int check = 1;
	vec2 dz = vec2(1.0, 0.0);
	vec2 addC = p.julia != 0 ? vec2(0.0) : vec2(1.0, 0.0);
	float ac = length(c);
	float deg = degree_of(p.formula);
	float m2 = dot(z, z);
	float sum = 0.0, sumPrev = 0.0, count = 0.0;
	float minR2 = 1e30;
	int n = 0;
	for (int i = 0; i < p.max_iter; i++) {
		vec2 zp = z;
		iterate(p.formula, z, dz, c, addC);
		m2 = dot(z, z);
		minR2 = min(minR2, m2);
		n = i + 1;
		if (p.tex_on > 0.5 && i > 1) {
			float azp2 = pow(dot(zp, zp), 0.5 * deg);
			float lo = abs(azp2 - ac);
			float hi = azp2 + ac;
			float t = (sqrt(m2) - lo) / max(1e-12, hi - lo);
			sumPrev = sum;
			sum += clamp(t, 0.0, 1.0);
			count += 1.0;
		}
		if (m2 > ESC2) break;
		// Brent's periodicity check, as ground.glsl escape(): an orbit back on a saved point
		// has settled on a cycle, and the rest of max_iter would only confirm it is inside.
		vec2 dd = z - zs;
		if (dot(dd, dd) < CYCLE_EPS2) break;
		if (n == check) {
			zs = z;
			check *= 2;
		}
	}
	if (m2 <= ESC2) return vec4(log2(1.0 + float(p.max_iter)), -40.0, 1.0, clamp(sqrt(minR2), 0.0, 1.0));
	float avg1 = count > 0.0 ? sum / count : 0.0;
	float avg0 = count > 1.0 ? sumPrev / (count - 1.0) : avg1;
	float lm = log(m2) * 0.5;
	float s = float(n) - log2(lm / LOG_ESC) / log2(deg);
	float de = sqrt(m2) * lm / max(1e-20, length(dz));
	float tia = mix(avg0, avg1, clamp(s - floor(s), 0.0, 1.0));
	return vec4(log2(1.0 + max(s, 0.0)), log2(max(de, 1e-30)), 0.0, tia);
}

void main() {
	ivec2 t = ivec2(gl_GlobalInvocationID.xy) + ivec2(0, p.row0);
	if (t.x >= p.n || t.y >= p.n) return;
	vec2 q = ((vec2(t) + 0.5) / float(p.n) * 2.0 - 1.0) * p.half_w;
	vec2 pt = p.centre + p.r * q;
	vec4 s = p.julia != 0 ? escape(p.julia_c, pt) : escape(pt, vec2(0.0));
	imageStore(sky_data, t, s);
}
