shader_type spatial;
render_mode unshaded, cull_front, depth_draw_always, fog_disabled, shadows_disabled, specular_disabled;

// Raymarched bulb surface. The alternative to splatting a distance-estimate shell: every
// pixel sphere-traces the same DE the compute shader projects particles onto, so the
// surface is crisp at any distance, lit from its true normal, and costs nothing when
// not on screen. The price is per-pixel DE evaluations, which is what SURFACE and DETAIL
// are for measuring.
//
// The mesh is a box in the cloud's local space, drawn back-faces-only so it covers the
// silhouette whether the head is inside it or out. Rays are built from the inverse
// MODELVIEW in the vertex stage: that matrix is per eye under multiview, so the two
// eyes get their own origins with nothing left to guess about CAMERA_POSITION_WORLD.
//
// The DE functions are in bulb_de.gdshaderinc, a straight port of bulb.glsl; keep them in step.

uniform float bound = 1.3;

uniform vec3 cloud_center = vec3(0.0);
uniform float cloud_fit = 1.0;

uniform vec3 pal0 = vec3(0.0);
uniform vec3 pal1 = vec3(0.25, 0.0, 0.3);
uniform vec3 pal2 = vec3(0.9, 0.2, 0.4);
uniform vec3 pal3 = vec3(1.0, 0.6, 0.1);
uniform vec3 pal4 = vec3(1.0, 0.95, 0.65);
uniform float palette_cycles = 1.0;
global uniform float colour_cycle;
uniform float gain = 1.0;
uniform int max_steps = 64;

// Fragment VERTEX is view-space in Godot's spatial pipeline. Keep the per-eye inverse
// model-view rotation, state-space ray origin and scale flat from the vertex stage.
varying flat mat3 v_inv_mv3;
varying flat vec3 v_ro;
varying flat float v_mscale;

// Metres from the eye the box's vertices are pulled in to. ENTER scales the cloud by
// up to 60x, which puts the box's back faces a kilometre out, past the camera's far
// plane, and a clipped back face draws nothing: a black view from inside. Moving a
// vertex along its own eye ray leaves every fragment's ray unchanged (the fragment's
// view-space position is only ever normalised into a direction) and the depth comes
// from the march, not the mesh, so this is exact.
const float VERTEX_REACH = 90.0;

void vertex() {
	mat4 inv_mv = inverse(MODELVIEW_MATRIX);
	vec3 eye_l = inv_mv[3].xyz;
	v_inv_mv3 = mat3(inv_mv);
	v_ro = eye_l / cloud_fit + cloud_center;
	v_mscale = 1.0 / max(length(inv_mv[0].xyz), 1e-9);
	vec3 to_v = VERTEX - eye_l;
	float d = length((MODELVIEW_MATRIX * vec4(to_v, 0.0)).xyz);
	if (d > VERTEX_REACH) { VERTEX = eye_l + to_v * (VERTEX_REACH / d); }
}

#include "res://shaders/bulb_de.gdshaderinc"
#define ART_GLOBAL
#include "res://shaders/styles.gdshaderinc"

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

void fragment() {
	// Ray in the cloud's local space, then into state (DE) space. State space is a
	// uniform scale and offset of local, so directions carry over unchanged. In the
	// fragment stage VERTEX is already the eye-to-fragment direction in VIEW space.
	vec3 vdir = normalize(VERTEX);
	vec3 rd = normalize(v_inv_mv3 * vdir);
	vec3 ro = v_ro;

	// Start at the bounding sphere, or at the eye when the head is inside it. `bound` is
	// already march_bound(), 8-15% past the measured extent, and the extra 1.15 looks
	// redundant, but it is load-bearing from the inside: dropping it (2026-09-23) cut the
	// lit pixels of the inside Mandelbox view from 14% to 4%, because the escape walk and
	// the march both stop at t1 and the far walls sit past the tighter sphere.
	float R = bound * 1.15;
	float b = dot(ro, rd);
	float cc = dot(ro, ro) - R * R;
	float h = b * b - cc;
	// A ray that misses the sphere is not discarded here: dFdx/dFdy below need every pixel
	// of the 2x2 quad alive, or a hit beside a miss reads undefined derivatives (NaN on
	// Adreno) and the silhouette pixel lights wrongly. It skips the march instead.
	bool outside = h < 0.0;
	h = sqrt(max(h, 0.0));
	float t0 = max(0.0, -b - h);
	float t1 = -b + h;
	outside = outside || t1 <= 0.0;

	// One pixel's angular size, so the stopping distance grows with range: near
	// surfaces get the fine detail, far ones stop early instead of stalling.
	float pix = 2.0 / (VIEWPORT_SIZE.y * PROJECTION_MATRIX[1][1]);

	float t = t0;
	float eps = 1e-4 * bound;
	vec4 r = vec4(0.0);
	int steps = 0;
	bool hit = false;
	// A head inside the solid (the Mandelbox's origin is in the set, and a grab can push
	// you through any wall) would hit at the first sample and paint the whole view one
	// colour. Instead the ray walks out of the solid in fixed strides and then marches
	// normally, so the far wall of whatever cavity lies ahead is what you see.
	bool clear = false;
	float stride = 0.012 * bound;
	for (int i = 0; i < max_steps; i++) {
		if (outside) { break; }
		vec3 pos = ro + rd * t;
		eps = max(t * pix * 1.0, 1e-5 * bound);
		r = de(pos, eps * 0.5);
		steps = i;
		if (!clear) {
			// The escape walk used a fixed 24 iterations, which made a 12-step quality
			// mode never enter the real march and shade its bounding sphere instead.
			if (r.x > 2.0 * eps + 1e-4 * bound || i >= min(max_steps / 2, 24)) { clear = true; }
			else { t += stride; if (t > t1) { break; } continue; }
		}
		if (r.x < eps) { hit = true; break; }
		t += r.x * 0.85;
		if (t > t1) { break; }
	}
	// The derivative of the hit positions is the rendered surface normal. It is stable
	// at the screen resolution the marcher can display and replaces the four extra DE
	// samples of a tetrahedral gradient after every successful ray. Taken BEFORE the
	// discard, with misses parked at their exit point, so every quad pixel contributes.
	vec3 pos = ro + rd * (hit ? t : t1);
	vec3 dn = cross(dFdx(pos), dFdy(pos));
	// Natural and the finishes take no derivatives past this point, so a miss leaves now and
	// pays for no shading. The four NPR styles (art_colour's fwidth) keep it alive to the end.
	if (!hit && (art_style < 1 || art_style > 4)) { discard; }
	// Degenerate at a silhouette where a neighbour missed: face the ray rather than NaN.
	vec3 n = dot(dn, dn) > 1e-24 ? normalize(dn) : -rd;
	vec3 v = -rd;
	// Different DE families disagree about the sign around their interior folds. The
	// visible side of a two-sided marched shell is always the side facing the ray; make
	// lighting consistent rather than leaving one formula lit from behind.
	if (dot(n, v) < 0.0) n = -n;
	float ndv = max(dot(n, v), 0.0);
	const vec3 KEY = vec3(0.485643, 0.825593, 0.291386);   // normalize(0.5, 0.85, 0.3)
	float ndk = max(dot(n, KEY), 0.0);
	// Depth complexity as a second occlusion cue: rays that crawled in took many steps.
	float crawl = 1.0 - 0.5 * float(steps) / float(max_steps);
	// The crawl term is a free, stable cavity cue. An additional DE probe here was a
	// sixth expensive DE evaluation after each hit and dominated the visible detail.
	float ao_raw = crawl;
	float ao = mix(0.45, 1.0, ao_raw * ao_raw);

	// VERTEX is the view-space ray. t is in state units, so apply the state/local fit
	// and the cloud's uniform node scale before writing its real depth.
	float hit_dist = t * cloud_fit * v_mscale;
	vec3 hit_view = vdir * hit_dist;
	vec3 wpos = (INV_VIEW_MATRIX * vec4(hit_view, 1.0)).xyz;
	vec3 wn = normalize((MODEL_MATRIX * vec4(n, 0.0)).xyz);
	vec3 wview = normalize(CAMERA_POSITION_WORLD - wpos);

	// Same orbit-trap coordinate the compute path stores per particle, so a palette
	// bands the surface the way it bands the splats.
	float trap = clamp((r.y * 0.7 + r.z * 0.5) * 0.45, 0.0, 1.0);
	float col = clamp(0.65 * ao_raw + 0.35 * trap, 0.0, 1.0);
	vec3 c;
	if (art_style >= 1 && art_style <= 4) {
		c = art_colour(col * neon_bands + 0.5, col * 3.999, pos, n, ndk, ao, ndv, hit_dist);
	} else {
		vec3 albedo = palette(cycle_u(col));
		if (colour_cycle > 0.0)
			albedo = keep_luma(albedo, dot(palette(fract(col * palette_cycles)), vec3(0.2126, 0.7152, 0.0722)));
		if (art_style >= 5) {
			float refl_y = reflect(-wview, wn).y;
			c = physical_finish(albedo, pal4, n, KEY, v, refl_y, 1.0, ao_raw * ao_raw, col);
		} else {
			// V4: two-tone hemisphere ambient + metallic sheen & tight gloss highlight.
			vec3 hemi = mix(vec3(0.10, 0.11, 0.16), vec3(0.26, 0.30, 0.38), wn.y * 0.5 + 0.5);
			c = albedo * (hemi + vec3(0.32 * ndv + 0.92 * ndk)) * ao * crawl;
			vec3 hv = half_dir(KEY, v);
			float ndh = max(dot(n, hv), 0.0);
			float s2 = ndh * ndh;
			float s4 = s2 * s2;
			float s8 = s4 * s4;
			float s16 = s8 * s8;
			float s64 = s16 * s16 * s16 * s16;
			c += albedo * 0.75 * (s16 * s8) * ndk * ao;
			c += mix(albedo, vec3(1.0), 0.35) * 0.65 * s64 * ndk * ao;
			float f1 = 1.0 - ndv;
			float fres = f1 * f1 * f1;
			c += pal4 * fres * 0.38 * ao;
		}
		c += hand_lantern(wpos, wn, wview, albedo);
	}
	ALBEDO = c * gain;

	vec4 clip = PROJECTION_MATRIX * vec4(hit_view, 1.0);
	DEPTH = clip.z / clip.w;
	// A budget miss must stay a miss. Treating it as a hit painted the enclosing seed
	// sphere when a low-step ray had not reached the actual DE surface yet. Under an NPR style
	// it is discarded here, last, so art_colour's fwidth had every pixel of the quad alive.
	if (!hit) { discard; }
}
