import type { WebGLRenderer } from 'three'

export type ModeId = 'flames' | 'zoom' | 'splat'

export const MODE_PATH: Record<ModeId, string> = {
  flames: '/',
  zoom: '/zoom',
  splat: '/splat',
}

/** flames → zoom → splat → flames. Cycle order for stick-click MODE switches. */
export const MODE_ORDER: ModeId[] = ['flames', 'zoom', 'splat']

export function nextMode(current: ModeId): ModeId {
  return MODE_ORDER[(MODE_ORDER.indexOf(current) + 1) % MODE_ORDER.length]
}

/**
 * Leave the current page for another mode. A WebXR session is bound to its page, so
 * switching mode in-headset can only mean end session + navigate — the new page opens flat
 * and its own Enter VR button takes over from there.
 */
export function switchMode(renderer: WebGLRenderer, target: ModeId): void {
  renderer.xr.getSession()?.end()
  location.assign(MODE_PATH[target])
}
