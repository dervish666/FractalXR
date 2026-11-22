// FLAME SKY (scripts/core/flame_sky.gd): the baked flame, hung at infinity behind every
// mode. One texture fetch per background pixel and nothing that changes per frame,
// so it cannot shimmer.
shader_type sky;

// Linear HDR equirect from sky_resolve.glsl. No source_color: it is already linear.
uniform sampler2D flame_sky : filter_linear, repeat_enable;
// A pre-rendered preset (art/skies/, tools/sky_cube.py): a compressed cubemap with mipmaps,
// sRGB, holding the sky divided by cube_gain (1 for the shipped ones: under 0.03% of their
// texels are brighter, see tools/sky_cube.py).
// A cube has no poles and no wrap column, so it needs neither fix the equirect does below.
uniform samplerCube sky_cube : source_color, filter_linear_mipmap;
uniform bool use_cube = false;
uniform float cube_gain = 1.0;
// What is left of the sky at the nadir. Below the horizon it dims so the floor still reads as
// a floor: a sky is a stable reference, a nebula under your feet is not.
uniform float floor_keep = 0.12;
// V8: the sky's hue turns with CYCLE so it breathes with the fractal. (V8's slow drift on TIME
// is gone: TIME in a sky shader re-renders its radiance every frame, for 0.23 degrees a second
// nobody could see, and it jumped about 105 degrees when TIME rolled over each hour.)
global uniform float colour_cycle;

vec3 hue_turn(vec3 c, float a) {
	const vec3 k = vec3(0.57735027);
	float ca = cos(a);
	return max(c * ca + cross(k, c) * sin(a) + k * dot(k, c) * (1.0 - ca), vec3(0.0));
}

void sky() {
	// Nothing reads the radiance (flame_sky.gd turns ambient and reflections off), so a re-render
	// of it, as CYCLE moving colour_cycle causes, costs six black faces and not six fetches.
	if (AT_CUBEMAP_PASS) {
		COLOR = vec3(0.0);
	} else {
		vec3 d = normalize(EYEDIR);
		vec3 c;
		if (use_cube) {
			c = texture(sky_cube, d).rgb * cube_gain;
		} else {
			// The same mapping as sky_splat.glsl: forward (-Z) mid-texture, up at the top row.
			vec2 uv = vec2(atan(d.x, -d.z) * (0.5 / PI) + 0.5, acos(clamp(d.y, -1.0, 1.0)) / PI);
			// repeat wraps v as well as u, so within half a texel of a pole bilinear filtering
			// would blend in the far row: the other pole. Clamp v to the texel centres.
			float hv = 0.5 / float(textureSize(flame_sky, 0).y);
			uv.y = clamp(uv.y, hv, 1.0 - hv);
			c = texture(flame_sky, uv).rgb;
		}
		if (colour_cycle > 0.0) {
			// Keep each texel's luma, as points.gdshader's keep_luma does for CYCLE. A turn about
			// the grey axis keeps R+G+B, not luma, and the clamp adds more: a third of a cycle in,
			// the shipped skies measured Ember +49%, Nautilus -39%, Geode -15% (0.0% kept).
			const vec3 W = vec3(0.2126, 0.7152, 0.0722);
			float l0 = dot(c, W);
			vec3 h = hue_turn(c, colour_cycle * 6.2831853);
			h *= min(l0 / max(dot(h, W), 1e-4), 3.0);
			c = h + max(l0 - dot(h, W), 0.0);
		}
		COLOR = c * mix(floor_keep, 1.0, smoothstep(-0.35, 0.05, d.y));
	}
}
