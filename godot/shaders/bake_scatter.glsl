#[compute]
#version 450

// Part two of the spatial index: write every particle's id into its cell's slice, so the
// shape pass can walk a neighbourhood by reading a contiguous run.
//
// The cell mapping here MUST match density.glsl exactly. It is the same arithmetic on the
// same centre and extent, because the counts that sized the slices came from there.

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba32f) uniform restrict readonly image2D state_img;
layout(set = 0, binding = 1, std430) restrict readonly buffer Offsets { uint off[]; };
layout(set = 0, binding = 2, std430) restrict buffer Cursor { uint cur[]; };
layout(set = 0, binding = 3, std430) restrict writeonly buffer Sorted { uint sidx[]; };

layout(push_constant, std430) uniform PC {
	int count;
	int tex_size;
	int grid;
	float inv_extent;
	vec4 centre;
} p;

void main() {
	uint i = gl_GlobalInvocationID.x;
	if (i >= uint(p.count)) return;
	ivec2 ip = ivec2(int(i) % p.tex_size, int(i) / p.tex_size);
	vec3 pos = imageLoad(state_img, ip).xyz;
	if (!(pos.x == pos.x) || !(pos.y == pos.y) || !(pos.z == pos.z)) return;

	vec3 n = (pos - p.centre.xyz) * p.inv_extent;
	vec3 g = (n * 0.5 + 0.5) * float(p.grid);
	ivec3 c = ivec3(floor(g));
	if (any(lessThan(c, ivec3(0))) || any(greaterThanEqual(c, ivec3(p.grid)))) return;
	int ci = (c.z * p.grid + c.y) * p.grid + c.x;

	uint slot = atomicAdd(cur[ci], 1u);
	uint at = off[ci] + slot;
	// Belt and braces. If the counting pass and this one ever disagreed about a boundary
	// case, an out-of-range write would corrupt another cell's slice silently.
	if (at < uint(p.count)) sidx[at] = i;
}
