// Fullscreen composite for the COMPUTE path. Draws the tone-mapped compute output
// straight over each eye. POSITION is written directly so the quad ignores the camera
// and covers clip space; VIEW_INDEX picks the eye's layer under multiview.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, depth_test_disabled, fog_disabled, shadows_disabled;

uniform sampler2DArray tex : filter_linear, source_color;

varying vec2 v_uv;

void vertex() {
	v_uv = VERTEX.xy + vec2(0.5); // QuadMesh spans -0.5..0.5
	POSITION = vec4(VERTEX.xy * 2.0, 1.0, 1.0);
}

void fragment() {
	ALBEDO = texture(tex, vec3(vec2(v_uv.x, 1.0 - v_uv.y), float(VIEW_INDEX))).rgb;
}
