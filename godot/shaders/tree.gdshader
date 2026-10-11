shader_type spatial;
render_mode unshaded, cull_back, fog_disabled, shadows_disabled;

// Fractal tree branches: one instanced unit cylinder per segment. The instance transform
// carries position, direction, length and radius; INSTANCE_CUSTOM carries (birth, taper,
// level, phase), and the branches ignore phase since the flutter follows position. Growth
// and wind live here so the script never touches the buffer again: a segment extends
// from its base once the growth clock passes its birth, and every vertex is displaced by
// one wind field of height, so the whole tree bends as one thing and joints never pull
// apart.

uniform vec3 pal0 = vec3(0.05, 0.02, 0.0);
uniform vec3 pal1 = vec3(0.35, 0.18, 0.05);
uniform vec3 pal2 = vec3(0.6, 0.45, 0.2);
uniform vec3 pal3 = vec3(0.9, 0.8, 0.3);
uniform vec3 pal4 = vec3(1.0, 0.95, 0.7);
uniform float brightness = 1.0;
uniform float grow_t = 0.0;         // seconds since the seed
uniform float grow_s = 6.0;         // seconds to full height
uniform float tree_height = 3.0;    // metres, before the node's scale
uniform float wind = 0.3;
uniform vec3 tree_origin = vec3(0.0);
uniform vec3 tree_up = vec3(0.0, 1.0, 0.0);
uniform vec3 wind_dir = vec3(1.0, 0.0, 0.0);
uniform float tree_scale = 1.0;
// Forest trees: a small tree sways less in metres (1.0 for the hero), and each tree's
// gust arrives a little later the further downwind it stands, so wind crosses a grove
// instead of every tree nodding in step.
uniform float sway_gain = 1.0;
uniform float sway_phase = 0.0;
// The darkest palette stop is very nearly black in most themes, and the trunk sits on
// it, against a black void, under a 0.25 ambient floor. The result was a canopy hanging
// in mid-air. Lifting the darkest stop this far toward the next one keeps the trunk the
// darkest thing in the tree without making it the darkest thing in the room.
uniform float trunk_lift = 0.2;
// How much of the colour coordinate comes from height rather than recursion level.
// Level alone is an integer per branch, so the palette changed in visible steps: a
// band of one colour, then a band of the next, with a hard line between them. Height
// is continuous along the whole tree, and mixing a little level back in keeps a low
// side branch from reading as trunk.
uniform float colour_height = 0.7;
// Species bark: turn the theme's hue, then pull toward a species colour at the theme's
// own lightness, so a birch is pale and a baobab grey in every theme without either
// leaving it. All zero for oak, which draws exactly the theme.
uniform float bark_hue = 0.0;
uniform vec3 bark_tint = vec3(1.0);
uniform float bark_mix = 0.0;
// Where the crown sits on the theme, in turns (forest.gd's avenue walks it down the rows,
// with the leaves). The twig end of the ramp moves from pal2 toward pal3 and back; the trunk
// end never moves. 0 is the ramp exactly as before.
uniform float palette_phase = 0.0;
// CYCLE (main.gd, the COLOUR card), in turns: added to every tree's phase, so an avenue's
// colour rolls along the rows. A global every mode reads; 0 is the colour as before.
global uniform float colour_cycle;
// The far batch (far_forest.gd): many trees of one species in one MultiMesh, each instance
// composed into the avenue's frame. What is per tree there rides in the instance instead of a
// uniform: COLOR.r the level, COLOR.g the tree's bark hue, CUSTOM.x the birth on the shared
// clock (grow_s is 1), CUSTOM.z the tree's height and CUSTOM.w its palette phase. Off, every
// line below reads exactly as before.
uniform bool batch = false;

// --- BARK (T-55): a fractal pattern grown into the wood. Additive to the above: at bark_style 0,
// and in the far batch whatever the style, every line reads exactly as before. ------------------
// 1 veins: a 3D Kaliset (p = |p| / p.p - c), the orbit's step lengths summed into veins. Organic
//          and cellular, lit from inside like the flames' filaments.
// 2 julia: the San Marco Julia set's orbit trap, a lace of Julia filigree up the wood.
// Mapping: around the branch, the cylinder's own cross-section times the local radius, so the
// pattern wraps with no seam, and a twig a few millimetres of pattern round comes out smooth, as
// twigs are. Along it, metres from the tree's base: fractal_tree.gd passes the distance to each
// segment's start in COLOR.b, so the pattern runs on unbroken from a segment into its child. Both
// from the undeformed, fully grown vertex, as the colour is: wind and growth never slide it, and
// the viewer moving changes nothing.
// Stereo: past a footprint of BARK_FADE pattern units per pixel the pattern fades to its mean
// (fwidth, per eye), and its lines widen with the footprint before that, so nothing finer than a
// few pixels is drawn. A fragment past the fade skips the loop, so far trees pay nothing extra.
// It modulates the tree's own ramp and lifts toward the crown's tip colour, so a theme or a
// cycling palette recolours it for free.
uniform int bark_style = 0;
uniform float bark_cell = 0.2;   // metres of tree per pattern unit (the julia lace runs 1.5x that)
uniform float bark_glow = 1.0;   // how much the brightest lines lean toward the crown's tip colour

// Rotate a colour about the grey axis (Rodrigues). Angle 0 returns it unchanged.
vec3 hue_turn(vec3 c, float a) {
	const vec3 k = vec3(0.57735027);
	float ca = cos(a);
	return c * ca + cross(k, c) * sin(a) + k * dot(k, c) * (1.0 - ca);
}

varying float v_u;
varying vec3 v_normal_w;
varying vec3 v_world;
varying flat float v_phase;
varying flat float v_bark_hue;
varying vec3 v_bark;   // BARK's coordinate, in pattern units (see the uniforms)

// BARK's two patterns, each scaled to 0..1, and their means over branches 2-10 cm thick and 3 m of
// wood (a numpy port of these functions, 200k samples). The fade lands on the mean, and the colour
// is built so the mean gives the plain bark exactly: a far trunk is the colour its near pattern
// averages to, and the far batch's plain trees match it.
const float BARK_FADE = 0.1;      // pattern units a pixel: on the Quest, going at 7 m, gone by 18
const float VEINS_SCALE = 2.3;    // the veins' 99th percentile is 0.44
const float VEINS_MEAN = 0.32;    // 0.139 x VEINS_SCALE
const float VEINS_HI = 2.2;       // the brightest vein, against the plain bark
const float JULIA_MEAN = 0.07;
const float JULIA_HI = 4.0;

float bark_veins(vec3 p, float soft) {
	p = abs(mod(p + 0.37, 2.0) - 1.0);
	const vec3 c = vec3(0.7, 0.4, 0.6);
	float acc = 0.0;
	float prev = 0.0;
	for (int i = 0; i < 7; i++) {
		p = abs(p) / max(dot(p, p), 1e-4) - c;
		float l = length(p);
		acc += exp(-soft * abs(l - prev));
		prev = l;
	}
	return acc / 7.0;
}

float bark_julia(vec3 p, float soft) {
	// Around: arc length from the branch's front, mirrored at the back so the wrap has no seam.
	float around = abs(atan(p.z, p.x)) * length(p.xz);
	vec2 f = abs(mod(vec2(around, p.y) / 1.5, 2.0) - 1.0);
	vec2 z = vec2(f.x * 1.5, (f.y * 2.0 - 1.0) * 1.1);
	// A ring trap (the orbit's closest pass to |z| = 0.5) draws the San Marco set's chain of
	// bulbs as a lace round the wood; an axis trap filled whole regions with glow.
	float trap = 1e3;
	for (int i = 0; i < 10; i++) {
		z = vec2(z.x * z.x - z.y * z.y, 2.0 * z.x * z.y) + vec2(-0.75, 0.11);
		trap = min(trap, abs(length(z) - 0.5));
		if (dot(z, z) > 64.0) {
			break;
		}
	}
	return exp(-trap * soft);
}

// The ramp colour `base` with the pattern in it: darker wood between the lines, brighter lines
// leaning toward the crown's tip colour. Linear in the pattern and pinned so its mean gives `base`.
vec3 bark(vec3 base, vec3 p, vec3 tip) {
	vec3 fw = fwidth(p);
	float foot = max(max(fw.x, fw.y), fw.z);
	float detail = 1.0 - smoothstep(BARK_FADE * 0.4, BARK_FADE, foot);
	bool veins = bark_style == 1;
	float mean = veins ? VEINS_MEAN : JULIA_MEAN;
	float hi = veins ? VEINS_HI : JULIA_HI;
	float v = mean;
	if (detail > 0.0) {
		float soft = 1.0 / (1.0 + foot * 30.0);   // lines widen as the footprint grows
		v = veins ? min(bark_veins(p, 5.0 * soft) * VEINS_SCALE, 1.0) : bark_julia(p, 30.0 * soft);
		v = mix(mean, v, detail);
	}
	float lo = (1.0 - hi * mean) / (1.0 - mean);
	return base * mix(lo, hi, v) + tip * (bark_glow * 0.3 * max(v - mean, 0.0));
}

// One displacement field for branches and leaves: lateral bend growing with the square
// of height (a cantilever), a slow body sway, a faster ripple up the trunk, and a small
// per-branch flutter. Metres, in world space.
// The flutter phase comes from the point's place in the tree, not from its branch: with a
// phase per branch, a parent's tip ring and its child's base ring fluttered apart by up to
// 0.3 x amp. A smooth field of position gives both rings the same phase.
float flutter_phase(vec3 w0) {
	return dot(w0 - tree_origin, vec3(1.7, 0.9, 1.3)) / max(tree_scale, 1e-3);
}

vec3 sway(vec3 w, float phase) {
	float h = clamp(dot(w - tree_origin, tree_up) / max(tree_height * tree_scale, 1e-3), 0.0, 1.5);
	float t = TIME + sway_phase;
	float g = sin(t * 0.7) * 0.6 + sin(t * 1.9 + h * 2.0) * 0.25 + sin(t * 3.1 + phase) * 0.15;
	vec3 lateral = cross(tree_up, cross(wind_dir, tree_up));
	lateral = normalize(lateral + vec3(1e-5, 0.0, 0.0));
	float amp = wind * 0.12 * h * h * tree_scale * sway_gain;
	return w + lateral * (amp * g) - tree_up * (amp * 0.2 * abs(g));
}

void vertex() {
	float birth = INSTANCE_CUSTOM.x;
	float taper = INSTANCE_CUSTOM.y;
	float level = batch ? COLOR.r : INSTANCE_CUSTOM.z;
	float th = batch ? INSTANCE_CUSTOM.z : tree_height;
	v_phase = INSTANCE_CUSTOM.w;
	v_bark_hue = COLOR.g;
	// Growth: extends from the base over 0.9 s after birth, thickening with it.
	float g = clamp((grow_t - birth * grow_s) / 0.9, 0.0, 1.0);
	g = g * g * (3.0 - 2.0 * g);
	float y01 = VERTEX.y + 0.5;    // the unit cylinder is centred: 0 at the base, 1 at the tip
	vec3 v = VERTEX;
	v.xz *= mix(1.0, taper, y01) * g;
	v.y = y01 * g - 0.5;
	// Colour from the undeformed, fully-grown position: wind bends the geometry and
	// growth extends it, and neither should slide the palette along the trunk.
	vec3 w0 = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float h01 = clamp(dot(w0 - tree_origin, tree_up) / max(th * tree_scale, 1e-3), 0.0, 1.0);
	v_u = mix(level, h01, colour_height);
	v_bark = vec3(0.0);
	if (bark_style > 0 && !batch) {
		// The basis is (r, len, r) times the node's scale; tree_scale takes the node back out.
		float ts = max(tree_scale, 1e-3);
		float r_here = length(MODEL_MATRIX[0].xyz) / ts * mix(1.0, taper, y01);
		float along = COLOR.b + y01 * length(MODEL_MATRIX[1].xyz) / ts;
		v_bark = vec3(VERTEX.x * r_here, along, VERTEX.z * r_here) / bark_cell;
	}
	vec3 w = (MODEL_MATRIX * vec4(v, 1.0)).xyz;
	w = sway(w, flutter_phase(w0));
	v_world = w;
	// The basis scales x and z equally, so a radial normal keeps its direction.
	v_normal_w = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	POSITION = PROJECTION_MATRIX * (VIEW_MATRIX * vec4(w, 1.0));
}

void fragment() {
	float u = clamp(v_u, 0.0, 1.0);
	vec3 root = mix(pal0, pal1, trunk_lift);
	float phase = (batch ? v_phase : palette_phase) + colour_cycle;
	float bh = batch ? v_bark_hue : bark_hue;
	vec3 tip = mix(pal2, pal3, 1.0 - abs(fract(phase) * 2.0 - 1.0));
	vec3 base = (u < 0.5) ? mix(root, pal1, u * 2.0) : mix(pal1, tip, (u - 0.5) * 2.0);
	if (bark_mix > 0.0 || bh != 0.0) {
		base = max(hue_turn(base, bh), vec3(0.0));
		float luma = dot(base, vec3(0.299, 0.587, 0.114));
		base = mix(base, bark_tint * max(luma * 1.6, 0.05), bark_mix);
	}
	if (bark_style > 0 && !batch) {
		base = bark(base, v_bark, tip);
	}
	vec3 n = normalize(v_normal_w);
	vec3 key = normalize(vec3(0.5, 0.8, 0.3));
	vec3 V = normalize(CAMERA_POSITION_WORLD - v_world);
	float ndv = max(dot(n, V), 0.0);
	float diff = 0.6 * max(dot(n, key), 0.0) + 0.4 * ndv;
	float rim = pow(1.0 - ndv, 3.0);
	ALBEDO = (base * (0.25 + 0.75 * diff) + pal3 * rim * 0.35 * u) * brightness;
}
