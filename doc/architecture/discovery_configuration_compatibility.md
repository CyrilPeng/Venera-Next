# 发现与搜索配置兼容 / Discovery and search configuration compatibility

本记录对应原优化方案 P3.3/P3.4/P3.5，基线 `a935483`。配置仍使用原 JSON key，默认值保持不变；类型化读取生成独立、不可变的视图，不在读取时改写原始配置。

| 配置 | 默认值 | 类型化读取 | 保留的语义 |
|---|---|---|---|
| `explore_pages`、`categories`、`favorites` | `[]` | 字符串列表，错误容器返回空列表 | 保留字符串顺序、重复项、空标记和未知源标识；忽略非字符串元素但不修改存储 |
| `searchSources` | `null` | 可空字符串列表，错误容器返回 `null` | `null` 与 `[]` 不合并；列表中的字符串规则同上 |
| `defaultSearchTarget` | `null` | 可空字符串，错误类型返回 `null` | 保留 `_aggregated_`、空字符串和暂时不可用的源标识，不按当前可用源重写 |

`DiscoveryPreferences` 集中上述字段。`Preference<T>`、全局/阅读存储和 `SettingField` 支持可空类型。字段服务显式区分“没有类型规则”和“类型规则返回 null”，后者不会重新回退到原错误值。保存仍先捕获输入，再进入原队列；显式写入 null 和空列表保持不同的 JSON 值。

迁移的消费端：发现页、分类页、网络收藏侧栏、搜索页、聚合搜索、搜索结果页，以及发现设置的四种页面列表和默认搜索目标。它们继续在原位置过滤当前不可用的源、处理顺序、选择目标和响应设置通知。列表表单移除 `settingsIndex` 字符串接口，直接接收类型化 preference；其他尚未迁移的通用表单仍有真实旧调用点。

架构门禁检查这七个页面/表单文件的已迁移 key，同时禁止通过 `settingKey`/`settingsIndex` 构造参数重新引入字面量 key。该门禁不代表所有配置消费端都已类型化，也不代表全部动态调用都可被静态文本规则识别。

## 原始数据边界与后续工作 / Raw-data boundaries and follow-up

- `app_runtime/bootstrap_core.dart::_checkOldConfigs` 仍按原逻辑，仅在原始 `searchSources == null` 时填入当前搜索源。空列表表示主动禁用。该初始化的队列/落盘归属继续按 P4 核查，本批未改成另一种修复流程。
- `features/comic_source/source_configuration.dart` 及 `source_transaction_journal.dart` 的 before/after 快照、缺失字段与显式 null 区别、提交及回滚协议保持原样。不能用类型化视图替代恢复原始数据。
- `app_runtime/webdav_library.dart` 的原队列内列表修改与失败对账保持原样。其余配置类型化继续推进，不把这五个字段当作全域完成。

Typed reads return immutable views and never rewrite source data. String identifiers, order, duplicates and empty markers survive. Null search-source selection means unconfigured; an empty list means explicitly disabled. Nullable target identifiers remain source-independent. Wrong element/container types only affect the returned view. Explicit typed saves use the original queue and JSON keys.

The six consuming pages and discovery settings now use typed access, with guards against literal reads and form keys. Startup initialization, source transaction snapshots/recovery and WebDAV reconciliation retain their raw-data protocols. Those writers and remaining dynamic consumers still require the original P3/P4/P6 acceptance work. Validation is recorded in `optimization_progress.zh.md` and `optimization_progress.en.md` for this unit.
