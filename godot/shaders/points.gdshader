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
// Falloff tightness, for the legacy kernel. A rasterised point cannot be smaller than one
// pixel, so past point_size 1.0 the only way to make a particle read as finer is to
// concentrate its energy: a higher exponent pulls the visible dot in from the sprite's edges.
uniform float sharpness = 7.0;
// How a point lands on the pixels its sprite covers. This was the flame's flicker.
//   1 area: the point is a small square, aa_width + point_size - 1 pixels across, and each
//     pixel takes the share of the square's area that falls inside it. The shares add up to
//     one wherever the point sits, so a point is equally bright at every position and slides
//     across a pixel boundary instead of jumping it.
//   0 legacy: a falloff from the sprite's centre, cut to a circle. What a point deposits
//     depends on where its centre falls inside the pixel: at size 1 anything from nothing (the
//     corners, a fifth of all positions) to full, mean 0.41. The Quest head is never still, so
//     every point re-rolled its brightness every frame, and each eye rolled its own.
//     tools/flame_flicker.sh measures it; kept to compare against.
uniform int point_kernel = 1;
// The square's side at point_size 1, in pixels. 0 is a hard one-pixel point (still equal
// brightness everywhere, but it hops pixel to pixel); 1 slides like a bilinear splat and
// reads softer. 0.5 measured as the knee: most of the flicker gone for a little width.
uniform float aa_width = 0.5;
// The legacy kernel's mean deposit at this point_size and sharpness (ParticleCloud works it
// out), so the area kernel draws at the average brightness the look was tuned at.
uniform float energy_gain = 0.4068;
// The palette coordinate is stretched by a fixed 4/3 about the centre before the ramp
// lookup. A live version (measured mean and spread, which measure.glsl still sums)
// was planned and never wired up; this constant stretch is the look that shipped.
const float COLOUR_STRETCH = 1.0 / 0.75;
// How many times the palette repeats across the equalised range. Equalisation spreads
// every point evenly over one traversal of the ramp, which reads as a single gradient.
// Repeating it two or three times gives distinct colour bands from the same data, and
// because the input is already rank-equalised each band gets an equal share of points
// rather than one swamping the others.
uniform float palette_cycles = 1.0;
// CYCLE (main.gd, the COLOUR card): the ramp scrolls by this many cycles, a global set once a
// frame for every mode. It ping-pongs, so one cycle takes each point out along the ramp, back
// and home with no seam, and it moves hue only (keep_luma). 0, the default, is the old ramp.
global uniform float colour_cycle;
uniform vec3 pal0;
uniform vec3 pal1;
uniform vec3 pal2;
uniform vec3 pal3;
uniform vec3 pal4;
// GALAXY: points closer than this to the eye fade out, metres; 0 is off. A fixed-pixel point
// a hand's width from the eyes has a disparity no one can fuse, and inside a 30 m flame
// there are always a few.
uniform float near_fade = 0.0;
// Flame ECHOES (scripts/core/flame_echoes.gd). An echo is this same material on a smaller
// vertex buffer, so it reads the hero's live state image. It draws every echo_stride-th block
// of 64 particles, offset by echo_offset blocks: a sample spread over the whole cloud, so it
// changes the way the hero does while moving and not in one slab, and still reads texels in
// runs for the cache. echo_gain pays back the particles it skips. The hero leaves all three
// at their defaults, which is the old path exactly.
instance uniform int echo_stride = 1;
instance uniform int echo_offset = 0;
instance uniform float echo_gain = 1.0;

varying vec3 v_col;
// Sprite size and the area kernel's square side, in pixels.
varying flat float v_px;
varying flat float v_side;

// Piecewise-linear ramp as a mix chain. The previous local vec3[5] with a dynamic
// index is the pattern Adreno spills to scratch memory, in a shader that runs once
// per vertex for a million vertices.
vec3 ramp(float t) {
	float f = t * 4.0;
	vec3 c = mix(pal0, pal1, clamp(f, 0.0, 1.0));
	c = mix(c, pal2, clamp(f - 1.0, 0.0, 1.0));
	c = mix(c, pal3, clamp(f - 2.0, 0.0, 1.0));
	c = mix(c, pal4, clamp(f - 3.0, 0.0, 1.0));
	return c;
}

// CYCLE moves a point's colour and keeps its brightness: the ramp at the scrolled coordinate,
// scaled to the luma the point had unscrolled. Every theme dims somewhere along its ramp, and
// scrolling luma with hue took a whole bulb from cream to a dim purple and back. A dark stop on
// a bright point is scaled at most 3x and the rest made up in grey, so it reads pale, not neon.
vec3 keep_luma(vec3 c, float l0) {
	const vec3 W = vec3(0.2126, 0.7152, 0.0722);
	c *= min(l0 / max(dot(c, W), 1e-4), 3.0);
	return c + max(l0 - dot(c, W), 0.0);
}

vec3 palette(float t) {
	t = clamp(t, 0.0, 1.0);
	t = clamp(0.5 + (t - 0.5) * COLOUR_STRETCH, 0.0, 1.0);
	float u = t;
	if (palette_cycles > 1.5) {
		// Ping-pong rather than wrap, so bands meet at a shared colour instead of
		// snapping from the top of the ramp back to the bottom.
		float c = t * palette_cycles;
		u = abs(fract(c * 0.5) * 2.0 - 1.0);
	}
	vec3 base = ramp(u);
	if (colour_cycle <= 0.0) return base;
	// The same ping-pong, slid by the cycle: a whole cycle is out to one end, back, and home.
	u = (palette_cycles > 1.5) ? abs(fract(t * palette_cycles * 0.5 + colour_cycle) * 2.0 - 1.0)
		: 1.0 - abs(fract(t * 0.5 + colour_cycle) * 2.0 - 1.0);
	return keep_luma(ramp(u), dot(base, vec3(0.2126, 0.7152, 0.0722)));
}

void vertex() {
	int i = VERTEX_ID;
	if (echo_stride > 1) {
		i = (i >> 6) * (echo_stride << 6) + (i & 63) + (echo_offset << 6);
	}
	vec4 s = texelFetch(state_tex, ivec2(i % tex_size, i / tex_size), 0);
	// self-compare NaN check; mobile isnan() is unreliable
	bool bad = !(s.x == s.x) || !(s.y == s.y) || !(s.z == s.z);
	vec3 p = (s.xyz - cloud_center) * cloud_fit;
	VERTEX = bad ? vec3(0.0, 0.0, 1e9) : p;
	v_col = palette(s.w) * brightness * echo_gain;
	if (near_fade > 0.0) {
		float eye = length((MODELVIEW_MATRIX * vec4(p, 1.0)).xyz);
		v_col *= smoothstep(near_fade * 0.4, near_fade, eye);
	}

	// The area kernel's sprite covers every pixel its square can touch: side + 1. The floor
	// keeps the division below finite; the sprite grows with it, so the shares still sum to one.
	v_side = max(1e-3, aa_width + point_size - 1.0);
	float px = point_kernel == 0 ? point_size : 1.0 + v_side;
	if (splat_mode) {
		// Perspective size of a world-space radius: r * focal / depth, where the focal
		// length in pixels is PROJECTION_MATRIX[1][1] * viewport_height / 2.
		float depth = max(0.05, -(MODELVIEW_MATRIX * vec4(p, 1.0)).z);
		px = splat_radius * PROJECTION_MATRIX[1][1] * VIEWPORT_SIZE.y * 0.5 / depth;
		px = clamp(px, 1.0, splat_max_px);
		v_side = max(1e-3, px - 1.0);
		px = point_kernel == 0 ? px : 1.0 + v_side;
	}
	POINT_SIZE = bad ? 0.0 : px;
	v_px = px;
}

void fragment() {
	vec2 d = POINT_COORD - vec2(0.5);
	// blend_add is SRC_ALPHA, ONE, so writing s as both colour scale and alpha deposits
	// v_col * s^2 and alpha s^2: the legacy kernel's colour-to-alpha relation, which
	// passthrough reads, kept by both.
	float s;
	if (point_kernel == 0) {
		float r2 = dot(d, d);
		if (r2 > 0.25) discard;
		// v_col * fall^2: tighter and about half the energy of the web build's One/One
		// blend. That is the tuned native look; SHARPNESS was set against it.
		s = exp(-r2 * sharpness);
	} else {
		// Per axis, the overlap of this pixel with the point's square, as a share of the
		// square: u is the pixel centre's distance from the point centre. Separable, and each
		// axis sums to one over the pixels the sprite covers, so the product does too. A side
		// near zero is the limit, one pixel at full weight.
		vec2 u = abs(d) * v_px;
		vec2 k = clamp(0.5 * (1.0 + v_side) - u, vec2(0.0), vec2(min(1.0, v_side))) / v_side;
		s = sqrt(energy_gain * k.x * k.y);
	}
	ALBEDO = v_col * s;
	ALPHA = s;
}
