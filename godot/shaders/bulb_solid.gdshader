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
// A soft lamp at the eye, for inside a closed shape where the sun never reaches (VAULT):
// diffuse toward the viewer, falling off over lamp_m metres. 0 = off.
uniform float head_light = 0.0;
uniform float lamp_m = 6.0;
#define PAPER_LIFT 1.18
#include "res://shaders/styles.gdshaderinc"
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
#include "res://shaders/fly_de.gdshaderinc"
// PIXEL (scripts/sources/bulb_solid.gd; option S6 in the vault's bulb display notes): the
// mesh sits within a cell of the true surface, so a pixel can afford the last stretch of the
// march itself and shade from the DE there: the normal, the colour's trap and a short AO probe
// per pixel, where the vertices carry them a cell (about 6 mm on a hand-sized bulb) apart.
// Nothing is kept between frames and both eyes march the same surface, so it cannot ghost
// or disagree in stereo. Depth stays the mesh's (the march moves the point well under a cell),
// which keeps early depth. Fades back to the vertex terms once a pixel spans a cell.
//   0 off, 1 normal and AO probe, 2 and the colour's trap, 3 and the march onto the surface.
// The trap per pixel draws fine agate rings the vertices smoothed over (a four-tap mean half a
// cell wide); its own step so the headset can say whether they read as detail or crawl.
uniform int pixel_detail = 0;
uniform float solid_iso = 0.0;     // the extracted level set, DE = iso, state units
uniform float solid_cell = 0.01;   // the build's cell size, state units
uniform float inside_mode = 1.0;   // BulbSolid.inside_mode: a point that never escaped is solid
uniform int detail_steps = 8;
#include "res://shaders/bulb_de.gdshaderinc"

varying float v_trap;
varying float v_ao;
varying float v_sh;
// Model-space (state) position and normal, for the per-pixel shadow.
varying vec3 v_state;
varying vec3 v_nstate;
// CYCLE's colour, per vertex (see vertex()).
varying vec3 v_cycled;
// Key light direction in view space, constant per eye/draw.
varying flat vec3 v_light;

// bulb.glsl deSolid(): the escape-time families are loose inside, so with inside_mode a point
// that never escaped counts as on the surface whatever its DE says.
float de_solid(vec3 q, float lod, out vec4 r) {
	r = de(q, lod);
	bool signed_de = (formula > 1.5 && formula < 2.5) || formula > 3.5;
	if (signed_de || inside_mode < 0.5) return r.x;
	return (r.w > 0.5) ? r.x : 0.0;
}

// The DE's gradient from four taps and, averaged over them, its other channels: the same
// trick as bulb.glsl's solidGrad, here at the pixel's footprint, so the trap is filtered over
// the pixel and needs no fifth evaluation.
vec3 grad_mean(vec3 q, float e, float lod, out vec4 mean) {
	vec2 k = vec2(1.0, -1.0);
	vec4 a = de(q + k.xyy * e, lod);
	vec4 b = de(q + k.yyx * e, lod);
	vec4 c = de(q + k.yxy * e, lod);
	vec4 d = de(q + k.xxx * e, lod);
	mean = 0.25 * (a + b + c + d);
	return normalize(k.xyy * a.x + k.yyx * b.x + k.yxy * c.x + k.xxx * d.x);
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
	v_light = normalize((MODELVIEW_MATRIX * vec4(light_dir, 0.0)).xyz);
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
	float trap = v_trap;
	float ao_px = 1.0;
	if (pixel_detail > 0) {
		// State units a pixel spans here: the DE's detail cutoff and the fade.
		float fp = length(fwidth(v_state));
		float near_px = 1.0 - smoothstep(0.6 * solid_cell, 1.5 * solid_cell, fp);
		if (near_px > 0.0) {
			float lod = 0.5 * fp;
			float eps = max(lod, 0.02 * solid_cell);
			vec3 p = v_state;
			vec4 r;
			if (pixel_detail >= 3) {
				// From a cell and a half back toward the eye, sphere-trace forward. The model
				// matrix is a similarity, so its transpose turns a world direction into state.
				vec3 rd = normalize(transpose(mat3(MODEL_MATRIX)) * (mat3(INV_VIEW_MATRIX) * normalize(VERTEX)));
				vec3 o = v_state - rd * 1.5 * solid_cell;
				float t = 0.0;
				for (int i = 0; i < detail_steps; i++) {
					float d = de_solid(o + rd * t, lod, r) - solid_iso;
					if (d < eps) { p = o + rd * t; break; }
					t += d;
					if (t > 3.0 * solid_cell) break;
				}
			}
			vec4 mean;
			vec3 nm = grad_mean(p, eps, lod, mean);
			n = normalize(mix(n, normalize(mat3(VIEW_MATRIX * MODEL_MATRIX) * nm), near_px));
			// The colour key bulb.glsl's VERTS pass stores.
			if (pixel_detail >= 2)
				trap = mix(v_trap, clamp((mean.y * 0.7 + mean.z * 0.5) * 0.45, 0.0, 1.0), near_px);
			{
				// Three probes out along the normal at 1, 2 and 4 cells: what a crevice the
				// vertex AO rays straddle looks like up close.
				float occ = 0.0;
				float h = solid_cell;
				float w = 1.0;
				for (int i = 0; i < 3; i++) {
					float d = de(p + nm * h, lod).x - solid_iso;
					occ += w * clamp((h - d) / h, 0.0, 1.0);
					h *= 2.0;
					w *= 0.5;
				}
				ao_px = mix(1.0, clamp(1.0 - 0.55 * occ, 0.0, 1.0), near_px);
			}
		}
	}
	vec3 l = v_light;
	float ndl = max(dot(n, l), 0.0);
	float ndv = clamp(dot(n, VIEW), 0.0, 1.0);

	float ao = v_ao * v_ao * ao_px;   // a sharper falloff into the crevices, as AO strength 2.2 is
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

	vec3 albedo = vec3(0.0);
	if (art_style > 0 && debug_view == 0) {
		float dist = length(VERTEX);
		float near = 1.0 - smoothstep(0.5 * neon_far, neon_far, dist);
		if (pixel_trap > 0) {
			float near_t = 1.0 - smoothstep(pixel_trap_m, pixel_trap_m * 1.5, dist);
			if (near_t > 0.0)
				trap = mix(v_trap, fly_trap(v_state), near_t);
		}
		// Neon's contours come from the key per pixel near the eye; toon's colours only where
		// the per-pixel key is clean (SPIRES), else by facing (VAULT's per-vertex key is confetti).
		float key_raw = art_style == 1 && trap_family > 0 && near > 0.0 ? fly_trap(v_state) : trap;
		float f = equalise(key_raw) * neon_bands + 0.5;
		float toon_e = pixel_trap > 0 ? equalise(trap) * 3.999 : -1.0;
		ALBEDO = art_colour(f, toon_e, v_state, v_nstate, lit, ao, ndv, dist) * gain * tint;
	} else {
		if (pixel_trap > 0) {
			float near = 1.0 - smoothstep(pixel_trap_m, pixel_trap_m * 1.5, length(VERTEX));
			if (near > 0.0)
				trap = mix(v_trap, fly_trap(v_state), near);
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

		vec3 c = albedo * (ambient * ao * sky_tint + key * lit * key_colour * mix(0.6, 1.0, v_ao));
		// Metal, not plastic: a broad sheen tinted by the surface and a tight glint that stays
		// mostly the surface's colour. Plastic's highlight is white.
		if (lit > 0.0) {
			vec3 hv = normalize(l + VIEW);
			float ndh = max(dot(n, hv), 0.0);
			c += albedo * sheen * pow(ndh, shininess) * lit;
			c += mix(albedo, vec3(1.0), 0.3) * gloss * pow(ndh, 90.0) * lit;
		}
		float f1 = 1.0 - ndv;
		c += glow_colour * (f1 * f1 * f1) * rim * v_ao;
		if (head_light > 0.0) {
			float fall = lamp_m * lamp_m / (lamp_m * lamp_m + dot(VERTEX, VERTEX));
			c += albedo * key_colour * head_light * ndv * fall * mix(0.4, 1.0, v_ao);
		}
		ALBEDO = c * gain * grow * tint;
	}
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
	else if (debug_view == 6) ALBEDO = vec3(ao_px);
}
