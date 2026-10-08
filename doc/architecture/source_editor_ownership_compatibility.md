# 源脚本编辑兼容边界 / Source script editing compatibility

基线 `f677ee5`。源脚本格式、JS入口、初始化协议、持久化key、事务目录/schema和依赖版本未变。`replaceScript`从`Future<void>`返回本次实际替换的`Future<ComicSource>`；既有安装/更新/调试调用仍忽略结果，唯一测试替身同步返回类型。原变更主体逐段核对，仅增加精确成功结果，不改变提交点或错误类型。

| 场景 / Scenario | 行为 / Behavior |
|---|---|
| 同一编辑器连续保存 / Successive saves | 成功后接续本会话得到的实例；不在await后按key接管别的操作。 |
| 普通失败且完整回滚 / Complete rollback | 保留编辑内容，允许显式修改后重试。 |
| `applied` | 保留原错误/堆栈/恢复路径，暂停本会话保存；该状态可能包含提交决定写入失败，不等同于持久提交确认。 |
| `recoveryRequired` | 保留冲突文件与恢复证据，停止本会话后续保存；不猜测结果或覆盖未知修改。 |
| 保存期间继续编辑 / Editing while saving | 只将捕获的保存快照标为已保存，后续编辑仍需保存或确认丢弃。 |
| 关闭/路由覆盖/宿主更换发生在读取阶段 | 等待已接受的读取/启动完成，阻止迟到打开编辑器或开始源替换。 |
| 关闭发生在源替换已接纳之后 | 原应用与窗口继续等待真实变更完成，不把成功提交改写成取消。 |
| 数据目录改变 / Data directory changes | 在原管理器变更准入处拒绝旧编辑会话，避免在新目录初始化旧目标。 |
| 外部草稿 / External draft | 从单个共享`cache/source_edit/<key>.js`改为每次打开的独立临时目录，文件名沿用安装脚本名；这是缓存布局调整，不是源数据格式迁移。 |

外部编辑器的`code`启动调用仍使用原参数和shell方式，失败仍回退内置编辑器；异步边界验证原管理器、源、应用、窗口和路由。启动返回不证明用户已关闭编辑器。草稿在对话框关闭及启动结果不确定时继续保留，清理由原缓存策略决定，不强制终止外部编辑器。自动重开、检查/修复日志以及故障后恢复原编辑会话均不是本批提供的工作流；用户可保留草稿并使用原应用恢复机制。

漫画源页面从当前安装队列显式借用管理器，更换时解除旧监听，不创建或释放借用对象。列表和已迁移设置身份检查不再从全局源工厂取所有者。原设置保存/登录等待、源初始化、数据写入冻结、事务恢复、JS结果释放和公开API仍由原组件负责。更新检查服务结果配对、设置回调返回图、删除/更新导航和其他源能力继续单独验收。

验证包括四项旧生产页面失败、25项新增回归、实际SQLite提交决定拒绝与文件恢复冲突、同key替换、原应用/窗口关闭等待、360×640和800×360深色2倍字号错误布局。VS Code启动由实例注入替代，文件与数据库均为临时合成夹具。未启动真实应用访问个人数据；这些测试不替代五平台安装启动、真实外部编辑器集成、声明Flutter3.41.4或固定设备性能验收。

The editor follows only exact successful replacement receipts. Ordinary rolled-back failures remain retryable; applied or unresolved failures preserve their original diagnosis and stop replay within that session. Existing mutation, recovery, public JS and persistence contracts are unchanged. Original application/window ownership spans accepted preparation and saves; route or host changes suppress late admission, while committed writes are joined without post-completion cancellation. External drafts are independent cache files and remain available to an editor that may still own them. All platform/performance and remaining source-domain acceptance limits above stay open.
