import { zeroVariations, type FlameGenome } from './types'

const KEY = 'fractalxr.favorites.v1'

/** Backfill any variation keys added since this favourite was saved (older saves predate
 *  newer variations), so every transform carries the full weight set the pipeline expects. */
function normalizeVariations(g: FlameGenome): FlameGenome {
  for (const t of g.transforms) t.variations = { ...zeroVariations(), ...t.variations }
  return g
}

const isVec3 = (v: unknown): boolean =>
  Array.isArray(v) && v.length === 3 && v.every((x) => typeof x === 'number')

/** The fields morph.ts and encode.ts index directly. `variations` may be missing: the
 *  loader backfills it, which is how older saves keep working. */
function isFlameTransform(t: unknown): boolean {
  const x = t as Record<string, unknown> | null
  return (
    typeof x === 'object' &&
    x !== null &&
    isVec3(x.rowX) &&
    isVec3(x.rowY) &&
    isVec3(x.rowZ) &&
    isVec3(x.translate) &&
    typeof x.weight === 'number' &&
    typeof x.colorIndex === 'number' &&
    (x.variations === undefined || (typeof x.variations === 'object' && x.variations !== null))
  )
}

/** Shape guard so a corrupted or older-schema entry can't detonate the morph/encode pipeline
 *  on the first "Faves" press (a TypeError thrown inside the XR render loop kills the session). */
function isFlameGenome(g: unknown): g is FlameGenome {
  const f = g as FlameGenome | null
  return (
    !!f &&
    Array.isArray(f.transforms) &&
    f.transforms.length > 0 &&
    f.transforms.every(isFlameTransform) &&
    Array.isArray(f.palette) &&
    f.palette.length > 0 &&
    typeof f.brightness === 'number' &&
    typeof f.gamma === 'number' &&
    typeof f.k2 === 'number' &&
    typeof f.highlightDesat === 'number' &&
    typeof f.pointBrightness === 'number'
  )
}

/** Load saved flames from localStorage (survives across sessions). */
export function loadFavorites(): FlameGenome[] {
  try {
    const raw = localStorage.getItem(KEY)
    if (!raw) return []
    const arr = JSON.parse(raw)
    if (!Array.isArray(arr)) return []
    return (arr as unknown[]).filter(isFlameGenome).map(normalizeVariations)
  } catch {
    return []
  }
}

export function persistFavorites(favs: FlameGenome[]): void {
  try {
    localStorage.setItem(KEY, JSON.stringify(favs))
  } catch {
    /* storage full or disabled — keep them in-memory for this session */
  }
}
