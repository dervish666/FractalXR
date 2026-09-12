shader_type spatial;
render_mode unshaded, cull_disabled, blend_add, depth_draw_never, fog_disabled, shadows_disabled;

// Leaves: camera-facing soft discs at the branch tips, additive so the canopy glows the
// way the flames do under the same Environment glow. Same wind field as the branches
// (kept in step by hand), plus a flutter that spins each disc a little.

uniform vec3 pal0 = vec3(0.05, 0.02, 0.0);
uniform vec3 pal1 = vec3(0.35, 0.18, 0.05);
uniform vec3 pal2 = vec3(0.6, 0.45, 0.2);
uniform vec3 pal3 = vec3(0.9, 0.8, 0.3);
uniform vec3 pal4 = vec3(1.0, 0.95, 0.7);
uniform float brightness = 1.0;
uniform float grow_t = 0.0;
uniform float grow_s = 6.0;
uniform float tree_height = 3.0;
uniform float wind = 0.3;
uniform vec3 tree_origin = vec3(0.0);
uniform vec3 tree_up = vec3(0.0, 1.0, 0.0);
uniform vec3 wind_dir = vec3(1.0, 0.0, 0.0);
uniform float tree_scale = 1.0;

varying vec2 v_uv;
varying float v_hue;

vec3 sway(vec3 w, float phase) {
	float h = clamp(dot(w - tree_origin, tree_up) / max(tree_height * tree_scale, 1e-3), 0.0, 1.5);
	float g = sin(TIME * 0.7) * 0.6 + sin(TIME * 1.9 + h * 2.0) * 0.25 + sin(TIME * 3.1 + phase) * 0.15;
	vec3 lateral = cross(tree_up, cross(wind_dir, tree_up));
	lateral = normalize(lateral + vec3(1e-5, 0.0, 0.0));
	float amp = wind * 0.12 * h * h * tree_scale;
	return w + lateral * (amp * g) - tree_up * (amp * 0.2 * abs(g));
}

void vertex() {
	float birth = INSTANCE_CUSTOM.x;
	float phase = INSTANCE_CUSTOM.w;
	v_hue = COLOR.r;
	// Leaves open after their branch has finished extending.
	float g = clamp((grow_t - (birth * grow_s + 0.8)) / 1.2, 0.0, 1.0);
	g = g * g * (3.0 - 2.0 * g);
	vec3 center = MODEL_MATRIX[3].xyz;
	float size = length(MODEL_MATRIX[0].xyz) * g;
	vec3 right = INV_VIEW_MATRIX[0].xyz;
	vec3 up = INV_VIEW_MATRIX[1].xyz;
	float a = sin(TIME * 2.7 + phase) * 0.4 * (0.3 + wind);
	vec2 q = vec2(VERTEX.x * cos(a) - VERTEX.y * sin(a), VERTEX.x * sin(a) + VERTEX.y * cos(a));
	vec3 w = sway(center, phase) + right * (q.x * size) + up * (q.y * size);
	v_uv = VERTEX.xy;
	POSITION = PROJECTION_MATRIX * (VIEW_MATRIX * vec4(w, 1.0));
}

void fragment() {
	float d = length(v_uv) * 2.0;
	if (d > 1.0) { discard; }
	float a = pow(1.0 - d, 1.6);
	vec3 c = mix(pal3, pal4, v_hue);
	ALBEDO = c * a * brightness * 0.6;
	ALPHA = a;
}
