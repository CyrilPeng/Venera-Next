# 发现与显示配置兼容 / Discovery display configuration compatibility

本记录对应原优化方案 P3.3/P3.4/P3.5，基线 `4917b9d`。`DiscoveryPreferences` 集中下列八项配置；发现设置页的默认章节顺序同时复用已有 `AppPreferences.reverseChapterOrder`。原 JSON key、默认值类型和编辑器选项顺序保留。

| 配置 | 原默认值 | 类型化读取与旧值兼容 |
|---|---|---|
| `initialPage` | 字符串 `"0"` | 接受 0–3 的整数和 `int.tryParse` 可解析字符串，包括旧填充、符号和十六进制形式，返回规范字符串；越界、浮点数及错误类型回退主页 |
| `comicDisplayMode` | `"detailed"` | 保留 detailed/brief；未知值统一回退 detailed，布局、漫画卡片及收藏描述使用同一规则 |
| `comicTileScale` | 浮点数 `1.0` | 有限数值限制在编辑器原有的 0.5–1.5；非法类型、NaN/无穷回退 1.0；范围内小数不按滑块步长强制取整 |
| `showFavoriteStatusOnTile` | `true` | 接受布尔值，其他类型回退原默认值 |
| `showHistoryStatusOnTile` | `false` | 接受布尔值，其他类型回退原默认值 |
| `showUpdateStatusOnTile` | `true` | 接受布尔值，其他类型回退原默认值 |
| `autoAddLanguageFilter` | `"none"` | 保留 none/chinese/english/japanese；未知值回退 none；原源限制及显式 language 标签优先级不变 |
| `comicListDisplayMode` | `"paging"` | paging 保留；continuous 和 Continuous 都读为 Continuous，显式保存沿用原编辑器的大写拼写；其他值回退 paging |

读取仅返回有效视图，不修复或重写原配置。真实表单保存仍进入原准入/持久化队列，使用旧 JSON 结构；无关设置、页面列表、设备配置及同步排除字段保持。启动页使用范围受限的配置选择原四个页面。漫画状态标志在每次解析时读取当前设置，未变成启动时快照。

这是对非法配置的明确行为修复：此前启动页越界会索引失败，错误类型/负缩放可导致布局异常，非法显示模式在布局和卡片间解释不一致，未知语言字符串会被添加为任意语言标签。未知列表模式原本进入连续模式，现在使用分页默认值。有效配置的漫画布局算法、收藏画廊/强制详细覆盖及页面选项保持。

验证包括纯配置/JSON矩阵、真实布局和列表组件、375×812深色2倍字号及812×375浅色设置页、真实临时目录保存和重建、排队准入、无关字段保留。MainPage 启动页由范围规则测试及实际读者代码核对证明，未声称执行了完整应用启动或真实设备测试。设置页测试中的惰性列表定位/滑块误触，以及列表测试中的持续加载动画/空Sliver定位假设已修正，原失败日志保留。

应用数据代码仅删除八条重复默认值，存储/导入/恢复主体未改；同步字段协议、通用表单保存实现和纯搜索规则保持原 blob。收藏描述仍读取全局设置，其依赖所有权继续按 P4 验收。已迁移读者/表单的字面量 key 纳入门禁；文本门禁不代表能识别任意动态构造的键，也不完成全域配置验收。

The eight preferences retain their legacy JSON keys, default values and editor choices. Reads return normalized views without rewriting stored data. Explicit edits use the existing admission/persistence queue and preserve unrelated configuration. Startup indices accept legacy integers and parseable strings only within the original four-page range. Lowercase `continuous` remains an alias for the editor's existing `Continuous` spelling. Finite tile scales keep their exact in-range values; no new step rounding is introduced.

Invalid indices, display modes, flags, language values and scales now have deterministic defaults or bounds. Valid layout algorithms, favorite display overrides, source restrictions and explicit language tags remain unchanged. Real component/settings tests and temporary-directory JSON persistence cover the migrated paths; complete application startup and native-device acceptance are still outside this evidence. The remaining global favorite-model dependency, broader configuration matrix and original P0–P8 acceptance stay open.
