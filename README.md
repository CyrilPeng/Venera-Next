<div align="center">
  <img src="assets/readme_logo.png" alt="Venera Next" width="200" />

  # Venera Next

  ![Flutter](https://img.shields.io/badge/Flutter-3.41.4-02569B?logo=flutter&logoColor=white)
  ![Dart](https://img.shields.io/badge/Dart-3.8+-0175C2?logo=dart&logoColor=white)
  ![Platforms](https://img.shields.io/badge/Platforms-Android%20%7C%20iOS%20%7C%20Windows%20%7C%20Linux%20%7C%20macOS-7C3AED)
  ![License](https://img.shields.io/badge/License-GPL--3.0-10B981)

</div>

---

## 项目介绍

Venera Next 是一个基于 Flutter 框架开发的跨平台漫画阅读器，支持本地漫画和网络漫画源，支持 Android、iOS、Windows、Linux、macOS 平台。

本项目是 [venera](https://github.com/venera-app/venera) 的 fork 分支，本分支会根据个人使用习惯调整阅读、收藏、本地管理、同步和发布体验。维护方向会比较主观，但欢迎提 issue 或 PR。

---

## 功能亮点

### 阅读体验

- **瀑布流模式（本分支特色）**：默认阅读模式，跨章节连续阅读，接近末尾时自动加载后续章节，无缝切换到下一章
- 画廊模式：传统分页阅读
- 连续模式：当前章节内纵向连续阅读
- 图片预加载：减少翻页和跨章节等待
- 阅读进度：自动记录章节与页码

### 漫画来源

- 本地漫画阅读与导入
- 网络漫画源阅读（JavaScript 扩展）
- 搜索、分类、排行、探索页

### 管理能力

- 收藏管理、阅读历史、下载管理
- 图片收藏与图库浏览
- 本地漫画库管理
- WebDAV 数据同步
- WebDAV 本地漫画归档、恢复和删除
- 追更功能：自动检查已追更漫画的更新

### 跨平台

- Android
- iOS
- Windows
- Linux
- macOS

完整变更记录见 [CHANGELOG.md](CHANGELOG.md)。

---

## 下载安装

### Android

从 [Releases](https://github.com/CyrilPeng/venera-next/releases) 下载 APK 安装包：

| 文件名 | 说明 | 适用场景 |
|---|---|---|
| `Venera-xxx-android.apk` | 通用版 | 适用于大多数 Android 设备 |
| `Venera-xxx-android-arm64-v8a.apk` | ARM64 版 | 适用 4GB 以上内存的 64 位设备 |
| `Venera-xxx-android-armeabi-v7a.apk` | ARM32 版 | 较老的 32 位设备 |

**推荐**：如果不确定应该下载哪个，选择通用版 `Venera-xxx-android.apk`。

### iOS

从 Releases 下载 ipa 安装包，使用 AltStore 旁加载。

### Windows

从 Releases 下载 `Venera-xxx-windows.exe` 安装包或者 zip 便携版。

### Linux

从 Releases 下载 `venera_xxx_amd64.deb` 或 AppImage。

### macOS

从 Releases 下载 `Venera-xxx-macos.dmg`。

---

## 构建项目

### 环境要求

- Flutter `3.41.4`
- Dart `>=3.8.0 <4.0.0`
- JDK `17`，用于 Android 构建
- Rust 工具链，Android 构建需要安装对应 Android targets
- 对应平台的原生构建环境，例如 Android SDK / NDK、Xcode、Visual Studio、Linux GTK/WebKit 依赖等

### 重要依赖提示

本项目依赖 `rhttp 0.15.1`，需要保持 `flutter_rust_bridge 2.11.1`。

如果 `flutter_rust_bridge` 被升级到不匹配版本，构建出的 App 可能启动后无法联网，并提示：

```
flutter_rust_bridge has not been initialized
```

构建前建议确认锁文件中版本正确：

```powershell
Select-String pubspec.lock -Pattern "flutter_rust_bridge" -Context 0,6
```

应看到：

```
version: "2.11.1"
```

推荐使用锁文件获取依赖：

```powershell
flutter pub get --enforce-lockfile
```

不要在不了解影响的情况下删除或重新生成 `pubspec.lock`。

### Android 构建

准备签名文件：

```
android/keystore.jks
android/key.properties
```

`android/key.properties` 示例：

```properties
storePassword=你的 store 密码
keyPassword=你的 key 密码
keyAlias=你的 key alias
storeFile=../keystore.jks
```

构建 APK：

```powershell
flutter pub get --enforce-lockfile
flutter build apk --release
```

构建产物通常位于：

```
build/app/outputs/apk/release/
```

### 其他平台构建

```bash
flutter pub get --enforce-lockfile
flutter build windows
flutter build linux
flutter build macos
```

iOS 可使用无签名构建：

```bash
flutter pub get --enforce-lockfile
flutter build ios --release --no-codesign
```

---

## GitHub Actions

仓库内包含自动构建与发布工作流。

发布版本号统一维护在 `release.json`：

```json
{
  "version": "1.2.3",
  "build": 123
}
```

准备发布时先更新 `release.json`，再同步并校验相关文件：

```bash
python .github/scripts/release_version.py --write
python .github/scripts/release_version.py --check --tag v1.2.3
```

`pubspec.yaml`、发布 tag 和 `CHANGELOG.md` 版本章节必须与 `release.json` 一致。`alt_store.json` 不是版本源，它会在正式版 GitHub Release 成功后根据发布资产自动更新；RC 预发布不会更新 AltStore 源。

Android release 构建需要在仓库 Secrets 中配置：

- `ANDROID_KEYSTORE`
- `ANDROID_KEY_PROPERTIES`

其中 `ANDROID_KEYSTORE` 为 keystore 文件的 Base64 内容，`ANDROID_KEY_PROPERTIES` 为 `key.properties` 文本内容。

---

## 常见问题

- 自己构建的 App 无法联网：优先检查 `flutter_rust_bridge` 是否仍为 `2.11.1`。
- `flutter_rust_bridge has not been initialized`：通常是依赖版本漂移，请恢复 `pubspec.lock` 后重新构建。
- `Unable to satisfy pubspec.yaml using pubspec.lock`：通常是 Flutter/Dart 环境或包源不匹配，优先确认 Flutter 版本并使用锁文件获取依赖。
- Gradle 下载过慢：可在本地临时切换 Gradle wrapper 镜像，相关改动不建议提交。

---

## 许可

本项目遵循 GPL-3.0 许可。
