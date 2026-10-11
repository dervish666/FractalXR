#[compute]
#version 450

// FLAME SKY bake, the splat half (scripts/core/flame_sky.gd).
//
// The walkers are an RGBA32F image in the state layout, copied from the live cloud and then
// stepped by the unchanged chaos.glsl through a FlameSource of their own, so the variation
// code exists once. This pass adds each walker's palette colour into an equirect accumulator
// by its direction from the flame's centre: the sky is the flame as seen from inside it.
//
// Every walker adds the same weight, whatever its distance. That is the live renderer's rule
// too: a point is one pixel at any range, so near and far particles count alike.
//
// Atomics into a buffer, which the README measured as a disaster for a live splat (36.6 ms
// for 707,788 points on Adreno). The bake is not live: it runs a fixed slice per frame for a
// couple of seconds, once, and that is what makes the price payable.

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba32f) uniform restrict readonly image2D walkers;
layout(set = 0, binding = 1, std430) restrict buffer Acc { uint acc[]; };   // r, g, b per texel
layout(set = 0, binding = 2, std430) restrict readonly buffer Pal { vec4 pal[5]; };

layout(push_constant, std430) uniform Params {
	vec4 r0;       // rows of the cloud's world rotation
	vec4 r1;
	vec4 r2;
	vec4 centre;   // xyz: the flame's centre in state space; w: palette cycles
	ivec4 dims;    // x, y: accumulator width and height; z: walkers; w: walker row width
	vec4 misc;     // x: fixed-point scale; y: squared radius below which a walker is skipped
} p;

// points.gdshader's palette(), so the sky wears the colours the flame was wearing.
vec3 palette(float t) {
	t = clamp(t, 0.0, 1.0);
	t = clamp(0.5 + (t - 0.5) * (1.0 / 0.75), 0.0, 1.0);
	if (p.centre.w > 1.5) {
		float c = t * p.centre.w;
		t = abs(fract(c * 0.5) * 2.0 - 1.0);
	}
	float f = t * 4.0;
	vec3 c = mix(pal[0].rgb, pal[1].rgb, clamp(f, 0.0, 1.0));
	c = mix(c, pal[2].rgb, clamp(f - 1.0, 0.0, 1.0));
	c = mix(c, pal[3].rgb, clamp(f - 2.0, 0.0, 1.0));
	c = mix(c, pal[4].rgb, clamp(f - 3.0, 0.0, 1.0));
	return c;
}

void main() {
	uint idx = gl_GlobalInvocationID.x;
	if (idx >= uint(p.dims.z)) return;
	ivec2 ip = ivec2(int(idx) % p.dims.w, int(idx) / p.dims.w);
	vec4 s = imageLoad(walkers, ip);
	// self-compare NaN check; mobile isnan() is unreliable
	if (!(s.x == s.x) || !(s.y == s.y) || !(s.z == s.z)) return;
	vec3 q = s.xyz - p.centre.xyz;
	float r2 = dot(q, q);
	if (r2 < p.misc.y || r2 > 1.0e6) return;
	vec3 d = normalize(vec3(dot(p.r0.xyz, q), dot(p.r1.xyz, q), dot(p.r2.xyz, q)));

	// Equirect, forward (-Z) in the middle, up on row 0. flame_sky.gdshader reads it back
	// with the same two lines.
	float u = atan(d.x, -d.z) * 0.15915494 + 0.5;
	float v = acos(clamp(d.y, -1.0, 1.0)) * 0.31830989;
	int x = min(int(u * float(p.dims.x)), p.dims.x - 1);
	int y = min(int(v * float(p.dims.y)), p.dims.y - 1);
	uint t = uint(y * p.dims.x + x) * 3u;

	uvec3 add = uvec3(max(palette(s.w), vec3(0.0)) * p.misc.x + 0.5);
	if (add.r > 0u) atomicAdd(acc[t + 0u], add.r);
	if (add.g > 0u) atomicAdd(acc[t + 1u], add.g);
	if (add.b > 0u) atomicAdd(acc[t + 2u], add.b);
}
