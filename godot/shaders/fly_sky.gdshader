// V5: Procedural Rayleigh/Mie atmospheric sky for FLY worlds (SPIRES & VAULT).
// Replaces the flat uniform clear colour with a zenith-to-horizon gradient, warm Mie
// scattering halo and glowing sun disc aligned with the world's key light direction.
// Returns black on AT_CUBEMAP_PASS so radiance cubemaps cost nothing.
shader_type sky;

uniform vec3 horizon_colour = vec3(0.58, 0.70, 0.86);
uniform vec3 zenith_colour = vec3(0.14, 0.24, 0.46);
uniform vec3 sun_dir = vec3(0.45, 0.55, 0.30);
uniform vec3 sun_colour = vec3(1.0, 0.88, 0.65);
uniform float sun_scatter = 0.55;

void sky() {
	if (AT_CUBEMAP_PASS) {
		COLOR = vec3(0.0);
	} else {
		vec3 d = normalize(EYEDIR);
		vec3 sdir = normalize(sun_dir);
		float h = clamp(d.y, 0.0, 1.0);
		float h_inv = 1.0 - h;
		vec3 grad = mix(zenith_colour, horizon_colour, h_inv * h_inv * h_inv);
		// Below the horizon h is 0, so the gradient is horizon_colour: the fog's own colour. A
		// darker nadir drew the fogged towers pale against it, and the fog cannot follow one.
		vec3 col = grad;
		float sdot = max(dot(d, sdir), 0.0);
		float s2 = sdot * sdot;
		float s6 = s2 * s2 * s2;
		// Broad golden Mie halo matching bulb_solid.gdshader's directional fog scattering.
		col = mix(col, sun_colour * 1.15, s6 * sun_scatter);
		// Tight atmospheric aureole + soft HDR sun disc.
		float s32 = (s6 * s6) * (s6 * s6) * (s2 * s2 * s2 * s2);
		col += sun_colour * s32 * 0.45;
		// About 2.5 degrees across: big enough to read in the headset, a quarter of the first
		// pass, which drew a disc ten times the real sun's.
		float disc = smoothstep(0.99974, 0.99985, sdot);
		col += sun_colour * disc * 2.2;
		COLOR = col;
	}
}
