# FractalXR

Fractals you can hold, walk through and stand inside, on a **Meta Quest 3 or 3S**.

FractalXR is a native Quest app built in Godot 4. Every form is computed live on the
headset's GPU, not played back from a video or a pre-made model, so detail keeps arriving as
you get closer. It runs in the void or in passthrough, where the fractal hangs in your room.

It started as a WebXR app, and that version still exists (see [The web build](#the-web-build)).
The native build in [`godot/`](./godot) is the main product now.

## What's in it

Five modes, picked from the rail along the top of the wrist menu. Each mode's fractal
chooser is a page of pictures rendered by the real engine.

### FLAME

A 3D fractal flame: the IFS chaos game run on the GPU as a cloud of up to about a million
glowing points. 13 presets, each one melting into the next rather than cutting.

- **GALAXY** grows the living flame round you over 8 seconds to about 24 m across, then
  shrinks it back to arm's length on a second press.
- **ECHOES** hangs four or eight copies of the live flame round the room, from lanterns 3 m
  out to giants 20 to 40 m away. They follow every morph and palette change.
- **SKY** bakes the flame on show into a panorama and hangs it behind the scene. SKY RES sets
  how sharp the live bake is.

### BULB

21 Mandelbulb-style forms (Mandelbulb, Mandelbox, quaternion Julia and relatives), hand-sized
and in front of you like something to pick up. Four ways to draw one:

- **Splats**, the default: the particles drawn as soft, depth-sorted Gaussian splats.
- **SOLID**: the bulb meshed on the headset with baked light and shadow, drawn as an opaque
  sculpture.
- **LINES**: the bulb cut into stacked slices and drawn as glowing contour lines, with
  PATTERN (rings, grid or cross) and WIDTH (normal, thin, hair).
- **The marched surface**: a raymarched distance-estimate surface.

### GROUND

An escape-time fractal is the floor and runs to the horizon. Eight families (Mandelbrot,
Burning Ship, Tricorn, Celtic, Perpendicular, Buffalo, Cubic, Quartic), each with its Julia
twin. Walk on it with the left stick, zoom about your feet with the right, and point at the
ground and pull the trigger to glide there. ORBIT hangs the orbit of the point under your hand
in the air as a chain of beads.

### TREE

Fractal trees as real geometry, grown from the base and moving in one wind field. 13 species,
from oak and willow to sakura, baobab and crystal.

- **AVENUE** sows two rows of trees down a path ahead of you. **WALK** makes it endless: hold
  a trigger and the avenue glides toward you.
- **COUNT** sows from 30 up to 500 trees, adding rows and length to the avenue.
- **FLOOR** puts something under them: a faint fractal ground in the theme's colours, fallen
  leaves round each trunk, or both.
- **BARK** swaps plain wood for fractal veins or Julia-set lace that wraps each branch.

### IFS

A sculpture of mirrored frames built by recursion, which you can edit by hand.

- **SIZE** switches between tabletop and room size, where you stand inside it with its
  centre at your eyes.
- **Family echoes** (LAYOUT) place copies round the room where the sculpture's own maps put
  its relatives: siblings, then the parent's siblings, out to an ancestor about twenty times
  the size.
- **DIVE**: hold a trigger and the sculpture swells until the copy you were looking at takes
  the hero's place, then the next step starts inside that one, for ever.

### In every mode

- **THEME**: 26 colour themes, shared by every mode.
- **COLOUR CYCLE**: scrolls the palette through each fractal's colours at slow, medium or
  fast, or slow plus a cross-fade to a new theme every minute.
- **SKY PICK**: the live flame bake, or one of three pre-rendered skies (Ember, Nautilus,
  Geode) that need no bake.
- **PASSTHRU** on the bottom bar of the menu, at every level.

## Try it on a Quest

You need a Quest 3 or 3S, a computer, and a USB-C cable.

1. Put the headset in developer mode (Meta Horizon phone app: Menu, Devices, your headset,
   Headset settings, Developer mode).
2. Install [SideQuest](https://sidequestvr.com/setup-howto) on the computer and connect the
   headset by USB. Allow USB debugging when the headset asks.
3. Download the latest `.apk` from the
   [Releases page](https://github.com/dervish666/FractalXR/releases).
4. In SideQuest, use "Install APK file from folder" (the box-with-an-arrow icon at the top)
   and pick the APK.
5. On the headset, open your Library and look under Unknown Sources for FractalXR.

The app asks for no permissions and needs no internet connection.

## Controls

The first launch shows a card with both controllers drawn on it. HELP in the wrist menu
brings it back.

| Input | Does |
|---|---|
| Grip, one hand | Move and rotate the fractal |
| Grip, both hands | Pull your hands apart to scale it and fly through |
| Right trigger | Next fractal, or press the menu control you are pointing at |
| Left trigger | Previous fractal |
| Turn your left wrist toward your face | The wrist menu |
| Menu button | Float the menu off your wrist; press again to put it back |

The sticks and triggers take on extra jobs in some modes (walking in GROUND, WALK in TREE,
DIVE in IFS). The help card lists them per mode.

## Comfort

Grabbing moves the fractal, not you. The modes that do move you are built to be gentle:

- TREE's WALK has a PACE setting (0.5, 0.75 or 1.0 m/s) and short eases in and out.
- WALK and DIVE at room size close a tunnel vignette round the edge of your view while you
  move, and WALK adds a faint room-fixed lattice in the dark as a rest frame.
- GALAXY clears the points closest to your eyes, and room-size IFS cuts away any beam that
  would pass through your head.

If smooth movement in VR bothers you, keep to the tabletop modes and use grab.

## Build from source

### Native Quest build

Needs Godot 4.7, JDK 17, the Android SDK and the
[godot_openxr_vendors](https://github.com/GodotVR/godot_openxr_vendors) plugin, which is not in
the repo. [`godot/README.md`](./godot/README.md) has the full setup list and every tool.

```bash
source godot/tools/env.sh   # toolchain paths; edit them for your machine
godot/tools/build.sh        # debug APK
godot/tools/build.sh release   # release APK, needs the release keystore env vars
```

`godot/tools/selftest.sh` checks the compute chain on the desktop. Release signing and the
SideQuest listing are covered in [`SIDEQUEST.md`](./SIDEQUEST.md).

### Web build

```bash
npm install
npm run dev         # HTTPS dev server on :5173
npm run build       # type-check + production build into dist/
```

WebXR needs a secure context. With the headset on USB, `adb reverse tcp:5173 tcp:5173` and
open `http://localhost:5173` in the Quest Browser; or open `https://<your-computer>:5173` and
accept the self-signed certificate. [`CLAUDE.md`](./CLAUDE.md) lists every command.

## The web build

The original FractalXR: a WebXR fractal-flame app in TypeScript and Three.js r0.184, with
flames and bulbs, breeding and mutation, a wrist menu, a dome gallery of presets, and
VR or passthrough. The repo also holds three smaller web apps: a Mandelbrot relief zoomer
(`zoom.html`), a Gaussian-splat viewer (`splat.html`) and a dev-only thumbnail baker
(`bake.html`).

**Live: [fractalxr.uk](https://fractalxr.uk)**, open it in the Quest Browser.

The web build is parked: new work goes into the native build, and the web side gets fixes
and the shared palettes. Cloudflare still builds and deploys `main` to the live site.

## Docs

- [`godot/README.md`](./godot/README.md): the native build, its tools, and the
  native-versus-web measurements that started it.
- [`ARCHITECTURE.md`](./ARCHITECTURE.md): the web build's render pipeline and chaos-game maths.
- [`SPEC.md`](./SPEC.md): product decisions and the feel it aims for.
- [`SIDEQUEST.md`](./SIDEQUEST.md): shipping the APK.
- [`CHANGELOG.md`](./CHANGELOG.md): what changed, release by release.

## Tech

Native: Godot 4.7 (Mobile renderer, compute shaders), OpenXR, GDScript.
Web: TypeScript, Vite, Three.js r0.184, WebGL2 and WebXR.
