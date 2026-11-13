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
- **Performance.3**: head-tracked graphics within 4 seconds of launch.
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
