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
uniform int tex_size = 1024;
uniform int num_levels = 9;
uniform int level_rot = 0;      // layer of level i is (i + level_rot) % num_levels
uniform int min_level = 0;      // finest level that is complete
uniform int max_level = 7;      // coarsest level that is complete
uniform float texel0 = 1e-4;    // fractal units per texel at level 0
uniform float wpu = 30.0;       // world metres per fractal unit
uniform vec2 head_xz = vec2(0.0);       // where the viewer stands, world metres
uniform vec4 rot = vec4(1.0, 0.0, 0.0, 1.0);   // world -> fractal rotation, two columns
uniform ivec2 view_texel0 = ivec2(0);   // level-0 texel index of the viewer's fractal position
uniform vec2 view_frac0 = vec2(0.0);    // and the fraction within it, so world offsets stay small
uniform float slack = 48.0;             // texels of window kept around the viewer (see .gd)
uniform float fog_end = 100.0;          // metres; the coarsest window ends a little past this
uniform vec3 fog_colour : source_color = vec3(0.02, 0.02, 0.04);

uniform float colour_freq = 1.0;        // palette repeats per doubling of iteration count
uniform float colour_offset = 0.0;      // slides the palette along the count
uniform float palette_cycles = 1.0;
uniform float texture_strength = 0.6;   // how much the orbit texture modulates brightness
uniform int relief_mode = 3;            // 0 flat, 1 terraces (iteration height), 2 ridges (distance), 3 terrain (terraces + contours)
uniform float relief_scale = 1.0;
// Slope exaggeration for the lighting only: the normal is built from the true height
// gradient times this, so a shallow terrace still reads as a step. Hillshade maps do
// the same; a 1:1 gradient looks flat from head height.
uniform float relief_contrast = 2.5;
// Real displacement: the mesh is a radial grid centred on the head, and each vertex
// rises by its height minus the height under your feet, so the floor stays at floor
// level and the fractal rises and falls around you. 0 turns it off.
uniform float displace = 1.0;
// The radial mesh's ring spacing as a fraction of distance; picks the sampling level
// in the vertex stage, where there are no derivatives to measure a footprint with.
uniform float mesh_spacing = 0.06;
// Micro-relief from the orbit texture channel, a fixed few finest texels tall, so it
// reads as surface grain up close and smooths out with distance on its own.
uniform float bump_strength = 1.0;
uniform vec3 light_dir = vec3(0.5, 0.5, 0.35);   // a low sun: terrain reads by its shadows
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

// Relief height in metres. The big shape is scaled by the finest texel so it looks the
// same at every zoom: an octave of iteration count is 48 finest texels tall. The bump is
// scaled by the texel of the level being SAMPLED instead, so its slopes are the same
// steepness at every distance; tied to the finest texel it vanished two metres out,
// because the height stayed put while the texels it was measured over grew.
float height_of(vec4 s, int level, bool with_grain) {
	float unit0 = texel0 * wpu;
	float unit_l = unit0 * float(1 << level);
	float h = 0.0;
	if (relief_mode == 1 || relief_mode == 3) h = -log2(1.0 + s.r) * 48.0 * relief_scale * unit0;
	else if (relief_mode == 2) h = clamp(s.g - log2(texel0), 0.0, 16.0) * 12.0 * relief_scale * unit0;
	// Two grains: the orbit texture (broad, marbled) and the iteration bands themselves,
	// a sawtooth with a cliff at every whole count, which is the terraced Frax look.
	float grain = (s.a - 0.5) * 4.0 + (fract(s.r) - 0.5) * 1.5 * (1.0 - clamp(s.b, 0.0, 1.0));
	if (with_grain) h += grain * bump_strength * unit_l;
	return h;
}

float height_at(int level, vec2 e0) {
	bool d;
	return height_of(sample_level(level, e0, d), level, true);
}

void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	if (displace > 0.5 && (relief_mode != 0 || bump_strength > 0.0)) {
		vec2 w = wp.xz - head_xz;
		vec2 e0 = (mat2(rot.xy, rot.zw) * w) / (wpu * texel0);
		float R = float(tex_size) * 0.5 - slack - 1.0;
		// Same two limits as the fragment: never a level whose window does not reach the
		// vertex, and never one finer than the mesh can show at this distance.
		float lod_win = log2(max(max(abs(e0.x), abs(e0.y)), 1e-3) / (0.5 * R));
		float lod_fp = log2(max(length(w) * mesh_spacing, 1e-6) / (texel0 * wpu));
		int l = int(clamp(max(lod_win, lod_fp), float(min_level), float(max_level)));
		bool inside;
		vec4 sv = sample_level(l, e0, inside);
		// The big shape only. The grain is per-texel and scales with the level's texel,
		// so displacing it at coarse levels raised a field of metre-high spikes on the
		// horizon; it stays a shading term, which is where it belongs.
		bool dh;
		float h_head = height_of(sample_level(min_level, vec2(0.0), dh), min_level, false);
		float h = inside ? height_of(sv, l, false) - h_head : 0.0;
		// Local up, so the mirrored sky displaces toward the viewer as a reflection would.
		VERTEX.y += h;
	}
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 w = v_world.xz - head_xz;
	// Offset from the viewer in level-0 texels. Small numbers by construction.
	vec2 e0 = (mat2(rot.xy, rot.zw) * w) / (wpu * texel0);
	float dist = length(w);

	// Pick the level whose texel matches the pixel footprint, but never one whose window
	// does not reach this point: level i is valid out to R * 2^i level-0 texels from the
	// viewer, and choosing by footprint alone picked finer levels than that near the feet,
	// which sampled outside the window and painted fog in straight-edged wedges. The
	// half-R keeps floor(lod) inside its window; the blend to the next level is continuous
	// so the hand-over never shows as a ring.
	float fp = max(length(dFdx(e0)), length(dFdy(e0)));
	float R = float(tex_size) * 0.5 - slack - 1.0;
	float lod_fp = log2(max(fp, 1e-6));
	float lod_win = log2(max(max(abs(e0.x), abs(e0.y)), 1e-3) / (0.5 * R));
	float lod = clamp(max(lod_fp, lod_win), float(min_level), float(max_level));
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

	// Relief: a height from the data and its normal from the neighbouring texels of the
	// level actually sampled, so slopes carry per-texel detail up close and coarsen with
	// distance the way terrain does. Lit by one fixed directional light.
	if (relief_mode != 0 || bump_strength > 0.0) {
		float step = float(1 << l0);              // one texel of that level, in level-0 texels
		float tm = step * texel0 * wpu;           // and in metres
		float hx1 = height_at(l0, e0 + vec2(step, 0.0));
		float hx0 = height_at(l0, e0 - vec2(step, 0.0));
		float hz1 = height_at(l0, e0 + vec2(0.0, step));
		float hz0 = height_at(l0, e0 - vec2(0.0, step));
		float hc = height_of(sa, l0, true);
		vec3 n = normalize(vec3(-(hx1 - hx0) * relief_contrast / (2.0 * tm), 1.0,
			-(hz1 - hz0) * relief_contrast / (2.0 * tm)));
		vec3 L = normalize(light_dir);
		float diff = max(dot(n, L), 0.0);
		vec3 V = normalize(CAMERA_POSITION_WORLD - v_world);
		float spec = pow(max(dot(normalize(L + V), n), 0.0), 24.0) * 0.25;
		// Cavity: a positive Laplacian is a hollow, and hollows sit in shade. This is
		// what stops a terrain read like a bas-relief with a torch on it.
		float lap = (hx1 + hx0 + hz1 + hz0 - 4.0 * hc) / tm;
		float cavity = 1.0 - 0.4 * clamp(lap * 0.6, 0.0, 1.0);
		col = (col * (0.25 + 0.75 * diff) + spec * (1.0 - inside)) * cavity;
	}

	// Contour lines at every whole iteration count, as a topographic map draws its
	// heights; every fourth is heavier. They fade where the bands crowd past a pixel,
	// or the far distance would just go dark.
	if (relief_mode == 3) {
		float band = s.r;
		float wd = fwidth(band);
		float f = min(fract(band), 1.0 - fract(band));
		float line = 1.0 - smoothstep(0.0, wd * 1.2 + 0.015, f);
		float f4 = min(fract(band * 0.25), 1.0 - fract(band * 0.25)) * 4.0;
		float heavy = 1.0 - smoothstep(0.0, wd * 2.0 + 0.03, f4);
		float fade = 1.0 - smoothstep(0.12, 0.35, wd);
		float ink = clamp(0.45 * line + 0.35 * heavy, 0.0, 0.7) * fade * (1.0 - inside);
		col *= 1.0 - ink;
	}

	col *= brightness;
	float fog = smoothstep(fog_end * 0.55, fog_end, dist);
	if (!valid) fog = 1.0;
	ALBEDO = mix(col, fog_colour, fog);
}
