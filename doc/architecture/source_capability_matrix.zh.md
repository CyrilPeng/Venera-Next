# 漫画源能力兼容性矩阵

2026-10-05 收藏调用方补充：普通收藏导入和追更/详情更新固定来源数据库代次，排队取消在 SQL 前检查；追更详情与时间在单个事务提交。网络导入的异步提交/发布分别保留结果，卸载后继续发布已提交结果，旧 receipt 不跨重开刷新缓存。该证据来自真实 SQLite 和可控页面/调用方测试，不新增对真实网络源或 JS 桥错误矩阵的完成声明；精确范围见最新 optimization_progress。

验证环境：Windows Flutter test + 实际 QuickJS 动态库；使用 assets/init.js 与合成源，独立临时数据目录，无网络或个人源数据。原生库不可用的环境会明确跳过，不能沿用本机结果宣称通过。这里记录行为范围，不代表 P7 整体验收完成。

| 能力 | 已执行的行为 | 测试证据 | 尚未覆盖的主要边界 |
|---|---|---|---|
| 账户 | 带引号/中文/反斜杠的登录参数、身份落盘；网页登录判断及成功回调、Cookie 校验、登出回调 | source_capabilities_test.dart | 实际网页/Cookie 存储与 UI；登录期间取消及保存失败 |
| Cookie 桥 | 真实 QuickJS 同步 set/get/delete 顺序和返回值，替换忙碌/缺库同步失败；真实 SQLite/Dio 请求与旧响应的连接归属 | test/foundation/js_cookie_admission_test.dart; test/network/cookie_admission_test.dart | 实际 WebView 采集与账户/localStorage 的联合事务、五平台前后台与源生命周期 |
| 收藏 | 未登录时不发请求；过期后只重登录一次；重登录失败、再次过期停止；多文件夹读取/新增/删除 | source_capabilities_test.dart | 收藏添加删除、收藏游标、所有重登录操作分支；结构化取消 |
| 搜索 | 页码/游标入口、参数顺序、下一页标记、标签建议；解析器复用时源身份隔离 | source_capabilities_test.dart; source_lifecycle_test.dart | 搜索选项全部形式、畸形响应交叉矩阵 |
| 发现 | 页码/游标列表、下一页标记及参数 | 同上 | 多分区及混合布局返回类型 |
| 分类 | 新旧固定分类目标、空列表；动态选项参数与带连字符标签；分类加载；排行游标；非法动态加载器回滚；有效动态函数执行、替换回滚/提交、源移除和引擎关闭释放 | source_capabilities_test.dart | 动态函数返回值和异步返回的完整错误矩阵；随机分类、页码排行和完整选项条件 |
| 漫画 | 详情加载、非法数据与源错误；源身份隔离 | source_lifecycle_test.dart | 点赞/评分、归档列表与下载 URL 的实际桥接 |
| 图片 | 章节图片、缩略图与下一页标记、异步图片配置、同步缩略图配置；源身份隔离 | source_lifecycle_test.dart | 图片处理函数/取消/配置错误的完整矩阵 |
| 评论 | 普通/章节评论列表与分页，发送回调与源身份隔离 | source_lifecycle_test.dart | 评论投票/点赞、回复参数、重登录与取消交叉矩阵 |
| 元数据 | 能力缺失；静态设置回调、动态 getter 快照与独立释放、异常回退、解析失败清理；页面重建/收起/卸载及回调晚到/失败/重试；版本/key/安装回滚 | source_lifecycle_test.dart | 链接、标签跳转、翻译及动态设置的多页面/源替换交互 |

测试文件位于 test/features/comic_source/。源输入归一化另由现有 normalization 测试覆盖，但纯数据测试不能代替真实 JS 桥接执行。全量及阶段日志见 optimization_progress.zh.md。动态分类已使用显式原生回调作用域；图片/UI 所有权证据见下文，后续继续补齐未执行能力；P7.2 继续为部分完成。

设置页面证据：source_settings_widget_test.dart 使用正式 ComicSourcePage、实际 JsCallbackScope 与受控 JSInvokable，验证快照销毁次数和页面行为；它补充原生测试，不代替真实 JS 函数执行。

图片与 UI 补充证据：reader_image_processing_native_test.dart 验证真实图片处理/取消协议；test/components/js_ui_native_test.dart 使用真实 QuickJS 与 Widget 验证异步动作/取消、输入及 Navigator 卸载，关闭引擎时检查原生引用释放。js_ui_test.dart 的 14 项受控用例补齐返回/遮罩/按钮/卸载、id 复用、异常重试及晚到结果。UI 回调现由弹窗作用域显式释放；归一化兼容入口已删除，正式归一化测试验证显式释放后不能调用；未结束 Promise 的引擎退出仍待审查。
