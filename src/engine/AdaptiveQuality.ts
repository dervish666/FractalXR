/**
 * Self-regulating quality. Thermal throttling after 5–15 min of heavy additive
 * load on Quest 3 is guaranteed and unobservable via any API, so we adapt on
 * measured frame time: too slow → drop particle count + raise foveation; lots of
 * headroom → restore. Deliberately gentle to avoid visible oscillation.
 */
export interface AdaptiveHooks {
  minCount: number
  getMaxCount: () => number // user-set ceiling; adaptive may drop below under load but never exceed it
  getCount: () => number
  setCount: (n: number) => void
  setFoveation: (f: number) => void
}

export class AdaptiveQuality {
  private emaMs: number
  private foveation = 0 // start at full resolution (no foveation); only rise under real load
  private targetMs: number
  private cooldown = 0

  constructor(private hooks: AdaptiveHooks, targetHz = 72) {
    this.targetMs = 1000 / targetHz
    this.emaMs = this.targetMs
  }

  setTargetHz(hz: number): void {
    this.targetMs = 1000 / hz
  }

  update(dtMs: number): void {
    // clamp pathological spikes (GC, focus loss) so they don't crater quality
    const dt = Math.min(dtMs, 100)
    this.emaMs = this.emaMs * 0.9 + dt * 0.1
    if (this.cooldown > 0) {
      this.cooldown--
      return
    }

    const count = this.hooks.getCount()
    const maxCount = this.hooks.getMaxCount()
    if (this.emaMs > this.targetMs * 1.2) {
      // too slow: shed particle count first; only nudge foveation a little and never
      // far enough to look blocky (cap 0.45) — sharpness matters more than a few % fill
      this.hooks.setCount(Math.max(this.hooks.minCount, count * 0.88))
      this.foveation = Math.min(0.45, this.foveation + 0.08)
      this.hooks.setFoveation(this.foveation)
      this.cooldown = 30
    } else if (this.emaMs < this.targetMs * 1.08 && (count < maxCount || this.foveation > 0)) {
      // Comfortably holding refresh → climb back toward the user's ceiling and ease foveation
      // to 0. Frame time is vsync-locked to ~targetMs, so the only observable "headroom" is
      // *sustaining* the refresh rate — it can never read below target. (The old < 0.7×target
      // gate was therefore unreachable under vsync: one hitch would shed and never restore,
      // ratcheting the count down to the floor over a session.)
      this.hooks.setCount(Math.min(maxCount, count * 1.05))
      this.foveation = Math.max(0, this.foveation - 0.05)
      this.hooks.setFoveation(this.foveation)
      this.cooldown = 60
    }
  }

  get currentFoveation(): number {
    return this.foveation
  }

  /** Smoothed frame time (ms). Headroom readout: well under targetMs = room to push. */
  get frameMs(): number {
    return this.emaMs
  }
}
