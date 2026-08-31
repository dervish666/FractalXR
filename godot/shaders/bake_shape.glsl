#[compute]
#version 450

// The bake proper: give every splat its own size AND shape, from the actual distribution
// of its neighbours.
//
// This is the thing the WebXR viewer spends its few seconds on before a cloud appears,
// and the reason 60k of its splats read sharper than 294k of ours. It computes a kNN
// covariance per Gaussian and gets three real axes out of it; a live grid histogram can
// only ever produce a round disc that is a bit bigger here and a bit smaller there.
//
// Two things make it affordable to do the same on-device. It runs ONCE per bulb rather
// than per frame, chunked over a handful of frames so nothing stalls. And the surface
// normal is already known, so the covariance only has to be solved in the tangent plane:
// a 2x2 eigenproblem with a closed form, not a 3x3 needing Jacobi sweeps.
//
// Output is (cos, sin, s0, s1): the major axis as an angle in the tangent frame, and the
// two axis lengths. The vertex shader rebuilds the frame from the same normal with the
// same formula, so only three numbers have to cross.

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba32f) uniform restrict readonly image2D state_img;
layout(set = 0, binding = 1, rgba32f) uniform restrict readonly image2D normal_img;
layout(set = 0, binding = 2, std430) restrict readonly buffer Counts { uint cell[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer Offsets { uint off[]; };
layout(set = 0, binding = 4, std430) restrict readonly buffer Sorted { uint sidx[]; };
layout(set = 0, binding = 5, rgba16f) uniform restrict writeonly image2D bake_img;
layout(set = 0, binding = 6, std430) restrict buffer Norm {
	uint sum_s;
	uint n_s;
	uint n_cov;   // how many splats got a real neighbourhood
	uint sum_m;   // total neighbours found, for the mean
	uint sum_cand;  // candidates examined: separates "loop never ran" from "all rejected"
	uint sum_r;     // search radius, fixed point
} nb;

layout(push_constant, std430) uniform PC {
	int count;
	int tex_size;
	int grid;
	float extent;
	vec4 centre;
	int first;
	int chunk;
	float radius_mul;
	// Size for a particle that falls outside the grid. Rare outliers on a spike, and
	// they must not come out at zero: a zero-length axis is an invisible splat, so the
	// sparse edges of a fractal would simply disappear.
	float fallback_h;
} p;

// Fixed point for the mean-size readback. Only every 64th particle contributes, so the
// sum stays inside a uint even at the 4.19M ceiling: 65k samples of a few thousand units.
const float S_SCALE = 65536.0;

void main() {
	uint k = gl_GlobalInvocationID.x;
	if (k >= uint(p.chunk)) return;
	uint i = uint(p.first) + k;
	if (i >= uint(p.count)) return;

	ivec2 ip = ivec2(int(i) % p.tex_size, int(i) / p.tex_size);
	vec3 pos = imageLoad(state_img, ip).xyz;
	vec3 nrm = imageLoad(normal_img, ip).xyz;
	if (!(pos.x == pos.x) || !(pos.y == pos.y) || !(pos.z == pos.z) || dot(nrm, nrm) < 1e-12) {
		imageStore(bake_img, ip, vec4(1.0, 0.0, p.fallback_h, p.fallback_h));
		return;
	}
	vec3 n = normalize(nrm);

	float cs = 2.0 * p.extent / float(p.grid);   // cell size, state units
	vec3 gf = ((pos - p.centre.xyz) / p.extent * 0.5 + 0.5) * float(p.grid);
	ivec3 c0 = ivec3(floor(gf));
	if (any(lessThan(c0, ivec3(0))) || any(greaterThanEqual(c0, ivec3(p.grid)))) {
		imageStore(bake_img, ip, vec4(1.0, 0.0, p.fallback_h, p.fallback_h));
		return;
	}

	// Nominal spacing from the home cell. Particles lie on a SURFACE, so m of them in a
	// box of side L sit at a spacing of L/sqrt(m), not L/cbrt(m). Getting that exponent
	// wrong is what made the grid-only sizing so timid: a cube root flattens the range
	// the neighbourhood counts actually span.
	float m0 = max(1.0, float(cell[(c0.z * p.grid + c0.y) * p.grid + c0.x]));
	float h = cs / sqrt(m0);
	float R = p.radius_mul * h;
	float R2 = R * R;

	// The tangent frame. Identical formula to splat.gdshader, which is what lets the
	// angle alone carry the orientation.
	vec3 t1 = normalize(cross(n, abs(n.z) < 0.9 ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0)));
	vec3 t2 = cross(n, t1);

	// The cells the search ball actually touches, not a blanket 3x3x3. R is typically a
	// fraction of a cell, so this is usually one cell and at most eight. Scanning 27 and
	// truncating on a budget was the bug that made every splat circular: the budget went
	// on a far corner cell whose particles all failed the radius test, and the home cell
	// was never reached, so m stayed below three and every splat took the isotropic
	// fallback. The self-test caught it as minor/major 0.99.
	float rc = R / cs;
	ivec3 lo = clamp(ivec3(floor(gf - rc)), ivec3(0), ivec3(p.grid - 1));
	ivec3 hi = clamp(ivec3(floor(gf + rc)), ivec3(0), ivec3(p.grid - 1));
	hi = min(hi, lo + 3);

	float m = 0.0;
	vec2 sum = vec2(0.0);
	float sxx = 0.0, sxy = 0.0, syy = 0.0;
	int budget = 384;   // bounds the worst case in a pathologically dense cell
	int cand = 0;

	// Home cell first, so a truncated budget is still spent on the nearest candidates.
	for (int pass = 0; pass < 2 && budget > 0; pass++) {
		for (int z = lo.z; z <= hi.z && budget > 0; z++) {
			for (int y = lo.y; y <= hi.y && budget > 0; y++) {
				for (int x = lo.x; x <= hi.x && budget > 0; x++) {
					bool home = all(equal(ivec3(x, y, z), c0));
					if ((pass == 0) != home) continue;
					int ci = (z * p.grid + y) * p.grid + x;
					uint base = off[ci];
					uint cnt = cell[ci];
					for (uint q = 0u; q < cnt && budget > 0; q++) {
						uint j = sidx[base + q];
						if (j == i) continue;
						budget--;
						cand++;
						vec3 d = imageLoad(state_img,
							ivec2(int(j) % p.tex_size, int(j) / p.tex_size)).xyz - pos;
						if (dot(d, d) > R2) continue;
						vec2 u = vec2(dot(d, t1), dot(d, t2));
						m += 1.0;
						sum += u;
						sxx += u.x * u.x;
						sxy += u.x * u.y;
						syy += u.y * u.y;
					}
				}
			}
		}
	}

	float ca = 1.0, sa = 0.0, s0 = h, s1 = h;
	if (m >= 3.0) {
		vec2 mu = sum / m;
		float a = sxx / m - mu.x * mu.x;
		float b = sxy / m - mu.x * mu.y;
		float c = syy / m - mu.y * mu.y;
		// Closed-form 2x2 symmetric eigenvalues.
		float mid = 0.5 * (a + c);
		float rad = sqrt(max(0.0, 0.25 * (a - c) * (a - c) + b * b));
		float l1 = mid + rad;
		float l2 = max(0.0, mid - rad);
		s0 = sqrt(max(1e-14, l1));
		s1 = sqrt(max(1e-14, l2));
		// Eigenvector for l1. The degenerate case is a circular patch, where any axis is
		// as good as another.
		vec2 e = vec2(b, l1 - a);
		e = (dot(e, e) > 1e-20) ? normalize(e) : vec2(1.0, 0.0);
		ca = e.x;
		sa = e.y;
		// A perfectly collinear neighbourhood gives s1 = 0 and a splat with no width at
		// all, which reads as a gap rather than a filament. Keep a floor.
		s1 = max(s1, s0 * 0.22);
		// And do not let one outlier in a sparse region blow a splat up to cover the cloud.
		s0 = min(s0, 6.0 * h);
		s1 = min(s1, s0);
	}

	imageStore(bake_img, ip, vec4(ca, sa, s0, s1));
	if ((i & 63u) == 0u) {
		atomicAdd(nb.sum_s, uint(clamp(s0 * S_SCALE, 0.0, 1.0e9)));
		atomicAdd(nb.n_s, 1u);
		atomicAdd(nb.sum_m, uint(clamp(m, 0.0, 1.0e6)));
		atomicAdd(nb.sum_cand, uint(cand));
		atomicAdd(nb.sum_r, uint(clamp(R * 1048576.0, 0.0, 1.0e8)));
		if (m >= 3.0) atomicAdd(nb.n_cov, 1u);
	}
}
