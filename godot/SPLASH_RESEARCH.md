# Quest startup splash investigation, 2026-11-13

The APK meets Meta's published splash requirements. The missing OS splash is unresolved.
The best-supported remaining hypothesis is a Horizon OS launch/splash handoff problem,
including a possible interaction with Godot's Android launch surface. That is an inference,
not a reproduced root cause. The owner's 0.35-second `Splash Screen com.oculus.vrshell`
window names a shell window; it does not identify the app's VR compositor layer or establish
why that layer was absent. No adb command or headset operation was used in this investigation.

A separate, confirmed startup defect was fixed. `main.gd:341` constructs `Flam3Tonemap`
before `_ready()`. Its constructor queued shader creation and `compute_pipeline_create`
even on Mobile, where `_start_content()` never attaches its compositor. Mobile now skips
that work. This removes one avoidable cold pipeline compile. It does not establish that
the OS logo appears, that launch takes less than four seconds, or how many milliseconds
the change saves on Quest.

## Sources fetched and what they establish

Meta's [native splash guide](https://developers.meta.com/vr/documentation/native/android/mobile-splash/),
updated 9 October 2026, requires `assets/vr_splash.png` and
`com.oculus.ossplash=true` inside `<application>`. It says, "The file name is case-sensitive."
It also says, "The aspect ratio of your image, not its resolution, determines the displayed size."
There is no fixed mono resolution, power-of-two requirement, RGB-only rule, ban on alpha,
required sRGB PNG chunk, store-install restriction or minimum Horizon OS version on that page.
These are absent requirements, not proof that every undocumented image encoding or launch
path works. Stereo is side-by-side, each half no wider than 2.3 times its height.

Meta's [Unity guide](https://developers.meta.com/vr/documentation/unity/unity-splash-screen/)
packages the same asset and application metadata. It can convert any Unity texture to PNG.
Its current example uses `P3`, following OVRManager's Color Gamut setting. It does not require
every engine to use P3. PNG colour-profile chunks and the manifest's colorspace string are
different mechanisms. Our icon has no sRGB, gAMA or iCCP chunk. Neither guide requires one.
Changing the manifest value to the undocumented string `sRGB` has no support in these sources.

Meta's [Unreal guide](https://developers.meta.com/vr/documentation/unreal/unreal-loading-screens/)
distinguishes the system shell's launch splash from engine/Blueprint loading screens. It
uses the same PNG and manifest mechanism, including `mono` and colorspace metadata. Its
engine splash alpha controls concern engine composition layers; they are not evidence that
the system PNG must lose its alpha channel.

Meta's [design guide](https://developers.meta.com/vr/design/mr-splash-screen-bp/)
allows opaque or semi-transparent backing artwork and describes the OS splash as independent
of application stalls. It also warns that a custom startup scene still waits for engine
initialization. Its current sizing guidance agrees with the native and Unity guides.

Meta's [13 May 2021 announcement](https://developers.meta.com/vr/blog/instant-runtime-driven-splash-screens/)
says, "The splash image (and 3-dots) will hide as soon as the app renders its first frame."
It introduces the feature with SDK v28, which is not a statement of a current minimum OS
version. Its resolution-controls-display-size guidance is superseded by the October 2026
guides. Do not use that old sizing rule to diagnose this 512-pixel image.

No fetched primary source says the feature only works for store-installed or release-signed
apps. Therefore this investigation cannot substantiate the claim that sideloading prevents
the splash. The precise firmware version and compositor behavior still require device evidence.

## Vendor plugin and developer reports

The installed gitignored addon is a compiled GDExtension. Its shipped changelog identifies
5.1.0. The matching [5.1.0 source](https://github.com/GodotVR/godot_openxr_vendors/blob/5.1.0-stable/plugin/src/main/cpp/export/meta_export_plugin.cpp#L474)
reads `application/boot_splash/image` as raw bytes and adds `res://vr_splash.png` during export.
It does not convert the PNG, change its profile, resize it, or run an entitlement check.
Lines 507 through 514 emit `ossplash=true`, `type=mono`, and `colorspace=Rec.709`.
It adds `passthrough-contextual` only for a non-opaque OpenXR environment blend mode.
Black is the documented default, so the absent background key in our opaque-mode APK is valid.

[Vendor PR #444](https://github.com/GodotVR/godot_openxr_vendors/pull/444), merged 23 January
2026, reports that "without setting the splash type to `mono` in the manifest, the splash image would not appear."
The author explains that Rec.709 was chosen to match Godot and was not strictly necessary
for that fix. Our APK already contains both tags. Reapplying this fix cannot explain our failure.
[PR #441](https://github.com/GodotVR/godot_openxr_vendors/pull/441) attributed the regression
to an OS change in the default splash type and was superseded by #444. That historical report
does not override the current native guide's documented mono default.

[PR #255](https://github.com/GodotVR/godot_openxr_vendors/pull/255) introduced the feature
with a working developer preview. [Issue #190](https://github.com/GodotVR/godot_openxr_vendors/issues/190)
concerned loss of passthrough during loading, not a missing opaque PNG. Both establish that
this feature has worked in Godot, but neither proves our current firmware/launch path.

In the [Meta OpenXR developer thread](https://communityforums.atmeta.com/questions-and-discussions-26/how-to-handle-splash-on-unity-175543),
the original author confirms OVRManager's system splash works with OpenXR. The discussion
concerns launch yaw. A [Godot developer report](https://forum.godotengine.org/t/quest-godot-encryption-part-deux/129805)
describes an engine taking 8 to 10 seconds before its loading scene and adding the OS PNG
outside the encrypted pack. Our asset is already outside the Godot project data at the APK
root asset path. Neither report supplies a missing step for this APK. Searches of Reddit did
not find a directly matching, resolved system-splash report worth treating as evidence.

## APK inspection

Inspected the existing 13 November debug APK in the main checkout, then the new debug export.
`aapt2 dump xmltree` confirms all three application metadata values, required VR headtracking,
and the excluded-from-Recents launch activity. The PNG is a normal ZIP_STORED asset, not a
resource reference or an image hidden inside the project pack.

The packaged PNG is 231,470 bytes and byte-identical to `art/icon_512.png`.
`file`, `sips`, PNG chunk parsing and Pillow agree on 512 by 512, 8-bit RGBA, non-interlaced.
Every alpha byte is 255. Its colour channels span visible non-black values. Its chunks are
IHDR, four IDAT chunks and IEND. Transparency, indexed colour, 16-bit channels, an all-black
image and a malformed file extension do not explain this asset. Reducing it to RGB would
be an unsupported experiment, not a demonstrated fix.

The activity's resource ID resolves to `GodotAppSplashTheme`, inheriting `Theme.SplashScreen`,
with `GodotAppMainTheme` after the splash. The APK's `compat_splash_screen.xml`,
`splash_screen_view.xml` and `splash_icon.webp` belong to this Android window splash.
[GodotApp.java](https://github.com/godotengine/godot/blob/4.7.2-stable/platform/android/java/app/src/main/java/com/godot/game/GodotApp.java#L72)
unconditionally calls AndroidX `installSplashScreen()` before `super.onCreate()`.
The special keep condition applies when `disableGodotSplash` is set. This is a separate
mechanism from the Meta compositor PNG. Its presence alone proves no conflict. An A/B build
that bypasses both the theme and AndroidX installation could test the interaction; this
change has not been made on speculation.

## What runs before the loading label

[Godot 4.7.2 main.cpp](https://github.com/godotengine/godot/blob/4.7.2-stable/main/main.cpp#L4755)
loads and instantiates the configured main scene before it adds that scene to the tree.
Rendering, audio, XR, extensions, script languages and theme initialization precede that.
The flat engine boot logo uses the main window framebuffer through
[RendererCompositorRD](https://github.com/godotengine/godot/blob/4.7.2-stable/servers/rendering/renderer_rd/renderer_compositor_rd.cpp#L214);
it is not an independent head-tracked Quest loading scene.

Main's member initializers construct the cloud, ground, marcher, solid, trees, IFS and tone
effect before `_ready()`. Those constructors load graphics shaders. The tone effect also
queued an actual compute-pipeline creation, now removed on Mobile. Moving JSON/menu/compute
setup after `_ready()`'s first draw did not move these constructors. The reported 2.5 to
4.5 seconds cannot be assigned entirely to scene loading or shader work without target
profiling. Mac Metal caches and timings do not reproduce a cold Quest Vulkan driver.

Also, `RenderingServer.frame_post_draw` proves an engine draw boundary, not headset visibility.
[OpenXRAPI::end_frame](https://github.com/godotengine/godot/blob/4.7.2-stable/modules/openxr/openxr_api.cpp#L2652)
can submit zero layers while the session is not ready to render. The existing startup test
must not be read as proof of a visible loading frame on the device.

The fastest independent fallback is a tiny `boot.tscn` with only XROrigin3D, XRCamera3D,
an unshaded loading label or quad and a black environment. It must not reference main.gd,
fractal shaders, gallery textures or content constructors. Enable `use_xr`, keep rendering
through session startup, then request `main.tscn` with `ResourceLoader.load_threaded_request`.
Keep the loading layer alive through main instantiation and until main has supplied a
visible XR frame. A one-shot desktop `frame_post_draw` is insufficient for that handoff.
Keep scene-tree node creation on the main thread. A compositor quad can preserve a tracked
loading layer during a main-thread stall, but its registration/handoff still needs Quest.

Meta's [startup guidance](https://developers.meta.com/vr/documentation/unity/unity-mobile-performance-intro/)
says, "While the small start up scene is active, the main scene is loaded in the background."
A scratch Mac probe rendered the loading label at engine tick 637 with
`main_started=false` and `cached_main=false`; main resource load and instantiation then
took 406 and 120 ms. These figures demonstrate ordering in one local run, not Quest latency.
The eager-load control failed the same first-draw assertion. The positive frame was inspected.
This prototype is in `.spike-out/splash-research/boot_probe.gd`; it is not the shipped boot path.

## Changes and gates

`scripts/core/flam3_tonemap.gd` skips the unused Mobile pipeline. The new assertion in
`tools/startup_check.gd` failed against the original constructor and passed after the fix.
`tools/manifest_check.py` now also enforces the shipped Rec.709 choice. Its `controls` command
rejects a missing or P3 colorspace. The original checker accepted the P3 control.
These are startup-work and packaging protections, not a claimed OS-splash repair.

```
SELFTEST PASS
PARSEALL PASS files=76 errors=0 control=FAIL
STARTUPCHECK PASS failures=0 control=FAIL
TONEMAPPROBE PASS renderer=mobile pipeline=false
TONEMAPPROBE PASS renderer=forward_plus pipeline=true
MANIFEST TEMPLATE PASS headtracking-only override
MANIFEST APK PASS android.hardware.vr.headtracking required=true launch activity excludeFromRecents=true ossplash=true mono colorspace=Rec.709 PNG=512x512
MANIFEST CONTROLS PASS rejected=2 wrong-colorspace=FAIL missing-colorspace=FAIL
BUILD PASS debug
```

The debug export ran `bash godot/tools/build.sh`. A fresh worktree exposed a pre-existing
bootstrap bug: standalone `--install-android-build-template --quit` does not install the
template in Godot 4.7.2. The installed source archive was unpacked locally instead, with
the version marker and executable Gradle wrapper restored. No shared SDK files were changed.
For export, `runnable=false` temporarily prevented Godot's Android device-discovery thread;
the original preset bytes were restored afterward. No adb-daemon messages occurred in the
successful export log. No release export, push, merge or tag was performed.

## Owner's headset check

Use `build/fractalxr-debug.apk`. With the headset worn, record the firmware version and do a
fresh-install launch from Library > Unknown Sources, followed by a warm launch. Look for the
fractal icon in front of the initial view and the OS loading treatment, then the text
`Loading FractalXR...`, then content. Turn the head during each stage. Require a visible VR
loading indicator or head-tracked graphics within four seconds of selecting Launch, with
margin, and no black gap during the handoff. Observe inside the headset; a desktop capture
or a named Android window cannot establish what the compositor showed.

If the icon remains absent, this patch has not fixed the OS splash. If the first loading
label remains late, take the tiny boot path next and profile the remaining engine startup.
For an AndroidX hypothesis test, compare an otherwise identical minimal XR app with its
window splash enabled and bypassed. A release-channel installation of the same APK is a
separate way to test distribution-path dependence. Neither experiment justifies declaring
sideloaded builds unsupported before observing its result. VRC.Performance.3 remains open.
