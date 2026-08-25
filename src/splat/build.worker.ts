import { buildPly } from './bulbSplat'

export interface BuildRequest {
  xyz: Float32Array
  trap: Float32Array
  n: number
}
export type BuildMessage =
  | { type: 'progress'; frac: number; label: string }
  | { type: 'done'; ply: Uint8Array; splats: number }

const ctx = self as unknown as {
  onmessage: ((e: MessageEvent) => void) | null
  postMessage: (msg: unknown, transfer?: Transferable[]) => void
}

ctx.onmessage = (e: MessageEvent<BuildRequest>) => {
  const { xyz, trap, n } = e.data
  const ply = buildPly(xyz, trap, n, (frac, label) => {
    ctx.postMessage({ type: 'progress', frac, label } satisfies BuildMessage)
  })
  ctx.postMessage({ type: 'done', ply, splats: n } satisfies BuildMessage, [ply.buffer])
}
