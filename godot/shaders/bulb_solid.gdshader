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
// FLY's STYLE. 0 = natural (everything above), 1 = neon: dark bodies drawn in glowing lines
// that follow the fractal, not the screen, so both eyes see the same line on the same
// fold. Lines sit at even steps of the equalised orbit trap, at the trap's jumps (the
// fold boundaries) and where the surface creases. Widths are in pixels via fwidth, and a
// set of lines packed closer than a few pixels fades out instead of crawling. Line colour
// runs past 1.0 so the Environment's glow (threshold 1, main.tscn) blooms it.
uniform int art_style = 0;
uniform float neon_bands = 11.0;
uniform float neon_gain = 2.0;
uniform float neon_far = 80.0;   // metres: lines fade out by here, and the per-pixel key stops
uniform vec3 neon_a = vec3(0.12, 0.85, 1.0);
uniform vec3 neon_b = vec3(1.0, 0.22, 0.72);
uniform vec3 neon_c = vec3(0.55, 0.35, 1.0);
uniform vec3 neon_body = vec3(0.004, 0.005, 0.012);
// 2 = toon: flat colours in two light steps and ink outlines. 3 = pencil: graphite hatching
// on paper, denser and crossed in the shade. 4 = circuit: copper traces and pads on a green
// board. Their patterns live in state space on the plane the surface faces most, at a
// power-of-two period that keeps them near a set size in pixels, so a pattern sticks to the
// fractal (the same stroke in both eyes) and holds its size as you shrink.
uniform float style_px = 12.0;       // pattern period, in pixels, give or take an octave
uniform vec3 paper = vec3(0.92, 0.9, 0.85);
uniform vec3 graphite = vec3(0.12, 0.12, 0.15);
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

// The STYLEs' shared parts. An integer hash, as sin() hashes lose their bits on mobile GPUs.
float hash2(vec2 c) {
	uvec2 q = uvec2(ivec2(c)) * uvec2(1597334673u, 3812015801u);
	return float((q.x ^ q.y) * 1597334673u) * (1.0 / 4294967295.0);
}

// The plane a surface faces most, as 2D state coordinates: 0 yz, 1 xz, 2 xy.
vec2 face_uv(vec3 p, vec3 a) {
	return a.x > a.y && a.x > a.z ? p.yz : (a.y > a.z ? p.xz : p.xy);
}

// One pencil stroke family: thin parallel strokes at this angle, each broken into dashes of
// its own length and pressed a little harder or lighter, anti-aliased against px (state
// units per pixel). Returns coverage.
float strokes(vec2 uv, float period, float px, float angle, float thick) {
	vec2 d = vec2(cos(angle), sin(angle));
	float u = dot(uv, d) / period;
	float v = dot(uv, vec2(-d.y, d.x)) / period;
	float h = hash2(vec2(floor(u), floor(angle * 10.0)));
	float run = fract(v / (3.0 + 5.0 * h) + h);
	float dash = smoothstep(0.0, 0.06, run) * (1.0 - smoothstep(0.84, 0.92, run));
	float band = abs(fract(u) - 0.5);
	float w = 0.5 * px / period;
	return (1.0 - smoothstep(0.5 * thick - w, 0.5 * thick + w, band)) * dash * (0.6 + 0.4 * h);
}

// Graphite on one plane at one period: a first layer from light grey, a cross layer in the
// shade and a closer third in the darkest crevices. Strokes stay thin; shade comes from more
// of them.
float hatch(vec2 uv, float period, float px, float dark) {
	float a = strokes(uv, period, px, 0.6, 0.2) * smoothstep(0.12, 0.32, dark);
	float b = strokes(uv, period, px, 2.2, 0.2) * smoothstep(0.38, 0.58, dark);
	float c = strokes(uv, 0.5 * period, px, 1.35, 0.22) * smoothstep(0.58, 0.78, dark);
	return max(a, max(b, c));
}

// Copper on one plane at one period. Each cell's four edges are on or off by a hash of the
// edge, so a neighbour agrees and traces run on across cells; a cell with one connection
// ends in a pad. x = trace or pad coverage, y = pad, z = a lit pad (an LED).
vec3 circuit(vec2 uv, float period, float px) {
	vec2 g = uv / period;
	vec2 id = floor(g);
	vec2 f = fract(g) - 0.5;
	float w = 0.5 * px / period;
	float r = step(0.55, hash2(id * 2.0 + vec2(1.0, 0.0)));
	float l = step(0.55, hash2(id * 2.0 - vec2(1.0, 0.0)));
	float u = step(0.55, hash2(id * 2.0 + vec2(0.0, 1.0)));
	float d = step(0.55, hash2(id * 2.0 - vec2(0.0, 1.0)));
	const float HW = 0.07;
	float across_x = 1.0 - smoothstep(HW - w, HW + w, abs(f.y));
	float across_y = 1.0 - smoothstep(HW - w, HW + w, abs(f.x));
	float t = max(max(r * step(0.0, f.x), l * step(f.x, 0.0)) * across_x,
		max(u * step(0.0, f.y), d * step(f.y, 0.0)) * across_y);
	float links = r + l + u + d;
	float cell = hash2(id * 2.0 + vec2(1.0, 1.0));
	float has_pad = (links == 1.0 || (links > 0.0 && cell > 0.8)) ? 1.0 : 0.0;
	float rad = length(f);
	float pad = has_pad * (1.0 - smoothstep(0.2 - w, 0.2 + w, rad)) * smoothstep(0.07 - w, 0.07 + w, rad);
	float led = has_pad * step(0.93, cell) * (1.0 - smoothstep(0.2 - w, 0.2 + w, rad));
	return vec3(max(t, pad), pad, led);
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
	if (head_light > 0.0) {
		float fall = lamp_m * lamp_m / (lamp_m * lamp_m + dot(VERTEX, VERTEX));
		c += albedo * key_colour * head_light * ndv * fall * mix(0.4, 1.0, v_ao);
	}
	ALBEDO = c * gain * grow * tint;
	if (art_style == 1) {
		float dist = length(VERTEX);
		float fade = 1.0 - smoothstep(0.5 * neon_far, neon_far, dist);
		float key_raw = (trap_family > 0 && fade > 0.0) ? fly_trap(v_state) : v_trap;
		// Lines at the half steps: where the key saturates (0 or 1, flat over a whole dome)
		// f sits on a whole number, and a line there would paint the dome solid.
		float f = equalise(key_raw) * neon_bands + 0.5;
		float w = max(fwidth(f), 1e-5);
		float band = abs(fract(f + 0.5) - 0.5);   // 0 on a line
		// Where the key changes faster than a band every few pixels it is noise, not a
		// contour, and lines there would sum to a white sheet: draw nothing.
		float sharp = 1.0 - smoothstep(0.12, 0.3, w);
		float line = (1.0 - smoothstep(0.6 * w, 1.7 * w, band)) * sharp;
		// A crease: the normal turns fast per metre, compared with how far a pixel spans.
		// Gated like the lines, or distant detail creases everywhere.
		float turn = length(fwidth(normalize(v_nstate)));
		float crease = smoothstep(0.35, 0.9, turn) * sharp;
		float pick = fract(floor(f) * 0.618);
		vec3 hue = pick < 0.45 ? neon_a : (pick < 0.8 ? neon_b : neon_c);
		// A dim, lit body so the shape reads between the lines, and a violet rim to hold
		// silhouettes against the dark sky.
		vec3 body = neon_body * (0.5 + 3.0 * lit + 1.2 * ao) + neon_c * 0.05 * pow(1.0 - ndv, 3.0);
		// Silhouettes glow too, so a shape whose key is flat (SPIRES' arches) still reads
		// as an outline against the dark.
		float edge = pow(1.0 - ndv, 5.0) * v_ao;
		vec3 glow = hue * line + neon_a * (crease * 0.5 + edge * 0.6);
		ALBEDO = (body + glow * neon_gain * fade) * gain * tint;
	}
	if (art_style >= 2) {
		vec3 ns = normalize(v_nstate);
		vec3 ax = abs(ns);
		vec2 uv = face_uv(v_state, ax);
		// State units per pixel, from the position (continuous where the face plane flips).
		float px = max(length(fwidth(v_state)) * 0.7, 1e-9);
		float lvl = log2(px * style_px);
		float period = exp2(floor(lvl));
		float up = fract(lvl);   // how far toward the next period up
		float sil = 1.0 - smoothstep(0.2, 0.36, ndv);
		float turn = length(fwidth(ns));
		float crease = smoothstep(0.35, 0.9, turn);
		if (art_style == 2) {
			// Colour by band of the key where it is clean per pixel (SPIRES), else by the way
			// the surface faces: floors, and walls each way (VAULT's per-vertex key is confetti).
			const vec3 TOON[4] = vec3[4](vec3(1.0, 0.82, 0.5), vec3(0.95, 0.42, 0.32),
				vec3(0.18, 0.62, 0.58), vec3(0.5, 0.46, 0.86));
			float e = pixel_trap > 0 ? equalise(trap) * 3.999
				: (ax.y > ax.x && ax.y > ax.z ? 0.5 : (ax.x > ax.z ? 2.5 : 1.5));
			vec3 col = TOON[int(floor(e))];
			float fl = max(fwidth(lit), 1e-4);
			float step_lit = smoothstep(0.22 - fl, 0.22 + fl, lit);
			float fa = max(fwidth(ao), 1e-4);
			float step_ao = smoothstep(0.3 - fa, 0.3 + fa, ao);
			vec3 tc = col * mix(0.42, 1.0, step_lit) * mix(0.72, 1.0, step_ao);
			// Ink where colour bands meet, gated like neon's lines so a busy key does not
			// turn to black fuzz, plus silhouettes and creases.
			float we = max(fwidth(e), 1e-5);
			float be = abs(fract(e + 0.5) - 0.5);
			float edge_ink = (1.0 - smoothstep(0.5 * we, 1.5 * we, be)) * (1.0 - smoothstep(0.15, 0.35, we));
			float ink = max(max(sil, crease), edge_ink * (pixel_trap > 0 ? 1.0 : 0.0));
			ALBEDO = mix(tc, vec3(0.03, 0.025, 0.04), ink) * gain * tint;
		} else if (art_style == 3) {
			float tone = (0.38 + 0.62 * lit) * mix(0.6, 1.0, ao);
			float dark = 1.0 - tone;
			// Triplanar, blended, so strokes do not snap where the facing plane flips.
			vec3 wt = ax * ax * ax * ax;
			wt /= wt.x + wt.y + wt.z;
			float ink = 0.0;
			ink += wt.x * mix(hatch(v_state.yz, period, px, dark), hatch(v_state.yz, 2.0 * period, px, dark), up);
			ink += wt.y * mix(hatch(v_state.xz, period, px, dark), hatch(v_state.xz, 2.0 * period, px, dark), up);
			ink += wt.z * mix(hatch(v_state.xy, period, px, dark), hatch(v_state.xy, 2.0 * period, px, dark), up);
			ink = max(ink, max(sil, crease * 0.7));
			// The tonemap greys a mesh's white a little against the clear colour; lift it to match.
			ALBEDO = mix(paper * 1.18, graphite, ink) * gain * tint;
		} else {
			vec3 c0 = circuit(uv, period * 2.0, px);
			vec3 c1 = circuit(uv, period * 4.0, px);
			vec3 cc = mix(c0, c1, up);
			float shade = 0.25 * ao + 0.85 * lit;
			vec3 board = vec3(0.025, 0.15, 0.07) * (0.4 + shade);
			vec3 copper = vec3(0.85, 0.52, 0.2) * (0.35 + shade);
			vec3 gold = vec3(1.0, 0.86, 0.45) * (0.5 + shade);
			vec3 cb = mix(board, copper, cc.x);
			cb = mix(cb, gold, cc.y);
			cb += vec3(0.25, 1.6, 0.45) * cc.z;   // past 1, so it blooms
			cb += vec3(0.1, 0.6, 0.3) * sil * 0.15;
			ALBEDO = cb * gain * tint;
		}
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
}
