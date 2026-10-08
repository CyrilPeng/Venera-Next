# 阅读提示与组件边界 / Reader presentation boundaries

本批相对 `1093eaa`，只修改章节滑动提示的展示与监听；其余六个组件只调整职责登记。阅读控制器、连续视图、设置请求、图片选择/导出、状态轮询业务、存储和源协议不变。

## 章节滑动提示

- 原 State 缓存首次 `isPrev`，文字/图标却读取当前参数。复用组件并反转方向后，进度仍使用旧边缘。现在每次根据当前方向及当前唯一有效 ScrollPosition 计算进度；初次展示和控制器替换也读取已有越界位置。
- 组件改为 StatelessWidget，通过 Flutter 的 ListenableBuilder 订阅借用的控制器。替换和卸载由框架解除监听，组件不销毁控制器。构造参数保持；仓库内没有依赖其旧 State 的调用。
- 未连接、多位置、尚无像素/内容范围、非有限偏移显示零进度。控制器通知或组件重建会重新取值。ScrollController 本身不通知 attach/detach；本批不引入轮询或声称独立连接变化会自动产生通知。
- 160 像素阈值、边缘计算、0–1 限制、圆角绘制、图标、文字与主题色保持。提示文字在空间不足时换行，避免大字号横向溢出。指示器不触发导航，连续视图原切章判定及手势逻辑未改。
- 唯一生产调用位于 ContinuousModeState.buildBackground。方向复用回归直接验证组件契约，不将其等同于已复现连续视图的特定子节点复用顺序；首次挂载已有越界位置是独立验证的行为。

## 七项 UI 登记

`chapter_swipe_indicator`、`information_text`、`top_bar`、`settings_panel`、`progress_bar`、`image_selection`、`status_info` 已全文审查并登记为 UI。

- 顶栏、页码/进度和描边文字只显示输入及转发命令；TextPainter 按次释放，进度身份与可见性键、键盘/语义行为保留。
- 设置面板装配原 SettingsSaveScope 与 ReaderSettingsRequest，不接管保存/效果业务。
- 图片选择拥有一次 OverlayEntry/Completer，原阅读壳负责销毁，图片收藏/导出传入取消回调；替换、移除和退出的既有测试保留。
- 状态展示包含原生电量适配及窗口/应用/前后台绑定；采样、暂停和迟到结果决策仍在独立 ReaderStatusPolling。完整生命周期回归已核查，未迁移这些实现。

完整清单为 502 文件：319 业务、141 UI、42 待审查，234 个业务入口。所有旧业务保护、57 条允许特性边和 46 文件剩余 SCC 保持；七项业务接回这些 UI 的探针全部被拒绝。六个非提示组件及相关业务/阅读壳 blob 不变。

## 验证范围

修复前 6 项测试中 5 项失败，分别暴露方向保留、首次进度遗漏、断开控制器断言，以及两个尺寸/字号的布局溢出。修复后 6 项通过，扩展到连续视图、自动阅读、底栏、语义、设置/图片/状态生命周期及真实阅读退出共 228 项通过。测试观察实际绘制进度，不读取私有 State 或 painter 字段。首次严格分析发现测试的冗余 physics 导入，已在冻结前移除。

加载真实字体/图标后，375×740 深色和 812×375 浅色常规字号两组截图与基线逐像素一致；375 深色两倍字号、812 浅色三倍字号图片已目视核查。控件使用主题语义色，无新增动画或交互目标。合成夹具不代表实机字体/平台行为或性能验收。

最终全量、覆盖率、门禁、构建与提交绑定以本轮执行记录为准。原 52 项保持 24 I / 27 P / 1 U；42 个待审查文件、剩余导航环、跨域/配置/生命周期/存储/JS/兼容、完整 CLI、声明 SDK、五平台及固定设备性能仍需完成。

## English

The hint reads the current direction and unique initialized scroll position through a framework-owned ListenableBuilder; borrowed controllers are never disposed. Existing overscroll is visible on mount/replacement. Missing, ambiguous, uninitialized or nonfinite metrics display zero on rebuild/notification. Controller attach/detach alone does not notify; no polling was added. The 160-pixel threshold, painter, normal layout and navigation remain unchanged; long scaled text wraps.

Seven fully reviewed presentation/adaptation files are now UI, retaining all business protections, 57 feature edges and the 46-file SCC. Inventory: 502 files, 319 business, 141 UI, 42 pending and 234 business entries. Six unchanged component blobs retain their original ownership protocols. Six new tests and 228 extended tests pass; two normal-text image pairs match and two large-text images were inspected. Full acceptance still requires remaining domain, compatibility, CLI, SDK, platform and fixed-device performance evidence.
