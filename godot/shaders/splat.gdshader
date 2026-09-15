// Camera-facing quad splats, two triangles per particle.
//
// Why not point sprites: Adreno clamps gl_PointSize to 1. Every particle came out as a
// single pixel at every distance no matter what size was requested, which is why the
// cloud read as dust from inside a shell and why no point-size setting ever changed
// anything. Real size needs real geometry.
//
// The mesh is four dummy vertices per particle, indexed. VERTEX_ID carries everything: the
// particle index and which corner this is. So the mesh is a bare resize with no
// attributes to fill, and changing the particle count stays cheap.
shader_type spatial;
// This is a real Gaussian-splat rasteriser now, not a billboard with a soft edge.
//
// What Spark (the WebXR build's renderer) does, and what the first four attempts here did
// not, in the order it matters:
//
// 1. NO DEPTH WRITE. Spark's material is `depthTest: true, depthWrite: false`. Ours wrote
//    depth on every splat, so a nearer splat OCCLUDED the ones behind it. That is the
//    whole reason the result kept reading as "a point cloud with splats": each splat was
//    an opaque disc with a soft edge, and discs do not merge into a surface.
// 2. The footprint is computed in SCREEN SPACE, by projecting the splat's 3D covariance
//    through the Jacobian of the perspective transform, not by drawing a fixed-size quad
//    in the world. The ellipse is therefore exactly right at every distance and view angle.
// 3. A blur floor with matching alpha compensation, so a splat can never shrink below
//    about a pixel. It fades instead of aliasing, which is what stops the sparkle.
// 4. Premultiplied alpha, which is the correct "over" operator.
//
// And, since the depth sort landed, the one thing Spark did that this did not: splats
// are drawn back-to-front. The host runs a GPU counting sort by view depth every frame
// (sort_count.glsl, bake_scan.glsl, sort_scatter.glsl) and hands the permutation over
// as a texture, because a spatial shader can sample a texture and not a storage buffer.
render_mode unshaded, blend_premul_alpha, cull_disabled, depth_draw_never,
	fog_disabled, shadows_disabled, skip_vertex_transform;

// Quad half-extent in squared standard deviations. Spark's default is 8 (2.83 sigma);
// 5 (2.24 sigma) cuts the quad's area by 37% and clips the Gaussian at exp(-2.5) = 8%,
// which Spark's own tuning notes call acceptable. Fill is the entire cost of this
// renderer, and coverage-sized splats need every pixel of it.
const float MAX_STDDEV2 = 5.0;
// Dilation of the projected covariance, in square pixels, and the antialiasing floor.
// Without it a distant splat lands inside one pixel and flickers as it moves.
const float BLUR_PX2 = 0.3;
// Hard bound on any one splat's footprint. 512 sounded generous and was a death
// sentence: a 42mm mean size with the bake's spread put ellipses of tens of thousands
// of pixels each over the whole view, 147k of them, alpha blended — measured 2fps and a
// hard quit. Fill rate is the entire cost of this renderer.
const float MAX_PIXEL_RADIUS = 192.0;
// The key light, in world space. High, a little to the right and a little in front:
// the direction a lamp would be if you were holding the thing up to look at it.
const vec3 KEY_DIR = vec3(0.5145, 0.8231, 0.2401);   // normalize(0.5, 0.8, 0.3)

uniform sampler2D state_tex : filter_nearest, source_color;
uniform sampler2D normal_tex : filter_nearest;
// Surface-aligned splats. bulbSplat.ts is explicit that a uniform camera-facing sphere
// per point "blurs the filigree": a disc lying ACROSS a filament smears it, a disc lying
// ALONG it keeps the edge. The web build gets that orientation from a 14-neighbour
// covariance computed offline. A distance-estimate surface hands us the normal directly,
// so we get the same alignment for free and on a moving cloud.
uniform bool use_normals = false;
// How flat the disc is along the normal. bulbSplat.ts uses THIN = 0.16 for the same job.
uniform float splat_thin = 0.18;
uniform float splat_opacity = 0.35;
// Local density, so a splat can be sized by how crowded its neighbourhood is rather than
// by one global number. Packed as a 3D grid flattened into a 2D texture: Godot spatial
// shaders cannot sample a storage buffer, so the counts come across as a texture.
uniform sampler2D density_tex : filter_nearest;
uniform int density_grid = 64;
uniform float density_extent = 1.6;
uniform float density_strength = 1.0;
// 1/2 for a surface, 1/3 for a volume. A distance-estimate shell is two-dimensional, so
// m particles in a box of side L sit at a spacing of L/sqrt(m). Using the cube root on a
// surface compresses the range the counts actually span, which is why the first
// density-sized build varied so little.
uniform float density_exponent = 0.3333;
// Mean particles per occupied cell, measured on the GPU. Dividing by it is what keeps
// the mean splat size at whatever SPLAT is set to: only the departures from average
// resize, so changing the particle count or the grid does not quietly rescale the cloud.
uniform float density_nominal = 8.0;
// Baked per-splat shape: (cos, sin) of the major axis in the tangent frame, then the two
// axis lengths. This is the kNN covariance the WebXR viewer computes during its loading
// pause, and it is the difference between a disc that is merely the right size and one
// that lies ALONG the filament it belongs to.
uniform sampler2D bake_tex : filter_nearest;
uniform bool use_bake = false;
// Back-to-front draw order: slot i of the mesh draws particle perm_tex[i]. R32F holds the
// id exactly. Off, the slot is the particle, which is the unsorted order.
uniform sampler2D perm_tex : filter_nearest;
uniform bool use_sort = false;
// Either splat_radius / mean baked axis (SPLAT sets the average, the bake the spread) or,
// with bake_in_cloud_units, a coverage multiple of each splat's own baked axis, which is
// in state units and so also wants cloud_fit.
uniform float bake_scale = 1.0;
uniform bool bake_in_cloud_units = false;
// The frame-rate governor's lever. Scales every splat's real size, so cost falls with
// its square. 1 when the frame budget holds; cut hard the moment it does not.
uniform float perf_scale = 1.0;
uniform vec3 density_centre = vec3(0.0);
uniform int tex_size = 2048;
uniform float splat_radius = 0.026;
uniform float brightness = 0.3;
// How much of the splat's colour comes from which way its surface faces. 0 is the old
// look exactly, for an A/B against any capture taken before this existed.
//
// The cloud already knows its normals: they are what orients each disc into the surface.
// Using them for shade as well costs one dot product per splat in a shader that was
// already fetching the normal, and it is the difference between a bulb that reads as a
// solid with folds in it and one that reads as a uniformly bright fog in the shape of a
// bulb. Applied to RGB only: the silhouette, the opacity and the sort order are the
// splat rasteriser's business and none of them change.
uniform float splat_light = 0.35;
uniform float sharpness = 3.0;
uniform vec3 cloud_center = vec3(0.0);
uniform float cloud_fit = 1.0;
// The palette coordinate is stretched by a fixed 4/3 about the centre before the ramp
// lookup. A live version (measured mean and spread, which measure.glsl still sums)
// was planned and never wired up; this constant stretch is the look that shipped.
const float COLOUR_STRETCH = 1.0 / 0.75;
// How many times the palette repeats across the equalised range. Equalisation spreads
// every point evenly over one traversal of the ramp, which reads as a single gradient.
// Repeating it two or three times gives distinct colour bands from the same data, and
// because the input is already rank-equalised each band gets an equal share of points
// rather than one swamping the others.
uniform float palette_cycles = 1.0;
uniform vec3 pal0;
uniform vec3 pal1;
uniform vec3 pal2;
uniform vec3 pal3;
uniform vec3 pal4;

varying vec3 v_col;
varying vec2 v_off;
varying float v_alpha;

const vec2 CORNERS[4] = vec2[4](
	vec2(-1.0, -1.0), vec2(1.0, -1.0), vec2(1.0, 1.0), vec2(-1.0, 1.0));

vec3 palette(float t) {
	t = clamp(t, 0.0, 1.0);
	t = clamp(0.5 + (t - 0.5) * COLOUR_STRETCH, 0.0, 1.0);
	if (palette_cycles > 1.5) {
		// Ping-pong rather than wrap, so bands meet at a shared colour instead of
		// snapping from the top of the ramp back to the bottom.
		float c = t * palette_cycles;
		t = abs(fract(c * 0.5) * 2.0 - 1.0);
	}
	// Piecewise-linear ramp as a mix chain. The previous local vec3[5] with a dynamic
	// index is the pattern Adreno spills to scratch memory, in a shader that runs once
	// per vertex for a million vertices.
	float f = t * 4.0;
	vec3 c = mix(pal0, pal1, clamp(f, 0.0, 1.0));
	c = mix(c, pal2, clamp(f - 1.0, 0.0, 1.0));
	c = mix(c, pal3, clamp(f - 2.0, 0.0, 1.0));
	c = mix(c, pal4, clamp(f - 3.0, 0.0, 1.0));
	return c;
}

void vertex() {
	int slot = VERTEX_ID / 4;   // indexed draw: four corners per splat
	int pid = slot;
	if (use_sort) {
		int pw = textureSize(perm_tex, 0).x;
		pid = int(texelFetch(perm_tex, ivec2(slot % pw, slot / pw), 0).r + 0.5);
	}
	v_off = CORNERS[VERTEX_ID % 4];

	vec4 s = texelFetch(state_tex, ivec2(pid % tex_size, pid / tex_size), 0);
	bool bad = !(s.x == s.x) || !(s.y == s.y) || !(s.z == s.z);
	vec3 p = (s.xyz - cloud_center) * cloud_fit;

	vec3 vc = (MODELVIEW_MATRIX * vec4(p, 1.0)).xyz;
	float mscale = length(MODELVIEW_MATRIX[0].xyz);   // carry the cloud's own scale
	float r = splat_radius * perf_scale * mscale;

	// --- the splat's three axes, in VIEW space -----------------------------------
	// Together they are the RS matrix of 3D Gaussian splatting: cov3D = RS * RS^T.
	vec3 a1, a2, a3;
	float shade = 1.0;
	if (use_normals) {
		// The tangent frame is built in LOCAL space, from the same formula
		// bake_shape.glsl uses, which is what lets the bake send an angle instead of
		// two vectors.
		vec3 nl = texelFetch(normal_tex, ivec2(pid % tex_size, pid / tex_size), 0).xyz;
		nl = (dot(nl, nl) > 1e-12) ? normalize(nl) : vec3(0.0, 0.0, 1.0);
		vec3 t1 = normalize(cross(nl, abs(nl.z) < 0.9 ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0)));
		vec3 t2 = cross(nl, t1);

		float l1 = r;
		float l2 = r;
		if (use_bake) {
			vec4 bk = texelFetch(bake_tex, ivec2(pid % tex_size, pid / tex_size), 0);
			// Rotate the frame into the neighbourhood's own principal axes.
			vec3 e1 = t1 * bk.x + t2 * bk.y;
			vec3 e2 = t2 * bk.x - t1 * bk.y;
			t1 = e1;
			t2 = e2;
			float bs = bake_scale * mscale * perf_scale * (bake_in_cloud_units ? cloud_fit : 1.0);
			l1 = bk.z * bs;
			l2 = bk.w * bs;
		} else if (density_strength > 0.01) {
			vec3 gn = ((s.xyz - density_centre) / density_extent) * 0.5 + 0.5;
			ivec3 gc = ivec3(clamp(gn * float(density_grid), vec3(0.0), vec3(float(density_grid) - 1.0)));
			int flat_i = (gc.z * density_grid + gc.y) * density_grid + gc.x;
			int w = textureSize(density_tex, 0).x;
			float n_here = max(1.0, texelFetch(density_tex, ivec2(flat_i % w, flat_i / w), 0).r);
			float rel = clamp(pow(density_nominal / n_here, density_exponent), 0.4, 2.5);
			l1 *= rel;
			l2 *= rel;
		}
		// Flat along the normal, so a splat lies IN the surface. Spark's source cloud
		// uses THIN = 0.16 for exactly this.
		a1 = (MODELVIEW_MATRIX * vec4(t1 * l1, 0.0)).xyz;
		a2 = (MODELVIEW_MATRIX * vec4(t2 * l2, 0.0)).xyz;
		a3 = (MODELVIEW_MATRIX * vec4(nl * (splat_thin * l1), 0.0)).xyz;
		// The key is in WORLD space, not view space: a light welded to the head would
		// slide across the surface as you looked around, and would land differently in
		// each eye. The cloud's basis is uniformly scaled, so the model matrix carries
		// the normal without needing its inverse transpose.
		vec3 nw = normalize((MODEL_MATRIX * vec4(nl, 0.0)).xyz);
		// A high, slightly-to-the-right key, and a 0.45 floor so a face turned away goes
		// dim rather than black: the recesses have to keep their colour.
		shade = mix(1.0, 0.45 + 0.55 * max(dot(nw, KEY_DIR), 0.0), splat_light);
	} else {
		// No surface to lie in: an isotropic Gaussian, already in view space.
		a1 = vec3(r, 0.0, 0.0);
		a2 = vec3(0.0, r, 0.0);
		a3 = vec3(0.0, 0.0, r);
	}

	float alpha = splat_opacity;
	vec2 pixel_off = vec2(0.0);
	bool cull = bad || vc.z >= 0.0;

	if (!cull) {
		mat3 rs = mat3(a1, a2, a3);
		mat3 cov3 = rs * transpose(rs);

		// Jacobian of the perspective projection at this point, in pixels.
		vec2 focal = 0.5 * VIEWPORT_SIZE * vec2(PROJECTION_MATRIX[0][0], PROJECTION_MATRIX[1][1]);
		float inv_z = 1.0 / vc.z;
		vec2 j1 = focal * inv_z;
		vec2 j2 = -(j1 * vc.xy) * inv_z;
		mat3 jm = mat3(
			vec3(j1.x, 0.0, j2.x),
			vec3(0.0, j1.y, j2.y),
			vec3(0.0, 0.0, 0.0));
		mat3 cov2 = transpose(jm) * cov3 * jm;

		float ca = cov2[0][0];
		float cd = cov2[1][1];
		float cb = cov2[0][1];
		float det_orig = ca * cd - cb * cb;
		ca += BLUR_PX2;
		cd += BLUR_PX2;
		float det = ca * cd - cb * cb;
		// Dilating the footprint spreads the same energy over more pixels, so the alpha
		// has to come down to match or every distant splat quietly gets brighter.
		alpha *= sqrt(max(0.0, det_orig / max(1e-12, det)));

		float eig_avg = 0.5 * (ca + cd);
		float eig_del = sqrt(max(0.0, eig_avg * eig_avg - det));
		float eig1 = eig_avg + eig_del;
		float eig2 = max(0.0, eig_avg - eig_del);
		vec2 ev1 = normalize(vec2((abs(cb) < 1e-6) ? 1.0 : cb, eig1 - ca));
		vec2 ev2 = vec2(ev1.y, -ev1.x);
		float sc1 = min(MAX_PIXEL_RADIUS, sqrt(MAX_STDDEV2) * sqrt(eig1));
		float sc2 = min(MAX_PIXEL_RADIUS, sqrt(MAX_STDDEV2) * sqrt(eig2));
		pixel_off = v_off.x * ev1 * sc1 + v_off.y * ev2 * sc2;
		if (alpha < 0.002) cull = true;
	}

	v_alpha = alpha;
	v_col = palette(s.w) * brightness * shade;

	if (cull) {
		POSITION = vec4(2.0, 2.0, 2.0, 1.0);   // outside the clip volume
	} else {
		vec4 clip = PROJECTION_MATRIX * vec4(vc, 1.0);
		vec2 ndc_off = (2.0 / VIEWPORT_SIZE) * pixel_off;
		POSITION = vec4(clip.xy + ndc_off * clip.w, clip.z, clip.w);
	}
	VERTEX = vc;
}


void fragment() {
	float r2 = dot(v_off, v_off);
	if (r2 > 1.0) discard;
	// The quad spans MAX_STDDEV2 in squared standard deviations, so this is the real
	// Gaussian: exp(-0.5 * sigma^2). `sharpness` scales it for taste.
	float fall = exp(-0.5 * MAX_STDDEV2 * r2 * (sharpness / 3.0));
	float a = fall * v_alpha;
	// Premultiplied: the blend is src + dst * (1 - a), so the colour arrives pre-scaled.
	ALBEDO = v_col * a;
	ALPHA = a;
}
