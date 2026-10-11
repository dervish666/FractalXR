shader_type canvas_item;

// One draw, once, when FLOOR's ground is first shown (forest_floor.gd): the Kaliset tile at two
// constants, red and green, so the floor can drift between them along the avenue. The floor
// samples the result with mipmaps, which filter the lines far better than a per-pixel fade could
// and cost one texture read where the live pattern cost eight Kaliset steps a pixel.

#include "res://shaders/tree_floor_kali.gdshaderinc"

uniform float soft = 6.0;   // the lines' sharpness: exp(-soft x the change in step length)

void fragment() {
	COLOR = vec4(kali_floor(UV, vec2(0.55, 0.62), soft), kali_floor(UV, vec2(0.61, 0.56), soft), 0.0, 1.0);
}
