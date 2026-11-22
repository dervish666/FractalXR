// The disc you stand on in GROUND's SPHERE mode (bowl and globe), translucent dark glass at
// y = 0 with anti-aliased stance rings and four cardinal ticks. It sits on the real floor and
// holds still in the world (fractal_ground.gd STAND_HOLD_M), so the feet keep a fixed floor
// while the fractal drops away below, 0.4 m at R = 2. Two triangles, no discard. Hidden on
// the flat floor, and in passthrough, where the room's own floor shows.
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, fog_disabled, shadows_disabled;

uniform vec3 tint : source_color = vec3(0.05, 0.06, 0.10);
uniform vec3 ring_col : source_color = vec3(0.78, 0.86, 0.96);
uniform float glass_alpha = 0.12;
uniform float ring_alpha = 0.36;

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);
	float w = max(fwidth(r), 1e-4);
	float disc = 1.0 - smoothstep(1.0 - w, 1.0 + w, r);

	// Outer rim ring and a subtler inner stance ring.
	float outer_ring = 1.0 - smoothstep(0.008 - w, 0.008 + w, abs(r - 0.96));
	float inner_ring = (1.0 - smoothstep(0.005 - w, 0.005 + w, abs(r - 0.50))) * 0.35;

	// Four short cardinal ticks inside the outer rim for rotational orientation.
	vec2 ap = abs(p);
	float wx = max(fwidth(p.x), 1e-4);
	float wy = max(fwidth(p.y), 1e-4);
	float tick_r = smoothstep(0.86 - w, 0.86 + w, r) * (1.0 - smoothstep(0.95 - w, 0.95 + w, r));
	float tick_x = 1.0 - smoothstep(0.007 - wx, 0.007 + wx, ap.x);
	float tick_y = 1.0 - smoothstep(0.007 - wy, 0.007 + wy, ap.y);
	float ticks = max(tick_x, tick_y) * tick_r * 0.55;

	float line_k = clamp(max(max(outer_ring, inner_ring), ticks), 0.0, 1.0);
	// Clearer glass right between the feet so the nadir fractal reads cleanly through it.
	float body_a = glass_alpha * (0.55 + 0.45 * r * r);
	ALBEDO = mix(tint, ring_col, line_k);
	ALPHA = clamp(body_a + line_k * ring_alpha, 0.0, 1.0) * disc;
}
