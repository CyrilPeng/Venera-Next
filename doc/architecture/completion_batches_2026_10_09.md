# 集中收尾批次记录 / Completion batches

执行基线 `fb92ddb`，方案见 [中文第 11 节](optimization_plan.zh.md#remaining-work) / [English section 11](optimization_plan.en.md#remaining-work)。本报告只追加本轮证据，不改写历史全量结果。工具链：Windows、Flutter 3.41.6、Dart 3.11.4；不升级依赖，测试使用 `--no-pub`、合成数据和隔离路径。

## R1.1 收藏入口与批量提交 / Favorite entry ownership

实现 / Changes:

- 批量添加在一个 SQLite 事务内去重写入，输入值在排队前复制；保留顺序、schema 和身份。失败整批回滚，明确提交后不重放。
- 快捷删除、导出、批量添加和网络导入固定原页面、数据库、连接代数及路径；网络导入另固定源实例。删除/添加可排空已接受的有效写入，已退役目标不能写入替换后的库。
- 导入取消等待原请求，迟到业务错误仍保留；取消/不支持不按普通失败重试。真实提交后仍发布原结果，发布重试不重做导入。
- 网络删除/创建复用已有确认与输入组件；源替换使旧列表状态退役，旧结果不进入新页面。添加/转移的追更发布失败仍尝试普通视图刷新，并保留 committed 及全部发布错误。
- 打开目录固定调用时的路径，由原窗口/应用等待实际操作；隔离测试注入 opener，不调用真实文件浏览器。comic tile 和实际运行时注册的 Future/context 签名同步迁移。

验证目录 / Evidence directory:

`D:/GitHub/Agent/venera_next_task_artifacts/2026-10-09-batches-fb92ddb/`

| 日志 / Log | 范围与结果 / Scope and result |
|---|---|
| r1-favorite-entry-baseline.log | 原收藏入口新增基线：0 通过 / 12 失败；生产代码未改时复现 |
| r1-analysis-01.log | 早期 8 条诊断，后续修正调用 tear-off、导入与异步 context 检查 |
| r1-favorite-entry-targeted-01.log | 10 通过 / 10 失败；6 处测试空值断言及 4 处 SQLite DLL 环境问题，保留原日志 |
| r1-native-inputs.json | 从既有 release 复制未修改的原生依赖到新 native 目录，逐份记录源/副本 SHA-256；未重建应用 |
| r1-favorite-entry-targeted-02.log | R1 过滤集 24 通过，含真实 SQLite 回滚/去重/重开、替换源/数据库、原宿主等待 |
| r1-favorite-entry-regression-01.log | 20 通过 / 6 失败；测试路径拼写与移除仍被 MenuButton 使用的 import 导致加载/编译失败，随后修正 |
| r1-favorite-entry-regression-02.log | 8 个测试文件、207 通过；包含既有导入、确认、输入、视图和数据库回归 |
| r1-favorite-entry-consumers.log | 网络页、转移、comic_widgets 与普通确认，59 通过；与上组部分重叠，不相加为新增数 |
| r1-entry-analysis-02.log | 两处剩余样式诊断（无用 import、child 顺序），已修正 |
| r1-entry-analysis-final.log | 严格分析零诊断（26.0 秒） |
| r1-entry-format-final.log | 15 个变更 Dart 文件格式检查通过，无改写 |
| r1-entry-structure.log / r1-entry-architecture-final.log | 结构与架构门禁通过，无规则放宽 |
| r1-entry-inputs.json / r1-entry-commit.json | 基线、变更文件 SHA-256/Git blob 与提交绑定；源码副本保存在 r1-entry-inputs/ |

最终检查日志与输入清单在上述目录记录。两处样式修正不改变行为，因此不重复已通过的行为回归；严格分析和依赖门禁使用修正后的源码。未运行本组全量、覆盖率或 release 构建。

验收范围 / Acceptance: 本组为 R1 P4.4/P4.6/P7.4/P7.5、R2 P6.2 的贡献；R1 尚需源/账户及初始化资源审计。原状态仍为 **24 I / 27 P / 1 U**，不能把此组提交计为全批或原方案完成。

## 后续批次 / Remaining batches

R1 继续源回调、账户与初始化/释放清单；R2 集中存储、同步和配置；R3 集中待审查文件、SCC 和兼容退出；R4 才冻结最终候选并执行一次本地全量与覆盖率。声明 SDK、完整真实 CLI、五平台及六类固定设备性能按原退出条件保留，缺少结果不得由合成单测代替。
