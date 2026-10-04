# Git 依赖接管与替换审计（2026-09-28）

[English](dependency_audit.en.md) · [治理规则](dependencies.zh.md) · [机器可读清单](git_dependencies.json)

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
| `desktop_webview_window` | pub.dev 0.3.0；源码指向 `MixinNetwork/flutter-plugins` | 官方包有 Apache-2.0 许可证，但不能据此自动补齐当前 fork 的授权记录。官方 `CreateConfiguration` 没有应用使用的 proxy；当前 fork 还有 libsoup-3.0、Linux 和 Windows ARM64 修改。保留原固定来源，先追溯定制代码授权，再决定迁移。 |
| `flutter_saf` | 当前来源 `pkuislm/flutter_saf` 的 fork；pub.dev 同名 0.1.0 来自 `hamiranisahil/flutter_saf` | 当前 LICENSE 是占位文本，同名发布包虽为 MIT，但没有当前使用的 IOOverrides 机制，属于不同实现。保留原固定来源；替换必须覆盖持久目录授权、isolate 内 IO override、随机访问和后台读写。 |
| `flutter_7zip` | `wgh136/flutter_7zip` 的 fork；pub.dev 同名查询返回 404 | 当前 LICENSE 是占位文本；7Z/CB7 导入直接使用 `SZArchive.extractIsolates`，ZIP 也用它作回退。不能因已有 `archive` 依赖就移除。先核实 Dart/FFI 包装层和内嵌原生代码许可，或选取具有等价 7Z 能力的替代实现。 |
| `lodepng_flutter` | Venera 原生插件；pub.dev 同名查询返回 404 | 当前 LICENSE 是占位文本。应用使用原生编码指针和 finalizer；替换不仅是 PNG 输出，还涉及内存所有权和大图性能。保留原固定来源，评估许可证清晰的编码器，并以尺寸、透明度、像素一致性、峰值内存和耗时作为验收。 |
| `flutter_to_debian` | pub.dev 2.0.2；`jeffrey0606/flutter_to_debian`，MIT | 官方 HEAD `7bf3b03df4e0f9f38f29dab6b5b66e587074262d` 后，当前 fork 只多出 `3777c91` 的 Depends 传递修复。发布归档也缺失该传递。已用项目脚本替代，不再维护 fork。 |

## 维护责任与下一次更新

VeneraNext 维护者负责自有 fork 的补丁选择、上游变更审查和发布验证。原始上游与 Venera 的定制历史均须保留；必要时比较两条来源，不能只看最新一次提交说明。每次升级记录比较基线、完整变更范围、保留/已合并/可删除的补丁、许可证及安全公告、对应功能测试和回滚 commit。未经比较，不自动把上游默认分支同步进发布依赖。

许可证待核实的四项不新增发布、不自行套用主项目 GPL 或同名包许可证。继续处理的输入是明确覆盖定制代码和内嵌原生代码的授权材料，或者经功能与平台验证的替代实现；未向外部维护者发送消息。该限制不影响已完成的五个 fork 接管和 Debian 替换。

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
