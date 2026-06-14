import type { FlameGenome } from './types'

const KEY = 'fractalxr.favorites.v1'

/** Load saved flames from localStorage (survives across sessions). */
export function loadFavorites(): FlameGenome[] {
  try {
    const raw = localStorage.getItem(KEY)
    if (!raw) return []
    const arr = JSON.parse(raw)
    return Array.isArray(arr) ? (arr as FlameGenome[]) : []
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
