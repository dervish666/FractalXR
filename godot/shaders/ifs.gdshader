shader_type spatial;
render_mode unshaded, cull_back, fog_disabled, shadows_disabled;

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

varying float v_u;
varying float v_shade;

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
	float g_out = 1.0 - clamp((echo_t - echo_swap.x - (1.0 - birth) * swap_span) / swap_s, 0.0, 1.0);
	float g_in = clamp((echo_t - echo_swap.y - birth * swap_span) / swap_s, 0.0, 1.0);
	float gs = min(g_out, g_in);
	g *= gs * gs * (3.0 - 2.0 * gs);
	vec3 parent = (COLOR.rgb * 2.0 - 1.0) * origin_span;
	VERTEX *= UV.y < 0.5 ? seed_scale0 : seed_scale1;
	VERTEX = mix(parent, VERTEX, g);
	float swell = 0.0;
	float t = echo_t + echo_life.x;
	if (echo_live > 0.5) {
		// In world space about the echo's centre, so every bound is in metres and none of it
		// depends on the echo's random orientation or the instance's depth in the tree. Then
		// back into the instance's mesh space for the model matrix to carry out again.
		vec3 w = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
		swell = echo_life.y * sin(echo_life.z * t);
		vec3 rel = (w - echo_centre) * (1.0 + swell);
		vec3 k = echo_spin.xyz;
		float a = echo_spin.w * t;
		float c = cos(a);
		float s = sin(a);
		rel = rel * c + cross(k, rel) * s + k * dot(k, rel) * (1.0 - c);
		vec3 wob = echo_wander.xyz * sin(echo_wander.w * t * vec3(1.0, 1.37, 0.71) + vec3(0.0, 2.1, 4.2));
		w = echo_centre + rel + wob;
		VERTEX = inverse(mat3(MODEL_MATRIX)) * (w - MODEL_MATRIX[3].xyz);
	}
	// Level and radius together. Level alone bands the palette by generation with a hard
	// line between bands, radius alone ignores the recursion that built the shape.
	v_u = mix(level * level_gain, radius * radius_gain, radius_mix) + anim_t * scroll + echo_phase
		+ echo_life.w * echo_t;
	v_shade = UV.x * echo_gain * (1.0 + echo_glow * swell);
}

void fragment() {
	// fract() keeps the drifting coordinate precise after minutes of scrolling; the ramp is
	// built cyclic, first colour repeated at 1.0, so the wrap is not a seam.
	ALBEDO = texture(ramp, vec2(fract(v_u), 0.5)).rgb * v_shade * brightness;
}
