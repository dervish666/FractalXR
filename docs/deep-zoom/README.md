# Deep zoom on the fractal ground: why it blocks up, and what to do about it

2026-09-15 · Plan for review · Native Quest build (`godot/`), GROUND mode

## Recommendation up front

**Do not build perturbation. Build two-float (df32) arithmetic in `ground.glsl`.**

This document started out as a perturbation plan, because perturbation is what the
literature reaches for and it is already on the project backlog. Working through it
changed the answer, and the reasoning is worth keeping:

- Perturbation exists to push past classic zoom ~1e13. `STAGE_MAX = 13` caps this app at
  about 6e5. It is the wrong tool for the range that can actually be reached.
- Perturbation needs a reference orbit, a glitch criterion, a **multi-pass re-reference
  loop**, and a new storage-buffer binding, in a clipmap fill that is already budgeted
  per frame and already over its GPU budget.
- Perturbation requires the iteration to be holomorphic. **It fixes three of the eight
  ground formulas.** The five folded families (Burning Ship, Tricorn, Celtic,
  Perpendicular, Buffalo) are not perturbable by the obvious method, and the negative
  result below shows why.
- df32 needs no reference orbit, no glitch pass, no extra binding, and **no holomorphy,
  so it fixes all eight**. Measured: 12/12 exact escape counts at both the zoom reached in
  the headset and at the app's deepest setting, where the current code produces a single
  value across twelve adjacent texels.

The perturbation analysis is kept below because it is the evidence that establishes what
the defect is, rules out the cheap alternatives, and is the right answer *if* the zoom
range is ever raised past about 1e6.

## The problem, in one paragraph

Zoom the ground past about 1000x and the terrain breaks into hard, axis-aligned
rectangles. It is not the renderer, the tile budget, the iteration count or the RENDER
setting. `ground.glsl` computes each sample's fractal coordinate as `vec2(a) * texel`,
where `a` is the **absolute integer texel index**. float32 cannot represent consecutive
integers past 2^24, so beyond that index neighbouring texels collapse onto the same
coordinate and are handed the same iteration count. The rectangles are runs of identical
counts. No amount of extra rendering time can recover a distinction that was destroyed
before the iteration started.

## Measured, not assumed

From the running app on the headset (2026-09-15, `[perf]` line): at `zoom=2.1e3x`, stage
11, `texel = 1/40960000`, a coordinate of ~0.745 sits at texel index **3.05e7**. The
float32 gap there is **2.0 texel indices**.

| zoom | texel index | float32 gap | effect |
|---|---|---|---|
| 128x | 1.9e6 | 0.12 | fine |
| 256x | 3.8e6 | 0.25 | softening begins |
| 512x | 7.6e6 | 0.50 | |
| 1024x | 1.5e7 | 1.00 | neighbours start colliding |
| **2048x** | **3.1e7** | **2.00** | **2x2 blocks (the zoom in the headset session)** |
| 8192x | 1.2e8 | 8.00 | 8x8 blocks |
| 16384x | 2.4e8 | 16.00 | 16x16 blocks |

`STAGE_MAX = 13` allows 16384x. **The app permits roughly 32x more zoom than it can
render honestly.**

Reproduce all of this with `python3 docs/deep-zoom/precision_probe.py`. It emulates
float32 with an exact `struct` round-trip, so it is doing the GPU's arithmetic, not an
approximation of it.

## The fix, measured

Two-float arithmetic: carry every coordinate and every iterate as a `hi + lo` pair of
float32s using Veltkamp-Dekker products and two-sum additions, which buys roughly 46 bits
of mantissa against float32's 24. The requirement is about 32 bits at stage 13, so there
is real headroom.

A real Mandelbrot boundary row, 12 adjacent texels, against a full double-precision
ground truth:

```
stage 11, zoom 2048x (the zoom reached in the headset)
  truth:  481  713  293  294  295  296  323  643  425  318  321  323
  naive:  407  296  296  296  296  296  553  553  553  318  323  323
  df32 :  481  713  293  294  295  296  323  643  425  318  321  323
  distinct: truth 11, naive 5, df32 11      exact: naive 3/12, df32 12/12

stage 13, zoom 8192x (the app's deepest)
  truth:  470  428  325  450  345  412  431  303  320  414  380  298
  naive:  601  601  601  601  601  601  601  601  601  601  601  601
  df32 :  470  428  325  450  345  412  431  303  320  414  380  298
  distinct: truth 12, naive 1, df32 12      exact: naive 0/12, df32 12/12
```

At stage 13 the current code returns **one** value across twelve texels. df32 returns all
twelve correctly. `python3 docs/deep-zoom/precision_probe.py df32` reproduces it.

### What this costs

Roughly: a df multiply is about 19 ALU operations without FMA, a df add about 11. The
Mandelbrot inner loop's `z` update goes from about 8 operations to about 90, against a
total loop cost of roughly 37 operations today. Call it **2.5x to 3x the inner loop** on
the levels that need it. GROUND already measures 14.2 ms GPU against a 13.89 ms budget,
so this must be **gated**: switch to the df path per dispatch, only when that rect's own
absolute texel index is large enough to need it. Shallow levels and shallow zooms keep
today's cost exactly.

### A ceiling this does NOT lift

The clipmap texture is `DATA_FORMAT_R16G16B16A16_SFLOAT` (`fractal_ground.gd:191` and
`:310`). All four channels are stored as **half floats**, so however precisely the compute
shader works, the result is quantised on the way out. Checked: the smooth count and its
fractional part are exact to about 1024, half-resolution at 2048, and the fraction is dead
above that.

That matters because `fract(s.r)` is load-bearing in three separate places in
`ground.gdshader`: the sawtooth grain in `height_of`, the contour lines in relief mode 3,
and `fwidth(s.r)` which drives the distance damping. **ITER 4096 already renders with a
dead `fract` today**, before any of this work.

So df32 makes the existing zoom range honest, but "now we can go deeper" also needs the
output format addressed. RGBA32F would double texture memory: 9 levels at 1024^2 goes from
about 75 MB to 151 MB, and the hq 2048^2 path from 302 MB to 604 MB, which is not viable on
a Quest. Deeper zoom therefore needs a smarter encoding, not just a wider format.

### The risk that would kill it

Veltkamp-Dekker is only exact if the compiler leaves it alone. `two_sum` relies on
`(a + b) - a` not being reassociated to `b`, and the split relies on `t - (t - a)`
surviving. glslang emits these faithfully into SPIR-V, but the Qualcomm backend under
fast-math could contract or reassociate them. **The failure mode is subtle: the result
looks like noise rather than blocks, which would pass a naive adjacency check while being
wrong.** Any spike must cross-check GPU output against the CPU model in
`precision_probe.py`, not merely look at a screenshot.

## The perturbation analysis, and why it is the wrong tool here

### The evidence that perturbation fixes it

A real Mandelbrot boundary row at the zoom above, 16 adjacent texels. `truth` is a full
double-precision orbit; `naive` is exactly what `ground.glsl` computes today; `pert` is
the perturbed recurrence with a double-precision reference orbit and float32 deltas:

```
truth:  522  332  299  298  296  299  572  293  292  291  289  288  286  285  283  282
naive:  492  492  492  295  295  295  352  290  290  290  287  287  287  287  287  280
pert :  522  332  299  298  296  299  524  293  292  291  289  288  286  285  283  282

distinct values: truth 15, naive 6, pert 15
exactly right:   naive 0/16, pert 15/16
```

The `492 492 492` and `287 287 287 287 287` runs in the naive row **are** the rectangles.
Perturbation recovers 15 of the 16 true counts.

The one it misses (index 6: 524 against a true 572) is not noise. It is a **glitch
pixel**, the known failure mode where the perturbed orbit passes far closer to zero than
the reference does and the delta loses its relative precision. Any real implementation
needs a detection criterion and a re-reference pass. It is useful that a 16-pixel test
already surfaces one.

## The maths

For `z -> z^2 + c`, with a reference point `C` iterated in high precision as
`Z_{n+1} = Z_n^2 + C`, and a nearby point `c = C + dc`, writing `z_n = Z_n + d_n`:

```
d_{n+1} = 2 Z_n d_n + d_n^2 + dc
```

Every term is small or known. `d` stays float32-representable; `Z` is read from the
reference orbit. The escape test is on `|Z_n + d_n|`, where precision loss does not
matter because it is only a magnitude comparison.

The higher powers follow by binomial expansion and are equally clean:

```
z^3:  d_{n+1} = 3 Z_n^2 d_n + 3 Z_n d_n^2 + d_n^3 + dc
z^4:  d_{n+1} = 4 Z_n^3 d_n + 6 Z_n^2 d_n^2 + 4 Z_n d_n^3 + d_n^4 + dc
```

## The folded families do not come along for free

Five of the eight ground formulas (Burning Ship, Tricorn, Celtic, Perpendicular, Buffalo)
apply `abs()` or a conjugation before squaring. These are not holomorphic, so there is no
derivative and the expansion above does not exist.

The obvious workaround is that away from the axes, `|Re(Z+d)| = sign(Re Z) * (Re Z + Re d)`,
so you can fold the *delta* by the *reference's* signs and recover the quadratic
recurrence. **Tested, and it fails.** On a Burning Ship boundary row at the same zoom:

```
truth:  186  242  143  131  403  168  131  246  129   86  468   82   71  494  313  185
naive:  249  249  179  179  179  179  179  179  179   64   64   64   64   64   64   64
pert :  186   69   66   65   64   63   63   62   62   62   62   61   60   59   59   58

exactly right: naive 0/16, pert 1/16
fold-crossing pixels: 15/16
```

Fifteen of sixteen pixels cross a fold line relative to the reference, so the reference's
signs simply do not apply to them. This is not bad luck with the sample point: the ship's
structure exists *because* the orbit repeatedly passes close to the axes. Sign-trick
perturbation is wrong there by construction.

**Correction, from an independent per-family derivation pass.** The failure above is real
but it is a failure of the *naive* sign trick, not of perturbation. The proper technique is
`diffabs` (compute the difference of absolute values directly rather than applying the
reference's sign), plus a perturbed-sign fold correction. That rescues all five folded
families exactly: Celtic 16/16 where the reference-sign trick scores 1/16, Burning Ship
16/16 against 400-digit truth. The row above should be read as "here is why the obvious
approach fails", not as "these families cannot be perturbed".

The real reason to prefer df32 is different, and worse for perturbation:

**The Quest GPU is float32 only, so a perturbation delta on this device IS float32, and
f32 deltas buy a finite number of honest iterations before they collapse.** Measured per
family: Burning Ship 216-687, Celtic ~367, Buffalo 43-70, Quartic 100% exact below 500
iterations, 33% at 750-999, **0% past 2000**. The ground's ITER control goes to 4096.
Perturbation here would ship a mode whose accuracy silently degrades as the user raises
iterations, worst on the two-fold families. df32 has no cliff: it is the same algorithm
with a longer mantissa, and its error is a smooth function of position at every iteration
count.

## What the codebase gives us

Established by reading `ground.glsl`, `fractal_ground.gd` and `ground.gdshader`:

- The push constant is a full 64 bytes with exactly **4 free** (`_pad1`). It can grow:
  `particle_cloud.gd` already ships a **112-byte** push constant through the same
  `RenderingDevice` on the same device, so 96 or 112 is a three-line change
  (`resize()`, the size literal at the dispatch, the GLSL struct). Nothing in the repo
  queries `LIMIT_MAX_PUSH_CONSTANT_SIZE`; 112 is empirically fine, 128 is untested.
- Adding a storage buffer for the reference orbit has a direct precedent:
  `fractal_source.gd` binds `[image @0, storage buffer @1]` in one `uniform_set_create`
  and updates it in place with `buffer_update` rather than churning RIDs.
- **Trap:** the uniform set is built in *two* places, `setup()` and `set_quality()`.
  `set_quality` frees `_tex` and rebuilds, relying on Godot tearing down dependent RIDs.
  An orbit buffer must be recreated there too, not only in `setup()`.
- GDScript floats are 64-bit doubles, so the host can compute the reference orbit
  accurately with no extra machinery.
- Only the **fine** levels are affected. Level `i`'s texel index is `2^i` smaller than
  level 0's, so at stage 11 level 8 sits at ~1.2e5 and is perfectly safe. Perturbation
  does not need to touch the whole clipmap.
- A reference orbit of 4096 iterations as `vec2` doubles is 64 KB. Recomputing it costs
  microseconds on the CPU. Neither is a constraint.

## Three things the experiments settled that a design would otherwise guess

**The reference orbit can be stored as float32.** Iterate it in double on the host, then
store float32 pairs for the GPU. Tested: identical results on all 16 pixels, 15/16 against
truth either way. This matters for cost, because 2048 iterations of `vec2` float32 is
**16 KB**, which fits Adreno's typical 32 KB workgroup shared memory. The orbit can be
loaded into `shared` once per workgroup and read from there in the inner loop, instead of
a storage-buffer read per iteration. Double would be 32 KB and would not fit.

**The orbit is only valid until the reference itself escapes.** In the sample above the
reference escaped after **523** iterations with `max_iter` at 2048. Any pixel needing more
than that has no reference left to perturb against. The shader needs the valid length, not
just the buffer.

**One reference cannot serve a whole tile, and "pick a better reference" does not fix it.**
Using the tile corner, pixel 6 fails (needs 572, orbit survives 523). Moving the reference
to the deepest-iterating texel makes the orbit survive 573 and fixes pixel 6. It breaks
pixel 0 instead:

```
reference = tile corner      522  332  299  298  296  299   -1  293 ...   15/16
reference = deepest texel     -1  332  299  298  296  299  572  293 ...   15/16
truth                        522  332  299  298  296  299  572  293 ...
```

The failing pixel simply moves. This is the known behaviour and it means perturbation here
is a **multi-pass algorithm**, not a single dispatch: run, detect glitched pixels,
re-reference, re-run those. About 6% of pixels in this sample. That is cheap in arithmetic
but it is a structural change to a clipmap fill that currently issues one dispatch per
rectangle and is already budgeted per frame.

## The cost question, which is the real one

GROUND already measures **14.2 ms GPU and 17.4 ms CPU** against a **13.89 ms** budget at
72 Hz. It is over budget before anything is added, and the session log shows frame rate
falling with CPU time even when the GPU is inside budget.

Per iteration, the perturbed recurrence is roughly the same arithmetic as the current one
(two complex multiplies). The new cost is a **reference-orbit read per iteration**, in the
innermost loop. Every invocation in a workgroup reads the same address at the same `n`, so
it should cache well, but on Adreno this is the number that decides whether the feature is
viable. Any plan must measure it before committing.

---

## Proposed first session

Four steps, in order, each of which can end the work honestly.

1. **Prove the wall is where the analysis says it is.** Add `texel_lo` over the unused
   `_pad1` at offset 60, build the coordinate as a df pair, then immediately collapse it
   back to a single float before iterating. Capture at stage 11. *Expected: the rectangles
   are unchanged.* If they visibly clear, the diagnosis is wrong about where the precision
   is lost and everything after this is void.
2. **Port the six df helpers and the quadratic families' inner loop**, gated on a `deep`
   flag derived from the rect's absolute texel index. Grow the push constant 64 -> 80 in
   the three places the facts section names.
3. **Cross-check against an independent CPU model, not a screenshot.** Read back a 64x64
   patch of the level texture and compare smooth counts against a GDScript double-precision
   port; require max |delta| < 0.05. `orbit_trace.gd:99-113` already has an iterator but
   hardcodes `z^2+c` with `BAILOUT2 = 16`, so it needs the formula switch, `ESC2 = 65536`
   and the smooth count. GDScript doubles against GLSL df32, no shared code, is the point:
   driver contraction produces **noise rather than blocks**, which would pass an adjacency
   check while being wrong. A picture cannot catch this.
4. **Measure the GPU cost** with the existing `[perf]` line at stage 11 and stage 13, with
   the gate on and off, and decide whether it fits.

Only then consider the folded families, cubic and quartic, and whether `STAGE_MAX` should
rise.

## Open questions for review

1. Is the df32 cost estimate (2.5x to 3x the inner loop, gated to deep dispatches only)
   survivable on a mode already at 14.2 ms GPU, or does the gate need to be tighter than
   per-dispatch?
2. Is the Veltkamp-Dekker reassociation risk on Adreno real in practice, and is the
   FMA-based product safer or less safe than the split-based one?
3. Answered during review: `diffabs` does rescue the folded families for perturbation. The
   open part is whether the measured f32-delta iteration ceilings (Buffalo 43-70, Quartic
   0% past 2000) can be lifted on a float32-only GPU, since that is what rules perturbation
   out here rather than the algebra.
4. Should `STAGE_MAX` rise once the arithmetic is honest, and if so how far before
   perturbation genuinely becomes necessary?
5. Is there a reason to prefer perturbation anyway that this analysis has missed?
