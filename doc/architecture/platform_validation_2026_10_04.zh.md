# 本机平台构建验证（2026-10-04）

Windows 验证基点 `02c1f5accd422ee4465624d953b425950f78a68d`（Android 增量构建基点见下节），构建包含当时工作区中用户未提交的阅读器、设置和翻译修改，并非干净 HEAD 或发布验收。未跟踪测试文件不参与 release 编译。构建期间未修改业务代码。

已跟踪源码范围（lib/assets/test/pubspec/windows/android）相对 HEAD 的二进制 diff SHA-256：`018d5f3e85501ccc6fc306db1275c6a51d1a653d185729f3083f39a57d0636e4`。此指纹用于识别工作区差异，不是完整源码归档或可复现构建证明。

## 环境

- Windows 11 26H2，10.0.26300.9457；Visual Studio Enterprise 2026 18.10.3，Windows SDK 10.0.26100.0。
- Flutter stable 3.41.6（framework db50e20168，engine 425cfb54d0）、Dart 3.11.4。仓库声明 Flutter 3.41.4；本轮不代表声明版本的 CI 结果。
- Android SDK 36.1.0、platform 36.1，Java 21.0.10；项目 Java 编译目标 17、NDK 28.0.13004108。许可证已接受。
- 可用设备为 Windows 与 Edge，没有连接 Android 实机。Chrome 缺失不影响本轮两个原生构建目标。

## Windows

`flutter build windows --release --no-pub` 返回 0，日志报告 655.3 秒。仅验证 release 应用编译；未运行打包脚本或安装器。

| 产物 | 字节 | SHA-256 |
|---|---:|---|
| build/windows/x64/runner/Release/VeneraNext.exe | 174080 | AE10FA8B5B189DCA643336358E83100A16B31E32963C9052FE979975DF54FC95 |
| build/windows/x64/runner/Release/data/app.so | 14943152 | 5313ED4C7B62294E0B11F90B3A09968C55EA6DFB7463C71922C8653656FC3640 |

exe 需要 Release 目录内的 DLL 和 data；表中两个文件不能视为完整可分发包。编译存在 flutter_inappwebview_windows 的 CMake CMP0175 警告、QuickJS/zip_flutter 的类型转换等警告，以及 zip_flutter 的未识别链接选项 `/Wl,--build-id=none`，没有因此宣称原生编译零警告。

原生测试使用 Visual Studio 自带 CMake：

```powershell
cmake -S windows/tests -B build/windows/optimization_startup_tests -A x64
cmake --build build/windows/optimization_startup_tests --config Release
ctest --test-dir build/windows/optimization_startup_tests -C Release --output-on-failure
```

配置、编译及测试均返回 0；CTest 1/1 通过，0.30 秒。覆盖新窗口初始化、失败返回、已有窗口恢复及最大化保持、启动日志错误码/轮转/锁定文件等。测试不加载 Dart 入口或应用数据。

完整应用/安装器 smoke 由 `.github/scripts/test_windows_startup.ps1` 要求一次性 GitHub Actions Windows runner。本机日常用户环境未执行，也未绕过检查。

## Android

命令 `flutter build apk --release --no-pub --split-per-abi` 首轮返回 0，2057.2 秒；该轮期间有缓存源码修改，因此不作为缓存修复后的证据。随后在 `83c6da130f21c3bdd10f8cbc142282543e7295ad` 加用户原有修改上增量重建，返回 0，143.8 秒。下表仅记录增量构建最终产物，位于 `build/app/outputs/apk/release/`；构建期间未再改动生产源码。

增量构建源码范围（lib/assets/test/pubspec/windows/android）的 HEAD 差异 SHA-256：`018d5f3e85501ccc6fc306db1275c6a51d1a653d185729f3083f39a57d0636e4`。用户修改与 Windows 验证时相同，但 HEAD 已包含缓存修复。Flutter、Java 与 CI 声明版本差异仍适用；本机 Java 21.0.10，CI 使用 Java 17。仓库 Rust 固定 1.85.1，本机同时安装 stable 1.98.0；原生插件日志/进程显示有 `--toolchain stable` 目标准备步骤，不把仓库声明等同于全部插件编译版本。

| APK | 字节 | SHA-256 |
|---|---:|---|
| VeneraNext-1.17.0-android-arm64-v8a.apk | 22440203 | E2CE927BE0DE55A66215BB9ED867DDBF37BA25F2DEAD31D78FF47CD648BF00CB |
| VeneraNext-1.17.0-android-armeabi-v7a.apk | 21229551 | 8514E1CA967B41B945407B1C583403348C8126F022C0AA17663691E788B8AE4A |
| VeneraNext-1.17.0-android-x86_64.apk | 22962511 | 8E3FC29F10AC694039ED6AC670FA5D440464168D7321179016E42389C023A5E5 |
| VeneraNext-1.17.0-android.apk | 59558669 | B36F6797BF46FD49F908F35B33463E02639C4F65A19C6728DBD5B9C0F8E0A157 |

四个 APK 均使用 Android build-tools 36.1.0 的 `apksigner verify --verbose` 返回 0，v2 签名通过、单个签名者；没有输出证书身份或读取密钥配置。签名有效不等于已经与发布证书比对。`aapt dump badging` 均返回 0：包名 `com.github.cyrilpeng.veneranext`、版本 `1.17.0`、minSdk 24、targetSdk/compileSdk 36；armeabi-v7a/arm64-v8a/x86_64/universal 的 versionCode 分别为 2281/2282/2283/2280。

ZIP 内容检查确认分架构包仅含对应 ABI、universal 包含三种 ABI；每种 ABI 均包含 libapp、libflutter、libsqlite3、libqjs、librhttp、libflutter-saf 和 libsuper_native_extensions 原生库。文件存在不是原生功能运行证明。

首轮依赖编译存在 Java source/target 8 过时警告；本轮未改依赖编译选项来掩盖警告。构建日志中的依赖解析属于原生插件构建工具，工作区 pubspec.lock 无修改。没有 Android 设备，未安装 APK、未运行实机行为或性能测试。

本地证据：`output/android-release-cache-validation.log`、`output/android-release-artifacts.json`，以及 `output/VeneraNext-1.17.0-android*-signature.log` / `*-badging.log`。首轮诊断保留在 `output/android-release-validation.log` 和 `output/android-gradle-threads.log`。APK、密钥和原始日志不随本提交发布。

## 剩余验收与证据

- Windows 安装/完整启动与 CLI、Android SAF/音量/方向和前后台行为仍待对应环境验证。
- Linux、macOS、iOS 本轮未构建；五平台结果不能标为通过。
- 六场景固定设备性能基线/复测未执行；构建耗时不是应用性能指标。
- 本轮未推送或触发远端 CI。后续应在声明 Flutter 版本和隔离 runner 上补验。
- 本地原始日志位于 output/platform-{doctor,devices}.log、output/windows-release-validation.log、output/android-release-validation.log、output/windows-native-{configure,build,test}.log。日志保留本机，不随提交发布；本文件记录结果摘要及产物指纹。

后续 CI 门禁已补入 5 个真实无头 exe 错误路径检查（参数校验、未配置同步/追更），本机仅验证输出判定器；实际 CI 结果仍待收集。
