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
| Devices | `quest3\|quest3s` (Quest 2 is off: 700k points at 72Hz is a Quest 3 load and no Quest 2 has ever run it) |
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
- `godot/art/store/card_1024x576.png` — the listing artwork, the card shown in the library and on
  the homepage. This is the one that decides whether anyone clicks.
- `godot/art/store/background_1920x1080.png` — the listing background. Their guide is explicit:
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

**Summary**: Grab glowing fractals, walk a forest, and sculpt repeating worlds in VR.

**Description** (their markdown subset permits bold, italic, lists and links):

```
FractalXR makes live fractals on your headset. Take hold of a cloud of light, grow it around
you, explore a fractal floor, plant a forest, or reshape a repeating sculpture.

**Five modes**

- FLAME has 13 fractal flames, breeding and morphing, with about a million points by default.
  Grip to move one, use both grips to scale it, and pull a trigger to pick the next or previous
  flame. GALAXY grows it around you; ECHOES and SKY fill the space.
- BULB has 21 forms, including Mandelbulbs, Mandelboxes and quaternion Julia sets. They open
  hand-sized. Grab and scale them, use the triggers to browse, and pick splats, lines, a solid
  mesh or a marched surface under SURFACE.
- GROUND has eight fractal families. Walk with the left stick, zoom and snap turn with the
  right, drag with a grip, or point and pull a trigger to glide. JULIA explores the set at your
  feet; ORBIT traces the point you aim at.
- TREE has 13 species. The left trigger regrows the trees; the right plants at your pointer.
  SOW fills a grove, AVENUE lays out rows at COUNT settings up to about 500 trees, and WALK
  glides along them while you hold a trigger or push the right stick forward.
- IFS makes repeating sculptures. Use EDIT and hold a trigger on a handle to sculpt, with UNDO
  for the last edit. Both grips scale it. DIVE flies into a copy while you hold a trigger;
  ROOM and ECHOES put the sculpture around you.

Pick among 26 colour themes, let CYCLE move the colours, or turn on passthrough to see your
room. Turn your left wrist toward your face for the menu. A controls card explains each mode
on first launch, and HELP brings it back.

**Early Access.** Free, native, and computed live on the headset. Tell me what breaks.
```

**Tags**: fractal, art, relaxing, psychedelic, passthrough, mixed reality, experience, sandbox
**Devices**: Quest 3 and Quest 3S (3S untested) · **Position**: seated, standing and roomscale · **License**: free
**Comfort**: moderate. Grabbing moves the fractal rather than you, but flying through it moves
the whole world past your eyes, which some people will feel.

## 4. Before strangers touch it

Every upload requires this headset pass in each mode. Use snap turn where supported
(GROUND, TREE outside WALK, GALAXY, room-size IFS); check the comfort tunnel during movement.

- [ ] FLAME opens framed; controls card matches; snap turn and tunnel work in GALAXY; system
      dash mid-grab hides pointers and pauses movement; relaunch resumes the selected state
- [ ] BULB opens framed; controls card matches; grab, scale and movement tunnel work; system
      dash mid-grab hides pointers and pauses movement; relaunch resumes the selected state
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

- [ ] Release-signed APK installs clean over nothing (`adb uninstall uk.fractalxr.app` first)
- [ ] First-launch controls card appears, dismisses on either trigger, and does not come back
- [ ] `HELP` in the wrist menu brings it back
- [ ] 15-minute thermal soak (`godot/tools/soak.sh 900`), because every number so far is a
      cold-start number and Quest throttling after 5 to 15 minutes is guaranteed
- [ ] Passthrough toggles both ways without a black frame
- [ ] Quest 3S check, or drop it from the supported devices list
