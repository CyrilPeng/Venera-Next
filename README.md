<div align="center">
  <img src="assets/readme_logo.png" alt="VeneraNext" width="200" />

  # VeneraNext

  ![Flutter](https://img.shields.io/badge/Flutter-3.41.4-02569B?logo=flutter&logoColor=white)
  ![Dart](https://img.shields.io/badge/Dart-3.8+-0175C2?logo=dart&logoColor=white)
  ![Platforms](https://img.shields.io/badge/Platforms-Android%20%7C%20iOS%20%7C%20Windows%20%7C%20Linux%20%7C%20macOS-7C3AED)
  [![Release](https://img.shields.io/github/v/release/CyrilPeng/venera-next?label=Release&color=10B981)](https://github.com/CyrilPeng/venera-next/releases)
  ![License](https://img.shields.io/badge/License-GPL--3.0-10B981)

</div>

---

## 项目介绍

VeneraNext 是一个基于 Flutter 框架开发的跨平台漫画阅读器，支持本地漫画和网络漫画源，支持 Android、iOS、Windows、Linux、macOS 平台。

本项目是 [venera](https://github.com/venera-app/venera) 的 fork 分支，当前维护仓库为 [CyrilPeng/venera-next](https://github.com/CyrilPeng/venera-next)。本分支会根据个人使用习惯调整阅读、收藏、本地管理、同步和发布体验。维护方向会比较主观，但欢迎提 issue 或 PR。

VeneraNext 的定位是偏日常使用的漫画阅读器：打开漫画后尽量少打断阅读，长篇作品可以用瀑布流跨章节连续阅读，也可以把常看的作品收藏、追更、离线下载，并通过 WebDAV 在多台设备之间同步常用数据。

**重要声明**：本仓库只维护 VeneraNext 漫画阅读器本体，不提供、内置、托管或推荐任何漫画源，也不处理任何源站内容。网络阅读能力依赖用户自行合法配置的 JavaScript 漫画源扩展；搜索结果、章节加载、图片可用性和内容版权均取决于对应源站与扩展实现。请不要在本仓库提交与漫画源、源站内容、具体作品可用性或版权相关的问题。

---

## 功能亮点

### 阅读体验

- **瀑布流模式（本分支特色）**：默认阅读模式，支持跨章节连续阅读，接近末尾时自动加载后续章节
- 画廊模式：传统分页阅读
- 连续模式：当前章节内纵向连续阅读
- 图片预加载：减少翻页和跨章节等待
- 阅读进度：自动记录章节与页码
- 章节排序：漫画详情页可在正序、倒序之间切换，并作为全局偏好保存

### 漫画来源

- 本地漫画阅读与导入
- 网络漫画源阅读（JavaScript 扩展）
- 搜索、分类、排行、探索页
- 本地漫画导入导出工具

### 管理与同步

- 收藏管理、阅读历史、下载管理
- 图片收藏与图库浏览
- 本地漫画库管理
- WebDAV 数据同步
- WebDAV 本地漫画归档、恢复和删除
- 追更功能：自动检查已追更漫画的更新

### 跨平台

- Android、iOS、Windows、Linux、macOS
- Releases 提供多平台构建产物
- Windows 分发流程包含 winget manifest，收录后可使用包管理器安装和更新

完整变更记录见 [CHANGELOG.md](CHANGELOG.md)。

---

## 下载安装

### Android

从 [Releases](https://github.com/CyrilPeng/venera-next/releases) 下载 APK 安装包：

| 文件名 | 说明 | 适用场景 |
|---|---|---|
| `VeneraNext-xxx-android.apk` | 通用版 | 适用于大多数 Android 设备 |
| `VeneraNext-xxx-android-arm64-v8a.apk` | ARM64 版 | 适用 4GB 以上内存的 64 位设备 |
| `VeneraNext-xxx-android-armeabi-v7a.apk` | ARM32 版 | 较老的 32 位设备 |

**推荐**：如果不确定应该下载哪个，选择通用版 `VeneraNext-xxx-android.apk`。

### iOS

从 Releases 下载 ipa 安装包，使用 AltStore 旁加载。

### Windows

从 Releases 下载 `VeneraNext-xxx-windows-installer.exe` 安装包或者 zip 便携版。

如果 `CyrilPeng.VeneraNext` 已被 winget 收录，也可以使用：

```powershell
winget install CyrilPeng.VeneraNext
winget upgrade CyrilPeng.VeneraNext
```

Windows 安装器、便携包和 winget manifest 维护说明见 [doc/windows_distribution.md](doc/windows_distribution.md)。

### Linux

从 Releases 下载 `venera-next_xxx_amd64.deb` 或 AppImage。

### macOS

从 Releases 下载 `VeneraNext-xxx.dmg`。

---

## 快速上手

1. 从 [Releases](https://github.com/CyrilPeng/venera-next/releases) 下载适合当前平台的安装包。
2. 准备漫画来源：可以导入本地漫画，也可以在漫画源管理中添加 JavaScript 漫画源扩展。
3. 通过首页、探索页、分类页或搜索页找到漫画，进入详情页查看简介、章节和评论。
4. 在详情页选择章节开始阅读；章节列表支持正序、倒序切换，适合不同站点和阅读习惯。
5. 在阅读器设置中选择瀑布流、画廊或连续模式。长篇连载优先推荐瀑布流，单章节精读可以使用画廊或连续模式。
6. 常看的作品可以加入收藏或追更；需要离线阅读时，可使用下载管理保存章节。
7. 多设备使用时，在设置中配置 WebDAV，同步应用数据；本地漫画可以使用归档、恢复能力进行迁移。

---

## 使用说明

### 网络漫画源

- 漫画源通过 JavaScript 扩展提供，添加后才能搜索、浏览和读取对应站点内容。
- 如果某个站点搜索不到、章节为空或图片加载失败，通常需要检查对应漫画源是否仍可用。
- 不同漫画源的分类、排行、标签和评论能力可能不同，应用会按扩展提供的能力显示入口。

### 本地漫画

- 本地漫画适合阅读已经保存在设备上的作品，也适合管理从网络源下载的章节。
- 本地漫画相关导入导出能力集中在本地漫画功能域，便于做备份、迁移和归档。
- 如果需要跨设备迁移本地漫画，可结合 WebDAV 本地漫画归档、恢复和删除功能使用。

### 阅读器

- 瀑布流模式会把章节内容连续串起来，适合一口气阅读长篇作品。
- 画廊模式更接近传统翻页阅读，适合单页、双页或横屏场景。
- 连续模式只在当前章节内纵向连续阅读，适合希望保持章节边界的用户。
- 阅读进度会自动记录；下次打开同一漫画时，可以继续从上次位置阅读。

### 收藏、追更和下载

- 收藏用于长期管理作品，阅读历史用于快速回到最近看过的内容。
- 追更会检查已追更漫画的更新情况，适合连载作品。
- 下载管理用于离线阅读，网络状况不稳定或移动端使用时尤其有用。
- 图片收藏和图库浏览适合单独保存、查看喜欢的图片页。

### 同步和备份

- WebDAV 可用于同步应用数据，常见服务包括坚果云、Nextcloud、ownCloud、群晖 Synology 等。
- 应用数据同步和本地漫画归档是两类能力：前者偏设置、收藏、历史等数据，后者偏本地漫画文件迁移。
- 更新或换设备前，建议先确认同步状态，必要时手动导出数据作为额外备份。

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

## FAQ

### 1. VeneraNext 自带漫画源吗？

不自带。VeneraNext 只提供阅读器、漫画源运行环境和本地管理能力，网络内容需要用户自行合法配置漫画源扩展。

### 2. 可以在本仓库反馈漫画源问题吗？

不建议，也不会在本仓库处理。与漫画源、源站内容、具体作品可用性、章节缺失、图片加载失败或版权相关的问题，请不要提交到本仓库。

本仓库只维护阅读器本体。如果问题能在不涉及具体源站和具体内容的情况下复现，例如阅读器崩溃、界面异常、设置不生效、构建失败，可以提交 issue。

### 3. 为什么搜索不到漫画或图片加载失败？

通常与漫画源扩展、源站状态、网络环境或代理设置有关。请先检查对应漫画源是否仍可用，以及当前设备是否能正常访问对应站点。

### 4. 瀑布流、画廊、连续模式怎么选？

长篇连续阅读推荐瀑布流；习惯传统翻页阅读可以使用画廊；只想在当前章节内纵向阅读、并保留明确章节边界时，可以使用连续模式。

### 5. Windows 能不能一键更新？

正式收录到 winget 后，可以使用：

```powershell
winget upgrade CyrilPeng.VeneraNext
```

在此之前，Windows 仍以 Releases 安装包或便携包为主。

### 6. 自己构建的 App 无法联网怎么办？

优先检查 `flutter_rust_bridge` 是否仍为 `2.11.1`。本项目依赖 `rhttp 0.15.1`，不匹配的 `flutter_rust_bridge` 版本可能导致构建出的 App 启动后无法联网。

### 7. `flutter_rust_bridge has not been initialized` 是什么原因？

通常是依赖版本漂移。请恢复 `pubspec.lock`，确认 `flutter_rust_bridge` 版本为 `2.11.1`，再重新获取依赖并构建。

### 8. `Unable to satisfy pubspec.yaml using pubspec.lock` 怎么处理？

通常是 Flutter/Dart 环境或包源不匹配。优先确认 Flutter 版本符合要求，并使用锁文件获取依赖：

```powershell
flutter pub get --enforce-lockfile
```

### 9. Gradle 下载过慢怎么办？

可以在本地临时切换 Gradle wrapper 镜像，但这类环境相关改动不建议提交到仓库。

---

## 星标历史

<div align="center">
  <a href="https://www.star-history.com/?repos=CyrilPeng%2Fvenera-next&type=date&legend=top-left">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=CyrilPeng/venera-next&type=Date&legend=top-left&theme=dark">
      <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=CyrilPeng/venera-next&type=Date&legend=top-left">
      <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=CyrilPeng/venera-next&type=Date&legend=top-left" width="100%">
    </picture>
  </a>
</div>

---

## 许可

本项目遵循 GPL-3.0 许可。
