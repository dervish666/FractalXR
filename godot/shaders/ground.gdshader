// The ground viewer: a flat plane you stand on, textured from a stack of fractal clipmap
// levels (ground.glsl fills them). Level i has texels twice the size of level i-1, all
// windows centred under the viewer, so what is near is sampled from fine texels and the
// horizon from coarse ones: crisp at your feet, smooth in the distance, and the frame cost
// does not depend on zoom depth or iteration count at all.
//
// Colouring is Frax's model: the fractal data is fixed, and palette, texture and relief
// are applied here at sample time, so every look control is free.
shader_type spatial;
render_mode unshaded, cull_back, fog_disabled, shadows_disabled;

uniform sampler2DArray levels : filter_nearest, repeat_disable;
uniform int tex_size = 512;
uniform int num_levels = 8;
uniform int level_rot = 0;      // layer of level i is (i + level_rot) % num_levels
uniform int min_level = 0;      // finest level that is complete
uniform int max_level = 7;      // coarsest level that is complete
uniform float texel0 = 1e-4;    // fractal units per texel at level 0
uniform float wpu = 30.0;       // world metres per fractal unit
uniform vec2 head_xz = vec2(0.0);       // where the viewer stands, world metres
uniform ivec2 view_texel0 = ivec2(0);   // level-0 texel index of the viewer's fractal position
uniform vec2 view_frac0 = vec2(0.0);    // and the fraction within it, so world offsets stay small
uniform float slack = 48.0;             // texels of window kept around the viewer (see .gd)
uniform float fog_end = 100.0;          // metres; the coarsest window ends a little past this
uniform vec3 fog_colour : source_color = vec3(0.02, 0.02, 0.04);

uniform float colour_freq = 1.0;        // palette repeats per doubling of iteration count
uniform float colour_offset = 0.0;      // slides the palette along the count
uniform float palette_cycles = 1.0;
uniform float texture_strength = 0.6;   // how much the orbit texture modulates brightness
uniform int relief_mode = 1;            // 0 flat, 1 terraces (iteration height), 2 ridges (distance)
uniform float relief_scale = 1.0;
uniform vec3 light_dir = vec3(0.45, 0.75, 0.35);
uniform vec3 inside_colour : source_color = vec3(0.03, 0.02, 0.05);
uniform float brightness = 1.0;
uniform vec3 pal0;
uniform vec3 pal1;
uniform vec3 pal2;
uniform vec3 pal3;
uniform vec3 pal4;

varying vec3 v_world;

vec3 palette(float t) {
	if (palette_cycles > 1.5) {
		float c = t * palette_cycles;
		t = abs(fract(c * 0.5) * 2.0 - 1.0);
	} else {
		t = abs(fract(t * 0.5) * 2.0 - 1.0);   // ping-pong once, so the ramp never snaps
	}
	float f = t * 4.0;
	vec3 c = mix(pal0, pal1, clamp(f, 0.0, 1.0));
	c = mix(c, pal2, clamp(f - 1.0, 0.0, 1.0));
	c = mix(c, pal3, clamp(f - 2.0, 0.0, 1.0));
	c = mix(c, pal4, clamp(f - 3.0, 0.0, 1.0));
	return c;
}

int layer_of(int level) {
	return (level + level_rot) % num_levels;
}

vec4 fetch(int level, ivec2 a) {
	ivec2 slot = ((a % tex_size) + tex_size) % tex_size;
	return texelFetch(levels, ivec3(slot, layer_of(level)), 0);
}

// Bilinear sample of a level at a level-0 texel coordinate (already relative to the
// viewer's texel, so the arithmetic below never sees a large number). Also returns, via
// `inside_window`, whether the point lies inside this level's valid window.
vec4 sample_level(int level, vec2 e0, out bool inside_window) {
	// Level-i texel coordinate of the point, split as (viewer texel >> i) + small float.
	ivec2 vt = view_texel0 >> level;
	ivec2 rem = view_texel0 - (vt << level);
	float sc = float(1 << level);
	vec2 f = (vec2(rem) + view_frac0 + e0) / sc - 0.5;   // -0.5: texel centres
	vec2 fl = floor(f);
	vec2 w = f - fl;
	ivec2 base = vt + ivec2(fl);
	// The window is N texels centred within `slack` of the viewer's texel.
	vec2 rel = f + 0.5;
	inside_window = all(lessThan(abs(rel), vec2(float(tex_size) * 0.5 - slack - 1.0)));
	vec4 s00 = fetch(level, base);
	vec4 s10 = fetch(level, base + ivec2(1, 0));
	vec4 s01 = fetch(level, base + ivec2(0, 1));
	vec4 s11 = fetch(level, base + ivec2(1, 1));
	return mix(mix(s00, s10, w.x), mix(s01, s11, w.x), w.y);
}

float height_of(vec4 s) {
	if (relief_mode == 1) return -log2(1.0 + s.r) * 0.08 * relief_scale;
	if (relief_mode == 2) return log2(max(1e-12, s.g)) * 0.03 * relief_scale;
	return 0.0;
}

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 w = v_world.xz - head_xz;
	// Offset from the viewer in level-0 texels. Small numbers by construction.
	vec2 e0 = w / (wpu * texel0);
	float dist = length(w);

	// Pick the level whose texel matches the pixel footprint; blend the two nearest.
	float fp = max(length(dFdx(e0)), length(dFdy(e0)));
	float lod = clamp(log2(max(fp, 1e-6)), float(min_level), float(max_level));
	int l0 = int(floor(lod));
	int l1 = min(l0 + 1, max_level);
	bool in0;
	bool in1;
	vec4 sa = sample_level(l0, e0, in0);
	vec4 sb = sample_level(l1, e0, in1);
	float k = fract(lod);
	if (!in0) { sa = sb; k = 1.0; }
	vec4 s = mix(sa, sb, k);
	bool valid = in0 || in1;

	// Colour: log of the count through the palette (Frax's ramp), texture as a brightness
	// modulation, the interior from its own orbit-trap channel.
	float v = log2(1.0 + s.r) * colour_freq + colour_offset;
	vec3 col = palette(v);
	col *= mix(1.0, 0.45 + 1.1 * s.a, texture_strength);
	float inside = clamp(s.b, 0.0, 1.0);
	col = mix(col, inside_colour * (0.4 + 1.2 * s.a), inside);

	// Relief: a height from the data, its normal from screen-space derivatives of that
	// height against the plane, lit by one fixed directional light.
	if (relief_mode != 0) {
		float h = height_of(s) * wpu * 0.01;
		vec3 dpx = dFdx(v_world);
		vec3 dpy = dFdy(v_world);
		vec3 t1 = vec3(dpx.x, dFdx(h), dpx.z);
		vec3 t2 = vec3(dpy.x, dFdy(h), dpy.z);
		vec3 n = normalize(cross(t2, t1));
		if (n.y < 0.0) n = -n;
		vec3 L = normalize(light_dir);
		float diff = max(dot(n, L), 0.0);
		vec3 V = normalize(CAMERA_POSITION_WORLD - v_world);
		float spec = pow(max(dot(normalize(L + V), n), 0.0), 24.0) * 0.25;
		col = col * (0.3 + 0.7 * diff) + spec * (1.0 - inside);
	}

	col *= brightness;
	float fog = smoothstep(fog_end * 0.55, fog_end, dist);
	if (!valid) fog = 1.0;
	ALBEDO = mix(col, fog_colour, fog);
}
