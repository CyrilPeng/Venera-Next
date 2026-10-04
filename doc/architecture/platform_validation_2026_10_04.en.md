# Local platform build evidence (2026-10-04)

Windows source base: `02c1f5accd422ee4465624d953b425950f78a68d` (Android rebuild base below) plus the user's uncommitted reader, settings and translation edits. This is neither a clean-HEAD build nor release acceptance. Untracked tests are not compiled into release builds. No production code changed during these builds.

SHA-256 of the tracked binary diff against HEAD for lib/assets/test/pubspec/windows/android: `018d5f3e85501ccc6fc306db1275c6a51d1a653d185729f3083f39a57d0636e4`. This identifies the working-tree differences, not a complete source archive or proof of reproducibility.

## Environment

- Windows 11 26H2, 10.0.26300.9457; Visual Studio Enterprise 2026 18.10.3; Windows SDK 10.0.26100.0.
- Flutter stable 3.41.6 (framework db50e20168, engine 425cfb54d0), Dart 3.11.4. The repository declares Flutter 3.41.4, so this is not evidence for the declared CI toolchain.
- Android SDK 36.1.0/platform 36.1, Java 21.0.10; project Java target 17 and NDK 28.0.13004108. Licenses accepted.
- Connected devices: Windows and Edge; no Android device. Missing Chrome does not affect these native build targets.

## Windows

`flutter build windows --release --no-pub` exited 0; reported duration 655.3 seconds. This verifies application compilation, not packaging or installer execution.

| Artifact | Bytes | SHA-256 |
|---|---:|---|
| build/windows/x64/runner/Release/VeneraNext.exe | 174080 | AE10FA8B5B189DCA643336358E83100A16B31E32963C9052FE979975DF54FC95 |
| build/windows/x64/runner/Release/data/app.so | 14943152 | 5313ED4C7B62294E0B11F90B3A09968C55EA6DFB7463C71922C8653656FC3640 |

The executable requires the Release directory's DLLs and data. These two artifacts are not a distribution package. Warnings remain: flutter_inappwebview_windows CMake CMP0175, QuickJS/zip_flutter conversion warnings, and zip_flutter's unrecognized `/Wl,--build-id=none` linker option. Native compilation is not warning-free.

Using Visual Studio's bundled CMake:

```powershell
cmake -S windows/tests -B build/windows/optimization_startup_tests -A x64
cmake --build build/windows/optimization_startup_tests --config Release
ctest --test-dir build/windows/optimization_startup_tests -C Release --output-on-failure
```

Configuration, compilation and tests exited 0. CTest passed 1/1 in 0.30 seconds. Cases cover initialization/failure, existing-window restoration/maximized state, and log error codes/rotation/locked files. Tests load neither the Dart entry point nor application data.

`.github/scripts/test_windows_startup.ps1` requires a disposable GitHub Actions Windows runner for full application/installer smoke. It was not run on this daily-use profile and its guard was not bypassed.

## Android

`flutter build apk --release --no-pub --split-per-abi` first exited 0 in 2057.2 seconds. Cache source changed during that run, so it does not validate the cache fix. An incremental rebuild at `83c6da130f21c3bdd10f8cbc142282543e7295ad` plus the original user edits then exited 0 in 143.8 seconds. Only the final incremental artifacts under `build/app/outputs/apk/release/` are recorded below; production source did not change during that rebuild.

SHA-256 of the tracked HEAD diff for lib/assets/test/pubspec/windows/android: `018d5f3e85501ccc6fc306db1275c6a51d1a653d185729f3083f39a57d0636e4`. User edits match the Windows validation worktree, but HEAD now includes the cache fix. Flutter/Java differences from CI still apply: local Java is 21.0.10, while CI uses Java 17. The repository pins Rust 1.85.1; local stable 1.98.0 is also installed. Native plugin logs/processes included target preparation with `--toolchain stable`, so the repository pin is not evidence of every plugin compiler version.

| APK | Bytes | SHA-256 |
|---|---:|---|
| VeneraNext-1.17.0-android-arm64-v8a.apk | 22440203 | E2CE927BE0DE55A66215BB9ED867DDBF37BA25F2DEAD31D78FF47CD648BF00CB |
| VeneraNext-1.17.0-android-armeabi-v7a.apk | 21229551 | 8514E1CA967B41B945407B1C583403348C8126F022C0AA17663691E788B8AE4A |
| VeneraNext-1.17.0-android-x86_64.apk | 22962511 | 8E3FC29F10AC694039ED6AC670FA5D440464168D7321179016E42389C023A5E5 |
| VeneraNext-1.17.0-android.apk | 59558669 | B36F6797BF46FD49F908F35B33463E02639C4F65A19C6728DBD5B9C0F8E0A157 |

Android build-tools 36.1.0 `apksigner verify --verbose` exited 0 for all four APKs, with v2 signatures and one signer each. No certificate identity was printed or key configuration read. Signature validity is not comparison against the release certificate. `aapt dump badging` also exited 0: package `com.github.cyrilpeng.veneranext`, version `1.17.0`, minSdk 24, targetSdk/compileSdk 36. Version codes for armeabi-v7a/arm64-v8a/x86_64/universal are 2281/2282/2283/2280 respectively.

ZIP checks confirmed one corresponding ABI per split and all three in the universal APK. Every ABI contains libapp, libflutter, libsqlite3, libqjs, librhttp, libflutter-saf and libsuper_native_extensions. Library presence does not prove native runtime behavior.

The first build reported obsolete Java source/target 8 warnings in dependencies; dependency options were not changed to hide these. Dependency resolution in the log belongs to native plugin build tooling; the working-tree pubspec.lock is unchanged. No Android device was available, so installation, device behavior and performance remain untested.

Local evidence: `output/android-release-cache-validation.log`, `output/android-release-artifacts.json`, and `output/VeneraNext-1.17.0-android*-signature.log` / `*-badging.log`. Initial diagnostics remain in `output/android-release-validation.log` and `output/android-gradle-threads.log`. APKs, keys and raw logs are not published with this commit.

## Remaining acceptance and evidence

- Windows installation/full startup and CLI, plus Android SAF/volume/orientation/lifecycle behavior, still require verification.
- Linux, macOS and iOS were not built; five-platform acceptance is incomplete.
- Six-scenario fixed-device performance baselines/remeasurements remain pending. Build duration is not application performance.
- No push or remote CI dispatch was performed. Repeat on the declared Flutter version and isolated runners.
- Local logs: output/platform-{doctor,devices}.log, output/windows-release-validation.log, output/android-release-validation.log and output/windows-native-{configure,build,test}.log. Logs remain local; this document commits result summaries and artifact fingerprints.

The subsequent CI gate adds five real executable CLI error-path checks (arguments and unconfigured sync/subscriptions). Only its output oracle was tested locally; actual CI results remain pending.
