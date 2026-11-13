# Shipping the Quest build to the Meta Horizon Store

The Horizon Store gets the same APK as SideQuest: same package id, same release keystore, so an
install from either store upgrades over the other. SideQuest reviews content. Meta runs its
Virtual Reality Checks (VRCs) on every submission, so this file is the work on top of
[SIDEQUEST.md](SIDEQUEST.md). The requirements below were read off Meta's developer pages on
2026-11-13. They change, so re-read the linked page before trusting a number.

## 1. Accounts

- Organization verification in the developer dashboard (Admin, with a government ID) before the
  first upload. No fee for a free app.
  ([verification](https://developers.meta.com/horizon/resources/publish-organization-verification/))
- Create the app in the Developer Dashboard. It hands out an App ID, which the build does not
  need while we stay off the Platform SDK.

## 2. The APK

What Meta checks, and where we stand
([manifest](https://developers.meta.com/horizon/resources/publish-mobile-manifest/),
[signing](https://developers.meta.com/horizon/resources/publish-mobile-app-signing/)):

| Rule | FractalXR |
|---|---|
| targetSdk 34 (required for apps created since 2026-03-01) | 34 |
| minSdk 29 to 34 | 29 |
| 64-bit only (VRC.Quest.Packaging.6) | arm64-v8a only |
| `excludeFromRecents="true"` on the launch activity (VRC.Quest.Packaging.1) | `package/exclude_from_recents=true` from 0.10.0 |
| `android:debuggable` false or unset | release export only |
| Signature scheme v2, your own release certificate, the same one for every update | `godot/tools/build.sh release` |
| Required head tracking | `tools/AndroidManifest.xml` overrides the generated optional feature |
| Minimum permissions (VRC.Quest.Security.2) | OpenXR only, no INTERNET |

Release-sign with the keystore from SIDEQUEST.md section 1. Meta's prep page says a lost
keystore leaves one way out: delete every build.

**No entitlement check.** VRC.Quest.Security.1 has been recommended, not required, since
2021-03-03. Adding one means the Meta Platform SDK plugin, which asks for the INTERNET
permission, and then the install screen asks for something.

## 3. The VRCs only the headset can answer

- **Performance.1** requires an allowed refresh rate and at least 60 fps rendering.
  Interactive apps must use 72, 80, 90, 96, 100 or 120 Hz where supported; FractalXR requests
  72 Hz. Meta's test rejects extended periods below 60 fps and lists exceptions for loading,
  system overlays and recording. Measure the **release APK** with **OVR Metrics Tool for
  45 minutes per GPU-heavy mode, GROUND and BULB**, each from a cold headset. Release builds
  suppress `[perf]`. Use `godot/tools/soak.sh 2700 > soak.csv` on a **debug build only** for
  the per-stage breakdown. Debug measurements do not replace the release soak.
  ([Performance.1](https://developers.meta.com/horizon/resources/vrc-quest-performance-1/))
- **Performance.3** allows head-tracked graphics within 4 seconds **or a loading indicator in
  VR** ([Performance.3](https://developers.meta.com/vr/resources/vrc-quest-performance-3/)).
  The installed OpenXR Vendors 5.1.0 plugin exports Meta's OS splash through
  `meta_xr_features/instant_splash_screen=true`. It copies `application/boot_splash/image`
  (`godot/art/icon_512.png`, existing 512x512 mono PNG) into `assets/vr_splash.png` and adds
  application metadata `com.oculus.ossplash=true` and type `mono`. No manifest-template
  override is needed. Every export checks both the manifest and the exact packaged image.
  **13 November headset result:** the owner sees no OS splash in the sideloaded debug build,
  despite a correct manifest and PNG. Published sources do not establish a store-only
  restriction. See [the investigation](godot/SPLASH_RESEARCH.md) for fetched sources, the
  removed unused Mobile pipeline compile, and the tiny boot-scene fallback. The OS-splash
  failure remains unresolved.
  Meta's [native splash guide](https://developers.meta.com/vr/documentation/native/android/mobile-splash/)
  (updated 2026-10-09) requires PNG and the case-sensitive asset name, with no fixed mono
  resolution. Aspect ratio determines displayed size; resolution determines sharpness.
  For stereo, each half must be no more than 2.3 times as wide as tall.
  The system splash stays in front of the initial view rather than following head movement.
  The app then draws a tracked loading label before loading JSON, the menu/atlas and compute
  pipelines. Startup phase timestamps remain in release logs.
  **Headset gate remains open.** On a fresh install of the next release-signed APK, with the
  headset worn, measure launch-intent wall time to the first visible OS splash/loading view.
  Require under 4 seconds with margin, head tracking during loading, no black handoff, then
  focus, placement and the first-launch controls card. Repeat warm launches and system-menu
  interruption during loading. Engine `ticks_msec` and Mac renders do not measure launch-intent
  latency or prove what the Quest compositor displayed. v0.10.0/code 3 measured 8955 ms engine
  time to first focus on a fresh install and 2224/2479 ms warm, plus about 2.5 to 3 s before
  engine start. Do not claim compliance until the device pass.
- **Functional.2 and Input.4**: open the system menu in the middle of a grab, press the power
  button, take the headset off. The app must keep rendering, pause, draw no menu or pointer, and
  ignore input until focus comes back.
  ([Functional.2](https://developers.meta.com/horizon/resources/vrc-quest-functional-2/),
  [Input.4](https://developers.meta.com/horizon/resources/vrc-quest-input-4/))

## 4. The listing

- **Privacy policy URL**, in Additional Details:
  https://fractalxr.uk/privacy.html (served after merge and web deployment; check it before
  submission). The policy covers the native Quest app. No Data Use Checkup while we stay off
  the Platform SDK.
- **Age group self-certification** and the **IARC questionnaire**, both at submission.
  ([age groups](https://developers.meta.com/horizon/resources/age-groups/))
- **Copy**: the SideQuest title, summary and description.
- **Art**, all 24-bit PNG unless noted
  ([asset guidelines](https://developers.meta.com/horizon/resources/asset-guidelines/)).
  `godot/tools/make_store_art.py` only writes SideQuest's sizes today.
  For now, make the Meta-sized art by hand in an image editor using the engine renders in
  `godot/art/candidates/` (`npm run art` regenerates them). Compose or crop each image to the
  dimensions below and export as a 24-bit RGB PNG. Capture the five screenshots on the headset.

Chosen submission fields follow Meta's
[category and genre list](https://developers.meta.com/vr/resources/publish-taxonomy-guidelines/).
The modes follow tracked head and controller poses; they do not require a fixed play area.
Confirm all three player modes during the headset pass.

| Field | Chosen value |
|---|---|
| Category | Apps |
| Primary genre | Creativity |
| Comfort | Moderate |
| Devices | Quest 3, Quest 3S (3S untested; keep the SideQuest section 4 gate) |
| Player modes | Seated, standing, roomscale |
| Supported input | Touch controllers; hand tracking off |
| Upload tool | `ovr-platform-util upload-quest-build` |

The [OVR Platform Utility guide](https://developers.meta.com/vr/resources/publish-reference-platform-command-line-utility/)
describes APK uploads and release channels.
Run this from the repo root after building the release APK:

```bash
ovr-platform-util upload-quest-build \
  --app-id '<APP_ID>' --app-secret '<APP_SECRET>' \
  --apk godot/build/fractalxr.apk --channel ALPHA \
  --age-group '<AGE_GROUP>'
```

In the Meta Horizon Developer Dashboard, select the app, then Development, API. Copy App ID
and App Credentials (the app secret) there. Keep the secret outside the repo. Replace
`<AGE_GROUP>` with the self-certified value, one of `TEENS_AND_ADULTS`, `MIXED_AGES` or `CHILDREN`.
Meta leaves uploads without an age group in draft status.

| Asset | Size |
|---|---|
| Hero cover | 3000x900 |
| Cover landscape | 2560x1440 |
| Cover square | 1440x1440 |
| Cover portrait | 1008x1440 |
| Mini landscape | 1080x360 |
| Icon | 512x512 |
| Screenshots, exactly 5, no duplicates | 2560x1440 |
| Trailer, 30 s to 2 min | 1080p to 2K, MP4 H.264 + AAC |
| Trailer cover | 2560x1440 |
| Logo, transparent (optional) | up to 9000x1440, 32-bit PNG |

## 5. Release channels

Upload to **ALPHA** first. It is invite-only, the store's version of SideQuest's unlisted page,
and every upload there must already meet the release packaging rules. When it holds up, copy the
build to Production and Submit for Review at least two weeks before the launch you want; Meta
publishes no review time for a new app. Every upload needs a higher `version/code` than the last
([channels](https://developers.meta.com/horizon/resources/publish-release-channels/)).
