import type { WebGLRenderer } from 'three'

/**
 * "Enter MR" button — a minimal, VRButton-styled entry point that requests an
 * immersive-ar (passthrough) session so the flame appears to float in the real room.
 *
 * Deliberately NOT three's stock ARButton: that helper calls
 * `setReferenceSpaceType('local')` immediately before `setSession`, which anchors
 * content at head height. We want the flame floor-anchored, so a custom button is
 * used instead — it leaves the renderer's existing 'local-floor' reference space
 * (set in main.ts) untouched and simply hands the AR session to renderer.xr.
 *
 * The button stays hidden entirely when the device can't do immersive-ar (e.g. a
 * desktop browser), so the VR-only landing page is unaffected.
 */
export function createMRButton(renderer: WebGLRenderer): HTMLElement {
  const button = document.createElement('button')
  button.id = 'MRButton'
  stylize(button)
  button.style.display = 'none'

  if (!('xr' in navigator) || !navigator.xr) {
    return button // no WebXR at all → stay hidden (the VR button already explains why)
  }

  const xr = navigator.xr
  let currentSession: XRSession | null = null

  const onSessionEnded = (): void => {
    currentSession?.removeEventListener('end', onSessionEnded)
    button.textContent = 'ENTER MR'
    currentSession = null
  }

  const onSessionStarted = async (session: XRSession): Promise<void> => {
    session.addEventListener('end', onSessionEnded)
    await renderer.xr.setSession(session) // uses the renderer's existing 'local-floor' ref space
    button.textContent = 'EXIT MR'
    currentSession = session
  }

  // local-floor keeps the flame on the floor; the rest are best-effort niceties.
  const sessionOptions: XRSessionInit = {
    optionalFeatures: ['local-floor', 'bounded-floor', 'hand-tracking', 'layers'],
  }

  xr.isSessionSupported('immersive-ar')
    .then((supported) => {
      if (!supported) return // leave hidden on non-AR devices
      button.style.display = ''
      button.textContent = 'ENTER MR'
      button.onclick = (): void => {
        if (currentSession === null) {
          xr.requestSession('immersive-ar', sessionOptions).then(onSessionStarted).catch(() => {})
        } else {
          currentSession.end()
        }
      }
    })
    .catch(() => {})

  return button
}

function stylize(el: HTMLElement): void {
  el.style.position = 'absolute'
  el.style.bottom = '20px'
  el.style.padding = '12px 6px'
  el.style.width = '120px'
  el.style.border = '1px solid #fff'
  el.style.borderRadius = '4px'
  el.style.background = 'rgba(0,0,0,0.1)'
  el.style.color = '#fff'
  el.style.font = 'normal 13px sans-serif'
  el.style.textAlign = 'center'
  el.style.opacity = '0.5'
  el.style.outline = 'none'
  el.style.cursor = 'pointer'
  el.style.zIndex = '999'
  el.onmouseenter = (): void => {
    el.style.opacity = '1.0'
  }
  el.onmouseleave = (): void => {
    el.style.opacity = '0.5'
  }
}
