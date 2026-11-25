# Boot scene evidence, 2026-11-13

`boot.tscn` is the project entry. It draws an unshaded world-locked label and a rotating
quad against black, without loading main's script, shaders or gallery. Only after its
first draw does it request `main.tscn` with `ResourceLoader.load_threaded_request`.

Godot initializes OpenXR during engine startup with `xr/openxr/enabled=true`. Boot enables
XR on the viewport and requests 72 Hz immediately and on session start. Main reuses that
interface, binds its session handlers, then reads `get_session_state()`. It applies the
current environment blend and requests the refresh rate immediately as well as on later
session-start signals. Saved passthrough still waits for focused content processing.
See [Godot's OpenXR interface documentation](https://docs.godotengine.org/en/latest/classes/class_openxrinterface.html).

Main instantiation and tree changes stay on the main thread. Boot retains its camera and
loading geometry throughout constructors and content setup. The destination inherits the
origin and initial camera pose. Once content is ready, and XR is visible or focused, boot
switches to main's camera, waits for a draw with loading geometry still present, makes main
the current scene and frees itself. It never uninitializes XR or resets the reference space.
Resource-load failures retain the tracked view with an error message.

This is a projection-layer loading view. Driver work during main instantiation or GPU setup
can still stall app frames and animation. Quest compositor reprojection and the absence of
black frames during those stalls require the device check. An engine draw callback does
not prove that the headset displayed a frame. Engine initialization still precedes boot.

The 26 tools that directly instantiate `main.tscn` keep their existing entry path. Main
shows its original loading HUD when boot does not manage it. No harness depends on the
old project entry setting. The startup harness uses a deterministic session source to
exercise focus before main loads, current visible/stopping/loss-pending/synchronized states,
and later focus-loss/recovery signals. It checks first-draw cache isolation, nonblack boot
and content frames, camera/origin continuity, loading overlap and boot cleanup. Controls
reject eager loading and a listener that only waits for future focus signals. Existing
composition-layer parent, pose, visibility and deletion checks remain.

## Mac measurements

Godot 4.7.2 Mobile renderer, 320x240, `--xr-mode off --quit-after 100`, three separate
processes per version. Numbers are `[startup]` engine ticks in milliseconds. These are
Mac desktop timings, not Quest timings, launch-intent measurements or empty-Quest-cache proof.
Caches were not cleared. Keep the slow baseline run in the evidence.

| Metric | Before, runs 1 / 2 / 3 | After, runs 1 / 2 / 3 |
|---|---|---|
| First loading draw | 930 / 4651 / 1403 | 501 / 496 / 504 |
| Main ready begins | 907 / 4287 / 1341 | 982 / 971 / 966 |
| Content ready | 1027 / 4888 / 1532 | 1075 / 1064 / 1061 |
| Boot handover | Not present | 1125 / 1113 / 1111 |

Median first loading draw is 1403 ms before and 501 ms after. The ordering is the useful
result: every boot draw precedes the main load request. Raw logs are in
`.spike-out/boot-timings/{before,after}-{1,2,3}.log`.

## Gates

```text
SELFTEST PASS
PARSEALL PASS files=77 errors=0 control=FAIL
LOGICCHECK PASS failures=0 control=FAIL
STARTUPCHECK PASS failures=0 control=FAIL
STARTUP CONTROLS PASS eager=FAIL signals-only=FAIL
MENUSHOT PASS shots=52 failures=0
CARDSHOT PASS modes=5
IFSCHECK PASS failures=0
MANIFEST TEMPLATE PASS headtracking-only override
MANIFEST APK PASS android.hardware.vr.headtracking required=true launch activity excludeFromRecents=true ossplash=true mono colorspace=Rec.709 PNG=512x512
BUILD PASS debug
```

Inspected `.spike-out/boot_loading.png`, `startup_loading.png`, `boot_overlap.png`,
`boot_content.png` and the menu/card contact sheet. No script errors in the gate logs.

Debug APK is `build/fractalxr-debug.apk`. Copied the gitignored Vendors addon from the main
checkout. Unpacked the installed 4.7.2 Android source template locally because standalone
Godot template installation does not populate a fresh worktree. Export ran
`bash godot/tools/build.sh` with preset `runnable=false` temporarily, to prevent Android
device discovery. The original preset bytes were restored. No adb command, headset
operation, release export, push, merge or tag was performed.

## Owner's Quest check

1. Fresh-install this debug APK. Wear the Quest 3 and start a recording/timer at the launch
   selection in Library > Unknown Sources. Record firmware and installation state. By four
   seconds, require visible loading or tracked content, with margin as the target. Expect
   cyan "Loading FractalXR" text and a slowly rotating square once the engine can render.
   The Meta OS logo may still be absent. Its failure is unresolved.
2. Turn and translate your head during loading. The indicator should stay fixed in the room.
   Loading must remain visible through main setup, then give way to content with no black
   gap, head-pose reset or origin jump. On a fresh install, the controls card should appear
   after focus and tracked placement. Boot's engine log must precede the main load request
   and main ready; main's first-focus timestamp must preserve an earlier boot focus.
3. Dismiss the card, quit fully and relaunch from Unknown Sources. Repeat the timing and
   tracking checks warm. The card should remain dismissed. Record both wall-clock timings;
   desktop engine ticks cannot supply them.
4. Open the system dash during loading and after content appears. Rendering should continue.
   Input must be ignored, menu/help/pointers hidden, grips released and locomotion stopped
   while unfocused. Close the dash. Loading should finish without a pose reset; content
   should respond immediately after focus. An interrupted open help card should return.
5. Repeat interruption with sleep/power and headset removal, including while loading. Test
   a saved passthrough launch. The room should resume on the first focused content frames
   without requiring another focus cycle, and the runtime should report the requested 72 Hz.
   Repeat the fresh-install checks on a release-signed build before Meta submission.

The four-second deadline remains a headset gate. This Mac run does not establish VRC compliance.
