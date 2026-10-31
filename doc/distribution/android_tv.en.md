# Android TV Installation and Distribution

Default Chinese version: [android_tv.zh.md](android_tv.zh.md)

Android TV has completed maintainer-confirmed small-scale testing and joins `main` from the separate `android-tv` test branch. Future Android builds produce mobile and TV packages together; new versions publish both in the same GitHub Release. This integration does not bump the version, create a tag, or backfill TV packages into published `v1.18.1` or `v1.18.2-rc.6` releases.

## Installation and Updates

Choose a version with TV assets on [Releases](https://github.com/CyrilPeng/venera-next/releases):

- Universal: `VeneraNext-<version>-android-tv.apk`
- ARM64: `VeneraNext-<version>-android-tv-arm64-v8a.apk`
- ARM32: `VeneraNext-<version>-android-tv-armeabi-v7a.apk`
- x86_64: `VeneraNext-<version>-android-tv-x86_64.apk`

Use universal if the system ABI is unknown; 64-bit hardware does not necessarily run an OS supporting ARM64 apps. Transfer and sideload the APK on the TV or box, granting installation permission to a trusted installer when prompted. No comic sources are bundled or recommended; users configure legal content themselves.

| Property | Mobile | TV |
|---|---|---|
| Flavor | `mobile` | `tv` |
| Package | `com.github.cyrilpeng.veneranext` | `com.github.cyrilpeng.veneranext.tv` |
| Launcher | VeneraNext | VeneraNext TV, with TV entry and banner |
| Orientation | Existing settings | Landscape |
| Data | Original sandbox | Separate sandbox; no automatic mobile data migration or deletion |
| App updates | Existing stable/prerelease channel | Same version channel, requiring an uploaded universal TV APK |

Update checks notify and open the matching release page; they do not download or install an APK automatically. TV prompts explicitly request an `android-tv` package. Source-extension updates are unchanged. Early TV Alpha builds disabled app update checks, so install the first mainline TV package manually to gain the new update controls.

The two apps can coexist. Export a separate backup before upgrading. Official TV Alpha installations can upgrade in place with a mainline TV APK signed by the same certificate; no uninstall or data clearing is needed. Do not let both apps write to the same comic or WebDAV backup directory concurrently. Android may block downgrades; uninstalling to bypass that restriction would lose TV app data.

## Remote Controls and Reading Policy

- Direction keys move focus in the main UI; Select / gamepad A activates, Back / gamepad B returns. Menu keys open context menus on supported controls.
- On the reading surface, direction keys turn pages or scroll and Select opens the menu. Menu navigation never turns background pages. Back closes the menu first, then saves progress and exits.
- Losing focus, opening menus, or backgrounding cancels held input. The reader does not resume page repeats unexpectedly, and TV hides the rotation button.
- Settings -> Reading -> TV low-memory mode is enabled by default: single-page Gallery, one-page preloading, a 64 MiB decoded-image cache, and decoding limited to `1920 x 1080` pixels with an 8192-pixel maximum edge.
- Disabling this mode restores existing global/device/comic settings, including Continuous and Waterfall. The switch stays on the device, is excluded from backups/WebDAV, and is not overwritten by imports. Original files and their dimension metadata remain unchanged.

This adapts the existing UI to a remote, rather than redesigning every screen for ten-foot use. Web login, CAPTCHA, system file pickers, and third-party pages may need an input method or companion device. Long strips and zoomed details may look softer. Codec buffers, animation, native plugins, and other allocations are not all part of Flutter's image cache: 64 MiB is not a total-memory cap or an OOM guarantee. Small-scale testing does not certify all models or content.

## Version Codes and Signing Continuity

Mobile keeps `base build * 10 + ABI ID`. TV uses `(200000 + base build) * 10 + ABI ID`; the IDs are universal `0`, ARM32 `1`, ARM64 `2`, and x86_64 `3`. Gradle adds the offset for both local and CI builds. **Do not pass an old Alpha-style large build number.**

The last delivered Alpha, `alpha.19.2` at `a4ba52463380`, had a maximum versionCode of `1000193`. Mainline base build `242` produces TV codes `2002420` through `2002423`, all higher than those test APKs. Increase the build in `release.json` for future versions. Rebuilding the same version does not increment its code; changing to a lower ABI ID at the same version may be rejected, so keep the installed ABI where possible.

The `pubspec.yaml` version seen by source scripts remains unchanged. About additionally displays TV build and revision information. Both flavors retain the published signing identity; verification requires this public certificate SHA-256:

```text
3d990535d15d2ecb8f65f599db7725e1d83e10a5e801ddcdae262cc78983dc10
```

Signing keys are not distributed with the source. Future certificate rotation requires an explicit upgrade-compatibility plan, not simply weakening verification.

## Builds and Release Gates

Manually run the build workflow on `main` with Android enabled to build both flavors. There is no longer an `android_flavor` selector. Android-only example:

```powershell
gh workflow run build.yml --ref main `
  -f build_android=true `
  -f build_windows=false -f build_macos=false -f build_ios=false `
  -f build_linux_x64=false -f build_linux_arm64=false
```

Manual Android builds run quality checks first. Full builds and tag releases reuse those checks upstream. The Android matrix contains `mobile` and `tv`; other enabled platforms still build normally. PR smoke builds compile both Android Debug flavors and Windows Debug. In addition to the full ordinary test suite, quality checks run the actual TV flavor's navigation, input, low-memory, and update regressions.

Each flavor verifies all four signed release APKs: package, base version, versionCode, MainActivity namespace, TV launcher/banner/landscape/touchscreen declarations, native ABIs, bundled version, and signing certificate. A failed APK prevents uploads for that flavor.

Actions artifacts are `apk-<ABI>`, `tv-apk-<ABI>`, `android-mobile-manifest`, and `android-tv-manifest`, retained for 7 days and requiring GitHub login. The manifests record commit, package, version codes, signing fingerprints, file sizes, and SHA-256 hashes. Tag publication downloads both sets, verifies the **complete eight-APK set, current release provenance, signing identity, and hashes**, then creates the Release. Both manifests are also published as release assets. Manual builds never create a Release.

For local builds, use the pinned Flutter and signing configuration in the [build guide](../development/build.en.md):

```powershell
flutter pub get --enforce-lockfile
flutter build apk --release --flavor mobile
flutter build apk --release --flavor tv `
  --dart-define=TV_BUILD=local --dart-define=TV_REVISION=local
```

Outputs are in `build/app/outputs/apk/mobile/release/` and `build/app/outputs/apk/tv/release/`. Always specify the Android flavor explicitly. A global `default-flavor` is deliberately not set, preserving the existing iOS/macOS Xcode schemes. Local commands do not replace complete CI signature and provenance verification.

## Continuing Device Regression Checks

Check mobile coexistence; 720p/1080p/4K, large text, both themes and reduced motion; focus return in search, lists, chapters, settings and dialogs; no background page turns from menus; no held input after resume; failed-save exit protection; device-local low-memory preferences across import/sync; and actual memory behavior with strips, animation, large pages and extended reading. Reports need version/revision, device and Android version, system ABI, remote type, and reproduction steps, not private comics, credentials, or full backups.

The [historical experiment record](../experiments/android_tv.zh.md) retains the old branch-isolation rules and acceptance checklist. It is no longer the current build guide.
