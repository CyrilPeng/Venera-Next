# R4 本地候选验收 / Local candidate acceptance

执行日期：2026-10-10；沿用 2026-10-09 开始的批次与证据目录。代码候选为 `5b338ad9afd0a94f3c6015933cbf332b8110d25d`，本批不改变生产代码或测试；CHANGELOG 在最终验证前冻结。

R1–R3 技术收尾已提交，R4 本机验证和产物核验已完成，覆盖趋势与门禁审查关闭 P8.3。原 52 项当前为 **37 I / 14 P / 1 U**：**71.2% 是完全完成项占比，不是剩余工作量的估计**。本报告保留各次失败、实际通过范围和 15 个原未完成项；原方案尚未全部验收，P8.5 保持 P。

相对收尾方案的 `57b8c88` 基线（24 I / 27 P / 1 U），本轮四批累计关闭 **13 项**，原未完成项从 28 项减为 15 项；各批关闭依据见[批次报告](completion_batches_2026_10_09.md)。

## 输入与范围 / Inputs and scope

- 工具链：Windows / Flutter 3.41.6 / Dart 3.11.4；声明 SDK 3.41.4 未安装。主应用和独立审查工具沿用既有依赖，不升级锁文件。
- `build/optimization_completion_2026_10_09/r4-candidate-inputs.json` 保存基点、1,553 个已跟踪文件的 SHA-256/Git blob、CHANGELOG 差异、依赖与原生输入和 helper 哈希。候选清单 SHA-256：`ef784c4cc865ca206d507de514d7d98e8c4b206054d40992ee4d24671cd32471`。
- Windows/Android 在 `build/r4c` 的独立源码副本构建。只有复制的插件元数据调整本地路径，Android 使用新生成的合成签名配置；不复制个人数据或真实签名凭据。四份预置原生构建工具 runner 锁文件记入 `r4-build-tool-lock-inputs.json`。Android 另行生成的 irondash runner 未预置，其 25 项依赖版本与原工作区 runner 一致；这项构建后对照单独记入最终输入核对，不冒充预先冻结的锁文件。
- 构建副本通过 `flutter pub get --offline --enforce-lockfile` 生成非跟踪的平台接线文件；原项目和副本的 `pubspec.lock` SHA-256 均保持 `e6b05cee52f37c9d05d7e0be6cf154c7815009b139d42b17020cccb695b31d23`。`r4-generated-glue-inputs.json` 另记生成输入；`r4-nuget-inputs.json` 记录复制的 182 份固定版本 NuGet 构建依赖及工具哈希，不复制旧应用二进制。
- 所有本轮日志使用新的 `r4-*` 名称，旧 R1–R3 helper、证据和产物只读。原有 Windows/Android 的 90 份产物先记入 `r4-existing-outputs.json`；构建结束后的 `r4-existing-outputs-verified.json` 确认 90 份 SHA-256 全部未变。
- 测试仅使用隔离目录和合成数据；不启动真实应用、浏览器、安装器或外部接收程序。测试及两个平台构建串行，等待实际进程结束。

## 本轮验证 / Current validation

证据目录为 `build/optimization_completion_2026_10_09/`。所有测试和应用源码均与候选清单一致；全量结束后只补齐了副本的生成接线和原生构建环境。

| 日志/证据 | 结果及适用范围 |
|---|---|
| `r4-test-candidate-full.log/json` | 唯一全量＋coverage，786.27 秒，**4,951 通过 / 2 项既有跳过 / 1 项超时**，退出码 1；原始结果保留 |
| `r4-test-source-admission-recheck.log/json` | 只复测 `source_data_admission_test.dart` 中的 `startup returns while sources init concurrently and replacement drains both`，**1 项通过**，命令 11.78 秒；源码、断言和 5 秒超时均未改 |
| `r4-analyze-final.log` | 严格分析零诊断，analyzer 报告 28.5 秒 |
| `r4-python-format-final.log` | lib/test/tool 的 1,031 份已跟踪 Dart 文件格式检查通过，零改写；未变的 vendored packages/patch 不扩为额外格式整治 |
| `r4-python-structure-final.log` / `architecture-final.log` | 结构/架构通过；524 文件：330 业务、194 UI、0 待定，245 入口；57 条特性边不变，业务无环且不能到达 UI |
| `r4-python-unit-final.log` | 116 项 Python 检查，113 通过、3 项既有平台跳过，无新跳过 |
| `r4-python-version-final.log` / `release-final.log` / `r4-dart-git-deps.log` | v1.17.0 / build 228 版本与发布元数据、Git 依赖清单通过 |
| `r4-audit-self-check.log` / `analyze.log` / `inventory.log` | 独立 AST 工具自检和严格分析通过；扫描 524 个生产、504 个测试文件，8,202 个声明、322 个低引用候选；原始清单为 `r4-public-symbols.json`，不将名称计数当作调用图 |
| `r4-build-windows.log` / `windows-02.log` | 两次构建准备失败：首次缺复制副本的非跟踪插件接线；第二次缺原目录的 NuGet 本地配置/缓存。原日志保留，修复的是隔离构建环境 |
| `r4-python-build-windows-03.log/json` | Windows Release 构建成功，退出码 0；Flutter 1000.2 秒，外层命令 1003.53 秒；完整目录来自本次独立副本 |
| `r4-python-build-android.log/json` / `r4-android-network-interruption.json` | 首次 Android 构建在 HTTPS 依赖下载等待；线程探针确认后，受控停止本次 daemon，原命令退出 1（1717.03 秒）。日志中的 daemon disappeared 是主动中断结果，不是自发崩溃 |
| `r4-python-build-android-proxy.log/json` | 通过本机代理重试成功，退出码 0；Gradle 1692.1 秒，外层命令 1696.71 秒；生成三个 ABI APK 和一个通用 APK，依赖版本未升级 |
| `r4-python-artifacts-check.log/json` / `r4-artifacts.json` | 产物核验通过：Windows 完整 64 文件目录及 ZIP，四个 APK 的包名、版本、ABI/ELF、内嵌资产与合成签名均符合候选输入 |
| `r4-existing-outputs-verified.json` | 本轮结束后原有 Windows/Android 90 份产物 SHA-256 全部不变 |

全量失败项是源初始化/替换场景的 `Future` 5 秒超时，原输入单项复测未重现；不能由此证明并发环境永不超时。没有更改生产代码、增加跳过或延长超时，也没有追加全量。上述组合覆盖全部用例，但**不是“一次全量全部通过”**。完整平台验收仍需关注该用例的并发稳定性。

两项 Flutter 跳过来自未改动的 `test/foundation/share_file_test.dart`：Android 原生确认后清理输入、Linux 拒绝文件分享，分别仅在 Android/Linux host 执行。本机 Windows 的跳过不能替代这两个平台的运行结果。

## 覆盖率趋势 / Coverage trend

本次 LCOV 为 **40,198 / 50,542 = 79.53%**，覆盖 489 个有记录的生产文件；SHA-256 为 `ba70ea3a14bddf684846af3ad9a1050bbdc6f025ac8eedcfd05520cd23290dce`。比较已记录的 `57b8c88` 基线 **39,747 / 50,169 = 79.23%**，增加约 **0.31 个百分点**。源码范围已变化，比例变化不等于行为质量改善；未记录文件也不能按零覆盖或全覆盖推断。

`r4-coverage-summary.json` 保留逐文件、模块和相对 `57b8c88` 的变更行指标：有 LCOV 记录的新增/修改可执行行 **935 / 1,209 = 77.34%**。未覆盖变更主要在页面导航/展示、图片收藏视图和真实 headless 入口，与仍开放的完整 UI/CLI/平台边界一致，没有用总百分比替代它们。

| 核心策略或本轮装配 | 命中/记录行 | 覆盖率 |
|---|---:|---:|
| FavoritesScope | 24/24 | 100.00% |
| HistoryScope | 10/10 | 100.00% |
| LocalComicRelatedData | 17/17 | 100.00% |
| AppDataOperations | 122/123 | 99.19% |
| ReaderSession | 138/144 | 95.83% |
| DataSyncController | 801/836 | 95.81% |
| LocalFavoritesManager | 750/840 | 89.29% |
| HistoryManager | 271/311 | 87.14% |

这些指标与 R1–R3 的失败注入、真实 SQLite/QuickJS、跨实例绑定和独立 VM 恢复证据共同支撑 P8.3 的趋势审查；不是新设的全库合格阈值。

## 本地产物 / Local artifacts

Windows 最终命令为 `flutter build windows --release --no-pub`，在独立副本内退出 0。`r4-windows-version.json` 记录 `VeneraNext.exe` 的 FileVersion 和 ProductVersion 均为 **1.17.0+228**。CMake CMP0175、WebView、QuickJS、lodepng 和 zip 的原生编译警告保留在日志中，没有通过压制警告修改源码。

Android 首轮依赖下载等待的原线程证据为 `r4-gradle-thread-probe.log/json`。本机 `127.0.0.1:7897` 代理对锁定的 AGP 8.12.3 POM 返回 HTTP 200（`r4-proxy-connectivity.json`），随后仅向本次构建进程及后代传入 HTTP/HTTPS 代理与 Java 代理参数，未改变全局配置。重试期间 `r4-gradle-proxy-probe.json` 与对应线程日志确认 Gradle 已开始执行构建子任务。最终 `flutter build apk --release --no-pub --split-per-abi` 退出 0；Java 8 目标、已弃用 API 和 unchecked 插件警告保留，未为消除警告修改应用或插件。

以下文件均来自本次副本。Windows 完整目录含 **64 文件 / 61,362,967 字节**，可分发 ZIP 为 **27,326,348 字节**，并非仅复制 EXE；每个文件的哈希见[完整产物清单](../../build/optimization_completion_2026_10_09/r4-artifacts.json)。

| 本地产物 | 字节数 | 版本 / versionCode | SHA-256 |
|---|---:|---|---|
| [Windows x64 完整 ZIP](../../build/optimization_completion_2026_10_09/r4-windows-x64-release.zip) | 27,326,348 | 1.17.0+228 | `167ba37ebe7c61d102033488c8a4b69511c8bd43d7ec2746ce6e209a5e379023` |
| [Android armeabi-v7a](../../build/r4c/build/app/outputs/apk/release/VeneraNext-1.17.0-android-armeabi-v7a.apk) | 22,095,903 | 1.17.0 / 2281 | `406a59258ad8fef14a5a0e420de9e98ced8d93c741a7217f865d459fbdc6d0e1` |
| [Android arm64-v8a](../../build/r4c/build/app/outputs/apk/release/VeneraNext-1.17.0-android-arm64-v8a.apk) | 23,264,335 | 1.17.0 / 2282 | `9032a6c98f16a9041dd6ae996e5ddff8894e1446d5949a0689ecb548720662c6` |
| [Android x86_64](../../build/r4c/build/app/outputs/apk/release/VeneraNext-1.17.0-android-x86_64.apk) | 23,816,211 | 1.17.0 / 2283 | `101a17be3bcda93aa934341aaba6e0ca4fea85eba069f573897fc85d19c383ea` |
| [Android 通用 APK](../../build/r4c/build/app/outputs/apk/release/VeneraNext-1.17.0-android.apk) | 62,041,849 | 1.17.0 / 2280 | `2720ac5fce03871962d3121e8023da5875ca946f998d599871ad80dc2032df8b` |

Windows EXE 的 PE machine 为 x86_64，文件 SHA-256 为 `571994edcb5dfd223b848766fc36da095b5aafa91347e3b0b64cd6267e0aba85`。四个 APK 的包名均为 `com.github.cyrilpeng.veneranext`；使用 Android build-tools 36.1.0 的 aapt/apksigner 核对元数据与签名，逐个验证全部原生库的 ELF 架构，并确认每个 ABI 含 `libapp.so`、`libflutter.so`、`libsqlite3.so` 与 `librhttp.so`。

四个 APK 均由本轮新生成的合成证书签名，证书 SHA-256 为 `bb712ad4aed331d98b95574d2fb87583db638e3feefa403c2aee38f9fce0d263`。这证明本地产物签名有效，**不构成正式发布签名或升级安装验收**。应用与安装器均未运行。

Windows 与每个 APK 的八份内嵌资产均逐字节哈希匹配冻结源：`pubspec.yaml`、`CHANGELOG.md`、`assets/translation.json`、`assets/init.js`、`assets/app_icon.png`、`assets/tags.json`、`assets/tags_tw.json`、`assets/opencc.txt`。原有 90 份产物的最终核对见[未改动证明](../../build/optimization_completion_2026_10_09/r4-existing-outputs-verified.json)。

最终 L0 核对与 1,553 份候选源码、原生工具版本、NuGet 输入、九份交付文档的快照记入 `r4-candidate-verified.json` / `r4-inputs.json`；`r4-commit.json` 将这些只读证据绑定至实际文档提交。报告提交不改变打包资产，已经取得的测试与构建证据无需因提交号变化而重新执行。

## 删除与保留入口 / Removed and retained entries

| 范围 | 已完成的删除或替换 | 保留理由和证据 |
|---|---|---|
| 早期无调用文件/符号 | Channel、无用途的 components 聚合、原 36 个调查候选及其独占辅助链；无调用的 flutter_to_arch/io Dart 依赖 | [符号审计](public_symbol_audit.zh.md)、[逐项调查结果](investigation_resolution.zh.md)、[依赖/产物审计](dependency_artifact_audit.zh.md)保留原基点和每项用途判定；Python 使用的打包配置仍保留 |
| 本地库默认测试替换 | LocalManager.debugSkipComicSourceInit、resetForTesting、forTesting | 独立实例不替换默认所有者；原连接、目录、准入与失败清理约束保持 |
| 源仓库、图片与备份 | SourceRepositories.forTesting/debugCreateDio；ImageDownloader 的全局图片流替换/reset；ComicBackupManager 的四个可写 static 依赖和 resetOps | 用实际实例、构造/请求参数和 runtime 装配代替；生产图片配置仍需明确绑定/解绑 |
| 历史与收藏 | 两个可写 cache 注册表及 45 份测试中的 200 处赋值 | 只读 cache getter 用于观察尚未初始化的默认实例；独立 manager、FavoritesScope/HistoryScope 和实际导航参数完成注入，原生命周期可关闭/重开 |
| 重复转发与状态 | 六个 CBZ/详情测试转发、parser.runReadCode、两个图片 provider 自导入、旧动态列表快照、无用途字段和失效注释 | 测试调用真实生产规则；列表使用类型化快照与请求代数。公开 JS 名称、持久化键、SQL schema、源 key、CLI 协议和归档布局保持 |
| 必须保留的入口 | UI 聚合与 42 个 UI/导航环成员；JS 引用计数、结果接管、真实 Future/恢复/限流和拆页规则入口 | 这些入口有实际所有者、协议或诊断用途；详见[R3 审计](architecture_compatibility_completion_2026_10_09.md)。符号名计数不能证明虚调用或动态协议无用 |

R1–R3 的源码、消费者迁移、失败记录与提交绑定统一见[批次报告](completion_batches_2026_10_09.md)。本报告汇总可核对的删除清单，不依据新一轮低引用计数自动删除代码，也不将历史候选数量当作当前扫描。

新扫描仍受同名计数限制。`ReaderChapterCommentsController.loadingMore`、`Future.minTime` 和字符串扩展 `isInt` 当前未发现 lib/test 静态引用，记录为非阻断的后续用途复核；本轮不为这类新增清理候选改变已冻结的应用输入，不宣称全项目零死代码。

## 原方案仍需完成的范围 / Remaining original acceptance

以下仍属于原方案，不从验收范围中移除。环境补齐后按矩阵集中验证同一候选；只有实现或输入发生实质变化才补跑受影响门禁。

| 原条目 | 仍缺的工作或证据 | 补验条件 |
|---|---|---|
| P0.3 | 声明 SDK 和完整测试/平台矩阵 | 独立 Flutter 3.41.4 环境及对应平台 runner；本机 3.41.6 的证据不能替代 |
| P0.5 | 六类固定设备性能基线，仍为 U | 阅读切章、快速跳页、长图滚动、目录扫描、同步、批量导入；固定版本、设备、样本和构建模式，各至少三次耗时/内存，先确定波动与回退范围 |
| P2.3 | 完整真实 Flutter 无头 CLI、退出码和平台效果 | 一次性隔离环境，运行实际可执行文件及源/同步/订阅命令；当前受控 Dart 子进程和服务测试只覆盖协议层 |
| P4.4 | 原生资源启动、释放和跨重启授权 | Apple 授权、Android SAF、平台插件故障及完整应用生命周期环境 |
| P4.5 | 分享派发后的真实外部消费与平台请求生命周期 | 合成接收程序和对应平台；现有引用/暂存所有权不能证明接收者已经消费结束 |
| P4.6 | 系统终止/后台、原生关闭故障及跨文件恢复的完整矩阵 | 对应设备/runner 与可控故障注入；逻辑取消、窗口回调和独立 VM 中断不等于真实平台终止 |
| P5.7 | 方向、系统 UI、音量、全屏和插件错误面的真实效果 | Android/iOS/桌面设备或 runner，执行前后台、快速切换及失败恢复场景 |
| P6.3 | 历史无标记半成品、未完成副本修复、共享外部目录与 SAF | 明确合成旧样本及恢复策略，完成尚缺实现/兼容判定，再对相关提供者验证；不能只归为设备缺失 |
| P6.5 | 备份与恢复在完整应用和平台失败矩阵中的结果 | 真实应用装配、隔离存储/服务器、恢复重启及原生关闭故障 |
| P6.6 | 三模式/pending 的真实原生关闭和平台矩阵 | 连接/isolate/VM 所有权已验证；仍需对应平台/原生故障，R3 已完成窄接口审查 |
| P6.7 | 未完成副本续复制/修复、旧/未知提交、外部路径及断电原子性 | 旧数据合成夹具、明确恢复策略、故障与外部提供者环境；不能由新版本协作写入锁推断全部历史恢复安全 |
| P7.2 | WebView/Cookie/账户联合流程与完整应用兼容 | 最小合成源、隔离账户/服务与实际 WebView；当前 QuickJS 能力回归保留 |
| P7.5 | Apple activity 报错及剩余消费端的错误分类展示 | 对应平台及真实 UI/CLI 边界，复核失败/取消/不支持和原始异常，不用业务单测代替展示验收 |
| P8.4 | 五平台构建、安装/启动、人工场景与性能对照 | Windows/Android 本机构建只贡献编译证据；iOS/macOS/Linux 与固定设备、安装器/启动场景另需对应环境 |
| P8.5 | 原方案最终整体验收 | 已有删除清单与补验范围；依原计划“有未完成验收时不标记整项完成”，保持 P |

性能对照若只能从 `57b8c88` 开始，只能说明剩余改造的影响，不能替代原方案起点的完整对照。新性能测试、平台运行和真实账户环境不在当前合成/不启动应用的边界内擅自执行。

English: R4 records the unchanged production candidate, one full-suite/coverage attempt, the unchanged isolated passing case, static gates and successful isolated Windows/Android release builds. The 64-file Windows output and four APKs pass version, architecture, asset and signature checks; Android uses a newly generated synthetic signing key and no application was installed or launched. All 90 prior outputs remain unchanged. The original inventory is 37 I / 14 P / 1 U: 71.2% fully completed items, not a workload estimate. Missing SDK, complete CLI, platform, legacy recovery and performance acceptance remains in the 15 original items; a report alone does not complete P8.5.
