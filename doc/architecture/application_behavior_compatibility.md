# 应用行为配置兼容 / Application behavior preferences

相对基线 `e6fd5c7`，本批集中 `language`、`checkUpdateOnStart`、`historyRetentionDays` 三项配置，保持原 key 和默认值 `system`、`false`、`0`。读取不改写原值，显式编辑仍走 Appdata 的原保存队列。

## 语言与启动更新

语言只接受原四个选项：system、zh-CN、zh-TW、en-US。错误类型和未知字符串均视为 system；原语言解析器的脚本优先于地区、系统语言遍历顺序和英文回退不变。未知字符串原本已按系统语言解析，但原 MyApp 仅为字面值 system 响应系统语言变化；现在这一判断也使用同一类型规则。未在本批启动完整 MyApp 或宣称原生语言事件已实机验收。

启动更新开关只接受 bool，错误类型回退 false。更新检查的源检查、24 小时预约、时间戳保存、取消和关闭顺序未改。`lastCheckUpdate` 隐式时间戳尚未完成类型化，本批不覆盖其非法值或其他启动配置。

## 历史保留

- 有限数字按原 round 规则读取为整天。0 和负数禁用；错误类型、非有限数、超过一亿天的值禁用，避免异常或巨大 Duration 溢出。一亿天以内的正数保留，不按编辑器上限缩短。该上限在当前日期及本机 DateTime/Duration 中验证；不声称所有异常系统时钟均已验证。
- 编辑器仍为 0–182 天、每档 7 天。旧配置如 365 天显示实际天数，滑块停在显示上限；只读不会改值或清理。原泛型滑块无法显示超范围值。明确选择新值才替换原值。
- 拖动只预览，松手提交最后选择；原来在 onChanged 的中间档位也会保存，可能提前按中间天数清理。提交后禁用控件，SettingsSaveState 等待设置持久化及历史删除，错误和重试均归原窗口/阅读任务；移除页面不丢弃已接受清理。
- HistoryRetentionChange 捕获天数、原管理器代次及第一次清理的截止时间。一次数据访问许可覆盖保存和清理；重新打开的连接拒绝旧请求。失败重试重新保存同一选项，并按同一截止时间重试删除；成功请求不重复执行。
- 设置文件与 SQLite 删除不是跨库事务。设置成功而删除失败时，选项保留并报告错误；用户可重试，后续启动仍执行既有保留策略。保存失败不开始删除。SQL schema、删除语句、队列与通知机制不变，未承诺全部崩溃/平台失败矩阵完成。
- 显式编辑保存整数天数；旧滑块可能保存 JSON 小数形式（如 14.0），旧读者接受 num，两者数值兼容。原始小数配置只读不重写，实际清理仍按原整数取整结果。

## 验证与范围

三个修复前回归复现语言/更新开关类型异常及历史初始化失败。新增 15 项回归覆盖非法值只读、365 天实际保留、JSON 保存/重载、真实 SQLite 删除失败、原连接代次、排队/移除/重试及两种尺寸。扩展 185 项通过；普通 Dart 进程 12,303 组合法保留决策/截止时间与旧行为一致。两组真实字体静态控件图像与旧布局逐像素一致，交互和失败行为另由 widget 测试验证。

首次测试存在错误的释放方法名、导入位置及 Future.then 类型夹具问题，均保留诊断并修正。真实 SQLite 发现工厂内嵌套闭包捕获管理器导致 isolate 传参失败，现由独立方法创建只捕获截止时间的回调。另两个 widget 收尾等待由 FakeAsync 队列跨时钟导致；探针确认任务已完成，夹具在原模拟时钟内排空并关闭缓存，收尾断言无历史待写入，不增加跳过或延长超时。

HistoryRetentionChange 为纯业务入口；设置页移除原 history 聚合 UI 导入后退出依赖环，剩余 SCC 从 47 文件缩为 46。全部旧保护和 57 条允许特性边保留。其余配置、49 个待审查文件、全域接口/生命周期/存储/JS、完整 CLI、声明 SDK、五平台与性能继续按原方案验收。

## English

Three preferences retain legacy keys/defaults. Language accepts the existing four choices; unknown/wrong-type values use system resolution, and MyApp's locale-change condition now uses that same rule. The resolver itself is unchanged; full native MyApp locale events were not exercised. Startup updates accept bool only and retain reservation/cancellation/close ordering; the implicit lastCheckUpdate timestamp remains outside this migration.

Retention reads round finite values and disable invalid/nonpositive/over-100-million-day values. Supported values above the editor's 182-day limit are preserved. The unchanged 7-day slider previews during dragging and commits on release, avoiding cleanup at transient intermediate values. SettingsSaveState retains persistence and cleanup after removal, with explicit failure/retry. One captured change retains its original database generation and first cleanup cutoff. Successful runs do not repeat; retries persist the same choice and reuse the cutoff.

Settings persistence and deletion are not a cross-database transaction: persisted choices survive cleanup failure. Existing SQL/schema/queues remain. Explicit saves use integer days, numerically compatible with legacy JSON doubles; reads never rewrite raw fractions. Fifteen new regressions, 185 extended tests, 12,303 plain-Dart comparisons and two static before/after image pairs provide local evidence. See current progress/acceptance records for final suite/build results and outstanding platform/performance requirements.
