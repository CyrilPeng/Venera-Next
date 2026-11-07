# 官方依赖方案实施记录（2026-11-07）

[迁移前审计](official_dependency_plan_20261107.zh.md) · [当前来源清单](git_dependencies.json) · [机器记录](official_dependency_implementation_20261107.json)

本轮依照“兼容的官方稳定版 → 已验证的官方完整 commit → 必要本地补丁”执行。
当前根锁文件仍有 156 项：136 hosted、7 Git、8 path、5 SDK。直接声明中的
滚动列表已回归 pub.dev；个人 Git 来源只剩确有包装层与核心补丁的 QuickJS。
本文记录实施时的本地验证，最终平台门禁与集成结果由 PR 检查和审核记录保存；
鸿蒙候选见 [PR #153](https://github.com/CyrilPeng/Venera-Next/pull/153)。本文不代表真机验收。

| 调整 | 已采用来源 | 依据 |
| --- | --- | --- |
| scrollable_positioned_list | 官方 pub.dev 0.3.8 | 应用用公开 Scrollable.position、可见 item bounds 和 ScrollConfiguration 接管像素滚动、自动阅读及活动列表归属，删除本地包；首次边界尚未发布时绑定唯一活动列表，双列表动画仍按几何选择。覆盖初始化、远距离动画换列表及旧控制器退役。 |
| InAppWebView 六包 | 官方 `0aaf7a0bfc01d61a4d1453cefb57fb6783b6e676` | 它是旧 fork 的直接父提交，整仓差异只有两个 Windows 文件、5 行新增／2 行删除，保留原 API／SDK／依赖组；稳定版 6.1.5 缺浏览器退出事件。 |
| InAppWebView Windows | 本地 0.7.0-beta.3 | 203 个上游文件保留原许可证与摘要，仅实例所有权、独立 interface 声明及必要分析／格式适配；删除补丁的条件是官方来源覆盖修复并通过同等验证。 |
| flutter_qjs | 既有 fork 的 `f5a1f20d08c33b0a6b3e38eda2a7b27705420620` | 官方稳定包装层不兼容现有 SDK/API，官方 0.4.0 候选在解析和真实 Map 探针中失败；保留 Map／TypedData／dispatch／port，独立回移适用的核心修复。 |
| sqlite3 | 官方 2.9.4 | 保留 2.x 加载与数据库 API，完成现有数据库／持久化回归；3.x 及旧原生库包的退出另行验证。 |
| dynamic_color | 官方精确 1.8.1 | 1.9.0 可解析，但其 Android 发布脚本未应用 Kotlin Android 插件，kotlin／compilerOptions 在 Android 和 TV 构建中失败；回退到已兼容的官方稳定版。 |
| shimmer_animation | 官方 2.2.2+1 | 发布补丁与实际归档摘要固定在 lock。 |
| flutter_reorderable_grid_view | 官方精确 5.7.0 | 5.10.0 在鼠标／触摸自适应列拖动中产生负 BoxConstraints；回退后 6 项回归通过。 |
| pdfrx | 官方 2.4.7 | 2.4.8 的 pdfrx_engine ^0.4.7 要求 meta ^1.18，与当前 Flutter 的 meta 1.17 冲突，未采用该候选。 |

其他普通 hosted 包继续使用已审核的兼容官方发布版。intl 随 Flutter 固定，FRB
2.11.1 与 Rust 生成代码成组保留；最新版本跨越当前 SDK 下界时不强行 override。

本地包仍为八个：PhotoView、SharePlus、Rhttp、WebDAV、desktop WebView、Windows
InAppWebView，以及项目自编的 venera_native／venera_saf。前六项都有官方候选、
必要补丁、失败证据、维护责任和退出条件；后两项的第三方核心分别记录官方来源。
Rhttp 官方 0.18.0 和当前官方 Git 的原生锁文件命中旧依赖公告，不能回退现有安全
pin；其后续替换须先对齐安全锁文件、FRB 和平台加载／取消契约。

QuickJS 原 18 个 C 源码／头文件与官方 d07f6b5 基线一致。新提交修复数组 getter／GC
初始化、增长边界、CallSite／Promise／async OOM 所有权、TypedArray／Proxy 分配、
Atomics.store 失效清理和 ArrayBuffer 外部缓冲／旧视图／失败回滚。
[补丁与来源](https://github.com/CyrilPeng/flutter_qjs/blob/f5a1f20d08c33b0a6b3e38eda2a7b27705420620/CORE_PATCHES.md)
及机器摘要独立保留。旧 d07 的泛型 push 没有后来优化路径的缺陷，已更正上一轮判断。

[核心 CI](https://github.com/CyrilPeng/flutter_qjs/actions/runs/42342818783) 在精确 f5a1f20
上全部通过：Linux 64／32 位 ASan、UBSan，Windows 64／32 位 ASan。Linux 明确执行
Atomics 回归；MSVC 此配置没有 Atomics API，不能把 Windows 成功计为该项覆盖。
五个程序各尝试 256 个单次故障注入位置，实际触发 47／77／119／43／19 个分配
失败分支，并在排空、GC 和退出后检查分配全部释放。

本机已成功构建完整 Windows Debug bundle，并通过原生库、导出和随包 NOTICE 审计。
使用该 bundle 实际生成的 DLL 执行应用回归，148 项通过、1 项平台跳过，覆盖真实
数值、Map、Promise／复制缓冲、30 次退出、生命周期、图片处理和 WebView 流程。
这次整包验证包含此前独立 DLL 的 129 项和新增 3 项契约，不将它们重复累计。
严格分析零诊断，来源工具 41 项通过／1 项平台跳过；网格回退后的 6 项通过。
Python 仓库测试共 239 项、7 项平台跳过；Windows 原生启动、心跳和快捷键 CTest
3 项通过。可见窗口的首次启动／重复启动检查由隔离 Windows CI runner 执行。
本机为 Flutter 3.41.6／Dart 3.11.4，CI 准确版本为 3.41.4，分别记录。

Linux CI 的主线／鸿蒙回归发现首次页码边界通知之前，连续滚动代理尚未绑定的
初始化问题。修正后唯一活动列表立即可用，双列表动画继续按发布几何选择归属。
新增实际官方列表、空边界通知、像素滚动与退役回归；该回归在旧源码上稳定失败，
修正后的连续输入及阅读器退出集成回归 184 项全部通过。该修正随运行代码纳入
公共基线，并实际合并到鸿蒙候选；最终平台检查按新提交重新执行。

来源检查除 pubspec／lock 外还核对真实 Git HEAD、实际包子目录与源码状态。
Windows 长路径失败曾留下一个目录名为 0aaf、实际 HEAD 为 17527 的共享缓存，
本轮未修改其中源码；验证使用独立 PUB_CACHE 完整检出，已确认实际 HEAD 为 0aaf。
Windows CI／构建任务使用进程级 core.longpaths。遇到该诊断应使用新的独立缓存，
不要靠更改目录名或手改缓存源码通过检查。

鸿蒙根声明、工具链、官方 API 导出和锁模板同步本轮来源。HAP 实际 WebView 继续
使用固定 CPF 平台组；生成时先替换同名主线 overrides，再插入协调的 path 组，
拒绝重复 YAML key。滚动列表由 path 变为 hosted，生成锁文件为 130 hosted、21 path、
5 SDK；Windows 本地输入仍纳入项目来源摘要，HAP 的 Windows Dart 包采用 CPF 覆盖。
schema 1 的 244 来源继续冻结，245 下一 pin 保持 release_enabled:false。
当前候选为 `ca5f7ef98ec03872d087f0b691e40f0de0080939`，直接以公共基线
`c16e3545e17e12b68296ec125c8702430a6617bd` 为父提交；其 Git 树与此前已审核的
`d842be19c826d43cf64f3c4a131fd5742466c37f` 完全一致。本机已全量重建七个
ARM64 原生库并检查 ELF、导出与摘要；它们使用公开 API 20 SDK，API 26 HAP 由 CI
重新编译及验包。生成工程同时重定位新增来源回归的工具 import，保持严格分析。

本地 Windows 首次整包构建遇到宿主 stable Rust 缺 rustc，采用任务目录内真实 Rust
1.92.0 副本处理 Cargokit 的固定 stable 调用；第二次遇到旧 CMake cache 的安装目录
为 Program Files，将忽略的构建配置显式指向本工作区 Debug bundle。全局工具链和
共享源码缓存没有被更改。Windows 完整 bundle 验证通过；鸿蒙 API 26 HAP 和准确
CI Flutter 版本的结果以集成记录为准。

主线历史随后按用户指定的 `274ae716e32ec88b02a310fb754b6c9bb2c9dcfb` 边界
直接压缩重排。边界后的 18 条可达提交（含 5 条合并提交）改为两条单父提交，
主线不再通过合并父带回本阶段的旧历史。第一组 `c16e3545e17e12b68296ec125c8702430a6617bd`
包含全部运行代码、锁文件、来源工具和测试，Git 树与先前审核的 `5f7c572` 相同；
第二组只整理文档、changelog 与下一候选 pin。此次直接更新主分支。

鸿蒙候选 `ca5f7ef98ec03872d087f0b691e40f0de0080939` 直接以第一组为父提交，其 Git 树与先前
审核的 `d842be1` 相同，继续满足双方共有主线基线的门禁。schema 1 的 244 来源、
已有 tag 和历史发布资产继续保留；245 pin 保持 `release_enabled: false`。
244 来源由独立冻结引用 `codex/harmonyos-frozen-244` 保持远端可达，该引用不参与主线重排。

此前 PR 和本文件的实测数据保留为实施证据，其中旧提交 SHA 表示当时的验证对象。
此次历史整理的范围、树一致性与回滚方式见
[主线历史整理记录](history_reorganization_20261107.zh.md)。整理前的 refs 和完整对象
另存可恢复 Git bundle；其他工作区的未提交修改与冻结来源保留。
