# 摘要订阅与弹窗路由归属 / Summary and dialog ownership

本批相对 `cffb854`，首页向漫画源与历史摘要传入已存在的管理器，摘要只借用显式所有者。共享标题解决窄屏大字号布局，评分与脚本丢弃确认固定原路由，同步错误弹窗使用局部 context。

## 摘要数据与监听

`ComicSourceSummarySnapshot` 从显式源列表和更新映射生成不可变名称列表及可更新数量。保留安装顺序、重复名称/身份，以及原管理器 `find` 采用首个同 key 源的规则；未安装源的更新忽略。版本比较仍复用原 `compareSemVer`，保留 hotfix/prerelease 及无效版本的既有行为，没有新增版本校验。

`ComicSourceSummary` 接收必传但可空的管理器。空或正在关闭的所有者显示空摘要，不调用全局工厂或重新订阅已释放的管理器；正常监听由 ListenableBuilder 随借用对象替换/卸载释放。管理器只新增 `isClosing` 只读 getter，其他方法体未变。

`HistorySummary` 继续使用 State 保存历史与计数，合并传入的历史管理器与收藏通知。绑定/显式替换所有者以及通知时读取，同一所有者下的主题或布局重建只复用缓存。替换/卸载时从原合并监听中移除回调，不从可能已经更换的全局缓存查找清理对象，也不销毁借用对象。未初始化、已关闭或空数据库显示空摘要，收藏通知不会查询已关闭连接。

首页组合层读取 `HistoryManager.cache`、`LocalFavoritesManager.cache` 和 `ComicSourceManager.current`，均只获取已存在的对象。摘要不自行创建管理器；生产组合层和更广的初始化/退出策略仍由原应用生命周期负责。

## 弹窗和操作准入

- 同步错误弹窗使用当前挂载组件的 context；保留 Flutter showDialog 原有的 root-navigator 默认值。没有改变同步请求、错误内容或导航栈策略。
- 评分提交前检查 NavigationAdmission，接受后记录原路由/导航器。异步结束后先清除组件加载状态，再确认挂载、原路由身份、原路由仍为当前页面、导航器有效及准入允许，才显示反馈或关闭。成功/失败回写都不能影响随后压入的新页面；原对话框仍被覆盖时保持存在。
- 脚本保存和丢弃确认在冻结宿主中不接纳新操作。丢弃对话框出现前固定原编辑器路由，确认结束后仍需原路由当前且准入允许才关闭。确认期间出现新页面时保留编辑器和草稿。现有保存快照、错误展示和编辑器布局不变。
- 评分/编辑器 build 主体保持一致。此批没有修改 `ComicSourcePage` 保存回调里的全局管理器获取和外部编辑器重载流程；已接受管理器变更的排空机制沿用原实现，调用者生命周期另行审查。

## 标题与兼容边界

`SummaryHeader` 保留 56 像素高度、16 像素水平内边距、标题字体、徽标间距/颜色和右侧箭头。标题使用可收缩单行布局，窄屏或大字号时省略；完整原文本仍在语义树中。常规字号徽标紧随标题，未移到固定右侧位置。摘要内容列表、卡片与导航主体沿用原行为。

375×740 深色和 812×375 浅色下，源/历史四组普通字号真实字体、MaterialIcons 图像与旧版逐像素一致并已目视核查。对照是空摘要/标题，不能代表有数据的完整首页。两种尺寸 2 倍字号及减弱动态效果的 widget 测试覆盖布局和完整语义，源名称/更新数另有数据用例。没有宣称实机字体验收。

## 分类与证据

七个待审查文件完成 UI 职责核实：comic_source_summary、history_summary、sync_status_summary、rating_dialog、source_script_editor、action_button、cover_viewer。后两个文件源码 blob 不变，动作委派和真实图片收藏保存回归已经核对。新增 shared header 为 UI，源摘要快照为受业务边界约束的入口。

完整清单为 506 文件：322 业务、151 UI、33 待审查，237 个业务入口。原保护、57 条允许特性边及剩余 46 文件 SCC 保持；新业务入口接回七个已审查 UI 与共享标题的八个探针均被拒绝。架构门禁规则未改，分类不是全域生命周期验收。

新增 18 项回归：源监听 4、源快照 2、历史监听/查询 4、同步局部导航 1、弹窗路由/准入 5、摘要大字号 2。扩展 161 项覆盖相邻详情、脚本编辑、管理器关闭、历史、同步、真实图片收藏保存及 ImageSaveBinding。七项原代码缺陷在修复前复现；首轮旧源测试的外层 FakeAsync 清理等待、主题未稳定的探针、缺少 sqlite3.dll PATH 与一项格式诊断均保留并修正。

重构期间，查询次数回归发现主题切换后累计 8 次查询而非原来的 2 次。最终保留 HistorySummary 的 State/缓存，只在绑定和通知时查询；此回归在冻结前通过。未添加跳过或放宽超时。

最终全量、覆盖率、构建、冻结源码和提交以执行记录及 `summary-dialog-artifact-hashes.json` 为准。原 52 项仍为 24 I / 27 P / 1 U；其余文件语义、导航环、配置/接口/生命周期/存储/JS/兼容、完整 CLI、声明 SDK、五平台及固定设备性能继续验收。

## English

Home supplies existing managers explicitly. Source summaries follow the same borrowed owner for listening and snapshot reads; null/closing owners render empty without creating a manager. The immutable source snapshot preserves ordering, duplicates, first-key selection and existing version comparison. History summaries detach original borrowed listeners and retain query caching: only binding and notifications query the database, and closed/null owners are never queried.

Sync errors use local context with the existing showDialog navigator default. Rating and editor actions honor NavigationAdmission. Late rating results and discard confirmation can only present feedback/pop while the original route is current and its navigator remains mounted. Covered routes/drafts remain. Existing editor save snapshots and rendering remain; production caller manager capture and external reload are still pending.

The shared title retains dimensions, normal badge placement and full semantics while allowing constrained text to ellipsize. Four real-font normal-layout empty-summary pairs match exactly; populated full-page/device acceptance is not inferred. There are 18 new and 161 extended regressions, including real SQLite behavior and the notification-only history query cache. Seven UI classifications and one new business entry retain all gates, 57 feature edges and the 46-file SCC; eight reverse-UI probes fail as expected. Full-plan acceptance remains open.
