# 异步页面上下文检查清单

2026-10-03，基于本机工作区（含用户未提交改动）的 flutter analyze。启用规则后初始 85 处，导入流程修复 21 处、评论视图修复 8 处、漫画源页面修复 8 处、本地库页面修复 3 处、同步窗口绑定修复 1 处，历史页面修复 2 处，收藏面板修复 7 处，网络收藏页修复 9 处，应用设置修复 9 处，本地收藏设置/图片统计各修复 1 处，富文本评论修复 1 处，详情点赞/评分修复 4 处，详情下载修复 3 处，本地收藏文件导入修复 2 处，网络收藏批量导入修复 1 处，调试提示/本地跳转各修复 1 处，阅读手势再修复 2 处，剩余 0 处。规则已提升为 warning。其他 info 曾随死代码清理从 23 减至 21；类型与语法收尾后当前严格分析为 0 项诊断。

| 文件 | 剩余诊断 |
|---|---:|
| `lib/app_runtime/init.dart` | 0 |
| `lib/components/rich_comment_content.dart` | 0 |
| `lib/features/comic_details/actions.dart` | 0 |
| `lib/features/comic_details/comic_page.dart` | 0 |
| `lib/features/comic_details/favorite.dart` | 0 |
| `lib/features/favorites/favorite_actions.dart` | 0 |
| `lib/features/favorites/network_favorites_page.dart` | 0 |
| `lib/features/image_favorites/image_favorites_summary.dart` | 0 |
| `lib/features/reader/gesture.dart` | 0 |
| `lib/features/settings/app.dart` | 0 |
| `lib/features/settings/local_favorites.dart` | 0 |

处理原则：页面任务使用对应 context.mounted/State.mounted，并检查失败、finally 和资源释放；应用级任务在展示时取得当前可用根页面，不因原页面卸载误报任务失败。禁止靠全局屏蔽、dynamic 或移动到未检查辅助函数消除诊断。手势文件含用户修改，修复时选择性暂存。每阶段重新生成诊断并补行为回归。日志 output/context-lint-baseline.log 与 output/history-refresh-final-analyze.log。

收藏面板补验（2026-10-03）：网络区域只接收 FavoriteData，单/多文件夹共用受控提交；远端成功后的缓存失效先于 mounted 检查，提示/导航/父回调只在挂载时执行。目录异常可重试，本地新建文件夹的迟到完成不再刷新已卸载 State。5 项专项回归通过，最终日志见 output/favorite-lifecycle-{targeted,full,analyze}.log。

网络收藏页补验（2026-10-03）：目录加载移出 build，异常与卸载后结果受控；漫画/文件夹删除共用显式请求与提交回调的确认流程，创建弹窗释放文本控制器。远端成功仍清缓存并刷新存活父页面，不对已关闭弹窗执行导航；文件夹漫画删除传递真实 folderID。6 项专项回归通过，日志 output/network-favorites-{targeted,full,final-analyze}.log。

应用设置补验（2026-10-03）：四类存储任务共用页面进度展示所有者，异常也释放路由；授权能力检查包含过期请求序号和异常回退，UI 使用对应 context.mounted；同步配置提交使用实际 builder context 的挂载检查。任务展示专项 5 项通过；真实生物识别和平台选择器仍需平台补验。日志 output/settings-task-{targeted,final-full,final-analyze}.log。

收藏设置与统计补验（2026-10-03）：清理不可用收藏使用 SettingsTaskPresenter 收尾，成功计数仅回传存活页面。统计切换用布局后回调代替 20ms 定时器，并检查挂载、最新选择与滚动宿主；统计刷新也拒绝过期结果。3 项真实数据库/Widget 回归与已有 5 项任务展示回归通过；未以小样本测试宣称 >100 项后台 isolate 性能/竞态全部验收。日志 output/favorites-summary-{targeted,full,analyze}.log。

富文本评论补验（2026-10-03）：链接处理捕获原路由和导航器，打开应用链接后只移除仍活跃的原根导航页面，不 pop 新顶层页面；取消存活条件后不启动外部链接。Recognizer 由 State 持有，在文本/依赖变化及销毁时释放；文本更新清空旧 spans/images。5 项 Widget 回归与全量 1363 项通过，日志 output/rich-comment-{targeted,full,analyze}.log。

详情互动补验（2026-10-03）：点赞绑定漫画对象与当前挂载状态，异常后释放忙碌标记；评分弹窗直接接收提交操作，默认 1 星与显示一致，捕获异常并忽略卸载后结果。4 项专项覆盖重复、失败重试、切换漫画和弹窗替换。actions.dart 尚余下载路径 3 项，不据此完成详情域。日志 output/reaction-lifecycle-{targeted,full,final-analyze}.log。

详情下载补验（2026-10-03）：归档弹窗只返回普通/链接选择，源与漫画 ID 为固定输入，独立控制列表与链接请求；详情动作捕获原漫画/源/页面，异步选择后验证挂载和身份再入队，章节选择采用同一漫画。4 项弹窗回归与已有 3 项归档协议测试通过。已接受下载任务的底层取消、断网/续传等仍按 P6/P7 验收。日志 output/download-dialog-{targeted,full,final-analyze}.log。

本地收藏弹窗补验（2026-10-03）：新建/文件导入 UI 拆为显式验证、创建、选择读取和导入回调，控制器由 State 释放。导入期间禁止重复提交，选择/读取/解析异常均可重试，取消保留草稿，关闭后不提交读取结果。4 项回归通过；favorite_actions 剩余 1 项属于网络批量导入，尚未处理其提交/取消语义。日志 output/create-favorite-{targeted,full,analyze}.log。

网络收藏批量导入补验（2026-10-03）：预取与分页在独立 RequestScope 内，弹窗退出立刻取消等待/后续调度，完成后才同步事务提交；不再调用保存的 StateSetter 或延时关闭回调。收集失败和取消不提交暂存记录。10 项专项与全量 1385 项通过，详见 network_favorite_import.zh.md；底层源调用可能继续结束，提交后缓存/通知异常仍需后续处理。

本地跳转补验（2026-10-03）：延迟跳转捕获实际页面 context 并检查挂载/请求取消；replaceWithRootPage 只替换原路由，拒绝被覆盖或已卸载页面，阅读器参数与会话回调先捕获。调试重载失败提示从当前根 key 获取可空 context。3 项路由测试、全量 1388 项通过，日志 output/local-redirect-{targeted,full,final-analyze}.log。

## P5/P8：阅读图片动作生命周期与异步 context 门禁（2026-10-03）

- 复制/保存共用 useReaderImage，调用前校验视口存在，读取后校验挂载、视口、图片列表和章节身份；空图片提示与错误提示只作用于有效宿主，读取和平台操作异常均受控。平台操作已经启动后仍可完成，不宣称能撤销系统保存/剪贴板。
- 增加 6 项专项，覆盖失效前置检查、迟到图片/空结果、读取失败、平台失败与实际等待。全量 Windows Flutter 1394 项通过；分析零错误/警告、21 infos，use_build_context_synchronously 零诊断并提升为 warning。结构/架构（77 个业务入口）、Git 依赖、格式和 Python 63 项（3 个已有跳过）通过。日志 output/gesture-image-{targeted,full,analyze,python}.log。
- gesture.dart 与 CHANGELOG 选择性暂存，保留用户原有改动。P5/P8 与总方案仍未整体验收：其他 21 项 info、阅读壳职责、平台行为、性能和其余清单项继续执行。
