shader_type spatial;
render_mode unshaded, cull_disabled, blend_add, depth_draw_never, fog_disabled, shadows_disabled;

// FLOOR's fractal ground (scripts/tree/forest_floor.gd): a faint Kaliset filigree on the floor
// under the trees, in the theme's colours, added to whatever is below it. Added, not painted: the
// black void stays black between the lines, and in passthrough the lines lie on your real floor.
//
// The pattern lives in the avenue's frame (`offset` is where the plane's centre sits in it), so
// it slides past with the trees when you walk and stays still when you do not. It is the Kaliset
// of tree_floor_kali.gdshaderinc, baked once into a mipmapped tile (`pattern`: red and green, two
// constants), folded by mirroring so the tiles meet with no seam, and drifting between its two
// constants along the avenue so the tiles change instead of repeating.
//
// Baked, not live: computed per pixel it cost 0.37 ms for a frame of floor on the M1 Pro, which
// would be a few milliseconds on the Quest with the floor filling the lower half of both eyes.
// Baked, a whole frame of floor measured 0.07-0.15 ms there (tools/tree_look_shot.sh; explicit
// gradients cost the same as an implicit read), and the mipmaps fade the lines into the distance
// far more cleanly than a per-pixel fade, so the far floor never shimmers in stereo. It fades
// out by `radius` from its centre, where the void takes over again.

uniform vec3 pal1 = vec3(0.35, 0.18, 0.05);
uniform vec3 pal2 = vec3(0.6, 0.45, 0.2);
uniform vec3 pal3 = vec3(0.9, 0.8, 0.3);
uniform float brightness = 1.0;
uniform float gain = 0.14;          // the brightest line, against the canopy's leaf_gain 0.25
uniform vec2 offset = vec2(0.0);    // the plane's centre, in the avenue frame (metres)
uniform float tile = 4.0;           // metres per pattern tile
uniform float radius = 24.0;        // metres from the centre where the floor has faded out
uniform sampler2D pattern : filter_linear_mipmap, repeat_disable, hint_default_black;
// CYCLE (main.gd, the COLOUR card), in turns: slides the lines along the ramp, ping-ponged as the
// leaves are (tree_leaf.gdshader), so the ground rolls with the trees above it. 0 is the old path.
global uniform float colour_cycle;

varying vec2 v_p;
varying vec2 v_local;

void vertex() {
	v_local = VERTEX.xz;
	v_p = VERTEX.xz + offset;
}

void fragment() {
	vec2 p = v_p / tile;
	vec2 q = abs(mod(p, 2.0) - 1.0);
	// The gradient of the unfolded coordinate: the fold flips its sign, never its size, so the
	// mip level stays smooth across every fold line.
	vec2 s = textureGrad(pattern, q, dFdx(p), dFdy(p)).rg;
	float drift = 0.5 + 0.5 * sin(v_p.y * 0.045 + 0.8 * sin(v_p.x * 0.07));
	float v = mix(s.r, s.g, drift);
	float fade = 1.0 - smoothstep(radius * 0.45, radius, length(v_local));
	// Lines in the ramp's middle, the brightest leaning to pal3; the dark between stays black.
	float line = smoothstep(0.08, 0.45, v);
	// Where on the ramp a line sits; `line` alone still sets how bright it is.
	float h = colour_cycle > 0.0 ? 1.0 - abs(fract(line * 0.5 + colour_cycle) * 2.0 - 1.0) : line;
	ALBEDO = mix(pal1, mix(pal2, pal3, h), h) * line * fade * gain * brightness;
}
