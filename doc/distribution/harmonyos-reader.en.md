# HarmonyOS Full Reader Experiment

This unsigned HAP builds the **existing full Flutter/Dart application**, not the previous blank app or diagnostic probe. It retains the original sources, reader, favorites, history, downloads and WebDAV implementation. Full-source integration does **not** mean every platform feature works or that device acceptance is complete. Supported platforms and stable Releases remain unchanged.

Following the volunteer's preference in #77, this stage provides the application for ordinary use. **No repeated four-step probe test, diagnostic report or private attachment is requested.** Report actual problems in #77 if they arise.

## Download and Install

1. Use the successful Actions run linked by the maintainer in #77 and download `harmonyos-reader-experiment-RUN_ID`. Do not install probes from `harmonyos-unsigned-lab-haps` expecting a reader. Artifacts require a GitHub login and expire after 14 days; request a fresh build rather than using an unknown re-signed download.
2. The archive contains `venera-next-1.18.2-harmony.1-arm64-unsigned.hap`, `full-app-manifest.json`, `SHA256SUMS`, and both guides. Verify the original HAP digest. Signing changes the bytes, so that digest cannot validate a re-signed package.
3. Users with Xiaobai Debug Assistant on HarmonyOS can reuse their existing environment. Import the unsigned HAP and personally complete account login, device authorization, signing and installation. The maintainer does not collect accounts, device identifiers, authorization, certificates or private keys, bundle signing keys, bypass security controls, or promise automatic certificate renewal.
4. The app label is `VeneraNext (HarmonyOS Lab)`, the separate bundle name is `com.github.cyrilpeng.veneranext.harmony`, and the version is `1.18.2-harmony.1+1`. It does not overwrite the diagnostic probe or share the Android app's sandbox in an Android compatibility environment. Import desired data explicitly.

The build declares ARM64 `phone` and `tablet` targets, with minimum/target SDK `26.0.0`. One earlier MatePad / HarmonyOS 7.0 volunteer reported successful **core probe** use. This does not establish full-app acceptance on that device or compatibility with other systems. Do not repeatedly authorize or weaken security settings if an unsupported device cannot install it.

## Ordinary Use

- Add/install comic sources through the existing source page, then use search, favorites, reading, downloads and history. Embedded browsing uses a pinned CPF Flutter OHOS WebView implementation; individual source login, challenges and compatibility may still fail.
- Prefer local CBZ / ZIP / EPUB imports or selected image files. Native APIs copy a picker-granted URI into the app sandbox before the original import workflow consumes it; a URI is not treated as an already authorized filesystem path.
- App settings retain `data.venera` backup import/export and WebDAV sync. Keep independent original backups and comic files before migration. Configuration import does not automatically move external libraries or restore Android SAF / Windows paths.
- Exports use the system save picker. Success is returned only after the native copy and file closing finish. Confirm the saved file yourself before removing old copies; do not use the experiment as your only data backup.
- Existing reading-session and asynchronous shutdown ownership remains in place. Downloads run only while the application lifecycle permits; HarmonyOS background restrictions are not bypassed.

## Explicit Initial Limitations

- Persistent external directories, custom storage locations, system sharing, biometric app lock, and Android volume keys / SAF / foreground services are not integrated. Directory operations explain the archive-import alternative; save files and share through Files, or copy text. Unimplemented actions do not report success.
- **PDF import is unavailable** because PDFium has no OHOS build. Existing Dart PDF export remains. The build does not substitute Android/Linux PDFium binaries. PNG, ZIP and 7Z use real OHOS cross-compiles of the application's locked sources.
- Imported app-lock settings display an explicit warning and let the user continue without app authentication or exit; they do not silently pass biometric authentication. Turn off the imported app-lock setting if desired.
- WebView proxy override, platform image codecs, full-app network/TLS/login, large-file migration, device frame times/power use, full-app upgrades and certificate renewal remain unverified. Do not count #91 power savings as measured.
- Analysis, dependency resolution, host regressions, ARM64 ELF/FFI, bundle/version/API, library and asset checks confirm only those build properties. They are not user acceptance, do not close #77, and do not publish this HAP to a stable channel.

If a real issue occurs, describe the feature and error in #77. Screenshots are optional and should be redacted. No configuration, cookies, source credentials, raw device logs or signing material are required.

[中文指南](harmonyos-reader.zh.md)
