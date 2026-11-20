shader_type spatial;
render_mode unshaded, cull_back, depth_draw_opaque, fog_disabled, shadows_disabled, specular_disabled;

// SOLID's depth prepass, for PIXEL (bulb_solid.gd). The Mobile renderer has none of its own, and
// a bulb is many layers deep, so without one the per-pixel DE work ran for every hidden layer
// too. This pass lays the mesh's depth down with a black colour; bulb_solid.gdshader follows as
// its next pass and shades only the front surface. The depth is pushed a hair away from the eye
// (Godot's depth is reversed: smaller is further) so the second pass's identical triangles win
// the test whichever way the comparison breaks ties. Drawn in the wrong order it costs the
// saving and nothing else: the shaded pass is nearer, so this one cannot cover it.

uniform vec3 hole_lo = vec3(1.0);
uniform vec3 hole_hi = vec3(-1.0);
const float PUSH = 2e-6;

void vertex() {
	if (all(greaterThan(VERTEX, hole_lo)) && all(lessThan(VERTEX, hole_hi)))
		VERTEX = vec3(uintBitsToFloat(0x7fc00000u));
	POSITION = PROJECTION_MATRIX * MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	POSITION.z -= PUSH * POSITION.w;
}

void fragment() {
	ALBEDO = vec3(0.0);
}
