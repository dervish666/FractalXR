# Shipping the Quest build to SideQuest

The native Godot build in `godot/` is what a SideQuest listing hosts: SideQuest distributes
APKs, and the WebXR site can only be a link on the listing page. This is the checklist and the
copy, in the order the work actually happens.

## 1. The APK

Identity is permanent once published. It is already set:

| | |
|---|---|
| Package | `uk.fractalxr.app` |
| Label | FractalXR |
| Devices | `quest3\|quest3s` (Quest 2 is off because the default is about a million points and no Quest 2 has ever run it) |
| Permissions | OpenXR only. `INTERNET` is off, so the install screen asks for nothing |
| Icons | `godot/art/icon_192.png`, `icon_fg_432.png`, `icon_bg_432.png` |

**Release signing.** Every APK before this one was debug-signed. Once, ever:

```bash
godot/tools/keystore.sh                 # writes ~/.keys/fractalxr-release.keystore
export GODOT_ANDROID_KEYSTORE_RELEASE_PATH=~/.keys/fractalxr-release.keystore
export GODOT_ANDROID_KEYSTORE_RELEASE_USER=fractalxr
export GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD=…      # in your profile, never in the repo
godot/tools/build.sh release            # -> godot/build/fractalxr.apk, prints the signer
```

Back that keystore up somewhere you will still have in five years. Lose it and the only way to
ship an update is a new package id, with every existing user having to uninstall first.

**Version.** `version/code` in `godot/export_presets.cfg` and SideQuest's own Version Code field
both need bumping on every upload; SideQuest's is what triggers the update notification in a
user's dashboard.

## 2. The art

Everything is generated from real engine renders, so the store never shows something the app
cannot produce.

```bash
npm run art                                    # renders presets at 1024px -> godot/art/candidates/
                                               # narrow it: /icon.html?names=Vortex,Glacier
godot/tools/make_icons.py godot/art/candidates/glacier.png
godot/tools/make_store_art.py godot/art/candidates/vortex.png godot/art/candidates/glacier.png
```

- Launcher icon: currently **Glacier**, the blue spiral. Swap it by re-running `make_icons.py`
  against a different candidate; `--keep` and `--air` control how tightly it crops to the core.
- `godot/art/store/card_1024x576.png`: the listing artwork, the card shown in the library and on
  the homepage. This is the one that decides whether anyone clicks.
- `godot/art/store/background_1920x1080.png`: the listing background. Their guide is explicit:
  no text, no logos.

**Screenshots and the trailer have to come out of the headset.** 3 to 6 of them, 16:9, and a
video weighs more than everything else for getting a staff pick. A desktop render is not what a
person sees through the lenses.

```bash
adb shell ls -t /sdcard/Oculus/Screenshots/ | head
adb pull /sdcard/Oculus/Screenshots/<file>
```

## 3. The listing

App Studio on sidequestvr.com. Mark it **Early Access** and **Unlisted** first: the page stays
live on a direct link and is hidden from search, which is the right shape for handing it to a
dozen people and finding out what breaks.

**Title**: FractalXR

**Summary**: Hold a fractal in your hands, pull it open and walk through it.

**Description** (their markdown subset: bold, italic, lists, links, no tables or HTML):

```
FractalXR puts a fractal within arm's reach and lets you take hold of it. Every form is
computed live on the headset, not played back from a video, so more detail appears as you
bring it closer.

Squeeze a grip to move and turn it. Squeeze both grips and pull your hands apart to scale it
up and pass through the middle. Turn your left wrist toward your face for the menu.

**Five modes**

- **FLAME.** A cloud of about a million glowing points. 13 flames, each morphing into the next.
- **BULB.** 21 forms (Mandelbulbs, Mandelboxes, quaternion Julia sets) that open hand-sized,
  drawn as soft splats, contour lines, a solid sculpture or a marched surface.
- **GROUND.** A fractal floor that runs to the horizon. Eight families, each with its Julia
  twin. Walk with the left stick, or point and pull a trigger to glide there.
- **TREE.** 13 species that grow from the base and sway. Point at the floor and pull the right
  trigger to plant one, or lay out an avenue of about 500.
- **IFS.** A sculpture of mirrored frames. Turn on EDIT, hold a trigger on a handle and drag to
  reshape it.

**Also**

- 26 colour themes, and CYCLE to keep them moving
- Passthrough, so the fractal hangs in your room
- No account, no permission prompts, no internet

**Early Access.** If something breaks, tell me at https://github.com/dervish666/FractalXR/issues

A controls card shows on first launch. HELP in the wrist menu brings it back.
```

**Tags**: fractal, art, relaxing, mixed reality, passthrough, sandbox, creative, psychedelic
(the first five on the Meta store)
**Devices**: Quest 3 and Quest 3S (3S untested) · **Position**: seated, standing and roomscale · **License**: free
**Comfort**: moderate. Grabbing moves the fractal, not you. GROUND, TREE's WALK, IFS DIVE and
FLAME's GALAXY move the world past you behind a tunnel vignette. Snap turns are 30 degrees
where a mode has them.
FLAME and BULB at tabletop size are comfortable seated.

## 4. Before strangers touch it

Every upload requires this headset pass in each mode. Use snap turn where supported
(GROUND, TREE outside WALK, GALAXY, room-size IFS); check the comfort tunnel during movement.

- [ ] Release-signed APK installs clean over nothing (`adb uninstall uk.fractalxr.app` first)
- [ ] FLAME opens framed; controls card matches; snap turn and tunnel work in GALAXY; system
      dash mid-grab hides pointers and pauses movement; relaunch resumes the selected state
- [ ] BULB opens framed; controls card matches; grab, scale and stick movement turn or move the
      object in front of you without a movement tunnel; system dash mid-grab hides pointers
      and pauses movement; relaunch resumes the selected state
- [ ] GROUND opens framed; controls card matches; snap turn and tunnel work; system dash
      mid-drag or glide hides pointers and stops movement; relaunch resumes the selected state
- [ ] TREE opens framed; controls card matches; snap turn and WALK tunnel work; system dash
      mid-grab or WALK hides pointers and stops movement; relaunch resumes the selected state
- [ ] IFS opens framed; controls card matches; room-size snap turn and DIVE tunnel work; system
      dash mid-grab or DIVE hides pointers and pauses movement; relaunch resumes the selected state
- [ ] Cold launch reaches a head-tracked frame in under 4 seconds. Record launch in logcat,
      then the release-visible `[startup] first session_focussed ticks_msec=...` and
      `[startup] first placement ticks_msec=... first_focus_msec=...` lines. Engine ticks start
      at engine startup; use logcat timestamps for launch-to-frame timing and confirm in the
      headset that the first placed frame tracks the head. Placement alone does not prove this.

- [ ] First-launch controls card appears, dismisses on either trigger, and does not come back
- [ ] `HELP` in the wrist menu brings it back
- [ ] Run a 15-minute thermal soak on the release APK and watch the frame rate in OVR Metrics
      Tool. Every number so far is a cold-start number and the Quest throttles after 5 to 15
      minutes. Release builds suppress `[perf]`. Use
      `bash godot/tools/soak.sh 900 > soak.csv` on a debug build only for the per-stage breakdown.
      Debug measurements do not replace the release soak.
- [ ] Passthrough toggles both ways without a black frame
- [ ] Quest 3S check, or drop it from the supported devices list
