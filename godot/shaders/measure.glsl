#[compute]
#version 450

// Measures where the cloud actually is, so every preset frames itself.
//
// A genome's attractor is not centred on its origin and its size varies several times
// over across the gallery (roughly 2.4 to 8.4), so one camera distance cannot suit them
// all. This reduces the particle set to a centroid and an RMS radius.
//
// Fixed point via uint atomics, because float atomics are not guaranteed on mobile.
// That makes overflow the thing to design around, not an afterthought: the sample count
// is capped by the caller and the scales below are chosen so the worst case sum stays
// under 2^32. Getting this wrong once already collapsed the cloud to nothing.
//
//   samples <= 16384, |p| <= 8 (filtered), so:
//     sum_pos  (p + 8) * 4096  <=  65536 per sample  * 16384 = 1.07e9   ok
//     sum_sq   |p|^2   * 1024  <=  65536 per sample  * 16384 = 1.07e9   ok

#define HIST_BINS 32

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba32f) uniform restrict readonly image2D state_img;
layout(set = 0, binding = 1, std430) restrict buffer Stats {
	uint sum_x;
	uint sum_y;
	uint sum_z;
	uint count;
	uint sum_sq;
	uint _pad0;
	uint _pad1;
	uint _pad2;
	// Histogram of the palette coordinate. bulbSplat.ts rank-equalises colour offline by
	// sorting, because the raw orbit trap clusters in a narrow band and a linear map
	// spends a sliver of the palette. A sort is impossible per frame; a histogram is not,
	// and its running total is the same CDF.
	// sum_c, sum_c2 and hist are accumulated but not read back today: the shaders use
	// a fixed stretch (COLOUR_STRETCH). Kept so a live colour mapping is a GDScript
	// change rather than a shader one.
	uint sum_c;
	uint sum_c2;
	uint hist[HIST_BINS];
} stats;

layout(push_constant, std430) uniform Params {
	int count;
	int tex_size;
	int stride;
	int _pad;
} p;

const float POS_SCALE = 4096.0;
const float SQ_SCALE = 1024.0;
const float BIAS = 8.0;      // matches the |p| <= 8 filter below; positions are signed
const float MAX_R2 = 64.0;

void main() {
	uint i = gl_GlobalInvocationID.x * uint(p.stride);
	if (i >= uint(p.count)) return;
	ivec2 ip = ivec2(int(i) % p.tex_size, int(i) / p.tex_size);
	vec4 st = imageLoad(state_img, ip);
	vec3 pos = st.xyz;

	// Drop escaped and NaN particles. A handful of outliers would otherwise drag the
	// centroid and inflate the radius enough to shrink the whole cloud out of sight.
	if (!(pos.x == pos.x) || !(pos.y == pos.y) || !(pos.z == pos.z)) return;
	float r2 = dot(pos, pos);
	if (r2 > MAX_R2) return;

	atomicAdd(stats.sum_x, uint((pos.x + BIAS) * POS_SCALE));
	atomicAdd(stats.sum_y, uint((pos.y + BIAS) * POS_SCALE));
	atomicAdd(stats.sum_z, uint((pos.z + BIAS) * POS_SCALE));
	atomicAdd(stats.sum_sq, uint(r2 * SQ_SCALE));
	atomicAdd(stats.count, 1u);
	atomicAdd(stats.hist[clamp(int(st.w * float(HIST_BINS)), 0, HIST_BINS - 1)], 1u);
	float c = clamp(st.w, 0.0, 1.0);
	atomicAdd(stats.sum_c, uint(c * 65536.0));
	atomicAdd(stats.sum_c2, uint(c * c * 65536.0));
}
