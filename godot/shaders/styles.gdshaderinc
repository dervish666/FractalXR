// STYLE: how a surface is drawn, shared by FLY's meshes (bulb_solid), GROUND, IFS, MARCH and
// the trees. 0 = natural (the shader's own look; art_colour is not called), 1 = neon: dark
// bodies drawn in glowing lines. 2 = toon: flat colours in two light steps and ink outlines.
// 3 = pencil: graphite hatching on paper, denser and crossed in the shade. 4 = circuit:
// copper traces and pads on a green board. 5 = iridescent (thin-film interference),
// 6 = magma (obsidian ridges with glowing HDR crevices), 7 = jade (wrapped light and fake SSS),
// 8 = chrome (procedural 3-band liquid mirror reflection), 9 = opal (deep midnight potch body
// with patchy spectral diffraction fire and glass clearcoat), 10 = verdigris (satin antique
// bronze ridges with chalky pale mineral patina in crevices), 11 = frost (clear dark glacial ice
// with internal crystal facets and white hoarfrost rime), 12 = velvet (royal crimson-burgundy
// plush core with capped microfiber grazing sheen and no specular hot spot).
//
// Everything is fixed to the shape, never the screen, so both eyes see the same line on the
// same fold. Contours come from the caller's key; strokes and traces live on the plane the
// surface faces most (pos and nrm, in any frame that moves with the shape) at a power of two
// period sized in pixels, so a pattern keeps its size on screen as you shrink. Widths are in
// pixels via fwidth, and lines packed closer than a few pixels fade out instead of crawling.
// Neon's colour and magma's crevices run past 1.0 so the Environment's glow blooms them.
#ifdef ART_GLOBAL
global uniform int art_style;
#else
uniform int art_style = 0;
#endif
global uniform vec3 hand_light_pos;
global uniform vec3 hand_light_col;
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

// The half vector, safe where a + b is zero (the light exactly behind the surface from the eye):
// normalize() of zero is NaN there, and one NaN pixel smears through glow. Same cost.
vec3 half_dir(vec3 a, vec3 b) {
	vec3 h = a + b;
	return h * inversesqrt(max(dot(h, h), 1e-12));
}

// Soft world-space proximity lantern from the user's controller (V9). Skipped when off
// (hand_light_col == 0, the desktop/harness default).
vec3 hand_lantern(vec3 wpos, vec3 wnrm, vec3 wview, vec3 albedo) {
	if (dot(hand_light_col, hand_light_col) <= 1e-6) return vec3(0.0);
	vec3 hl = hand_light_pos - wpos;
	float d2 = dot(hl, hl);
	float att = 1.0 / (1.0 + d2 * 1.8);
	vec3 hd = hl * inversesqrt(max(d2, 1e-6));
	float ndl = max(dot(wnrm, hd), 0.0);
	vec3 hv = half_dir(hd, wview);
	float ndh = max(dot(wnrm, hv), 0.0);
	float s2 = ndh * ndh;
	float s4 = s2 * s2;
	float s16 = (s4 * s4) * (s4 * s4);
	return (albedo * (0.18 + 0.82 * ndl) + mix(albedo, vec3(1.0), 0.5) * 0.45 * s16 * ndl)
		* hand_light_col * att;
}

// An integer hash, as sin() hashes lose their bits on mobile GPUs.
float hash2(vec2 c) {
	uvec2 q = uvec2(ivec2(c)) * uvec2(1597334673u, 3812015801u);
	return float((q.x ^ q.y) * 1597334673u) * (1.0 / 4294967295.0);
}

// The plane a surface faces most, as 2D state coordinates: 0 yz, 1 xz, 2 xy.
vec2 face_uv(vec3 p, vec3 a) {
	return a.x > a.y && a.x > a.z ? p.yz : (a.y > a.z ? p.xz : p.xy);
}

// One pencil stroke family: thin parallel strokes along precomputed direction d = (cos, sin),
// each broken into dashes of its own length and pressed a little harder or lighter, anti-aliased
// against px (state units per pixel). Returns coverage.
float strokes(vec2 uv, float period, float px, vec2 d, float seed_id, float thick) {
	float inv_p = 1.0 / period;
	float u = dot(uv, d) * inv_p;
	float v = dot(uv, vec2(-d.y, d.x)) * inv_p;
	float h = hash2(vec2(floor(u), seed_id));
	float run = fract(v / (3.0 + 5.0 * h) + h);
	float dash = smoothstep(0.0, 0.06, run) * (1.0 - smoothstep(0.84, 0.92, run));
	float band = abs(fract(u) - 0.5);
	float w = 0.5 * px * inv_p;
	return (1.0 - smoothstep(0.5 * thick - w, 0.5 * thick + w, band)) * dash * (0.6 + 0.4 * h);
}

// Graphite on one plane at one period: a first layer from light grey, a cross layer in the
// shade and a closer third in the darkest crevices. Strokes stay thin; shade comes from more
// of them. Direction vectors are precomputed constants for angles 0.6, 2.2, 1.35.
float hatch(vec2 uv, float period, float px, float dark) {
	const vec2 D0 = vec2(0.8253356, 0.5646425);   // cos/sin(0.6)
	const vec2 D1 = vec2(-0.5885011, 0.8084964);  // cos/sin(2.2)
	const vec2 D2 = vec2(0.2190067, 0.9757234);   // cos/sin(1.35)
	float a = strokes(uv, period, px, D0, 6.0, 0.2) * smoothstep(0.12, 0.32, dark);
	float b = dark > 0.38 ? strokes(uv, period, px, D1, 22.0, 0.2) * smoothstep(0.38, 0.58, dark) : 0.0;
	float c = dark > 0.58 ? strokes(uv, 0.5 * period, px, D2, 13.0, 0.22) * smoothstep(0.58, 0.78, dark) : 0.0;
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
// Called for NPR styles 1..4 only (physical finishes 5..12 call physical_finish below).
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
		float f1 = 1.0 - ndv;
		float f2 = f1 * f1;
		float f3 = f2 * f1;
		vec3 body = neon_body * (0.5 + 3.0 * lit + 1.2 * ao) + neon_c * 0.05 * f3;
		// Silhouettes glow too, so a shape whose key is flat still reads as an outline.
		float edge = (f3 * f2) * sqrt(ao);
		vec3 glow = hue * line + neon_a * (crease * 0.5 + edge * 0.6);
		return body + glow * neon_gain * fade;
	}
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
	// Shape units per pixel, from the position (continuous where the face plane flips).
	float px = max(length(fwidth(pos)) * 0.7, 1e-12);
	float lvl = log2(px * style_px);
	float period = exp2(floor(lvl));
	float up = fract(lvl);   // how far toward the next period up
	if (art_style == 3) {
		float tone = (0.38 + 0.62 * lit) * mix(0.6, 1.0, ao);
		float dark = 1.0 - tone;
		// Triplanar, blended, so strokes do not snap where the facing plane flips.
		// Skip axes with negligible weight (on flat/axis-aligned surfaces, 2 of 3 are 0).
		vec3 wt = ax * ax * ax * ax;
		wt /= wt.x + wt.y + wt.z;
		float ink = 0.0;
		if (wt.x > 0.01) ink += wt.x * mix(hatch(pos.yz, period, px, dark), hatch(pos.yz, 2.0 * period, px, dark), up);
		if (wt.y > 0.01) ink += wt.y * mix(hatch(pos.xz, period, px, dark), hatch(pos.xz, 2.0 * period, px, dark), up);
		if (wt.z > 0.01) ink += wt.z * mix(hatch(pos.xy, period, px, dark), hatch(pos.xy, 2.0 * period, px, dark), up);
		ink = max(ink, max(sil, crease * 0.7));
		return mix(paper * PAPER_LIFT, graphite, ink);
	}
	vec2 uv = face_uv(pos, ax);
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

// Physical surface finishes (art_style 5..12):
//   5  = iridescent (thin-film bismuth interference driven by view angle and surface key)
//   6  = magma      (dark glossy obsidian ridges with glowing HDR crevices that bloom)
//   7  = jade       (translucent carved jade / alabaster with wrapped light and backlit SSS)
//   8  = chrome     (liquid mirror reflecting a 3-band horizon/sky studio gradient)
//   9  = opal       (deep indigo-black potch body with patchy spectral diffraction fire and clearcoat)
//   10 = verdigris  (satin antique bronze ridges with chalky pale mineral patina in AO crevices)
//   11 = frost      (clear dark glacial ice with internal crystal facets and white hoarfrost rime)
//   12 = velvet     (royal crimson-burgundy plush pile with capped grazing sheen, no hot spot)
// n, l and v must share the same coordinate space (view or world). refl_y is the world-space
// reflection direction's Y component (-1..1). film_key: the caller's 0..1 colour key (or half
// the palette coordinate on GROUND), which shifts interference and surface variation. Not named
// `key`: bulb_solid.gdshader has a uniform of that name.
vec3 physical_finish(vec3 albedo, vec3 hi_col, vec3 n, vec3 l, vec3 v, float refl_y,
		float sh, float ao, float film_key) {
	float ndl = max(dot(n, l), 0.0);
	float ndv = clamp(dot(n, v), 0.0, 1.0);
	float lit = ndl * sh;
	vec3 hv = half_dir(l, v);
	float ndh = max(dot(n, hv), 0.0);
	float s2 = ndh * ndh;
	float s4 = s2 * s2;
	float s8 = s4 * s4;
	float s16 = s8 * s8;
	float s64 = s16 * s16 * s16 * s16;
	float f1 = 1.0 - ndv;
	float fres = f1 * f1 * f1;

	if (art_style == 5) {
		float phase = ndv * 2.2 + film_key * 0.85;
		vec3 film = 0.5 + 0.5 * cos(6.2831853 * (phase + vec3(0.0, 0.33, 0.67)));
		vec3 film_tint = mix(albedo, film, 0.58);
		vec3 base = film_tint * (0.24 * ao + 1.15 * lit * mix(0.6, 1.0, ao));
		vec3 spec = film * (0.85 * (s16 * s8) + 0.9 * s64) * (0.25 + 0.75 * lit);
		vec3 film_rim = film * fres * 0.75 * ao;
		return base + spec + film_rim;
	}
	if (art_style == 6) {
		vec3 basalt = mix(vec3(0.025, 0.025, 0.032), albedo * 0.16, 0.45);
		vec3 c = basalt * (0.35 + 1.4 * lit) + mix(albedo, vec3(1.0), 0.55) * 0.85 * s64 * lit;
		c += hi_col * fres * 0.22 * ao;
		float crev = clamp(1.0 - ao, 0.0, 1.0);
		float heat = crev * crev * (0.45 + 0.55 * crev);
		vec3 glow = mix(albedo, hi_col, 0.65) * 1.4 + hi_col * 1.35 * crev;
		return c + glow * heat * 1.55;
	}
	if (art_style == 7) {
		float wrap = max((dot(n, l) + 0.55) / 1.55, 0.0) * mix(0.45, 1.0, sh);
		float back = clamp(dot(-l, v), 0.0, 1.0);
		float b2 = back * back;
		float sss = (0.3 + 0.7 * b2 * b2) * ao * (0.35 + 0.65 * fres);
		vec3 deep = albedo * vec3(0.42, 0.62, 0.52);
		vec3 c = mix(deep, albedo, 0.55 + 0.45 * wrap) * (0.32 * ao + 0.95 * wrap);
		c += mix(albedo, hi_col, 0.45) * sss * 0.85;
		c += mix(vec3(1.0), hi_col, 0.3) * 0.45 * s64 * lit;
		return c;
	}
	if (art_style == 8) {
		vec3 ground_band = mix(albedo * 0.28, vec3(0.06, 0.07, 0.11), 0.5);
		vec3 horizon_band = mix(hi_col, vec3(1.0, 0.96, 0.92), 0.55) * 1.15;
		vec3 zenith_band = mix(albedo * 0.85, vec3(0.28, 0.42, 0.68), 0.45);
		vec3 env_refl = refl_y < 0.0
			? mix(horizon_band, ground_band, clamp(-refl_y * 2.2, 0.0, 1.0))
			: mix(horizon_band, zenith_band, clamp(refl_y * 1.6, 0.0, 1.0));
		float hline = exp(-refl_y * refl_y * 28.0);
		env_refl += mix(hi_col, vec3(1.0), 0.7) * hline * 0.65;
		float f_chrome = 0.25 + 0.75 * fres;
		vec3 c = env_refl * mix(albedo * 0.55 + vec3(0.45), vec3(1.0), f_chrome) * mix(0.22, 1.0, ao);
		c += vec3(1.0) * 1.2 * s64 * lit;
		return c;
	}
	if (art_style == 9) {
		// Precious black opal: deep midnight-indigo potch body with smoky Tyndall scattering,
		// replaced in patchy Bragg-diffraction domains by saturated spectral fire (whole-number
		// film_key cycles so IFS's scrolling wrap never pops), finished with a glass clearcoat.
		float op_wrap = max((dot(n, l) + 0.38) / 1.38, 0.0) * mix(0.45, 1.0, sh);
		vec3 op_potch = vec3(0.012, 0.018, 0.045);
		vec3 op_tyndall = mix(vec3(0.055, 0.11, 0.21), albedo * 0.22, 0.18);
		vec3 op_body = mix(op_potch, op_tyndall, op_wrap) * mix(0.42, 1.0, ao);
		float op_h = film_key * 1.0 + ndv * 1.55 - refl_y * 0.42 + 0.22;
		vec3 op_c = 0.5 + 0.5 * cos(6.2831853 * (op_h + vec3(0.02, 0.32, 0.64)));
		vec3 op_hue = op_c * op_c;
		float op_g1 = 0.5 + 0.5 * cos(6.2831853 * (film_key * 2.0 + ndv * 1.35 - refl_y * 0.50 + 0.35));
		float op_g2 = 0.5 + 0.5 * sin(6.2831853 * (film_key * 1.0 - ndv * 1.10 + ndl * 0.60));
		float op_patch = smoothstep(0.45, 0.88, op_g1 * 0.56 + op_g2 * 0.48);
		vec3 op_fire = op_hue * (0.30 + 0.80 * lit) * mix(0.52, 1.0, ao) * 1.15;
		vec3 op_col = mix(op_body, op_fire, op_patch * mix(0.52, 1.0, ao));
		op_col += mix(vec3(0.14, 0.28, 0.48), op_hue * 0.85, 0.55) * fres * 0.34 * mix(0.45, 1.0, ao);
		op_col += vec3(0.95, 0.98, 1.0) * (0.08 * s16 + 0.78 * s64) * (0.25 + 0.75 * lit);
		return op_col;
	}
	if (art_style == 10) {
		// Antique statuary bronze with chalky, pale desaturated mineral verdigris crust in AO
		// crevices. Patina boundary keys only on ao and whole-number film_key cycles (never a
		// reflection term, so both eyes see the same crust edge and IFS's wrap never pops).
		float vg_var = 0.14 * sin(6.2831853 * film_key) + 0.06 * cos(6.2831853 * (film_key * 2.0));
		float vg_pat = 1.0 - smoothstep(0.18, 0.64, ao + vg_var);
		float vg_seam = 4.0 * vg_pat * (1.0 - vg_pat);
		vec3 vg_metal = mix(vec3(0.28, 0.16, 0.075), albedo * vec3(0.55, 0.34, 0.16), 0.20);
		vec3 vg_env = refl_y < 0.0
			? mix(vec3(0.50, 0.32, 0.14), vec3(0.03, 0.02, 0.01), clamp(-refl_y * 2.0, 0.0, 1.0))
			: mix(vec3(0.50, 0.32, 0.14), vec3(0.14, 0.11, 0.09), clamp(refl_y * 1.5, 0.0, 1.0));
		vec3 vg_bronze = vg_metal * (0.14 * ao + 0.86 * lit)
			+ vg_env * vg_metal * (0.38 + 0.48 * fres) * mix(0.25, 1.0, ao)
			+ vec3(0.86, 0.62, 0.34) * (0.40 * s8 + 0.28 * s16 + 0.22 * s64) * (0.20 + 0.80 * lit);
		vg_bronze *= 1.0 - 0.36 * vg_seam;
		float vg_wrap = max((dot(n, l) + 0.55) / 1.55, 0.0) * mix(0.50, 1.0, sh);
		float vg_mottle = 0.5 + 0.5 * sin(6.2831853 * (film_key * 2.0 + 0.2));
		vec3 vg_pale = mix(vec3(0.22, 0.46, 0.35), vec3(0.36, 0.56, 0.43), vg_mottle);
		vec3 vg_shade = mix(vec3(0.07, 0.19, 0.15), vec3(0.11, 0.26, 0.21), vg_mottle);
		vec3 vg_ox = mix(vg_shade, vg_pale, 0.25 + 0.75 * vg_wrap);
		vg_ox = mix(vg_ox, vec3(0.42, 0.58, 0.47), vg_seam * 0.35);
		vg_ox *= 0.48 + 0.52 * mix(0.45, 1.0, ao);
		vg_ox += vec3(0.28, 0.46, 0.37) * fres * 0.12 * (0.4 + 0.6 * vg_wrap);
		return mix(vg_bronze, vg_ox, vg_pat);
	}
	if (art_style == 11) {
		// Glacial crystal ice and hoarfrost rime: clear dark sapphire-teal facing the eye, with
		// brightness carried by sharp internal crystal facets (integer film_key cycles), backlit
		// transmission, icy Fresnel reflection and chalky snow-white rime along edges and ridges.
		float fr_back = clamp(dot(-l, v), 0.0, 1.0);
		float fr_b2 = fr_back * fr_back;
		float fr_sss = (0.18 + 0.82 * fr_b2 * fr_b2) * mix(0.38, 1.0, ao) * (0.20 + 0.80 * fres);
		vec3 fr_abyss = vec3(0.006, 0.025, 0.075);
		vec3 fr_depth = mix(vec3(0.015, 0.09, 0.22), albedo * vec3(0.06, 0.18, 0.34), 0.12);
		float fr_core_l = (0.15 + 0.85 * lit) * (0.20 + 0.80 * f1);
		vec3 fr_ice = mix(fr_abyss, fr_depth, fr_core_l) * mix(0.32, 1.0, ao * ao)
			+ vec3(0.06, 0.52, 0.82) * fr_sss * 0.62;
		float fr_c1 = abs(cos(6.2831853 * (film_key * 1.0 + ndv * 1.40 - refl_y * 0.55)));
		float fr_c2 = abs(sin(6.2831853 * (film_key * 2.0 - ndv * 0.95 + ndl * 0.50)));
		float fr_p1 = fr_c1 * fr_c1;
		fr_p1 = fr_p1 * fr_p1 * fr_p1;
		float fr_p2 = fr_c2 * fr_c2;
		fr_p2 = fr_p2 * fr_p2 * fr_p2;
		float fr_facet = max(fr_p1, fr_p2 * 0.72);
		fr_ice += vec3(0.45, 0.88, 1.0) * fr_facet * (0.30 + 0.70 * lit) * mix(0.50, 1.0, ao) * 0.78;
		vec3 fr_refl = mix(vec3(0.18, 0.52, 0.80), vec3(0.76, 0.93, 1.0), smoothstep(-0.2, 0.65, refl_y));
		fr_ice += fr_refl * fres * 0.48 * mix(0.52, 1.0, ao);
		float fr_wrap = max((dot(n, l) + 0.35) / 1.35, 0.0) * mix(0.45, 1.0, sh);
		float fr_edge = smoothstep(0.14, 0.68, fres);
		float fr_frost_top = smoothstep(0.45, 0.90, refl_y) * smoothstep(0.45, 0.90, ao) * 0.42;
		float fr_rime = clamp(fr_edge * 0.88 + fr_frost_top, 0.0, 1.0) * mix(0.46, 1.0, ao);
		vec3 fr_snow = vec3(0.84, 0.94, 1.0) * (0.36 + 0.64 * fr_wrap);
		vec3 fr_col = mix(fr_ice, fr_snow, fr_rime * 0.82);
		fr_col += vec3(0.92, 0.98, 1.0) * (0.14 * (s16 * s8) + 0.95 * s64) * (0.25 + 0.75 * lit);
		return fr_col;
	}
	if (art_style == 12) {
		// Royal plush velvet: deep crimson-burgundy dye gently tinted by the palette (capped sat
		// push), inverted-Fresnel light-trapping core, bounded microfiber grazing sheen so GROUND
		// never clips, whole-number film_key nap wave, and no specular hot spot.
		float vl_lum = dot(albedo, vec3(0.2126, 0.7152, 0.0722));
		vec3 vl_pal = max(mix(vec3(vl_lum), albedo, 1.25), vec3(0.0));
		float vl_pm = max(vl_pal.r, max(vl_pal.g, vl_pal.b));
		vec3 vl_pal_norm = vl_pal * (min(vl_pm, 0.65) / max(vl_pm, 0.05));
		float vl_wave = 0.5 + 0.5 * cos(6.2831853 * (film_key * 1.0 + refl_y * 0.35));
		vec3 vl_royal = mix(vec3(0.36, 0.020, 0.11), vec3(0.58, 0.042, 0.14), vl_wave);
		float vl_tone = 0.26 + 0.74 * smoothstep(0.015, 0.22, vl_lum);
		vec3 vl_dye = mix(vl_royal, vl_pal_norm * vec3(0.75, 0.35, 0.58), 0.22) * vl_tone;
		float vl_nap = 0.78 + 0.22 * vl_wave;
		float vl_pile = 0.25 + 0.75 * f1;
		vec3 vl_core = vl_dye * (0.18 + 0.58 * lit) * vl_pile * vl_nap * mix(0.42, 1.0, ao);
		float vl_f2 = f1 * f1;
		float vl_fuzz = 0.52 * vl_f2 + 0.48 * fres;
		float vl_wrap = max((dot(n, l) + 0.45) / 1.45, 0.0) * mix(0.45, 1.0, sh);
		vec3 vl_rim_tint = mix(vec3(0.70, 0.17, 0.31), vec3(0.80, 0.30, 0.42), vl_wave) * vl_tone;
		vec3 vl_sheen = mix(vl_dye * 1.25, vl_rim_tint, 0.75);
		vec3 vl_fuzz_col = vl_sheen * vl_fuzz * (0.34 + 0.66 * vl_wrap) * mix(0.55, 1.0, ao) * vl_nap;
		float vl_retro = clamp(dot(l, v), 0.0, 1.0);
		vec3 vl_back = vl_dye * (0.14 * vl_retro * vl_retro * vl_wrap) * mix(0.40, 1.0, ao);
		return vl_core + vl_fuzz_col + vl_back;
	}
	// Plain diffuse fallback for any unmapped future style index.
	return albedo * (0.25 * ao + 0.75 * lit);
}
