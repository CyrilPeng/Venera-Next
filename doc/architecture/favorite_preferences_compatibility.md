# 收藏配置兼容边界 / Favorite preference compatibility

本批相对 `a826d5a` 集中十项收藏配置及实际消费端，不改变存储 key、JSON 类型、数据库 schema、源协议或 CLI 参数。

| 配置 / Key | 默认 / Default | 读取规则 / Read rule |
|---|---|---|
| `favoritesDisplayMode` | `list` | `list` / `gallery` |
| `favoritesGalleryColumns` | `0` | 先 round；0 为 Auto，其余限制为 2–6 / round, preserve zero, then clamp |
| `localFavoritesFirst` | `true` | 仅接受 bool / bool only |
| `autoCloseFavoritePanel` | `false` | 仅接受 bool / bool only |
| `newFavoriteAddTo` | `end` | `start` / `end` |
| `moveFavoriteAfterRead` | `none` | `none` / `end` / `start` |
| `quickFavorite` | `null` | String 或 null / String or null |
| `onClickFavorite` | `viewDetail` | `viewDetail` / `read` |
| `readLaterFolder` | `null` | String 或 null / String or null |
| `followUpdatesFolder` | `null` | String 或 null / String or null |

读取不改写原数据；错误类型和未知选项采用默认值。文件夹字符串保持空值、空白、大小写、Unicode 和未知名称，存在性校验仍属于收藏管理器。NullableStringPreference 的 null 与空字符串不合并。

合法列数保留旧 round→零哨兵→clamp 顺序，例如 -0.49 和 0.49 为 Auto，-0.5 为 2，2.5 为 3。普通 Dart 进程对照从 HEAD 提取的原函数，20,009 个有限/非数字输入一致。NaN/正负 Infinity 新增回退 Auto；它们不是合法 JSON，原 Appdata 快照编码仍会拒绝内存中的非有限值，本批不承诺通过点击保存修复这种内存数据。

明确的非法旧值行为变化：

- 非法新增位置原先等同于插到开头，现在回退到末尾。
- 非法读后移动原先虽不改变顺序，仍更新普通收藏时间并通知；现在按 `none` 处理，只保留追更已读处理，普通收藏时间不改。
- 非法点击动作原先进入阅读，现在回退详情页。
- 错误类型布尔值/可空文件夹不再导致对应消费端的动态转换异常。

初始化修复必须比较原始字段，否则错误类型先被转成 null 会漏掉修复；清空失败回滚必须恢复原始 tracking/quick 值。两处继续通过规范的 `.key` 访问原值，主体仅有 key 表达式和格式变化。重命名/删除仅修改精确匹配名称，保留无关或非法原值。数据库事务、修复重试、发布顺序和原 SettingsSaveState 的准入/失败重试/退出归属未改。

实际设置页改为已有类型化字段组件，菜单保存写入规范 Preference；获准时才读取当前 draft，修改选中的字段，保持其他字段。旧显示 helper/key 常量不再导出，仓库所有调用已迁移；不保留转发兼容层。Appdata 只移除十项重复默认值，保存/同步/恢复实现未改。

验证使用合成设置、临时目录和 SQLite。新增 15 项回归覆盖非法值、非有限值只读、JSON 保存/重载、队列等待、宿主移除、两种尺寸/大字号、普通收藏时间和文件夹修复。扩展专项 236 项通过；实际收藏显示/设置菜单四组旧新图像逐像素一致。截图中的标题和菜单加载真实字体，但自定义清理按钮使用测试引擎默认字体，不能据此宣称该按钮的字体或全页排版完成实机验收。

## English

Ten preferences preserve their legacy storage keys, JSON types and defaults. Reads normalize without rewriting storage. Folder strings preserve empty/whitespace/unknown names; the manager still validates existence. Finite column behavior is unchanged, with 20,009 samples compared against the extracted original function. Nonfinite values now read as Auto but remain invalid JSON; snapshot persistence still rejects nonfinite in-memory data.

Malformed insertion/movement/click choices now use end/none/viewDetail. In particular, invalid movement no longer updates ordinary favorite timestamps; tracking mark-as-read behavior remains. Invalid boolean/folder types use defaults instead of dynamic conversion failures. Initialization and clear rollback retain raw values via canonical `.key` access; rename/delete continue exact matching. Existing database/save/admission/retry/exit protocols are retained, and obsolete display helpers/constants have no forwarding aliases.

Fifteen new regressions and 236 extended tests cover temporary JSON/SQLite, malformed reads, queued saves, removal, viewport/text scaling, timestamps and repair. Four before/after menu image pairs match exactly. Titles and menus use loaded fonts; the custom cleanup button still uses the test engine's default font, so these captures are not device typography or whole-page layout acceptance. Final suite/build evidence is recorded in the progress and acceptance documents. Remaining configuration domains and platform/performance requirements stay open.
