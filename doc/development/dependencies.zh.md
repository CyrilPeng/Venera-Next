# 依赖治理

English version: [dependencies.en.md](dependencies.en.md)

本文记录 VeneraNext 的直接依赖治理规则，重点说明不来自 pub.dev 的 Git 依赖。`pubspec.lock` 是构建复现依据，但不能替代依赖来源和维护责任说明。

## 基本规则

接管进度和逐项替换条件见 [2026-09-28 审计记录](dependency_audit.zh.md)。当前来源、固定提交和全部传递 Git 包见 [git_dependencies.json](git_dependencies.json)；修改 Git 依赖时同步更新清单，并运行 `dart tool/check_git_dependencies.dart`。

- 同时提交 `pubspec.yaml` 和 `pubspec.lock` 的相关变更。
- 直接依赖优先使用 pub.dev 的稳定版本；使用 Git fork 时必须说明原因。
- Git 依赖必须固定到不可变 commit，不能使用默认分支、`main` 或 `HEAD`。
- 发布工作流中通过 `dart pub global activate` 使用的工具也必须固定到同一 commit。
- 升级依赖时检查上游变更、安全公告、许可证、平台构建和相关测试。
- 发布到 pub.dev 不能替代安全维护；发布前仍需完成差异审计和上游同步计划。

## 当前 Git 依赖

2026-09-28：`flutter_qjs`、`photo_view`、`flutter.widgets`、`flutter_inappwebview` 和 `webdav_client` 曾改用 `CyrilPeng` 下的现有 fork，固定 commit 不变。`flutter_inappwebview` 的六个平台子包通过仓库内相对路径一起解析到同一 fork。该阶段只迁移来源，不升级版本。2026-10-05 起，`photo_view` 改为下文记录的本地 path 包，不再列入当前 Git 清单；回滚时同步恢复依赖声明、锁文件和对应清单记录。

这些 fork 的补丁选择、上游审查和更新验证由 VeneraNext 维护者负责。保留原作者版权和许可证；镜像不能替代持续维护，也不能解决许可证缺失。

| 依赖 | 当前 commit | 上游 / 许可证 | 暂时保留定制仓库的直接原因 |
|---|---|---|---|
| `flutter_qjs` | `295f77421eedff356a02e92987181b525970c780` | 未记录 fork 上游 / MIT | 保留 NDK r28 构建适配，修复异步字节结果的数值缓冲引用扫描开销；替换前必须验证 JavaScript 运行时和各平台原生构建 |
| `scrollable_positioned_list` | `09e756b1f1b04e6298318d99ec20a787fb360f59` | `google/flutter.widgets` / BSD-3-Clause | 固定版本增加 `scrollControllerCallback` 和 `scrollBehavior`，连续阅读定位依赖这些接口 |
| `desktop_webview_window` | `7801fc582ecf5a7351632887891ecf309a7b2583` | `wgh136/flutter_desktop_webview` / 未声明 | 固定版本包含 Windows ARM64 构建修复，替换前需验证全部桌面平台 |
| `flutter_inappwebview` | `3ef899b3db57c911b080979f1392253b835f98ab` | `pichillilorenzo/flutter_inappwebview` / Apache-2.0 | 固定版本包含 `GraphicsContext` 释放修复；内嵌 WebView 和 Cloudflare 流程依赖该分支行为 |
| `lodepng_flutter` | `ac7d05dde32e8d728102a9ff66e6b55f05d94ba1` | 未记录 fork 上游 / 许可证文件仍为占位内容 | 固定版本包含 NDK r28 构建适配，图片处理链路仍依赖其原生插件 |
| `webdav_client` | `2f669c98fb81cff1c64fee93466a1475c77e4273` | `wgh136/webdav_client` / BSD-3-Clause | 固定版本增加多种认证方式支持，WebDAV 阅读和备份依赖该兼容性 |
| `flutter_saf` | `fe182cdf40e5fa6230f451bc1d643b860f610d13` | `pkuislm/flutter_saf` / 许可证文件仍为占位内容 | 固定版本关闭代码压缩以规避 Android 发布构建问题，存储访问流程依赖该插件 |
| `flutter_7zip` | `b33344797f1d2469339e0e1b75f5f954f1da224c` | `wgh136/flutter_7zip` / 许可证文件仍为占位内容 | 固定版本修复编译错误，CBZ 和归档兼容回退链路依赖该插件 |

上表依据当前固定 commit 的提交说明记录“为什么现在不能直接切回上游”，不等同于完整差异审计。每次升级 Git 依赖时，应在 PR 中补充上游仓库、对比范围、全部定制修改、上游 PR（如有）、安全影响和回滚方式。

`desktop_webview_window` 未声明许可证，`lodepng_flutter`、`flutter_saf` 和 `flutter_7zip` 的许可证文件仍是占位内容。这些是已知供应链债务：升级前必须向维护方核实许可证，无法确认时应迁移到许可证清晰的上游版本或替代包。

## QuickJS 数值缓冲引用扫描修复（2026-10-31）

本轮将固定提交从 `8feae95df7fb00455df129ad7a0dfec1d0e8d8e4` 更新为 `295f77421eedff356a02e92987181b525970c780`，维护在现有 fork 的 `venera-next-pinned` 分支，应用仍固定到完整 commit，不跟随分支浮动。
[完整差异](https://github.com/CyrilPeng/flutter_qjs/compare/8feae95df7fb00455df129ad7a0dfec1d0e8d8e4...295f77421eedff356a02e92987181b525970c780)仅包含 `lib/src/ffi.dart` 的 `TypedData` 提前返回、对应回归和依赖 changelog；许可证、包版本 0.3.7、原生代码、NDK／CMake 及平台配置不变。未声明未经确认的上游 PR。

原 `JSRef._callRecursive` 把 `Uint8List` 当作普通列表复制并逐个扫描，而纯数值缓冲不可能包含 JS 引用。跳过这一类数据可以消除 Promise 字节回传的无用遍历；普通列表／映射、别名、环、回调引用和异步完成协议保持原样，不关闭用户处理、不改写脚本，也不是零复制改造。
[阅读诊断记录](reader_diagnostics.md)保留独立副本的 A/B/A 对照及测量边界；依赖自身新增 2 项缓冲／循环图回归，应用侧覆盖处理结果、取消、异常、worker 和引用释放。宿主通过不替代 Android 原设备复测或各平台构建，#125 不因此自动关闭。

这不是 QuickJS 引擎安全版本升级，不解决既有上游来源记录债务；本次差异不增加权限或网络能力。回滚时一起恢复 `pubspec.yaml`、`pubspec.lock`、`git_dependencies.json` 及当前依赖表中的原 pin，并重新验证读取／处理生命周期，不能通过修改全局 Pub 缓存回滚。

## 本地维护的 PhotoView

`photo_view` 通过 `path: packages/photo_view` 使用仓库内的 [本地包](../../packages/photo_view/pubspec.yaml)，版本仍为 **0.14.0**。来源是 [CyrilPeng/photo_view](https://github.com/CyrilPeng/photo_view) 的原锁定提交 `a1255d1b5945aad4b7323303ec2ecdf0c90ffc4c`，上游为 [renancaraujo/photo_view](https://github.com/renancaraujo/photo_view)。原作者版权和 [MIT 许可证](../../packages/photo_view/LICENSE) 保持不变；VeneraNext 维护者负责本地补丁和后续上游比较。

[LOCAL_PATCHES.md](../../packages/photo_view/LOCAL_PATCHES.md) 记录原始 Git blob 的 SHA-256、保留文件范围和验证方式。补丁修复尺寸监听器丢弃 `ImageInfo` 克隆造成的泄漏：读取尺寸后在 `finally` 释放克隆，绘制监听器继续独立管理自己的图片。为适配当前 SDK，另有三项等价调用替换：

- `TickerMode.of(context)` → `TickerMode.valuesOf(context).enabled`。
- `translate(dx, dy)` → `translateByDouble(dx, dy, 0.0, 1.0)`。
- `scale(s)` → `scaleByDouble(s, s, s, 1.0)`，保留原来的三维缩放及齐次坐标。

这次迁移保留原 fork 的阅读器接口和行为，未切换到 pub.dev 版本。除上述三个源文件外，其余 Dart 源码经格式化归一后与来源一致；包版本、manifest 依赖、其他 **156** 个锁定依赖记录及 SDK 锁定均未改变。`git_dependencies.json` 只记录当前 Git 依赖，因此移除 `photo_view` 条目，其完整来源由本地补丁记录保留。依赖解析使用与锁文件一致的 `PUB_HOSTED_URL=https://pub.dev`，并执行 `flutter pub get --offline --enforce-lockfile`。

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
- [ ] 发布工作流中的 Git 工具使用相同 commit。
- [ ] 已运行 `flutter pub get --enforce-lockfile`、`flutter analyze --no-pub` 和 `flutter test --no-pub`。
- [ ] 已运行平台构建，或说明无法运行的平台及原因。
- [ ] 已检查许可证、安全公告和上游变更记录。
