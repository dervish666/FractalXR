import { sampleSlice, type Quality } from './bulbSplat'

export interface SampleRequest {
  want: number
  seed: number
  quality: Quality
}
export interface SampleDone {
  type: 'done'
  xyz: Float32Array
  trap: Float32Array
  count: number
  attempts: number
}
export interface SampleProgress {
  type: 'progress'
  done: number
}

const ctx = self as unknown as {
  onmessage: ((e: MessageEvent) => void) | null
  postMessage: (msg: unknown, transfer?: Transferable[]) => void
}

ctx.onmessage = (e: MessageEvent<SampleRequest>) => {
  const { want, seed, quality } = e.data
  const slice = sampleSlice(want, seed, quality, (done) => {
    const msg: SampleProgress = { type: 'progress', done }
    ctx.postMessage(msg)
  })
  const msg: SampleDone = {
    type: 'done',
    xyz: slice.xyz,
    trap: slice.trap,
    count: slice.count,
    attempts: slice.attempts,
  }
  // transfer rather than clone: these are megabytes and there is no reader left here
  ctx.postMessage(msg, [slice.xyz.buffer, slice.trap.buffer])
}
