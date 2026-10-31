<div align="center">
  <strong>简体中文</strong> | <a href="README.en.md">English</a>
  <br>
  <br>
  <img src="assets/readme_logo.png" alt="VeneraNext" width="200" />

  # VeneraNext

  ![Flutter](https://img.shields.io/badge/Flutter-3.41.4-02569B?logo=flutter&logoColor=white&style=flat-square)
  [![Release](https://img.shields.io/github/v/release/CyrilPeng/venera-next?label=Release&color=10B981&style=flat-square)](https://github.com/CyrilPeng/venera-next/releases/latest)
  ![License](https://img.shields.io/badge/License-GPL--3.0-10B981?style=flat-square)
  <br>
  [![Downloads](https://img.shields.io/github/downloads/CyrilPeng/venera-next/total?style=flat-square&color=2ea44f&logo=github)](https://tooomm.github.io/github-release-stats/?user=CyrilPeng&repo=venera-next)
  [![爱发电](https://img.shields.io/badge/爱发电-支持我-ff69b4?style=flat-square&logo=data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0id2hpdGUiPjxwYXRoIGQ9Ik0xMiAyMS4zNWwtMS40NS0xLjMyQzUuNCAxNS4zNiAyIDEyLjI4IDIgOC41IDIgNS40MiA0LjQyIDMgNy41IDNjMS43NCAwIDMuNDEuODEgNC41IDIuMDlDMTMuMDkgMy44MSAxNC43NiAzIDE2LjUgMyAxOS41OCAzIDIyIDUuNDIgMjIgOC41YzAgMy43OC0zLjQgNi44Ni04LjU1IDExLjU0TDEyIDIxLjM1eiIvPjwvc3ZnPg==)](https://ifdian.net/a/cyril)

  <a href="https://trendshift.io/repositories/140830?utm_source=repository-badge&amp;utm_medium=badge&amp;utm_campaign=badge-repository-140830" target="_blank" rel="noopener noreferrer"><img src="https://trendshift.io/api/badge/repositories/140830" alt="VeneraNext 的 Trendshift 项目徽章" width="250" height="55" /></a>
  <a href="https://trendshift.io/repositories/140830?utm_source=trendshift-badge&amp;utm_medium=badge&amp;utm_campaign=badge-trendshift-140830" target="_blank" rel="noopener noreferrer"><img src="https://trendshift.io/api/badge/trendshift/repositories/140830/daily?language=Dart" alt="VeneraNext 的 Trendshift Dart 每日趋势排名" width="250" height="55" /></a>

</div>

<!-- featured-sponsors:start -->
<!-- featured-sponsors:end -->

---

## 项目介绍

[VeneraNext](https://github.com/CyrilPeng/venera-next) 是基于 [Venera](https://github.com/venera-app/venera) 持续开发的 Flutter 漫画阅读器，支持 **Android、Android TV、iOS、Windows、Linux 和 macOS**。

本分支围绕“少一点打断，多一点阅读”打磨日常体验：瀑布流跨章连读不用退出，长按收藏省去选择收藏夹的步骤，夜间和墨水屏设备各有阅读设置。本地导入、离线下载、阅读统计与多设备同步，让找书、看漫画和追连载更方便。

原项目的 JavaScript 漫画源扩展、本地阅读、搜索与分类、收藏下载，以及按源提供的登录、评论和评分能力继续保留。

**快速入口：** [下载安装](#下载安装) · [使用说明](#使用说明) · [编写漫画源](doc/api/comic_source.zh.md) · [JavaScript API](doc/api/js.zh.md) · [更新日志](CHANGELOG.md)

> [!IMPORTANT]
> 本仓库只维护阅读器本体和扩展运行环境，不提供、内置、托管或推荐漫画源。网络漫画源需由用户自行合法配置，具体内容及源站可用性由相应扩展和服务决定。

<div align="center">
  <a href="https://github.com/CyrilPeng/Venera-Next">
    <img alt="GitHub 主仓库" src="https://img.shields.io/badge/GitHub-主仓库-181717?style=for-the-badge&logo=github&logoColor=white" /></a>
  <a href="https://gitee.com/CyrilPeng/venera-next">
    <img alt="Gitee 国内镜像" src="https://img.shields.io/badge/Gitee-国内镜像-C71D23?style=for-the-badge&logo=gitee&logoColor=white" /></a>
</div>

---

## 软件截图

| 主页：阅读历史、稍后阅读与追更 | 漫画详情页 |
|---|---|
| <a href="https://git-pictures.cyrilworkshop.dpdns.org/veneranext/Home.jpg"><img src="https://git-pictures.cyrilworkshop.dpdns.org/veneranext/Home.jpg" alt="VeneraNext 主页，展示阅读历史、稍后阅读和追更" width="100%" /></a> | <a href="https://git-pictures.cyrilworkshop.dpdns.org/veneranext/Details.jpg"><img src="https://git-pictures.cyrilworkshop.dpdns.org/veneranext/Details.jpg" alt="VeneraNext 漫画详情页，展示阅读操作、作品信息和章节列表" width="100%" /></a> |

---

## 功能亮点

### 一键追更

默认设置下，在漫画详情页**长按“收藏”按钮**，作品就会加入“追更”收藏夹，不用再选文件夹。应用会自动检查更新，在首页集中显示更新数量和作品封面；点封面进入详情，再点“阅读”或“继续阅读”即可开读。

新装应用会自动建好“追更”收藏夹。想更换快捷收藏或追更的目标收藏夹，具体入口见[收藏、稍后阅读与追更](#收藏稍后阅读与追更)。

### 阅读体验

- **瀑布流跨章阅读（非 TV 默认模式）**：看完整章不用退出再选下一章——接近章末自动接上下一章，往上滚也能回到已加载的上一章，进度记录在你实际看到的位置。
- **Android TV 与盒子**：独立电视安装包、横屏启动入口、遥控器方向键导航与可见焦点；默认启用单页低内存阅读，可与手机版共存。
- **纵向拆分双页**：横向双页图在手机上会被压得很小？在纵向连续/瀑布流模式里开启“拆分双页”，把左右两半上下排列着看，顺序不合适还可以交换。
- **夜间调光**：在阅读器内把画面调暗，方便夜间阅读，不改动系统亮度。
- **电子墨水屏刷新**：画廊模式按翻页间隔闪屏，帮助减少残影，间隔和样式可调。
- **更顺手的详情页**：下载、阅读/继续阅读更好找，章节进度与更新提示一目了然，上次选择的章节正序/倒序也会保留。

### 找书、收藏与数据

- **稍后阅读**：把准备以后看的漫画放进单独列表，首页就能找到。
- **本地漫画库**：图片文件夹、CBZ/ZIP/7Z/CB7、PDF、图片型 EPUB 导入即可阅读，支持章节子目录和自然排序，本地漫画还能导出成 CBZ 备份。
- **WebDAV：同步、备份、NAS 阅读**：同步多设备的设置、收藏和阅读进度，备份本地漫画，或在线阅读 NAS 图片目录；三种用途分别配置。
- **阅读统计**：记录你实际看漫画的时间，历史页查看累计时长、读过的作品数和时长排行。
- **收藏画廊与搜索快捷方式**：收藏页可切换封面画廊，常搜的作者/标签可保存为快捷方式，收藏的图片也能按漫画浏览。

### 延续 Venera 的核心能力

- **开放的扩展接口**：用 JavaScript 对接漫画服务，按源提供搜索、聚合搜索、探索页、分类、排行和标签翻译。
- **多种阅读方式**：画廊分页、章节内连续滚动、缩放与多图布局，支持触摸、键盘及移动端音量键操作。
- **收藏与离线阅读**：本地收藏、网络收藏、历史记录、图片收藏和下载队列，下载的章节可离线阅读。
- **按源启用的互动**：登录、Cookie、评论回复、点赞和评分等，由扩展实际支持的能力决定。
- **跨设备使用**：WebDAV 数据同步与导入导出，以及可供脚本调用的[无头命令模式](doc/user/headless.zh.md)。

---

## 下载安装

### Android 手机与平板

从 [最新稳定版](https://github.com/CyrilPeng/venera-next/releases/latest) 下载 APK 安装包：

| 文件名 | 说明 | 适用场景 |
|---|---|---|
| `VeneraNext-xxx-android.apk` | 通用版 | 适用于大多数 Android 设备 |
| `VeneraNext-xxx-android-arm64-v8a.apk` | ARM64 版 | 支持 ARM64 应用的 Android 设备 |
| `VeneraNext-xxx-android-armeabi-v7a.apk` | ARM32 版 | 较老的 32 位设备 |
| `VeneraNext-xxx-android-x86_64.apk` | x86_64 版 | x86_64 设备或模拟器 |

**推荐**：如果不确定应该下载哪个，选择通用版 `VeneraNext-xxx-android.apk`。

### Android TV

TV 版已完成小范围测试并纳入主线，后续构建和版本发布会同时提供手机与 TV 安装包。在 [Releases](https://github.com/CyrilPeng/venera-next/releases) 中选择含 TV 资产的版本：

| 文件名 | 说明 |
|---|---|
| `VeneraNext-xxx-android-tv.apk` | TV 通用版，不确定设备架构时优先选用 |
| `VeneraNext-xxx-android-tv-arm64-v8a.apk` | TV ARM64 版，要求系统支持 ARM64 应用 |
| `VeneraNext-xxx-android-tv-armeabi-v7a.apk` | TV ARM32 版，适合 32 位系统的电视或盒子 |
| `VeneraNext-xxx-android-tv-x86_64.apk` | TV x86_64 版，适合对应设备或模拟器 |

将 APK 传到电视后侧载，启动器名称为 **VeneraNext TV**。TV 版使用独立 `.tv` 包名和数据目录，不会覆盖手机版；已有官方 TV Alpha 测试版可使用新 TV 包覆盖升级，升级前先另存数据备份，无需卸载或清空数据。

> TV 包从本次主线集成后的新构建开始提供；已发布的 `v1.18.1`、`v1.18.2-rc.6` 不包含 TV 包，不会回填旧 Release。应用更新提示会打开相应发布页，请选择文件名含 `android-tv` 的 APK，而不是手机版包。

遥控器操作与默认阅读策略见[TV 遥控器与低内存阅读](#tv-遥控器与低内存阅读)，构建、升级规则和兼容边界见 [Android TV 分发说明](doc/distribution/android_tv.zh.md)。

### iOS

从 [最新稳定版](https://github.com/CyrilPeng/venera-next/releases/latest) 下载 ipa 安装包，使用 AltStore 旁加载。

### Windows

推荐通过 winget 安装，后续可以直接使用同一包 ID 升级：

```powershell
winget install --id CyrilPeng.VeneraNext --exact
winget upgrade --id CyrilPeng.VeneraNext --exact
```

也可以从 [最新稳定版](https://github.com/CyrilPeng/venera-next/releases/latest) 下载 `VeneraNext-xxx-windows-installer.exe` 安装包或 zip 便携版。便携版不受 winget 管理，需要手动下载新版本并覆盖更新。新版本发布后，winget 公共源可能需要等待 Microsoft 审核；可先执行 `winget source update` 刷新本地索引。

Windows 安装器、便携包和 winget manifest 维护说明见 [doc/distribution/windows.zh.md](doc/distribution/windows.zh.md)。

### Linux

从 [最新稳定版](https://github.com/CyrilPeng/venera-next/releases/latest) 下载对应架构的安装包：

| 发行版 / 方式 | 安装或运行 |
|---|---|
| Debian / Ubuntu（DEB） | `sudo apt install ./venera-next_xxx_amd64.deb`（ARM64 选择 `arm64` 包） |
| Fedora 等提供所需依赖的发行版（RPM） | `sudo dnf install ./venera-next-xxx.x86_64.rpm`（ARM64 选择 `aarch64` 包） |
| Arch Linux（x86_64） | `sudo pacman -U ./venera-next-xxx-x86_64.pkg.tar.zst` |
| AppImage（x86_64 / ARM64） | `chmod +x VeneraNext-xxx-x86_64.AppImage`，再执行 `./VeneraNext-xxx-x86_64.AppImage`（ARM64 选择 `aarch64` 文件） |

`xxx` 请替换为下载文件中的实际版本号。v1.18.1 稳定版提供 x86_64 和 ARM64 的 RPM 与 AppImage；可用 `uname -m` 查看机器架构。

Linux 安装包基于 Ubuntu 22.04 构建，glibc 基线为 2.35。当前稳定版 AppImage 已包含 GTK 3 和 WebKitGTK 4.1，无需额外安装 GTK/WebKit；仍需系统提供 glibc 2.35 或更新版本及兼容的 OpenGL/EGL 显卡驱动。依赖安装、FUSE 问题及发行版兼容范围见 [Linux 安装与分发](doc/distribution/linux.zh.md)。

### macOS

从 [最新稳定版](https://github.com/CyrilPeng/venera-next/releases/latest) 下载 `VeneraNext-xxx.dmg`。

---

## 快速上手

1. **安装**：从[最新稳定版](https://github.com/CyrilPeng/venera-next/releases/latest)安装当前平台的版本；电视按 [Android TV](#android-tv) 说明选择独立 TV 包。
2. **添加内容**（三选一即可开始）：已有漫画文件 → “本地 → 导入”；网络连载 → 在漫画源管理页安装扩展；NAS 目录 → “设置 → 应用 → WebDAV 漫画库”。
3. **开始阅读**：手机与桌面默认的瀑布流模式可以直接跨章连读，TV 默认采用单页低内存阅读；遇到想追的连载，试试在详情页长按“收藏”按钮。阅读模式、拆分双页、夜间调光等可在“设置 → 阅读器”或阅读器内随时调整。

## 使用说明

### 阅读模式与进度

| 模式 | 方向 | 适合 |
|---|---|---|
| 瀑布流（非 TV 默认） | 从上到下 | 跨章节连续阅读，接近章末自动加载相邻章节 |
| 画廊 | 左→右 / 右→左 / 上→下 | 逐页翻看，可按阅读习惯设置多图布局 |
| 连续 | 左→右 / 右→左 / 上→下 | 当前章节内滚动，保留章节切换边界 |

- **预加载**：在“设置 → 阅读器”调整预加载图片数量，提前准备后面的图片，减少翻页等待；多加载一些也会占用更多流量和内存。
- **继续阅读**：进度记录章节与页码，瀑布流记录实际正在读的章节；详情页的正序/倒序只影响章节列表显示。
- **独立阅读设置**：可以为当前设备或某本漫画启用独立设置，不必每次重新调整。

| 单页阅读模式 | 拆分双页模式 |
|---|---|
| <a href="https://git-pictures.cyrilworkshop.dpdns.org/veneranext/Single%20Page%20View.jpg"><img src="https://git-pictures.cyrilworkshop.dpdns.org/veneranext/Single%20Page%20View.jpg" alt="未拆分的单页阅读画面" width="100%" /></a> | <a href="https://git-pictures.cyrilworkshop.dpdns.org/veneranext/Double%20Page%20View.jpg"><img src="https://git-pictures.cyrilworkshop.dpdns.org/veneranext/Double%20Page%20View.jpg" alt="开启拆分双页后的阅读画面" width="100%" /></a> |

### TV 遥控器与低内存阅读

- **主界面**：方向键移动焦点，确定键／手柄 A 激活；返回键／手柄 B 返回。支持菜单键的遥控器可打开部分控件的上下文菜单。
- **阅读画面**：方向键翻页或滚动，确定键打开阅读菜单；菜单打开后方向键只选择菜单控件，不会在背景翻页。返回先收起菜单，再保存进度并退出阅读器。
- **默认低内存模式**：单页阅读、预加载 1 页、64 MiB 解码图片缓存和约 207 万像素解码预算。可在“设置 → 阅读器 → TV 低内存模式”关闭，恢复原有阅读配置并使用瀑布流等模式；这个开关仅保存在当前设备，不参与备份或同步。
- **兼容边界**：低内存模式不修改原文件，但长条图和放大细节可能变糊；缓存上限不是应用总内存上限。网页登录、验证码、文件选择器等仍可能需要输入法或配套输入设备，小范围测试不代表所有电视和盒子均已验证。

### 夜间与墨水屏阅读

- **夜间调光**：在阅读器内开启（阅读设置或底部快捷面板均可），亮度 20%–100% 可调，只作用于应用内画面；应用本身的浅色/深色/跟随系统主题在“设置 → 外观”选择。
- **墨水屏**：使用画廊模式并开启“电子墨水屏刷新”，可设置每 1–10 次翻页闪屏一次，时长为 100–1500 毫秒，样式有黑、白、先白后黑三种。连续与瀑布流模式不触发闪屏。

### 收藏、稍后阅读与追更

- **收藏**：点详情页“收藏”打开面板，可选择本地收藏夹，或收藏到源站账号（视扩展支持）。收藏页支持列表与封面画廊切换（自动或 2–6 列）。
- **快捷收藏**：在详情页长按“收藏”，直接加入指定的本地收藏夹，默认是“追更”。在“设置 → 本地收藏 → 快速收藏”更换目标。
- **追更设置**：在首页打开“追更”页，可更换要关注的收藏夹，也可点“立即检查”手动刷新。
- **稍后阅读**：在详情页或本地漫画菜单加入/移除，首页可进入完整列表；打开阅读不会自动移除。
- **阅读统计**：历史页查看累计阅读时长、读过的作品数和时长排行，可按保留天数清理历史。
- **搜索快捷方式**：常搜的作者/标签可保存为快捷方式，在搜索页一键复用。

### 本地漫画与离线下载

| 内容 | 导入与阅读方式 |
|---|---|
| 图片目录 | 支持单本、批量目录及章节子目录；封面可选，文件按自然顺序排列 |
| CBZ / ZIP / 7Z / CB7 | 解压后导入本地库，支持带顶层目录和章节子目录的归档 |
| PDF | 支持多选逐本导入、进度与取消；逐页转为本地 JPEG，第一页作为封面 |
| 图片型 EPUB | 按 EPUB 的阅读顺序导入漫画图片，尽量保留标题、作者、封面和章节目录 |
| 网络源下载 | 已下载章节进入本地漫画库，供离线阅读，也可用于后续导出和归档 |

支持导出 CBZ、扫描恢复下载内容、删除章节和迁移存储位置。PDF/EPUB 导入会占用额外空间；文字型 EPUB、直接绘制的 SVG 页面、加密 PDF 和 MOBI/AZW/AZW3 暂不支持。目录示例、压缩包兼容规则及元数据模板见[本地漫画导入、CBZ 与 WebDAV 漫画库](doc/user/import_comic.zh.md)。

### 网络漫画源

网络内容由用户添加的 JavaScript 扩展提供，不同扩展支持的搜索、探索、分类、账号、收藏和评论入口可能不同。

在漫画源管理页添加兼容的脚本链接或文件。想编写自己的扩展，见下方[漫画源开发](#漫画源开发)。

### WebDAV 数据同步、归档与在线漫画库

三类能力分别配置：

| 能力 | “设置 → 应用”中的入口 | 用途 |
|---|---|---|
| 应用数据同步 | 数据同步 / Data Sync | 同步设置、收藏、历史、Cookie 和源文件等，不包含本地漫画图片 |
| 漫画归档 | 漫画归档备份 / Comic Archive Backup | 把本地漫画导出为 CBZ 上传，或下载归档恢复到本地库 |
| 在线漫画库 | WebDAV 漫画库 / WebDAV Comic Library | 按需读取远端图片目录，并缓存目录与图片 |

在线漫画库支持图片目录、章节子目录和 VeneraNext 导出 CBZ 的解压目录。`metadata.json` 可补充标题、作者、标签和章节信息。书架先显示已缓存的漫画，再检查服务端新增或改动的内容；可手动同步，也可设置自动更新周期。

远端 CBZ/ZIP/7Z/CB7 压缩包需要先在服务端解压，或通过归档恢复到本地后再阅读。详见[目录与元数据规则](doc/user/import_comic.zh.md#webdav-在线漫画库)。

## 漫画源开发

**第三方源开发者从这里开始：**

| 文档 | 内容 |
|---|---|
| [漫画源编写指南](doc/api/comic_source.zh.md) | 最小示例、搜索/详情/章节返回规则、图片请求与可选能力 |
| [最小源模板](doc/examples/minimal_source.js) | 可复制的 JS 文件，使用虚构接口演示完整加载流程 |
| [JavaScript API](doc/api/js.zh.md) | Network、HTML 解析、数据存储、UI、图片处理及运行时限制 |
| [本地调试](doc/development/source_debugging.zh.md) | 导入、编辑、JS Evaluator 与日志 |

英文对应文档：[Comic Source Guide](doc/api/comic_source.en.md) · [JavaScript API](doc/api/js.en.md) · [Local Source Debugging](doc/development/source_debugging.en.md)。

本分支继续维护兼容 Venera 的扩展接口。瀑布流、拆分双页和夜间调光由阅读器处理；扩展应提供稳定的漫画/章节标识、正确的章节与图片顺序、有效的更新日期，无需为每一种阅读模式另写一套规则。

## FAQ

### VeneraNext 自带漫画源吗？

不自带，也不提供推荐源列表。可以先导入本地漫画，或自行合法配置兼容扩展、WebDAV 漫画库。

### 搜索不到内容或图片加载失败怎么办？

先检查漫画源扩展、登录状态（Cookie）、源站状态和网络。具体站点和内容问题请联系相应扩展的维护者；可脱离具体站点复现的阅读器或扩展运行时问题，欢迎按[贡献指南](CONTRIBUTING.md)反馈。

### 追更多久检查一次？为什么没有更新提示？

- **自动检查**：应用运行时每 10 分钟检查一轮，最近 24 小时内已成功检查的作品会跳过；想马上刷新，可在追更页点“立即检查”。
- **更新依据**：扩展返回的有效更新时间发生变化后才会标记更新。只新增章节、更新时间没变化时，可能不会提示。
- **更新标记**：“设置 → 发现 → 在漫画缩略图上显示更新提示”控制缩略图上的标记，不影响追更检查和首页更新数量。

### 平板上怎样缩小条漫？

在阅读器设置中选择纵向连续或瀑布流模式，调整「条漫缩小（每侧边距）」。每侧设为 20% 时，图片宽度缩小到原来的 60%，高度按比例变化，并保留阅读进度。详见[条漫缩小与左右边距](doc/user/reader_width.zh.md)。

### Windows 怎样更新？

使用 `winget upgrade --id CyrilPeng.VeneraNext --exact`。公共源收录新版本可能晚于 GitHub Release，可先运行 `winget source update`。便携版需要下载新版本手动覆盖更新。

## 开发者入口

- [构建与开发](doc/development/build.zh.md)：Flutter/Rust 环境、依赖锁定、测试和发布。
- [贡献指南](CONTRIBUTING.md) · [依赖治理](doc/development/dependencies.zh.md)。
- [Windows 分发维护](doc/distribution/windows.zh.md) · [无头命令模式](doc/user/headless.zh.md)。
- [安全政策](SECURITY.md) · [行为准则](CODE_OF_CONDUCT.md) · [完整文档索引](doc/README.md)。

---

## 星标历史

<a href="https://www.star-history.com/?repos=CyrilPeng%2FVenera-Next&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=CyrilPeng/Venera-Next&type=date&theme=dark&legend=top-left&sealed_token=oOpEg16aOzfNd-LxRdnNlKMFvVT7R4hxnX3R0_siwlG1kcvQby3KmHFNPHaH-dbuficb1pbCiQyzTRFVYt2oKGGfjghUgiIs1huNy1yZ1ffelz7owlDrYQ" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=CyrilPeng/Venera-Next&type=date&legend=top-left&sealed_token=oOpEg16aOzfNd-LxRdnNlKMFvVT7R4hxnX3R0_siwlG1kcvQby3KmHFNPHaH-dbuficb1pbCiQyzTRFVYt2oKGGfjghUgiIs1huNy1yZ1ffelz7owlDrYQ" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=CyrilPeng/Venera-Next&type=date&legend=top-left&sealed_token=oOpEg16aOzfNd-LxRdnNlKMFvVT7R4hxnX3R0_siwlG1kcvQby3KmHFNPHaH-dbuficb1pbCiQyzTRFVYt2oKGGfjghUgiIs1huNy1yZ1ffelz7owlDrYQ" />
 </picture>
</a>

---

## 声明


本仓库只维护 VeneraNext 漫画阅读器本体，**不提供、内置、托管或推荐任何漫画源，也不处理任何源站内容**。

网络阅读能力兼容 JavaScript 扩展 API，需要用户自行配置合法的漫画源扩展；搜索结果、章节加载、图片可用性和内容版权均取决于对应源站与扩展实现。

**请不要在本仓库提交与漫画源、源站内容、具体作品可用性或版权相关的问题，此类反馈会直接关闭。**

---

## 赞助

[![爱发电](https://img.shields.io/badge/爱发电-支持我-ff69b4?style=for-the-badge&logo=data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0id2hpdGUiPjxwYXRoIGQ9Ik0xMiAyMS4zNWwtMS40NS0xLjMyQzUuNCAxNS4zNiAyIDEyLjI4IDIgOC41IDIgNS40MiA0LjQyIDMgNy41IDNjMS43NCAwIDMuNDEuODEgNC41IDIuMDlDMTMuMDkgMy44MSAxNC43NiAzIDE2LjUgMyAxOS41OCAzIDIyIDUuNDIgMjIgOC41YzAgMy43OC0zLjQgNi44Ni04LjU1IDExLjU0TDEyIDIxLjM1eiIvPjwvc3ZnPg==)](https://ifdian.net/a/cyril)

本项目为个人兴趣维护，不以盈利为目的。如果 VeneraNext 对你的日常阅读有帮助，欢迎在[爱发电](https://ifdian.net/a/cyril)上支持作者的持续维护。

赞助状态会通过爱发电 API 定期同步。需要公开鸣谢时，请在订单备注中填写“公开昵称：你的昵称”；未提供公开昵称的订单不会展示。

赞助者名单见 [SPONSORS.md](SPONSORS.md)。

---

## 致谢

感谢 [Venera](https://github.com/venera-app/venera) 提供的阅读器与扩展基础，以及 [EhTagTranslation](https://github.com/EhTagTranslation/Database) 的中文标签翻译数据。也感谢所有贡献者与赞助者。

## 许可

本项目遵循 GPL-3.0 许可。

---

## 友情链接

- [LINUX DO](https://linux.do/)
