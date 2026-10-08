# 详情预览加载与资源归属 / Detail preview ownership

本批相对 `887c397`，将缩略图游标和旧裁剪语法移入两个业务入口，预览组件保留展示、路由回调和宿主适配。评论预览更新输入并释放自有滚动控制器。详情页主体、图片绘制、存储格式、公开 JS API 和其他图片能力未改。

## 缩略图分页与退出

- `ComicThumbnailPages` 持有漫画 ID、加载回调和初始列表副本。首次请求保持 null 游标，后续空字符串仍是有效游标；顺序和重复项保留。对外列表不可修改。无加载器或宿主禁止准入时不登记工作。
- 同步预约唯一进行中的 Future，再登记原应用/窗口和通知视图，最后在微任务中执行加载器，避免初始列表末项布局再次发出第一页请求。重复调用共用原 Future；登记过程中发生关闭也不会启动已取消的加载器。
- 只有完整合法结果可以追加。加载异常、错误 Res、非法游标不推进页序；重试沿用原游标，清除旧错误。`next` 只接受 String/null，非法值现在返回 FormatException，不再先追加图片后由动态赋值抛错。
- 每次获准请求运行于 RequestScope，窗口关闭传播取消，但完成信号仍等待已接纳的实际加载。取消是合作式信号，不保证任意源脚本立即停止。移除组件、替换漫画/源/加载器/初始快照或宿主后，原请求继续归原宿主等待，迟到图片不能进入新列表。
- 真实失败即使晚于取消仍保留原 Res 或异常/堆栈；正常取消标为 `FailureKind.cancelled`。可逆窗口关闭失败后，已有失败尝试通过 Retry 显式重试；关闭期间挂载且尚未获准的初始请求可在恢复后启动。宿主仍冻结时不接纳新请求。
- 可选预览读取错误保留为结果，在已接纳工作结束后不单独阻止宿主关闭；不把错误结果当作成功图片。JS 引擎自身的最终资源清理仍由原引擎生命周期负责。

## JS 结果与旧裁剪规则

`parseThumbnailLoader` 复用 `runReadCodeToCompletion`，在同步消费阶段复制字符串列表和游标，随后释放未使用的原生引用。正常结果、无效列表/游标、异常引用图和取消后的迟到 Promise 均有真实 QuickJS 回归；原应用注册表通过分页模型等待实际 Promise 结束。源回调域已关闭时拒绝迟到结果。除该方法及所需导入外，图片页、加载配置与其他方法逐段一致，SourceParserContext/JsEngine 没有修改。

只在缩略图适配器中将 RequestCancelled 转换为 cancelled，保留原因和堆栈；未改变全局 Res.fromException 的分类规则。原生回归先复现了取消被误标 failed，再验证修正。

`ThumbnailImage.parse` 保留 `url@x=...&y=...` 的旧行为：只使用第一个 @ 后的片段；重复坐标覆盖；后续解析错误之前已写入的坐标仍保留；负号分隔等既有限制没有重新定义。视图只将坐标记录适配为 ImagePart。网格、图片控件、边框、比例、页码及点击导航代码保持一致。

## 评论预览

父组件更新时重新过滤当前评论，继续使用原 shouldBlockComment/关键词规则。没有增加全局设置监听，独立设置变化仍需原页面重建才能反映。组件销毁时释放自有 ScrollController；左右按钮仅操作唯一且已初始化的位置，并将目标限制在实际范围内。

长用户名在固定卡片内单行省略，完整文本仍保留在语义树中。评论内容、时间、卡片尺寸和 340 像素滚动步长不变。375 深色和 812 浅色两倍字号用例验证长名称、无布局异常及完整语义；这些用例不等同于实机字体验收。

## 边界和验证

两个预览组件全文核实为 UI，新增分页和裁剪两个业务入口。完整清单为 504 文件：321 业务、143 UI、40 待审查，236 个业务入口。原保护、57 条允许特性边及剩余 46 文件 SCC 保持；两个业务入口接回两个 UI 的四个探针均被拒绝。结构门禁发现的私有 types 导入已改用现有 comic_source_api 入口，没有新增例外。

新增 28 项回归：组件 7、分页 7、裁剪 1、应用/窗口归属 5、原生 JS 8。修复前复现五项预览问题、六项旧解析器问题，另有取消分类回归；所有原生用例在本机实际执行。扩展回归含漫画详情和相邻源能力共 177 项。

375×740 深色、812×375 浅色常规字号下，缩略图和评论共四组真实字体/图标截图与旧版逐像素一致，并已目视核查。首轮缩略图基线未等到图片解码，诊断图予以保留；最终对照明确等待两张实际 RawImage 解码完成。合成黑色图片只证明布局和绘制路径，不代表外部源图片质量。

开发阶段的图片夹具收尾、缺少 Material 的归属夹具、Retry 定位歧义和静态诊断已修正并保留日志；首轮结构检查失败后重新冻结源码并执行最终全量。没有增加跳过或放宽超时。全量、覆盖率、构建及提交绑定以执行记录和 detail-preview-artifact-hashes.json 为准。

原 52 项仍为 24 I / 27 P / 1 U。剩余文件职责、导航环、全域配置/接口/生命周期/存储/JS/兼容、完整 CLI、声明 SDK、五平台及固定设备性能继续验收。

## English

The pagination model reserves one shared future before callbacks, registers original application/window owners before starting a loader, and joins accepted work after cooperative cancellation. Replacement/removal rejects late publication while keeping original ownership. Valid cursors, ordering, duplicates and retry positions are preserved; invalid cursors fail before any append. Real late failures retain diagnostics, and RequestCancelled is classified only in this adapter without changing global Res behavior.

The thumbnail parser synchronously detaches string/cursor data and releases native result/error graphs through the existing completion bridge. Real QuickJS and application-drain tests cover cancellation, retirement and invalid results. Crop syntax retains legacy partial parsing; grid/image/navigation code is unchanged. Comment previews refresh on parent updates, dispose their own controller, clamp scroll targets and ellipsize long authors without dropping semantic text.

Two new business entries and two UI classifications retain all protections, 57 feature edges and the 46-file SCC. Inventory: 504 files, 321 business, 143 UI, 40 pending, 236 entries. Four reverse-UI probes are rejected; private imports were corrected to the existing public business entry. There are 28 new and 177 extended regressions, four verified normal-layout image pairs, and two large-text widget cases. Full domain/platform/performance acceptance remains open.
