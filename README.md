<div align="center">

# Venera Next

本项目 fork 自 [venera-app/venera](https://github.com/venera-app/venera)

![Flutter](https://img.shields.io/badge/Flutter-3.41.4-02569B?logo=flutter&logoColor=white)
![Dart](https://img.shields.io/badge/Dart-3.8+-0175C2?logo=dart&logoColor=white)
![Platforms](https://img.shields.io/badge/Platforms-Android%20%7C%20iOS%20%7C%20Windows%20%7C%20Linux%20%7C%20macOS-7C3AED)
![License](https://img.shields.io/badge/License-GPL--3.0-10B981)

</div>

---

## 项目定位

Venera Next 是一个使用 Flutter 构建的跨平台漫画阅读器，支持本地漫画和网络漫画源。

这个 fork 会根据个人使用习惯继续调整阅读、收藏、本地管理、同步和发布体验。维护方向会比较主观，但欢迎参考、fork、提 issue 或 PR。

---

## 功能亮点

### 阅读体验

- 画廊模式：传统分页阅读。
- 连续模式：当前章节内纵向连续阅读。
- 瀑布流模式：跨章节连续阅读，接近末尾时自动加载后续章节。
- 图片预加载：减少翻页和跨章节等待。
- 阅读进度：自动记录章节与页码。

### 漫画来源

- 本地漫画阅读与导入。
- 网络漫画源阅读。
- JavaScript 漫画源扩展。
- 搜索、分类、排行、探索页。

### 管理能力

- 收藏管理、阅读历史、下载管理。
- 图片收藏与图库浏览。
- 本地漫画库管理。
- WebDAV 数据同步。
- WebDAV 本地漫画归档、恢复和删除。

### 跨平台

- Android
- iOS
- Windows
- Linux
- macOS

完整变更记录见 [CHANGELOG.md](CHANGELOG.md)。

---

## 构建项目

### 环境要求

- Flutter `3.41.4`
- Dart `>=3.8.0 <4.0.0`
- JDK `17`，用于 Android 构建
- 对应平台的原生构建环境，例如 Android SDK / NDK、Xcode、Visual Studio、Linux GTK/WebKit 依赖等

推荐使用锁文件获取依赖：

```powershell
flutter pub get --enforce-lockfile
```

不要在不了解影响的情况下删除或重新生成 `pubspec.lock`。

### Android 构建

准备签名文件：

```text
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

```text
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

Android release 构建需要在仓库 Secrets 中配置：

- `ANDROID_KEYSTORE`
- `ANDROID_KEY_PROPERTIES`

其中 `ANDROID_KEYSTORE` 为 keystore 文件的 Base64 内容，`ANDROID_KEY_PROPERTIES` 为 `key.properties` 文本内容。

发布说明从 [CHANGELOG.md](CHANGELOG.md) 读取。

---

## 常见问题

- `Unable to satisfy pubspec.yaml using pubspec.lock`：通常是 Flutter/Dart 环境或包源不匹配，优先确认 Flutter 版本并使用锁文件获取依赖。
- Gradle 下载过慢：可在本地临时切换 Gradle wrapper 镜像，相关改动不建议提交。

---

## 许可

本项目遵循 GPL-3.0 许可。
