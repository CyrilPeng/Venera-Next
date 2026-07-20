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

**重要声明**：本仓库只维护 VeneraNext 漫画阅读器本体，不提供、内置、托管或推荐任何漫画源，也不处理任何源站内容。网络阅读能力兼容 JavaScript 扩展 API，并依赖用户自行合法配置的漫画源扩展；搜索结果、章节加载、图片可用性和内容版权均取决于对应源站与扩展实现。请不要在本仓库提交与漫画源、源站内容、具体作品可用性或版权相关的问题。

---

## 功能亮点

### 本分支特色

- **瀑布流跨章节阅读**：默认阅读模式。阅读到章节末尾附近时会自动预加载下一章，适合长篇连载和整卷连续阅读。
- **纵向模式拆分双页**：纵向连续和瀑布流模式可将横向双页图拆成上下排列，并支持交换拆分顺序，适合右翻、左翻方向不同的作品。
- **章节排序偏好**：漫画详情页的正序、倒序切换使用分段控件，状态会作为全局偏好保存，减少每次打开都要重新调整的操作。
- **本地漫画和远端目录并重**：本地漫画支持目录、CBZ/ZIP/7Z 导入；WebDAV 漫画库支持普通图片目录，以及 VeneraNext 导出 CBZ 的解压目录在线阅读。
- **源与阅读器分离**：本仓库只维护阅读器本体。网络漫画源由用户自行合法配置，仓库不会内置、推荐或维护具体源站。

### 漫画来源

- **本地漫画**：适合阅读设备上已有的图片目录或压缩包。支持单本目录、批量目录、CBZ、ZIP、7Z、CB7 导入。
- **网络漫画源**：兼容 JavaScript 扩展 API。添加扩展后，可使用搜索、分类、排行、探索页、收藏和下载等能力。
- **WebDAV 漫画库**：把 WebDAV 服务端作为在线漫画库读取，适合 NAS、Nextcloud、坚果云等场景；支持普通图片目录和 CBZ 解压后的增强目录，不在线预览压缩包本身。
- **下载内容**：网络源章节可以下载到本地漫画库，适合移动端离线阅读或网络不稳定时使用。

### 管理与同步

- 收藏管理、阅读历史、图片收藏、下载队列和追更。
- 本地漫画导入、导出、扫描恢复、章节删除和存储路径迁移。
- WebDAV 数据同步：同步设置、收藏、历史、Cookie、漫画源文件等应用数据。
- WebDAV 漫画归档：把本地漫画导出为 CBZ 后上传、恢复或删除，适合备份和迁移。
- WebDAV 漫画库：直接读取远端目录图片，适合在线阅读，不要求先下载完整漫画。

### 跨平台

- Android、iOS、Windows、Linux、macOS
- Releases 提供多平台构建产物
- Windows 已正式接入 winget，可使用包管理器安装和更新

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

推荐通过 winget 安装，后续可以直接使用同一包 ID 升级：

```powershell
winget install --id CyrilPeng.VeneraNext --exact
winget upgrade --id CyrilPeng.VeneraNext --exact
```

也可以从 Releases 下载 `VeneraNext-xxx-windows-installer.exe` 安装包或 zip 便携版。便携版不受 winget 管理，需要手动下载新版本并覆盖更新。新版本发布后，winget 公共源可能需要等待 Microsoft 审核；可先执行 `winget source update` 刷新本地索引。

Windows 安装器、便携包和 winget manifest 维护说明见 [doc/distribution/windows.zh.md](doc/distribution/windows.zh.md)。

### Linux

从 Releases 下载 `venera-next_xxx_amd64.deb` 或 AppImage。

### macOS

从 Releases 下载 `VeneraNext-xxx.dmg`。

---

## 快速上手

1. 从 [Releases](https://github.com/CyrilPeng/venera-next/releases) 下载适合当前平台的安装包。
2. 先选择漫画来源：
   - 已经有图片目录或 CBZ 文件：进入 `本地` -> `导入`。
   - 使用网络漫画源：进入漫画源管理，添加兼容 JavaScript 扩展 API 的扩展。
   - 使用 NAS/WebDAV 在线阅读：进入 `设置` -> `应用` -> `WebDAV Comic Library` 配置远端目录。
3. 在 `设置` -> `阅读器` 中选择阅读模式。长篇作品推荐瀑布流；希望传统翻页时选择画廊；希望只在当前章节内纵向阅读时选择连续模式。
4. 打开漫画详情页，检查章节顺序。如果章节列表方向不符合习惯，用正序/倒序切换调整，应用会记住这个偏好。
5. 如果作品包含横向双页图，在纵向连续或瀑布流模式中开启拆分双页；顺序不对时再开启交换拆分顺序。
6. 常看的作品可以加入收藏或追更；网络不稳定或移动端使用时，可先下载章节再阅读。
7. 多设备使用时再配置 WebDAV。注意：应用数据同步、CBZ 归档备份、WebDAV 在线漫画库是三套独立配置。

---

## 使用说明

### 阅读器模式

- **瀑布流（从上到下）**：本分支重点优化的默认模式。适合长篇连续阅读，会在接近章节末尾时加载后续章节，阅读体验接近整本连续卷。
- **画廊模式**：传统分页阅读。左右、上下方向可选，适合想严格按页翻看的场景。
- **连续模式**：在当前章节内连续滚动，不自动跨章节。适合希望保留章节边界，但又想纵向浏览的场景。
- **图片预加载**：可在阅读器设置中调整预加载数量。网络较慢时适当增加；移动端内存较小或容易发热时不建议设置过高。
- **进度记录**：阅读器会记录章节、页码和章节组。瀑布流跨章节阅读时也会更新到当前实际章节。
- **拆分双页**：只作用于纵向连续和瀑布流模式。它会把横图处理成上下排列的竖向图，不改变章节页数；如果拆分后阅读顺序不对，可开启交换顺序。

### 本地漫画

- 本地漫画适合阅读设备上已有的作品，也适合管理从网络源下载的章节。
- 支持两类目录结构：

```text
漫画目录/
├── cover.jpg
├── 001.jpg
└── 002.jpg
```

```text
漫画目录/
├── cover.jpg
├── 第01卷/
│   ├── 001.jpg
│   └── 002.jpg
└── 第02卷/
    ├── 001.jpg
    └── 002.jpg
```

- `cover.jpg` 可选；如果没有封面，应用会尽量使用第一张图片作为封面。
- 页面顺序按文件名排序。推荐使用 `001.jpg`、`002.jpg`、`003.jpg` 这类命名，避免 `1.jpg`、`10.jpg`、`2.jpg` 在不同工具中排序不一致。
- 批量导入目录时，应选择“包含多本漫画目录”的父目录，而不是某一本漫画内部的章节目录。

### CBZ/ZIP/7Z 导入导出

- CBZ/ZIP/7Z/CB7 适合作为导入、导出、备份、迁移和分发格式。
- 压缩包可以直接包含图片，也可以包含一个顶层目录；如果顶层目录下是章节目录，应用会按章节导入。
- 支持这种打包风格：

```text
猫之眼[北条司].cbz
└── 猫之眼[北条司]/
    ├── cover.jpg
    ├── 第01卷/
    │   ├── 001.jpg
    │   └── 002.jpg
    └── 第02卷/
        ├── 001.jpg
        └── 002.jpg
```

- 如果压缩包很大，导入需要先解压和复制到本地漫画库，因此更适合“下载后阅读”或“分发迁移”，不适合作为在线流式阅读格式。
- 已导入的本地漫画可以导出为 CBZ，便于备份或在设备之间移动。

### 网络漫画源

- 漫画源通过兼容 JavaScript 扩展 API 的扩展提供。添加扩展后，应用才能搜索、浏览和读取对应站点内容。
- 本仓库不提供源列表，也不处理源站内容问题。搜索不到、章节为空、图片加载失败，通常需要检查对应扩展、源站状态、网络环境或代理设置。
- 不同漫画源提供的能力不同。分类、排行、评论、评分、归档下载、登录等入口会按扩展实际支持情况显示。
- 如果某个源要求登录、Cookie 或站点验证，应在对应源的设置或登录入口中处理。

### WebDAV 漫画库

- WebDAV 漫画库是一种在线阅读渠道，适合把 NAS、Nextcloud、ownCloud、坚果云等服务端目录当作漫画库。
- 配置入口：`设置` -> `应用` -> `WebDAV Comic Library`。
- 普通目录不要求配置文件。漫画名默认取文件夹名，章节取子目录；没有 `cover.*` 时会依次尝试根目录首图、首个可读章节的封面或首图。
- 普通目录示例：

```text
/venera_comics/
├── 猫之眼[北条司]/
│   ├── cover.jpg
│   ├── 第01卷/
│   │   ├── 001.jpg
│   │   └── 002.jpg
│   └── 第02卷/
│       ├── 001.jpg
│       └── 002.jpg
└── 另一部漫画/
    ├── cover.jpg
    └── Chapter 01/
        ├── 001.webp
        └── 002.webp
```

- VeneraNext 导出的单本 CBZ 解压后也可以直接放入漫画库。目录中的 `metadata.json` 会提供标题、作者、标签和章节页码范围，根目录图片仍按需加载：

```text
/venera_comics/猫之眼/
├── metadata.json
├── ComicInfo.xml
├── cover.jpg
├── 0001.jpg
├── 0002.jpg
└── ...
```

- `metadata.json` 缺失、损坏或章节范围不合法时，应用会忽略元数据并回退普通目录推断，不会隐藏整本漫画。
- 远端 CBZ/ZIP/7Z/CB7 文件仍会被视为归档文件，不会在线预览；需要在线阅读时，应先在服务端解压为上述目录。
- 首次打开远端目录时需要列目录，WebDAV 服务端较慢时会有等待；图片阅读时按需加载，并走应用缓存。
- 完整目录规则和元数据模板见 [本地漫画导入、CBZ 与 WebDAV 漫画库](doc/user/import_comic.zh.md)。

### WebDAV 数据同步和漫画归档

VeneraNext 有三类 WebDAV 能力，配置入口和用途不同：

| 能力 | 设置入口 | 用途 | 是否用于在线阅读 |
|---|---|---|---|
| WebDAV 数据同步 | `设置` -> `应用` -> `Data Sync` | 同步设置、收藏、历史、Cookie、漫画源文件等应用数据 | 否 |
| WebDAV 漫画归档 | `设置` -> `应用` -> `Comic Archive Backup` | 将本地漫画导出为 CBZ 上传，或从远端 CBZ 下载恢复 | 否 |
| WebDAV 漫画库 | `设置` -> `应用` -> `WebDAV Comic Library` | 读取远端目录图片结构并在线阅读 | 是 |

- 数据同步适合多设备共享应用状态，但不会同步本地漫画图片本体。
- 漫画归档适合换设备、备份和恢复本地漫画。它会上传或下载 CBZ 文件，恢复后漫画会进入本地漫画库。
- WebDAV 漫画库适合在线读取远端图片目录，不要求先把整本漫画下载到本地。

### 收藏、追更和下载

- 收藏用于长期管理作品，阅读历史用于快速回到最近看过的位置。
- 追更会检查已追更漫画的更新情况，适合连载作品；追更结果依赖对应网络源或收藏数据。
- 下载管理用于离线阅读，网络状况不稳定或移动端使用时尤其有用。下载后的章节会作为本地漫画内容读取。
- 图片收藏和图库浏览适合单独保存、查看喜欢的图片页。
- 本地收藏和网络收藏是不同概念：本地收藏由应用维护，网络收藏依赖对应源站账号和扩展能力。

---

## FAQ

### 1. VeneraNext 自带漫画源吗？

不自带。VeneraNext 只提供阅读器、兼容 JavaScript 扩展 API 的漫画源运行环境和本地管理能力，网络内容需要用户自行合法配置漫画源扩展。

### 2. 可以在本仓库反馈漫画源问题吗？

不建议，也不会在本仓库处理。与漫画源、源站内容、具体作品可用性、章节缺失、图片加载失败或版权相关的问题，请不要提交到本仓库。

本仓库只维护阅读器本体。如果问题能在不涉及具体源站和具体内容的情况下复现，例如阅读器崩溃、界面异常、设置不生效、构建失败，可以提交 issue。

### 3. 为什么搜索不到漫画或图片加载失败？

通常与漫画源扩展、源站状态、网络环境或代理设置有关。请先检查对应漫画源是否仍可用，以及当前设备是否能正常访问对应站点。

### 4. 瀑布流、画廊、连续模式怎么选？

长篇连续阅读推荐瀑布流；习惯传统翻页阅读可以使用画廊；只想在当前章节内纵向阅读、并保留明确章节边界时，可以使用连续模式。

### 5. Windows 能不能一键更新？

可以。推荐使用 winget 安装和升级：

```powershell
winget install --id CyrilPeng.VeneraNext --exact
winget upgrade --id CyrilPeng.VeneraNext --exact
```

如果刚发布的新版本尚未显示，请先运行 `winget source update`。winget 版本更新需要经过 Microsoft 审核，通常会晚于 GitHub Release；zip 便携版无法通过 winget 自动升级。

---

## 开发者入口

README 面向安装和使用。构建、测试、仓库结构与发布维护说明统一放在开发文档中：

- [构建与开发](doc/development/build.zh.md) / [Build and Development](doc/development/build.en.md)
- [项目结构约定](doc/architecture/project_structure.zh.md)
- [Windows 分发维护](doc/distribution/windows.zh.md)
- [完整文档索引](doc/README.md)

---

## 星标历史

<a href="https://www.star-history.com/?repos=CyrilPeng%2Fvenera-next&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=CyrilPeng/venera-next&type=date&theme=dark&legend=top-left&sealed_token=2JdfPV5RItrAVJNxNXhSHVr6mVbj9H_y_YMHJio2smj8uoRHGQKgrtY9k0PmbxUf6q0P-dR90ZWZSKlDDaygMd90LT7F0xI-2Bbtiq5muew1iXUSEFJzfouyqu70BiWT-hUeD9BKbFsdVr1knEJDWBqAArkJYIJcJCOYLZ5rUdpFdQ2aBIhT8wTQnOED" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=CyrilPeng/venera-next&type=date&legend=top-left&sealed_token=2JdfPV5RItrAVJNxNXhSHVr6mVbj9H_y_YMHJio2smj8uoRHGQKgrtY9k0PmbxUf6q0P-dR90ZWZSKlDDaygMd90LT7F0xI-2Bbtiq5muew1iXUSEFJzfouyqu70BiWT-hUeD9BKbFsdVr1knEJDWBqAArkJYIJcJCOYLZ5rUdpFdQ2aBIhT8wTQnOED" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=CyrilPeng/venera-next&type=date&legend=top-left&sealed_token=2JdfPV5RItrAVJNxNXhSHVr6mVbj9H_y_YMHJio2smj8uoRHGQKgrtY9k0PmbxUf6q0P-dR90ZWZSKlDDaygMd90LT7F0xI-2Bbtiq5muew1iXUSEFJzfouyqu70BiWT-hUeD9BKbFsdVr1knEJDWBqAArkJYIJcJCOYLZ5rUdpFdQ2aBIhT8wTQnOED" />
 </picture>
</a>

---

## 许可

本项目遵循 GPL-3.0 许可。
