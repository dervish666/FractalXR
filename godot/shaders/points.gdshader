// Particle cloud renderer. Type-agnostic: it reads position and palette coordinate
// from the state image and knows nothing about which FractalSource filled it, so
// flames, bulbs and anything added later all render through this one shader.
//
// Mirrors POINTS_VERT / POINTS_FRAG in src/engine/shaders.ts.
//
// VERTEX_ID indexes the state image directly, so the mesh carries no UV attribute
// and is just a resized vertex buffer. That is what makes the draw range (drawing
// only `count` of the 2.36M particles) cheap to change at runtime.
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, depth_test_disabled, fog_disabled, shadows_disabled, vertex_lighting;

uniform sampler2D state_tex : filter_nearest, source_color;
uniform int tex_size = 2048;
// Centre and size come from the measure pass, so each preset frames itself the same
// way. Applied here rather than on the node transform so the grab stays purely the
// user's: they move the cloud, this only decides what "the cloud" means.
uniform vec3 cloud_center = vec3(0.0);
uniform float cloud_fit = 1.0;
// Splat mode: size the particle in WORLD space rather than in pixels.
//
// This is the difference between the WebXR splat build and a point cloud, and it is not
// about Gaussians. A fixed-pixel point looks identical however close you get, so flying
// inside a shell gives you dust. A world-sized splat grows as you approach, so from
// inside you get large soft overlapping discs that read as a surface. One vertex per
// particle either way: no covariance matrices, no depth sorting.
uniform bool splat_mode = false;
uniform float splat_radius = 0.012;   // metres, before the cloud's own scale
uniform float splat_max_px = 64.0;    // a particle at arm's length must not fill the eye
uniform float point_size = 1.0;
uniform float brightness = 0.9;
// Falloff tightness. A rasterised point cannot be smaller than one pixel, so past
// point_size 1.0 the only way to make a particle read as finer is to concentrate its
// energy: a higher exponent pulls the visible dot in from the sprite's edges.
uniform float sharpness = 7.0;
// Running total of the palette-coordinate histogram, from the measure pass. Mapping a
// point through its own percentile uses the whole gradient; the raw value clusters in a
// narrow band and would use a sliver of it.
uniform float colour_cdf[32];
// How many times the palette repeats across the equalised range. Equalisation spreads
// every point evenly over one traversal of the ramp, which reads as a single gradient.
// Repeating it two or three times gives distinct colour bands from the same data, and
// because the input is already rank-equalised each band gets an equal share of points
// rather than one swamping the others.
uniform float palette_cycles = 1.0;
uniform vec3 pal0;
uniform vec3 pal1;
uniform vec3 pal2;
uniform vec3 pal3;
uniform vec3 pal4;

varying vec3 v_col;

vec3 palette(float t) {
	t = clamp(t, 0.0, 1.0);
	// Rank-equalise: replace the value with its percentile.
	int bin = clamp(int(t * 32.0), 0, 31);
	float lo = bin == 0 ? 0.0 : colour_cdf[bin - 1];
	t = mix(lo, colour_cdf[bin], fract(t * 32.0));
	if (palette_cycles > 1.5) {
		// Ping-pong rather than wrap, so bands meet at a shared colour instead of
		// snapping from the top of the ramp back to the bottom.
		float c = t * palette_cycles;
		t = abs(fract(c * 0.5) * 2.0 - 1.0);
	}
	float f = t * 4.0;
	int i0 = min(3, int(f));
	float lf = f - float(i0);
	vec3 cols[5] = vec3[5](pal0, pal1, pal2, pal3, pal4);
	return mix(cols[i0], cols[i0 + 1], lf);
}

void vertex() {
	int i = VERTEX_ID;
	vec4 s = texelFetch(state_tex, ivec2(i % tex_size, i / tex_size), 0);
	// self-compare NaN check; mobile isnan() is unreliable
	bool bad = !(s.x == s.x) || !(s.y == s.y) || !(s.z == s.z);
	vec3 p = (s.xyz - cloud_center) * cloud_fit;
	VERTEX = bad ? vec3(0.0, 0.0, 1e9) : p;
	v_col = palette(s.w) * brightness;

	float px = point_size;
	if (splat_mode) {
		// Perspective size of a world-space radius: r * focal / depth, where the focal
		// length in pixels is PROJECTION_MATRIX[1][1] * viewport_height / 2.
		float depth = max(0.05, -(MODELVIEW_MATRIX * vec4(p, 1.0)).z);
		px = splat_radius * PROJECTION_MATRIX[1][1] * VIEWPORT_SIZE.y * 0.5 / depth;
		px = clamp(px, 1.0, splat_max_px);
	}
	POINT_SIZE = bad ? 0.0 : px;
}

void fragment() {
	vec2 d = POINT_COORD - vec2(0.5);
	float r2 = dot(d, d);
	if (r2 > 0.25) discard;
	float fall = exp(-r2 * sharpness);
	ALBEDO = v_col * fall;
	ALPHA = fall;
}
