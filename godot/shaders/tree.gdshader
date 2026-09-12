shader_type spatial;
render_mode unshaded, cull_back, fog_disabled, shadows_disabled;

// Fractal tree branches: one instanced unit cylinder per segment. The instance transform
// carries position, direction, length and radius; INSTANCE_CUSTOM carries (birth, taper,
// level, phase). Growth and wind live here so the script never touches the buffer again:
// a segment extends from its base once the growth clock passes its birth, and every
// vertex is displaced by one wind field of height, so the whole tree bends as one thing
// and joints never pull apart.

uniform vec3 pal0 = vec3(0.05, 0.02, 0.0);
uniform vec3 pal1 = vec3(0.35, 0.18, 0.05);
uniform vec3 pal2 = vec3(0.6, 0.45, 0.2);
uniform vec3 pal3 = vec3(0.9, 0.8, 0.3);
uniform vec3 pal4 = vec3(1.0, 0.95, 0.7);
uniform float brightness = 1.0;
uniform float grow_t = 0.0;         // seconds since the seed
uniform float grow_s = 6.0;         // seconds to full height
uniform float tree_height = 3.0;    // metres, before the node's scale
uniform float wind = 0.3;
uniform vec3 tree_origin = vec3(0.0);
uniform vec3 tree_up = vec3(0.0, 1.0, 0.0);
uniform vec3 wind_dir = vec3(1.0, 0.0, 0.0);
uniform float tree_scale = 1.0;

varying float v_level;
varying vec3 v_normal_w;
varying vec3 v_world;

// One displacement field for branches and leaves: lateral bend growing with the square
// of height (a cantilever), a slow body sway, a faster ripple up the trunk, and a small
// per-branch flutter. Metres, in world space.
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
	float taper = INSTANCE_CUSTOM.y;
	v_level = INSTANCE_CUSTOM.z;
	float phase = INSTANCE_CUSTOM.w;
	// Growth: extends from the base over 0.9 s after birth, thickening with it.
	float g = clamp((grow_t - birth * grow_s) / 0.9, 0.0, 1.0);
	g = g * g * (3.0 - 2.0 * g);
	float y01 = VERTEX.y + 0.5;    // the unit cylinder is centred: 0 at the base, 1 at the tip
	vec3 v = VERTEX;
	v.xz *= mix(1.0, taper, y01) * g;
	v.y = y01 * g - 0.5;
	vec3 w = (MODEL_MATRIX * vec4(v, 1.0)).xyz;
	w = sway(w, phase);
	v_world = w;
	// The basis scales x and z equally, so a radial normal keeps its direction.
	v_normal_w = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	POSITION = PROJECTION_MATRIX * (VIEW_MATRIX * vec4(w, 1.0));
}

void fragment() {
	float u = v_level;
	vec3 base = (u < 0.5) ? mix(pal0, pal1, u * 2.0) : mix(pal1, pal2, (u - 0.5) * 2.0);
	vec3 n = normalize(v_normal_w);
	vec3 key = normalize(vec3(0.5, 0.8, 0.3));
	vec3 V = normalize(CAMERA_POSITION_WORLD - v_world);
	float ndv = max(dot(n, V), 0.0);
	float diff = 0.6 * max(dot(n, key), 0.0) + 0.4 * ndv;
	float rim = pow(1.0 - ndv, 3.0);
	ALBEDO = (base * (0.25 + 0.75 * diff) + pal3 * rim * 0.35 * u) * brightness;
}
