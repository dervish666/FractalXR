// Camera-facing quad splats, two triangles per particle.
//
// Why not point sprites: Adreno clamps gl_PointSize to 1. Every particle came out as a
// single pixel at every distance no matter what size was requested, which is why the
// cloud read as dust from inside a shell and why no point-size setting ever changed
// anything. Real size needs real geometry.
//
// The mesh is six dummy vertices per particle. VERTEX_ID carries everything: the
// particle index and which corner this is. So the mesh is a bare resize with no
// attributes to fill, and changing the particle count stays cheap.
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, depth_test_disabled,
	fog_disabled, shadows_disabled, skip_vertex_transform;

uniform sampler2D state_tex : filter_nearest, source_color;
uniform sampler2D normal_tex : filter_nearest;
// Surface-aligned splats. bulbSplat.ts is explicit that a uniform camera-facing sphere
// per point "blurs the filigree": a disc lying ACROSS a filament smears it, a disc lying
// ALONG it keeps the edge. The web build gets that orientation from a 14-neighbour
// covariance computed offline. A distance-estimate surface hands us the normal directly,
// so we get the same alignment for free and on a moving cloud.
uniform bool use_normals = false;
// How flat the disc is along the normal. bulbSplat.ts uses THIN = 0.16 for the same job.
uniform float splat_thin = 0.18;
uniform int tex_size = 2048;
uniform float splat_radius = 0.026;
uniform float brightness = 0.3;
uniform float sharpness = 3.0;
uniform vec3 cloud_center = vec3(0.0);
uniform float cloud_fit = 1.0;
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
varying vec2 v_off;

const vec2 CORNERS[6] = vec2[6](
	vec2(-1.0, -1.0), vec2(1.0, -1.0), vec2(1.0, 1.0),
	vec2(-1.0, -1.0), vec2(1.0, 1.0), vec2(-1.0, 1.0));

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
	int pid = VERTEX_ID / 6;
	v_off = CORNERS[VERTEX_ID % 6];

	vec4 s = texelFetch(state_tex, ivec2(pid % tex_size, pid / tex_size), 0);
	bool bad = !(s.x == s.x) || !(s.y == s.y) || !(s.z == s.z);
	vec3 p = (s.xyz - cloud_center) * cloud_fit;

	// skip_vertex_transform means VERTEX is expected in VIEW space, which is exactly
	// where a billboard wants to be built: offset on the view plane and the quad always
	// faces the eye, in both eyes, with no per-eye special case.
	vec3 vpos = (MODELVIEW_MATRIX * vec4(p, 1.0)).xyz;
	float mscale = length(MODELVIEW_MATRIX[0].xyz);   // carry the cloud's own scale
	float r = splat_radius * mscale;

	if (use_normals) {
		// Build the quad in the surface's tangent plane, then flatten it along the
		// normal. Seen face-on it is a disc in the surface; seen edge-on it nearly
		// vanishes, which is what stops a shell reading as fog.
		vec3 n = normalize((MODELVIEW_MATRIX * vec4(
			texelFetch(normal_tex, ivec2(pid % tex_size, pid / tex_size), 0).xyz, 0.0)).xyz);
		vec3 t1 = normalize(cross(n, abs(n.z) < 0.9 ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0)));
		vec3 t2 = cross(n, t1);
		vpos += (t1 * v_off.x + t2 * v_off.y) * r + n * (v_off.x * splat_thin * r);
	} else {
		vpos.xy += v_off * r;
	}

	VERTEX = bad ? vec3(0.0, 0.0, 1e9) : vpos;
	v_col = palette(s.w) * brightness;
}

void fragment() {
	float r2 = dot(v_off, v_off);
	if (r2 > 1.0) discard;
	float fall = exp(-r2 * sharpness);
	ALBEDO = v_col * fall;
	ALPHA = fall;
}
