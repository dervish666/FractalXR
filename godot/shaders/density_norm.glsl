#[compute]
#version 450

// Second half of the density pass: publish the counts to the renderer, and measure what
// a "normal" cell holds so the sizing can be self-normalising.
//
// The counts have to reach a spatial shader, which cannot read a storage buffer, so they
// go across as a texture. The first attempt uploaded the raw uint buffer into an R32_UINT
// texture and sampled it with `sampler2D`. Vulkan needs `usampler2D` for an integer
// format, so every fetch came back zero, every splat took the same clamped fallback size,
// and the whole point of the pass was silently lost: 147k identically-sized discs merged
// into a foam ball. Writing floats from a compute shader is both correct and cheaper —
// it also removes a 400KB readback that was stalling the render thread every measure.
//
// `occupied` and `total` give the mean occupancy of the cells that actually hold
// particles, which is the reference the splat shader divides by. Without it the sizing
// depends on the particle count and the grid resolution, so any change to either quietly
// rescales the whole cloud.

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer Density { uint cell[]; };
layout(set = 0, binding = 1, r32f) uniform restrict writeonly image2D out_img;
layout(set = 0, binding = 2, std430) restrict buffer Stats { uint occupied; uint total; } st;

layout(push_constant, std430) uniform PC {
	int cells;
	int width;
	int grid;
	int _pad0;
} p;

// A single cell is a bad neighbourhood estimate: it quantises hard, so two particles a
// millimetre apart across a cell boundary get different sizes and the boundaries show up
// as a visible grid. Summing the 3x3x3 block around it samples eight times the volume
// and varies smoothly. It costs 27 reads once per cell here, against 27 reads per VERTEX
// if the splat shader tried the same thing.
uint block27(ivec3 c) {
	uint sum = 0u;
	for (int z = -1; z <= 1; z++) {
		for (int y = -1; y <= 1; y++) {
			for (int x = -1; x <= 1; x++) {
				ivec3 q = c + ivec3(x, y, z);
				if (any(lessThan(q, ivec3(0))) || any(greaterThanEqual(q, ivec3(p.grid)))) continue;
				sum += cell[(q.z * p.grid + q.y) * p.grid + q.x];
			}
		}
	}
	return sum;
}

void main() {
	uint i = gl_GlobalInvocationID.x;
	if (i >= uint(p.cells)) return;
	int gi = int(i);
	ivec3 c = ivec3(gi % p.grid, (gi / p.grid) % p.grid, gi / (p.grid * p.grid));
	uint n = cell[i];
	uint smooth_n = block27(c);
	imageStore(out_img, ivec2(gi % p.width, gi / p.width), vec4(float(smooth_n), 0.0, 0.0, 0.0));
	if (n > 0u) {
		// Bounded by 27x the particle count (113M at the 4.19M ceiling), well inside a uint.
		atomicAdd(st.occupied, 1u);
		atomicAdd(st.total, smooth_n);
	}
}
