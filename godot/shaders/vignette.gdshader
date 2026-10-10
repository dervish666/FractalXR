shader_type spatial;
render_mode unshaded, blend_mix, depth_test_disabled, depth_draw_never, cull_disabled, fog_disabled, shadows_disabled;

// Tunnel vignette (scripts/xr/comfort_vignette.gd). A ring of geometry parented to the
// camera; the darkening is worked out per eye from the angle off that eye's forward axis,
// so both eyes see the same tunnel at infinity and it never takes a depth of its own.
//
// The ring's inner edge follows the window in the vertex shader, so at low strength only a
// thin band past the edge of the view is drawn at all, and nothing inside the clear window
// is ever shaded. Off (strength 0) the node is hidden and costs nothing.

uniform float strength = 0.0;     // 0 off, 1 full
uniform float clear_full = 0.62;  // radians: the clear window's half-angle at full strength
uniform float feather = 0.4;      // radians from clear to darkest
uniform float max_alpha = 0.9;
uniform vec3 tint = vec3(0.0);
uniform float dist = 0.5;         // metres in front of the head, matching the script
uniform float outer = 1.4;        // radians, past any headset's field

float clear_now() {
	// At strength 0 the window opens past 90 degrees, outside every headset's field.
	return mix(1.65, clear_full, strength);
}

void vertex() {
	// UV.x: 0 on the inner ring, 1 on the outer. The inner ring sits a parallax margin
	// inside the clear window: the eyes are 32 mm either side of the ring's centre, which
	// at 0.5 m moves its edge about 0.07 rad.
	float a = mix(max(clear_now() - 0.12, 0.05), outer, UV.x);
	a = min(a, outer);
	VERTEX = vec3(normalize(VERTEX.xy) * dist * tan(a), -dist);
}

void fragment() {
	vec3 d = normalize(VERTEX);
	float ang = acos(clamp(-d.z, -1.0, 1.0));
	float c = clear_now();
	ALBEDO = tint;
	ALPHA = smoothstep(c, c + feather, ang) * max_alpha * strength;
}
