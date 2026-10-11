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

void sky() {
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
	COLOR = c * mix(floor_keep, 1.0, smoothstep(-0.35, 0.05, d.y));
}
