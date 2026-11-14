# 测试整理：模块与候选去留审查

本记录配合[实施方案](test_reorganization_plan_20261113.zh.md)、[运行基线](test_reorganization_baseline_20261113.zh.md)及[结构化变更记录](test_reorganization_changes_20261113.json)使用。基线为 `482810df369d126e4011be31d64408e33aede76f`；S4 其余模块批次的来源为 `fa494135f01157a285abf36bde5045169114a6d7`。批次实际结果在运行基线中更新，最终规模与成本在 S7 汇总。

## 1. 审查范围和证据口径

根测试的 **21 个模块**全部进入清单、实际发现与运行结果对照；根 `support/`、`fixtures/` 和 67 个外部源码单元另行登记。模块决策结合当前生产入口、已有故障边界、共享资源与候选源码，不以测试名称中的 `legacy`、`integration` 或平台标签决定删除。

基线的 560 个主测试文件为 178,391 物理行；全部测试 Dart 为 583 文件／179,922 行，其中 23 个支持／探针文件为 1,531 行。这里包含注释与空行，计数从基线 Git blob 批量读取。主测试与含辅助代码的总量分别比较，不能将搬到 support 的行数都当成删除收益。

除 S0 的 19 组顶层声明候选外，本轮又检查了 H 来源提交的 4,264 个内联 `test`／`testWidgets` 注册点：完整 callback 源码没有相同组；仅遮蔽字符串、数值输入和局部变量名后得到 13 组语句形状候选，逐组阅读其输入、断言和夹具。这个静态数不等同于 S0 运行时展开的 6,062 项，也不能证明不存在其他语义重叠。动态参数循环、包内入口包装和实际文件加载由 machine 结果与清单检查保障。

## 2. 全模块决策

下表规模是原基线主 `*_test.dart` 的文件数／物理行。辅助代码以及最终计数单独汇总。

| 模块 | 基线规模 | 本轮决策及必须保留的边界 |
| --- | ---: | --- |
| app_runtime | 42／8,642 | 共用手动周期计时器；保留启动失败、关闭等待、无头进程、窗口宿主、同步和输入接线的不同阶段结果 |
| app_shell | 2／170 | 保留启动失败脱敏诊断、过期剪贴板完成和大字布局；不是普通状态单元测试的重复 |
| components | 34／10,971 | S2 解除借用测试文件的导入，I 共用 List 型 JS callback；保留弹窗、清理失败、取消、焦点及过期操作 |
| comic_details | 20／4,277 | 保留下载、章节选择、排序与归档呈现；小型 Actions 依赖各自漫画工厂和 context，SelectionCleanupFailure 展开就地保留 |
| comic_source | 48／18,263 | 共享适用的 QuickJS 环境探测；保留真实 ABI、安装／变更事务、进程崩溃恢复、脚本生命周期和所有权。编辑器与更新器的等待策略分别保留 |
| comic_storage | 1／176 | 保留自然排序、超大编号、确定性并列、封面筛选、混合目录、单层外壳和同步／异步布局规则 |
| comic_widgets | 7／1,356 | 保留规则消费者接线、封面内状态布局、深浅色、大字、历史徽标与列表生命周期；规则单元和界面接线具有不同作用 |
| favorites | 34／16,983 | F 按事务、生命周期、旧库兼容与更新追踪拆分；I 统一 SQLite 探测。旧索引、层级身份、失败回滚和重启保留继续执行 |
| follow_updates | 7／2,257 | 与 history 共用原 source 工厂；保留准备屏障、惰性队列、取消、最终通知、窗口关闭和持久化失败。短 item 工厂与有限等待就地保留 |
| history | 16／4,635 | 共用 SQLite 探测及 source 工厂；保留提交证据、只追加一次、发布失败、保留期变化、附加 repository 和图片收藏缓存竞争 |
| image_favorites | 6／1,044 | S2 共用合适的数据准备；保留原页身份、PageController 释放、时间范围、磁盘重建和过期统计／布局回调 |
| local_comics | 53／18,197 | G 拆分下载策略、取消、队列与归档；复用 SQLite 准备。EPUB 的文本内容与越界图像、PDF 的普通倍率与上限不是重复；坏包、续传、原子提交和真实文件仍保留 |
| reader | 83／30,047 | S3 按行为拆分 179 项回归，I 共用图片 codec／样本与 Favorites stub；保留七种模式、退出、菜单锁、白边裁剪、过期页面、真实窗口与原生生命周期 |
| search | 3／163 | 保留支持源、非支持源、已有语言条件和 none 的独立规则；少量单断言用例继续直接表达，避免参数表比原测试更复杂 |
| settings | 27／7,655 | 保留读写队列、失败重试、规则编辑所有权、旧导入、真实字段与页面接线；现有有限持久化等待不强制改成通用 settle |
| sync | 44／18,133 | H 共用 Dart VM 定位及响应夹具；保留上传失败、竞争、旧备份、真实 SIGKILL、磁盘检查点和双库恢复，慢进程用例继续进入 PR 全量验证 |
| webdav_library | 7／3,449 | 保留配置、快照、传输与同步生命周期；clear／close 版本、取消后等待、口令保存及旧配置互不替代 |
| foundation | 92／23,047 | 共用原生／SQLite／JS／图片夹具，核实文件名候选并纠正弱断言；兼容迁移、资源释放、文件身份、真实 serializer 和设备策略边界保留 |
| network | 26／7,040 | 共用适用 QuickJS 准备；新增生产活动流的真实取消屏障回归，原低层 callback ACK 回归保留。共享流、缓存、重定向认证、请求关闭互不替代 |
| routing | 6／1,153 | 保留页面替换、Cookie 授权、WebView 生命周期、菜单与 Windows 代理／环境；旧 C++ 模板在 S5 按失效 API 证据单独处理 |
| tool | 2／733 | 许可证、补丁来源、源码清单与依赖版本检查分别保留；S5 将工作流结构约束迁入锁定的 YAML 解析入口，脚本行为仍独立执行 |

## 3. 19 组辅助声明候选

原始位置与完整源码保存在 S0／S4 审查产物；实施的旧新位置、标识改名及验证在结构化变更记录中追溯。保留的短定义不等于允许借用其他 `_test.dart`；它们继续在自己的文件内使用。

| 候选 | 对象 | 决策／理由 |
| --- | --- | --- |
| 1 | 两个 `_PeriodicTimer` | I 抽为模块 `ManualPeriodicTimer`，保留 active、cancel 和手动 tick 的原契约，每个用例独立实例 |
| 2 | 两个 List 型 `_Callback` | I 抽为 `OwnedJsCallback`，保留复制参数、调用次数、释放次数；不能用它替换不同参数契约的 fake |
| 3 | 两个零参数 `_Callback` | 就地保留短定义。它们忽略 List 并调用零参数 action；共享 List callback 会改变契约，当前两个消费者的直观声明无需再增加适配层 |
| 4 | 两个 `_causes` | 保留 SelectionCleanupFailure 的 13 行局部展开；不能替换为其他异常类型的错误展开 helper |
| 5 | 两个 `_Actions` | 保留。相同文本中的 `_comic()` 指向各自工厂，context、漫画身份与菜单 controller 的生命周期须独立核实 |
| 6 | 两个 `_flush` | 保留有限持久化等待：明确 Future 完成和错误，500 次上限、10 ms 真异步等待及 pump；不改写等待契约 |
| 7 | 两个 `_FakeJSInvokable` | 保留短的原 List 透传及 destroyCount 契约。共享 callback 会复制 List 并增加 calls，不能机械替换 |
| 8 | Editor／SourceUpdate `drain` | Editor 已在 S2 抽取；SourceUpdate 仍用自己的 pumpUntil。虽然 drain 文本相同，依赖的 pumpUntil 分别使用 0／20 ms，不能强制统一 |
| 9 | 两个 `_until` | 保留短的有限谓词等待和 10 ms pump；不同于已有共享 helper 的时序，未用无界等待替换 |
| 10 | 六个 SQLite 探测 | 与候选 11 一并在 I 抽为 `sqliteTestAvailable`；保留实际内存库打开、dispose，以及必需依赖缺失时抛出 |
| 11 | 另外三个 SQLite 探测 | 同上；收藏 F 拆分后的公共名称及全部消费者也更新，仍是九个原探测的合并 |
| 12 | 两个追更 `_item` | 保留短领域工厂，不为了统一外观增加支持文件；关闭与正常追更的独立测试不删 |
| 13 | 两个 37 行 `_source` | I 向现有 `comic_source_fixture.dart` 增加 `stubComicSource`，保留原 Test Source／test.js，现有 ComicSourceFixture 默认行为不改 |
| 14 | 三个 `_Favorites` | I 抽为 ReaderFavoritesStub，只供读取夹具使用；不用真实库替换其原 stub 语义 |
| 15 | 三个 `_Codec` | I 抽为 TrackedImageCodec，保留帧、取帧与 dispose 计数 |
| 16 | 三个 `_image` | I 抽为 opaqueTestImage，保留实际画布、大小、颜色及 picture 释放；不换成恒定字节 mock |
| 17 | 两个 `_dartExecutable` | H 复用现有 Dart VM helper，保留不经 shell 的 SDK 查找与 dartvm 选择 |
| 18 | 两个 `_response` | H 抽为 dataSyncResponse，保留字节流、默认内容长度及传入 header 覆盖 |
| 19 | 三个 `_Reference` | I 抽为 OwnedJsReference，保留引用身份与原释放计数，每个场景独立创建 |

另外，18 处 QuickJS 准备不都表现为顶层声明；I 统一其内联／函数探测，保留当前 Windows Debug／Release bundle、Linux／Apple 库路径及必需依赖错误。能力探测不会把 CI 缺库写成合法 skip。

## 4. 13 组行为形状候选

| 候选 | 保护的输入或契约 | 决策 |
| --- | --- | --- |
| 1 | EPUB 纯文本内容／图片路径逃逸 | 保留不同故障与错误消息，真实目录收尾继续执行 |
| 2 | 旧导出 JSON 的 String／int 字段类型 | 保留各自类型校验及字段诊断 |
| 3 | emoji 标题／CJK middle 的字节预算 | 保留不同 Unicode 预算；将声称“长 extension”而实际为 `.png` 的标题改为准确的 CJK middle 描述 |
| 4 | 普通 CJK 标题／超长 middle | 保留分别消耗标题和 suffix 预算的边界 |
| 5 | ASCII 字符上限／完整 NFC 日文 | 改为精确文件名结果，去掉该输入下更弱的 suffix／预算重复断言；其他字节预算边界保留 |
| 6 | 本地许可证＋版本／源码＋未登记文件 | 保留不同治理对象与诊断，不能以同样写文件的语句合并其契约 |
| 7 | 有效 image extension／非图像 extension | 保留允许与拒绝的 MIME fallback 边界 |
| 8 | 空标题的有效 fallback／标题与 fallback 都无效 | 纠正后一用例的输入并断言精确 `file_EP1_P1.jpg`；同输入的 returnsNormally 声明没有额外边界，删除并记录替代用例 |
| 9 | PDF 三倍点数／最长边限幅 | 保留两个生产分支和准确宽高 |
| 10 | 补丁说明丢失来源／第三方许可证字节变化 | 保留不同来源／许可证契约 |
| 11 | 支持源、非支持源、已有语言条件 | 保留三个独立规则；短测试直接表达更清楚 |
| 12 | 简体／繁体显式语言 | 保留各自映射 |
| 13 | 显式 English／system／未知持久值 | 保留直接配置与系统 fallback 接线，不能因结果都是 English 合并 |

文件名的“标题和 fallback 都无效”用例原来传入有效的 `comic`，与名称不符；纠正后使用原 returnsNormally 声明的同一输入，增加精确结果，才使后者成为可证明的弱重复。原有效 `image` fallback 用例继续存在。本轮不是先删断言再声称有替代。

## 5. 关键回归与执行边界

活动 Rhttp 流测试使用真实 Rust bridge、本地 HTTP server 和明确 EOF 屏障：收到首字节后，要求取消后的 native request 和生产 body 先完成，server EOF 仍未放行。该路径对应 S3 波动的六行（394、396、397、398、401、403），原低层 callback ACK 测试保护另一阶段，继续保留。Windows 与 Linux 的实际结果分别记录，不能用宿主编译推断其他设备行为。

H 清理的 Android-only Dart 声明在普通、Windows、HAP 桌面 host 都无法获得 Android 运行身份。实际 serializer／源文件策略回归继续执行；原生分享 primitive 在 S5 补齐独立 CI 入口。真实 Android／鸿蒙分享、签装、覆盖升级及长期存储验收仍按既有平台指南记录，宿主测试和编译结果不记为设备通过。

所有旧库、旧备份、事务回滚、双库恢复、下载取消与续传、路径逃逸、FFI 所有权、窗口关闭、菜单锁及 TV 回归都按适用入口保留。#163、#81、#123 的新增功能继续搁置；有效兼容与已发布行为的回归不受搁置影响。
