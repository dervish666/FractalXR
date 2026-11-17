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
global uniform float colour_cycle;
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
// FLY (scripts/sources/bulb_fly.gd): the box a finer level of the stack draws, in model
// (state) space. A vertex inside it goes to NaN, and the rasteriser drops every triangle
// that touches it. Done here rather than with discard to keep early depth (see above).
// hi below lo is no hole, the default.
uniform vec3 hole_lo = vec3(1.0);
uniform vec3 hole_hi = vec3(-1.0);
// Harness only: FLY tints each level so a shot shows where the stack's seams fall.
uniform vec3 tint = vec3(1.0);
// FLY's SPIRES world (bulb_fly.gd sets these; the defaults are SOLID as it was): the
// ambient's colour, as from a blue sky, the key's, as from a low sun, and fog by view
// distance in metres toward the sky the background is cleared to.
uniform vec3 sky_tint = vec3(1.0);
uniform vec3 key_colour = vec3(1.0);
uniform vec3 fog_colour = vec3(0.6, 0.7, 0.85);
uniform float fog_density = 0.0;
// FLY's SPIRES: the sun's shadow marched per pixel where the baked one cannot draw it.
// The vertex shadow is right in bulk and wrong at its edges, where a hard penumbra
// interpolated across triangles comes out as a staircase. So a pixel marches only when
// its interpolated vertex shadow is partial: the triangles that straddle an edge. All in
// state units (model space). 0 = off, SOLID as it was.
uniform int pixel_shadow = 0;
uniform float shadow_cell = 0.01;    // the level's cell size: step floor and hit margin
uniform float shadow_iso = 0.0035;   // the level's extracted level set, DE = iso
uniform float shadow_reach = 1.0;
uniform float shadow_sharp = 12.0;   // Quilez's k
uniform int shadow_steps = 40;
// SPIRES's colour per pixel inside pixel_trap_m metres, easing back to the per-vertex
// colour over the next half again: a hard-edged pattern sampled per pixel crawls once
// its bands are thinner than a pixel. 0 = off.
uniform int pixel_trap = 0;
uniform float pixel_trap_m = 14.0;
#include "res://shaders/spires_de.gdshaderinc"

varying float v_trap;
varying float v_ao;
varying float v_sh;
// Model-space (state) position and normal, for the per-pixel shadow.
varying vec3 v_state;
varying vec3 v_nstate;
// CYCLE's colour, per vertex (see vertex()).
varying vec3 v_cycled;

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

// CYCLE (main.gd, the COLOUR card; points.gdshader says how the ramp scrolls). Banded, the wrap
// already has a seam per band and it scrolls with them; unbanded it ping-pongs, so cycling adds
// no seam. Off (0, the default) is the old wrap exactly.
float cycle_u(float u) {
	if (colour_cycle <= 0.0) return fract(u * palette_cycles);
	if (palette_cycles > 1.5) return fract(u * palette_cycles + colour_cycle);
	return 1.0 - abs(fract(u * 0.5 + colour_cycle) * 2.0 - 1.0);
}

// CYCLE moves the hue and keeps the brightness: the scrolled colour scaled to the unscrolled
// one's luma, at most 3x and the rest in grey (points.gdshader says why).
vec3 keep_luma(vec3 c, float l0) {
	const vec3 W = vec3(0.2126, 0.7152, 0.0722);
	c *= min(l0 / max(dot(c, W), 1e-4), 3.0);
	return c + max(l0 - dot(c, W), 0.0);
}

// After the ramp functions now, because CYCLE reads them here.
void vertex() {
	if (all(greaterThan(VERTEX, hole_lo)) && all(lessThan(VERTEX, hole_hi)))
		VERTEX = vec3(uintBitsToFloat(0x7fc00000u));
	v_trap = CUSTOM0.w;
	v_ao = CUSTOM1.x;
	v_sh = CUSTOM1.y;
	v_state = VERTEX;
	v_nstate = CUSTOM0.xyz;
	// Model space in, view space out: Godot carries NORMAL through MODELVIEW.
	NORMAL = CUSTOM0.xyz;
	// CYCLE's colour per vertex: the scrolled ramp at the unscrolled one's luma. Per pixel it cost
	// a quarter of SOLID's draw on the Mac, and at a few pixels a triangle the vertices carry the
	// colour as well. Banded, a band's seam would smear across a triangle, so fragment() keeps
	// that case per pixel. Unused, and black, when CYCLE is off.
	v_cycled = vec3(0.0);
	if (colour_cycle > 0.0) {
		float eq = equalise(v_trap);
		v_cycled = keep_luma(palette(cycle_u(eq)),
			dot(palette(fract(eq * palette_cycles)), vec3(0.2126, 0.7152, 0.0722)));
	}
}

void fragment() {
	vec3 n = normalize(NORMAL);
	vec3 l = normalize((VIEW_MATRIX * MODEL_MATRIX * vec4(light_dir, 0.0)).xyz);
	float ndl = max(dot(n, l), 0.0);
	float ndv = clamp(dot(n, VIEW), 0.0, 1.0);

	vec3 albedo;
	float trap = v_trap;
	if (pixel_trap > 0) {
		float near = 1.0 - smoothstep(pixel_trap_m, pixel_trap_m * 1.5, length(VERTEX));
		if (near > 0.0)
			trap = mix(v_trap, spires_trap(v_state), near);
	}
	if (colour_cycle > 0.0 && palette_cycles < 1.5) {
		albedo = v_cycled;
	} else {
		float eq = equalise(trap);
		albedo = palette(cycle_u(eq));
		if (colour_cycle > 0.0)
			albedo = keep_luma(albedo, dot(palette(fract(eq * palette_cycles)), vec3(0.2126, 0.7152, 0.0722)));
	}
	float lum = dot(albedo, vec3(0.2126, 0.7152, 0.0722));
	albedo *= mix(lum, 0.5, flatten) / max(lum, 0.03);
	// The tonemapper bleaches what the key lifts; push chroma back so gold stays gold.
	float lum2 = dot(albedo, vec3(0.2126, 0.7152, 0.0722));
	albedo = max(mix(vec3(lum2), albedo, saturation), vec3(0.0));

	float ao = v_ao * v_ao;   // a sharper falloff into the crevices, as AO strength 2.2 is
	float sh = v_sh;
	if (pixel_shadow > 0 && ndl > 0.0 && sh > 0.03 && sh < 0.97) {
		vec3 o = v_state + normalize(v_nstate) * shadow_cell;
		float vis = 1.0;
		float t = 2.0 * shadow_cell;
		for (int s = 0; s < shadow_steps; s++) {
			float d = spires_de(o + light_dir * t) - shadow_iso;
			vis = min(vis, shadow_sharp * d / t);
			if (vis < 0.01 || t > shadow_reach) break;
			t += max(d, 0.35 * shadow_cell);
		}
		sh = clamp(vis, 0.0, 1.0);
	}
	if (debug_view == 4) sh = (pixel_shadow > 0 && v_sh > 0.03 && v_sh < 0.97) ? 1.0 : 0.0;
	float lit = ndl * sh;
	vec3 c = albedo * (ambient * ao * sky_tint + key * lit * key_colour * mix(0.6, 1.0, v_ao));
	// Metal, not plastic: a broad sheen tinted by the surface and a tight glint that stays
	// mostly the surface's colour. Plastic's highlight is white.
	vec3 hv = normalize(l + VIEW);
	float ndh = max(dot(n, hv), 0.0);
	c += albedo * sheen * pow(ndh, shininess) * lit;
	c += mix(albedo, vec3(1.0), 0.3) * gloss * pow(ndh, 90.0) * lit;
	c += glow_colour * pow(1.0 - ndv, 3.0) * rim * v_ao;
	ALBEDO = c * gain * grow * tint;
	// Squared, so the near city keeps its colour and the haze gathers toward the edge.
	if (fog_density > 0.0) {
		float fd = fog_density * length(VERTEX);
		ALBEDO = mix(fog_colour, ALBEDO, exp(-fd * fd));
	}
	// Harness views of the baked terms (tools/solid_shot.sh): 1 AO, 2 shadow, 3 N.L.
	if (debug_view == 1) ALBEDO = vec3(v_ao);
	else if (debug_view == 2) ALBEDO = vec3(sh);
	else if (debug_view == 5) ALBEDO = albedo;
	else if (debug_view == 3) ALBEDO = vec3(ndl);
}
