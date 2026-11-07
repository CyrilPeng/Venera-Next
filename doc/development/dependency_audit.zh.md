# Git 依赖接管与替换审计（2026-09-28）

[English](dependency_audit.en.md) · [治理规则](dependencies.zh.md) · [机器可读清单](git_dependencies.json)

最新实施见[2026-11-07 记录](official_dependency_implementation_20261107.zh.md)：当前为 2 个 Git 来源、7 个 Git 包、8 个本地包，个人 Git 来源仅剩必要 QuickJS 补丁；下文按日期保留各阶段决策。

本轮目标是控制依赖来源、减少不必要的 fork，并明确其余依赖的替换条件。基线为接管前的 `pubspec.lock`；当前 Git 依赖的完整 commit、仓库 URL 和包路径以机器可读清单为准。本地 path 包见后续更新和[治理规则](dependencies.zh.md)。审计使用固定 commit 的本地源码和 Git 历史、GitHub 仓库信息，以及当天 pub.dev 最新稳定版的发布归档。下面保留 2026-09-28 的迁移决策和已确认的不兼容项，不是完整安全审计或逐行等价证明。

## 已完成的变更

- AltStore 删除六个原版 IPA 和对应新闻，更新器仅接受本项目发布地址。README 致谢、原作者版权、旧版数据目录迁移和扩展协议保留。
- 五个依赖复用 `CyrilPeng` 下已有 fork，Git commit 保持不变；`flutter_inappwebview` 的六个平台子包一起迁移。迁移后的锁文件未升级其他应用依赖。
- `flutter_to_debian` 已由 `debian/build.py` 与系统 `dpkg-deb` 替代，连带移除仅它使用的 `mime_type`；其余版本保持不变。CI 不再全局安装 Git 打包工具，ARM64 DEB 从自己的架构目录上传。
- CI 在获取锁定依赖后运行 `dart tool/check_git_dependencies.dart`。检查直接依赖、传递 Git 包、完整 commit、resolved-ref、仓库和包路径；新增或替换依赖必须同步更新审计清单。四个许可证待核实项是显式保留项，不表示问题已解决。

## 每项依赖的判断

| 依赖 | 已核对的候选 / 来源 | 证据与决定 |
|---|---|---|
| `flutter_qjs` | pub.dev 0.3.7；源码标注 `ekibun/flutter_qjs`，MIT | 当前历史包含迁移到 QuickJS-NG（`67496e2`）、Apple 平台构建和 JS 整数 / NaN 转换修复。不是单纯 NDK 补丁。保留自有 fork；替换需验证 Promise、异常、数值、typed array、对象释放及五个平台原生构建。 |
| `photo_view` | pub.dev 0.15.0；`renancaraujo/photo_view`，MIT | 发布归档缺少项目使用的 `getInitialScale`；当前 fork 历史还增加过 `resetWithNewBoxFit`。当前 fork 还修改了 GIF、dispose、触控板与动画定位。保留自有 fork；替换需验证缩放、长按、触控板、双页、自动阅读和图片生命周期。 |
| `scrollable_positioned_list` | pub.dev 0.3.8；`google/flutter.widgets`，BSD-3-Clause | 候选没有 `scrollControllerCallback` 和 `scrollBehavior`；当前定制提交 `09e756b` 明确加入两者。保留自有 fork；替换需改造阅读器滚动控制并验证长章节跳页、自动阅读和触摸恢复。 |
| `flutter_inappwebview` | pub.dev 稳定版 6.1.5；`pichillilorenzo/flutter_inappwebview`，Apache-2.0 | 当前包为 6.2.0-beta.3 定制分支，含 `GraphicsContext` 释放修复。切换稳定版会同时改变 API 基线和多个平台实现。保留整仓 fork；先逐个平台比较，再验证网页登录、Cookie、代理、Cloudflare 流程和销毁重建。 |
| `webdav_client` | pub.dev 1.2.2；原始上游 `flymzero/webdav_client`，BSD-3-Clause | 官方 `newClient` 只有 user/password/debug 参数，没有应用传入的 adapter。当前历史另有 HTTP adapter、301、上传及多认证修改。保留自有 fork；替换需验证 RHttpAdapter、认证、重定向、目录和大文件上传。 |
| `desktop_webview_window` | 原审计候选 pub.dev 0.3.0；2026-11-06 复核 0.4.2 | 已纠正旧判断：固定提交的包目录本来就有 Apache-2.0 LICENSE，根目录检查遗漏。0.4.2 要求 Flutter >=3.44 并改变配置 API，缺少原定制公开 proxy 参数；当前 0.2.4 已迁入本地，保留 Linux／ARM64 实现并补齐 SDK 加载器与第三方声明来源。 |
| `flutter_saf` | 当前来源 `pkuislm/flutter_saf` 的 fork；pub.dev 同名 0.1.0 来自 `hamiranisahil/flutter_saf` | 当前 LICENSE 是占位文本，同名发布包虽为 MIT，但没有当前使用的 IOOverrides 机制，属于不同实现。保留原固定来源；替换必须覆盖持久目录授权、isolate 内 IO override、随机访问和后台读写。 |
| `flutter_7zip` | `wgh136/flutter_7zip` 的 fork；pub.dev 同名查询返回 404 | 当前 LICENSE 是占位文本；7Z/CB7 导入直接使用 `SZArchive.extractIsolates`，ZIP 也用它作回退。不能因已有 `archive` 依赖就移除。先核实 Dart/FFI 包装层和内嵌原生代码许可，或选取具有等价 7Z 能力的替代实现。 |
| `lodepng_flutter` | Venera 原生插件；pub.dev 同名查询返回 404 | 当前 LICENSE 是占位文本。应用使用原生编码指针和 finalizer；替换不仅是 PNG 输出，还涉及内存所有权和大图性能。保留原固定来源，评估许可证清晰的编码器，并以尺寸、透明度、像素一致性、峰值内存和耗时作为验收。 |
| `flutter_to_debian` | pub.dev 2.0.2；`jeffrey0606/flutter_to_debian`，MIT | 官方 HEAD `7bf3b03df4e0f9f38f29dab6b5b66e587074262d` 后，当前 fork 只多出 `3777c91` 的 Depends 传递修复。发布归档也缺失该传递。已用项目脚本替代，不再维护 fork。 |

## 维护责任与下一次更新

VeneraNext 维护者负责自有 fork 的补丁选择、上游变更审查和发布验证。原始上游与 Venera 的定制历史均须保留；必要时比较两条来源，不能只看最新一次提交说明。每次升级记录比较基线、完整变更范围、保留/已合并/可删除的补丁、许可证及安全公告、对应功能测试和回滚 commit。未经比较，不自动把上游默认分支同步进发布依赖。

初次审计将四项列为许可证待核实；2026-11-06 已确认桌面 WebView 包目录的 Apache-2.0 LICENSE，并纠正根目录检查遗漏。剩余三个占位许可证包需区分包装层和内嵌代码的声明，或使用经功能与平台验证的替代实现；不自行套用主项目或同名包许可证，未向外部维护者发送消息。

回滚来源迁移时同时恢复 pubspec、lockfile 和清单；回滚 Debian 替换还需恢复构建脚本及 CI 安装步骤。锁定 SHA 控制内容漂移，不保证远程仓库永远可用；自有 fork 仍应保留固定提交可达的分支/标签及仓库备份。GitHub 上同一平台内的 fork 不解决 GitHub 整体网络不可用。

## 验证记录

- 五个自有仓库均通过 GitHub API 确认默认分支 HEAD 与固定 commit 相同，并成功获取锁定依赖；WebView 共七个包的 URL 已一致。
- 本机 Flutter 3.41.6 / Dart 3.11.4：566 项应用测试通过；分析无错误/警告，24 条既有 info；Windows x64 Release 构建通过。CI 仍使用 pubspec 声明的 Flutter 3.41.4，两者不混同。
- Android：本机 JBR 21 在 GC 线程发生 JVM 原生崩溃；仅对验证进程切换至已有 Oracle JDK 17、限制两个 Gradle worker 并使用本地代理后，`assembleDebug -Ptarget-platform=android-arm64` 构建通过（788 个任务）。未修改项目 JDK 配置，未进行真机运行测试。
- Debian：Linux 容器内真实 `dpkg-deb` 构建与解包 amd64/arm64 测试通过，核对 Depends、ELF 架构、菜单入口和安装路径；使用最小 bundle fixture，不宣称完成 Linux 应用运行验证。
- Python 本机测试共 36 项，35 项通过、1 项因需要 dpkg-deb 在 Windows 跳过（已在容器单独通过）。依赖检查器另有浮动分支、来源变化、子包遗漏和新增依赖回归测试。
- macOS、iOS 与 Linux 完整应用构建尚未在本机验证，应由对应平台发布构建完成。

## 后续更新：PhotoView 本地补丁（2026-10-05）

上述 `photo_view` 判断保留为历史记录；当前来源已从 Git 改为 `path: packages/photo_view`，仍为 **0.14.0**。本地包复制自 [CyrilPeng/photo_view](https://github.com/CyrilPeng/photo_view) 的原锁定提交 `a1255d1b5945aad4b7323303ec2ecdf0c90ffc4c`，上游为 [renancaraujo/photo_view](https://github.com/renancaraujo/photo_view)。[MIT 许可证](../../packages/photo_view/LICENSE)、版权、包 manifest 和原 fork 接口保留；没有切换到此前审计的 pub.dev 0.15.0。

新增补丁仅修复尺寸监听器未释放 `ImageInfo` 克隆的缺陷，并将三处已弃用调用等价更新为 `TickerMode.valuesOf(context).enabled`、`translateByDouble(dx, dy, 0.0, 1.0)` 和 `scaleByDouble(s, s, s, 1.0)`。后者保持锁定 vector_math 2.2.0 的原标量分支语义。16 个 Dart 源文件中仅三个在格式化归一后有差异；[LOCAL_PATCHES.md](../../packages/photo_view/LOCAL_PATCHES.md) 保存源文件 canonical LF Git blob SHA-256、差异说明、维护责任及回滚要求。其他 **156** 个依赖完整锁定记录和 SDK 锁定保持不变。

验证记录：真实 PhotoView 的缓存与异步图片所有权两项回归在原源码上失败、修复后通过；覆盖帧替换、卸载、尺寸及缩放。包和回归测试的严格分析、格式检查、来源比较以及 `dart tool/check_git_dependencies.dart` 均通过。新的真实阅读器退出集成回归还覆盖可见图片的原始文件读取、native 帧等待、强制卸载和退出失败后的 PhotoView/连续模式恢复。此更新的局部验证不替代历史记录之外的平台完整构建。

`photo_view` 已移出仅用于当前 Git 依赖的机器清单，来源记录迁至本地补丁文档。`.github/workflows/pr_build.yml` 已覆盖 `packages/`，无需更改构建触发规则。恢复 Git 来源需同步恢复依赖声明、锁文件及清单，并验证图片生命周期。

## 后续更新：首批 Git 依赖迁入本地源码（2026-11-06）

上述保留 fork 的决定仍作为历史审计证据。当前 `scrollable_positioned_list 0.3.8+1` 从 `CyrilPeng/flutter.widgets` 的 `09e756b1f1b04e6298318d99ec20a787fb360f59` 同名子目录迁入 `packages/scrollable_positioned_list`，`webdav_client 1.2.2` 从 `CyrilPeng/webdav_client` 的 `2f669c98fb81cff1c64fee93466a1475c77e4273` 迁入 `packages/webdav_client`。两个 BSD-3-Clause 许可证、版权、运行时源码和定制接口保留，版本与依赖约束不变。

每个包新增 `LOCAL_PATCHES.md` 和 `UPSTREAM_MANIFEST.json`，记录原 Git blob 校验值、审核后的本地摘要、保留文件范围、SDK 等价调用与回滚要求。同版本格式化后，滚动包 9/12、WebDAV 包 8/11 个运行时文件与原来源一致，其余三个文件各有明确记录的兼容处理；包级分析策略保留，应用严格分析门禁不变。

机器清单从仅管理 Git 来源扩展为同时管理 6 个 Git 来源和 5 个本地包。既有 PhotoView、SharePlus、Rhttp 的原始 commit／发布归档摘要及补丁说明也纳入检查。检查器拒绝未审核的本地直接依赖、覆盖项、传递包、路径／版本漂移、许可证或补丁文档缺失、真实路径越界，以及首批包未登记的源码变更。

迁移保留历史 fork 作旧版本构建与回滚来源，没有归档或删除远端仓库。QuickJS、WebView 和四项许可证待核实来源仍保持既有固定版本；此更新不修改冻结候选来源、原生桥接版本或发布资产。当前治理规则和本地维护方式以 [dependencies.zh.md](dependencies.zh.md) 为准。

## 后续更新：PNG／7z 包装层替代（2026-11-06）

上表中两个占位许可证包装层的保留决定现已完成替代。`lodepng_flutter` 和 `flutter_7zip` 不再是当前依赖；自编 `packages/venera_native 1.0.0` 以项目 GPL-3.0-or-later 维护 Dart API、C ABI 和平台构建，没有复制旧包装层并重新授权。PNG／7z 阶段清单为 **3 个 Git 来源、9 个 Git 包、7 个本地包**；其余 **155** 项完整锁定记录和 SDK 锁定保持不变。

- LodePNG：官方 `lvandeve/lodepng@79a61c79cc62814f315661f53a026004bac80614`，版本 20241015，Zlib；`.cpp` 原样改名为 `.c` 编译，保留完整版权。原固定插件仅在 C 文件附加 `freePtr`、在头文件增加导出声明，新桥接使用自己的 ABI。
- 7z：官方 `ip7z/7zip@e5431fa6f5505e385c6f9367260717e9c47dc2ee`，版本 24.09；34 个原 runtime C／header 文件逐项匹配，另收纳官方 `7zVersion.h` 声明。仅收纳明确声明 public domain 的 C 解码子集，不包含整个 7-Zip 或旧 Dart／构建包装层。
- 新桥接：PNG 返回独立字节后释放原生分配；7z 初始化失败时也关闭资源，一个 worker 复用 solid block，Windows 文件路径使用 UTF-8 → UTF-16，所有输出路径在写入前检查，CRC／长度或缺失文件名元数据时失败。原 ZIP／7z／Dart ZIP 回退保留。

官方 [7-Zip 历史记录](https://www.7-zip.org/history.txt)已复核至 26.05（固定对比提交 `b88c6bc09339de32f7d18bbab900686b244f42ba`）。后续 XZ、其他归档 handler 和 C++ 链接提取的公告不能直接套用到本包所编译的 C 解码子集；这些实现未收纳，链接条目由新桥接拒绝。`Lzma2Dec.c/.h` 与 26.05 无差异，`LzmaDec.c` 的比较涉及等价临时变量写法；`7zArcIn.c` 另有头部计数、重复属性和边界检查加固。本轮保持算法版本，并在桥接中补齐缺失名称元数据的防护与独立回归；后续核心升级须单独比较这些头部路径，不能据此声称完成了所有输入的安全审计。

本地清单记录 115 个文件，区分项目自编代码、两个独立来源和二进制夹具。CI 核对全部支持平台的原生导出、ABI 和分发声明，运行 C ABI 的 ASan／UBSan、真实 RGBA／alpha／typed view、solid／non-solid／Unicode／空文件以及损坏、越界、链接、失败后重试回归。PNG A/B/A 探针比较同一宿主上的旧／新／旧库，实测记录和限制见本地维护文档。冻结鸿蒙 `1.18.3+244` 来源与资产保持原样，下一候选另行同步。

## 后续更新：SAF 包装层替代（2026-11-06）

历史表中 `flutter_saf` 的保留决定已由自编 `packages/venera_saf 1.0.0` 替代。原插件的占位许可证源码没有被复制或重新授权；新的 Dart／Kotlin／JNI 与 C++ 句柄实现由项目以 GPL-3.0-or-later 维护。当前 **2 个 Git 来源、8 个 Git 包、8 个本地包**；其余 **155** 项锁定记录及 SDK 不变，历史 fork 留供旧构建。

本轮验证重点是保存路径和持久授权、含 `/` 的根 ID、授权撤销及 authority 歧义、原 PFD 的提交／关闭生命周期、跨 isolate 两阶段交接、64 位稀疏文件、流取消、错误清理与 PDF worker 退出。完整来源清单、接口限制和验证方式见 `packages/venera_saf/LOCAL_PATCHES.md`；真实 Android fixture 与混淆 Release 由 `tool/saf_provider_probe` 和 CI 重复验证，外部云盘的具体限制继续按 provider／设备记录。

PNG／7z 的 #148 已通过 Android／TV、Windows、Linux、macOS、iOS、完整 Flutter 与 Linux ASan／UBSan 并合并。UBSan 检出的 `CpuArch.h` 未对齐读取采用原核心逐字节路径修复，固定官方摘要与本地补丁摘要分别保留；未降低 sanitizer 或 ABI 门禁。冻结的 `1.18.3+244` 鸿蒙 selector 与资产保持原来源。

## 后续更新：剩余两项完整审计与鸿蒙候选（2026-11-06）

完整比较、2092 条文件变化记录、当前官方候选的实测及安全公告判断见[剩余 Git 依赖审计](remaining_git_audit_20261106.zh.md)和[机器证据](remaining_git_audit_20261106.json)。当前仍为 2 个 Git 来源／8 个 Git 包／8 个本地包。QuickJS 官方 Git 已有支持 Dart 3 的未发布 0.4.0；本轮实际 solver 和 Map 契约失败，不能沿用“官方都不支持 Dart 3”的旧概括。InAppWebView 的个人补丁仅两个 Windows 文件，官方 master 的大范围演进另行登记。

固定 QuickJS 核心的真实来源已匹配到 2025-01-18 的 QuickJS-NG `d07f6b5`。本轮核对 10 项公开 GHSA 并找到多项需修复的源码模式，完整条件和当前 Dart buffer API 的边界逐项记录；保留包装层 API 的决定不替代核心修复。下一鸿蒙来源已同步主线 `55c7c44` 的八个本地包和新原生库，使用独立 >=245 预览 pin，保持 `release_enabled: false`；旧 244 pin、锁文件和 Release 资产保持冻结。
