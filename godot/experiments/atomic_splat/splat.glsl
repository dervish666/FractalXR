#[compute]
#version 450

// Additive splat via image atomics. WebGL2 cannot do this at all.
// The web build rasterises GL_POINTS with additive blending into an RGBA16F
// target; here each particle atomically adds fixed-point RGB straight into a
// uint accumulation image, skipping the rasteriser entirely.

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba32f) uniform restrict readonly image2D state_img;
layout(set = 0, binding = 1, r32ui) uniform restrict uimage2DArray accum_img; // 6 layers: rgb x 2 views
layout(set = 0, binding = 2, std430) restrict readonly buffer Genome { float g[]; };

#define PAL(i, k) g[208 + (i) * 3 + (k)]

layout(push_constant, std430) uniform Params {
	mat4 viewproj;   // 64 bytes
	ivec2 res;       // 8
	int view;        // 4
	int count;       // 4
	int tex_size;    // 4
	int stamp;       // 4. 1 = single pixel, 2 = 2x2 bilinear (matches the web's 2px sprite)
	float brightness;// 4
	float _pad;      // 4  = 96 bytes total, inside the 128-byte guaranteed limit
} p;

const float FIXED = 1024.0; // fixed-point scale; 708K particles x 0.9 x 1024 stays well under uint32

// 5 control colours, linearly interpolated. Same LUT the web build bakes into a 256x1 texture.
vec3 palette(float t) {
	t = clamp(t, 0.0, 1.0);
	float f = t * 4.0;
	int i0 = min(3, int(f));
	float lf = f - float(i0);
	vec3 a = vec3(PAL(i0, 0), PAL(i0, 1), PAL(i0, 2));
	vec3 b = vec3(PAL(i0 + 1, 0), PAL(i0 + 1, 1), PAL(i0 + 1, 2));
	return mix(a, b, lf);
}

void add_px(ivec2 px, vec3 c) {
	if (px.x < 0 || px.y < 0 || px.x >= p.res.x || px.y >= p.res.y) return;
	uvec3 q = uvec3(max(c, vec3(0.0)) * FIXED);
	int base = p.view * 3;
	if (q.r > 0u) imageAtomicAdd(accum_img, ivec3(px, base + 0), q.r);
	if (q.g > 0u) imageAtomicAdd(accum_img, ivec3(px, base + 1), q.g);
	if (q.b > 0u) imageAtomicAdd(accum_img, ivec3(px, base + 2), q.b);
}

void main() {
	uint idx = gl_GlobalInvocationID.x;
	if (idx >= uint(p.count)) return;
	ivec2 ip = ivec2(int(idx) % p.tex_size, int(idx) / p.tex_size);

	vec4 s = imageLoad(state_img, ip);
	vec3 pos = s.xyz;
	if (!(pos.x == pos.x) || !(pos.y == pos.y) || !(pos.z == pos.z)) return;

	vec4 clip = p.viewproj * vec4(pos, 1.0);
	if (clip.w <= 1e-6) return;
	vec3 ndc = clip.xyz / clip.w;
	if (abs(ndc.x) > 1.0 || abs(ndc.y) > 1.0 || ndc.z < -1.0 || ndc.z > 1.0) return;

	vec2 uv = vec2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5); // y-flip: image space is y-down
	vec2 fp = uv * vec2(p.res);
	vec3 c = palette(s.w) * p.brightness;

	if (p.stamp <= 1) {
		add_px(ivec2(fp), c);
		return;
	}

	// 2x2 bilinear stamp, approximating the web's exp(-r2*7) 2px sprite closely enough
	// that the accumulated field matches, at 4x the atomic traffic. Toggleable: this is
	// the single biggest cost knob on the compute path.
	vec2 f = fract(fp - 0.5);
	ivec2 b = ivec2(floor(fp - 0.5));
	add_px(b + ivec2(0, 0), c * (1.0 - f.x) * (1.0 - f.y));
	add_px(b + ivec2(1, 0), c * f.x * (1.0 - f.y));
	add_px(b + ivec2(0, 1), c * (1.0 - f.x) * f.y);
	add_px(b + ivec2(1, 1), c * f.x * f.y);
}
