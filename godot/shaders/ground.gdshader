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

// Four packed 16-bit uints a texel (see encode() in ground.glsl); fetch() unpacks them.
uniform usampler2DArray levels : filter_nearest, repeat_disable;
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
// The floor reference, in level-0 texels from the viewer: the terrain is lowered by the
// height at this point so it sits at floor level. The host holds it still while the eye
// stays within ref_hold of it and lags it behind the viewer over a couple of seconds
// once it moves; sampling under the head itself made the whole field jump every time you
// stepped over a terrace.
uniform vec2 level_e0 = vec2(0.0);
// How far the eye may wander from that reference before it moves (REF_HOLD_M). The
// displaced field picks its level by distance from the reference plus this, so it cannot
// be finer than the eye-centred mesh can carry anywhere the eye is allowed to be.
uniform float ref_hold = 0.3;
uniform float slack = 48.0;             // texels of window kept around the viewer (see .gd)
// Per level, the part of its window that holds that level's texels right now, as
// (lo.x, lo.y, hi.x, hi.y) in level texels from the viewer's texel, hi exclusive. The rest
// is queued for the fill (a strip a pan uncovered, a level a zoom step just made) and its
// slots still hold texels from the far side of the window or another scale entirely.
// All zeros: nothing usable. FractalGround._clean_rect() works these out.
uniform vec4 clean_rect[9];
uniform float fog_end = 100.0;          // metres; the coarsest window ends a little past this
uniform vec3 fog_colour : source_color = vec3(0.02, 0.02, 0.04);

uniform float colour_freq = 1.0;        // palette repeats per doubling of iteration count
uniform float colour_offset = 0.0;      // slides the palette along the count
uniform float palette_cycles = 1.0;
uniform float texture_strength = 0.6;   // how much the orbit texture modulates brightness
uniform int relief_mode = 3;            // 0 flat, 1 terraces (iteration height), 2 ridges (distance), 3 terrain (terraces + contours), 4 coast
uniform float relief_scale = 1.0;
// COAST: the contour lines are heights. The escape count falls by one each time the distance
// to the set doubles (s ~ c - log2 DE, since DE = G / |grad G|), so the lines TERRAIN draws
// at whole counts sit at doubling distances from the shore, crowded at the edge and spreading
// out across the open exterior. COAST climbs coast_step metres at each one: the land rises
// away from the set and keeps rising, the far exterior stands as the high ground on the
// horizon, and every pocket between filaments is a hill whose ridge runs along its middle.
// Inside coast_beach metres of the set the lines crowd past a step a texel, and climbing
// all of them made the coast a wall of spikes: there the land eases flat instead, a beach
// for the fractal's edge, and the set's interior is the sea at the same level.
uniform float coast_step = 0.8;
uniform float coast_beach = 0.6;
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
// Overwritten from the theme by FractalGround.set_palette(); this default is only what
// a palette-less first frame draws.
uniform vec3 inside_colour : source_color = vec3(0.06, 0.07, 0.11);
// With the alpha-blend environment active, discard the filled set so the physical room
// shows through it. Discarding keeps the exterior in the fast opaque path instead of
// making the entire kilometre-scale ground plane blend every frame.
uniform float inside_passthrough = 0.0;
uniform float brightness = 1.0;
uniform vec3 pal0;
uniform vec3 pal1;
uniform vec3 pal2;
uniform vec3 pal3;
uniform vec3 pal4;

#define ART_GLOBAL
#include "res://shaders/styles.gdshaderinc"

varying vec3 v_world;

// CYCLE (main.gd, the COLOUR card): Fractint's colour cycling, the ramp sliding along the count
// so the bands flow. A global in cycles, the same one every mode reads; 0 is the ramp as before.
// It moves hue and keeps each texel's brightness (keep_luma, as points.gdshader): the ground
// fills the lower half of the view, and a whole field dimming and brightening is not ambient.
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

vec3 palette(float t) {
	float k = (palette_cycles > 1.5) ? t * palette_cycles : t;
	// Ping-pong, so the ramp never snaps; banded, the bands meet at a shared colour.
	vec3 base = ramp(abs(fract(k * 0.5) * 2.0 - 1.0));
	if (colour_cycle <= 0.0) return base;
	return keep_luma(ramp(abs(fract(k * 0.5 + colour_cycle) * 2.0 - 1.0)),
		dot(base, vec3(0.2126, 0.7152, 0.0722)));
}

int layer_of(int level) {
	return (level + level_rot) % num_levels;
}

// Unpacks ground.glsl's encode(): count as float32, distance as half, texture as 15-bit
// unorm, inside flag as the low bit. Keep the two in step.
vec4 fetch_layer(int layer, int mask, ivec2 a) {
	// tex_size is a power of two (1024, 2048), so the torus wrap is a mask: two's
	// complement makes it the positive modulo for negative indices too.
	ivec2 slot = a & ivec2(mask);
	uvec4 u = texelFetch(levels, ivec3(slot, layer), 0);
	return vec4(uintBitsToFloat(u.x | (u.y << 16u)), unpackHalf2x16(u.z).x,
		float(u.w & 1u), float(u.w >> 1u) / 32767.0);
}

// Whether level `level` can be sampled at the point: inside its reach around the viewer, and
// every texel a sample there fetches is filled. The widest fetch is relief_heights()'s 4x4
// block, base - 1 to base + 2 with base = floor(rel - 0.5), which stays inside [lo, hi) for
// rel in [lo + 1.5, hi - 1.5). Pure arithmetic, so walking up the levels with it is cheap.
bool in_window(int level, vec2 e0) {
	ivec2 vt = view_texel0 >> level;
	ivec2 rem = view_texel0 - (vt << level);
	vec2 rel = (vec2(rem) + view_frac0 + e0) / float(1 << level);
	vec4 c = clean_rect[level];
	return all(lessThan(abs(rel), vec2(float(tex_size) * 0.5 - slack - 1.0)))
		&& all(greaterThanEqual(rel, c.xy + 1.5)) && all(lessThan(rel, c.zw - 1.5));
}

// The finest level from `level` up whose sample at the point is usable, or max_level if
// none is. `ok` reports whether the returned level is usable, avoiding a duplicate check.
int usable_level(int level, vec2 e0, out bool ok) {
	int l = level;
	ok = false;
	for (int i = 0; i < 9; i++) {
		if (in_window(l, e0)) {
			ok = true;
			break;
		}
		if (l >= max_level) {
			break;
		}
		l++;
	}
	return l;
}

// Bilinear sample of a level at a level-0 texel coordinate (already relative to the
// viewer's texel, so the arithmetic below never sees a large number). Also returns, via
// `inside_window`, whether the point can be sampled there (in_window).
vec4 sample_level(int level, vec2 e0, out bool inside_window) {
	// Level-i texel coordinate of the point, split as (viewer texel >> i) + small float.
	ivec2 vt = view_texel0 >> level;
	ivec2 rem = view_texel0 - (vt << level);
	float sc = float(1 << level);
	vec2 f = (vec2(rem) + view_frac0 + e0) / sc - 0.5;   // -0.5: texel centres
	vec2 fl = floor(f);
	vec2 wl = f - fl;
	vec2 w = wl * wl * (3.0 - 2.0 * wl);
	ivec2 base = vt + ivec2(fl);
	inside_window = in_window(level, e0);
	int layer = layer_of(level);
	int mask = tex_size - 1;
	vec4 s00 = fetch_layer(layer, mask, base);
	vec4 s10 = fetch_layer(layer, mask, base + ivec2(1, 0));
	vec4 s01 = fetch_layer(layer, mask, base + ivec2(0, 1));
	vec4 s11 = fetch_layer(layer, mask, base + ivec2(1, 1));
	return mix(mix(s00, s10, w.x), mix(s01, s11, w.x), w.y);
}

// COAST's height in metres, before HEIGHT. A texel mixed with the set's interior carries its
// log2 DE of -40 in the mix, so the shore falls to 0 by itself and the interior is sea level.
// log2(1 + (d/b)^2) / 2 is log2(d/b) once d is a few beaches out, one step a line, and
// eases to flat with no crease at the shore; its steepest is 0.72 step/beach, at d = beach.
float coast_height(vec4 s) {
	float d = exp2(s.g) * wpu / coast_beach;
	return coast_step * 0.5 * log2(1.0 + d * d);
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
	else if (relief_mode == 4) h = coast_height(s) * relief_scale;
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

// The relief normal needs the bilinear sample one texel either side of the point in x
// and z. Those four and the centre share a 12-texel cross inside the 4x4 block (the four
// corners are never read). Streaming row-by-row avoids a 16-vec4 local array (keeping
// Adreno register occupancy high) and hoists layer_of(level) out of every fetch.
void relief_heights(int level, vec2 e0, out float hx0, out float hx1, out float hz0, out float hz1,
		out vec4 centre) {
	ivec2 vt = view_texel0 >> level;
	ivec2 rem = view_texel0 - (vt << level);
	float sc = float(1 << level);
	vec2 f = (vec2(rem) + view_frac0 + e0) / sc - 0.5;
	vec2 fl = floor(f);
	vec2 wl = f - fl;
	vec2 w = wl * wl * (3.0 - 2.0 * wl);
	ivec2 base = vt + ivec2(fl);
	int layer = layer_of(level);
	int mask = tex_size - 1;

	// Row j=0 (y = base.y - 1): only columns 0 and 1 are used (for sz0).
	vec4 m01 = mix(fetch_layer(layer, mask, base + ivec2(0, -1)),
		fetch_layer(layer, mask, base + ivec2(1, -1)), w.x);

	// Row j=1 (y = base.y): all 4 columns.
	vec4 r10 = fetch_layer(layer, mask, base + ivec2(-1, 0));
	vec4 r11 = fetch_layer(layer, mask, base + ivec2(0, 0));
	vec4 r12 = fetch_layer(layer, mask, base + ivec2(1, 0));
	vec4 r13 = fetch_layer(layer, mask, base + ivec2(2, 0));
	vec4 m10 = mix(r10, r11, w.x);
	vec4 m11 = mix(r11, r12, w.x);
	vec4 m12 = mix(r12, r13, w.x);

	// Row j=2 (y = base.y + 1): all 4 columns.
	vec4 r20 = fetch_layer(layer, mask, base + ivec2(-1, 1));
	vec4 r21 = fetch_layer(layer, mask, base + ivec2(0, 1));
	vec4 r22 = fetch_layer(layer, mask, base + ivec2(1, 1));
	vec4 r23 = fetch_layer(layer, mask, base + ivec2(2, 1));
	vec4 m20 = mix(r20, r21, w.x);
	vec4 m21 = mix(r21, r22, w.x);
	vec4 m22 = mix(r22, r23, w.x);

	// Row j=3 (y = base.y + 2): only columns 0 and 1 are used (for sz1).
	vec4 m31 = mix(fetch_layer(layer, mask, base + ivec2(0, 2)),
		fetch_layer(layer, mask, base + ivec2(1, 2)), w.x);

	hx0 = height_of(mix(m10, m20, w.y), level, true);
	hx1 = height_of(mix(m12, m22, w.y), level, true);
	hz0 = height_of(mix(m01, m11, w.y), level, true);
	hz1 = height_of(mix(m21, m31, w.y), level, true);
	centre = mix(m11, m21, w.y);
}

// The displaced big shape at a level-0 texel offset from the viewer, at a fractional level
// blended continuously between its two neighbours so no ring of distance pops. The grain
// is per-texel and scales with the level's texel, so displacing it at coarse levels raised
// a field of metre-high spikes on the horizon; it stays a shading term.
// A level with texels still queued at the point is passed over for the next coarser one,
// as the fragment does.
float shape_height(vec2 e0p, float lod, out bool inside) {
	float lc = clamp(lod, float(min_level), float(max_level));
	int la = int(lc);
	float k = lc - float(la);
	bool dummy_ok;
	int lu = usable_level(la, e0p, dummy_ok);
	if (lu != la) k = 0.0;
	la = lu;
	int lb = min(la + 1, max_level);
	bool ib;
	vec4 a = sample_level(la, e0p, inside);
	float ha = height_of(a, la, false);
	if (k <= 0.0 || lb == la || !in_window(lb, e0p)) return ha;
	vec4 b = sample_level(lb, e0p, ib);
	return mix(ha, height_of(b, lb, false), k);
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
		// Snap the vertex to the centre of a texel of the level its spacing matches, so it
		// sits on a fixed world point. The rings slide with the viewer, and without this
		// every triangle re-interpolated between new sample points each frame and the
		// whole surface swam as you walked. Ring spacing is at least one texel of this
		// level, so neighbours never cross.
		float sc = float(1 << l);
		ivec2 rem = view_texel0 - ((view_texel0 >> l) << l);
		vec2 t = (vec2(rem) + view_frac0 + e0) / sc;
		vec2 e0s = (floor(t) + 0.5) * sc - vec2(rem) - view_frac0;
		vec2 ws = (transpose(mat2(rot.xy, rot.zw)) * e0s) * (wpu * texel0);
		VERTEX += transpose(mat3(MODEL_MATRIX)) * vec3(ws.x - w.x, 0.0, ws.y - w.y);
		// The displaced height is a function of the world point and the floor reference,
		// never of where the eye is. The rings are centred on the eye, and turning your
		// head swings the eye about 9 cm round the neck, so every glance slid them across
		// the field; picking the height's level by distance from the EYE then resampled
		// the same world point at another level, and the texels the snapped vertices
		// landed on changed too, so the bumps rose and fell as you looked about. Measured
		// from the reference, which holds still while you turn (REF_HOLD_M), the level of
		// every point is fixed. Half a level coarser than the mesh spacing, smoothed by
		// sample_level's C1 weights, is a field the triangles can follow wherever their
		// corners land: a 90 degree turn in place moved the surface 2-3 mm on average
		// against 6-50 mm before, and a full level coarser bought almost nothing more while
		// flattening the filament cliffs. The per-texel detail stays in the shading.
		float tm = texel0 * wpu;
		float d_ref = length(e0s - level_e0) * tm;
		bool inside;
		float hv = shape_height(e0s, max(lod_win, log2((d_ref + ref_hold) * mesh_spacing / tm) + 0.5), inside);
		// The same field at the reference itself, so the floor under a still viewer is at 0.
		bool dh;
		float lod_rw = log2(max(max(abs(level_e0.x), abs(level_e0.y)), 1e-3) / (0.5 * R));
		float h_ref = shape_height(level_e0, max(lod_rw, log2(ref_hold * mesh_spacing / tm) + 0.5), dh);
		float h = inside ? hv - h_ref : 0.0;
		// Local up, so the mirrored sky displaces toward the viewer as a reflection would.
		VERTEX.y += h;
	}
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

// Lighting normal and Laplacian from the four neighbour heights of one level. The heights
// are one texel apart along the FRACTAL's axes (e0 = M * w), so the gradient has to go back
// through M's transpose to be a world-space slope; without it the hillshade turned with the
// map under a twist while the light and the displaced mesh stayed put.
void relief_normal(mat2 m, int level, float hx0, float hx1, float hz0, float hz1, float hc,
		out vec3 n, out float lap) {
	float tm = float(1 << level) * texel0 * wpu;   // one texel of that level, in metres
	// COAST's slopes are real metres of hillside, and 2.5x of them turned every hill face
	// black or white: 1.3 keeps a little hillshade emphasis.
	float con = relief_mode == 4 ? 1.3 : relief_contrast;
	vec2 g = transpose(m) * vec2(hx1 - hx0, hz1 - hz0) * con / (2.0 * tm);
	n = normalize(vec3(-g.x, 1.0, -g.y));
	lap = (hx1 + hx0 + hz1 + hz0 - 4.0 * hc) / tm;
}

// NEAR: the escape count per pixel, where the screen is finer than the finest data the
// clipmap can hold there. At 1024 texels a level, a level's window reaches only so far, so
// the headset's eye buffer sees texels 10-20 pixels across near the set and every line built
// from the bilinear count wobbles at that size. This is ground.glsl's float32 escape(), the
// same maths and the same four outputs, run in the fragment. Keep the two in step.
//
// Cost control: a pixel runs it only when its texel is coarser than the pixel, the data
// says the set is within a few texels (the count is smooth further out and the bilinear is
// already exact to the eye), and the texel's own count is under near_iter, the budget. A
// pixel the budget cannot settle keeps the texel value.
uniform int near_iter = 0;              // per-pixel iteration budget; 0 is off
uniform vec4 near_c = vec4(0.0);        // the viewer's fractal x hi, x lo, y hi, y lo
uniform int near_formula = 0;
uniform int near_julia = 0;
uniform vec2 near_julia_c = vec2(0.0);
uniform int near_max_iter = 256;
uniform float near_tex_on = 1.0;
uniform float near_stalk = 0.0;
uniform float near_stalk_width = 0.05;

vec2 n_cmul(vec2 a, vec2 b) { return vec2(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x); }

// ground.glsl iterate() and degree_of(), formula order as FORMULA_NAMES.
float n_degree(int f) { return f == 6 ? 3.0 : (f == 7 ? 4.0 : 2.0); }

void n_iterate(int f, inout vec2 z, inout vec2 dz, vec2 c, vec2 addC) {
	vec2 zf = z;
	if (f == 1) zf = abs(z);
	else if (f == 2) zf = vec2(z.x, -z.y);
	else if (f == 4) zf = vec2(abs(z.x), z.y);
	if (f == 6) {
		dz = 3.0 * n_cmul(n_cmul(z, z), dz) + addC;
		z = n_cmul(n_cmul(z, z), z) + c;
		return;
	}
	if (f == 7) {
		vec2 z2 = n_cmul(z, z);
		dz = 4.0 * n_cmul(n_cmul(z2, z), dz) + addC;
		z = n_cmul(z2, z2) + c;
		return;
	}
	dz = 2.0 * n_cmul(zf, dz) + addC;
	vec2 sq = n_cmul(zf, zf);
	if (f == 3) sq.x = abs(sq.x);
	else if (f == 4) sq.y = -sq.y;
	else if (f == 5) sq = vec2(abs(sq.x), -abs(sq.y));
	z = sq + c;
}

// ok false: the budget ran out before the orbit settled either way.
vec4 near_escape(vec2 c, vec2 z0, int cap, out bool ok) {
	const float ESC2 = 65536.0;
	const float LOG_ESC = 5.5451774;
	vec2 z = z0;
	vec2 dz = vec2(1.0, 0.0);
	vec2 addC = near_julia != 0 ? vec2(0.0) : vec2(1.0, 0.0);
	float ac = length(c);
	float m2 = dot(z, z);
	float sum = 0.0, sumPrev = 0.0, count = 0.0;
	float minR2 = 1e30;
	float minAxis = 1e30;
	float deg = n_degree(near_formula);
	int n = 0;
	int lim = min(cap, near_max_iter);
	for (int i = 0; i < lim; i++) {
		vec2 zp = z;
		n_iterate(near_formula, z, dz, c, addC);
		m2 = dot(z, z);
		minR2 = min(minR2, m2);
		n = i + 1;
		if (near_tex_on > 0.5 && i > 1) {
			minAxis = min(minAxis, min(abs(z.x), abs(z.y)));
			float zp2 = dot(zp, zp);
			float azp2 = near_formula == 6 ? zp2 * sqrt(zp2) : (near_formula == 7 ? zp2 * zp2 : zp2);
			float lo = abs(azp2 - ac);
			float hi = azp2 + ac;
			float t = (sqrt(m2) - lo) / max(1e-12, hi - lo);
			sumPrev = sum;
			sum += clamp(t, 0.0, 1.0);
			count += 1.0;
		}
		if (m2 > ESC2) break;
	}
	float avg1 = count > 0.0 ? sum / count : 0.0;
	float avg0 = count > 1.0 ? sumPrev / (count - 1.0) : avg1;
	if (m2 <= ESC2) {
		// Inside only if it ran the whole max_iter, as the fill decides it.
		ok = lim >= near_max_iter;
		return vec4(float(near_max_iter), -40.0, 1.0, clamp(sqrt(minR2), 0.0, 1.0));
	}
	ok = true;
	float lm = log(m2) * 0.5;
	float s = float(n) - log2(lm / LOG_ESC) / log2(deg);
	float de = sqrt(m2) * lm / max(1e-20, length(dz));
	float tia = mix(avg0, avg1, clamp(s - floor(s), 0.0, 1.0));
	float st = 1.0 - clamp(minAxis / max(1e-4, near_stalk_width), 0.0, 1.0);
	return vec4(s, log2(max(de, 1e-30)), 0.0, mix(tia, st, near_stalk));
}

// STYLE on the ground. styles.gdshaderinc's art_colour draws an object by its folds and a
// world-space pattern, and a flat floor has neither: pencil came out blank paper, circuit a
// PCB texture that ignored the set, and neon and toon turned the filaments to mush. Here
// every line comes from the fractal itself:
// - count contours, at a step of 2^L counts picked per pixel so the lines stay about
//   `gap` pixels apart however tightly the bands crowd. The odd lines fade out as the step
//   doubles, so the hand-over between steps never shows.
// - the set's edge, from the distance estimate the fill stores (s.g, log2 fractal units),
//   in pixels: one pixel sharp at any zoom and at any distance, filaments included, where
//   the count is already chaotic.
// - the orbit trap (s.a) for structure inside the set, where the count is flat.

// An anti-aliased line of `wpx` pixels on every whole number of `key`, which changes by
// `wk` a pixel.
float gline(float key, float wk, float wpx) {
	float d = abs(fract(key + 0.5) - 0.5) / max(wk, 1e-6);
	return clamp(0.5 * wpx + 0.5 - d, 0.0, 1.0);
}

// Contours of `key` at the adaptive step, about `gap` pixels apart. idx: the line's index at
// the coarser of the two steps in play, for picking a colour that does not flicker as the
// step changes. Fades to nothing where the key is chaos (a step past 2^6 counts).
float gcontours(float key, float wk, float gap, float wpx, float lmin, out float idx) {
	float lv = max(log2(max(wk * gap, 1e-6)), lmin);
	float L = floor(lv);
	float st = exp2(L);
	float q = key / st;
	float c = gline(q, wk / st, wpx);
	float n = floor(q + 0.5);
	idx = floor(n * 0.5);
	c *= mod(n, 2.0) > 0.5 ? 1.0 - fract(lv) : 1.0;
	return c * (1.0 - smoothstep(5.0, 7.0, lv));
}

const vec3 LUMA = vec3(0.2126, 0.7152, 0.0722);

// nat: the natural colour (palette, texture, relief light). inside 0..1. de_px: pixels to the
// set (0 inside). wk: fwidth(s.r).
vec3 ground_art(vec4 s, vec3 nat, float v, float wk, float inside, float de_px, float lit,
		float ao, vec3 pos, float dist) {
	float out_k = 1.0 - inside;
	// Slow escapers shadow a repelling cycle, |dz| grows exponentially and the DE is tiny:
	// whole dendrite zones sit within a pixel of the set. They are `dense`, drawn as a fill,
	// and `edge` is the line round them, a pixel or two out, plus the inside mask's own edge.
	float dense = clamp(1.5 - de_px, 0.0, 1.0) * out_k;
	float edge = smoothstep(0.6, 1.6, de_px) * (1.0 - smoothstep(1.8, 3.4, de_px)) * out_k;
	// Only where the DE is smooth across the pixel: inside a dendrite zone it jumps from 0 to a
	// few pixels between neighbours, and lines there were a bright speckle that bloomed to haze.
	edge *= 1.0 - smoothstep(0.6, 1.5, fwidth(de_px));
	float iw = fwidth(inside);
	float iedge = iw > 1e-4 ? clamp(1.0 - abs(inside - 0.5) / iw, 0.0, 1.0) : 0.0;
	edge = max(edge, iedge);
	float trap = s.a * 10.0;                                       // orbit-trap rings inside
	float wt = max(fwidth(trap), 1e-6);
	float tone = clamp(dot(nat, LUMA) * 1.25, 0.0, 1.0);
	float idx;
	if (art_style == 1) {
		// No neon_far fade: the ground's fog already ends it, and the two stacked dimmed the
		// middle distance twice.
		float fade = 1.0;
		float c = gcontours(s.r, wk, 9.0, 1.4, 0.0, idx) * out_k;
		float pick = fract(idx * 0.618);
		vec3 hue = pick < 0.45 ? neon_a : (pick < 0.8 ? neon_b : neon_c);
		// The set glows from its edge: a hot core and a wide soft halo over the filaments.
		float halo = exp2(-de_px / 3.0) * out_k;
		float rings = gline(trap, wt, 1.2) * (1.0 - smoothstep(0.08, 0.3, wt)) * inside;
		vec3 body = neon_body * (0.6 + 3.0 * lit + 1.2 * ao) + neon_b * 0.03 * tone;
		// The edge takes the orbit trap's texture, so a zone of filaments packed closer than a
		// pixel still shows its grain instead of one white sheet.
		vec3 ecol = mix(neon_c, neon_b, smoothstep(0.25, 0.75, s.a)) * (0.03 + 0.12 * s.a);
		vec3 glow = hue * c * (1.0 - dense) + ecol * dense + neon_a * (edge * 0.8 + halo * 0.06)
			+ neon_c * rings * 0.35;
		return body + glow * neon_gain * fade;
	}
	if (art_style == 2) {
		// Flat cels of the theme's own colours: the palette coordinate quantised in steps that
		// widen where the bands crowd, two light steps from the relief, ink on the cel edges
		// and a heavy outline round the set.
		const float N = 6.0;
		float kv = v * N;
		float wv = fwidth(kv);
		float lv = max(log2(max(wv * 10.0, 1e-6)), 0.0);
		float st = exp2(floor(lv));
		vec3 cel = palette((floor(kv / st) + 0.5) * st / N);
		float fl = max(fwidth(lit), 1e-4);
		float shade = mix(0.55, 1.0, smoothstep(0.3 - fl, 0.3 + fl, lit)) * mix(0.8, 1.0, step(0.75, ao));
		float in_band = floor(clamp(s.a, 0.0, 0.999) * 3.0);
		vec3 icel = inside_colour * (1.0 + 0.35 * in_band);
		vec3 col = mix(cel, icel, step(0.5, inside)) * shade;
		float ink = gcontours(kv, wv, 10.0, 1.3, 0.0, idx) * (1.0 - smoothstep(4.0, 6.0, lv)) * out_k;
		ink = max(ink, gline(trap * 0.3, wt * 0.3, 1.0) * inside * (1.0 - smoothstep(0.1, 0.3, wt)) * 0.6);
		// Past where the cels hold (lv high) the filaments are drawn in ink by their distance.
		ink = max(max(ink, edge), dense * 0.85);
		return mix(col, vec3(0.03, 0.025, 0.04), ink);
	}
	if (art_style == 3) {
		// Graphite contour hatching: the count's own level lines are the strokes, more of them
		// where the picture is dark, and the orbit trap's rings cross them in the deepest shade.
		float dark = 1.0 - tone;
		float idx2;
		float a = gcontours(s.r, wk, 9.0, 1.0, 0.0, idx) * smoothstep(0.1, 0.3, dark);
		float b = gcontours(s.r, wk, 4.5, 0.9, -1.0, idx2) * smoothstep(0.4, 0.62, dark);
		float x = gline(trap * 2.0, wt * 2.0, 0.9) * (1.0 - smoothstep(0.1, 0.35, wt * 2.0))
			* smoothstep(0.62, 0.85, dark);
		float pres = 0.7 + 0.3 * hash2(vec2(idx, 7.0));
		float xi = gline(trap, wt, 1.0) * (1.0 - smoothstep(0.1, 0.35, wt));
		float ink = max(max(a * pres, b * 0.8), x * 0.85) * out_k + max(x, xi) * inside * 0.9;
		ink = max(ink, inside * 0.5);                                  // a graphite wash in the set
		ink = max(ink, edge * 0.95);
		ink = max(ink, dense * (0.62 + 0.3 * s.a));                    // filaments, soft
		vec3 sheet = paper * mix(1.0, 0.86, dark * 0.6);
		return mix(sheet, graphite, ink);
	}
	// Circuit: copper traces along the count's level lines, a via wherever a trace crosses an
	// orbit-trap ring, a gold rail round the set, and the set itself a dense chip of fine
	// traces on a dark die.
	float t = gcontours(s.r, wk, 11.0, 2.2, 0.0, idx) * out_k;
	float tr2 = gline(trap, wt, 6.0) * (1.0 - smoothstep(0.08, 0.25, wt));
	float via = step(0.5, t) * tr2;
	float led = via * step(0.85, hash2(vec2(idx, floor(trap))));
	float shade = 0.25 * ao + 0.85 * lit;
	vec3 board = vec3(0.025, 0.15, 0.07) * (0.45 + shade) * (0.8 + 0.4 * tone);
	vec3 copper = vec3(0.85, 0.52, 0.2) * (0.35 + shade);
	vec3 gold = vec3(1.0, 0.86, 0.45) * (0.5 + shade);
	vec3 cb = mix(board, copper, t);
	cb = mix(cb, gold, via);
	cb += vec3(0.25, 1.6, 0.45) * led;
	// The die: the shared circuit pattern in world metres, fine.
	float px = max(sqrt(length(dFdx(pos.xz)) * length(dFdy(pos.xz))), 1e-9);
	float per = exp2(ceil(log2(px * 14.0)));
	vec3 chip = circuit(pos.xz, per, px);
	vec3 die = mix(vec3(0.02, 0.022, 0.03), copper * 0.3, chip.x * 0.7) + vec3(0.25, 1.6, 0.45) * chip.z * 0.4;
	cb = mix(cb, die, step(0.5, inside));
	cb = mix(cb, copper * (0.25 + 0.35 * s.a), dense);
	cb = mix(cb, gold, edge);
	return cb;
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
	float k = fract(lod);
	// A level whose texels here are still queued for the fill holds the far side of its
	// window or another scale in those slots. Pass over it to the next coarser level that is
	// filled, without a blend: a patch a level blurrier until the fill lands, never one of
	// somewhere else. Same for l1, which then drops out of the blend.
	bool in0;
	int lu = usable_level(l0, e0, in0);
	if (lu != l0) k = 0.0;
	l0 = lu;
	int l1 = min(l0 + 1, max_level);
	bool in1 = l1 != l0 && in_window(l1, e0);
	if (!in1) k = 0.0;
	// Relief needs a 12-texel cross at l0 that contains this sample: fetch it once, up front.
	bool relief_on = relief_mode != 0 || bump_strength > 0.0;
	float hx0 = 0.0;
	float hx1 = 0.0;
	float hz0 = 0.0;
	float hz1 = 0.0;
	vec4 sa;
	if (relief_on) {
		relief_heights(l0, e0, hx0, hx1, hz0, hz1, sa);
	} else {
		bool d0;
		sa = sample_level(l0, e0, d0);
	}
	// When blending normals to l1 (kn > 0), fetch l1's relief block once and reuse its centre
	// as sb instead of calling sample_level(l1) and then re-fetching the same 4 texels later.
	float kn = relief_on ? smoothstep(0.75, 1.0, k) : 0.0;
	bool need_n1 = kn > 0.0 && l1 != l0 && in1;
	float a0 = 0.0, a1 = 0.0, b0 = 0.0, b1 = 0.0;
	vec4 sb = sa;
	if (need_n1) {
		relief_heights(l1, e0, a0, a1, b0, b1, sb);
	} else if (k > 0.0) {
		bool d1;
		sb = sample_level(l1, e0, d1);
	}
	vec4 s = mix(sa, sb, k);
	bool valid = in0;

	// NEAR (above): per-pixel escape where a texel spans more than a pixel near the set.
	if (near_iter > 0) {
		float fpg_n = sqrt(length(dFdx(e0)) * length(dFdy(e0)));
		// Octaves the sampled texel is coarser than this pixel.
		float mag = float(l0) + k - log2(max(fpg_n, 1e-9));
		float ibn = clamp(s.b, 0.0, 0.999);
		float de_tex = exp2((s.g + 40.0 * ibn) / (1.0 - ibn)) / (texel0 * exp2(float(l0)));
		bool near_set = ibn > 0.001 || de_tex < 4.0;
		// A texel on the set's edge can only be settled per pixel when the budget reaches
		// max_iter; below it every such pixel spent the whole budget and kept the texel.
		bool mixed = s.b > 0.001 && s.b < 0.999;
		bool cheap = mixed ? near_max_iter <= near_iter : s.r < float(near_iter);
		float c_ratio = max(1.0, length(near_c.xz)) / (texel0 * max(fpg_n, 1e-9));
		// Only where a texel spans two pixels or more: below that the bilinear is already
		// close, and the headset paid full price for a change nobody could see.
		if (mag > 0.75 && near_set && cheap && c_ratio < 4194304.0) {
			vec2 dc = e0 * texel0;
			vec2 cp = vec2(near_c.x + (near_c.y + dc.x), near_c.z + (near_c.w + dc.y));
			bool ok;
			vec4 r = near_julia != 0 ? near_escape(near_julia_c, cp, near_iter, ok)
				: near_escape(cp, vec2(0.0), near_iter, ok);
			if (ok) s = mix(s, r, smoothstep(0.75, 1.25, mag));
		}
	}

	// How much per-texel detail this pixel can still resolve. Measured as iteration counts
	// per pixel, which is what the contour fade below has always used: past about one
	// count per pixel the bands are crowded tighter than the screen can show, and the
	// orbit texture and the specular on top of it stop being detail and start being
	// noise that lands somewhere different every frame. That is the shimmer in the
	// distance.
	//
	// Do NOT derive this from dFdx of the texel offset. That was the first attempt: at
	// grazing angles near the horizon the derivative of a level-0 texel coordinate runs
	// away, the damping saturated everywhere at once, and the whole ground rendered as
	// one flat plane. fwidth of the count is bounded by the data.
	float wcount = fwidth(s.r);
	float sharp = 1.0 - 0.7 * smoothstep(0.2, 1.6, wcount);

	// Colour: log of the count through the palette (Frax's ramp), texture as a brightness
	// modulation, the interior from its own orbit-trap channel.
	float v = log2(1.0 + s.r) * colour_freq + colour_offset;
	vec3 col = palette(v);
	col *= mix(1.0, 0.45 + 1.1 * s.a, texture_strength * sharp);
	float inside = clamp(s.b, 0.0, 1.0);
	// PASSTHROUGH_DISCARD (injected by FractalGround only when inside_passthrough is active,
	// keeping discard out of the default shader so Adreno Early-Z/LRZ stays enabled).
	col = mix(col, inside_colour * (0.4 + 1.2 * s.a), inside);

	// Relief: a height from the data and its normal from the neighbouring texels of the
	// level actually sampled, so slopes carry per-texel detail up close and coarsen with
	// distance the way terrain does. Lit by one fixed directional light.
	// STYLE's light: flat ground in a fixed sun unless relief says otherwise.
	float lit_art = 0.75;
	float ao_art = 1.0;
	if (relief_on) {
		mat2 m = mat2(rot.xy, rot.zw);
		vec3 n;
		float lap;
		relief_normal(m, l0, hx0, hx1, hz0, hz1, height_of(sa, l0, true), n, lap);
		if (need_n1) {
			vec3 n1;
			float lap1;
			relief_normal(m, l1, a0, a1, b0, b1, height_of(sb, l1, true), n1, lap1);
			n = normalize(mix(n, n1, kn));
			lap = mix(lap, lap1, kn);
		}
		vec3 L = normalize(light_dir);
		float diff = max(dot(n, L), 0.0);
		float spec = 0.0;
		if (sharp > 0.0 && inside < 1.0) {
			vec3 V = normalize(CAMERA_POSITION_WORLD - v_world);
			float ndh = max(dot(normalize(L + V), n), 0.0);
			float s2 = ndh * ndh;
			float s4 = s2 * s2;
			float s8 = s4 * s4;
			spec = (s8 * s8 * s8) * 0.12 * sharp;
		}
		// Cavity: a positive Laplacian is a hollow, and hollows sit in shade. This is
		// what stops a terrain read like a bas-relief with a torch on it.
		float cavity = 1.0 - 0.4 * clamp(lap * 0.6, 0.0, 1.0);
		col = (col * (0.25 + 0.75 * diff) + spec * (1.0 - inside)) * cavity;
		lit_art = diff;
		ao_art = cavity;
	}

	// Contour lines at every whole iteration count, as a topographic map draws its
	// heights; every fourth is heavier. They fade where the bands crowd past a pixel,
	// or the far distance would just go dark.
	if (relief_mode == 3) {
		float band = s.r;
		float wd = wcount;   // fwidth(s.r), already taken above
		float f = min(fract(band), 1.0 - fract(band));
		float line = 1.0 - smoothstep(0.0, wd * 1.2 + 0.015, f);
		float f4 = min(fract(band * 0.25), 1.0 - fract(band * 0.25)) * 4.0;
		float heavy = 1.0 - smoothstep(0.0, wd * 2.0 + 0.03, f4);
		float fade = 1.0 - smoothstep(0.12, 0.35, wd);
		float ink = clamp(0.45 * line + 0.35 * heavy, 0.0, 0.7) * fade * (1.0 - inside);
		col *= 1.0 - ink;
	}

	// COAST: a contour line at every step of height, heavier every fourth, as TERRAIN draws
	// one at every count: the same lines, now true to the ground's height. The beach and the
	// sea carry none.
	if (relief_mode == 4) {
		float hc = coast_height(s);
		float band = hc / coast_step;
		float wd = fwidth(band);
		float f = min(fract(band), 1.0 - fract(band));
		float line = 1.0 - smoothstep(0.0, wd * 1.2 + 0.01, f);
		float f4 = min(fract(band * 0.25), 1.0 - fract(band * 0.25)) * 4.0;
		float heavy = 1.0 - smoothstep(0.0, wd * 2.0 + 0.02, f4);
		float fade = (1.0 - smoothstep(0.15, 0.4, wd)) * smoothstep(0.1, 0.5, band);
		col *= 1.0 - clamp(0.35 * line + 0.3 * heavy, 0.0, 0.6) * fade * (1.0 - inside);
	}

	if (art_style > 0) {
		// Pixels to the set: the stored distance estimate over the pixel's footprint, both in
		// fractal units. Inside the set the estimate is meaningless and the mask takes over.
		// The footprint's geometric mean, not its long side: at a grazing angle the long side
		// runs metres down the view and called every filament zone solid edge.
		float fpg = sqrt(length(dFdx(e0)) * length(dFdy(e0)));
		// Inside texels store log2 DE = -40, and the sample mixed them in with the same weights
		// as s.b, which dragged every pixel near a speck of the set to zero distance. Undo the
		// mix to get the escaped texels' own mean.
		float ib = clamp(s.b, 0.0, 0.999);
		float g_out = (s.g + 40.0 * ib) / (1.0 - ib);
		float de_px = exp2(g_out) / max(texel0 * fpg, 1e-30);
		col = ground_art(s, col, v, wcount, inside, de_px, lit_art, ao_art, v_world, dist);
	}
	col *= brightness;
	float fog = smoothstep(fog_end * 0.55, fog_end, dist);
	if (!valid) fog = 1.0;
	ALBEDO = mix(col, fog_colour, fog);
}
