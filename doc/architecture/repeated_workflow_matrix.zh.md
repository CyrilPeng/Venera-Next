# 重复流程与共享机制对照

日期：2026-10-03；代码基线：8f77c1c，工作区含未提交用户修改。本文完成 P7.3 的机制对照，不代表 P7 的协议、错误和生命周期验收全部完成。路径相对仓库根目录。

## 五类流程

| 流程与代码证据 | 去重/调度 | 进度、取消与资源所有权 | 提交语义与复用判断 |
|---|---|---|---|
| 源更新：`lib/features/comic_source/source_update_service.dart` | 同源更新拒绝重入；检查更新共享 `_checking`；按源保存 token | 每次更新独占 Dio；取消释放源键，finally 按 token 身份清理，允许旧请求收尾期间重试 | `replaceScript` 的 validate 核对源/仓库身份，进入提交后不再允许 UI 取消。保留专用更新协议，不能套用最后订阅者取消规则 |
| 图片：`lib/network/shared_request_stream.dart`、`lib/features/reader/image_precache.dart` | SharedRequestStream 首次订阅启动；预取按 provider 去重 | 最后订阅者离开才取消共享请求；预取释放自己的监听及 pending 缓存，不移除 live 消费者；解码完成后保留一帧 | 网络字节完成与 Flutter 图片解码/缓存并非同一提交点。保留请求层和视图层两种所有者，不将单个阅读视图销毁升级为全局图片取消 |
| 归档下载/导出：`lib/features/local_comics/archive_download_task.dart`、`lib/features/local_comics/import_export/comic_export_service.dart` | 下载按 generation 作废旧运行，恢复等待旧运行/清理；导出逐本执行 | 下载统计字节与速度，暂停保留独占工作目录用于续传；导出统计本数，临时文件保留到 save 完成 | 原生解压不能立即中断，须等待后再清理；已登记漫画拥有输出目录。导出取消不撤回已完成保存。保持下载、格式转换与保存适配器，不能用 Future.any 提前清理文件 |
| 应用同步：`lib/features/sync/data_sync_controller.dart`、`lib/features/sync/data_sync_transfer.dart` | 控制器维护 active/pending 任务和自动调度；每次传输独占远端连接 | RequestScope 传递取消；关闭远端连接但继续等待任务清理；下载临时目录由传输拥有 | 上传新归档获确认后才清理旧恢复点；下载比较版本，区分未应用与已应用；替换开始后由参与者完成提交/回滚，已应用仍通知。禁止对写入无条件自动重试，响应丢失不证明远端未写入 |
| 文档导入：`lib/features/local_comics/import_export/document_import.dart`、`pdf_import_batch.dart`（同目录）、`lib/features/local_comics/local_storage_guard.dart` | PDF 批次顺序执行，区分重复文件/标题；storage guard 协调导入与迁移/恢复 | PDF 按文件/页报告，DocumentImportCancellation 合作取消；selection 在 finally 释放；退出拒绝新任务并等待已接纳存储操作 | importFile 返回意味着登记完成，迟到取消不能改成 cancelled；DocumentImportSession.finish 仅生成模型，登记仍由调用者负责。保留批次结果和存储准入，不能替换为通用网络队列 |

## 已有共享机制与边界

| 原语 | 真实调用者/证据 | 必须保留的限制 |
|---|---|---|
| `lib/foundation/throttled_task_runner.dart` | history_manager 的刷新；webdav_library_synchronizer 的目录刷新（并发 4、无批次延迟） | 只共享有限并发和批次节流；取消检查阻止继续调度，不中断已开始任务；单项错误策略由调用者决定 |
| `lib/foundation/platform_dialog_queue.dart` | `file_interaction.dart` 中两个独立实例：`_mobileFileSaves` 供移动 `saveFile` 使用；`Share._dialogs` 由 `Share.shareFile` 和 `Share.shareText` 共用 | 当前 `run` 回调的原 Future 返回或失败后才放行下一项；取消准入、文件清理和错误展示仍由调用者负责。两个实例不相互排队，也不覆盖网络、图片读取或桌面保存；平台确认不证明外部接收者消费完成 |
| `lib/network/request_scope.dart` | chapter_image_loader、reader_controller、data_sync_transfer、JS 引擎、follow_updates | 父子取消、超时、HTTP token 和取消等待；run 可以先结束等待，不能证明底层工作已停止；dispose 仅释放计时器/父关系，不等于 cancel |
| `lib/foundation/sqlite_transaction.dart` | local/history/favorites 仓储及收藏导入 | 同步 SQL 事务和嵌套 savepoint；禁止异步工作，不能覆盖文件写入；保留原操作与回滚双重失败 |
| `lib/foundation/directory_replacement.dart` | app_data_transfer 的恢复协调 | 调用者先停用资源，目录备份/恢复；路径重叠和目标类型校验不等于全链符号链接或崩溃恢复验收 |
| `DocumentImportSession` | PDF/EPUB 导入的页面路径、封面、模型生成和失败清理 | 保留格式解码差异；不是跨文件和 DB 原子事务 |

`lib/features/follow_updates/follow_update_queue.dart` 与批次节流表面相似，但它同时约束全局并发、同源并发及同源间隔，跳过被限流源继续处理其他源；不能直接换成 runThrottledTasks。进度的字节、本数、页数、版本/应用结果也不应压成一个失去含义的百分比。

## 后续动作与验收

1. 保留上述已使用原语；本次对照不新增执行框架或仅转发参数的包装层。任何后续提取须列出至少两个语义一致的调用者、删除的重复实现，以及重入/失败/取消测试。
2. P7.4 继续审查重试与进度：只读重试需明确次数、超时、取消和原始错误；写入需先确认幂等/提交边界。没有这些证据时保留业务适配，不自动推广。
3. P6 补齐删除原子性、符号链接及所有存储写入者覆盖；storage guard 的存在不代表每个写入口都已登记。P4 补齐停机/失败资源矩阵；P7.5 继续错误类型与消费端翻译。
4. 现有回归入口：`test/network/{request_scope,shared_request_stream}_test.dart`、`test/foundation/{throttled_task_runner,sqlite_transaction,directory_replacement}_test.dart`、`test/features/follow_updates/follow_update_queue_test.dart`、`test/features/local_comics/local_storage_guard_test.dart`、`test/features/local_comics/import_export/{pdf_import_batch,comic_export_service}_test.dart`、`test/features/sync/data_sync_transfer_test.dart`。花括号为文件名缩写，不是单个路径。

本阶段只新增审查文档，逐项核对实现和测试入口，不重复运行完整测试。上一代码阶段日志 `output/legacy-codec-full.log` 为 1306 项通过，`output/legacy-codec-analyze.log` 为零 error/warning、65 个 info；该结果不证明本表所列剩余验收已完成。

## 设置任务展示共性落实（2026-10-03）

SettingsTaskPresenter 仅管理当前设置页的进度路由、重复触发、异常提示和收尾。真实调用者为目录迁移、清缓存、导出与导入，原四份手工弹窗关闭路径已移除。页面退出不取消已接受的存储任务，finally 始终关闭该任务持有的路由；业务临时文件清理仍留在导入任务中。它不提供自动重试、业务回滚、跨页面互斥或网络请求取消，也不替代 P6 的存储锁。失败/重入/卸载后的完成由 settings_task_presenter_test 覆盖。

## 图片保存共性落实（2026-10-05）

阅读器图片操作与图片收藏/封面保存均使用 `lib/foundation/image_work.dart`：取消阻止下一阶段，已开始的读取、原生交付和释放必须实际完成。原 reader 路径和类型直接迁移，不保留转发。`image_save_work.dart` 只统一三个页面的字节读取、文件名快照和交付；`image_save_binding.dart` 负责路由与窗口，阅读会话继续拥有进度、时长和平台效果。

详情页和封面查看器原两份匿名首帧监听/转换已由 `image_provider/read_image.dart` 替代，保留其他消费者与成功缓存。`file_save_operation.dart` 拥有每次保存的临时目录，写入/复制后检查 `checkStop`，移动保存还在自己的队列出队后、调用插件前检查。已进入平台的保存等待移动插件实际返回，或桌面 `XFile.saveTo` 实际完成，再清理本次目录；用户取消和失败也走清理，调用方传入的文件不被删除。返回的 Future 包含清理，原操作和清理同时失败时保留两者及原始堆栈。移动插件串行限制不推广到网络、读取或桌面保存。重入、取消、错误与真实页面/窗口交接分别由 `image_save_work_test.dart`、`read_image_provider_test.dart`、`file_save_test.dart`、`image_save_binding_test.dart` 和 `image_favorite_save_test.dart` 验证。

## 分享队列与文件所有权落实（2026-10-05）

`Share.shareFile` 与 `Share.shareText` 共用上述分享队列，等待原平台 Future，失败不会阻断后续请求。文件分享在排队结束后检查 `checkStop`；`share_file_operation.dart` 在 `App.cachePath/shares` 下创建独立目录，异步完整写入并校验长度后再次检查，尚未派发的取消或失败只清理自己的目录。Linux 文件分享在创建源文件前拒绝。阅读器传入图片任务的检查函数，漫画详情页文本分享通过 `canShare` 再核对页面、漫画和窗口准入；文本内容保留请求开始时的快照。`resolveOrigin` 在实际交付前重新取得可见区域，文件分享也在写入后刷新，避免排队期间窗口调整后使用旧的 iPad 弹出位置。

保存完成与分享派发采用不同的源文件协议。Windows、iOS 和 macOS 的分享源在进入平台调用后保留，即使返回异常也不推断未交付。Android 的 `packages/share_plus/android/src/main/kotlin/dev/fluttercommunity/plus/share/ShareFileSession.kt` 先同步复制输入；应用侧等待原平台调用结束后清理自己的输入目录，分享 Future 包含这次清理，但已交付的原生 URI 副本继续保留，选择器返回或后续分享不会清除它们。平台确认、窗口等待结束与外部应用完成读取不是同一个事件；本轮不提供外部消费终点驱动的回收。

`test/foundation/share_file_operation_test.dart` 验证独立目录、写入、保留及双错误；`test/foundation/share_file_test.dart` 验证真实方法通道、文件/文本队列、排队和写入中的取消、动态位置与输入生命周期；`test/features/comic_details/share_lifecycle_test.dart` 验证页面快照、防重入、卸载/关闭等待、迟到失败恢复及位置边界。Android 原生复制所有权另由 `packages/share_plus/android/src/test/kotlin/dev/fluttercommunity/plus/share/ShareOwnershipTest.kt` 覆盖。方法通道和原生单测不代表外部接收应用或全部平台真机验收。
