/**
 * Two-viewport equality test — stereo space-handling regression guard.
 *
 * WHY THIS EXISTS
 * ---------------
 * `gl_FragCoord` is in FRAMEBUFFER space. A viewport is a sub-rectangle of that
 * framebuffer. On a flat screen the two are indistinguishable, because the viewport is
 * always at (0,0) and the same size as the framebuffer — so a shader that normalises
 * `gl_FragCoord` by the VIEWPORT size instead of the FRAMEBUFFER size is correct on
 * desktop and wrong in one eye on a headset, silently, for the entire life of the file.
 *
 * Credit where due: cupboard Claude hit exactly this on a WebXR raymarcher (right eye
 * wrong because `uRes` was viewport size) and their test is the one ported here.
 *
 * THE PROPERTY UNDER TEST
 * -----------------------
 * Tone-mapping through two half-width eye viewports must produce the same framebuffer as
 * tone-mapping once through a single full-width viewport. The flat path is the known-good
 * reference; the per-eye path is the one that only ever runs on a device nobody can attach
 * a debugger to.
 *
 * Determinism: both composites are drawn in the same frame, on the same GPU, with the same
 * shader and the same source texture. This is NOT the cross-build pixel-diff problem that
 * needs SwiftShader to be reproducible — identical work in one frame should differ by
 * exactly zero, so the pass threshold is 0 and any drift is a real finding.
 *
 * NEGATIVE CONTROL is not optional. `runStereoTest({ injectBug: true })` rebuilds the
 * tone-map with `uFbSize` set to the VIEWPORT size — the actual historical bug — and must
 * report a large delta. A test nobody has watched fail is not a test.
 */

import {
  Camera,
  GLSL3,
  LinearFilter,
  Mesh,
  NoBlending,
  RawShaderMaterial,
  RGBAFormat,
  Scene,
  Vector2,
  Vector4,
  WebGLRenderer,
  WebGLRenderTarget,
} from 'three'
import { Compositor, type ToneParams } from '../engine/Compositor'
import { makeFullscreenTriangle } from '../engine/util'
import { RAW_VERT, TONEMAP_FRAG } from '../engine/shaders'

/** Half-width of the simulated stereo framebuffer. Full target is 2*EYE_W x EYE_H. */
const EYE_W = 256
const EYE_H = 192

/** Fixed, unremarkable tone params — the test is about space, not about the curve. */
const TONE: ToneParams = { exposure: 0.32, gamma: 2.4, k2: 55, hiDesat: 0.3 }

export interface StereoTestResult {
  pass: boolean
  differing: number // pixels with any channel delta > DELTA_TOL
  maxDelta: number // worst single-channel delta, 0..255
  total: number
  width: number
  height: number
  injectedBug: boolean
  note: string
}

/** Report count-above-tolerance AND max delta, never a bare pass/fail — a refactor that
 *  moves arithmetic around can legitimately tip a few silhouette pixels by 1, and treating
 *  that as a regression wastes an hour. Cross-path in one frame, though, expect exact zero. */
const DELTA_TOL = 2

/**
 * Fill an HDR target with a deterministic pattern that is ASYMMETRIC ACROSS X.
 *
 * This is load-bearing. If the pattern were left/right symmetric, an eye that wrongly
 * sampled the left half would produce the right answer by luck and the test would pass
 * while the bug was present. The horizontal ramp guarantees every column is distinct.
 */
function fillHdr(renderer: WebGLRenderer, target: WebGLRenderTarget, w: number, h: number): void {
  const mat = new RawShaderMaterial({
    glslVersion: GLSL3,
    vertexShader: RAW_VERT,
    depthTest: false,
    depthWrite: false,
    blending: NoBlending,
    uniforms: { uSize: { value: new Vector2(w, h) } },
    fragmentShader: /* glsl */ `
      precision highp float;
      uniform vec2 uSize;
      out vec4 fragColor;
      void main(){
        vec2 uv = gl_FragCoord.xy / uSize;
        // Horizontal ramp = strictly increasing across x, so no two columns match and a
        // half-width sampling error cannot alias onto a correct-looking result. Vertical
        // bands + a hot blob push values through the log-density curve's interesting range
        // rather than sitting in the linear part.
        float ramp = uv.x * 6.0;
        float bands = step(0.5, fract(uv.y * 8.0)) * 0.8;
        vec2 d = uv - vec2(0.72, 0.38);
        float blob = exp(-dot(d, d) * 90.0) * 7.0;
        fragColor = vec4(ramp + blob, bands + ramp * 0.4, uv.y * 3.0 + blob * 0.5, 1.0);
      }
    `,
  })
  const scene = new Scene()
  const mesh = new Mesh(makeFullscreenTriangle(), mat)
  mesh.frustumCulled = false
  scene.add(mesh)

  renderer.setRenderTarget(target)
  renderer.setViewport(0, 0, w, h)
  renderer.clear(true, true, true)
  renderer.render(scene, new Camera())

  mesh.geometry.dispose()
  mat.dispose()
}

/** A tone-map material wired the WRONG way — uFbSize = viewport size — to prove the
 *  harness detects the bug it exists to catch. Never used by the app. */
function buggyToneMaterial(hdrTex: WebGLRenderTarget, viewportSize: Vector2): RawShaderMaterial {
  return new RawShaderMaterial({
    glslVersion: GLSL3,
    vertexShader: RAW_VERT,
    fragmentShader: TONEMAP_FRAG,
    depthTest: false,
    depthWrite: false,
    transparent: true,
    blending: NoBlending,
    uniforms: {
      uHdr: { value: hdrTex.texture },
      uFbSize: { value: viewportSize.clone() }, // <-- THE BUG: viewport, not framebuffer
      uExposure: { value: TONE.exposure },
      uGamma: { value: TONE.gamma },
      uK2: { value: TONE.k2 },
      uHiDesat: { value: TONE.hiDesat },
      uPassthrough: { value: 0 },
    },
  })
}

function readAll(renderer: WebGLRenderer, rt: WebGLRenderTarget, w: number, h: number): Uint8Array {
  const buf = new Uint8Array(w * h * 4)
  renderer.readRenderTargetPixels(rt, 0, 0, w, h, buf)
  return buf
}

export interface StereoTestOpts {
  injectBug?: boolean
}

export function runStereoTest(opts: StereoTestOpts = {}): StereoTestResult {
  const injectedBug = !!opts.injectBug
  const fbW = EYE_W * 2
  const fbH = EYE_H

  const canvas = document.createElement('canvas')
  canvas.width = fbW
  canvas.height = fbH
  const renderer = new WebGLRenderer({ canvas, antialias: false, alpha: true })
  renderer.autoClear = false
  renderer.setPixelRatio(1)

  // 8-bit LDR, deliberately: this is the tone-map's OUTPUT, the equivalent of the XR
  // framebuffer. It must also match the Uint8Array readback below — a HalfFloatType target
  // read into a Uint8Array yields all zeros, which silently makes both composites identical
  // and the whole comparison vacuous. (Cost an iteration; the liveness check below is why
  // it was caught rather than shipped as a green test.)
  const out = (): WebGLRenderTarget =>
    new WebGLRenderTarget(fbW, fbH, {
      format: RGBAFormat,
      minFilter: LinearFilter,
      magFilter: LinearFilter,
      depthBuffer: false,
      stencilBuffer: false,
    })

  const flatRT = out()
  const stereoRT = out()

  const compositor = new Compositor(TONE)
  compositor.ensureSize(fbW, fbH, 1)
  fillHdr(renderer, compositor.hdrRT, fbW, fbH)

  // --- Reference: one full-width viewport. This is the desktop path, and it is the path
  //     that is always right, which is precisely why it makes a usable oracle.
  renderer.setRenderTarget(flatRT)
  renderer.setViewport(0, 0, fbW, fbH)
  renderer.clear(true, true, true)
  compositor.tonemap(renderer, flatRT, new Vector4(0, 0, fbW, fbH))

  // --- Under test: two half-width viewports, exactly as three.js drives the ArrayCamera
  //     while presenting. Same source texture, same shader, same frame.
  renderer.setRenderTarget(stereoRT)
  renderer.setViewport(0, 0, fbW, fbH)
  renderer.clear(true, true, true)

  if (injectedBug) {
    const buggy = buggyToneMaterial(compositor.hdrRT, new Vector2(EYE_W, EYE_H))
    const scene = new Scene()
    const mesh = new Mesh(makeFullscreenTriangle(), buggy)
    mesh.frustumCulled = false
    scene.add(mesh)
    const cam = new Camera()
    for (const x of [0, EYE_W]) {
      renderer.setRenderTarget(stereoRT)
      renderer.setViewport(x, 0, EYE_W, EYE_H)
      renderer.render(scene, cam)
    }
    mesh.geometry.dispose()
    buggy.dispose()
  } else {
    for (const x of [0, EYE_W]) {
      compositor.tonemap(renderer, stereoRT, new Vector4(x, 0, EYE_W, EYE_H))
    }
  }

  const a = readAll(renderer, flatRT, fbW, fbH)
  const b = readAll(renderer, stereoRT, fbW, fbH)

  // LIVENESS CHECK — non-negotiable. Comparing two buffers is meaningless if both are blank:
  // every delta is 0, the positive case "passes", and the negative control passes too, so the
  // test can never fail. Require the reference to actually vary across x before believing any
  // comparison drawn from it.
  let refMin = 255
  let refMax = 0
  for (let i = 0; i < a.length; i += 4) {
    if (a[i] < refMin) refMin = a[i]
    if (a[i] > refMax) refMax = a[i]
  }
  const refSpread = refMax - refMin
  if (refSpread < 16) {
    flatRT.dispose()
    stereoRT.dispose()
    renderer.dispose()
    return {
      pass: false,
      differing: 0,
      maxDelta: 0,
      total: fbW * fbH,
      width: fbW,
      height: fbH,
      injectedBug,
      note:
        `HARNESS BROKEN, not a result: the reference composite is nearly uniform ` +
        `(red spread ${refSpread}). Nothing is being compared — check the HDR fill and that ` +
        `the readback type matches the render-target type.`,
    }
  }

  let differing = 0
  let maxDelta = 0
  for (let i = 0; i < a.length; i += 4) {
    let worst = 0
    for (let c = 0; c < 3; c++) {
      const d = Math.abs(a[i + c] - b[i + c])
      if (d > worst) worst = d
    }
    if (worst > maxDelta) maxDelta = worst
    if (worst > DELTA_TOL) differing++
  }

  const total = fbW * fbH
  const pass = injectedBug ? differing > total * 0.05 : differing === 0

  flatRT.dispose()
  stereoRT.dispose()
  renderer.dispose()

  return {
    pass,
    differing,
    maxDelta,
    total,
    width: fbW,
    height: fbH,
    injectedBug,
    note: injectedBug
      ? 'negative control: uFbSize deliberately set to viewport size — a large delta here is the PASS'
      : 'per-eye viewports must reproduce the full-width reference exactly',
  }
}
