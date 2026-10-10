#[compute]
#version 450

// FLAME SKY bake, the resolve half (scripts/core/flame_sky.gd). Once, after the last splat.
//
// Turns the accumulator into an HDR equirect the sky shader samples:
//
//   1. Near the poles an equirect row is a small circle, so its texels are thin slivers that
//      the sky minifies sideways and would shimmer under head motion. Each texel averages
//      about 1/cos(latitude) neighbours along its row (three at least), and a 1-2-1 tent
//      across the rows above and below, which makes the footprint roughly the same solid
//      angle everywhere and spreads a lone splat over a few texels instead of a hard speck.
//   2. Density relative to the flame spread evenly over the whole sphere, so the curve below
//      does not care how many samples were taken or how big the texture is.
//   3. flam3 log-density, the same curve as flam3.glsl: dense cores compress into a glow while
//      single-sample filaments stay visible. The live flame on Quest never gets this curve
//      (Forward Mobile has no HDR storage buffer); a bake that owns its accumulator does.
//
// The output is linear and above 1.0 in the cores, so Godot's own tonemapper and glow treat
// the sky the way they treat the live points.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer Acc { uint acc[]; };
layout(set = 0, binding = 1, rgba16f) uniform restrict writeonly image2D sky_img;

layout(push_constant, std430) uniform Params {
	ivec4 dims;   // x, y: size; z: most taps a row may average
	vec4 tone;    // exposure, k2, gamma, hi_desat
	vec4 norm;    // x: 1 / fixed-point scale; y: samples splatted
} p;

void main() {
	ivec2 px = ivec2(gl_GlobalInvocationID.xy);
	int w = p.dims.x;
	int h = p.dims.y;
	if (px.x >= w || px.y >= h) return;

	float lat = 3.14159265 * (0.5 - (float(px.y) + 0.5) / float(h));
	float cl = max(cos(lat), 1.0e-4);
	int n = clamp(int(ceil(1.0 / cl)), 3, p.dims.z);
	vec3 sum = vec3(0.0);
	for (int dy = -1; dy <= 1; dy++) {
		int yy = clamp(px.y + dy, 0, h - 1);
		float wy = dy == 0 ? 0.5 : 0.25;
		for (int k = 0; k < n; k++) {
			int xx = px.x - n / 2 + k;
			xx = xx < 0 ? xx + w : (xx >= w ? xx - w : xx);
			uint t = uint(yy * w + xx) * 3u;
			sum += wy * vec3(float(acc[t]), float(acc[t + 1u]), float(acc[t + 2u]));
		}
	}
	sum *= p.norm.x / float(n);

	// Samples one texel would hold if the flame were spread evenly over the sphere.
	float omega = (6.2831853 / float(w)) * (3.14159265 / float(h)) * cl;
	float expect = p.norm.y * omega * 0.07957747;   // 1 / (4 pi)
	vec3 c = sum / max(expect, 1.0e-9);

	float lum = dot(c, vec3(0.2126, 0.7152, 0.0722));
	float ls = lum > 1.0e-6 ? p.tone.x * log(1.0 + lum * p.tone.y) / lum : 0.0;
	vec3 col = c * ls;
	// A gamma above 1 lifts the faint filaments, as flam3's does, before Godot's own curve. The
	// shipped curve uses 1.0: lifted, the sparse half of the sky read as grain.
	float m = max(col.r, max(col.g, col.b));
	if (m > 1.0e-6) {
		col *= pow(m, 1.0 / p.tone.z) / m;
		m = max(col.r, max(col.g, col.b));
	}
	// Hot cores lean toward white instead of clipping each channel on its own.
	if (m > 1.0) {
		col = mix(col, vec3(m), clamp((1.0 - 1.0 / m) * p.tone.w, 0.0, 1.0));
	}
	imageStore(sky_img, px, vec4(col, 1.0));
}
