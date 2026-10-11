// FLAME SKY (scripts/core/flame_sky.gd): the baked flame, hung at infinity behind every
// mode. One texture fetch per background pixel and nothing that changes per frame,
// so it cannot shimmer.
shader_type sky;

// Linear HDR equirect from sky_resolve.glsl. No source_color: it is already linear.
uniform sampler2D flame_sky : filter_linear, repeat_enable;
// What is left of the sky at the nadir. Below the horizon it dims so the floor still reads as
// a floor: a sky is a stable reference, a nebula under your feet is not.
uniform float floor_keep = 0.12;

void sky() {
	vec3 d = normalize(EYEDIR);
	// The same mapping as sky_splat.glsl: forward (-Z) mid-texture, up at the top row.
	vec2 uv = vec2(atan(d.x, -d.z) * (0.5 / PI) + 0.5, acos(clamp(d.y, -1.0, 1.0)) / PI);
	vec3 c = texture(flame_sky, uv).rgb;
	COLOR = c * mix(floor_keep, 1.0, smoothstep(-0.35, 0.05, d.y));
}
