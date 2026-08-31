#[compute]
#version 450

// flam3 log-density tone map, ported 1:1 from TONEMAP_FRAG in src/engine/shaders.ts.
//
// Runs as a CompositorEffect over the scene's HDR colour buffer, after the additive
// points have accumulated into it and before Godot's own post chain. This is what
// gives a fractal flame its look: dense regions compress into a glowing core while
// single-particle filaments stay visible, instead of everything above 1.0 clipping
// to flat white.
//
// Reading and writing the same image is safe here because each invocation touches
// exactly one pixel and never reads a neighbour.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba16f) uniform restrict image2D color_img;

layout(push_constant, std430) uniform Params {
	ivec2 size;
	float exposure;
	float gamma;
	float k2;
	float hi_desat;
	float pre_gamma;  // undoes Godot's later linear->sRGB encode; 1.0 disables
	float _pad;
} p;

void main() {
	ivec2 px = ivec2(gl_GlobalInvocationID.xy);
	if (px.x >= p.size.x || px.y >= p.size.y) return;

	vec4 src = imageLoad(color_img, px);
	vec3 c = src.rgb;

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

	// The curve above produces a display-referred value, but Godot still encodes
	// linear->sRGB downstream. Pre-compensating here means the pixel that reaches the
	// panel is the one this shader actually chose.
	mapped = pow(mapped, vec3(p.pre_gamma));

	imageStore(color_img, px, vec4(mapped, src.a));
}
