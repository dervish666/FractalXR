#[compute]
#version 450

// Depth sort, part two: write every particle id into its bucket's slice of the
// permutation. The output is an image rather than a buffer because a spatial shader can
// sample a texture and cannot read a storage buffer. R32F holds an integer exactly up
// to 16.7M, four times the largest cloud.
//
// The key computation here MUST match sort_count.glsl exactly.

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba32f) uniform restrict readonly image2D state_img;
layout(set = 0, binding = 1, std430) restrict readonly buffer Offsets { uint off[]; };
layout(set = 0, binding = 2, std430) restrict buffer Cursor { uint cur[]; };
layout(set = 0, binding = 3, r32f) uniform restrict writeonly image2D perm_img;

layout(push_constant, std430) uniform PC {
	mat4 mv;
	vec4 centre_fit;
	int count;
	int tex_size;
	int buckets;
	float d0;
	float inv_range;
	int _pad0;
	int _pad1;
	int _pad2;
} p;

int depth_key(uint i) {
	ivec2 ip = ivec2(int(i) % p.tex_size, int(i) / p.tex_size);
	vec3 pos = imageLoad(state_img, ip).xyz;
	if (!(pos.x == pos.x) || !(pos.y == pos.y) || !(pos.z == pos.z)) return p.buckets - 1;
	vec3 local = (pos - p.centre_fit.xyz) * p.centre_fit.w;
	float d = -(p.mv * vec4(local, 1.0)).z;
	float nd = clamp((d - p.d0) * p.inv_range, 0.0, 1.0);
	return clamp(int((1.0 - nd) * float(p.buckets)), 0, p.buckets - 1);
}

void main() {
	uint i = gl_GlobalInvocationID.x;
	if (i >= uint(p.count)) return;
	int k = depth_key(i);
	uint at = off[k] + atomicAdd(cur[k], 1u);
	if (at >= uint(p.count)) return;   // cannot happen if count and scan agree; never corrupt
	int w = imageSize(perm_img).x;
	imageStore(perm_img, ivec2(int(at) % w, int(at) / w), vec4(float(i), 0.0, 0.0, 0.0));
}
