// STYLE: how a surface is drawn, shared by FLY's meshes (bulb_solid), GROUND, IFS and the
// trees. 0 = natural (the shader's own look; art_colour is not called), 1 = neon: dark
// bodies drawn in glowing lines. 2 = toon: flat colours in two light steps and ink outlines.
// 3 = pencil: graphite hatching on paper, denser and crossed in the shade. 4 = circuit:
// copper traces and pads on a green board.
//
// Everything is fixed to the shape, never the screen, so both eyes see the same line on the
// same fold. Contours come from the caller's key; strokes and traces live on the plane the
// surface faces most (pos and nrm, in any frame that moves with the shape) at a power of two
// period sized in pixels, so a pattern keeps its size on screen as you shrink. Widths are in
// pixels via fwidth, and lines packed closer than a few pixels fade out instead of crawling.
// Neon's colour runs past 1.0 so the Environment's glow (threshold 1, main.tscn) blooms it.
#ifdef ART_GLOBAL
global uniform int art_style;
#else
uniform int art_style = 0;
#endif
uniform float neon_bands = 11.0;
uniform float neon_gain = 2.0;
uniform float neon_far = 80.0;   // metres: lines fade out by here (and FLY's per-pixel key stops)
uniform vec3 neon_a = vec3(0.12, 0.85, 1.0);
uniform vec3 neon_b = vec3(1.0, 0.22, 0.72);
uniform vec3 neon_c = vec3(0.55, 0.35, 1.0);
uniform vec3 neon_body = vec3(0.004, 0.005, 0.012);
// FLY's meshes draw a little grey against the clear colour through its light; they lift the
// paper to match (bulb_solid defines this as 1.18).
#ifndef PAPER_LIFT
#define PAPER_LIFT 1.0
#endif
uniform float style_px = 12.0;       // pattern period, in pixels, give or take an octave
uniform vec3 paper = vec3(0.92, 0.9, 0.85);
uniform vec3 graphite = vec3(0.12, 0.12, 0.15);

// An integer hash, as sin() hashes lose their bits on mobile GPUs.
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

// f: the contour coordinate, a line at every whole number (keep a saturated key off whole
// numbers, or a flat region is all line). toon_e: toon's colour, 0 to 3.999, inked where it
// changes band; below 0, colour by facing instead (floors, and walls each way). pos, nrm: a
// frame fixed to the shape. lit: 0 to 1 sun on the surface. ao: 0 to 1, 1 open. ndv: facing
// the eye. dist: metres from the eye. Returns linear colour before the caller's gain.
vec3 art_colour(float f, float toon_e, vec3 pos, vec3 nrm, float lit, float ao, float ndv, float dist) {
	vec3 ns = normalize(nrm);
	vec3 ax = abs(ns);
	float turn = length(fwidth(ns));
	if (art_style == 1) {
		float fade = 1.0 - smoothstep(0.5 * neon_far, neon_far, dist);
		float w = max(fwidth(f), 1e-5);
		float band = abs(fract(f + 0.5) - 0.5);   // 0 on a line
		// Where the key changes faster than a band every few pixels it is noise, not a
		// contour, and lines there would sum to a white sheet: draw nothing.
		float sharp = 1.0 - smoothstep(0.12, 0.3, w);
		float line = (1.0 - smoothstep(0.6 * w, 1.7 * w, band)) * sharp;
		// A crease: the normal turns fast across a pixel. Gated like the lines, or distant
		// detail creases everywhere.
		float crease = smoothstep(0.35, 0.9, turn) * sharp;
		float pick = fract(floor(f) * 0.618);
		vec3 hue = pick < 0.45 ? neon_a : (pick < 0.8 ? neon_b : neon_c);
		// A dim, lit body so the shape reads between the lines, and a violet rim.
		vec3 body = neon_body * (0.5 + 3.0 * lit + 1.2 * ao) + neon_c * 0.05 * pow(1.0 - ndv, 3.0);
		// Silhouettes glow too, so a shape whose key is flat still reads as an outline.
		float edge = pow(1.0 - ndv, 5.0) * sqrt(ao);
		vec3 glow = hue * line + neon_a * (crease * 0.5 + edge * 0.6);
		return body + glow * neon_gain * fade;
	}
	vec2 uv = face_uv(pos, ax);
	// Shape units per pixel, from the position (continuous where the face plane flips).
	float px = max(length(fwidth(pos)) * 0.7, 1e-12);
	float lvl = log2(px * style_px);
	float period = exp2(floor(lvl));
	float up = fract(lvl);   // how far toward the next period up
	float sil = 1.0 - smoothstep(0.2, 0.36, ndv);
	float crease = smoothstep(0.35, 0.9, turn);
	if (art_style == 2) {
		const vec3 TOON[4] = vec3[4](vec3(1.0, 0.82, 0.5), vec3(0.95, 0.42, 0.32),
			vec3(0.18, 0.62, 0.58), vec3(0.5, 0.46, 0.86));
		float e = toon_e >= 0.0 ? toon_e
			: (ax.y > ax.x && ax.y > ax.z ? 0.5 : (ax.x > ax.z ? 2.5 : 1.5));
		vec3 col = TOON[int(clamp(floor(e), 0.0, 3.0))];
		float fl = max(fwidth(lit), 1e-4);
		float step_lit = smoothstep(0.22 - fl, 0.22 + fl, lit);
		float fa = max(fwidth(ao), 1e-4);
		float step_ao = smoothstep(0.3 - fa, 0.3 + fa, ao);
		vec3 tc = col * mix(0.42, 1.0, step_lit) * mix(0.72, 1.0, step_ao);
		// Ink where colour bands meet, gated like neon's lines so a busy key does not turn to
		// black fuzz, plus silhouettes and creases.
		float we = max(fwidth(e), 1e-5);
		float be = abs(fract(e + 0.5) - 0.5);
		float edge_ink = (1.0 - smoothstep(0.5 * we, 1.5 * we, be)) * (1.0 - smoothstep(0.15, 0.35, we));
		float ink = max(max(sil, crease), edge_ink * (toon_e >= 0.0 ? 1.0 : 0.0));
		return mix(tc, vec3(0.03, 0.025, 0.04), ink);
	}
	if (art_style == 3) {
		float tone = (0.38 + 0.62 * lit) * mix(0.6, 1.0, ao);
		float dark = 1.0 - tone;
		// Triplanar, blended, so strokes do not snap where the facing plane flips.
		vec3 wt = ax * ax * ax * ax;
		wt /= wt.x + wt.y + wt.z;
		float ink = 0.0;
		ink += wt.x * mix(hatch(pos.yz, period, px, dark), hatch(pos.yz, 2.0 * period, px, dark), up);
		ink += wt.y * mix(hatch(pos.xz, period, px, dark), hatch(pos.xz, 2.0 * period, px, dark), up);
		ink += wt.z * mix(hatch(pos.xy, period, px, dark), hatch(pos.xy, 2.0 * period, px, dark), up);
		ink = max(ink, max(sil, crease * 0.7));
		return mix(paper * PAPER_LIFT, graphite, ink);
	}
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
	return cb;
}
