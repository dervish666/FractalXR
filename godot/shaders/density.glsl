#[compute]
#version 450

// Local particle density on a coarse grid, so each splat can be sized from how crowded
// its neighbourhood is.
//
// bulbSplat.ts sizes every Gaussian from the covariance of its 14 nearest neighbours,
// across a 10x range (MIN_S 0.0007 to MAX_S 0.0075). That is why 60k of its splats read
// better than 294k of uniformly sized ones: a dense region gets small splats that keep
// the detail, a sparse region gets large ones that close the gaps, and one global size
// can only ever do one of those. kNN per frame is out of the question on a live cloud;
// a grid histogram gives the same signal for one atomic per particle.

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba32f) uniform restrict readonly image2D state_img;
layout(set = 0, binding = 1, std430) restrict buffer Density { uint cell[]; };

layout(push_constant, std430) uniform PC {
	int count;
	int tex_size;
	int grid;         // cells per axis
	float inv_extent; // 1 / half-extent of the region the grid covers
	vec4 centre;      // cloud centroid, xyz
} p;

void main() {
	uint i = gl_GlobalInvocationID.x;
	if (i >= uint(p.count)) return;
	ivec2 ip = ivec2(int(i) % p.tex_size, int(i) / p.tex_size);
	vec3 pos = imageLoad(state_img, ip).xyz;
	if (!(pos.x == pos.x) || !(pos.y == pos.y) || !(pos.z == pos.z)) return;

	vec3 n = (pos - p.centre.xyz) * p.inv_extent;   // roughly -1..1
	vec3 g = (n * 0.5 + 0.5) * float(p.grid);
	ivec3 c = ivec3(floor(g));
	if (any(lessThan(c, ivec3(0))) || any(greaterThanEqual(c, ivec3(p.grid)))) return;
	atomicAdd(cell[(c.z * p.grid + c.y) * p.grid + c.x], 1u);
}
