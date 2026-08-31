# Experiment: atomic splat (abandoned)

Replaces the rasteriser with `imageAtomicAdd` into a uint accumulator, then a compute
tone map. This was the whole premise for going native. It lost, badly:

| path | Quest 3, 707,788 particles |
|---|---|
| compute chaos + atomic splat + compute tone map | 103.7 ms |
| compute chaos + rasterised points | 14.35 ms |

Adreno is a tile-based GPU. The rasteriser's additive blend happens in tile memory and
is close to free; `imageAtomicAdd` goes to global memory and serialises on contention,
and a fractal flame's dense core is nothing but contention. The 2x2 stamp cost 3.6x the
1x1 stamp, tracking atomic count, and splat cost barely fell when the resolution dropped
4x, because fewer pixels means more contention per pixel.

It also could not track the head. The compute output is composited as a screen-space
blit built from a possibly-stale pose, which reads on-device as the cloud sitting still
while the world moves around it. Fixing that means owning the frame loop, which means
not using Godot's scene renderer.

Kept so the measurement can be reproduced, not because it is a live option. These files
are not referenced by the project.
