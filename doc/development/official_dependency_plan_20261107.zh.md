# 官方依赖来源核查与迁移方案（2026-11-07）

[机器证据与完整版本记录](official_dependency_plan_20261107.json) · [依赖治理](dependencies.zh.md)

本文保留迁移前的审计快照；后续实际来源切换、未采用候选和验证结果见[实施记录](official_dependency_implementation_20261107.zh.md)。

推荐顺序为：**满足功能、SDK、许可证与安全要求的官方稳定发布版 → 已验证的官方完整 commit → 有明确必要补丁的本地源码**。源码归属不构成固定 SHA 的必要条件。使用稳定版也必须保留当前已审核的行为与安全修复；官方版本名本身不能代替验证。

本轮是审计与方案，没有切换依赖声明、锁文件或原生库。主线审核工作区基线为 `de2e0a9f397a0d06e727d3fde2dc54c95c50e39f`，鸿蒙为 `db77548bbf944da3f6b0233174b11df060a33d2b`。两者依赖声明与完整包锁定记录相同，应用版本分别为 `1.18.3+244` / `1.18.3+245`；业务代码和平台初始化路径不同。

根 pubspec 共 **49 个直接声明**，包含 36 个 pub.dev 包（含开发依赖 flutter_lints）、2 个 Git 直接依赖、8 个本地包、3 个 SDK 依赖。完整根锁文件共 **156 个包：135 hosted、8 Git、8 path、5 SDK**。两个 Git 来源中，WebView 同仓提供七个包；本地包为六个第三方定制包和两个项目自编模块。这里使用当前锁文件实际统计，历史迁移文档的其他计数不作为当前总数。

查询 pub.dev 当前发布元数据、校验 15 个正式发布归档的 SHA-256，核查八个当前第三方定制包的官方 Git 来源；另比较 PhotoView、滚动列表、WebDAV 的全部运行时 Dart 文件。相同 Dart 3.11 格式化后，官方稳定版与本地源码分别有 6/16、7/12、6/11 文件一致；变化数包括原 fork、上游版本差异和后续本地修改，不能全解释为本轮新增业务补丁。

以下表格覆盖所有直接声明。最新稳定版是查询结果，建议列中的候选仍须经过对应的解析与行为验证。

| 依赖 | 当前来源 / 锁定版本 | 当前官方稳定版 | 建议 |
|---|---|---|---|
| `flutter` | SDK `0.0.0` | `随项目/SDK` | 随平台 SDK。Flutter / localizations / test 随对应 SDK 固定，不复制到个人仓库。 |
| `path_provider` | pub.dev `2.1.6` | `2.1.6` | 保留官方稳定版。当前已直接使用 pub.dev；不新增 fork 或本地源码副本。 |
| `intl` | pub.dev `0.20.2` | `0.20.3` | 官方稳定版 0.20.2。跟随 Flutter localizations 的固定版本；0.20.3 不能单独强制升级。 |
| `window_manager` | pub.dev `0.5.2` | `0.6.0` | 官方稳定版 0.5.2。最新 0.6.0 要求 Flutter >=3.47 / Dart ^3.13；当前保留兼容版。 |
| `sqlite3` | pub.dev `2.7.4` | `3.9.0` | 官方稳定版；先评估 2.9.4。2.x 更新与数据库回归单独进行；3.9.0 的 hooks 2.2 链需要当前图中没有的 meta ^1.19。 |
| `sqlite3_flutter_libs` | pub.dev `0.5.42` | `0.6.0+eol` | 官方稳定版 0.5.42。0.6.0+eol 已不提供原生库；SQLite 3.x 验收后删除本包，不能在 2.x 下直接升级它。 |
| `flutter_qjs` | Git `0.3.7` | `0.3.7` | 目标官方固定 commit；暂保留必要定制。0.3.7 稳定版的 SDK/API 不满足项目；官方 0.4.0 commit 有解析、Map 与生命周期差异。先独立修复旧核心安全问题。 |
| `crypto` | pub.dev `3.0.8` | `3.0.8` | 保留官方稳定版。当前已直接使用 pub.dev；不新增 fork 或本地源码副本。 |
| `dio` | pub.dev `5.11.1` | `5.11.1` | 保留官方稳定版。当前已直接使用 pub.dev；不新增 fork 或本地源码副本。 |
| `html` | pub.dev `0.15.7` | `0.15.7` | 保留官方稳定版。当前已直接使用 pub.dev；不新增 fork 或本地源码副本。 |
| `pointycastle` | pub.dev `4.0.0` | `4.0.0` | 保留官方稳定版。当前已直接使用 pub.dev；不新增 fork 或本地源码副本。 |
| `url_launcher` | pub.dev `6.3.3` | `6.3.3` | 保留官方稳定版。当前已直接使用 pub.dev；不新增 fork 或本地源码副本。 |
| `path` | pub.dev `1.9.1` | `1.9.1` | 保留官方稳定版。当前已直接使用 pub.dev；不新增 fork 或本地源码副本。 |
| `photo_view` | 本地 `0.14.0` | `0.15.0` | 必要本地补丁；目标官方稳定版。官方 0.15.0 仍有图片引用释放问题，并缺缩放/动画接口；真实应用替换有 15 个 API 错误。 |
| `mime` | pub.dev `2.1.0` | `2.1.0` | 保留官方稳定版。当前已直接使用 pub.dev；不新增 fork 或本地源码副本。 |
| `share_plus` | 本地 `12.0.2` | `13.3.1` | 必要本地原生补丁；目标官方稳定版。官方 13.3.1 已含新修复，但 Windows 回调/数据所有权和 Android 已分享文件保留问题仍未覆盖。 |
| `scrollable_positioned_list` | 本地 `0.3.8+1` | `0.3.8` | 优先迁回官方稳定版 0.3.8。先以官方像素滚动接口、滚动通知和 ScrollConfiguration 承接原始控制器/行为接口；不是直接改声明。 |
| `flutter_reorderable_grid_view` | pub.dev `5.7.0` | `5.10.0` | 官方稳定版；评估 5.10.0。已经使用官方来源；新版本需独立解析并验证网格排序的现有调用。 |
| `uuid` | pub.dev `4.6.0` | `4.6.0` | 保留官方稳定版。当前已直接使用 pub.dev；不新增 fork 或本地源码副本。 |
| `desktop_webview_window` | 本地 `0.2.4` | `0.4.2` | 必要本地平台补丁；目标官方稳定版。兼容 SDK 的 0.3.2 也缺 proxy 和 setOnNavigation；最新 0.4.2 另要求 Flutter >=3.44。 |
| `flutter_inappwebview` | Git `6.2.0-beta.3` | `6.1.5` | 目标官方固定 commit + 必要 Windows 本地包。稳定版 6.1.5 缺退出事件；官方 commit 有 API，但仍缺 Windows context 所有权修复。 |
| `app_links` | pub.dev `7.0.0` | `7.2.2` | 官方稳定版 7.0.0。最新 7.2.2 要求 Flutter >=3.44 / Dart ^3.12；跟随 SDK 升级。 |
| `sliver_tools` | pub.dev `0.2.12` | `0.2.12` | 保留官方稳定版。当前已直接使用 pub.dev；不新增 fork 或本地源码副本。 |
| `flutter_file_dialog` | pub.dev `3.0.3` | `3.3.6` | 官方稳定版 3.0.3。最新 3.3.6 要求 Flutter >=3.44 / Dart ^3.12；跟随 SDK 升级。 |
| `file_selector` | pub.dev `1.1.0` | `1.1.0` | 保留官方稳定版。当前已直接使用 pub.dev；不新增 fork 或本地源码副本。 |
| `zip_flutter` | pub.dev `0.0.13` | `0.0.13` | 保留官方稳定版。当前已直接使用 pub.dev；不新增 fork 或本地源码副本。 |
| `venera_native` | 本地 `1.0.0` | `随项目/SDK` | 项目代码保留本地。项目自编 PNG/7z 桥接；官方核心分别登记固定来源，不能用旧同名包装包替代。 |
| `rhttp` | 本地 `0.15.1` | `0.18.0` | 必要本地安全补丁；目标官方稳定版 0.18.0。新 bridge 已改掉旧发送 panic 路径，但稳定版和当前官方 Git 的 Rust 锁文件都命中公告；鸿蒙还需显式库加载适配。 |
| `flutter_rust_bridge` | pub.dev `2.11.1` | `2.13.0` | 官方稳定版；与 Rust 生成代码成组固定。当前 Dart/Rust 为 2.11.1；评估 rhttp 0.18.0 时先对齐 2.12.0，不能独立跳到最新 2.13.0。 |
| `webdav_client` | 本地 `1.2.2` | `1.2.2` | 必要本地补丁；目标官方稳定版/修复 commit。adapter 可在创建后设置，但认证、301、上传和取消处理仍有差异；官方包还调用 Dio 内部接口。 |
| `battery_plus` | pub.dev `7.1.2` | `7.1.2` | 保留官方稳定版。当前已直接使用 pub.dev；不新增 fork 或本地源码副本。 |
| `local_auth` | pub.dev `3.0.2` | `3.0.2` | 保留官方稳定版。当前已直接使用 pub.dev；不新增 fork 或本地源码副本。 |
| `venera_saf` | 本地 `1.0.0` | `随项目/SDK` | 项目代码保留本地。项目自编 Android 持久授权与文件访问；原占位许可证包装层不再作为来源。 |
| `dynamic_color` | pub.dev `1.8.1` | `2.1.0` | 官方稳定版；评估 1.9.0/2.1.0。已经使用官方来源；需核对新的 material_ui 依赖、颜色行为与原生构建要求。 |
| `shimmer_animation` | pub.dev `2.2.2` | `2.2.2+1` | 官方稳定版；评估 2.2.2+1。已使用官方来源，当前锁定 2.2.2；补丁更新与其他迁移分开验证。 |
| `flutter_memory_info` | pub.dev `0.0.3` | `0.0.3` | 保留官方稳定版。当前已直接使用 pub.dev；不新增 fork 或本地源码副本。 |
| `syntax_highlight` | pub.dev `0.5.0` | `0.5.0` | 保留官方稳定版。当前已直接使用 pub.dev；不新增 fork 或本地源码副本。 |
| `flex_seed_scheme` | pub.dev `4.0.1` | `5.0.1` | 官方稳定版 4.0.1。最新 5.0.1 要求 Flutter >=3.47 / Dart >=3.13；当前保留兼容版。 |
| `flutter_localizations` | SDK `0.0.0` | `随项目/SDK` | 随平台 SDK。Flutter / localizations / test 随对应 SDK 固定，不复制到个人仓库。 |
| `yaml` | pub.dev `3.1.4` | `3.1.4` | 保留官方稳定版。当前已直接使用 pub.dev；不新增 fork 或本地源码副本。 |
| `enough_convert` | pub.dev `1.7.1` | `1.7.1` | 保留官方稳定版。当前已直接使用 pub.dev；不新增 fork 或本地源码副本。 |
| `display_mode` | pub.dev `0.0.2` | `0.0.2` | 保留官方稳定版。当前已直接使用 pub.dev；不新增 fork 或本地源码副本。 |
| `flutter_staggered_grid_view` | pub.dev `0.7.0` | `0.7.0` | 保留官方稳定版。当前已直接使用 pub.dev；不新增 fork 或本地源码副本。 |
| `archive` | pub.dev `4.6.0` | `4.6.0` | 保留官方稳定版。当前已直接使用 pub.dev；不新增 fork 或本地源码副本。 |
| `image` | pub.dev `4.12.0` | `4.12.0` | 保留官方稳定版。当前已直接使用 pub.dev；不新增 fork 或本地源码副本。 |
| `pdfrx` | pub.dev `2.4.7` | `2.12.0` | 官方稳定版；先评估 2.4.8。最新 2.12.0 要求 Flutter >=3.47 / Dart ^3.13；2.4.8 仍需验证引擎及 PDFium 关联依赖。 |
| `xml` | pub.dev `6.6.1` | `7.1.0` | 官方稳定版 6.6.1。最新 7.1.0 要求 Dart ^3.12；7.0.1 也不在当前 WebDAV 的 ^6.2.2 范围内。 |
| `flutter_test` | SDK `0.0.0` | `随项目/SDK` | 随平台 SDK。Flutter / localizations / test 随对应 SDK 固定，不复制到个人仓库。 |
| `flutter_lints` | pub.dev `6.0.0` | `6.0.0` | 保留官方稳定版。当前已直接使用 pub.dev；不新增 fork 或本地源码副本。 |

**普通 hosted 包继续使用官方稳定版。** 已锁定的包不需要为了来源治理而复制源码。小批候选为 sqlite3 2.9.4、flutter_reorderable_grid_view 5.10.0、shimmer_animation 2.2.2+1、pdfrx 2.4.8；分别核验数据库、排序、动画和 PDF 引擎/原生库。intl 跟随 SDK，不使用 override 强推 0.20.3。window_manager、app_links、flutter_file_dialog、flex_seed_scheme 和 pdfrx 的最新版本已跨越当前 CI SDK 下界，SDK 升级单独评估。SQLite 3.9 的 hooks 2.2 / meta ^1.19 链与当前 meta 1.17 不相容；sqlite3_flutter_libs 0.6.0+eol 是空包，必须在 SQLite 3.x 实际加载与平台构建验收后删除旧库包。

**滚动列表是优先退出本地的候选。** 官方稳定版 0.3.8 没有 scrollControllerCallback / scrollBehavior，但已有 ItemScrollController、ScrollOffsetController 和滚动通知。应用目前直接依赖 ScrollController 的 pixels、min/max extent、自动阅读和主控制器切换，必须先用公开接口和应用适配层承接这些行为，再迁回稳定版。验收覆盖长章节跳页、像素滚动、横向/反向、自动阅读、鼠标/触控和越界切章节；不能以去掉两个参数作为完成。官方 Git `494c6abd3de44a92d34c5cbc424db2eefe3915cf` 也没有这两个定制入口，来源顺序因此仍优先稳定版。

**InAppWebView 推荐官方固定 commit 与最小平台例外。** 稳定版 6.1.5 缺应用使用的 onBrowserProcessExited。官方 `17527cae5a3371c1e87f9c1df4281a7710debf28` 已在前一轮通过主线应用分析，当前 head 仍为同一 SHA，但没有 Windows GraphicsContext 实例所有权修复。目标是主包、platform interface、Android、iOS、macOS、Web 六包采用一致官方来源，Windows 包仅保留必要的本地所有权补丁，并记录同一官方基线。若新 Linux 包加入，另核对注册和现有桌面流程。整组需完成 Windows 多窗口关闭/重建、代理、登录、Cookie 与相关平台原生构建；Windows 补丁合入官方后删除本地 override。原 fork 的个人修改是两个 Windows 文件、5 行新增/2 行删除，官方整仓演进不代表个人补丁范围。

**rhttp 必须先处理官方候选的原生安全差异。** 官方 0.16.0 / 0.18.0 使用 FRB 2.12.0，其 Rust handler 已把取消后发送失败改成日志处理；不能再只凭旧发送 panic 断言这一项永久必须本地。主线隔离替换 0.18.0 + Dart FRB 2.12.0 通过严格 API 分析。鸿蒙仍需显式 librhttp.so 加载：直接调用生成 RustLib 的隔离原型消除了参数错误，但产生一条 implementation_imports info，严格门禁没有通过。更合适的临时方案是官方包作为主线目标，鸿蒙沿用受控生成目录覆盖，仅保留必要加载接口；公共入口改善后去除该覆盖。

OSV 对完整 Cargo.lock 的版本匹配显示：当前唯一匹配为 pin-utils 0.1.0 的失维护提示 RUSTSEC-2026-0441；官方 0.16.0 有 **8 个包版本**命中公告，0.18.0 有 **10 个**，包括 h2、quinn-proto、rustls、rustls-webpki、tokio 及 0.18 新增的 zstd 系列。这里按包版本计数，GHSA/RUSTSEC 别名不重复计成漏洞数量，也不声称所有路径在每个平台可触发。官方 Git `39a3d766139c34c672561b13877438994afbb4cd` 的 rhttp/rust/Cargo.lock 与 0.18.0 归档逐字节相同，直接换官方 commit 也不能解决。当前 rustls 0.23.46 / webpki 0.103.16 等安全 pin 不能回退到候选里的旧版本。

因此 rhttp 当前仍是必要本地例外。下一步以官方 0.18.0 为比较基线，先审核更新原生锁文件、安全公告及 Rust 1.92 / iOS libc 兼容；用新编译的库验证真实取消、回调排空、退出、TLS 根证书、HTTP/2/3 与 OHOS ABI。FRB Dart、Rust crate、生成绑定和工具链清单成组对齐，再判断 CallbackDrain 是否仍必要。官方稳定版或 commit 包含这些必要修复并通过原生验收后，才切回纯官方来源。pin-utils 的失维护提示作为常规清理项，和候选的安全公告分类记录。

**PhotoView、SharePlus、WebDAV 与桌面 WebView 保留有证据的最小本地修改。** PhotoView 0.15.0 与官方 head `a13ca2fc387a3fb1276126959e092c44d0029987` 仍有 `_imageInfo = _imageInfo` 的丢弃引用路径，缺 getInitialScale / animateScale / onScaleUpdate；先上游化通用图片/控制器所有权修复，再评估应用缩放适配。SharePlus 13.3.1 与当前 Git 已有 iPad、Android IO 等修复，但 Windows 仍以引用捕获共享可变 payload、原生集合所有权仍不等价，Android 仍清理先前分享缓存；应用串行队列不能独自证明这些原生问题消失。WebDAV 官方 1.2.2 与 `5a8dd0d9a82bac86e5ed326f648c2b0871478d8f` 仍缺多认证、301、上传和取消修改；创建后设置 c.httpClientAdapter 可消除一个定制入口，但其余差异仍须独立处理。Dio 的 listenCancelForAsyncTask 在当前版本仍存在但标为 internal，不能误写成已删除的编译错误。桌面 WebView 官方兼容版 0.3.2 缺 proxy / setOnNavigation，0.4.2 还要求 Flutter >=3.44；代理、导航拦截、Linux WebKit/libsoup 和 ARM64 逐项验收后才替换，也可单独评估与 InAppWebView 合并桌面登录流程。

**项目自编模块与鸿蒙平台来源单独维护。** venera_native / venera_saf 是应用实现，继续本地维护；前者的 LodePNG 和 7-Zip C 解码子集记录官方固定来源与许可证，后者不再依赖原占位许可证包装层。native 核心升级优先已发布官方版本；现有 ABI、子集范围、端序修复、归档边界与随包声明是本地必要构建约束。

鸿蒙实际 SDK 为 CPF-Flutter 的 3.41.9+ohos-1.0.2、Dart 3.11.5，固定 `62357a93d653bf844f730bb1f4b7cc9e2139d14e`；Google Flutter 的普通稳定版不能直接提供同等 OHOS 能力。鸿蒙 WebView 为平台上游 CPF-Flutter `a281ae3272a9218760d52b95014a71a41866bd6c`，code_assets 为 openharmony-sig `9d2eaf45940e5042637b3387b18292ed39223a4a`；这些是平台实现的固定上游来源。webview_api 的类型导出今后应改为已审核的原始官方 API commit，减少对个人 fork 的间接读取。生成 HAP 锁文件同为 156 项，其中 129 hosted、22 path、5 SDK；额外 path 是受校验的构建覆盖，不代表新增 22 个个人 fork。SQLite 核心来自 sqlite.org 3.52.0 正式归档。OpenHarmony 6 SDK 已指向华为云正式归档；Harmony CI 26.0.0.851 CLI 使用社区镜像及 GitHub 资产摘要，应优先改用可取得并核验的华为正式归档/厂商校验信息，目前不能把镜像摘要标成厂商摘要或改用 API 不同的 SDK。

建议按以下阶段推进，每次更新同步声明、完整锁文件、来源清单、补丁说明、changelog 和相关鸿蒙覆盖层：

1. **先修安全与规则。** QuickJS 核心修复独立推进，不等待包装层来源迁移；当前使用的稳定安全 pin 保留。为每项非官方来源记录稳定候选、官方 commit、必要补丁、失败证据、退出条件和维护责任；现有检查器继续验证完整来源/许可证/摘要。
2. **第一批回官方稳定版。** 小批评估已 hosted 包的兼容稳定更新，并改造滚动列表的应用适配层，验证后移除其本地包。当前证据还没有证明它能只改来源通过验收。
3. **第二批缩减个人 Git 来源。** InAppWebView 整组迁向官方固定 SHA，Windows 仅保留必要本地实现；同步鸿蒙 API 导出与平台构建。该阶段可能增加一个本地平台包，但减少维护整仓 fork 的范围。
4. **清理复杂本地差异。** rhttp 安全锁文件与 FRB 生命周期验证后优先官方稳定版；PhotoView、SharePlus、WebDAV 和桌面 WebView 逐项消除或上游化必要补丁。官方 commit 确实包含修复时才使用它，不能仅改 URL。
5. **单独升级 SDK 与 native assets。** 核查 SDK 的 meta 等固定依赖后评估 QuickJS 官方 0.4.0 commit，保留 Map、TypedData、dispatch/port 所代表的真实契约并完成各平台加载/释放验收。核心修复和平台审核通过前，下一鸿蒙 pin 保持 release_enabled:false。

以上阶段不预设把本地包压到某个数量。只有补丁必要性消失并完成验证，才删除本地实现；历史 fork 留给历史构建与回滚，新的正常构建尽量引用官方来源。

本轮源码分析结果如下。隔离副本使用现有锁定 package graph，没有运行候选 Pub solver；本机为 Flutter 3.41.6 / Dart 3.11.4，不能替代 CI 的准确 3.41.4 或原生设备验收。WebDAV 包级检查不继承应用样式 lints，保留 analyzer 的内部 API 警告与弃用诊断。

| 隔离检查 | 退出码 | 诊断数 |
|---|---:|---:|
| `baseline-application` | 0 | 0 |
| `photo_view-application` | 3 | 15 |
| `scrollable_positioned_list-application` | 3 | 2 |
| `webdav_client-application` | 3 | 1 |
| `webdav_client-package` | 2 | 21 |
| `rhttp-0.16.0-application` | 3 | 1 |
| `rhttp-0.18.0-application` | 3 | 1 |
| `desktop_webview_window-0.3.2-application` | 3 | 2 |
| `rhttp-0.18.0-main` | 0 | 0 |
| `rhttp-0.18.0-harmonyos-adapted` | 1 | 1 |

QuickJS 与 InAppWebView 沿用前一轮针对相同 official head 的解析、原生 Map 探针和应用分析证据，详见[固定主线审计](https://github.com/CyrilPeng/venera-next/blob/08b1ff40e5b16c9d6cc14c9fd4be4ad5f2785c63/doc/development/remaining_git_audit_20261106.zh.md)。本轮没有把已有成功重复计算为新增原生验证。OSV 是版本级公告匹配，既有 cargo audit --deny unsound、原生 sanitizer 和平台门禁仍为实际切换条件。

机器证据保存发布归档 SHA-256、官方仓库完整 SHA、比较/分析摘要、Rust 公告与构建覆盖的来源。详细日志与采集脚本位于 build/official-dependency-audit-20261107，机器记录保存它们的摘要。未迁移依赖、未签装设备、未启用 tag/Release，不把计划与隔离原型作为完成的来源切换。
