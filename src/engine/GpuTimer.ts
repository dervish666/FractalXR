/**
 * Per-pass GPU timing via EXT_disjoint_timer_query_webgl2. Brackets named regions of GL work
 * (sim / splat / tonemap) and reports a smoothed millisecond cost per label — so quality/perf
 * tuning is measured, not guessed.
 *
 * Results come back a few frames late (the GPU is asynchronous), so each `begin/end` enqueues a
 * query that `poll()` harvests once it's ready. Only ONE timer query may be active at a time per
 * the spec, so regions must not overlap (they don't — we time sequential passes).
 *
 * Degrades to a no-op when the extension is unavailable. Notably, many WebXR sessions disable it
 * (timing-attack mitigation), so `available` can be true on desktop and false in-headset — in which
 * case the HUD simply falls back to the wall-clock fps readout.
 */
interface TimerExt {
  TIME_ELAPSED_EXT: number
  GPU_DISJOINT_EXT: number
}

export class GpuTimer {
  private ext: TimerExt | null
  private active: { label: string; query: WebGLQuery } | null = null
  private inflight: { label: string; query: WebGLQuery }[] = []
  private ema: Record<string, number> = {}

  constructor(private gl: WebGL2RenderingContext) {
    this.ext = gl.getExtension('EXT_disjoint_timer_query_webgl2') as TimerExt | null
  }

  get available(): boolean {
    return this.ext !== null
  }

  /** Start timing a region. Ignored if unsupported or a region is already open. */
  begin(label: string): void {
    if (!this.ext || this.active) return
    const query = this.gl.createQuery()
    if (!query) return
    this.gl.beginQuery(this.ext.TIME_ELAPSED_EXT, query)
    this.active = { label, query }
  }

  /** Close the open region and queue its query for later harvest. */
  end(): void {
    if (!this.ext || !this.active) return
    this.gl.endQuery(this.ext.TIME_ELAPSED_EXT)
    this.inflight.push(this.active)
    this.active = null
  }

  /** Call once per frame: harvest any completed queries into the smoothed per-label times. */
  poll(): void {
    if (!this.ext) return
    const gl = this.gl
    const disjoint = gl.getParameter(this.ext.GPU_DISJOINT_EXT) as boolean
    for (let i = this.inflight.length - 1; i >= 0; i--) {
      const { label, query } = this.inflight[i]
      const ready = gl.getQueryParameter(query, gl.QUERY_RESULT_AVAILABLE) as boolean
      if (!ready && !disjoint) continue
      if (ready && !disjoint) {
        const ms = (gl.getQueryParameter(query, gl.QUERY_RESULT) as number) / 1e6
        this.ema[label] = this.ema[label] === undefined ? ms : this.ema[label] * 0.85 + ms * 0.15
      }
      gl.deleteQuery(query) // disjoint → result is garbage, discard the query but keep the last EMA
      this.inflight.splice(i, 1)
    }
  }

  ms(label: string): number {
    return this.ema[label] ?? 0
  }

  /** Compact `sim/splat/tone` ms string for the HUD, or '' when unsupported. */
  hud(): string {
    if (!this.ext) return ''
    return ` · gpu ${this.ms('sim').toFixed(1)}/${this.ms('splat').toFixed(1)}/${this.ms('tone').toFixed(1)}`
  }
}
