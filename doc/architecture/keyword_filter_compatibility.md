# 关键词过滤与保存兼容说明 / Keyword filtering and persistence

基线为 `df8a542`。本轮覆盖漫画列表过滤、普通评论及其预览、章节评论、关键词设置页和漫画卡片屏蔽入口。

| 配置/操作 | 本轮行为 |
|---|---|
| `blockedWords` / `blockedCommentWords` | 保持原 key、JSON 列表与空列表默认值，沿用原导入/同步协议。 |
| 有效字符串列表 | 顺序、重复、大小写、空白及空字符串均保留。空词仍匹配任意文本，不隐式 trim。 |
| 非列表、null、混合列表 | 读取只返回其中合法字符串，非列表视为空；读取不重写原始数据。设置页不再因非法列表抛错。 |
| 评论中的数字/null/对象词 | 以前通过 `toString()` 参与匹配，现在忽略。这是明确的非法值处理变更；原数据保留至用户编辑该字段。 |
| 漫画匹配 | 区分大小写，按关键词存储顺序返回首项；标题、副标题、描述为子串匹配。标签只匹配完整标签或第一个冒号后的段，如 `a:b:c` 还可匹配 `b`，不能据此匹配 `c`。 |
| 评论匹配 | 使用原 `toLowerCase()` 子串规则，不新增语言、分词或正则规则。 |
| 设置页单项编辑 | 添加已有词不重复；删除移除所有相同词。只修改目标字段，使用获准执行时的当前草稿。 |
| 卡片批量屏蔽 | 捕获选择后一次提交成员编辑。新选择不再追加已有词的重复行，避免重试重复添加；历史重复行不会自动清除。 |
| 磁盘写入失败 | 原 Appdata 可能已发布内存或部分文件，不伪造回滚。对话框保留选择、显示错误/重试；重试合并当前草稿且不重复新增成员。 |
| 保存期间退出/移除 | 复用 SettingsSaveState；已接纳保存固定原窗口/应用宿主，根对话框携带原 SettingsSaveScope。强制移除不丢失保存，也不执行卸载后的成功回调。 |
| UI 成功反馈 | 持久化完成后才提示、调用原目标回调及请求关闭。原输入宿主已替换时不调用它，原对话框已被覆盖时不弹出新路由。 |

`KeywordSettingsStore` 从功能设置目录迁到 `foundation/`，已有测试和生产调用直接使用新路径，没有旧路径兼容转发。`KeywordFilter` 只接收显式数据；实际页面在过滤时读取当前配置。Appdata 的存储、同步、恢复和通用保存状态主体未变。

验证包括修复前失败回归、普通 Dart 旧规则对照、真实章节组件、临时目录 JSON 保存/重载、磁盘失败重试及原阅读/窗口排空。六张真实字体截图核查两种屏幕的选择、等待与重试状态。具体冻结版本、全量测试、覆盖率和构建证据见本轮执行记录与仓库外 `keyword-filter-*` 产物。

本说明不代表收藏/其他配置、全部跨域生命周期、完整应用进程、五平台或固定设备性能已经验收。

The legacy keys/defaults and valid string matching remain. Reads filter malformed values without rewriting raw storage. Non-string comment entries no longer match via implicit stringification. Card selections now make idempotent membership additions instead of appending duplicates; existing duplicates survive. Explicit edits repair only their target field and merge the admitted current draft. Real persistence failure stays visible and retryable, with accepted work retained by its original reader/window/host. This scope does not replace full configuration, process, platform or performance acceptance.
