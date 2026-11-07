# 剩余 Git 依赖完整差异审计（2026-11-06）

[English](remaining_git_audit_20261106.en.md) · [完整文件清单与证据摘要](remaining_git_audit_20261106.json) · [治理规则](dependencies.zh.md)

当前应用保留 **2 个 Git 来源、8 个 Git 包和 8 个本地包**。这轮审计不改变依赖 SHA、SDK 或应用版本；比较剩余两项的完整 Git 文件范围、真正的定制补丁、当前官方候选及应用契约。官方来源仍用于版本和安全更新跟踪。历史 fork 留供旧构建与回滚。

两个现有 fork 的 API 暂时保留。QuickJS 官方未发布候选不能通过当前应用的依赖解析，且实测丢失 JS Map 内容；InAppWebView 官方稳定版缺少应用所需退出事件，官方 Git 候选也没有纳入 Windows GraphicsContext 所有权修复。与此同时，QuickJS 内嵌核心确有需要优先处理的安全公告对应代码模式。**保留包装层 API 不表示继续接受旧核心的安全缺陷。** 下一鸿蒙 pin 仅允许预览，`release_enabled: false` 在核心修复和平台审核前阻止 tag 分发。

## 比较方法与范围

使用完整 SHA、共同祖先及 canonical Git blob；不用分支名代替审核基线，也不把后来打的同版本 tag 当作原 fork 的父提交。JSON 登记每个变化路径、增删行数及前后 Git blob ID，包含原生核心、各平台、生成文件、示例和工具。统计固定使用 `--no-renames`；重命名的删除／新增分别登记，因此 QuickJS 候选为 161 个路径，默认重命名识别下的 159 个文件属于另一种统计口径。

| 项目 | 从 → 到 | 全部变化路径 | 结论 |
|---|---|---:|---|
| QuickJS 定制历史 | `32aac42…` → `295f774…` | 84 | 包含迁入内嵌核心、平台与生成文件，不能解释成 84 项业务补丁。 |
| QuickJS 官方候选 | `295f774…` → `12a393b…` | 161 | 原生 assets、核心及包装层共同变化，需要独立升级验证。 |
| InAppWebView 定制历史 | `0aaf7a0…` → `3ef899b…` | 2 | 仅 Windows manager 的 5 行新增／2 行删除。 |
| InAppWebView 官方候选 | `3ef899b…` → `17527ca…` | 1845 | 包含上游 API、生成文件、新 Linux 插件和平台演进；并非个人定制规模。 |

这份审计提供完整变化清单和影响判断；候选的原生设备行为、漏洞利用和全部平台的等价性分别列明，不将源代码比较当成这些验收。

## QuickJS：API 与核心分别维护

原固定 fork 为 [CyrilPeng/flutter_qjs@295f774…](https://github.com/CyrilPeng/flutter_qjs/tree/295f77421eedff356a02e92987181b525970c780)，原始包装层上游为 `ekibun/flutter_qjs`，共同基线为 `32aac42c194bd9631fb44e0582e6fde1778807d0`。

截至本次查询，pub.dev 最新仍为 **0.3.7**，SDK 约束为 `>=2.12.0-0 <3.0.0`。但官方 Git 已在 2026-10-19 提交未发布的 **0.4.0**（`12a393bd22529753935705b2a8f5db636e93d37f`），要求 Dart `^3.10.0`、`hooks ^2.2.0`、`code_assets ^2.0.0` 和 `native_toolchain_cmake ^0.3.2`。不能继续笼统地说官方不支持 Dart 3。

固定 fork 中 19 个内嵌核心文件的 18 个源码／头文件与官方 QuickJS-NG `d07f6b5232dd92ba712fe729bd018aae3a1b328f` 完全一致，该提交为 2025-01-18 的 `v0.8.0-31-gd07f6b5`。唯一不同的 `VERSION` 仍写着 `2024-02-14`；它不是核心内容的可靠版本标识。官方 0.4.0 使用 QuickJS-NG submodule `081d50c2792c16763f0e4a62ee4fdfb902b15a67`，头文件版本为 **0.17.0**。JSON 保存逐文件匹配记录。

| 层／平台 | 固定 fork 的必要行为 | 官方候选的变化与处置 |
|---|---|---|
| Dart／FFI | Dart 3 类型和 FFI 签名、整数／NaN 转换、JS Map entries、`JSInvokable.call`、TypedData 引用遍历跳过。 | 候选重新生成 native bindings；数值探针通过，但删除 Map 转换和 TypedData 快速路径。保留对应契约，不能直接换包。 |
| Engine／isolate | 应用实际调用公开 `dispatch()`、`port` 和 `JSInvokable.call`，由应用协调退出、Promise 与回调排空。 | 候选将事件循环和 port 改为内部所有权，并移除这些公开接口。后续须适配真实应用生命周期。 |
| Android | NDK 28、AGP／namespace／CMake 更新和原有 build-id 处理；继续构建当前库名。 | 改为 native assets，CMake 增加 16 KiB 页面链接选项，移除传统插件目录。需实际 APK、全部 ABI、导出及生命周期验收。 |
| iOS／macOS | framework 动态加载与 CocoaPods 入口、平台原生源码和原版权。 | 移除 pods／插件目录并使用 hook 构建；需应用实际链接、加载及释放验收。 |
| Windows／Linux | 现有插件／CMake 与库名，应用当前 CI 和宿主加载契约。 | 使用新 `flutter_qjs` native asset；纯 Dart Windows 核心已编译运行，Flutter 应用集成仍被 solver 门禁阻止。 |

应用隔离候选只替换 QuickJS 声明，保留真实应用 `lib/`。解析失败链为 Flutter 的 `meta 1.17.0` → `hooks 2.2.0` 所需 `record_use 1.0.0` → `meta ^1.19.0`；没有用 SDK／依赖 override 绕过这个失败。

独立纯 Dart Windows probe 在缩短生成目录、解决 MSBuild 长路径错误后实际编译了 0.17.0 核心：数值边界／NaN／Infinity，以及 30 轮 Promise、Dart callback、ArrayBuffer 复制和 engine teardown 通过；`new Map([["中文",7],["second",9]])` 返回 `{}`，该项失败。负零候选保留符号、旧 fork 归零，只记录差异；不将旧行为或初试的过强 int 类型断言误报为回归。固定 fork 的同一内容契约加既有应用生命周期回归共 **29 项通过**，旧引擎显式启动 dispatch 并关闭 port。

包装层 MIT LICENSE 和内嵌核心版权保留。许可证摘要见 JSON；内嵌核心来源由源码匹配确定。官方 native assets 的构建路径是后续候选，不等于已消除所有平台补丁。

## QuickJS 安全公告：必须先处理核心

本次读取 QuickJS-NG 仓库的 **10 项已公开 GHSA**。下表对照的是锁定核心实际源码，公告宽泛版本范围不能代替代码判断。没有运行任意命令执行或读取宿主秘密的利用程序；源码模式和原生平台风险不依赖这种测试才能登记。完整函数位置、报告范围与查询摘要见 JSON。

| 公告 | 当前源码判断 | 后续处理 |
|---|---|---|
| [GHSA-m53g-qx47-3h38](https://github.com/quickjs-ng/quickjs/security/advisories/GHSA-m53g-qx47-3h38) | 四个数组 copy constructor 在 getter 重入前发布未初始化 slots 的 count；对应模式存在。 | 优先同步初始化／GC 所有权修复，并以受控 getter／GC 原生 sanitizer 回归验证。 |
| [GHSA-r6vf-p8wr-4vg9](https://github.com/quickjs-ng/quickjs/security/advisories/GHSA-r6vf-p8wr-4vg9) | 2026-11-07 更正：当前 d07 核心使用泛型 `JS_SetPropertyInt64`，没有后来引入的 push 快速路径，原“缺少条件”的判断不适用。 | 不回移不适用的 `d98ff101` 条件；保留 shrink／grow、空洞、push 和 GC 回归。 |
| [GHSA-v647-xff9-jxf7](https://github.com/quickjs-ng/quickjs/security/advisories/GHSA-v647-xff9-jxf7) | CallSite 插入失败重复释放已转移的值，原记录仍进入 cleanup。 | 比较 `c846cb1364272de07bcc42e5a385ccdadf6b8409` 的值转移与 OOM 修复。 |
| [GHSA-crgj-9jv8-xfhq](https://github.com/quickjs-ng/quickjs/security/advisories/GHSA-crgj-9jv8-xfhq) | Promise reject function 分配失败时释放 resolve function 后未清空调用方 slot。 | 比较 `776d724cfa46a3b5bb045012ef4c838eae71ebaf`，同时检查 async function／generator 的同类 cleanup。 |
| [GHSA-wm7w-r6qf-3c9w](https://github.com/quickjs-ng/quickjs/security/advisories/GHSA-wm7w-r6qf-3c9w) | Atomics.store 在缓冲失效的错误返回中未释放转换值。 | 修复错误路径，验证 detach／转换／重试和内存所有权。 |
| [GHSA-9wv5-5cgr-grj6](https://github.com/quickjs-ng/quickjs/security/advisories/GHSA-9wv5-5cgr-grj6) | sort index 的长度乘法没有受控 size 运算；项目支持 Android ARM32。 | 比较 `e93cca611908e12b824ec85fbee6b31a5ee61568`，增加真实 32 位边界回归。 |
| [GHSA-jp52-chwg-2p9p](https://github.com/quickjs-ng/quickjs/security/advisories/GHSA-jp52-chwg-2p9p) | 旧 Proxy 实现含 `sizeof(tab[0]) * len` 分配；公告中的 extra_len 变体与此版本不同。 | 审核相关 32 位分配溢出；不声称复现了公告的具体利用路径。 |
| [GHSA-52gx-967m-hxp3](https://github.com/quickjs-ng/quickjs/security/advisories/GHSA-52gx-967m-hxp3) | 核心对外部 ArrayBuffer 的 transfer 可 realloc 外部指针；当前 Dart bridge 使用 `JS_NewArrayBufferCopy`。 | 保持复制契约，同时在核心拒绝或安全复制外部 backing store；不把其他 Rust binding 的利用结果套用到当前 Dart API。 |
| [GHSA-3jf7-4qfx-xc2h](https://github.com/quickjs-ng/quickjs/security/advisories/GHSA-3jf7-4qfx-xc2h) | 当前匹配的早期核心没有该 rope string 实现。 | 更新核心时核对该路径已修复；不将宽泛 `<0.16.0` 自动套用。 |
| [GHSA-rxpx-wj25-jhqq](https://github.com/quickjs-ng/quickjs/security/advisories/GHSA-rxpx-wj25-jhqq) | 报告下界为 0.15.1；当前更早的 RegExp compiler 需自己的分配错误审核。 | 独立检查旧 compiler；当前不声明已证明受影响或完成修复。 |

上游当前 SECURITY.md 不再接受私人安全报告／签发 CVE，并将不可信 bytecode 排除在其安全范围之外；这不撤回已经公开的 GHSA，也不能作为 JavaScript 源码触发的内存错误已解决的证据。当前包装层和 WebView 的仓库公告查询为 0，不包含系统 WebView2／WebKit 或其他依赖的全部公告。

下一步应在保留 Map、TypedData 和应用生命周期契约的前提下，独立审核官方核心修复的回移或升级，记录前后源码／补丁摘要，运行原生 ASan／UBSan、OOM／GC／32 位边界及所有发布平台的实际构建。完成后重新同步鸿蒙来源和共同基线，再以审核后的完整 SHA 启用分发。当前常规回归和 HAP 预览只验证已声明的构建行为。

## InAppWebView：两文件所有权补丁与上游平台变化

固定 fork 为 `3ef899b3db57c911b080979f1392253b835f98ab`，最近共同基线为 `0aaf7a0bfc01d61a4d1453cefb57fb6783b6e676`；后来的 `v6.2.0-beta.3` tag 为 `5e4b6a4cd88870a45c8e2396bb43ce94a50e7317`，不能用该 tag 反推个人补丁。官方 master 审计至 `17527cae5a3371c1e87f9c1df4281a7710debf28`（2026-02-10），pub.dev 稳定版仍为 6.1.5。

fork 的全部定制仅在 Windows 的 `in_app_webview_manager.h/.cpp`：将 `graphics_context_` 从 `inline static unique_ptr` 改为 manager 实例成员，构造时设 nullptr，在清理三个 webview 集合后 reset。当前官方 master 仍使用静态 context，未纳入该修复。不能将这个修复解释成所有静态 Windows／COM 资源已经完成所有权重构。

| 范围 | 官方 master 相对固定 fork 的全部变化路径 | 审核影响 |
|---|---:|---|
| 主包 | 327 | facade、环境 API、示例和生成工程。 |
| Android | 43 | Dart 实现与 Android 原生实现／构建。 |
| iOS | 315 | Dart、Swift、插件打包、原生能力和示例。 |
| macOS | 288 | Dart、Swift、插件打包与能力对齐。 |
| Windows | 93 | WebView2、环境／消息／打印等能力和构建；仍需保留 context 修复。 |
| Web | 22 | JS bridge、controller、storage 及平台支持。 |
| Platform interface | 494 | API、类型和大量生成文件；同一个 beta 版本名不能保证内容相同。 |
| 新 Linux 包 | 220 | 官方新增 Linux 插件；评估其注册、依赖和已有桌面 WebView 的关系。 |

其余 43 个路径属于仓库工具、测试服务和元数据；完整列表在 JSON。七个当前包的根／包级 Apache-2.0 LICENSE 摘要均已记录。系统 WebView Runtime 的更新和公告仍需分别跟踪。

完整应用隔离候选的结果：稳定版 6.1.5 在 `windows_webview_environment.dart` 的 `onBrowserProcessExited` setter 处严格分析失败；官方 master 的严格应用分析通过。官方 master 尚未完成 Windows 多窗口／关闭／重建、实际代理路径、Cookie／登录／Cloudflare 或各平台原生验收。本轮不删除退出事件或降级 API 来绕过分析。

后续以固定官方提交为基线，先保留／上游化或采用等效的 context 生命周期修复，再同步全部关联包和接口，并验证原生多窗口退出与代理切换。通过后才能移除个人 fork；无需再创建一批新的平台 fork。没有向原上游维护者发送消息或创建上游 PR。

## 证据与回滚

证据目录保存两个 QuickJS 契约源码（`.dart.txt`，需在隔离项目复制为测试文件）及解析／运行／分析日志，路径已替换为占位名；JSON 保存其 SHA-256。完整 Git 差异可按 JSON 的 from／to 和记录的 `git diff` 命令复核。失败、Windows 路径修正和未验收范围均保留，不将其中任何一步记成全面升级成功。

下一鸿蒙候选保留既有的 `packages/rhttp/lib/src/rhttp.dart` 平台变体：`Rhttp.init()` 接受可选 `ExternalLibrary?` 并传给 `RustLib.init`，供鸿蒙显式加载 `librhttp.so`；Rust 源码与主线一致。这不是本轮新补丁，也不表示八个本地包与主线逐字节相同。候选包摘要以其固定 Git 提交的真实文件计算，主线随版校验按同一来源复核。

当前 SHA 没有改变，因此本轮审计不需要依赖回滚。后续改变核心或包来源时必须同步 pubspec、完整锁文件、清单、审计和鸿蒙 overlay；回滚恢复整组记录，并保持冻结 `1.18.3+244` 来源、锁文件和历史 Release 资产。
