#[compute]
#version 450

// Exclusive prefix sum over the grid cell counts, so each cell knows where its slice of
// the sorted particle list starts. Part one of the bake's spatial index.
//
// The alternative was a fixed number of slots per cell, which needs no scan but wants
// 25-67MB to hold the worst case and silently drops particles from exactly the crowded
// cells where the neighbourhood estimate matters most. A scan costs three dispatches and
// is exact.
//
// Two-level: each 256-wide block scans itself in shared memory and publishes its total,
// one invocation scans the 1024 block totals, then every element adds its block's offset.
// Stage comes in by push constant so all three live in one shader.

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer Counts { uint cell[]; };
layout(set = 0, binding = 1, std430) restrict buffer Offsets { uint off[]; };
layout(set = 0, binding = 2, std430) restrict buffer BlockSums { uint bsum[]; };

layout(push_constant, std430) uniform PC {
	int cells;
	int blocks;
	int stage;
	int _pad0;
} p;

shared uint tmp[256];

void main() {
	uint gid = gl_GlobalInvocationID.x;
	uint lid = gl_LocalInvocationID.x;

	if (p.stage == 0) {
		// Every invocation reaches every barrier: the out-of-range ones contribute zero
		// rather than returning early, because a barrier in divergent flow is undefined.
		uint v = (gid < uint(p.cells)) ? cell[gid] : 0u;
		tmp[lid] = v;
		barrier();
		for (uint d = 1u; d < 256u; d <<= 1u) {
			uint t = (lid >= d) ? tmp[lid - d] : 0u;
			barrier();
			tmp[lid] += t;
			barrier();
		}
		if (gid < uint(p.cells)) off[gid] = tmp[lid] - v;   // inclusive minus own = exclusive
		if (lid == 255u) bsum[gl_WorkGroupID.x] = tmp[255];
	} else if (p.stage == 1) {
		// 1024 block totals, scanned serially by one invocation. It is a one-off on a
		// tiny array; a second parallel scan would be more code than it saves.
		if (gid != 0u) return;
		uint acc = 0u;
		for (int i = 0; i < p.blocks; i++) {
			uint v = bsum[i];
			bsum[i] = acc;
			acc += v;
		}
	} else {
		if (gid >= uint(p.cells)) return;
		off[gid] += bsum[gid / 256u];
	}
}
