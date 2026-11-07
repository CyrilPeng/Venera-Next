# HarmonyOS Beta Installation and Upgrades

The HarmonyOS beta shares the complete mainline Flutter/Dart reader with other platforms and uses an independent HarmonyOS SDK to produce an unsigned HAP alongside mainline releases. It retains the existing sources, reader, favorites, history, downloads and WebDAV implementation. **Distribution alongside a release does not imply complete platform support or device acceptance.**

This stage provides the application for ordinary use. **No repeated probe test or private attachment is requested.** Report actual problems in later versions through new issues if they arise.

## Download and Install

1. Choose a version providing a HarmonyOS package on [GitHub Releases](https://github.com/CyrilPeng/Venera-Next/releases), and download `VeneraNext-VERSION-harmonyos-arm64-unsigned.hap`, not an APK or diagnostic probe. Historical releases without a HAP do not apply; development Actions artifacts are not published releases.
2. The same release provides `harmonyos-manifest.json`, `harmonyos-SHA256SUMS`, `harmonyos-install.zh.md` and `harmonyos-install.en.md`. Verify the original HAP digest before signing. Signing changes the bytes, so that digest cannot validate a re-signed package. Do not use unknown re-signed downloads.
3. Users with Xiaobai Debug Assistant on HarmonyOS can reuse their existing environment. Import the unsigned HAP and personally complete account login, device authorization, signing and installation. The maintainer does not collect accounts, device identifiers, authorization, certificates or private keys, bundle signing keys, bypass security controls, or promise automatic certificate renewal.
4. The app label is `VeneraNext (HarmonyOS Beta)`. The separate bundle remains `com.github.cyrilpeng.veneranext.harmony`; it does not share the diagnostic probe's or Android compatibility environment's sandbox. Import desired data explicitly.

The in-app version and build number match the containing release and the manifest's `build` object. HarmonyOS displays a three-part numeric native version; RC suffixes remain visible in the app, while increasing build numbers distinguish upgrades.

Before upgrading an earlier reader build, export a separate backup. Keep the same bundle and signing identity/key for an in-place upgrade; do not uninstall or clear data. The same assistant/account does not guarantee the same key. Stop and report a signature mismatch or an uninstall requirement rather than treating reinstallation as an upgrade. App-owned copies need local free space; keep your original comics. Devices sharing WebDAV sync should use compatible data-format versions. Downgrade with the independent pre-upgrade backup, not an older writer over the new favorites database.

The build declares ARM64 `phone` and `tablet` targets, with minimum/target SDK `26.0.0`. One MatePad / HarmonyOS 7.0 volunteer completed the core probe and reported no other problems during ordinary use of the initial full reader beyond missing folder import. This records only that person's usage, not full-feature, other-device/system, real-data migration or certificate-renewal acceptance. Do not repeatedly authorize or weaken security settings if an unsupported device cannot install it.

## Ordinary Use

- Add/install comic sources through the existing source page, then use search, favorites, reading, downloads and history. Embedded browsing uses a pinned CPF Flutter OHOS WebView implementation; individual source login, challenges and compatibility may still fail.
- Single Comic selects an image folder; Multiple Comics selects a parent containing several comic folders, when the system provides folder selection. The granted directory URI is copied into an exclusive temporary sandbox with its original name and chapter structure, then the existing import workflow creates durable library copies. Originals are unchanged; temporary paths never become long-term comic references.
- Folder imports show copying, scanning and saving phases. Copy progress does not confirm registration. The persistent result shows actual imported counts and rejected-folder reasons (up to 100 details); zero imports never count as success and partial successes remain. New imports avoid IDs occupied by migrated favorites without deleting or replacing them.
- Comic collection ZIP imports `Book A/1.png` and `Book B/Chapter 1/1.png` separately and detects one optional outer folder. If the tree could mean multiple books or one book's chapters, it previews the folder names and asks for confirmation; cancelling imports nothing. Ordinary single-book archive rules are unchanged. Unsafe paths, links, conflicts and damaged data are rejected; originals remain unchanged and owned temporary extraction is cleaned up afterward. The historical `1.18.2-harmony.3` package does not include these ID and outer-folder improvements.
- Multiple archive files now directly multi-selects CBZ / ZIP / 7Z / CB7, one comic per archive, without selecting a directory. Missing folder selection, denied access or copy failure explains this alternative. Partial archive failures list the affected files and success/failure counts while retaining successful imports. EPUB retains its separate import entry.
- App settings retain `data.venera` backup import/export and WebDAV sync. Keep independent original backups and comic files before migration. Configuration import does not automatically move external libraries or restore Android SAF / Windows paths.
- Exports use the system save picker. Success is returned only after the native copy and file closing finish. Confirm the saved file yourself before removing old copies; do not use the experiment as your only data backup.
- Existing reading-session and asynchronous shutdown ownership remains in place. Downloads run only while the application lifecycle permits; HarmonyOS background restrictions are not bypassed.
- Update checks only offer releases containing a matching unsigned HAP and manifest. The app opens that release page; signing and installation remain your responsibility, and no APK is automatically downloaded.

## Explicit Experimental Limitations

- Folders support copy import only, not persistent external references or custom storage locations. Actual device folder-selection support still needs ordinary-use feedback; declaring phone/tablet targets is not device acceptance. System sharing, biometric app lock, and Android volume keys / SAF / foreground services remain unimplemented; save files and share through Files, or copy text. Unimplemented actions do not report success.
- **PDF import is unavailable** because PDFium has no OHOS build. Existing Dart PDF export remains. The build does not substitute Android/Linux PDFium binaries. PNG, ZIP and 7Z use real OHOS cross-compiles of the application's locked sources.
- Imported app-lock settings display an explicit warning and let the user continue without app authentication or exit; they do not silently pass biometric authentication. Turn off the imported app-lock setting if desired.
- WebView proxy override, platform image codecs, full-app network/TLS/login, large-file migration, device frame times/power use, full-app upgrades and certificate renewal remain unverified. Do not count #91 power savings as measured.
- Analysis, dependency resolution, host regressions, ARM64 ELF/FFI, bundle/version/API, library and asset checks confirm only those build properties. They are not user acceptance.

If a real issue occurs, describe the version, feature and error. Screenshots are optional and should be redacted. No configuration, cookies, source credentials, raw device logs or signing material are required.

[中文指南](harmonyos-reader.zh.md)
