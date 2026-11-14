# 测试整理基线与实施记录（2026-11-13）

本记录配合[实施方案](test_reorganization_plan_20261113.zh.md)使用。基线应用源码、测试和依赖为 `482810df369d126e4011be31d64408e33aede76f`；后续方案提交 `2928035c` 只增加文档，相关运行代码仍与基线一致。

## 1. 已取得的证据

- [原主线质量运行](https://github.com/CyrilPeng/Venera-Next/actions/runs/43340757021)成功，已下载其 `dart-coverage` 原始产物并按源码路径与行号统计。
- [方案提交质量运行](https://github.com/CyrilPeng/Venera-Next/actions/runs/43349524153)成功；同提交依赖审查、平台门禁和[鸿蒙 HAP](https://github.com/CyrilPeng/Venera-Next/actions/runs/43349524288)亦成功。文档改动的 Windows／Android 冒烟任务按现有触发规则跳过，由平台汇总门禁明确接受。
- 清单批次 `fe7202d3` 的[质量运行](https://github.com/CyrilPeng/Venera-Next/actions/runs/43355057150)、[平台构建](https://github.com/CyrilPeng/Venera-Next/actions/runs/43355057153)、[鸿蒙 HAP](https://github.com/CyrilPeng/Venera-Next/actions/runs/43355057118)及依赖审查全部成功，已保存 default／TV 原始 machine 事件和同批 LCOV。
- S1 修复后的 `d509e676` 的[质量运行](https://github.com/CyrilPeng/Venera-Next/actions/runs/43366256286)、[平台构建](https://github.com/CyrilPeng/Venera-Next/actions/runs/43366256320)、[鸿蒙 HAP](https://github.com/CyrilPeng/Venera-Next/actions/runs/43366256383)及依赖审查全部成功；Windows 实际加载全部 101 文件／1,461 项：1,457 通过、4 跳过、0 失败，wall 为 458.797 秒，原生启动和应用启动 smoke 继续通过。两次此前失败保留如下，未通过重试隐藏。
- S2 的 `20907e3b` 的[质量运行](https://github.com/CyrilPeng/Venera-Next/actions/runs/43369464514)、[平台构建](https://github.com/CyrilPeng/Venera-Next/actions/runs/43369464541)、[鸿蒙 HAP](https://github.com/CyrilPeng/Venera-Next/actions/runs/43369464544)与依赖审查全部成功。Linux default 仍为 6,062 项（5,907 通过／155 跳过），TV 89 项全部通过，Windows 仍为 1,461 项（1,457 通过／4 跳过）；wall 分别为 1,146.943、29.057、446.437 秒。同源码 LCOV 为 45,648／55,832：记录集合无变化、没有丢失原命中，本次新增 7 行命中，后续比较继续保留逐行集合。
- S3 的 `84283d19` 的[质量运行](https://github.com/CyrilPeng/Venera-Next/actions/runs/43373965316)、[平台构建](https://github.com/CyrilPeng/Venera-Next/actions/runs/43373965317)、[鸿蒙 HAP](https://github.com/CyrilPeng/Venera-Next/actions/runs/43373965381)与依赖审查全部成功。Linux 仍为 6,062 项（5,907 通过／155 跳过，917.466 秒），全局名称 Counter 相同；TV 89 项通过（21.810 秒）。Windows 115 文件／1,502 项（1,498 通过／4 跳过，413.703 秒）；五个原有文件新增 41 项实际执行。HAP host 77 文件／1,175 项（1,135 通过／40 跳过，175.532 秒），独立 SDK、必需宿主库与 `runtime_verified:false` 保留。
- S3 同源码 LCOV 为 45,637／55,832，记录集合一致。阅读器没有丢失命中；唯一丢失的六行集中在未改动的 `lib/network/rhttp_stream_request.dart` 的活动原生请求取消闭包（394、396、397、398、401、403），新增两行在布局构造和同步冲突异常构造。现有相关用例仍通过，I 批次继续核查实际取消时机并补足稳定的活动请求保障，不能将全局命中下降写成完全一致。
- S4 下载 `5f7130a4` 的[质量运行](https://github.com/CyrilPeng/Venera-Next/actions/runs/43389957215)、[平台构建](https://github.com/CyrilPeng/Venera-Next/actions/runs/43389957176)、[鸿蒙 HAP](https://github.com/CyrilPeng/Venera-Next/actions/runs/43389957388)和[依赖审查](https://github.com/CyrilPeng/Venera-Next/actions/runs/43389957293)全部成功。Linux 575 文件／6,062 项（5,907 通过／155 跳过），完整名称及结果 Counter 与原基线一致；Windows 118 文件／1,502 项（1,498 通过／4 跳过），TV 89 项全部通过，HAP host 80 文件／1,175 项（1,135 通过／40 跳过）。原始 machine 时轴分别为 1,195.398、406.233、27.471 和 172.739 秒；执行器测量的墙钟分别为 1,214.747、408.735、28.860 和 175.852 秒，两类口径分别保留。LCOV 为 525 文件、45,641／55,832 行，记录及命中集合与原基线一致；这不改变 S3 已记录的单次波动结论。
- S4 同步 `fa494135` 的[质量运行](https://github.com/CyrilPeng/Venera-Next/actions/runs/43396095377)、[平台构建](https://github.com/CyrilPeng/Venera-Next/actions/runs/43396095396)、[鸿蒙 HAP](https://github.com/CyrilPeng/Venera-Next/actions/runs/43396095409)和[依赖审查](https://github.com/CyrilPeng/Venera-Next/actions/runs/43396095440)全部成功。Linux 575 文件／6,061 项（5,907 通过／154 跳过），扣除唯一移除的 Android 声明后，名称、结果和 skip Counter 完全一致；Windows 118 文件／1,501 项（1,498 通过／3 跳过），TV 89 项全通过，HAP host 仍为 80 文件／1,175 项（1,135 通过／40 跳过）。machine 时轴分别为 1,122.218、402.145、25.526、179.192 秒，执行器墙钟为 1,141.400、404.687、26.807、181.849 秒。LCOV 记录仍为 55,832 行，命中 45,646 行；唯一丢失的六行仍是 Rhttp 活动取消闭包，另有 11 行构造／异常路径新增命中。I 的真实活动请求测试使用 EOF 屏障保护这六行，当前单次波动继续如实保留。
- S4 其余模块 `3a82ef93` 的[质量运行](https://github.com/CyrilPeng/Venera-Next/actions/runs/43422036932)、[平台构建](https://github.com/CyrilPeng/Venera-Next/actions/runs/43422036947)、[鸿蒙 HAP](https://github.com/CyrilPeng/Venera-Next/actions/runs/43422037009)和[依赖审查](https://github.com/CyrilPeng/Venera-Next/actions/runs/43422036903)全部成功。Linux 576 文件／6,061 项（5,907 通过／154 跳过）、Windows 119 文件／1,502 项（1,499 通过／3 跳过）、TV 89 项全部通过、HAP host 80 文件／1,175 项（1,135 通过／40 跳过），均无漏项、零用例文件或协议错误。与 H 对照仅有已记录的弱重复删除、CJK 名称修正及活动取消新增；其余名称、结果与 skip Counter 一致。machine 时轴分别为 988.318、398.378、24.970、167.064 秒，执行器墙钟分别为 1,006.674、400.875、26.148、169.627 秒。LCOV 记录仍为 55,832 行，命中 45,648 行；与原基线无丢失命中，新增七行均在 Rhttp 的取消／响应收尾路径。活动取消六行（394、396、397、398、401、403）命中分别为 4、4、6、2、4、2，与本机真实原生运行相符。此前各批的六行波动记录继续保留。
- 本机独立使用 Flutter `3.41.4` / Dart `3.11.1`，framework `ff37bef603469fb030f2b72995ab929ccfc227f0`；已按根锁解析依赖，Dart 分析无问题。SDK 的临时 checkout 位于忽略的 `build/`，不作为应用源码或测试统计对象。
- 新执行清单校验目前覆盖 560 个应用测试文件；`default` 为 560、`windows` 为 85、`tv` 为 9。Windows 数量包含平台分支和原有原生／WebView 合同，属于目标执行集合，不表示旧 CI 已执行这 85 个文件。
- 脚本、包内、内联原生、自检与探针共有 67 个已登记源码单元。这个计数包含构成真实 Provider 探针的源文件，不能解释为 67 个独立用例。
- 新增九项基础设施回归已通过，验证漏项、过期路径、平台归属、辅助导入、协议计数、并发耗时、缺失终态以及失败退出码；Python 全量 302 项回归通过，其中七项平台跳过。
- Linux default 实际加载全部 **560 文件／6,062 项用例：5,907 通过、155 跳过、0 失败**；TV 实际加载全部 **9 文件／89 项用例：89 通过、0 跳过、0 失败**。文件遗漏、零用例文件和协议错误均为零，运行有完整终态。
- 本机基线 Windows 集合实际加载全部 **85 文件／1,234 项：1,230 通过、4 跳过、0 失败**，运行时长 305.462 秒。Linux 的 155 个跳过项中，154 个已在此 Windows 实跑通过；剩余 Android 适配器用例登记为审查候选，不能计为 Android 已执行。

完整机器清单用以下命令重新生成；运行事件和覆盖率不提交进源码：

```bash
python .github/scripts/test_suites.py --output build/test-audit/inventory.json
```

## 2. 原运行耗时

下列时间来自质量运行的 job／step 起止时间，而非 compact 日志中重复显示的测试标题。

| 项目 | 原主线运行 | 方案提交运行 |
| --- | ---: | ---: |
| Flutter 测试与覆盖率 job | 23 分 00 秒 | 17 分 13 秒 |
| 原主线全量 `flutter test --coverage` 步骤 | 20 分 59 秒 | 待按步骤继续统计 |
| 原主线 Linux 原生库准备 | 41 秒 | 待按步骤继续统计 |
| 原主线两项 sanitizer 执行步骤 | 4 秒 | 待按步骤继续统计 |
| 原主线 TV 回归步骤 | 33 秒 | 待按步骤继续统计 |

两次应用代码与测试相同，job 时间已有明显波动，说明不能直接将单次缩短归因于测试整理。后续需保留 runner、缓存、步骤和逐文件数据，再用正常 CI 样本比较。

清单批次的 Linux Flutter job 为 **20 分 29 秒**；准备原生库 33 秒，两项 sanitizer 各 2 秒，default 为 **1,113.562 秒**，TV 为 **27.104 秒**。前三次运行的应用与原有测试相同；缓存和共享 runner 波动尚未单独控制。

| Linux default 主要文件 | suite span | 实际用例 | 跳过 |
| --- | ---: | ---: | ---: |
| `sync/data_sync_upload_crash_test.dart` | 127.263 秒 | 22 | 0 |
| `reader/reader_exit_integration_test.dart` | 93.136 秒 | 179 | 23 |
| `sync/app_data_import_crash_test.dart` | 76.157 秒 | 11 | 0 |
| `reader/auto_reading_viewport_test.dart` | 36.934 秒 | 17 | 0 |
| `comic_source/source_editor_ownership_test.dart` | 36.200 秒 | 21 | 0 |
| `comic_source/source_transaction_crash_test.dart` | 35.552 秒 | 15 | 0 |
| `comic_source/source_update_ownership_test.dart` | 22.077 秒 | 31 | 0 |
| `comic_source/source_mutation_recovery_test.dart` | 20.842 秒 | 22 | 0 |

suite span 从 suite 事件到最后用例终态，包含加载、调度和真实进程等待，多个文件可同时运行；不能相加作为 job 墙钟时间或解释为纯 CPU 成本。崩溃恢复文件仍保护真实中断，不因其位列耗时排行而删除。

## 3. 原覆盖率

原报告包含 **525 个源码文件，45,641 / 55,832 行命中，约 81.75%**。这是 LCOV 记录的命中范围，不代表所有 `lib/` 文件或所有平台的完整覆盖。

| 模块 | 命中行 | 记录行 | 源文件 |
| --- | ---: | ---: | ---: |
| reader | 7,214 | 7,768 | 82 |
| favorites | 4,144 | 4,670 | 33 |
| local_comics | 4,715 | 5,988 | 49 |
| sync | 3,623 | 3,950 | 30 |
| comic_source | 5,310 | 6,172 | 48 |
| foundation | 5,351 | 6,228 | 82 |
| network | 1,383 | 1,555 | 18 |
| components | 3,749 | 4,408 | 32 |
| app_runtime | 1,150 | 1,405 | 30 |

比较时以相同源码路径／行号的命中集合和关键行为为依据；移动测试产生的文件数变化，不作为覆盖率下降的判断标准。TV、Windows、鸿蒙与设备证据分别记录。

`fe7202d3` 报告与原主线按 `(SF, DA 行号)` 比较，缺失／新增记录和丢失／新增命中均为 **0**；不只是全局百分比相同。

## 4. 已核实的执行缺口

| 项目 | 现状 | 下一步 |
| --- | --- | --- |
| Windows 分支与受限组 | 31 个文件有 75 处显式 Windows skip；新清单包含更广的 85 个 Windows 相关文件，旧 PR 仅执行 11 个 | S1 统一环境准备并接入新清单，核实实际运行与预期跳过 |
| 根独立 Kotlin 回归 | 下载 session、所选文件所有权、音量键订阅均有真实生产 primitive 和 JVM `main()`，尚无 CI 入口 | S1 接入匹配生产源码的独立 JVM 执行 |
| Windows WebView 旧模板 | 可选 CMake test runner 引用旧模板，但模板使用当前插件没有的默认构造、`HandleMethodCall` 和 `getPlatformVersion` | S5 按代码证据审查并移除无效模板及仅为它存在的配置 |
| 手动诊断／设备探针 | AVIF、图片 pipeline、阅读处理及鸿蒙诊断模板有独立用途 | 保留用途说明，不能因缺少自动 job 删除或计为真机通过 |
| Android adapter Dart 用例 | `share_file_test.dart` 的 `Platform.isAndroid` 条件在三个桌面 Flutter host 上均不满足；同文件已有实际 serializer 与确认后清理的通用回归 | S4 对照应用分支与原生 Android 分享所有权，记录替代保障后处理，当前不计为通过 |

另外，原生测试中多处写死 Windows Release 路径，而 PR 提供的是 Debug 目录；这需要在环境夹具中统一处理。上述缺口已登记，不作为已通过的保障。

基线 Windows 的四个跳过项已逐一核实：原生归档输出符号链接保护限定 Linux；Android 确认后清理限定 Android；Linux 拒绝分享限定 Linux；依赖源码链接检查在 Windows 需要宿主权限，Linux 全量已执行该链接保护。前三项没有因为缺少依赖而跳过。

S1 将路径及必需依赖探测统一后，Windows 清单扩大到 101 文件，其中包括字体包和 SQLite 环境消费者；此数值是新执行范围，最终实跑结果在该批完成后记录。三个 Kotlin main 使用生产同版本 **Kotlin 2.1.0／Java 17**；官方 compiler zip 的 SHA-256 为 `b6698d5728ad8f9edcdd01617d638073191d8a03139cc538a391b4e3759ad297`，来源是 [JetBrains v2.1.0](https://github.com/JetBrains/kotlin/releases/tag/v2.1.0)，许可证 Apache-2.0。Linux 任务保留完整 POSIX 符号链接用例；Windows 预编译仅证明编译和两个会话 main，不作为 Android 文件路径语义通过的证据。

## 5. 决策记录

S5 的 `49123b45` [依赖运行](https://github.com/CyrilPeng/Venera-Next/actions/runs/43428723148)报告三个真实漏洞：`quinn-proto` 0.11.18 的 RUSTSEC-2026-0524／0523，以及 `quinn-udp` 0.5.14 的 RUSTSEC-2026-0538。原扫描失败记录保留；按官方公告分别更新到 0.11.19／0.5.16，作为独立安全修复提交验证。UDP 补丁复用已有的 `windows-sys` 0.52.0 图，并移除十个已失去引用的 Windows binding 条目。该修复属于本轮 CI 阻断项，后续比较明确记录原生依赖变化；测试整理的普通回滚不撤销安全修复。

J1 本地完整 cargo-audit 0.22.2 已载入 1,509 个公告并扫描 233 个依赖，退出码为 0，没有漏洞或被禁止的 unsound 警告；既有 `pin-utils` unmaintained 警告按原策略单独记录。四项 `cargo test --locked --lib` 全部通过。新编译的 `rhttp.dll` 只复制到私有测试 bundle，默认 `Rhttp.init()` 的实际模块路径通过 Windows API 核实，原应用 Release DLL 摘要保持不变；该来源验证、生产活动取消及低层 callback ACK 三项 Flutter 测试通过，machine 为 6.538 秒。`90546772` 的完整 CI 已全部通过，实际报告与 J 相同的用例／结果保持一致，数据如下。

| 批次 | 对象 | 决策／依据 | 当前验证 |
| --- | --- | --- | --- |
| A | 完整方案与文档入口 | 保留可审查方案、范围、去留标准和回滚要求 | `2928035c`；本地检查及完整 PR 基线成功 |
| B / S0 | 执行清单和 machine 记录 | 保留全量发现；用协议事件核对文件加载和实际用例，禁止缺少终态／漏项仍成功 | `fe7202d3` 全部 CI 成功；default 6,062／TV 89／Windows 1,234 项，预期跳过分别 155／0／4；同源码覆盖命中集合一致 |
| C / S1 | Windows 路径、必需原生库与 JVM 入口 | 原 Test skip 语义保留；当前 job 的 bundle 显式传入，缺少必需库失败，三个 JVM main 编译生产 primitive 后实际执行 | `8fcaea50` 本机 Windows 101 文件／1,461 项：1,457 通过、4 项预期跳过；质量、Kotlin、Android／TV、Apple、Provider、HAP 与依赖 CI 成功；Windows runner 启动缺陷见下一行 |
| C / S1 后续 | 默认 Flutter launcher | Windows PowerShell 会将 `flutter` 解析为 `.bat`，Python CreateProcess 不查询 PATHEXT；启动前显式解析入口，保留工具缺失错误 | `61285756` 的质量、HAP、Android／TV、依赖检查成功；Windows 已实际加载全部 101 文件／1,461 项，启动修复有效，临时目录问题见下一行 |
| C / S1 后续 | Windows 临时目录 | runner 的 `RUNNER~1` 系统目录是 8.3 别名；fixture 在测试内部别名边界前需要真实根路径。子进程优先使用 RUNNER_TEMP 并统一解析 TEMP／TMP，本地解析系统根，原业务保护和测试断言保持 | `61285756` Windows 为 1,431 通过、4 跳过、26 失败：23 项导入／崩溃恢复被系统别名阻止，3 项 v1.17 导出夹具的物理路径包含断言受同一问题影响。本机真实短路径已复现原失败；修复后四个受影响文件的 48 项及十一项执行基础设施回归通过。`d509e676` 完整 CI 全部成功 |
| D / S2 | 借用测试文件辅助逻辑的导入 | 将 12 个 helper 纯搬移到 5 个支持文件并更新 36 个借用者；原等待、错误传播及生命周期保持；photo_view 合法 main 包装保留。完整映射见 `test_reorganization_changes_20261113.json` | `20907e3b` 全部 CI 成功，42 个消费者／定义文件的 681 项名称计数一致；严格导入校验通过，借用导入归零；完整用例及覆盖记录集合一致，没有丢失命中，本次新增 7 行命中 |
| E / S3 | 阅读器退出大文件与平台归属 | 97 个完整语句（参数循环保留）拆为 10 个职责文件，33 个私有夹具标识改为共享标识；只修改标识 token，不修改字符串或 named argument label。Windows 递归识别辅助导入，HAP 原固定集合纳入共享清单并包含全部拆分文件，宿主库缺失不能静默跳过 | `84283d19` 全部 CI 成功；本地 179 项名称 Counter 相同，完整 Linux 6,062 项名称也一致。default 569／Windows 115／HAP host 77／TV 9；阅读器命中无下降，独立 Rhttp 取消的六行波动保留为 I 批次审查项 |
| F / S4 收藏 | 管理器的大文件与领域夹具 | 46 个完整语句及参数循环拆为事务、生命周期、旧库兼容和更新追踪四个职责文件，共享原夹具并同步全部 HAP 目标 | `30a52305` 本地 59 项名称一致；检查点修复 `c503b134` 的全部 CI 成功，Linux 6,062 项／Windows 1,502 项／TV 89 项完整执行；原失败记录保留如下 |
| F 后续 / 进程夹具 | 同步内容及孤立恢复的检查点握手 | [Windows 运行](https://github.com/CyrilPeng/Venera-Next/actions/runs/43379501072)为 1,497 通过／4 跳过／1 失败；`recovery-ready` 的同步读取报 Windows errno 32。目标文件可见不能证明生产者的重命名调用已完成，改为子进程返回该调用后发出检查点消息，父进程收到消息才读文件及强制终止；不重试失败用例、不改变磁盘协议 | 两组原有真实进程回归共 11 项通过／0 跳过／0 失败，完整名称 Counter 一致；每次仍检查实际 PID／阶段、非零退出、stderr、文件及数据库恢复结果。`c503b134` 完整 CI 全部成功：Windows 1,498 通过／4 跳过／0 失败，424.204 秒；Linux 5,907 通过／155 跳过，1,206.581 秒，完整名称 Counter 与基线一致；TV 89 项通过，29.808 秒 |
| G / S4 下载 | 任务策略、取消、队列和归档职责 | 移动 34 个完整语句及参数循环，抽取原漫画源、控制任务和存储夹具；保留 sourceKey 的 named argument label 与所有原断言 | `5f7130a4` 完整 CI 成功；根目录 43 通过／0 跳过／0 失败，名称 Counter `164215a3…` 一致。default 575／Windows 118／HAP host 80／TV 9；原 HAP 集合没有选择 download_task，本批不增加无依据的宿主目标；完整 Linux 名称／结果与覆盖记录及命中集合对照一致 |
| H / S4 同步 | VM 定位、远程响应与未执行声明 | 两处重复的 VM 定位逻辑复用 `test/support/dart_vm.dart`；两处相同响应构造集中到领域 support，保留内容长度、字节及响应流语义。移除 `share_file_test.dart` 的 Android-only 声明：普通、Windows、HAP 桌面 host 均不具备 Android 运行身份；保留现有实际 serializer 与 Android 源策略清理回归，原生分享所有权入口在 S5 接入，真实设备接线仍单独验收 | `fa494135` 完整 CI 成功。根目录 102 项：101 通过／1 预期跳过，名称 Counter `2ad75939…` 一致；完整 Linux 名称／结果仅减少该声明，Windows 少一项相同的 skip。覆盖记录一致，Rhttp 六行波动在 I 继续验证；原移除声明不计为原生或设备通过证据 |
| I / S4 其余模块 | 环境探测、生命周期夹具与行为候选 | 统一九处 SQLite、18 处 QuickJS 探测及手动计时器、JS、图片、source、Favorites 夹具，清除 50 处未使用导入；完整去留理由见[21 模块／19 helper／13 行为候选审查](test_reorganization_audit_20261113.zh.md)。文件名回归纠正双无效输入并删除同输入的弱声明；真实活动 Rhttp 取消保留独立 callback ACK 回归 | `3a82ef93` 完整质量、平台、HAP 与依赖 CI 成功。Linux 576 文件／6,061 项（5,907 通过／154 跳过），machine／runner wall 为 988.318／1,006.674 秒；Windows 119 文件／1,502 项（1,499／3），398.378／400.875 秒；TV 89 项，24.970／26.148 秒；HAP host 80 文件／1,175 项（1,135／40），167.064／169.627 秒。变化仅为已登记的删除、新增和改名；LCOV 55,832 记录／45,648 命中，相对原基线没有丢失命中，活动取消六行全部命中 |
| J / S5 工作流与原生 | YAML 契约、直接 Bash 门禁、分享与旧 WebView 模板 | 七项结构断言替代两个格式敏感 Python 断言，脚本仍直接验证；四个 Kotlin main 按真实声明编译运行，Windows C++／COM 六组回归执行。删除失效上游模板及唯一 GoogleTest runner，保留摘要、许可证和生产实例所有权补丁 | `49123b45` 的质量 `43428723074`、平台 `43428723175`、HAP `43428723150` 成功；依赖 `43428723148` 失败由 J1 处理。Linux 577 文件／6,068 项（5,914／154），machine／wall 1,302.912／1,322.779 秒；Windows 1,502 项（1,499／3），360.707／362.907 秒；TV 89 项，30.607／32.118 秒；HAP host 1,175 项（1,135／40），191.295／194.611 秒。只有新增七项 YAML 契约，其他名称／结果一致；LCOV 55,832 记录／45,659 命中，没有丢失命中，新增命中为 11 行应用启动路径 |
| J1 / 独立安全修复 | QUIC 传递依赖 | 按官方 RustSec 公告精确更新两个补丁版本，保留 Rust／FRB／libc pin 与完整扫描策略 | `90546772` 的质量 `43434471214`、平台 `43434471155`、HAP `43434471205`、依赖 `43434471132` 全部成功。Linux 577 文件／6,068 项（5,914／154），machine／wall 976.783／994.871 秒；Windows 119 文件／1,502 项（1,499／3），509.883／513.266 秒；TV 89 项，21.750／22.710 秒；HAP host 80 文件／1,175 项（1,135／40），159.546／161.970 秒。名称／结果与 J 一致；LCOV 55,832 记录／45,659 命中，没有丢失原基线命中，活动取消六行均命中。完整 RustSec 扫描实际载入 1,509 公告／233 依赖并通过，原失败记录保留 |
| S4 保留项 | 旧库与取消／恢复回归 | 当前兼容和资源逻辑仍存在，不能按 `legacy` 名称删除 | 全模块审查已完成，有效回归继续在适用套件执行 |

后续每批在本表记录处理对象、旧新对应、理由、commit 与实际验证；完整移动／合并映射可另存结构化记录。未实施或未取得证据的项目保持待办状态。

## 6. S6 配置与本地验收

本批从 J1 成功的 Linux／Windows machine 记录生成执行配置，不使用未测文件豁免。分支 HEAD 为 `9054677215cbe02f5fca685890285d4011bf88bb`，CI 实际 checkout 为 PR 合并提交 `29c3b0202b01d06f849fc0f0eec1cca3bce52d1f`；两者 Git 源码树均为 `e88f2572ce359b4af8d2cb5859fa902aad249ebe`。后续实际执行报告以 job checkout 为来源，分支 HEAD 单独记录，不能混用两个 SHA。

fast 为 62 文件，其余 515 文件按 44 个超过 5 秒的实测 suite span 和其余文件的 2 秒权重分为 170／172／173 文件。各 full 权重为 526.052／526.086／527.840 秒，只用于分配，不能视为 job 墙钟预测。新增普通文件自动进入完整并集；name／tag／内置 shard 及覆盖率缩减参数被禁止。每组 machine 保留完整终态、ID、组、错误与计数，汇总校验来源、清单字节及 LCOV 摘要；TV 必须提交实际独立报告。

精确平台策略来源为 Linux 154、Windows 3 项实际跳过，以及 macOS 181 项明确源码条件；macOS 保持 `runtime_verified: false`，不将 Linux 策略直接复制过去。Windows 新执行器在当前源码和私有新 DLL bundle 下实际运行 119 文件／1,502 项：1,499 通过、3 跳过、0 失败，machine／wall 为 430.004／434.847 秒；名称／结果与 J1 CI 一致，所有完整性错误、意外和过期跳过均为零。

原生准备单独编译并执行 ABI／ASan／UBSan，五库 bundle 包含实际解析的 unversioned SQLite；每个新 runner 校验文件／摘要并实际加载。Rust 锁文件与源码触发桌面构建的缺口用实际 Bash 和临时 Git 仓库复现，修复后文档、根测试、Rust 锁／源码、原生 CMake 和 Android 路径六组触发均符合预期。上述为本地与准备阶段证据；S6 推送后仍需完整 CI 及实际分片并集／覆盖率验收。

根目录本批验收已完成：严格 Flutter 分析无问题，333 项 Python 回归通过（7 项预期跳过，646.588 秒），50 项鸿蒙脚本通过（13.239 秒），实际九项 YAML／工作流契约通过。62 文件快速组为 513 通过／0 跳过，machine／wall 为 37.774／44.678 秒，在空自编原生目录和必需依赖模式下仍完整执行。版本、结构、架构、严格清单、Dart 格式与 diff 检查均通过。

本机中文 PowerShell 的负向 CLI 夹具曾以 GB2312 输出，UTF-8 reader 丢失五项错误诊断；修复夹具输出编码并核对具体错误后，七项定向检查及完整脚本回归均通过，原日志保留。一次恢复后的 Flutter 工具启动因缺少标准 Windows 环境变量未加载测试，执行器明确失败；补齐环境后九项契约实际通过。S6 完整 CI、分片并集与覆盖率对照仍待推送后的真实运行。

## 7. S6 完整 CI 验收与第一轮样本

`ebdb307c` 的[质量](https://github.com/CyrilPeng/Venera-Next/actions/runs/43447775607)、[平台](https://github.com/CyrilPeng/Venera-Next/actions/runs/43447775595)、[鸿蒙](https://github.com/CyrilPeng/Venera-Next/actions/runs/43447775898)及[依赖](https://github.com/CyrilPeng/Venera-Next/actions/runs/43447775628)全部成功。实际 checkout `3e29e563d8af864fa238db3987d93aee35a1807c` 与分支 HEAD 的源码树都为 `9da3da83e0a8f7da051ff6a8683f9d7c0dca0c6d`，每份执行报告的清单字节 SHA-256 都为 `939192d5a6aaf43a96bda2422c66dcce4e9c9c9fecd84f79dcc2d1c5366d598a`。

| 执行组 | 文件 | 用例 | 通过／跳过 | machine／执行器 wall 秒 |
| --- | ---: | ---: | ---: | ---: |
| fast | 62 | 513 | 513／0 | 57.784／75.702 |
| shard-1 | 170 | 1,797 | 1,772／25 | 337.977／356.184 |
| shard-2 | 172 | 1,947 | 1,914／33 | 258.614／276.017 |
| shard-3 | 173 | 1,813 | 1,717／96 | 367.384／386.586 |
| Windows | 119 | 1,502 | 1,499／3 | 500.442／503.750 |
| TV | 9 | 89 | 89／0 | 31.448／49.874 |
| 鸿蒙 host | 80 | 1,175 | 1,135／40 | 158.416／160.720 |

普通平台并集为 577 文件／6,070 项（5,916 通过、154 跳过）。对照 J1 仅新增已记录的两项工作流契约；其余普通、Windows、TV、鸿蒙的名称／结果与 skip Counter 一致。LCOV 仍为 55,832 记录／45,659 命中，记录和命中集合与 J1 完全一致；相对原基线无丢失命中，取消六行命中仍为 4、4、6、2、4、2。

本轮质量工作流墙钟为 701 秒，完整四组 PR 从首个 job 启动到最后必需门禁结束为 1,370 秒，Actions job 起止时长合计 7,483 秒（未应用计费倍率）。Linux 分片不能改变当前 Windows 构建／全量回归占据的最长链；稳定汇总 job 的 13 秒不能拿来与旧全量 job 的约二十分钟比较。该正常实现提交作为第一轮样本，S7 继续通过必要文档提交取得后两轮完整结果，报告中同时列出快反馈、准备、测试、PR 等待和总 runner 成本。


## S7 正常 CI 暴露的收帧竞争

指南提交 `7a687d4d` 的[质量运行](https://github.com/CyrilPeng/Venera-Next/actions/runs/43453795583)在 shard-3 失败，原 13 项 display image provider 回归中，`two visible listeners stay mounted while preparation joins and resumes` 在恢复后只推进一次事件队列和帧，就断言已收到两帧，实际为零。该分片 1,716 通过／96 跳过／1 失败，汇总门禁正确拒绝失败；[平台](https://github.com/CyrilPeng/Venera-Next/actions/runs/43453795831)、[鸿蒙](https://github.com/CyrilPeng/Venera-Next/actions/runs/43453795619)和[依赖](https://github.com/CyrilPeng/Venera-Next/actions/runs/43453795694)全部成功。原运行不重试、不计入成功样本。

PNG 原生解码完成时间独立于 Dart 事件队列。忽略目录中的受控 probe 保留原真实 decoder，仅把完成延后 150 ms：旧等待方式实际运行 13 项，12 通过／1 失败，准确复现两帧预期与零帧结果；修正后同一延迟 13 项全部通过，正常延迟的原文件 13 项也全部通过，展开名称一致。将八处正向收帧／原生帧启动等待改为明确条件及 5 秒超时，原暂停／取消期间零帧、恢复后的准确帧数、共享加载次数、错误与资源释放断言保留；主应用 Dart 和原生依赖未改变。严格分析真实执行通过。

本批修正增加 28 行测试辅助／等待，S7 将按实际 Git blob 更新最终规模；S6 已取得的第一轮仍保留为历史数据，修正后三轮正常同类 CI 另成一组，避免把测试输入变化混成相同条件的性能样本。完整修复 CI 在推送后记录。


## S7 修正后正常样本 1

`a682e042` 的[质量](https://github.com/CyrilPeng/Venera-Next/actions/runs/43458342695)、[平台](https://github.com/CyrilPeng/Venera-Next/actions/runs/43458343046)、[鸿蒙](https://github.com/CyrilPeng/Venera-Next/actions/runs/43458343179)和[依赖](https://github.com/CyrilPeng/Venera-Next/actions/runs/43458342981)在第一次 attempt 全部成功。普通 577 文件／6,070 项、Windows 119／1,502、TV 9／89、鸿蒙 host 80／1,175 的完整名称、结果及 skip Counter 与 S6 保留集一致，原 13 项收帧回归在普通与鸿蒙 host 均完整保留。实际 checkout `0737b6add52d647f929148b55afc739365643c2e` 与请求 HEAD 的源树均为 `cd5818210e72dd044d2a64552c45c4fbb8a0cf44`，清单字节摘要均为 `939192d5a6aaf43a96bda2422c66dcce4e9c9c9fecd84f79dcc2d1c5366d598a`。

LCOV 仍为 525 文件／55,832 记录／45,659 命中，与 S6 和 J1 的记录／命中集合一致、无丢失基线命中；活动取消六行仍为 4／4／6／2／4／2。独立覆盖产物传输曾返回一次 HTTP 503，随后仅重取该 artifact 成功，没有重跑 CI。Quality wall 656 秒、整个四组 PR wall 1,509 秒、所有 runner 7,692 秒；Windows Debug 编译 755 秒、Dart 回归步骤 519 秒，时间与成本分别记录。这个单例不能代替后两轮的中位数／范围验收，完整结果见[整理结果报告](test_reorganization_result_20261113.zh.md)。


## S7 结果报告提交的外部 SDK 准备失败

`58f42251` 的第一次 attempt 结果为 [质量](https://github.com/CyrilPeng/Venera-Next/actions/runs/43464188443)：failure，[平台](https://github.com/CyrilPeng/Venera-Next/actions/runs/43464189482)：success，[鸿蒙](https://github.com/CyrilPeng/Venera-Next/actions/runs/43464188570)：success，[依赖](https://github.com/CyrilPeng/Venera-Next/actions/runs/43464188425)：success。Android Provider 任务在 `sdkmanager --install emulator --channel=0` 阶段报告 `Error on ZipFile unknown archive`，尚未创建 AVD、未启动模拟器及 Provider 用例；没有运行报告又导致 artifact 上传失败。原失败保留，不计为完整成功样本。

上一轮相同 action SHA `a421e43855164a8197daf9d8d40fe71c6996bb0d` 及同一 SDK 准备命令已实际运行 Emulator 37.2.13.0（build 16740729），initial／resume 报告均 `ok:true`、原生 descriptor 为零；本次证据确认的是外部 SDK 准备错误，不能据此判定应用 Provider 回归。后续平台文档按实际内容提交并接受正常完整 CI；若错误重复，再依据版本和下载证据处理环境，不重跑这次失败以选择成功结果。

本次普通 577 文件／6,070 项、Windows 119／1,502、TV 9／89、鸿蒙 host 80／1,175 的已执行名称、结果和跳过与保留集一致；普通覆盖记录及命中集合无损失。这些实际结果不能代替未执行的必需 Provider 入口。

平台与剩余事项见[验收矩阵](test_reorganization_platform_acceptance_20261113.zh.md)，主测试减少 1,011 行／全部测试 Dart 增加 576 行的口径继续保留。


## S7 修正后正常样本 2

`1d61b992` 的[质量](https://github.com/CyrilPeng/Venera-Next/actions/runs/43469352391)、[平台](https://github.com/CyrilPeng/Venera-Next/actions/runs/43469352350)、[鸿蒙](https://github.com/CyrilPeng/Venera-Next/actions/runs/43469352584)、[依赖](https://github.com/CyrilPeng/Venera-Next/actions/runs/43469352446)在第一次 attempt 全部成功。普通、Windows、TV、鸿蒙 host 的实际展开名称、结果与 skip Counter 和 S6 保留集一致；实际 checkout `e2d59471dfdad04bc0e153fcf7e8e2e40ea1a79f` 的源树 `e2541546509bd49ce976fafbc49a1b0691f1d8c7` 与请求 HEAD 一致，全部清单 SHA-256 为 `939192d5a6aaf43a96bda2422c66dcce4e9c9c9fecd84f79dcc2d1c5366d598a`。测试 Dart、应用 Dart、清单、执行和原生依赖没有改变。

普通覆盖 525 文件／55,832 行记录／45,659 命中，无丢失原基线或 S6 命中，活动取消六行全部实际命中。Quality wall 719 秒、完整四组 PR wall 1450 秒、所有 runner 7887 秒；逐分片及 Windows 步骤使用原始 machine／job API 记录，完整数据见[结果报告](test_reorganization_result_20261113.zh.md)。


## S7 修正后正常样本 3

`f07181d2` 的[质量](https://github.com/CyrilPeng/Venera-Next/actions/runs/43474007522)、[平台](https://github.com/CyrilPeng/Venera-Next/actions/runs/43474007511)、[鸿蒙](https://github.com/CyrilPeng/Venera-Next/actions/runs/43474007609)、[依赖](https://github.com/CyrilPeng/Venera-Next/actions/runs/43474007301)在第一次 attempt 全部成功。普通、Windows、TV、鸿蒙 host 的实际展开名称、结果与 skip Counter 和 S6 保留集一致；实际 checkout `e36d197a5155b6e8bd3f118e70aafe6f6981ab3c` 的源树 `e27820eb9a9e2545421bc1b220a93f280ce32393` 与请求 HEAD 一致，全部清单 SHA-256 为 `939192d5a6aaf43a96bda2422c66dcce4e9c9c9fecd84f79dcc2d1c5366d598a`。测试 Dart、应用 Dart、清单、执行和原生依赖没有改变。

普通覆盖 525 文件／55,832 行记录／45,659 命中，无丢失原基线或 S6 命中，活动取消六行全部实际命中。Quality wall 751 秒、完整四组 PR wall 1416 秒、所有 runner 7484 秒；逐分片及 Windows 步骤使用原始 machine／job API 记录，完整数据见[结果报告](test_reorganization_result_20261113.zh.md)。


## S7 三轮正常样本与阶段收尾

三轮均为有实际内容的独立提交，测试及执行输入一致，四组第一次 attempt 成功；质量、完整 PR 和所有 runner 的中位数及范围分别报告，不计算 P95，也不声称没有达到的完整 PR 提速目标已经完成。S0–S7 的硬性退出条件均有证据，macOS Dart／鸿蒙与其他真实设备事项保持实际未验收状态。原 PNG 等待及 emulator 下载失败继续保留，最终记录提交仍需正常完整 CI，最终实际终态保存在忽略目录并在交付回复链接。
