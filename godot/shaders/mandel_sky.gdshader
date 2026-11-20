// MANDEL SKY (scripts/core/mandel_sky.gd): GROUND's family over the whole sky, the plane on
// the Riemann sphere with the point at infinity under your feet. mandel_sky.glsl fills a flat
// square of the plane; this maps each direction into it and colours it as ground.gdshader
// colours the floor (same palette, bands, hue, texture and CYCLE). One texture fetch a pixel.
shader_type sky;

uniform sampler2D sky_data : filter_linear, repeat_disable;
uniform bool has_data = false;
// The view on show against the one the data was filled for, both worked out in 64-bit on the
// host: q = off + k * M w is where direction w falls in the data's square. A zoom in progress
// stretches the last fill (k < 1) until the next one lands.
uniform vec2 off = vec2(0.0);
uniform float k = 1.0;
uniform float half_w = 1.0;
// The share of the texture the fill on show wrote, from the corner: a fill while zooming
// runs at a fraction of the slot's resolution.
uniform float fill_frac = 1.0;
// The ground's map rotation, two columns (FractalGround's `rot`): the sky turns with the floor.
uniform vec4 rot = vec4(1.0, 0.0, 0.0, 1.0);
// The data's fractal units per stereographic unit, for the pixel footprint of the edge line.
uniform float data_r = 2.0;
// You are here: the direction of the fractal point under your feet, and whether to draw it.
uniform vec3 here_dir = vec3(0.0, 1.0, 0.0);
uniform float here_on = 0.0;

uniform float colour_freq = 1.0;
uniform float colour_offset = 0.0;
uniform float palette_cycles = 1.0;
uniform float texture_strength = 0.6;
uniform vec3 inside_colour : source_color = vec3(0.06, 0.07, 0.11);
uniform vec3 pal0;
uniform vec3 pal1;
uniform vec3 pal2;
uniform vec3 pal3;
uniform vec3 pal4;
// How bright the sky stands against the floor (MANDEL SKY tile), and what is left of it below
// the horizon, as flame_sky.gdshader keeps.
uniform float gain = 0.6;
uniform float floor_keep = 0.12;
// What is left of the far exterior's brightness (see sky_colour).
uniform float dusk = 0.2;
// The edge: a thin bright line along the set's boundary from the distance estimate, a pixel
// or so wide at any zoom. Filaments thinner than a texel still show as a line.
uniform float edge_glow = 0.6;

global uniform float colour_cycle;

vec3 ramp(float t) {
	float f = t * 4.0;
	vec3 c = mix(pal0, pal1, clamp(f, 0.0, 1.0));
	c = mix(c, pal2, clamp(f - 1.0, 0.0, 1.0));
	c = mix(c, pal3, clamp(f - 2.0, 0.0, 1.0));
	c = mix(c, pal4, clamp(f - 3.0, 0.0, 1.0));
	return c;
}

vec3 keep_luma(vec3 c, float l0) {
	const vec3 W = vec3(0.2126, 0.7152, 0.0722);
	c *= min(l0 / max(dot(c, W), 1e-4), 3.0);
	return c + max(l0 - dot(c, W), 0.0);
}

// ground.gdshader's palette(), unchanged.
vec3 palette(float t) {
	float kk = (palette_cycles > 1.5) ? t * palette_cycles : t;
	vec3 base = ramp(abs(fract(kk * 0.5) * 2.0 - 1.0));
	if (colour_cycle <= 0.0) return base;
	return keep_luma(ramp(abs(fract(kk * 0.5 + colour_cycle) * 2.0 - 1.0)),
		dot(base, vec3(0.2126, 0.7152, 0.0722)));
}

vec3 sky_colour(vec3 d) {
	// Stereographic from the nadir. Right at the nadir w runs to infinity; the floor dims it
	// to floor_keep there anyway, and the clamp keeps the arithmetic finite.
	vec2 w = vec2(d.x, d.z) / max(1.0 + d.y, 1e-3);
	vec2 q = off + k * (mat2(rot.xy, rot.zw) * w);
	vec2 uv = q / (2.0 * half_w) + 0.5;
	vec3 col = vec3(0.0);
	if (has_data && all(greaterThan(uv, vec2(0.0))) && all(lessThan(uv, vec2(1.0)))) {
		// Clamp half a fill texel in so the filter never reaches the stale texels past it.
		float nf = float(textureSize(sky_data, 0).x) * fill_frac;
		vec2 tuv = clamp(uv, vec2(0.5 / nf), vec2(1.0 - 0.5 / nf)) * fill_frac;
		vec4 s = texture(sky_data, tuv);
		float v = s.r * colour_freq + colour_offset;
		col = palette(v);
		col *= mix(1.0, 0.45 + 1.1 * s.a, texture_strength);
		// Dusk: the far exterior, a few counts from infinity, is most of the dome at home and
		// came out a wide pale field brighter than the floor. Dim it and let the light gather
		// round the set, where the counts climb. At depth every count is high and it is moot.
		col *= mix(dusk, 1.0, smoothstep(1.0, 4.5, s.r));
		float inside = clamp(s.b, 0.0, 1.0);
		col = mix(col, inside_colour * (0.4 + 1.2 * s.a), inside);
		// Pixels to the set: the stored distance over the pixel's footprint in the plane. The
		// sample mixes inside texels (log2 DE = -40) in with the weight s.b, so undo that.
		float ib = clamp(s.b, 0.0, 0.999);
		float g_out = (s.g + 40.0 * ib) / (1.0 - ib);
		float fp = max(length(fwidth(q)) * data_r, 1e-30);
		float de_px = exp2(g_out) / fp;
		float edge = (1.0 - smoothstep(0.5, 2.5, de_px)) * (1.0 - inside);
		col += edge_glow * edge * mix(vec3(1.0), palette(v + 0.5), 0.5);
	} else if (has_data) {
		// Outside the filled square: below the horizon, or the rim of a zoom-out the next fill
		// has not reached. The plane out there is the smooth far exterior; the palette's start
		// is what the last bands fade into.
		col = palette(colour_offset) * dusk;
	}
	if (here_on > 0.5) {
		// A small ring round the point under your feet, about a degree across.
		float a = acos(clamp(dot(d, here_dir), -1.0, 1.0));
		float ring = 1.0 - smoothstep(0.0, 0.0025, abs(a - 0.009));
		float dot_c = 1.0 - smoothstep(0.0015, 0.003, a);
		col = mix(col, vec3(1.0), max(ring, dot_c) * 0.9);
	}
	return col * gain * mix(floor_keep, 1.0, smoothstep(-0.35, 0.05, d.y));
}

void sky() {
	// Nothing in the app is lit (FlameSky disables ambient and reflections while a sky hangs),
	// so the radiance cubemap is never read. The view changes every frame of a zoom, which
	// would re-render it every frame: keep that pass free.
	COLOR = AT_CUBEMAP_PASS ? vec3(0.0) : sky_colour(normalize(EYEDIR));
}
