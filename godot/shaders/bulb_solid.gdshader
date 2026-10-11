shader_type spatial;
render_mode unshaded, cull_back, depth_draw_opaque, fog_disabled, shadows_disabled, specular_disabled;

// SOLID: the extracted bulb mesh (scripts/sources/bulb_solid.gd). The expensive light is
// already in the vertices, baked by bulb.glsl's mesh_light pass: AO from six DE rays and a
// marched soft shadow from one key light fixed to the shape. Per pixel this only does the
// palette, a key and a sheen against that same light, and a rim for the glow, so it costs
// about what any opaque mesh of this triangle count costs.
//
// No discard anywhere: on a tiler a shader that can discard loses early depth for the
// whole draw, and the grow-in is a brightness ramp for that reason.

uniform vec3 pal0 = vec3(0.02, 0.02, 0.12);
uniform vec3 pal1 = vec3(0.35, 0.04, 0.45);
uniform vec3 pal2 = vec3(0.95, 0.15, 0.4);
uniform vec3 pal3 = vec3(1.0, 0.6, 0.1);
uniform vec3 pal4 = vec3(1.0, 0.95, 0.65);
uniform float palette_cycles = 2.0;
uniform float gain = 1.0;
// Trap equalisation, measured over the vertices at build time: cdf[i] is the share of
// vertices whose trap is under i/64.
uniform float cdf[65];
// State-space key light, the one the shadow was marched toward.
uniform vec3 light_dir = vec3(0.5, 0.8, 0.35);
uniform float ambient = 0.22;
uniform float key = 1.45;
uniform float sheen = 0.9;
uniform float shininess = 20.0;
uniform float gloss = 0.8;
uniform float saturation = 1.35;
// How far the palette's own light and dark are pulled to one level. The themes run from
// near black to near white, which on a lit surface reads as holes and highlights painted
// on; the classic renders take their light and dark from the lighting and their hue from
// the trap. 1 keeps only the hue.
uniform float flatten = 0.2;
// Mandelbulber's glow_color_1 for the rim: the blue haze round the classic renders.
uniform vec3 glow_colour = vec3(0.31, 0.41, 0.75);
uniform float rim = 0.9;
uniform float grow = 1.0;
uniform int debug_view = 0;

varying float v_trap;
varying float v_ao;
varying float v_sh;

void vertex() {
	v_trap = CUSTOM0.w;
	v_ao = CUSTOM1.x;
	v_sh = CUSTOM1.y;
	// Model space in, view space out: Godot carries NORMAL through MODELVIEW.
	NORMAL = CUSTOM0.xyz;
}

float equalise(float x) {
	float f = clamp(x, 0.0, 1.0) * 64.0;
	int i = int(min(floor(f), 63.0));
	return mix(cdf[i], cdf[i + 1], f - float(i));
}

vec3 palette(float u) {
	u = clamp(u, 0.0, 1.0) * 4.0;
	int i = int(min(floor(u), 3.0));
	float f = u - float(i);
	vec3 a = (i == 0) ? pal0 : (i == 1) ? pal1 : (i == 2) ? pal2 : pal3;
	vec3 b = (i == 0) ? pal1 : (i == 1) ? pal2 : (i == 2) ? pal3 : pal4;
	return mix(a, b, f);
}

void fragment() {
	vec3 n = normalize(NORMAL);
	vec3 l = normalize((VIEW_MATRIX * MODEL_MATRIX * vec4(light_dir, 0.0)).xyz);
	float ndl = max(dot(n, l), 0.0);
	float ndv = clamp(dot(n, VIEW), 0.0, 1.0);

	vec3 albedo = palette(fract(equalise(v_trap) * palette_cycles));
	float lum = dot(albedo, vec3(0.2126, 0.7152, 0.0722));
	albedo *= mix(lum, 0.5, flatten) / max(lum, 0.03);
	// The tonemapper bleaches what the key lifts; push chroma back so gold stays gold.
	float lum2 = dot(albedo, vec3(0.2126, 0.7152, 0.0722));
	albedo = max(mix(vec3(lum2), albedo, saturation), vec3(0.0));

	float ao = v_ao * v_ao;   // a sharper falloff into the crevices, as AO strength 2.2 is
	float lit = ndl * v_sh;
	vec3 c = albedo * (ambient * ao + key * lit * mix(0.6, 1.0, v_ao));
	// Metal, not plastic: a broad sheen tinted by the surface and a tight glint that stays
	// mostly the surface's colour. Plastic's highlight is white.
	vec3 hv = normalize(l + VIEW);
	float ndh = max(dot(n, hv), 0.0);
	c += albedo * sheen * pow(ndh, shininess) * lit;
	c += mix(albedo, vec3(1.0), 0.3) * gloss * pow(ndh, 90.0) * lit;
	c += glow_colour * pow(1.0 - ndv, 3.0) * rim * v_ao;
	ALBEDO = c * gain * grow;
	// Harness views of the baked terms (tools/solid_shot.sh): 1 AO, 2 shadow, 3 N.L.
	if (debug_view == 1) ALBEDO = vec3(v_ao);
	else if (debug_view == 2) ALBEDO = vec3(v_sh);
	else if (debug_view == 3) ALBEDO = vec3(ndl);
}
