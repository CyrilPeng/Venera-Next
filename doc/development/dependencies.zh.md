# 依赖治理

English version: [dependencies.en.md](dependencies.en.md)

本文记录 VeneraNext 的依赖治理规则，覆盖不来自 pub.dev 的 Git 依赖和仓库内本地源码包。`pubspec.lock` 是构建复现依据，但不能替代依赖来源和维护责任说明。

全部直接依赖的迁移前核查见[2026-11-07 官方来源方案](official_dependency_plan_20261107.zh.md)；当前已实施来源、未采用候选和验证证据见[本轮实施记录](official_dependency_implementation_20261107.zh.md)。

## 基本规则

接管进度和逐项替换条件见[依赖审计记录](dependency_audit.zh.md)。[统一清单](git_dependencies.json)的 `repositories` 记录当前 Git 来源及全部传递 Git 包，`local_packages` 记录本地路径、版本、上游、不可变来源、许可证与补丁文档；修改任一类依赖时同步更新清单，并运行 `dart tool/check_git_dependencies.dart`。

- 同时提交 `pubspec.yaml` 和 `pubspec.lock` 的相关变更。
- 来源按以下顺序选择：满足功能、SDK、许可证与安全要求的官方稳定发布版；稳定版尚未包含所需修复时，使用已验证的官方完整 commit；两者均不能满足要求时，才保留必要的本地补丁或既有 fork。
- 优先用应用适配层和官方公开接口消除定制。必须修改依赖源码时，仅保留必要范围，由应用提交固定内容；避免为每个小包新增独立 fork。项目自编模块单独记录，不要求改成同名第三方包。
- 每项第三方本地或 fork 例外必须记录已比较的官方稳定版与官方 commit、必要补丁、失败/验证证据、退出条件及维护责任。官方版本覆盖补丁并通过验收后，重新选择官方来源；不得为回归官方而丢失现有安全修复。
- 本地包必须记录原始上游、完整来源 commit／发布归档 SHA-256、版本、保留的许可证及校验值、维护原因和 `LOCAL_PATCHES.md`；不能通过改为 `path` 绕过来源审查。
- Git 依赖必须固定到不可变 commit，不能使用默认分支、`main` 或 `HEAD`。
- 发布工作流中通过 `dart pub global activate` 使用的工具也必须固定到同一 commit。
- 升级依赖时检查上游变更、安全公告、许可证、平台构建和相关测试。
- 发布到 pub.dev 不能替代安全维护；发布前仍需完成差异审计和上游同步计划。

## 当前 Git 依赖

2026-09-28：五个依赖曾改用 `CyrilPeng` 下的现有 fork，固定 commit 不变。2026-10-05 起，PhotoView 改为本地包；2026-11-06，滚动列表、WebDAV 和桌面 WebView 也曾收纳为本地包，PNG／7z 和 SAF 包装层由自编模块替代。2026-11-07，滚动列表回归官方 pub.dev 0.3.8，InAppWebView 六包改为同一官方完整 commit，Windows 单包保留实例所有权补丁。当前为 2 个独立 Git 来源、7 个 Git 包、8 个本地包；个人 Git 来源只剩必要的 QuickJS。回滚时同步恢复声明、锁文件和对应清单记录。

必要的 fork／本地补丁选择、上游审查和验证由 VeneraNext 维护者负责；官方 Git 包也核对真实检出 HEAD、子目录及源码状态。保留原作者版权和许可证；来源归属不代替安全验证。

| 依赖 | 当前 commit | 上游 / 许可证 | 来源选择与必要补丁 |
|---|---|---|---|
| `flutter_qjs` | `f5a1f20d08c33b0a6b3e38eda2a7b27705420620` | `ekibun/flutter_qjs` / MIT | 既有必要 fork；保留 Map／TypedData／dispatch／port 契约，已回移适用的 d07 核心安全修复。官方 0.4.0 当前解析与 Map 探针失败 |
| `flutter_inappwebview` | `0aaf7a0bfc01d61a4d1453cefb57fb6783b6e676` | `pichillilorenzo/flutter_inappwebview` / Apache-2.0 | 六包直接使用官方来源；稳定版 6.1.5 缺浏览器退出事件，Windows 实例所有权补丁仅保留在本地单包 |

上表是当前来源选择摘要；完整比较与候选验证见上述官方来源核查及其固定主线审计链接。每次升级 Git 依赖时，应在 PR 中补充上游仓库、对比范围、全部定制修改、上游 PR（如有）、安全影响、退出条件和回滚方式。

`desktop_webview_window` 的包目录已有 Apache-2.0 许可证，已纠正此前根目录检查的遗漏并随本地源码保留第三方声明。PNG／7z 已采用自编桥接和许可证明确的官方核心。原 `flutter_saf` 已由项目自编的 `venera_saf` 替代，保留历史路径与系统持久授权，不复制占位许可证包装层的源码。

## QuickJS 数值缓冲引用扫描修复（2026-10-31）

本轮将固定提交从 `8feae95df7fb00455df129ad7a0dfec1d0e8d8e4` 更新为 `295f77421eedff356a02e92987181b525970c780`，维护在现有 fork 的 `venera-next-pinned` 分支，应用仍固定到完整 commit，不跟随分支浮动。
[完整差异](https://github.com/CyrilPeng/flutter_qjs/compare/8feae95df7fb00455df129ad7a0dfec1d0e8d8e4...295f77421eedff356a02e92987181b525970c780)仅包含 `lib/src/ffi.dart` 的 `TypedData` 提前返回、对应回归和依赖 changelog；许可证、包版本 0.3.7、原生代码、NDK／CMake 及平台配置不变。未声明未经确认的上游 PR。

原 `JSRef._callRecursive` 把 `Uint8List` 当作普通列表复制并逐个扫描，而纯数值缓冲不可能包含 JS 引用。跳过这一类数据可以消除 Promise 字节回传的无用遍历；普通列表／映射、别名、环、回调引用和异步完成协议保持原样，不关闭用户处理、不改写脚本，也不是零复制改造。
[阅读诊断记录](reader_diagnostics.md)保留独立副本的 A/B/A 对照及测量边界；依赖自身新增 2 项缓冲／循环图回归，应用侧覆盖处理结果、取消、异常、worker 和引用释放。宿主通过不替代 Android 原设备复测或各平台构建，#125 不因此自动关闭。

这不是 QuickJS 引擎安全版本升级，不解决既有上游来源记录债务；本次差异不增加权限或网络能力。回滚时一起恢复 `pubspec.yaml`、`pubspec.lock`、`git_dependencies.json` 及当前依赖表中的原 pin，并重新验证读取／处理生命周期，不能通过修改全局 Pub 缓存回滚。

## 本地源码包与首批迁移（2026-11-06）

| 本地包 | 当前版本 | 应用内路径 | 不可变来源基线 |
|---|---|---|---|
| `photo_view` | 0.14.0 | `packages/photo_view` | 原 fork commit `a1255d1b5945aad4b7323303ec2ecdf0c90ffc4c` |
| `share_plus` | 12.0.2 | `packages/share_plus` | pub.dev 12.0.2 发布归档与 SHA-256 |
| `rhttp` | 0.15.1 | `packages/rhttp` | pub.dev 0.15.1 发布归档与 SHA-256 |
| `flutter_inappwebview_windows` | 0.7.0-beta.3 | `packages/flutter_inappwebview_windows` | 官方 commit `0aaf7a0bfc01d61a4d1453cefb57fb6783b6e676` 的 Windows 包及必要实例所有权补丁 |
| `webdav_client` | 1.2.2 | `packages/webdav_client` | 原 fork commit `2f669c98fb81cff1c64fee93466a1475c77e4273` |
| `desktop_webview_window` | 0.2.4 | `packages/desktop_webview_window` | 原 fork commit `7801fc582ecf5a7351632887891ecf309a7b2583` 的包子目录 |
| `venera_native` | 1.0.0 | `packages/venera_native` | 项目提交固定自编桥接；第三方核心独立固定官方 commit |
| `venera_saf` | 1.0.0 | `packages/venera_saf` | 项目提交固定自编 Dart／Kotlin／JNI 与原生句柄实现 |

上表为当前本地包；首批滚动包已于 2026-11-07 退役，其历史源码和摘要保留在原提交。2026-11-06 的首批迁移曾保留滚动列表与 WebDAV 的运行时源码、manifest、BSD-3-Clause 许可证及版权，相关原始记录继续供旧构建核对。当前滚动控制使用应用适配器与官方公开接口，WebDAV 的 adapter、认证、重定向及上传补丁仍保留本地。

两个包的 `UPSTREAM_MANIFEST.json` 保存原固定提交的 canonical LF Git blob SHA-256 和审核后的本地文件 SHA-256。检查器验证源码清单的来源与统一清单一致、文件摘要匹配、全部 `lib/` Dart 文件已登记。已有三个本地包继续沿用各自详细的补丁／原始归档记录，并新增统一的声明、来源、许可证和文档检查。

所有本地包的声明和锁文件路径必须一致，锁文件使用相对路径；包 manifest 的名称／版本须与清单相同。文件的真实路径须留在审核包目录内，许可证按 canonical LF 字节校验，补丁文档必须保留版本和来源摘要。未登记的直接依赖、覆盖项或传递本地包均使检查失败。`path` 包的内容由应用 Git 提交固定，不能仅凭锁文件中的路径保证源码不变。

修改本地包时同步更新补丁记录、清单及适用的本地文件摘要，比较上游变更，运行严格分析和受影响的功能回归。恢复 Git 来源时一起恢复声明、锁文件和清单中的 Git 条目。现有历史 fork 保留作旧版本构建和回滚来源；SAF 使用项目自管实现，既有目录授权和存储引用继续保留。

## PhotoView 初次本地迁移记录（2026-10-05）

以下保留初次迁移范围；后续生命周期和缩放补丁以本地 `LOCAL_PATCHES.md` 为准。

`photo_view` 通过 `path: packages/photo_view` 使用仓库内的 [本地包](../../packages/photo_view/pubspec.yaml)，版本仍为 **0.14.0**。来源是 [CyrilPeng/photo_view](https://github.com/CyrilPeng/photo_view) 的原锁定提交 `a1255d1b5945aad4b7323303ec2ecdf0c90ffc4c`，上游为 [renancaraujo/photo_view](https://github.com/renancaraujo/photo_view)。原作者版权和 [MIT 许可证](../../packages/photo_view/LICENSE) 保持不变；VeneraNext 维护者负责本地补丁和后续上游比较。

[LOCAL_PATCHES.md](../../packages/photo_view/LOCAL_PATCHES.md) 记录原始 Git blob 的 SHA-256、保留文件范围和验证方式。补丁修复尺寸监听器丢弃 `ImageInfo` 克隆造成的泄漏：读取尺寸后在 `finally` 释放克隆，绘制监听器继续独立管理自己的图片。为适配当前 SDK，另有三项等价调用替换：

- `TickerMode.of(context)` → `TickerMode.valuesOf(context).enabled`。
- `translate(dx, dy)` → `translateByDouble(dx, dy, 0.0, 1.0)`。
- `scale(s)` → `scaleByDouble(s, s, s, 1.0)`，保留原来的三维缩放及齐次坐标。

这次迁移保留原 fork 的阅读器接口和行为，未切换到 pub.dev 版本。除上述三个源文件外，其余 Dart 源码经格式化归一后与来源一致；包版本、manifest 依赖、其他 **156** 个锁定依赖记录及 SDK 锁定均未改变。初次迁移时，`photo_view` 从当时仅管理 Git 依赖的清单移出；2026-11-06 起重新纳入统一清单的 `local_packages`，详细来源与补丁记录继续保留。依赖解析使用与锁文件一致的 `PUB_HOSTED_URL=https://pub.dev`，并执行 `flutter pub get --offline --enforce-lockfile`。

真实 PhotoView 回归覆盖缓存命中与异步首帧、帧替换、卸载释放、适配尺寸和缩放。PR 构建规则已覆盖 `packages/`，此包修改会触发现有平台验证，无需单独调整规则。恢复 Git 来源时必须一起恢复 `pubspec.yaml`、`pubspec.lock` 和 Git 清单，并重新验证图片生命周期。

## 本地 Rhttp 的 Rust 安全维护

`packages/rhttp` 保留本地取消回调补丁及 `flutter_rust_bridge =2.11.1`；Rust 传递依赖的来源、版本和安全公告记录在 [LOCAL_PATCHES.md](../../packages/rhttp/LOCAL_PATCHES.md)。项目与 CI 固定 Rust 1.92.0，满足当前安全修复依赖的最低编译器要求。

Dependabot 每周检查 `/packages/rhttp/rust`。Rust 桥接 crate 的升级需要与 Dart 依赖和生成代码一起验证，因此不自动单独升级。完整 Rust 锁文件在 PR、主分支推送、手动触发及每周任务中由[依赖安全工作流](../../.github/workflows/dependency_review.yml)扫描，已知漏洞和 `unsound` 内存安全告警都会使扫描失败；这项检查同时覆盖已存在于锁文件中的依赖。

本地执行相同检查：

```sh
cargo install cargo-audit --version 0.22.2 --locked --no-default-features
cargo audit --file packages/rhttp/rust/Cargo.lock --deny unsound
```

更新锁文件后须重新构建 Rhttp 原生库，再运行取消回调和 Flutter 网络回归，避免测试加载旧 DLL。工具链变更同时更新 `rust-toolchain.toml` 和 `.github/scripts/prepare_rust_toolchain.py`，并验证各平台构建。

## 上游化流程

1. 将当前 commit 与上游对应版本进行差异比较。
2. 将可通用的修改拆成最小 PR 提交上游。
3. 对无法上游化的修改补充本仓库维护说明和测试。
4. 上游发布安全修复后，先更新 fork，再更新本项目锁定 commit。
5. 连续失去维护且无法替代的依赖应记录风险，不应无声切换到浮动分支。

## 审查清单

- [ ] `pubspec.yaml` 使用固定 commit，未出现 `HEAD` 或默认分支。
- [ ] `pubspec.lock` 的 resolved commit 与声明一致。
- [ ] 本地依赖的路径、版本、上游、来源摘要、许可证和补丁记录已同步；适用的源码清单与本地文件摘要已更新。
- [ ] 发布工作流中的 Git 工具使用相同 commit。
- [ ] 已运行 `flutter pub get --enforce-lockfile`、`flutter analyze --no-pub` 和 `flutter test --no-pub`。
- [ ] 已运行平台构建，或说明无法运行的平台及原因。
- [ ] 已检查许可证、安全公告和上游变更记录。

## 桌面 WebView 本地维护（2026-11-06）

`desktop_webview_window 0.2.4` 保留固定提交的桌面代理、Linux WebKit／libsoup 和 Windows ARM64 实现。原包目录已有 Apache-2.0 LICENSE；此前仓库根目录检查将其误记为未声明许可证，现已纠正。Microsoft WebView2 的 x64 1.0.992.28 与 ARM64 1.0.3124.44 加载器及导入库均与官方 NuGet 归档逐字节一致，归档摘要、匹配条目及 LICENSE／NOTICE 见本地 `NATIVE_ARTIFACTS.json` 和 `licenses/`；原 WIL 与 strconv 声明保留。

官方 0.4.2 已核对发布归档，但要求 Flutter >=3.44.0，并改变配置／标题栏 API，缺少原定制公开 proxy 参数。本轮以来源迁移为范围，维持应用 Flutter 3.41.4 和包版本。维护与回滚方式见 `packages/desktop_webview_window/LOCAL_PATCHES.md`。

本地清单的 `source_directories` 声明需审核的全部原生目录；二进制源码条目使用 `encoding: binary` 和原始字节摘要，其余文件继续使用 canonical LF 校验。目录内新增文件、链接或未审核内容均使检查失败。

## PNG／7z 自管桥接（2026-11-06）

`packages/venera_native 1.0.0` 替代两个占位许可证包的 Dart／FFI 包装层和平台构建文件。新包装层由项目编写，以 GPL-3.0-or-later 维护；没有复制旧包装层并重新贴许可证。原生算法分别来自官方 LodePNG `79a61c79cc62814f315661f53a026004bac80614`（20241015，Zlib）和 7-Zip `e5431fa6f5505e385c6f9367260717e9c47dc2ee`（24.09，所收纳 C 解码子集在各文件头明确声明 public domain）。后者的声明仅适用于收纳的文件，不能外推到整个 7-Zip 仓库。完整来源、原始文件名、摘要和保留声明见本地 `SOURCE_MANIFEST.json` 与 `LOCAL_PATCHES.md`。

项目自编包的 `source.type: project` 必须有完整源码清单、许可证及维护文档；第三方目录必须逐项登记独立固定来源和许可证，文件不能重新标为项目自编。Android APK 核对每个 Flutter ABI 的原生库、实际导出和 assets 声明；Windows／Linux 检查加载后的导出，Apple 检查 framework 导出、ARM64 和应用包内声明。CI 同时执行独立 C ABI 的 ASan／UBSan 回归和完整平台构建。Windows 图片／JS 生命周期测试可通过 `VENERA_NATIVE_TEST_DIRECTORY` 加载本次 Debug bundle，避免只查历史 Release 目录造成假跳过。

PNG 保留算法与参数，验证 RGBA／alpha 和带偏移的 typed view，返回独立 Dart bytes 后释放全部原生分配。7z 使用一个后台 isolate 拥有并关闭归档，复用 solid block；写入前检查全部路径、重复名、目录冲突和链接，解码时检查 CRC 与长度。密码保护或未支持的压缩方法明确失败；应用原有 ZIP → 7z → Dart ZIP 回退保留。

`tool/native_png_probe.py` 使用同一 RGBA 输入执行原库／新库／原库的 A/B/A，对比编码字节、耗时与宿主进程 RSS。其峰值 RSS 是同一进程累计峰值，不能视为单次编码独立峰值；本探针不测 Android 帧率或功耗。改变算法版本须单独比较官方修复、更新来源／摘要，并重新运行像素、归档、内存安全和平台回归。历史 fork 仍供旧构建使用；冻结的 `1.18.3+244` 鸿蒙来源与资产不随本轮迁移改变。

## Android SAF 自管实现（2026-11-06）

`packages/venera_saf 1.0.0` 以项目自编的 GPL-3.0-or-later 实现替代占位许可证插件。源码、许可证、平台构建和维护说明由完整 `SOURCE_MANIFEST.json` 管理，不包含原包装层源码；迁移后为 **2 个 Git 来源、8 个 Git 包、8 个本地包**，其余 **155** 项锁定记录及 SDK 不变。

已有 `android://<treeDocumentId>/<display names>` 路径与 Android 持久 URI 授权继续使用。树 ID 中的 `/` 以最长完整授权根解析；已见的较长授权被撤销时明确报错，避免改按较短根访问。不同 provider authority 的同一根 ID、缺失文件、未授权与 provider 不可用分别处理；名称通过 UTF-8 JSON 传递，保留中文、emoji、冒号和 `|`。

原 `ParcelFileDescriptor` 保持到最终关闭，原生 64 位读写、定位、长度、截断与 flush 不通过 JNI 拷贝数据。跨 isolate 文件采用 retain／ack／sender release／adopted 交接，调用方取得文件前释放 worker 的 lease；generation token 防止误关复用的 FD。worker 幂等启动、保留异常栈并在 dispose 时 drain；流取消和 PDF 子 isolate 的失败路径关闭输出及 worker。显式关闭传播 provider 错误，清理保留主读写错误。

创建已有文件不截断内容，重命名限同目录并检查已有目标，授权根受保护；原子独占创建、createTemp、watch、文件锁及设置时间等不支持的接口明确失败。provider API 的跨应用竞态和各云盘限制不能被通用接口消除。

宿主回归、200 轮 C++ 句柄／错误／复用测试与 >2 GiB 稀疏文件检查纳入验证；CI 执行 ASan／UBSan、完整 Android／TV 构建、13 个原生／JNI 导出及随包声明核验。`tool/saf_provider_probe` 的两个隔离 APK 和混淆 Release 消费端验证真实 DocumentsProvider、持久授权、重启、Unicode、读写模式、流取消、关闭回调与错误。详细语义和维护方式见 `packages/venera_saf/LOCAL_PATCHES.md`，外部云盘仍按具体 provider／设备补充验收。
