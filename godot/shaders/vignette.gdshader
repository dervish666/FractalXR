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
// Radians: the window's half-angle as strength leaves 0. 1.65 is past every headset's field, so
// the tunnel only shows once strength passes about 0.7; the walk starts it at the field's edge
// (0.95) so it closes steadily over the whole of its ease instead of in the last few frames.
uniform float clear_open = 1.65;
uniform float feather = 0.4;      // radians from clear to darkest
uniform float max_alpha = 0.9;
uniform vec3 tint = vec3(0.0);
uniform float dist = 0.5;         // metres in front of the head, matching the script
uniform float outer = 1.4;        // radians, past any headset's field
// Rest frame (T-55, the walk's profile; 0 leaves the tunnel plain black). A faint latitude and
// longitude lattice fixed to the room at infinity, drawn only where the tunnel is dark and in
// proportion to it. It turns with your head and never moves with the walk: the "independent
// visual background that moves only with head movement" of Meta's locomotion guidance, and the
// static rest frame that lets the eyes agree with the inner ear that you are standing still
// (Prothero's rest frame hypothesis; Cao, Jerald and Kopper, IEEE VR 2018). At infinity, both
// eyes see it at the same place, so it never takes a depth.
uniform float rest = 0.0;
uniform vec3 rest_tint = vec3(0.5, 0.45, 0.6);
uniform float rest_step = 0.5236; // radians between lines (30 degrees)

float clear_now() {
	// At strength 0 the window is at clear_open (by default past 90 degrees, outside the field).
	return mix(clear_open, clear_full, strength);
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
	if (rest > 0.0) {
		vec3 w = normalize(mat3(INV_VIEW_MATRIX) * d);
		float lon = atan(w.z, w.x);
		float lat = asin(clamp(w.y, -1.0, 1.0));
		// atan jumps at the back; the derivative comes from whichever of two cuts is smooth here.
		float dlon = min(fwidth(lon), fwidth(atan(-w.z, -w.x)));
		vec2 g = vec2(lon, lat) / rest_step;
		vec2 px = abs(fract(g + 0.5) - 0.5) / max(vec2(dlon, fwidth(lat)) / rest_step, vec2(1e-5));
		// Meridians crowd together toward the poles, so they fade out there.
		float mer = (1.0 - smoothstep(0.75, 1.75, px.x)) * (1.0 - smoothstep(0.8, 0.95, abs(w.y)));
		float par = 1.0 - smoothstep(0.75, 1.75, px.y);
		ALBEDO += rest_tint * rest * max(mer, par);
	}
}
