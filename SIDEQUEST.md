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

**Summary**: Grab a fractal flame with both hands, pull it open, and fly through the middle.

**Description** (their markdown subset: bold, italic, lists, links, no tables or HTML):

```
FractalXR draws a million-point fractal flame in front of you and lets you take hold of it.

Grip to move it around. Grip with both hands and pull them apart to open it up and fly through
the middle. Every form is a live chaos game running on the headset's own GPU rather than a video
or a mesh, so the detail keeps arriving as you get closer to it.

**In this build**

- 13 flames and 21 Mandelbulb-style forms, each one melting into the next instead of cutting
- A wrist menu for particle count, brightness, colour theme, drift and detail
- Passthrough, so the fractal hangs in your actual room
- Holds 72Hz on a Quest 3 at around 700,000 points

**Early Access.** This is the native port of a browser project and the feature list is still
growing. Tell me what breaks.

The controls appear on a card the first time you launch it. Turn your left wrist toward your
face for the menu.
```

**Tags**: fractal, art, relaxing, psychedelic, passthrough, mixed reality, experience, sandbox
**Devices**: Quest 3, Quest 3S · **Position**: seated and standing · **License**: free
**Comfort**: moderate. Grabbing moves the fractal rather than you, but flying through it moves
the whole world past your eyes, which some people will feel.

## 4. Before strangers touch it

- [ ] Release-signed APK installs clean over nothing (`adb uninstall uk.fractalxr.app` first)
- [ ] First-launch controls card appears, dismisses on either trigger, and does not come back
- [ ] `HELP` in the wrist menu brings it back
- [ ] 15-minute thermal soak (`godot/tools/soak.sh 900`), because every number so far is a
      cold-start number and Quest throttling after 5 to 15 minutes is guaranteed
- [ ] Passthrough toggles both ways without a black frame
- [ ] Quest 3S check, or drop it from the supported devices list
