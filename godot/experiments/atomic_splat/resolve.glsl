#[compute]
#version 450

// flam3 log-density tone map, ported 1:1 from TONEMAP_FRAG in src/engine/shaders.ts.
// Reads the uint accumulator, zeroes it in the same pass (a fused clear, saving a full
// clear pass over ~100MB of accumulation image every frame) and writes the display texture.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, r32ui) uniform restrict uimage2DArray accum_img;
layout(set = 0, binding = 1, rgba8) uniform restrict writeonly image2DArray out_img;

layout(push_constant, std430) uniform Params {
	ivec2 res;
	int views;
	float exposure;
	float gamma;
	float k2;
	float hi_desat;
	float _pad;
} p;

const float FIXED = 1024.0;

void main() {
	ivec2 px = ivec2(gl_GlobalInvocationID.xy);
	if (px.x >= p.res.x || px.y >= p.res.y) return;

	for (int v = 0; v < p.views; v++) {
		int base = v * 3;
		ivec3 cr = ivec3(px, base + 0);
		ivec3 cg = ivec3(px, base + 1);
		ivec3 cb = ivec3(px, base + 2);

		vec3 c = vec3(
			float(imageLoad(accum_img, cr).r),
			float(imageLoad(accum_img, cg).r),
			float(imageLoad(accum_img, cb).r)) / FIXED;

		// fused clear for the next frame
		imageStore(accum_img, cr, uvec4(0u));
		imageStore(accum_img, cg, uvec4(0u));
		imageStore(accum_img, cb, uvec4(0u));

		// flam3 log-density: scale by luminance so hue survives the curve
		float lum = dot(c, vec3(0.2126, 0.7152, 0.0722));
		float ls = lum > 1e-6 ? (p.exposure * log(1.0 + lum * p.k2) / lum) : 0.0;
		vec3 col = c * ls;

		// hold the hue in bright cores instead of clipping each channel to flat white
		float m = max(col.r, max(col.g, col.b));
		if (m > 1.0) {
			vec3 hue = col / m;
			col = mix(hue, vec3(1.0), (1.0 - 1.0 / m) * p.hi_desat);
		}
		vec3 mapped = pow(clamp(col, 0.0, 1.0), vec3(1.0 / p.gamma));
		imageStore(out_img, ivec3(px, v), vec4(mapped, 1.0));
	}
}
