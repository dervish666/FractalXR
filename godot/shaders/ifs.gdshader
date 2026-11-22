shader_type spatial;
render_mode unshaded, cull_back, fog_disabled, shadows_disabled, skip_vertex_transform;

// The IFS sculpture's frames: one instanced seed polyhedron per node of the assembly.
// Two things move here so the script never rewrites the instance buffer for either of them,
// the palette drifting through the shape and each generation growing out of the frame that
// made it. Breathing and morphing do rebuild, because they change the maps themselves.
//
// INSTANCE_CUSTOM is (level / levels_built, radial distance / the outermost, birth, spare).
// COLOR.rgb is not a colour here: it packs the parent's origin in the instance's own mesh
// space, the one per-instance slot left once INSTANCE_CUSTOM is full. It is packed into
// [0, 1] rather than written raw because an instance colour is a colour to the renderer and
// may be stored normalised. The axis shade therefore rides in UV.x instead of vertex colour.

uniform sampler2D ramp : filter_linear, repeat_enable;
uniform float anim_t = 0.0;        // seconds, from FractalIFS.tick
uniform float born_at = -10000.0;  // anim_t at the last rebuild that was allowed to grow in
uniform float grow_s = 0.6;        // seconds for one generation to reach full size
uniform float grow_span = 0.0;     // seconds between the first generation and the last
// Instances born before this (in INSTANCE_CUSTOM.z units) are already grown. 0 grows the
// whole shape; a morph landing on a deeper rung grows only the generation it adds.
uniform float grow_from = 0.0;
// The seed cross-fade of a morph between two frames: UV.y picks the group, and each group is
// scaled about the frame's centre. Outside a morph the mesh is all group 0 at scale 1.
uniform float seed_scale0 = 1.0;
uniform float seed_scale1 = 0.0;
uniform float scroll = 0.02;       // palette turns per second
// CYCLE (main.gd, the COLOUR card), in palette turns, on top of the scroll above. A global every
// mode reads; 0, the default, leaves the colour exactly as before.
global uniform float colour_cycle;
uniform float radius_mix = 0.45;   // colour coordinate: level at 0, radial distance at 1
uniform float origin_span = 4.0;   // construction units the packed parent origin covers
uniform float brightness = 1.0;
// Multiply the level and radius channels. 1 except for the half second after a rebuild at
// another rung, where they hold every frame's colour still while the normalisation catches up.
uniform float level_gain = 1.0;
uniform float radius_gain = 1.0;
// Per echo, set on the node rather than the shared material, so forty copies of the sculpture
// are forty different points on the palette and one material. The hero leaves both at their
// defaults. Phase is in palette turns; gain dims a far echo so the hero stays the subject.
instance uniform float echo_phase = 0.0;
instance uniform float echo_gain = 1.0;
// An echo's own life, all of it on the GPU so the CPU writes nothing per frame however many
// echoes there are. IfsEchoes sets these once per placement and once per shape swap, and
// advances echo_t; the hero leaves echo_live at 0 and runs none of it.
//   echo_centre  the echo's centre in world space, what it spins and breathes about
//   echo_spin    world axis (xyz) and rad/s (w)
//   echo_wander  world amplitude in metres (xyz) and base rad/s (w), a slow Lissajous drift
//   echo_life    clock offset s (x), breathe amplitude (y) and rad/s (z), palette drift turns/s (w)
//   echo_swap    echo_t the shape began to fold away (x) and the next one began to grow (y)
// IfsEchoes.reach() is the bound on all of this that the placement keeps clear; change one
// and change the other.
instance uniform float echo_live = 0.0;
instance uniform vec3 echo_centre = vec3(0.0);
instance uniform vec4 echo_spin = vec4(0.0, 1.0, 0.0, 0.0);
instance uniform vec4 echo_wander = vec4(0.0);
instance uniform vec4 echo_life = vec4(0.0);
instance uniform vec2 echo_swap = vec2(1e9, -1e4);
uniform float echo_t = 0.0;        // seconds, the echoes' clock: stops with MOTION off
uniform float swap_s = 1.6;        // seconds for one generation to fold or grow
uniform float swap_span = 2.4;     // seconds between the outermost generation and the root
uniform float echo_glow = 1.5;     // gain swing per unit of breathe, so a swell also brightens
// V1: architectural metallic/crystal shading and generation energy pulse.
uniform vec3 light_dir = vec3(0.45, 0.82, 0.35);
uniform float sheen = 0.72;
uniform float gloss = 0.55;
uniform float rim_gain = 0.52;
// Off unless MOTION is on (fractal_ifs.gd tick), and slow: one swell about every 20 s.
uniform float pulse_gain = 0.0;

#define ART_GLOBAL
#include "res://shaders/styles.gdshaderinc"

varying float v_u;
varying float v_shade;
// STYLE's inputs: the frame's mesh-space position and normal (fixed to the frame, whatever its
// size, so a pattern sits on it) and the axis shade alone, as STYLE's sun.
varying vec3 v_pos;
varying vec3 v_n;
varying float v_axis;
// V1/V2/V9: (level, radius), world position & normal, and view-space key light.
varying vec2 v_meta;
varying vec3 v_world;
varying vec3 v_wnorm;
varying flat vec3 v_light;

void vertex() {
	float level = INSTANCE_CUSTOM.x;
	float radius = INSTANCE_CUSTOM.y;
	float birth = INSTANCE_CUSTOM.z;
	// Grow-in. A generation scales up out of its parent's origin, so a child reads as pushed
	// out of the frame that made it rather than fading in where it will end up. mix() of two
	// points is affine and so is MODEL_MATRIX, which is why doing this in mesh space and
	// letting the model matrix carry it out gives the same answer as doing it in world space
	// without needing the node transform here.
	float late = birth - grow_from;
	float g = late < 0.0 ? 1.0 : clamp((anim_t - born_at - late * grow_span) / grow_s, 0.0, 1.0);
	g = g * g * (3.0 - 2.0 * g);
	// A shape swap: the old shape folds back into its parents outermost generation first,
	// then the new one grows out root first, the hero's own grow-in run at an echo's pace.
	if (echo_live > 0.5) {
		float g_out = 1.0 - clamp((echo_t - echo_swap.x - (1.0 - birth) * swap_span) / swap_s, 0.0, 1.0);
		float g_in = clamp((echo_t - echo_swap.y - birth * swap_span) / swap_s, 0.0, 1.0);
		float gs = min(g_out, g_in);
		g *= gs * gs * (3.0 - 2.0 * gs);
	}
	vec3 parent = (COLOR.rgb * 2.0 - 1.0) * origin_span;
	vec3 local_v = VERTEX * (UV.y < 0.5 ? seed_scale0 : seed_scale1);
	local_v = mix(parent, local_v, g);
	v_pos = local_v;
	v_n = NORMAL;
	v_axis = UV.x;
	v_meta = vec2(level, radius);
	float swell = 0.0;
	vec3 w = (MODEL_MATRIX * vec4(local_v, 1.0)).xyz;
	vec3 wn = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	if (echo_live > 0.5) {
		// In world space about the echo's centre, avoiding inverse(mat3(MODEL_MATRIX)) via
		// skip_vertex_transform.
		float t = echo_t + echo_life.x;
		swell = echo_life.y * sin(echo_life.z * t);
		vec3 rel = (w - echo_centre) * (1.0 + swell);
		vec3 k = echo_spin.xyz;
		float a = echo_spin.w * t;
		float c = cos(a);
		float s = sin(a);
		rel = rel * c + cross(k, rel) * s + k * dot(k, rel) * (1.0 - c);
		wn = wn * c + cross(k, wn) * s + k * dot(k, wn) * (1.0 - c);
		vec3 wob = echo_wander.xyz * sin(echo_wander.w * t * vec3(1.0, 1.37, 0.71) + vec3(0.0, 2.1, 4.2));
		w = echo_centre + rel + wob;
	}
	// Level and radius together. Level alone bands the palette by generation with a hard
	// line between bands, radius alone ignores the recursion that built the shape.
	v_u = mix(level * level_gain, radius * radius_gain, radius_mix) + anim_t * scroll + echo_phase
		+ echo_life.w * echo_t;
	// Its own line: FractalIFS._variant anchors on the one above, whole.
	v_u += colour_cycle;
	v_shade = UV.x * echo_gain * (1.0 + echo_glow * swell);
	v_world = w;
	v_wnorm = wn;
	v_light = normalize((VIEW_MATRIX * vec4(normalize(light_dir), 0.0)).xyz);
	vec3 view_v = (VIEW_MATRIX * vec4(w, 1.0)).xyz;
	VERTEX = view_v;
	NORMAL = normalize((VIEW_MATRIX * vec4(wn, 0.0)).xyz);
	POSITION = PROJECTION_MATRIX * vec4(view_v, 1.0);
}

void fragment() {
	// fract() keeps the drifting coordinate precise after minutes of scrolling; the ramp is
	// built cyclic, first colour repeated at 1.0, so the wrap is not a seam.
	float echo_k = v_shade / max(v_axis, 1e-3);
	vec3 n = normalize(NORMAL);
	if (dot(n, VIEW) < 0.0) n = -n;
	if (art_style >= 1 && art_style <= 4) {
		float u = fract(v_u);
		// AXIS_SHADE runs 0.66 to 1.0: the brightest axis is in the sun.
		float lit = clamp((v_axis - 0.6) / 0.4, 0.0, 1.0);
		// The unflipped normal, as before V1: a beam's visible faces wind away from the eye, so
		// this is 0 on them and neon's edge term lights the whole wire. The flipped one dimmed
		// IFS neon to a quarter (style_shot mean luma 30.8 -> 7.6).
		float ndv = clamp(dot(normalize(NORMAL), VIEW), 0.0, 1.0);
		ALBEDO = art_colour(u * neon_bands + 0.5, u * 3.999, v_pos, v_n, lit, 1.0, ndv, length(VERTEX))
			* echo_k * brightness;
	} else {
		float u = fract(v_u);
		vec3 base = texture(ramp, vec2(u, 0.5)).rgb;
		vec3 hi_col = texture(ramp, vec2(fract(u + 0.35), 0.5)).rgb;
		vec3 wview = normalize(CAMERA_POSITION_WORLD - v_world);
		vec3 wn = normalize(v_wnorm);
		if (dot(wn, wview) < 0.0) wn = -wn;
		vec3 l = normalize(v_light);
		float pulse = 0.0;
		if (pulse_gain > 0.001) {
			float wave = 0.5 + 0.5 * sin((v_meta.x * 0.7 + v_meta.y * 0.3) * 6.2831853 - anim_t * 0.3);
			float w2 = wave * wave;
			float w8 = (w2 * w2) * (w2 * w2);
			pulse = w8 * pulse_gain;
		}
		vec3 col;
		if (art_style >= 5) {
			float ao_ifs = mix(0.18, 0.96, v_meta.y);
			if (art_style == 10) {
				// Joint and sheltered-face weathering for verdigris instead of radial distance
				// (which put the whole root frame at radius 0 into solid patina).
				vec3 ap = abs(v_pos);
				float joint = min(ap.x, min(ap.y, ap.z));
				float mottle = 0.5 + 0.5 * sin(v_pos.x * 4.5 + v_pos.y * 3.1)
					* cos(v_pos.z * 3.9 - v_pos.y * 2.7);
				ao_ifs = clamp(0.86 - 0.64 * smoothstep(0.56, 0.96, joint) - 0.20 * mottle
					+ (v_axis - 0.8) * 0.45, 0.10, 0.95);
			}
			float refl_y = reflect(-wview, wn).y;
			col = physical_finish(base, hi_col, n, l, VIEW, refl_y, 1.0, ao_ifs, u);
			col += mix(base, hi_col, 0.5) * (pulse * 0.5);
		} else {
			float ndl = max(dot(n, l), 0.0);
			float ndv = clamp(dot(n, VIEW), 0.0, 1.0);
			float depth_ao = mix(0.76, 1.06, v_meta.y);
			float lit = 0.26 + 0.42 * v_axis + 0.56 * ndl;
			col = base * lit * depth_ao;
			vec3 hv = half_dir(l, VIEW);
			float ndh = max(dot(n, hv), 0.0);
			float s2 = ndh * ndh;
			float s4 = s2 * s2;
			float s8 = s4 * s4;
			float s16 = s8 * s8;
			float s64 = s16 * s16 * s16 * s16;
			col += base * sheen * (s16 * s8) * (0.35 + 0.65 * ndl);
			col += mix(base, vec3(1.0), 0.45) * gloss * s64 * (0.25 + 0.75 * ndl);
			float f1 = 1.0 - ndv;
			float fres = f1 * f1 * f1;
			col += mix(hi_col, vec3(1.0), 0.25) * fres * rim_gain * depth_ao;
			col += mix(base, vec3(1.0), 0.35) * pulse;
		}
		col += hand_lantern(v_world, wn, wview, base);
		ALBEDO = col * echo_k * brightness;
	}
}
