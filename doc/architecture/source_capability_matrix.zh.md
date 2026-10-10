# 漫画源能力兼容性矩阵

更新于 2026-10-09，R1 第二组。使用 Windows Flutter test、实际 QuickJS 动态库、assets/init.js、合成源与独立临时目录，不连接第三方在线源或读取个人数据。745 项相关域回归通过、无跳过；新旧证据与工具链见[批次报告](completion_batches_2026_10_09.md)。历史日志继续按其输入和提交使用。

| 能力 | 已验证行为与实际测试 | 剩余应用或平台边界 |
|---|---|---|
| 账户 | source_capabilities：特殊字符参数、身份保存、网页登录判断/成功、Cookie 校验、登出；连接错误下登录/登出/网页登录成功仅执行一次；同步状态结果和拒绝图释放 | 真实 WebView/Cookie 采集、登录保存失败与界面联合流程；不承诺远端动作和本地账户落盘为同一事务 |
| Cookie 桥 | js_cookie_admission、cookie_admission：同步 set/get/delete、忙碌/替换拒绝、真实 SQLite/Dio 连接与迟到响应归属 | WebView 与账户/localStorage 联合事务、实际平台生命周期 |
| 收藏 | source_capabilities、source_action_completion：未登录拒绝、过期后一次重登录、失败停止、页码/游标/文件夹读取、添加/删除/文件夹写入；原 Promise、结果及拒绝图释放，取消保留迟到错误 | 真实账户 UI 与远端结果；原库固定和 SQLite 提交/发布见 R1.1，完整存储验收归 R2 |
| 搜索 | source_capabilities、source_lifecycle：页码/游标、参数、分页标记、标签建议和源身份隔离；读取取消排空与同步建议释放；不支持的同步 Promise 保持立即回退并观察迟到引用 | 第三方非法数据组合不作为协议支持；真实应用端兼容归 R4 |
| 发现 | source_capabilities：multiPage 页码/游标、旧分区 Map、多分区列表及 mixed；viewMore 解析；所有读取的成功/拒绝/取消真实完成与引用释放 | 真实页面布局和导航联合场景归 R4 |
| 分类与排行 | source_capabilities：新旧目标、动态函数保留/替换/移除、动态选项参数、页码/游标排行；动态分类在借用期转换，错误及结果释放；异步读取取消排空 | 随机展示及完整界面选项组合归应用回归，不改变现有条件语义 |
| 详情与归档 | source_comic_completion、source_archive_completion、source_action_completion：详情嵌套模型、拒绝/非法结果释放，归档列表/链接、点赞/评分单次执行、源退休、重登录与取消；归档 UI 另有真实 JS 回归 | 外部下载、真实平台打开和文件原子性归 R2/R4 |
| 图片 | source_lifecycle、source_thumbnail_completion、reader_image_processing_native：章节图片、缩略图游标、异步配置、图片处理/native 回调、源退休与取消释放 | 插件、共享请求在实际设备上的生命周期与资源峰值归 R4 |
| 评论 | source_comments_completion、source_action_completion、source_lifecycle：普通/章节列表、发送/投票/点赞/回复、参数及分页、Promise 完成和拒绝图释放、源身份与重登录 | 实际 UI 及平台生命周期归 R4 |
| 元数据与设置 | source_capabilities、source_lifecycle、source_settings_widget、source_setting_callback：链接、标签、动态/静态设置、替换/回滚/释放、同步回调拒绝图、页面与原宿主；favorite_metadata_source 验证真实解析器取消与迟到失败 | 完整账户/设置/多页面联合流程；任意未返回后台脚本不由同步接口承诺排空 |
| JS UI 桥 | test/components/js_ui_native_test.dart 与 js_ui_test.dart：真实 resolve/reject 图、独立引擎、动作/取消、输入与选择、路由卸载、原宿主等待和显式释放 | 真实原生交互和系统终止；逻辑取消、Promise 完成、原生释放和外部应用消费分开验收 |

未显式写目录的源测试位于 test/features/comic_source/；cookie/js 测试位于 test/foundation/、test/network/。现有 normalization 测试负责数据归一化，不能替代真实 JS 执行。实际动态库不可用的环境必须记为未验证，不复制本机“通过”。

R1 新增 37 项：14 类读取各两项、3 类账户动作、5 类同步回调及1项不支持的同步 Promise。31 处 parser 错误边界统一区分取消，保留 cause/stack；Cookie validator 保持 bool/失败 false 的旧契约。账户动作不按只读规则重试，显式登录失效后的原重登录协议保留。公开回调名、参数、source key、持久化格式与 assets/init.js 未变。P7.2 保持 P，真实应用和最终兼容证据由 R4 补齐。
