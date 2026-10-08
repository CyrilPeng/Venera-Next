# 收藏转移与元数据刷新兼容记录 / Favorite workflow compatibility

日期 / Date: 2026-10-09。基线 / Baseline: 0f52561c7000f71f239a6afed1e7f799b8dd3382。

## 行为和数据 / Behavior and data

| 边界 / Boundary | 保持和修正 / Preserved behavior and fixes |
|---|---|
| 转移 / Transfer | 原文件夹及固定 (id,type) 选择，多目标拷贝与可选删除仍在既有一个 SQLite 事务中。实际准入核对原数据库，成功后关闭原外层路由；已提交或未知结果不重放。 / Original identities and the existing single multi-target transaction remain; original database admission and outer-route dismissal are enforced. |
| 元数据 / Metadata | 原 name/author/cover/tags 映射、四项一批和三次读取尝试保持；保存不再触发重新读取和重复写入。 / Existing mapping, four-item batches and three ordinary read attempts remain; a save failure never repeats loading or writing. |
| 存储 / Storage | 原 repository blob 不变。UPDATE 仍只改 name、author、cover_path、tags；rowid、身份、原时间、顺序、翻译标签、追更字段、其他类型/文件夹和关联均由真实 SQLite/重开测试验证。 / Repository SQL/schema is unchanged; original identity and unrelated columns/rows/links survive reopening. |
| 取消与源 / Cancellation and source | 固定原源实例与 loader；取消阻止后续保存和批次，并等待已接受的原请求。Res.failure 在 scope 内解包，真实迟到错误不被取消覆盖。 / Original source/loaders remain fixed; cancellation drains accepted work and preserves genuine late errors. |
| 关闭 / Shutdown | 原应用及 WindowFrame 等待已接受的完整保存或读取。移除失败保留原路由与错误，明确重试只清理；可见路由与任务都结束才释放刷新 notifier。 / The original host drains accepted work; explicit cleanup retry retains original route identity and failures. |
| API 和资源 / API and assets | 公开 JS/CLI、原 parser 和请求/窗口原语不变；只给 zh_CN/zh_TW 加入 Cancelled。旧两个页面方法及无用途字段删除，无兼容转发。 / Public protocols and resource primitives are unchanged; only two translation keys are added and obsolete workflow methods/fields are removed. |

## 验证 / Validation

新增 79 项：转移 34、元数据 UI 25、业务服务 17、真实合成 QuickJS 3。最终定向 656 通过，全量 4844 通过/2 项既有跳过，LCOV 39,747/50,169（79.23%）。严格分析无诊断；Python 110 项/3 项既有跳过；结构、架构、版本、Git 依赖和格式检查通过。

79 added tests cover actual SQLite triggers and post-commit failures, (id,type)/row preservation and reopening, real source-parser/native Promise completion, original page/window ownership and cleanup failure. Targeted 656 pass; full 4844 pass / 2 existing skips; fresh coverage 79.23%. Strict analysis and all listed gates pass.

生产转移基线 3/27、元数据基线 2/17；元数据基线时转移已修改。MenuButton/enableTagsTranslate、reorderFolders 和销毁后 Navigator 查询均是夹具问题；误删 _checkExitSelectMode 是中间实现错误，首次 teardown 修补位置也有误。全部日志和源码快照保留，未通过增加跳过或放宽超时掩盖失败。

Baseline transfer was 3 pass / 27 fail and metadata 2 pass / 17 fail, with transfer edits already present during the metadata baseline. Fixture/compiler mistakes and the intermediate accidental method removal remain separately recorded. No new skips or timeout relaxation were introduced.

## 边界、交付与剩余范围 / Boundaries, delivery and remaining scope

最后 Dart 编辑和完整格式检查后冻结 15 条变更路径及全部 1020 Dart 文件。当前分类 520 / 326 业务 / 166 UI / 28 待审查 / 241 入口；91 个基线 blob、57 条边和原 46 文件 SCC 不变，12 项反向探针拒绝。favorite_actions.dart 剩余添加/导入等职责仍待审查。

业务入口清单同时按路径排序，原条目集合保留；只有本轮新服务及对话框增加分类，没有新增依赖例外。后续收藏发布审计还需覆盖转移在追更通知抛出后对普通视图的刷新；本轮 committed 保留和不重放证据不替代全部观察者失败矩阵。

The business entry list is also sorted by path with every existing entry retained; only the new service and dialogs add classifications, without new dependency exceptions. Follow-up publication review must cover ordinary view refresh when a transfer's follow-update notification throws. Preserving committed state and preventing replay does not complete every observer-failure scenario.

Artifacts use the favorite-workflow-ownership family. The manifest binds frozen source, normalized Git blobs, logs, fresh coverage, Windows artifacts, helper hashes and the delivered commit. All previously bound artifact families remain read-only. The code rollback unit does not migrate database schema or roll back user data.

本机 SDK Flutter 3.41.6 / Dart 3.11.4；Windows 构建与打包资源校验记录在执行/验收文档。本轮仅使用合成数据，未打开真实应用。声明 SDK 3.41.4、五平台完整验收、真实设备人工场景及六类固定设备性能仍未完成。

The original 52-item status stays 24 I / 27 P / 1 U (46.2% implemented items). This unit does not complete all favorite actions, domain-wide interfaces/settings/lifetimes/storage/source/account contracts, pending SCC classification, compatibility retirement or complete CLI acceptance. Declared SDK, full platform and fixed-device performance acceptance remain open.
