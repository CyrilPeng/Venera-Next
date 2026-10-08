# 导航手势与观察者归属 / Navigation ownership and compatibility

基线`866ccfb`。本次处理原方案P2业务/UI分类及P4导航资源生命周期；不改数据格式、源协议、CLI参数或依赖版本。

## 手势所有权 / Gesture ownership

- 已接受的竞技场项在OneSequenceGestureRecognizer析构时不会再次收到reject；EdgeBackRecognizer现在先取消当前手势，再移除指针路由。短距离、反向、竖向、非边缘与多指规则保留。
- IOSBackGestureController构造新增必需的`route`参数。页面、弹窗和侧栏三个实际生产入口传入所属Route；没有通过Navigator当前栈顶推测归属。原控制器仍借用路由的AnimationController，不负责销毁它。
- 输入结束后停止接受更新；完成与dispose均按单次归属配对停止Navigator手势。IOSBackGestureDetector保留回弹阶段控制器，失活或销毁时移除状态监听；销毁期间的停止通知延后到帧尾，避免重建锁冲突。整个Navigator已卸载时不向已销毁监听器发送通知。
- 迟到拖动结束时，原Route仍在栈中但被覆盖则恢复它；原Route已离栈则不弹出新Route。正常当前路由保留原速度/进度阈值及动画时长；取消仍恢复当前页，不把过半取消解释成返回。
- 路由过渡使用CurveTween驱动，替代每次build创建且未释放的CurvedAnimation；202个正/反向采样值一致。底栏原来只用CurvedAnimation通知重建，实际绘制一直读原controller.value；现在直接监听该controller，绘制语义不变。

## Pane与观察者 / Pane and observer lifetime

- NaviPane替换observer时解除旧订阅，并将同一个内层Navigator的路由快照交给新observer，清除旧快照。内层Navigator更换时首次路由事件绑定新实例并清除旧栈；Pane销毁后清除已脱离Navigator的快照。
- NaviObserver.didReplace在原位置替换被覆盖的路由，didPop按传入Route移除；不再把被替换路由移到栈顶或误删另一条路由。
- 通知迭代固定快照并检查监听是否仍存在。监听可以移除自身/其他项，新加入的监听从下一轮通知开始。
- 主视图更新回调按具体State绑定和解绑。旧视图卸载时不会清除新视图安装的回调，Pane最终卸载不留下指向已销毁State的回调。
- observer快照交接由NaviPane完成；直接使用Flutter Navigator并自行更换observer的调用者仍须负责观察历史的初始快照，未增加全局Navigator栈查询器。

## 验证与边界 / Evidence and limits

新增11项回归：6项边缘/iOS手势、5项导航观察/快照/回调/动画；五项修复前失败证明取消遗漏、拖动/回弹宿主移除、旧订阅和栈顺序问题。后续回归覆盖新页面不被误弹、另一手势不被重复停止、整个Navigator移除、监听增删、过渡反复重建和嵌套Navigator更换。

手势夹具覆盖375×812、812×375、深浅主题、1/3倍字号及减少动画环境；原菜单专项继续验证键盘、语义、安全区和大字号。测试使用合成Widget与注入的动画控制器，不启动个人数据应用；本机Widget结果不替代真实iOS原生事件、系统手势和全平台验收。

首次实现的可空Route索引类型错误已修正。第一次阅读器扩展回归漏配sqlite3.dll搜索路径，出现144项连带失败；补齐原Release目录PATH后180项扩展通过。失败日志保留，没有改超时/跳过项。最终全量和产物绑定见本次执行/验收记录。

菜单、导航栏、页面过渡及边缘手势四文件归入UI；全库仍有55文件待审查、47文件导航SCC待语义核实。其他组件的全局导航、保存准入、动画/交互一致性、服务生命周期、平台和性能继续按原方案推进，不把本次归类或局部修复等同最终验收。

The gesture controller explicitly owns one original Route and one Navigator gesture notification, while borrowing the route's animation controller. Detachment releases active/settling listeners, and late input cannot pop a newer page. Pane observers transfer or reset route snapshots with their actual Navigator; replacement preserves route order and callbacks detach by owner. UI classification and local regressions do not establish full native-device, accessibility, navigation-policy or overall-plan acceptance.
