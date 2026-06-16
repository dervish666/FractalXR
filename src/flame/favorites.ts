import { zeroVariations, type FlameGenome } from './types'

const KEY = 'fractalxr.favorites.v1'

/** Backfill any variation keys added since this favourite was saved (older saves predate
 *  newer variations), so every transform carries the full weight set the pipeline expects. */
function normalizeVariations(g: FlameGenome): FlameGenome {
  for (const t of g.transforms) t.variations = { ...zeroVariations(), ...t.variations }
  return g
}

/** Shape guard so a corrupted or older-schema entry can't detonate the morph/encode pipeline
 *  on the first "Faves" press (a TypeError thrown inside the XR render loop kills the session). */
function isFlameGenome(g: unknown): g is FlameGenome {
  const f = g as FlameGenome | null
  return (
    !!f &&
    Array.isArray(f.transforms) &&
    f.transforms.length > 0 &&
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
