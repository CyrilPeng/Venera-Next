<div align="center">
  <strong>简体中文</strong> | <a href="README.en.md">English</a>
  <br>
  <br>
  <img src="assets/readme_logo.png" alt="VeneraNext" width="200" />

  # VeneraNext

  ![Flutter](https://img.shields.io/badge/Flutter-3.41.4-02569B?logo=flutter&logoColor=white&style=flat-square)
  [![Release](https://img.shields.io/github/v/release/CyrilPeng/venera-next?label=Release&color=10B981&style=flat-square)](https://github.com/CyrilPeng/venera-next/releases)
  ![License](https://img.shields.io/badge/License-GPL--3.0-10B981?style=flat-square)
  <br>
  [![Downloads](https://img.shields.io/github/downloads/CyrilPeng/venera-next/total?style=flat-square&color=2ea44f&logo=github)](https://tooomm.github.io/github-release-stats/?user=CyrilPeng&repo=venera-next)
  [![爱发电](https://img.shields.io/badge/爱发电-支持我-ff69b4?style=flat-square&logo=data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0id2hpdGUiPjxwYXRoIGQ9Ik0xMiAyMS4zNWwtMS40NS0xLjMyQzUuNCAxNS4zNiAyIDEyLjI4IDIgOC41IDIgNS40MiA0LjQyIDMgNy41IDNjMS43NCAwIDMuNDEuODEgNC41IDIuMDlDMTMuMDkgMy44MSAxNC43NiAzIDE2LjUgMyAxOS41OCAzIDIyIDUuNDIgMjIgOC41YzAgMy43OC0zLjQgNi44Ni04LjU1IDExLjU0TDEyIDIxLjM1eiIvPjwvc3ZnPg==)](https://ifdian.net/a/cyril)

</div>

<!-- featured-sponsors:start -->
<!-- featured-sponsors:end -->

---

## 目录

- [项目介绍](#项目介绍)
- [功能亮点](#功能亮点)
- [下载安装](#下载安装)
- [快速上手](#快速上手)
- [使用说明](#使用说明)
- [漫画源开发](#漫画源开发)
- [FAQ](#faq)
- [开发者入口](#开发者入口)
- [声明](#声明)
- [赞助](#赞助)
- [致谢](#致谢)
- [许可](#许可)

---

## 项目介绍

[VeneraNext](https://github.com/CyrilPeng/venera-next) 是基于 [Venera](https://github.com/venera-app/venera) 持续开发的 Flutter 漫画阅读器，支持 **Android、iOS、Windows、Linux 和 macOS**。

本分支围绕“少一点打断，多一点阅读”改进日常体验：长篇漫画可以瀑布流跨章阅读，横向双页可以拆开看，夜间和墨水屏设备有各自的阅读设置；从发现作品、稍后阅读、收藏追更，到离线下载、阅读统计和多设备同步，也有相互衔接的入口。

原项目的 JavaScript 漫画源扩展、本地阅读、搜索与分类、收藏下载，以及按源提供的登录、评论和评分能力继续保留。

**快速入口：** [下载安装](#下载安装) · [使用说明](#使用说明) · [编写漫画源](doc/api/comic_source.zh.md) · [JavaScript API](doc/api/js.zh.md) · [更新日志](CHANGELOG.md)

> [!IMPORTANT]
> 本仓库只维护阅读器本体和扩展运行环境，不提供、内置、托管或推荐漫画源。网络漫画源需由用户自行合法配置，具体内容及源站可用性由相应扩展和服务决定。

<div align="center">
  <a href="https://github.com/CyrilPeng/venera-next">GitHub 主仓库</a> ·
  <a href="https://gitee.com/CyrilPeng/venera-next">Gitee 国内镜像</a>
</div>

---

## 功能亮点

### 本分支的重点改进

以下能力已包含在截至 **v1.16.0** 的稳定版中；后续版本归属见 [CHANGELOG](CHANGELOG.md)。

| 改进 | 日常使用体验 |
|---|---|
| **瀑布流跨章节阅读** | 默认阅读模式。接近章末自动预加载下一章，可以继续向下阅读，也可以滚回已加载的上一章；章节分隔和阅读记录跟随实际位置。 |
| **纵向拆分双页** | 在纵向连续和瀑布流模式中，把横向双页按顺序上下排列，支持交换左右两半的先后顺序；保持原图片页数与进度含义。 |
| **夜间调光** | 阅读器内独立开关与 20%–100% 亮度调节，阅读设置和底部快捷面板均可操作；与应用的浅色、深色主题配合使用。 |
| **电子墨水屏刷新** | 画廊翻页后按设定间隔闪屏，可调时长，支持黑色、白色、先白后黑三种样式，帮助减少残影。 |
| **更顺手的详情页** | 桌面与移动端统一两行操作区，突出下载、阅读和继续阅读；显示章节进度与更新提示，章节正序/倒序偏好会保存。 |
| **稍后阅读与追更** | 把“准备开始看的作品”和“持续关注的连载”分别管理；首页提供待看列表、追更封面预览和更新提示。 |
| **收藏与检索** | 收藏页可切换封面画廊，自动或 2～6 列；支持保存作者、标签搜索快捷方式，图片收藏增加单部漫画的图库浏览。 |
| **阅读时长统计** | 记录前台有效阅读时长，在历史页和设置入口查看累计时长、读过的漫画数量与排行。 |
| **更完整的本地漫画库** | 图片目录、CBZ/ZIP/7Z/CB7、PDF 和图片型 EPUB 导入；支持章节目录、自然排序、PDF 批量导入，以及 CBZ 导出和恢复。 |
| **WebDAV 漫画库与归档** | 在线读取 NAS/WebDAV 图片目录，支持目录缓存、增量同步和元数据；本地漫画还可单独备份为 CBZ 并恢复。 |
| **数据与桌面体验** | 配置原子写入与备份恢复、同步状态与错误展示、历史清理，以及 Windows 安装器、便携包和 winget 更新。 |

### 主分支的新变化

下面这些改进已合入当前主分支，仍列在 [CHANGELOG 的“未发布”](CHANGELOG.md#未发布) 中，**不属于 v1.16.0 稳定版**：

- **自动选择阅读模式**：根据正文原图比例识别页漫或条漫，按各自偏好切换模式；默认关闭，单本手动指定优先。[使用说明](doc/user/automatic_reader_mode.zh.md)
- **自动阅读与长按动作**：覆盖七种模式，分页定时翻页，连续与瀑布流支持平滑或步进滚动，可选择自动跨章；触摸、缩放、打开设置或进入后台时暂停推进。
- **PDF 后台导入**：收起进度后可继续阅读，在“本地”的 PDF 任务入口查看进度、取消或回看结果；多批次依次处理，任务限应用运行期间。[导入说明](doc/user/import_comic.zh.md#pdf)
- **统一添加来源与多仓库管理**：链接、粘贴内容和 JS/JSON 文件统一识别预览；可选择安装条目、保存多个在线仓库，并查看后台安装、取消、重试和来源关联。[漫画源与源仓库](doc/user/source_repositories.zh.md)
- **追更与源调试改进**：追更按源限流，取消时停止旧检查；源编辑支持保存并重载、失败保留原源，调试器能等待异步结果。[本地调试](doc/development/source_debugging.zh.md)

### 延续 Venera 的核心能力

- **开放的扩展接口**：用 JavaScript 对接漫画服务，按源提供搜索、聚合搜索、探索页、分类、排行和标签翻译。
- **多种阅读方式**：保留画廊分页、章节内连续滚动、缩放和多图布局，支持触摸、键盘及移动端音量键等阅读操作。
- **收藏与离线阅读**：本地收藏、网络收藏、历史记录、图片收藏和下载队列；已下载章节可离线读取。
- **按源启用的互动**：登录、Cookie、评论与回复、章节评论、点赞和评分等，由扩展实际支持的能力决定。
- **跨设备使用**：WebDAV 应用数据同步与导入导出，以及可用于脚本调用的[无头命令模式](doc/user/headless.zh.md)。

---

## 下载安装

### Android

从 [Releases](https://github.com/CyrilPeng/venera-next/releases) 下载 APK 安装包：

| 文件名 | 说明 | 适用场景 |
|---|---|---|
| `VeneraNext-xxx-android.apk` | 通用版 | 适用于大多数 Android 设备 |
| `VeneraNext-xxx-android-arm64-v8a.apk` | ARM64 版 | 支持 ARM64 应用的 Android 设备 |
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

1. 从 [Releases](https://github.com/CyrilPeng/venera-next/releases) 安装适合当前平台的版本。
2. 选择内容来源：设备上的图片、压缩包或图片文档进入“本地 → 导入”；网络阅读先添加兼容扩展；NAS 目录在“设置 → 应用 → WebDAV 漫画库”配置。
3. 在“设置 → 阅读器”选择阅读模式。长篇连载可用默认瀑布流；传统逐页翻看可用画廊；只想在当前章滚动可用连续模式。
4. 按设备调整拆分双页、夜间调光或墨水屏刷新。需要时启用设备专属、漫画专属设置。
5. 详情页点“阅读/继续阅读”或具体章节开始；暂时不看可加入“稍后阅读”，连载作品可放入追更收藏夹。
6. 需要离线时下载章节；需要跨设备时再配置数据同步、漫画归档或在线漫画库。

## 使用说明

### 阅读模式与进度

| 模式 | 方向 | 适用场景 |
|---|---|---|
| 瀑布流 | 从上到下 | 跨章节连续阅读，接近边界时加载相邻章节 |
| 画廊 | 从左到右、从右到左、从上到下 | 按页翻看，可按阅读习惯设置多图布局 |
| 连续 | 从左到右、从右到左、从上到下 | 当前章节内滚动，保留章节切换边界 |

- **预加载**：瀑布流复用“预加载图片数量”设置。数量越大，可能越早加载后续内容，也会增加网络和内存占用。
- **拆分双页**：只适用于纵向连续、瀑布流；顺序不合适时开启“交换拆分顺序”。应用仍按原图片记录页数。
- **继续阅读**：保存章节、页码和章节组；瀑布流会记录实际正在阅读的章节。详情页的正序/倒序只调整章节列表显示。
- **设置范围**：普通阅读设置按漫画专属、设备专属、全局依次回退，专属设置需先启用。主分支中的单本阅读模式指定有独立优先级。
- **自动模式识别（主分支）**：默认关闭，只依据正文图片比例，不依赖源站声明；切换保持章节和原图片位置，不保留图片内精确像素偏移。[详细说明](doc/user/automatic_reader_mode.zh.md)

### 夜间与墨水屏阅读

在“设置 → 外观”选择浅色、深色或跟随系统主题；阅读器内的**夜间调光**用于进一步压暗漫画画面。开启后可在阅读设置或底部快捷面板调节 20%–100% 的亮度，它作用于应用内画面，不调整设备系统亮度。

墨水屏设备可选择**画廊模式**并开启“电子墨水屏刷新”：设置每 1～10 次翻页刷新一次、100～1500 毫秒闪屏时长，以及黑色、白色或先白后黑样式。这是阅读器画面的闪屏刷新，效果会受设备自身刷新策略影响。连续与瀑布流模式不触发这一功能。

### 自动阅读与手势（主分支）

开启自动阅读后，画廊模式按间隔翻页；连续与瀑布流可以平滑滚动（10～1000 像素/秒），或步进滚动（每秒 1～10 次、每次 10～500 像素）。可选择是否自动跨章，长图会滚动到底后再继续。

触摸、缩放、设置面板和后台状态会暂停推进，加载失败或读到末章末尾时停止。长按动作可设为放大图片、开始/停止自动阅读或无操作；原有长按缩放偏好会保留。

### 详情页、稍后阅读与追更

- **详情页**：常用互动操作与下载/阅读主按钮分行显示，继续阅读、章节进度、更新提示集中呈现；正序/倒序切换会记住偏好。
- **稍后阅读**：详情页或本地漫画菜单可加入/移除，首页可以进入完整列表。打开阅读不会自动移除；列表复用独立本地收藏夹，可重命名、删除并随应用数据同步。
- **追更**：以选定的本地收藏夹作为检查范围，首页展示封面和更新数量。默认快捷收藏可指向“追更”，已有有效偏好与主动停用状态会保留；长按详情页收藏按钮可快速收藏。
- **更新依据**：追更依赖源详情提供的有效更新日期，不保证仅凭新增章节就能识别更新；更新提示可在设置中关闭。
- **作者与标签**：支持搜索跳转的作者/标签可保存为搜索快捷方式，在搜索页复用；这是保存检索条件，不是自动追更某位作者的全部作品。

### 收藏、图片与阅读统计

本地收藏由应用管理，网络收藏由源站账号和扩展提供。收藏页的封面画廊支持自动或 2～6 列布局；图片收藏可按漫画进入图库浏览。

历史页记录阅读位置和前台有效阅读时长，并提供累计时长、漫画数量和时长排行；“设置”中也有阅读统计入口。可按保留天数清理历史。离开阅读器或进入后台时会结算相应的有效阅读时段。

### 本地漫画与离线下载

| 内容 | 导入与阅读方式 |
|---|---|
| 图片目录 | 支持单本、批量目录及章节子目录；封面可选，文件按自然顺序排列 |
| CBZ / ZIP / 7Z / CB7 | 解压后导入本地库，支持带顶层目录和章节子目录的归档 |
| PDF | 支持多选逐本导入、进度与取消；逐页转为本地 JPEG，第一页作为封面 |
| 图片型 EPUB | 按 spine 顺序提取栅格图片，尽量保留标题、作者、封面和有效章节导航 |
| 网络源下载 | 已下载章节进入本地漫画库，供离线阅读，也可用于后续导出和归档 |

可导出 CBZ、扫描恢复下载内容、删除章节或迁移存储位置。PDF/EPUB 导入会占用额外空间；文字型 EPUB、直接绘制的 SVG 页面、加密 PDF 和 MOBI/AZW/AZW3 不支持。

目录示例、压缩包兼容规则及元数据模板见[本地漫画导入、CBZ 与 WebDAV 漫画库](doc/user/import_comic.zh.md)。

### 网络漫画源

网络内容由用户添加的 JavaScript 扩展提供，不同扩展支持的搜索、探索、分类、账号、收藏和评论入口可能不同。

主分支使用“漫画源 → 添加来源”：粘贴脚本/列表链接或内容，也可选择 JS/JSON 文件；识别后预览再安装。在线列表可保存为仓库，已安装源可关联、切换或解除更新来源。稳定版 v1.16.0 仍使用原有链接/文件和单源列表入口。

安装任务、仓库更新与迁移规则见[漫画源与源仓库](doc/user/source_repositories.zh.md)。编写自己的扩展请直接阅读下方[漫画源开发](#漫画源开发)。

### WebDAV 数据同步、归档与在线漫画库

三类能力分别配置：

| 能力 | “设置 → 应用”中的入口 | 用途 |
|---|---|---|
| 应用数据同步 | 数据同步 / Data Sync | 同步设置、收藏、历史、Cookie 和源文件等，不包含本地漫画图片 |
| 漫画归档 | 漫画归档备份 / Comic Archive Backup | 把本地漫画导出为 CBZ 上传，或下载归档恢复到本地库 |
| 在线漫画库 | WebDAV 漫画库 / WebDAV Comic Library | 按需读取远端图片目录，并缓存目录与图片 |

在线漫画库支持普通图片目录、带章节的目录，以及 VeneraNext 导出 CBZ 的解压目录。有效的 `metadata.json` 可提供标题、作者、标签和章节页码范围，也可标记分层目录中的漫画根目录；元数据无效时回退普通目录识别。

书架优先展示缓存，后台增量检查远端变化，可手动同步和设置自动更新周期。远端 CBZ/ZIP/7Z/CB7 本身不支持在线预览，应先在服务端解压，或通过归档恢复后本地阅读。[目录与元数据规则](doc/user/import_comic.zh.md#webdav-在线漫画库)

## 漫画源开发

**第三方源开发者从这里开始：**

| 文档 | 内容 |
|---|---|
| [漫画源编写指南](doc/api/comic_source.zh.md) | 最小示例、搜索/详情/章节返回规则、图片请求、可选能力与仓库发布 |
| [最小源模板](doc/examples/minimal_source.js) | 可复制的 JS 文件，使用虚构接口演示完整加载流程 |
| [JavaScript API](doc/api/js.zh.md) | Network、HTML 解析、数据存储、UI、图片处理及运行时限制 |
| [本地调试](doc/development/source_debugging.zh.md) | 导入、编辑、重新加载、JS Evaluator、日志与取消边界 |
| [源仓库使用说明](doc/user/source_repositories.zh.md) | 安装队列、来源关联、版本更新和旧配置迁移 |

英文对应文档：[Comic Source Guide](doc/api/comic_source.en.md) · [JavaScript API](doc/api/js.en.md) · [Local Source Debugging](doc/development/source_debugging.en.md)。

本分支继续维护兼容 Venera 的扩展接口。瀑布流、拆分双页、夜间调光和自动阅读由阅读器处理；扩展应提供稳定的漫画/章节标识、正确的章节与图片顺序、有效的更新日期，无需为每一种阅读模式另写一套规则。

## FAQ

### VeneraNext 自带漫画源吗？

不自带，也不提供推荐源列表。可以先导入本地漫画，或自行合法配置兼容扩展、WebDAV 漫画库。

### 为什么找不到 README 提到的部分按钮？

先检查“关于”中的版本。本文标为“主分支”的功能仍在未发布记录中，v1.16.0 稳定版不包含它们；账号、评论、评分等能力还取决于扩展是否实现。

### 搜索不到内容、图片加载失败或没有追更提示怎么办？

先检查扩展、登录/Cookie、源站状态和网络。追更还需要扩展返回有效的更新日期。具体站点和内容问题应联系相应维护者；可脱离具体站点复现的阅读器或扩展运行时问题可按[贡献指南](CONTRIBUTING.md)反馈。

### Windows 怎样更新？

使用 `winget upgrade --id CyrilPeng.VeneraNext --exact`。公共源收录新版本可能晚于 GitHub Release，可先运行 `winget source update`。便携版需要下载新版本手动覆盖更新。

## 开发者入口

- [构建与开发](doc/development/build.zh.md)：Flutter/Rust 环境、依赖锁定、测试和发布。
- [贡献指南](CONTRIBUTING.md) · [项目结构约定](doc/architecture/project_structure.zh.md) · [依赖治理](doc/development/dependencies.zh.md)。
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
