# HarmonyOS Full Reader Experiment

This unsigned HAP builds the **existing full Flutter/Dart application**, not the previous blank app or diagnostic probe. It retains the original sources, reader, favorites, history, downloads and WebDAV implementation. Full-source integration does **not** mean every platform feature works or that device acceptance is complete. Supported platforms and stable Releases remain unchanged.

Following the volunteer's preference in #77, this stage provides the application for ordinary use. **No repeated four-step probe test, diagnostic report or private attachment is requested.** Report actual problems in #77 if they arise.

## Download and Install

1. Use the successful Actions run linked by the maintainer in #77 and download `harmonyos-reader-experiment-RUN_ID`. Do not install probes from `harmonyos-unsigned-lab-haps` expecting a reader. Artifacts require a GitHub login and expire after 14 days; request a fresh build rather than using an unknown re-signed download.
2. The archive contains `venera-next-1.18.2-harmony.3-arm64-unsigned.hap`, `full-app-manifest.json`, `SHA256SUMS`, and both guides. Verify the original HAP digest. Signing changes the bytes, so that digest cannot validate a re-signed package.
3. Users with Xiaobai Debug Assistant on HarmonyOS can reuse their existing environment. Import the unsigned HAP and personally complete account login, device authorization, signing and installation. The maintainer does not collect accounts, device identifiers, authorization, certificates or private keys, bundle signing keys, bypass security controls, or promise automatic certificate renewal.
4. The app label is `VeneraNext (HarmonyOS Lab)`, the separate bundle name is `com.github.cyrilpeng.veneranext.harmony`, and the version is `1.18.2-harmony.3+3`. It does not overwrite the diagnostic probe or share the Android app's sandbox in an Android compatibility environment. Import desired data explicitly.

HarmonyOS displays numeric native `versionName=1.18.2.3` and `versionCode=3`, as required by Flutter OH. This is the same experiment as the in-app Dart version `1.18.2-harmony.3+3`, not a mainline stable release.

Before upgrading an earlier reader build, export a separate backup. Keep the same bundle and signing identity/key for an in-place upgrade; do not uninstall or clear data. The same assistant/account does not guarantee the same key. Stop and report a signature mismatch or an uninstall requirement rather than treating reinstallation as an upgrade. App-owned copies need local free space; keep your original comics.

The build declares ARM64 `phone` and `tablet` targets, with minimum/target SDK `26.0.0`. One MatePad / HarmonyOS 7.0 volunteer completed the core probe and reported no other problems during ordinary use of the initial full reader beyond missing folder import. This records only that person's usage, not full-feature, other-device/system, real-data migration or certificate-renewal acceptance. Do not repeatedly authorize or weaken security settings if an unsupported device cannot install it.

## Ordinary Use

- Add/install comic sources through the existing source page, then use search, favorites, reading, downloads and history. Embedded browsing uses a pinned CPF Flutter OHOS WebView implementation; individual source login, challenges and compatibility may still fail.
- Single Comic selects an image folder; Multiple Comics selects a parent containing several comic folders, when the system provides folder selection. The granted directory URI is copied into an exclusive temporary sandbox with its original name and chapter structure, then the existing import workflow creates durable library copies. Originals are unchanged; temporary paths never become long-term comic references.
- Folder imports show copying, scanning and saving phases. Copy progress comes from the system and does not confirm registration. The persistent result shows the actual imported count and rejected-folder reasons (up to 100 details); zero imports never count as success and partial successes remain. Copy failures retain their operation/error code without requiring private logs. The second build's device folder failure is still under investigation; better feedback is not a confirmed device fix.
- Comic collection ZIP provides an explicit alternative: place `Book A/1.png` and `Book B/Chapter 1/1.png` directly inside `Collection.zip`, with one comic per root child folder. Do not add an extra wrapper folder. Ordinary CBZ/ZIP files with root images still use An archive file. Unsafe paths, links, conflicts and damaged data are rejected; the original ZIP is unchanged and owned temporary extraction is cleaned up after the operation.
- Multiple archive files now directly multi-selects CBZ / ZIP / 7Z / CB7, one comic per archive, without selecting a directory. Missing folder selection, denied access or copy failure explains this alternative. Partial archive failures list the affected files and success/failure counts while retaining successful imports. EPUB retains its separate import entry.
- App settings retain `data.venera` backup import/export and WebDAV sync. Keep independent original backups and comic files before migration. Configuration import does not automatically move external libraries or restore Android SAF / Windows paths.
- Exports use the system save picker. Success is returned only after the native copy and file closing finish. Confirm the saved file yourself before removing old copies; do not use the experiment as your only data backup.
- Existing reading-session and asynchronous shutdown ownership remains in place. Downloads run only while the application lifecycle permits; HarmonyOS background restrictions are not bypassed.
- Updates to this experiment are provided in issue #77. The app does not advertise mainline APK/other-platform releases as HAP updates; manual update checks explain the separate channel.

## Explicit Experimental Limitations

- Folders support copy import only, not persistent external references or custom storage locations. Actual device folder-selection support still needs ordinary-use feedback; declaring phone/tablet targets is not device acceptance. System sharing, biometric app lock, and Android volume keys / SAF / foreground services remain unimplemented; save files and share through Files, or copy text. Unimplemented actions do not report success.
- **PDF import is unavailable** because PDFium has no OHOS build. Existing Dart PDF export remains. The build does not substitute Android/Linux PDFium binaries. PNG, ZIP and 7Z use real OHOS cross-compiles of the application's locked sources.
- Imported app-lock settings display an explicit warning and let the user continue without app authentication or exit; they do not silently pass biometric authentication. Turn off the imported app-lock setting if desired.
- WebView proxy override, platform image codecs, full-app network/TLS/login, large-file migration, device frame times/power use, full-app upgrades and certificate renewal remain unverified. Do not count #91 power savings as measured.
- Analysis, dependency resolution, host regressions, ARM64 ELF/FFI, bundle/version/API, library and asset checks confirm only those build properties. They are not user acceptance, do not close #77, and do not publish this HAP to a stable channel.

If a real issue occurs, describe the feature and error in #77. Screenshots are optional and should be redacted. No configuration, cookies, source credentials, raw device logs or signing material are required.

[中文指南](harmonyos-reader.zh.md)
