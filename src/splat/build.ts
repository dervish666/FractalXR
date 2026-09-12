import type { SampleDone, SampleProgress, SampleRequest } from './sample.worker'
import type { BuildMessage, BuildRequest } from './build.worker'
import type { Quality } from './bulbSplat'

export interface BuildResult {
  ply: Uint8Array
  splats: number
  sampleMs: number
  fitMs: number
}

/**
 * Generate a Mandelbulb splat cloud in the page.
 *
 * Sampling costs about 0.4ms per accepted point and is embarrassingly parallel — each point is
 * an independent scatter-and-project — so it fans out across workers. Fitting the Gaussians is
 * not parallel (every point needs its neighbours), so it runs once on its own worker. Nothing
 * touches the main thread, because a minute of blocked main thread in a headset is not a slow
 * frame, it is a dead app.
 */
export async function buildBulbSplats(
  want: number,
  onProgress: (frac: number, label: string) => void,
  threads = Math.max(1, Math.min(12, (navigator.hardwareConcurrency || 4) - 1)),
  quality: Quality = 'fast',
): Promise<BuildResult> {
  const t0 = performance.now()
  const per = Math.ceil(want / threads)
  const progress = new Array<number>(threads).fill(0)

  // Handles live outside the promises: when one sampler fails, Promise.all rejects at
  // once and the siblings would otherwise keep every core busy behind a failed banner.
  const workers: Worker[] = []
  const slices = await Promise.all(
    Array.from({ length: threads }, (_, i) =>
      new Promise<SampleDone>((resolve, reject) => {
        const w = new Worker(new URL('./sample.worker.ts', import.meta.url), { type: 'module' })
        workers.push(w)
        w.onerror = (err) => {
          w.terminate()
          reject(new Error(`sampler ${i} failed: ${err.message}`))
        }
        w.onmessage = (e: MessageEvent<SampleDone | SampleProgress>) => {
          if (e.data.type === 'progress') {
            progress[i] = e.data.done
            const done = progress.reduce((a, b) => a + b, 0)
            onProgress(0.55 * Math.min(1, done / want), `sampling ${done.toLocaleString()} / ${want.toLocaleString()}`)
            return
          }
          w.terminate()
          resolve(e.data)
        }
        // distinct seeds, or every worker walks the same sequence and returns the same points
        w.postMessage({ want: per, seed: 0x1a2b3c4d + i * 0x9e3779b9, quality } satisfies SampleRequest)
      }),
    ),
  ).finally(() => {
    for (const w of workers) w.terminate()
  })

  const total = slices.reduce((a, s) => a + s.count, 0)
  const sampleMs = performance.now() - t0
  if (total === 0) throw new Error('no surface points found')

  const xyz = new Float32Array(total * 3)
  const trap = new Float32Array(total)
  let at = 0
  for (const s of slices) {
    xyz.set(s.xyz.subarray(0, s.count * 3), at * 3)
    trap.set(s.trap.subarray(0, s.count), at)
    at += s.count
  }

  const t1 = performance.now()
  const result = await new Promise<{ ply: Uint8Array; splats: number }>((resolve, reject) => {
    const w = new Worker(new URL('./build.worker.ts', import.meta.url), { type: 'module' })
    w.onerror = (err) => {
      w.terminate()
      reject(new Error(`builder failed: ${err.message}`))
    }
    w.onmessage = (e: MessageEvent<BuildMessage>) => {
      if (e.data.type === 'progress') {
        onProgress(0.55 + 0.45 * e.data.frac, e.data.label)
        return
      }
      w.terminate()
      resolve({ ply: e.data.ply, splats: e.data.splats })
    }
    w.postMessage({ xyz, trap, n: total } satisfies BuildRequest, [xyz.buffer, trap.buffer])
  })

  return { ...result, sampleMs, fitMs: performance.now() - t1 }
}
