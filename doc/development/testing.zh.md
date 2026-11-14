# 测试执行与维护

English version: [testing.en.md](testing.en.md)

本文说明测试清单、本地执行、CI 证据和新增回归的维护规则。构建工具链见[构建与开发](build.zh.md)，依赖来源及补丁要求见[依赖治理](dependencies.zh.md)。本轮整理的基线、去留理由和验收记录保存在 [experiments](../experiments/test_reorganization_plan_20261113.zh.md)。

## 环境与入口

在仓库根目录执行以下命令，使用 `pubspec.yaml` 指定的 Flutter 3.41.4、仓库锁文件和 Python 3。涉及原生回归时还需要目标平台工具链；Rust 由 `rust-toolchain.toml` 固定为 1.92.0，Flutter Rust Bridge 保持 2.11.1。鸿蒙使用其[独立固定 SDK 与受控依赖](harmonyos_releases.zh.md)。

`test/suites.json` 维护执行归属。业务目录继续使用 `test/features/<feature>/`、`test/foundation/` 等；单模块夹具放在模块的 `support/`，跨模块夹具放在 `test/support/`，实际子进程入口和兼容样本放在 `test/fixtures/`。直接导入其他 `*_test.dart` 借用辅助函数会使严格清单检查失败；PhotoView 的包内 `main()` 包装有单独登记的例外。

| 入口 | 内容与环境 |
| --- | --- |
| `default` | 根目录全部 Flutter 回归；在适用 host 上准备原生库后运行 |
| `fast` / `--partition fast` | 经审查的不依赖自编原生库的逻辑与组件文件，提供早期反馈 |
| `--partition shard-1` 等 | default 扣除 fast 后按实测权重分配的完整文件组；分片数量以清单为准 |
| `windows` | Windows 平台、真实 ABI、WebView、窗口及其辅助文件消费者 |
| `tv` | 真实 TV flavor 和清单中的编译参数；独立验证输入、低内存和更新策略 |
| `harmonyos-host` | 鸿蒙固定 SDK 下的 Linux host 回归，由鸿蒙构建工具在准备项目中执行 |
| `external` 清单 | Python、Swift、Rust、Kotlin、C++、Provider、打包 smoke 与手动探针的直接或间接入口 |

## 日常检查和快速反馈

```bash
flutter pub get --enforce-lockfile
python .github/scripts/release_version.py --check
python .github/scripts/check_structure_imports.py
python .github/scripts/check_architecture_dependencies.py
python .github/scripts/test_suites.py --strict-imports --output build/test-audit/inventory.json
python .github/scripts/run_flutter_tests.py --partition fast --concurrency 4 --output build/test-audit/fast
python -m unittest discover -s .github/scripts/tests -p "test_*.py"
flutter analyze --no-pub --fatal-infos --fatal-warnings
git diff --check
```

清单检查包含新增文件、过期路径、Windows 归属、测试间导入、外部入口、平台跳过和完整分片并集。新的普通测试会自动进入 default 的完整分片；进入 fast 需要先核实原生依赖、资源生命周期及实际成本。快速组的结果属于完整验证的一部分，提交的完整验证还需要其余适用入口。

定向诊断可以显式选择已归属的文件：

```bash
python .github/scripts/run_flutter_tests.py --output build/test-audit/reader-menu test/features/reader/reader_menu_integration_test.dart
```

报告会记录本次实际选择的文件。完整 CI 按清单重新核对分片并集，定向运行的报告不能通过完整分片汇总。完整套件禁止 name、tag 和 Flutter 内置 shard 筛选；覆盖率模式也禁止缩减覆盖范围的参数。

## Linux 全量与原生库

先安装 CMake、Ninja、C/C++ 编译器、pkg-config 和 SQLite 开发库。在 Ubuntu 上可以使用：

```bash
sudo apt-get update
sudo apt-get install -y cmake ninja-build g++ pkg-config libsqlite3-dev
RUSTFLAGS="--cfg reqwest_unstable" cargo test --locked --manifest-path packages/rhttp/rust/Cargo.toml --lib
RUSTFLAGS="--cfg reqwest_unstable" cargo build --locked --manifest-path packages/rhttp/rust/Cargo.toml --lib
mkdir -p build/test-native/lib
cp packages/rhttp/rust/target/debug/librhttp.so build/test-native/lib/librhttp.so
python .github/scripts/prepare_linux_test_libraries.py
export LD_LIBRARY_PATH="$(pwd)/build/test-native/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export VENERA_REQUIRE_NATIVE_TEST_LIBRARIES=1
python .github/scripts/run_flutter_tests.py --suite default --coverage --output build/test-audit/default
python .github/scripts/run_flutter_tests.py --suite tv --output build/test-audit/tv
```

原生准备器从当前 package config 的源码编译 QuickJS、ZIP 和 Venera 编码／归档库，执行其 ctest，并将实际解析的 `libsqlite3.so` 与当前 Rhttp 库放入同一 bundle。五个库都必须存在且能实际加载。下载 CI bundle 后可执行 `python .github/scripts/prepare_linux_test_libraries.py --verify-only`，它会检查文件摘要并加载必需库。

ASan／UBSan 和 SAF descriptor 回归仍在质量工作流的 `flutter-native` job 中实际编译执行，完整命令见[质量工作流](../../.github/workflows/analyze.yml)。Dart mock 不能替代句柄、ABI 和内存安全证据。原生代码或安全依赖变化需要重新编译并运行相关入口。

## Windows 与其他平台

Windows 先构建当前源码的 Debug bundle，再在 PowerShell 中传入实际目录：

```powershell
flutter build windows --debug
$env:VENERA_NATIVE_TEST_DIRECTORY = (Resolve-Path 'build/windows/x64/runner/Debug').Path
$env:VENERA_REQUIRE_NATIVE_TEST_LIBRARIES = '1'
$env:Path = $env:VENERA_NATIVE_TEST_DIRECTORY + ';' + $env:Path
python .github/scripts/check_native_codec_bundle.py --platform windows --root build/windows/x64/runner/Debug
python .github/scripts/run_flutter_tests.py --suite windows --output build/test-audit/windows
cmake -S windows/tests -B build/windows/startup_tests -A x64
cmake --build build/windows/startup_tests --config Debug
ctest --test-dir build/windows/startup_tests -C Debug --output-on-failure
cmake -S packages/share_plus/windows/tests -B build/share-plus-tests -A x64
cmake --build build/share-plus-tests --config Debug
ctest --test-dir build/share-plus-tests -C Debug --output-on-failure
```

测试环境也接受当前源码的 Release bundle；字体、Flutter DLL 和实际原生库随该 bundle 使用。CI 的 `VENERA_REQUIRE_NATIVE_TEST_LIBRARIES=1` 将缺少依赖报告为失败。系统临时目录由执行器解析为物理路径，保留测试内部的路径别名和越界验证。

| 独立入口 | 命令或维护位置 |
| --- | --- |
| Android JVM | Linux／Java 17 下运行 `python .github/scripts/run_android_jvm_tests.py`；按生产声明分别验证 Kotlin 2.1.0 与分享包 2.2.0 的官方摘要、编译器版本和实际 main |
| Apple 目录授权 | `swift test --package-path apple`；iOS Rhttp 另执行固定 target 的原生兼容编译 |
| Android 真实 Provider | [隔离 Provider 工具](../../tool/saf_provider_probe/)的 build／run；质量工作流在模拟器执行实际持久授权、64 位操作和关闭协议 |
| 鸿蒙脚本 | `python -m unittest discover -s tool/harmonyos -p "test_*.py"` 和 `node --test tool/harmonyos/test_directory_bridge.mjs` |
| 鸿蒙 host 与 HAP | [鸿蒙随版构建](harmonyos_releases.zh.md)；使用固定 SDK、原生库、受控锁及共享清单 |
| 设备与诊断探针 | 按 `external` 的 `manual` 说明及对应平台指南记录原产物、提交和实际结果 |

macOS 跳过策略记录经源码审查的明确条件，实际 host 执行状态以报告为准。Swift 通过、iOS 编译、Linux 鸿蒙 host 通过和 HAP 构建成功分别保存证据；设备签装、升级与真实系统交互按既有设备要求验收。

## CI 汇总和证据

质量工作流独立运行 fast、原生准备／sanitizers、三个 full 分片及 TV。每个 full 分片从同一次运行下载已验证的五库 bundle，保持文件级完整执行；matrix 的 `fail-fast: false` 保留其余分片的诊断。PR、主线、完整构建和发布质量入口复用相同完整保障，关键慢测试继续执行。

稳定门禁名称仍为「Flutter 测试与覆盖率」。它在 `always()` 条件下验证所有必需 job 成功，再读取实际 machine 报告，核对来源 commit、清单字节 SHA-256、分片归属、文件并集、用例 ID／数量／终态及跳过理由。每份请求的 LCOV 必须存在且摘要匹配。失败、取消、意外跳过、漏文件、过期 case 和错误编译身份都会阻止通过；TV 的实际报告单独存入 `tv`，不混入 ordinary 覆盖率分母。

报告的 `source_commit` 是 job 实际检出的提交，PR 检查通常使用临时合并提交。比较时分别记录分支 HEAD 和实际 checkout，并按 Git 源码树或文件内容确认比较范围；不能直接将两个不同含义的 SHA 当作同一个提交。

LCOV 按规范化源码路径和行号合并命中，并核对每个记录的 LF／LH。相关模块与关键路径按相同源码和环境对照，当前没有统一百分比硬阈值。直接拼接覆盖报告会重复分母，应使用合并工具。各分片 `events.jsonl`、`console.log`、`summary.json`、完整 `aggregate/summary.json` 及最终 `dart-coverage` 按工作流保留 14 天；长期保留决策摘要和 CI 链接。

`elapsed_ms` 是 machine 运行时长，`wall_seconds` 是执行器墙钟时间，`suite_span_ms` 包含文件加载、调度和用例等待。多个 suite 可并发，不能把 suite span 相加作为 job 耗时。比较优化时另列准备／编译、job 墙钟、完整 PR 关键路径和 Actions job 总运行时间，并说明缓存、runner 与新增执行入口。

## 新增、拆分与删除规则

- 先说明独立保护的行为、前置状态、操作、结果、错误和资源收尾，再选择合适层级与执行入口。
- 新平台／原生测试同时更新清单、原生准备及适用触发条件。平台不适用登记到 `test/platform_skips.json`，按 OS、文件、完整参数化名称和理由维护，并核对实际报告；依赖未准备应失败。
- 多个消费者拥有一致生命周期时抽取夹具，每个用例独立临时目录、数据库、端口和控制对象。有限等待必须有明确条件、超时及错误传播。
- 约 1,000 行作为职责审查提醒；按业务和资源需求拆分，保留可追踪名称。移动到 support 的代码仍计入测试总规模。
- 合并或删除必须记录旧用例／参数组、保护行为、当前代码依据、替代保障、平台及验证；未决候选继续保留。名称带 legacy、native 或 integration 不决定去留。
- 保留旧库／备份、事务失败、真实中断恢复、下载续传／取消、路径边界、FFI 所有权、过期回调、阅读菜单锁、TV 和发布来源门禁的独立故障保障。样本保留来源、许可证与摘要。
- 每批同步 `CHANGELOG.md`，使用中文约定式提交，完成相关本地检查与完整 CI 后推进下一批。回滚按批次普通 revert；独立安全修复单独保留。
