# 调试执行兼容与资源说明 / Debug evaluation compatibility and ownership

执行边界基线`91865f4`，嵌套Promise清理基线`baad85f`。不改公开JS API、init.js、源格式、CLI参数或持久化协议。

## 行为与修复 / Behavior and fixes

- `DebugEvaluator`构造注入执行、同步释放和可选异步排空回调，构造不启动任务。每次start固定代码与执行器，只运行一次；调试代码可能有副作用，不复用runReadCode的只读重试。默认运行时与页面注入装配都提供嵌套结果排空。
- 顶层Future会被等待；Map/List优先缩进JSON，无法编码时回退toString，其余值直接toString。12个普通数据样本与基线方法一致。运行时绑定引用的内部类名可能与旧裸引用不同，调试文本中的私有类型名不作为稳定协议。
- `result`沿用30秒显示期限；超时不终止任意JS、不关闭共享引擎。含嵌套Promise的对象仍立即显示，`completion`等待顶层执行和已返回图的全部派生清理。嵌套拒绝只使completion失败，不改写已显示内容。UI用不捕获State的回调记录失败，迟到结果不会覆盖下一次显示；仅等待result的调用者也不会收到未观察的迟到清理异常。
- `DebugEvaluationFailure`保留原异常、原堆栈和不可变cleanupFailures列表，容纳同步和后续多个清理错误/堆栈，替代原单个cleanupError/cleanupStackTrace字段；项目内消费者已迁移。错误文本先于释放捕获。原异常的toString再次失败也不会跳过释放。原生引用已释放后不可继续调用，保留异常对象用于身份/诊断，不作为继续持有原生资源的承诺。
- 原始freeRecursive已保护循环容器，但不按JSRef身份去重，也不访问Map键。修复前真实页面回归观察共享引用销毁3次、仅作Map键的引用销毁0次，拒绝图引用销毁0次。现在复用discardJsResult，身份去重并访问键/值，单项释放失败仍尝试其他项；回归均为一次。
- 默认运行时装配使用传入引擎的runOwnedCode，JsEngine类及其后实现不改；类前共享遍历支持同步释放与派生排空。引擎关闭与消费之间的微任务竞态不会把引用转交给新引擎或再次销毁已关闭原生引用；运行中关闭的JsDisposedError标记cancelled，新提交在已关闭引擎被拒绝的StateError仍为failed。全部嵌套失败均为运行时关闭时，completion标记cancelled；混有真实脚本/释放错误时保留failed及全部诊断。其他脚本异常不按字符串猜测分类。
- `drainJsResultDescendants`要求调用方已尝试同步discardJsResult，并转移整个返回/拒绝图的引用释放责任；跨派生图共享身份集合，观察Map键/值、List、循环容器和重复Future，兄弟结果可独立释放。根图先登记后订阅，兼容同步Future。free失败不通过别名再次尝试，避免原生释放状态不明时二次释放。同步discardJsResult其他调用者的行为不变。
- 页面保留既有evaluate注入入口；注入者须转移返回/拒绝图的释放责任，真实引擎消费者应使用运行时工厂。重载源流程、布局和控件标签不变，忽略证书错误的开关复用已有NetworkPreferences与原保存组件。

## 验证范围与剩余项 / Evidence and remaining scope

新增19项回归：10项纯执行合同、5项原生引擎所有权、4项真实页面引用/期限回归。加上原有调试、JS引用/引擎/Promise/读取回归，扩展66项通过。服务测试和新原生测试使用注入依赖及独立运行时，没有全局reset；真实页面测试使用合成返回值，不启动个人数据应用。

首次原生夹具误用了close方法，随后修正为closeAndWait；新提交与运行中取消的类型预期、Future值matcher也根据实际契约修正，失败日志保留。没有修改引擎生命周期、测试超时或跳过列表来消除失败。

后续嵌套清理新增18项回归（6项结果图、5项纯执行、4项原生、3项同步注入/页面生命周期），扩展84项通过。修复前两个原生回归复现引用滞留和过早completion；修复后独立探针返回`{pending: Promise.resolve({callback: ...})}`，仍显示Future，await completion后的引用计数由1降为0，引擎关闭后仍为0。运行时替换、嵌套拒绝、多级/多分支、页面卸载和新一轮显示均有回归。

尚未完成：脚本启动但没有放入返回/拒绝结果图的异步工作或定时器不由该completion加入。原生桥传递的是复制后的普通容器；任意Dart注入者事后向已访问容器添加新引用不在此合同内。永不结束且不由引擎拥有的Dart Future会保持等待；本轮不增加强制取消或超时后丢弃引用。其他服务的JS消费策略、全域生命周期、平台行为和性能仍按原方案验收。

The service and runtime adapter separate UI from evaluation and reuse runtime ownership. Returned nested Promises now drain independently of the display deadline, releasing successful and rejected descendant graphs exactly once by identity. Original and cleanup failures remain observable without overwriting displayed output. Unreturned script work, arbitrary mutation of transferred Dart containers, other consumers, domain lifetimes, platform behavior and performance remain outside this unit's acceptance.
