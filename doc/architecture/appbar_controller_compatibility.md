# 顶栏控制器归属 / Appbar controller ownership

本记录对应原优化方案 P2/P4/P8，基线 `fca7406`。`components/appbar.dart` 保留页面顶栏、标签栏、搜索输入及其渲染适配职责，不引入业务服务或兼容转发。

| 对象 | 归属与行为 |
|---|---|
| AppTabBar | 借用显式/默认 TabController，只订阅当前实例的实际动画；更换和销毁时解绑。自建 ScrollController 在销毁时释放。 |
| 标签布局 | 标签 key 随数量增减保留原位置，支持空列表。选中项居中等待当前实例的布局完成；失活、替换或销毁使旧回调失效。原居中计算和 200ms 动画保持。 |
| 页面恢复 | 首次挂载读取有效 PageStorage 索引；同一 State 换控制器使用新控制器的选择，不用旧存储覆盖它。主题/布局重建不重新施加旧索引。 |
| TabViewBody | 更换显式或默认控制器时立即读取新选择，解绑旧监听；空 children 显示空视图。调用方仍应使控制器长度与标签/children 对应。 |
| SearchBarController | 单个当前字段绑定。新字段覆盖旧绑定；旧字段卸载仅解除自己的绑定，不清除后来的字段。当前字段卸载后 text 返回空字符串，setText 不操作已释放字段，不自动回退到较早的字段。 |
| 搜索输入字段 | AppSearchBar/SliverSearchBar 复用私有生命周期 mixin；各自拥有并释放 TextEditingController。更换外部控制器使用其 currentText 初值，并更新提交目标；currentText 仍是初始文本，不新增草稿持久化。 |
| Sliver 搜索代理 | onChanged、FocusNode 和 action 改变时重建代理，避免继续使用旧输入目标。FocusNode 和 TabController 均不由这些借用方销毁。 |

回归覆盖重复依赖变化、显式/默认控制器替换、旧控制器迟到操作、标签增减和清空、PageStorage 恢复、选择项居中、深浅主题、375×812/812×375及2倍字号、搜索替换与重叠宿主、文本资源释放、最新回调/焦点/动作。8项修复前测试均失败，修复后12项新增回归通过。

四组正常界面以微软雅黑及打包 MaterialIcons 渲染，最终截图与基线逐像素一致。首次对照未包含 Scaffold 背景及图标字体，随后修正外部截图夹具并重新对照、目视核实；旧日志/图片保留。该证据覆盖选定静态状态，不代替全部原生输入、平台或性能验收。

同轮全文核实 `components/scroll.dart`、`features/comic_widgets/rating.dart` 和 `features/reader/chapter_navigation_button.dart` 为 UI 适配：分别负责滚动视口/输入、评分绘制/指针映射和章节动作展示；三文件原 blob 未改。组件分类不等于完成全部输入校验、可访问性和生命周期验收。收藏画廊列数、章节滑动提示方向等已定位事项继续按原方案推进。

AppTabBar owns only its scroll controller and subscriptions, never the supplied/default TabController. Subscription replacement follows the actual animation instance; delayed centering belongs to the active owner and completed layout. TabViewBody follows replacement controllers immediately. Initial PageStorage restoration remains, while later controller replacement honors the new controller's selection.

Search fields share a private lifecycle mixin and release their own TextEditingController. External controllers target only the latest attached field; old disposal cannot detach a newer owner. Detached reads return an empty string and writes do nothing. Replacement uses the new controller's initial text. Sliver delegate changes propagate current callbacks, actions and borrowed focus nodes. This does not add draft persistence or a multi-field broadcast controller.

The original static appearance matches four baseline screenshots. Full appbar/header rendering, tab-row rendering and TabActionButton bodies retain their original implementation. UI classification, synthetic tests and local Windows validation do not complete the original cross-platform/performance acceptance.
