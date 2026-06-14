# FractalXR

A WebXR **3D fractal flame** generator for the **Meta Quest 3**. Breed, morph and
explore glowing, living fractal-flame structures — in full **VR**, or in **mixed
reality** where they float in your actual room. Built with a custom GPU chaos-game
engine running a few-million-particle point cloud at headset framerate.

**▶ Live: [fractalxr.brisflix.com](https://fractalxr.brisflix.com)** — open it in the Meta Quest 3 browser.

> Put on a Quest 3, open the page, press **Enter VR** (void) or **Enter MR** (passthrough),
> and reach out and grab a fractal.

## Features

- **3D volumetric fractal flames** — the IFS chaos game generalised to 3D, rendered as a
  glowing additive point cloud (~700K–2.4M particles) you fly through and grab.
- **Explore** — 13 presets (8 hand-tuned + 5 bred-and-curated); one-hand grab to move, two-hand pull to scale and fly in.
- **Create** — randomize / mutate / cross-breed endless new flames (Electric-Sheep style).
- **Animate** — smooth flame-to-flame morphing, infinite auto-generate, gentle auto-rotation.
- **Colour** — 14 multi-hue palettes + recolour any flame.
- **VR _or_ Mixed Reality** — a passthrough toggle dissolves the void so the flame glows in
  your real room, with no session re-entry.
- **Keep & tune** — save favourites (persisted), and live-adjust particle count, point size,
  morph duration and spin from an in-VR wrist menu.
- **Adaptive quality** — a thermal/perf guard sheds particle count and nudges foveation to
  hold framerate on-device.

## Controls (in the headset)

- **Trigger** (pointing hand): commit the highlighted wrist-menu button, or — when not aimed
  at the menu — spawn a random flame.
- **Trigger** (other hand): mutate the current flame.
- **Grip** (either / both): grab to move & rotate; pull apart with both to scale and fly through.
- **☰ Menu button** (left controller): open / close the wrist menu.
- **A / X**: toggle auto-generate · **B / Y**: cross-breed.
- **Wrist menu**: presets, breeding, recolour, save / favourites, **passthrough** toggle,
  settings (particles / size / morph / spin) and **Exit VR**.

## Run it (development)

```bash
npm install
npm run dev
```

WebXR requires a **secure context (HTTPS or localhost)**. Two ways to open it on the Quest:

### Option A — USB (zero cert friction)
With the headset plugged in via USB-C and developer mode on:

```bash
adb reverse tcp:5173 tcp:5173
```

Then in the **Quest Browser** open `http://localhost:5173`. `localhost` is a secure context,
so WebXR works with no certificate warning. Hot reload works.

### Option B — LAN over HTTPS
`npm run dev` serves HTTPS via a self-signed cert (`@vitejs/plugin-basic-ssl`). Find your
machine's LAN IP (`ipconfig getifaddr en0`), then in the Quest Browser open
`https://<lan-ip>:5173` and accept the cert warning (**Advanced → proceed**).

## Build & deploy

```bash
npm run build     # type-check + production build into dist/
npm run preview   # serve the production build locally
```

`dist/` is a fully static bundle (`base: './'`, so it works from any path). Deployed via
**Cloudflare Pages** — build command `npm run build`, output directory `dist`.

## How it works

WebGL2 + Three.js **r0.184** + WebXR (WebGPU can't drive WebXR on Quest as of 2026). The
chaos game runs on the GPU as a float-texture ping-pong (state = `pos.xyz` + colour index),
points splat additively into an HDR target sized to the XR framebuffer, then a per-eye
log-density tone-map composites to the display. Mixed reality uses premultiplied-alpha output
so dark space reveals passthrough while bright cores stay opaque. See
[`ARCHITECTURE.md`](./ARCHITECTURE.md) and [`SPEC.md`](./SPEC.md) for the details.

## Tech

TypeScript · Vite · Three.js r0.184 · WebGL2 / WebXR.
