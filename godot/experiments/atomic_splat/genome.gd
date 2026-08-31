extends RefCounted
class_name Genome

## "Ember", the hand-authored M0 genome, copied verbatim from src/flame/presets.ts.
## Three transforms; bubble3D + sinusoidal give it genuine z-extent so it reads as a
## volumetric cloud rather than a flat sheet.
##
## Packed into the flat float layout the compute shaders index (see chaos.glsl):
##   0..23  row0[8][3]   24..47  row1[8][3]   48..71  row2[8][3]   72..95  b[8][3]
##   96..103 cdf[8]      104..111 color[8]    112..207 varW[8][12] 208..222 palette[5][3]

const MAX_TRANSFORMS := 8
const NVAR := 12
const FLOATS := 224

# Variation order is load-bearing: must match VARIATION_NAMES in src/flame/types.ts
# and the applyVars() branch order in chaos.glsl. Append only, never reorder.
const VAR_LINEAR3D := 0
const VAR_SPHERICAL := 1
const VAR_SWIRL := 2
const VAR_SINUSOIDAL := 3
const VAR_BUBBLE3D := 4

# rows (3x3), translate, weight, colorIndex, {variation index: weight}
const EMBER_TRANSFORMS := [
	{
		"rows": [[0.62, -0.20, 0.10], [0.20, 0.62, -0.08], [-0.10, 0.08, 0.62]],
		"t": [0.10, 0.06, 0.04], "w": 1.0, "c": 0.05,
		"v": {VAR_LINEAR3D: 0.35, VAR_SPHERICAL: 0.65},
	},
	{
		"rows": [[0.45, 0.30, -0.25], [-0.30, 0.45, 0.20], [0.25, -0.20, 0.50]],
		"t": [0.28, 0.34, -0.22], "w": 0.85, "c": 0.55,
		"v": {VAR_SWIRL: 0.55, VAR_BUBBLE3D: 0.55, VAR_LINEAR3D: 0.15},
	},
	{
		"rows": [[0.40, 0.00, 0.18], [0.00, 0.40, 0.00], [-0.18, 0.00, 0.40]],
		"t": [-0.30, 0.20, 0.30], "w": 0.7, "c": 0.95,
		"v": {VAR_SINUSOIDAL: 0.7, VAR_BUBBLE3D: 0.3},
	},
]

# THEMES["Ember"] from src/flame/palettes.ts
const EMBER_PALETTE := [
	[0.02, 0.02, 0.12], [0.35, 0.04, 0.45], [0.95, 0.15, 0.4], [1.0, 0.6, 0.1], [1.0, 0.95, 0.65],
]

# Display tuning, from the EMBER preset
const BRIGHTNESS := 0.32        # tone-map exposure
const GAMMA := 2.4
const K2 := 55.0
const HIGHLIGHT_DESAT := 0.3
const POINT_BRIGHTNESS := 0.9

static func num_transforms() -> int:
	return EMBER_TRANSFORMS.size()

## Pack into the flat float array the shaders index. Mirrors encodeFlame() in
## src/flame/encode.ts, including the cdf[n-1] = 1 guard against float drift.
static func pack() -> PackedFloat32Array:
	var f := PackedFloat32Array()
	f.resize(FLOATS)

	var n := EMBER_TRANSFORMS.size()
	var total := 0.0
	for t in EMBER_TRANSFORMS:
		total += maxf(0.0, t["w"])
	if total <= 0.0:
		total = 1.0

	var acc := 0.0
	for i in MAX_TRANSFORMS:
		if i < n:
			var t: Dictionary = EMBER_TRANSFORMS[i]
			var rows: Array = t["rows"]
			for k in 3:
				f[i * 3 + k] = rows[0][k]
				f[24 + i * 3 + k] = rows[1][k]
				f[48 + i * 3 + k] = rows[2][k]
				f[72 + i * 3 + k] = t["t"][k]
			acc += maxf(0.0, t["w"]) / total
			f[96 + i] = acc
			f[104 + i] = t["c"]
			for v in NVAR:
				f[112 + i * NVAR + v] = t["v"].get(v, 0.0)
		else:
			# padding rows are never selected (cdf already saturated) but must be valid
			f[i * 3 + 0] = 1.0
			f[24 + i * 3 + 1] = 1.0
			f[48 + i * 3 + 2] = 1.0
			f[96 + i] = 1.0
	f[96 + n - 1] = 1.0 # guard the last bucket against float drift

	for i in 5:
		for k in 3:
			f[208 + i * 3 + k] = EMBER_PALETTE[i][k]
	return f
