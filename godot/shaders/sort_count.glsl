#[compute]
#version 450

// Depth sort, part one: count how many splats fall in each depth bucket.
//
// Splats composite with "over", and "over" is order-dependent: a far splat drawn after a
// near one bleeds through it, which is why an unsorted cloud never reads as a solid
// surface however high the opacity goes. Spark (the WebXR build's renderer) sorts every
// splat back-to-front on every view change; this is the same idea as a counting sort on
// the GPU: bucket by view depth, prefix-sum the buckets (bake_scan.glsl), scatter the
// particle ids into a permutation (sort_scatter.glsl), and let the vertex shader draw
// slot i as particle perm[i]. Three small dispatches a frame.
//
// The key computation here MUST match sort_scatter.glsl exactly.

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba32f) uniform restrict readonly image2D state_img;
layout(set = 0, binding = 1, std430) restrict buffer Counts { uint cnt[]; };

layout(push_constant, std430) uniform PC {
	mat4 mv;            // view <- cloud local (after framing), i.e. camera^-1 * cloud
	vec4 centre_fit;    // framing: local = (state - centre) * fit
	int count;
	int tex_size;
	int buckets;
	float d0;           // nearest depth of the bucket range
	float inv_range;    // 1 / (farthest - nearest)
	int _pad0;
	int _pad1;
	int _pad2;
} p;

int depth_key(uint i) {
	ivec2 ip = ivec2(int(i) % p.tex_size, int(i) / p.tex_size);
	vec3 pos = imageLoad(state_img, ip).xyz;
	// A NaN particle still needs a slot, or the permutation has holes and the vertex
	// shader draws stale ids twice. Send it to the last bucket; it culls itself anyway.
	if (!(pos.x == pos.x) || !(pos.y == pos.y) || !(pos.z == pos.z)) return p.buckets - 1;
	vec3 local = (pos - p.centre_fit.xyz) * p.centre_fit.w;
	float d = -(p.mv * vec4(local, 1.0)).z;
	float nd = clamp((d - p.d0) * p.inv_range, 0.0, 1.0);   // 0 near, 1 far
	// Far first: bucket 0 is the farthest, so slot order is back-to-front draw order.
	return clamp(int((1.0 - nd) * float(p.buckets)), 0, p.buckets - 1);
}

void main() {
	uint i = gl_GlobalInvocationID.x;
	if (i >= uint(p.count)) return;
	atomicAdd(cnt[depth_key(i)], 1u);
}
