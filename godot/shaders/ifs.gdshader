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
uniform float scroll = 0.02;       // palette turns per second
uniform float radius_mix = 0.45;   // colour coordinate: level at 0, radial distance at 1
uniform float origin_span = 4.0;   // construction units the packed parent origin covers
uniform float brightness = 1.0;

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
	float g = clamp((anim_t - born_at - birth * grow_span) / grow_s, 0.0, 1.0);
	g = g * g * (3.0 - 2.0 * g);
	vec3 parent = (COLOR.rgb * 2.0 - 1.0) * origin_span;
	VERTEX = mix(parent, VERTEX, g);
	// Level and radius together. Level alone bands the palette by generation with a hard
	// line between bands, radius alone ignores the recursion that built the shape.
	v_u = mix(level, radius, radius_mix) + anim_t * scroll;
	v_shade = UV.x;
}

void fragment() {
	// fract() keeps the drifting coordinate precise after minutes of scrolling; the ramp is
	// built cyclic, first colour repeated at 1.0, so the wrap is not a seam.
	ALBEDO = texture(ramp, vec2(fract(v_u), 0.5)).rgb * v_shade * brightness;
}
