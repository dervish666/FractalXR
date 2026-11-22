// V7: Wind-carried ambient petals, spores and fireflies for TREE AVENUE / WALK.
// One GPU-driven MultiMesh wrapping seamlessly around the camera in a world-space box:
// three uniforms a frame from forest.gd (walk, drift, clock), stereo-coherent world positions, near_fade near the eyes.
shader_type spatial;
render_mode unshaded, cull_disabled, blend_add, depth_draw_never, fog_disabled, shadows_disabled;

uniform vec3 pal2 = vec3(0.6, 0.45, 0.2);
uniform vec3 pal3 = vec3(0.9, 0.8, 0.3);
uniform vec3 pal4 = vec3(1.0, 0.95, 0.7);
uniform float brightness = 1.0;
uniform float gain = 0.28;
uniform vec3 walk_offset = vec3(0.0);   // avenue scroll in metres, so motes flow with WALK
// Wind drift so far, integrated on the CPU (forest.gd): a WIND change alters the speed from
// now on, where speed * TIME moved every mote by the whole history at once.
uniform vec3 drift_offset = vec3(0.0);
// Seconds, from forest.gd: TIME rolls over every hour and would move every mote at once.
uniform float anim_t = 0.0;
uniform vec3 box_size = vec3(16.0, 6.0, 16.0);
uniform float mote_size = 0.032;
uniform float leaf_shape = 0.0;         // 0 soft orb/spore, 1 petal, 2 needle, 3 crystal sparkle
uniform float leaf_hue = 0.0;
uniform vec3 leaf_tint = vec3(1.0);
uniform float leaf_mix = 0.0;
global uniform float colour_cycle;

varying vec2 v_uv;
varying flat vec3 v_col;

vec3 hue_turn(vec3 c, float a) {
	const vec3 k = vec3(0.57735027);
	float ca = cos(a);
	return c * ca + cross(k, c) * sin(a) + k * dot(k, c) * (1.0 - ca);
}

void vertex() {
	// INSTANCE_CUSTOM: (rx, ry, rz, phase) in [0, 1).
	vec3 seed = INSTANCE_CUSTOM.xyz;
	float phase = INSTANCE_CUSTOM.w * 6.2831853;
	float t = anim_t;
	float fall_speed = mix(0.06, 0.22, fract(seed.y * 7.13));
	// World-space drift wrapped smoothly into a box centred on the camera.
	vec3 raw = seed * box_size + drift_offset - vec3(0.0, t * fall_speed, 0.0) + walk_offset;
	vec3 cam = CAMERA_POSITION_WORLD;
	vec3 box_origin = cam - box_size * 0.5;
	vec3 p = box_origin + mod(raw - box_origin, box_size);
	// Gentle sinusoidal flutter perpendicular to fall.
	p.x += sin(t * 1.1 + phase) * 0.28;
	p.y += sin(t * 0.8 + phase * 1.37) * 0.14;
	p.z += cos(t * 0.95 + phase * 0.73) * 0.28;

	// Soft fade near the box walls and close to the eyes so nothing pops or strains stereo.
	vec3 edge_d = abs(p - cam) / (box_size * 0.5);
	float box_fade = 1.0 - smoothstep(0.72, 1.0, max(edge_d.x, max(edge_d.y, edge_d.z)));
	float cam_d = distance(p, cam);
	float near_f = smoothstep(0.45, 1.1, cam_d);
	float twinkle = 0.65 + 0.35 * sin(t * 0.8 + phase * 2.0);

	float hue = 1.0 - abs(fract(seed.z * 0.5 + colour_cycle) * 2.0 - 1.0);
	vec3 c = (hue < 0.5) ? mix(pal2, pal3, hue * 2.0) : mix(pal3, pal4, (hue - 0.5) * 2.0);
	if (leaf_mix > 0.0 || leaf_hue != 0.0) {
		c = max(hue_turn(c, leaf_hue), vec3(0.0));
		float luma = dot(c, vec3(0.299, 0.587, 0.114));
		c = mix(c, leaf_tint * max(luma * 1.4, 0.08), leaf_mix);
	}
	v_col = c * brightness * gain * box_fade * near_f * twinkle;

	float sz = mote_size * (0.65 + 0.7 * fract(seed.x * 13.7));
	// Spin and twinkle slow and independent of WIND, which would twitch every mote's angle
	// when it changed (and the slow-ambient rule wants under about 1 rad/s).
	float ang = t * 0.4 + phase;
	float ca = cos(ang), sa = sin(ang);
	vec2 q = vec2(VERTEX.x * ca - VERTEX.y * sa, VERTEX.x * sa + VERTEX.y * ca);
	vec3 right = INV_VIEW_MATRIX[0].xyz;
	vec3 up = INV_VIEW_MATRIX[1].xyz;
	vec3 w = p + right * (q.x * sz) + up * (q.y * sz);
	v_uv = VERTEX.xy;
	POSITION = PROJECTION_MATRIX * (VIEW_MATRIX * vec4(w, 1.0));
}

void fragment() {
	float r2 = dot(v_uv, v_uv);
	float d;
	if (leaf_shape <= 0.5) {
		if (r2 > 0.25) { discard; }
		d = sqrt(r2) * 2.0;
	} else {
		float th = atan(v_uv.y, v_uv.x);
		float edge;
		if (leaf_shape < 1.5) {
			edge = 0.5 + 0.5 * abs(cos(2.5 * th));
		} else if (leaf_shape < 2.5) {
			edge = 0.18 + 0.82 * pow(abs(cos(3.5 * th)), 10.0);
		} else {
			edge = 0.22 + 0.78 * pow(abs(cos(2.0 * th)), 6.0);
		}
		d = sqrt(r2) * 2.0 / edge;
		if (d > 1.0) { discard; }
	}
	float a = pow(1.0 - d, 1.8);
	ALBEDO = v_col * a;
	ALPHA = a;
}
