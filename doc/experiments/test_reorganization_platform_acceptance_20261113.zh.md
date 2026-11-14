# 测试整理：平台执行与剩余验收（2026-11-13）

状态：以已验收的第 3 轮 `f07181d2` 为来源，四组正常 CI 和全部必需 job 均实际成功。本文记录自动回归、编译与设备事项的区别；本次记录提交继续接受正常完整 CI。

整理结果及前后数据见[结果报告](test_reorganization_result_20261113.zh.md)，逐批失败和修复见[运行基线](test_reorganization_baseline_20261113.zh.md)。日常操作见[中文](../development/testing.zh.md)／[英文](../development/testing.en.md)指南，入口的机器归属由[执行清单](../../test/suites.json)维护。

## 1. 来源与执行完整性

实际 checkout 为 `e36d197a5155b6e8bd3f118e70aafe6f6981ab3c`，其 Git tree `e27820eb9a9e2545421bc1b220a93f280ce32393` 与请求 HEAD 一致。所有 schema-2 测试报告的清单 SHA-256 为 `939192d5a6aaf43a96bda2422c66dcce4e9c9c9fecd84f79dcc2d1c5366d598a`。

当前证据：[质量](https://github.com/CyrilPeng/Venera-Next/actions/runs/43474007522)、[平台](https://github.com/CyrilPeng/Venera-Next/actions/runs/43474007511)、[鸿蒙](https://github.com/CyrilPeng/Venera-Next/actions/runs/43474007609)、[依赖](https://github.com/CyrilPeng/Venera-Next/actions/runs/43474007301)。报告中的所有用例名称、结果及 skip Counter 与 S6 保留集一致；原生收帧等待修正后的样本另成一组，未纳入指南 `7a687d4d` 的失败运行，也没有通过重跑掩盖失败。

| 执行集合 | 文件 | 用例 | 通过 | 预期跳过 | 实际失败 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 普通 Linux 完整并集 | 577 | 6,070 | 5,916 | 154 | 0 |
| Windows | 119 | 1,502 | 1,499 | 3 | 0 |
| 真实 TV flavor | 9 | 89 | 89 | 0 | 0 |
| 鸿蒙 Linux host | 80 | 1,175 | 1,135 | 40 | 0 |

普通集合由快速组和三个分片完整组成；TV 是另一运行身份，不重复并入普通覆盖率分母。全部必需原生库在当前提交编译后校验并实际加载；错误身份、缺库、缺文件、零用例、缺少终态、未知／过期 skip 或失败／取消都会阻止完整门禁。

## 2. 自动化结果的实际含义

| 入口 | 已执行的环境与保障 | 证据边界 |
| --- | --- | --- |
| 普通 Flutter | 官方 Flutter 3.41.4，原全部测试文件的完整并集；真实数据库、文件、请求、子进程中断和恢复；原生收帧、菜单锁、退出保存及所有权回归 | Linux host 运行；不推断未运行设备或其他 OS 的原生 UI 状态 |
| Linux 原生与内存安全 | 当前提交的 `librhttp.so`、`libsqlite3.so`、`libflutter_qjs_plugin.so`、`libzip_flutter.so` 和 `libvenera_native.so`；native codecs／SAF descriptor CTest、ABI、ASan／UBSan 与 bundle 摘要／实际加载 | 实际原生运行与内存安全证据；不是截图或设备交互验收 |
| Windows Flutter、启动与分享 | 当前 Debug bundle、真实临时路径、原生／窗口生命周期集合；启动 C++ CTest、分享 C++／COM 回归、首次／重复启动及失败诊断 | Windows hosted runner 的回归与应用启动；不替代用户全部真实桌面操作 |
| TV | 使用 `--flavor tv --dart-define=EXPECT_TV=true --dart-define=TV_BUILD=ci-test --dart-define=TV_REVISION=tv-test`；遥控器、焦点、低内存与更新策略，另有 Android TV Debug 构建 | 明确的真实编译身份和 host 输入回归；物理遥控器、电视签装及设备性能仍是设备证据 |
| Android JVM | Java 17，按应用 Kotlin 2.1.0 和分享包 2.2.0 的官方 compiler 摘要／版本编译实际生产 primitive；下载会话、所选文件、音量键和分享四个 main | Linux JVM 实际运行；Android Activity／系统 UI／真实分享操作另行验收 |
| Android Provider | 隔离 Provider 工具在模拟器执行持久授权、Unicode、64 位文件及关闭协议 | 模拟器中的实际 Provider 行为；不能外推所有厂商和系统版本 |
| Apple 目录授权 | macOS runner 上的 `swift test --package-path apple`，真实授权／所有权与恢复逻辑 | Swift 原生回归；没有将整个 macOS Dart 集合记为实跑 |
| iOS Rhttp 与应用 | 固定 Rust／iOS target 的原生依赖兼容编译、模拟器应用及插件编译 | 编译通过；iPhone 签装、授权、升级与交互另行验收 |
| Rust Rhttp 与安全 | 锁定 crate 的原生 callback 生命周期及完整 RustSec 扫描；QUIC 传递依赖补丁与现有 pinned Rust／bridge 继续适用 | 原生运行和依赖安全检查，未把漏洞公告失败改写为成功 |
| 鸿蒙脚本、host 与 HAP | 固定 Flutter OH SDK、受控锁／overlay、Python／Node bridge 行为、host 全集合与 HAP 构建／源码和内容核验 | host 及构建通过；manifest 的 `runtime_verified:false` 保留 |
| CI Python、工作流与工具自检 | 完整 script suite、结构／版本／架构／清单及 code-audit 自检；发布、草稿、来源和完整聚合契约 | 本轮未执行公开发布；发布门禁验证成功不表示已有新 Release |
| AppImage、完整安装包与手动探针 | 清单登记 AppImage／Windows packaged smoke 与各 host 的手动 codec／pipeline／设备诊断入口 | 使用对应实际构建或手动报告验证；未因登记入口而虚构执行结果 |

根 `test/native/`、包内、内联 Rust、C++、Swift、脚本、自检和手动探针都有清单归属；当前盘点为 72 个外部源码单元，不能当作 72 个独立用例。photo_view 根入口有意复用包内 main，不是被禁止的测试间 helper 借用。失效 WebView 模板的去除理由及来源摘要继续留在变更记录。

## 3. 平台跳过与待设备状态

| 范围 | 当前状态 | 后续验收条件 |
| --- | --- | --- |
| Linux 的 154 条件跳过 | 原显式 Windows 行为由 Windows 集合实际承接；没有未知或过期跳过 | 新文件和新参数名称进入清单，适用平台必须真实执行 |
| Windows 的 3 跳过 | Linux 归档符号链接、Linux 拒绝分享、需要源码链接权限的检查；对应 Linux 行为实际运行 | 具备所需 Windows 权限时可实际执行原链接用例，不新增依赖缺失 skip |
| macOS 的 181 预期跳过 | [skip 清单](../../test/platform_skips.json)来自源码和参数名称审查，`runtime_verified:false` | 若执行 macOS Dart 集合，保留 actual machine 与 skip 对照；本轮不称其已运行 |
| 鸿蒙 host 的 40 跳过 | 独立 SDK／host 条件已经登记，实际 host 报告无额外或过期项 | host 不能代替真机系统能力；适用条件改变时更新对应清单和回归 |
| 鸿蒙签装、阅读和覆盖升级 | 待真实设备，`runtime_verified:false`，既有 stable_required 策略继续适用 | 相同签名身份，准确源码／版本／构建号与原 HAP SHA-256，真实启动、阅读、导入／下载、备份往返、升级和冷启动恢复报告 |
| 鸿蒙长期外部漫画目录（#159） | 当前只读诊断与应用内库／复制导入边界保留，持久目录能力仍未交付 | 持久授权获取／续期／释放、存储适配、原子迁移及失败回滚、重启／升级恢复和真机证据 |
| Android、TV 和 Apple 真实交互 | 自动部分已按上表运行／编译，未附新设备全验收报告 | 按对应平台实际设备验证输入、分享、授权、签装、升级与性能；报告绑定准确产物 |

设备约束见[鸿蒙随版构建](../development/harmonyos_releases.zh.md)。构建和 host 成功不生成真机合格报告，也不把暂未收到用户回复作为 issue 已解决的依据。

## 4. 阶段硬性条件复核

| 方案指标 | 本轮状态与依据 |
| --- | --- |
| 100% 文件归属 | 577 主文件和 72 外部源码单元无执行缺口；新增／改名、错误筛选、重复和过期条目有实际门禁 |
| 行为可追溯 | 移动、合并、删除、输入／命名修正与新取消回归均有旧新对应；21 模块、19 helper、13 相似候选的保留理由可核查 |
| 测试间 helper 导入归零 | 严格清单通过；唯一包内 main 包装有意复用并明确登记 |
| 平台与原生实际入口 | 75 处 Windows 条件已核实，JVM、Provider、Swift、Rust、CTest、Windows 和鸿蒙 host 有适用自动入口 |
| 关键保障保留 | 迁移、恢复、取消、资源所有权、阅读／TV 和发布契约继续被实际执行；未删有效慢测试换取好看的时间 |
| 覆盖率无未解释损失 | 逐路径／行号记录和命中集合核对；普通 55,832 记录，原基线命中没有丢失；活动取消六行实际命中 |
| 稳定性 | 原生 PNG 等待竞争有受控前后对照，原失败保留；成功样本第一次 attempt 完整通过，无未知 skip、零用例或协议缺口 |
| 职责与资源明确 | 阅读器、收藏和下载按职责拆分；真实资源与原关闭顺序保留；剩余大文件有行为保留依据 |
| 成本可比较 | 修复后三轮同类正常样本的中位数／范围在结果报告汇总；质量反馈提前与整个 PR／所有 runner 成本分别报告 |
| 维护交付 | 双语指南、贡献要求、构建、索引、changelog、基线、决策和本记录同步；最终记录提交仍需正常 CI |

时长降低 20%–30% 是方案的力争目标；是否达标按整个 PR wall 判断，不以汇总 job 代替全量耗时。未达标时报告实测和 Windows 关键路径，保留有效保障。三个共享 runner 样本没有固定缓存条件，不计算 P95 或精确账单。

## 5. 开放 issues 与后续回归建议

截至 2026-11-14 的本轮核查，仓库有 25 条开放 issues。以下给出后续独立功能批次和验收重点；测试整理保留当前有效回归，不能仅凭另一分支的实现或静态线索宣称问题已解决。

| 条目 | 建议顺序及验收重点 |
| --- | --- |
| [#163](https://github.com/CyrilPeng/Venera-Next/issues/163)、[#81](https://github.com/CyrilPeng/Venera-Next/issues/81)、[#123](https://github.com/CyrilPeng/Venera-Next/issues/123) | 按用户要求继续搁置新增功能，已有批量／归档／收藏兼容回归仍保留 |
| [#165](https://github.com/CyrilPeng/Venera-Next/issues/165) Cloudflare JS null | 优先修正当前 Windows 路径的 null 强转；未就绪继续有限检查，保留取消／失效页面边界，不把 null 自动当作验证通过 |
| [#168](https://github.com/CyrilPeng/Venera-Next/issues/168)／[#169](https://github.com/CyrilPeng/Venera-Next/issues/169) 设置与调光跳动 | 优先保持控件位置、面板高度和即时预览，保存状态单独表达；慢保存、失败、连续输入、窄屏／大字号只保留有独立价值的布局与持久化回归 |
| [#167](https://github.com/CyrilPeng/Venera-Next/issues/167) 收藏性能 | 测量键盘动画和页面重建、历史查找与身份映射；先消除“全部”模式不必要的查找，再校验查询、排序、选择和失效回调，真实帧数据与调用次数分开报告 |
| [#170](https://github.com/CyrilPeng/Venera-Next/issues/170)／[#178](https://github.com/CyrilPeng/Venera-Next/issues/178) 阅读卡顿 | 结合分页和瀑布流 profile 测量字节累积／复制、解码、缓存写入和重排；候选优化保留 callback、字节快照隔离、取消与清理；宿主合成耗时不当作 Android 帧改善 |
| [#171](https://github.com/CyrilPeng/Venera-Next/issues/171)／[#172](https://github.com/CyrilPeng/Venera-Next/issues/172) 转场 | 作为独立界面批次校验详情 Hero 和阅读器不透明背景；代表性动画阶段及快速返回覆盖，设备录屏确认最终体验 |
| [#166](https://github.com/CyrilPeng/Venera-Next/issues/166) 验证循环 | 先保证有限重试、取消和明确拒绝原因，核对 WebView／原生请求的真实状态；脱敏证据不足时继续调查，不能承诺第三方站点会接受任意原生栈 |
| [#173](https://github.com/CyrilPeng/Venera-Next/issues/173) 自有列表屏蔽策略 | 明确收藏／历史／本地／追更／稍后阅读与搜索／发现的规则归属；保留列表自己的查询和排序、漫画身份与备份兼容，不修改或删除用户数据 |
| [#176](https://github.com/CyrilPeng/Venera-Next/issues/176) 规则编辑直接删除 | 可作为范围较小的交互批次；确认、稳定规则身份、保存失败、列表刷新及过期对话框边界保留 |
| [#175](https://github.com/CyrilPeng/Venera-Next/issues/175) 封面与详情入口 | 按需展示封面和进入正确详情，返回保持原因列表；继续核对异步 source／comic 所有权和已改变规则 |
| [#174](https://github.com/CyrilPeng/Venera-Next/issues/174) 后台保存后退出 | 先设计应用宿主持有的保存任务与不可变漫画／章节／页码快照，再改变导航；必须保护快速切换、最终应用关闭、失败提示与重试，作为单独数据生命周期批次 |
| [#139](https://github.com/CyrilPeng/Venera-Next/issues/139)／[#157](https://github.com/CyrilPeng/Venera-Next/issues/157)／[#162](https://github.com/CyrilPeng/Venera-Next/issues/162) | 白边裁剪、收藏面板和 HAP 名称的现有实现及回归保留，按实际发版和对应设备结果跟进，测试整理不关闭这些报告 |
| [#152](https://github.com/CyrilPeng/Venera-Next/issues/152)／[#155](https://github.com/CyrilPeng/Venera-Next/issues/155)／[#158](https://github.com/CyrilPeng/Venera-Next/issues/158)／[#143](https://github.com/CyrilPeng/Venera-Next/issues/143)／[#129](https://github.com/CyrilPeng/Venera-Next/issues/129) | 保留已修正行为及现有待反馈状态，结合准确版本和复现结果判断后续路径，未回复不等于解决 |
| [#159](https://github.com/CyrilPeng/Venera-Next/issues/159) | 持久目录完整交付仍受上表条件约束；现有应用内库与能力提示测试不能被当作长期外部库已经支持 |

当前菜单锁已具备收起菜单、边缘小锁、触摸／右键／长按入口保护以及只解锁不立即弹菜单；翻页、滚动和缩放继续可用，换章／旋转保留本漫画会话锁，退出／新漫画重置，TV 明确先解锁再打开。相关组件和集成回归在本轮保留。

后续修复优先表达用户可观察的结果和独立故障边界，复用当前夹具及实际平台入口。改变产品行为时更新对应旧断言及说明，不能让已有测试把已确认的旧问题固定为长期预期，也无需为每个控件或函数新增一批镜像测试。

## 6. 后续正常 CI 的环境故障

`58f42251` 的[质量运行](https://github.com/CyrilPeng/Venera-Next/actions/runs/43464188443)在 Android SDK 安装 emulator 包时报告 `Error on ZipFile unknown archive`。模拟器尚未创建、Provider 用例未启动，后续 evidence 上传亦因没有运行日志而失败。原运行保留，不计为通过，也不纳入正常成功样本。

上一轮相同配置已经实际执行 Provider 并成功，本次日志能确认外部 SDK 准备失败，不能据此认定应用 Provider 行为有回归。继续用有实际内容的后续提交接受正常完整 CI；若安装错误重复，再基于实际 SDK 版本和下载证据处理环境。没有重跑失败 CI 来挑选成功结果。

后续 `1d61b992` 的[质量运行](https://github.com/CyrilPeng/Venera-Next/actions/runs/43469352391)使用相同配置与 Emulator 37.2.13.0（build 16740729），Provider 的 initial／resume 实际均 `ok:true`，原生 descriptor 为零，打开／关闭计数分别 23／23、24／24。后续通过与原失败分开保留，没有改变原运行的未执行结论。
